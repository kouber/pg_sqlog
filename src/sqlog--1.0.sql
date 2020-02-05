\echo Use "CREATE EXTENSION sqlog" to load this file. \quit


CREATE FUNCTION check_settings() RETURNS boolean AS $$
BEGIN
  IF CURRENT_SETTING('log_destination') NOT LIKE '%csvlog%' THEN
    RAISE invalid_parameter_value USING MESSAGE = '"log_destination" parameter should include ''csvlog''';
  END IF;

  IF CURRENT_SETTING('log_filename') ~ '%[^YmdFa]' THEN
    RAISE invalid_parameter_value USING MESSAGE = '"log_filename" parameter should be limited to: %Y, %m, %d, %F or %a';
  END IF;

  IF NOT CURRENT_SETTING('logging_collector')::bool THEN
    RAISE invalid_parameter_value USING MESSAGE = '"logging_collector" parameter should be set to ''on''!';
  END IF;

  IF NOT CURRENT_SETTING('log_truncate_on_rotation')::bool THEN
    RAISE invalid_parameter_value USING MESSAGE = '"log_truncate_on_rotation" parameter should be set to ''on''!';
  END IF;

  IF CURRENT_SETTING('log_rotation_age')::interval < '1 day' THEN
    RAISE invalid_parameter_value USING MESSAGE = '"log_rotation_age" parameter should be set to a value >= ''1 day''';
  END IF;

  IF CURRENT_SETTING('log_rotation_size') != '0' THEN
    RAISE invalid_parameter_value USING MESSAGE = '"log_rotation_size" parameter should be set to 0';
  END IF;

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql VOLATILE;


SELECT check_settings();


CREATE FUNCTION log_path(timestamp = now()) RETURNS text AS $$
DECLARE
  filename TEXT;
BEGIN
  filename := RTRIM(CURRENT_SETTING('log_filename'), '.log');

  filename := REPLACE(filename, '%F', '%Y-%m-%d');
  filename := REPLACE(filename, '%Y', TO_CHAR($1, 'YYYY'));
  filename := REPLACE(filename, '%m', TO_CHAR($1, 'MM'));
  filename := REPLACE(filename, '%d', TO_CHAR($1, 'DD'));
  filename := REPLACE(filename, '%a', TO_CHAR($1, 'Dy'));

  RETURN CURRENT_SETTING('log_directory') || '/' || filename || '.csv';
END;
$$ LANGUAGE plpgsql STABLE;


CREATE SERVER sqlog FOREIGN DATA WRAPPER file_fdw;


CREATE FOREIGN TABLE log (
  log_time               timestamp(3) with time zone,
  username               text,
  database               text,
  process_id             integer,
  connection_from        text,
  session_id             text,
  session_line_num       bigint,
  command_tag            text,
  session_start_time     timestamp with time zone,
  virtual_transaction_id text,
  transaction_id         bigint,
  error_severity         text,
  sql_state_code         text,
  message                text,
  detail                 text,
  hint                   text,
  internal_query         text,
  internal_query_pos     integer,
  context                text,
  query                  text,
  query_pos              integer,
  location               text,
  application_name       text
)
SERVER
  sqlog
OPTIONS
  (filename '/dev/null', format 'csv');


CREATE FUNCTION set_date(timestamp = now()) RETURNS date AS $$
BEGIN
  EXECUTE FORMAT('
    ALTER TABLE @extschema@.%I OPTIONS (SET filename %L)
  ', 'log', @extschema@.log_path($1));

  RETURN $1;
END;
$$ LANGUAGE plpgsql;


CREATE FUNCTION log(timestamp = now()) RETURNS SETOF log AS $$
DECLARE
  context text;
BEGIN
  PERFORM @extschema@.set_date($1);

  RETURN QUERY SELECT * FROM @extschema@.log;
EXCEPTION
  WHEN undefined_file THEN
    RAISE WARNING '%', SQLERRM
      USING ERRCODE = 'undefined_file';
  WHEN bad_copy_file_format THEN
    GET STACKED DIAGNOSTICS context = PG_EXCEPTION_CONTEXT;

    RAISE WARNING 'Corrupted CSV format (%), incomplete result set!', SQLERRM
      USING ERRCODE = 'bad_copy_file_format',
            HINT    = REGEXP_REPLACE(context, E'^(.*?)\nPL/pgSQL.*$', E'\\1');
END;
$$ LANGUAGE plpgsql STABLE;


CREATE FUNCTION duration(message text) RETURNS numeric AS $$
  SELECT
    CASE WHEN $1 ~ '^duration: \d+' THEN
      REGEXP_REPLACE($1, '^duration: ([\d\.]+) ms.*', E'\\1')::numeric
    ELSE
      NULL
    END;
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE FUNCTION preparable_query(message text) RETURNS text AS $$
  SELECT
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE($1, '^(duration: [^:]+ (<unnamed>|statement|execute [^:]+): +)?', ''),
          '('')[\d\.:\- ]+('')',
          E'\\1?\\2',
          'g'
        ),
        '([^\d])\d+([^\d])?',
        E'\\1?\\2',
        'g'
      ),
      '([^A-Za-z_]IN[^A-Za-z_]*\()[\d\?, ]+(\))',
      E'\\1?\\2',
      'g'
    );
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE FUNCTION temporary_file_size(text) RETURNS bigint AS $$
  SELECT
    CASE WHEN $1 ~ '^temporary file:' THEN
      regexp_replace($1, '^temporary file:.*? size (\d+)$', E'\\1')::bigint
    ELSE
      0
    END;
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE TYPE autovacuum AS (
  log_time                  timestamp(3) with time zone,
  database                  name,
  schema_name               name,
  table_name                name,
  idx_scans                 int,
  pages_removed             int,
  pages_remain              int,
  pages_skipped_pins        int,
  pages_skipped_frozen      int,
  tuples_removed            int,
  tuples_remain             int,
  tuples_dead_not_removable int,
  oldest_xmin               xid,
  buffer_hits               int,
  buffer_misses             int,
  buffer_dirtied            int,
  read_mbs                  numeric,
  write_mbs                 numeric,
  cpu_user                  numeric,
  cpu_system                numeric,
  elapsed                   numeric
);


-- in sync with output format as defined within the PostgreSQL source code:
-- src/backend/commands/vacuumlazy.c
-- src/backend/utils/misc/pg_rusage.c

CREATE FUNCTION autovacuum(timestamp = now()) RETURNS SETOF autovacuum AS $$
DECLARE
  mask_suffix text;
  usr_idx     smallint;
  sys_idx     smallint;
  context     text;
BEGIN
  PERFORM @extschema@.set_date($1);

  IF VERSION() ~ '^PostgreSQL 9\.' THEN
    mask_suffix := 'CPU ([\.\d]+)s/([\.\d]+)u sec elapsed ([\.\d]+) sec$';
    usr_idx := 19;
    sys_idx := 18;
  ELSE
    mask_suffix := 'CPU: user: ([^ ]+) s, system: ([^ ]+) s, elapsed: ([^ ]+) s$';
    usr_idx := 18;
    sys_idx := 19;
  END IF;

  RETURN
    QUERY
  SELECT
    log_time,
    m[1]::name,
    m[2]::name,
    m[3]::name,
    m[4]::int,
    m[5]::int,
    m[6]::int,
    m[7]::int,
    NULLIF(m[8]::text, '')::int,
    m[9]::int,
    m[10]::int,
    m[11]::int,
    NULLIF(m[12]::text, '')::xid,
    m[13]::int,
    m[14]::int,
    m[15]::int,
    m[16]::numeric,
    m[17]::numeric,
    m[usr_idx]::numeric,
    m[sys_idx]::numeric,
    m[20]::numeric
  FROM (
    SELECT
      log_time,
      REGEXP_MATCHES(
        message,
        '^automatic(?: aggressive)? vacuum of table "([^\.]+)\.([^\.]+)\.([^\.]+)": index scans: (\d+).*?pages: (\d+) removed, (\d+) remain, (\d+) skipped due to pins(?:, (\d+) skipped frozen)?.*?tuples: (\d+) removed, (\d+) remain, (\d+) are dead but not yet removable(?:, oldest xmin: (\d+))?.*?buffer usage: (\d+) hits, (\d+) misses, (\d+) dirtied.*?avg read rate: ([^ ]+) MB/s, avg write rate: ([^ ]+) MB/s.*?system usage: ' || mask_suffix,
        'g'
      ) AS m
    FROM
      @extschema@.log
    WHERE
      command_tag IS NULL
    AND
      message ~ '^automatic( aggressive)? vacuum'
  ) AS regx;
EXCEPTION
  WHEN undefined_file THEN
    RAISE WARNING '%', SQLERRM
      USING ERRCODE = 'undefined_file';
  WHEN bad_copy_file_format THEN
    GET STACKED DIAGNOSTICS context = PG_EXCEPTION_CONTEXT;

    RAISE WARNING 'Corrupted CSV format (%), incomplete result set!', SQLERRM
      USING ERRCODE = 'bad_copy_file_format',
            HINT    = REGEXP_REPLACE(context, E'^(.*?)\nPL/pgSQL.*$', E'\\1');
END;
$$ LANGUAGE plpgsql STABLE;


CREATE TYPE autoanalyze AS (
  log_time                  timestamp(3) with time zone,
  database                  name,
  schema_name               name,
  table_name                name,
  cpu_user                  numeric,
  cpu_system                numeric,
  elapsed                   numeric
);


-- in sync with output format as defined within the PostgreSQL source code:
-- src/backend/commands/analyze.c
-- src/backend/utils/misc/pg_rusage.c

CREATE FUNCTION autoanalyze(timestamp = now()) RETURNS SETOF autoanalyze AS $$
DECLARE
  mask_suffix text;
  usr_idx     smallint;
  sys_idx     smallint;
  context     text;
BEGIN
  PERFORM @extschema@.set_date($1);

  IF VERSION() ~ '^PostgreSQL 9\.' THEN
    mask_suffix := 'CPU ([\.\d]+)s/([\.\d]+)u sec elapsed ([\.\d]+) sec$';
    usr_idx := 5;
    sys_idx := 4;
  ELSE
    mask_suffix := 'CPU: user: ([^ ]+) s, system: ([^ ]+) s, elapsed: ([^ ]+) s$';
    usr_idx := 4;
    sys_idx := 5;
  END IF;

  RETURN
    QUERY
  SELECT
    log_time,
    m[1]::name,
    m[2]::name,
    m[3]::name,
    m[usr_idx]::numeric,
    m[sys_idx]::numeric,
    m[6]::numeric
  FROM (
    SELECT
      log_time,
      REGEXP_MATCHES(
        message,
        '^automatic analyze of table "([^\.]+)\.([^\.]+)\.([^\.]+)" system usage: ' || mask_suffix,
        'g'
      ) AS m
    FROM
      @extschema@.log
    WHERE
      command_tag IS NULL
    AND
      message ~ '^automatic analyze'
  ) AS regx;
EXCEPTION
  WHEN undefined_file THEN
    RAISE WARNING '%', SQLERRM
      USING ERRCODE = 'undefined_file';
  WHEN bad_copy_file_format THEN
    GET STACKED DIAGNOSTICS context = PG_EXCEPTION_CONTEXT;

    RAISE WARNING 'Corrupted CSV format (%), incomplete result set!', SQLERRM
      USING ERRCODE = 'bad_copy_file_format',
            HINT    = REGEXP_REPLACE(context, E'^(.*?)\nPL/pgSQL.*$', E'\\1');
END;
$$ LANGUAGE plpgsql STABLE;
