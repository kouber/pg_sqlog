\echo Use "CREATE EXTENSION pg_sqlog" to load this file. \quit


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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


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


DO $$
BEGIN
  IF CURRENT_SETTING('server_version_num')::int >= 130000 THEN
    ALTER FOREIGN TABLE @extschema@.log ADD backend_type text;
  END IF;

  IF CURRENT_SETTING('server_version_num')::int >= 140000 THEN
    ALTER FOREIGN TABLE @extschema@.log ADD leader_pid int;
    ALTER FOREIGN TABLE @extschema@.log ADD query_id   bigint;
  END IF;
END
$$ LANGUAGE plpgsql;


CREATE FUNCTION format_cache_table(timestamp) RETURNS name AS $$
  SELECT 'log_' || TO_CHAR($1, 'YYYYMMDD');
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE FUNCTION cache_exists(timestamp) RETURNS name AS $$
  SELECT
    tablename
  FROM
    pg_tables
  WHERE
    schemaname = '@extschema@'
  AND
    tablename = @extschema@.format_cache_table($1);
$$ LANGUAGE sql STABLE STRICT;


CREATE FUNCTION create_cache(timestamp = now(), rebuild bool = false) RETURNS name AS $$
DECLARE
  tbl name;
  cln name;
BEGIN
  IF pg_is_in_recovery() THEN
    RAISE NOTICE 'caching on a replica is not supported';

    RETURN NULL;
  END IF;

  BEGIN
    PERFORM pg_advisory_lock(current_setting('@extschema@.advisory_lock_key')::bigint);

    IF NOT current_setting('@extschema@.cache')::bool THEN
      RAISE EXCEPTION 'Caching is disabled'
      USING HINT = 'Check @extschema@.cache setting';
    END IF;

    tbl := @extschema@.format_cache_table($1);

    RAISE NOTICE 'Building daily cache "%" ...', tbl;

    IF rebuild THEN
      EXECUTE FORMAT('DROP TABLE IF EXISTS @extschema@.%I', tbl);
    END IF;

    EXECUTE FORMAT('
      CREATE UNLOGGED TABLE IF NOT EXISTS @extschema@.%I AS SELECT * FROM @extschema@.log(%L)',
      tbl,
      $1
    );

    FOR cln
      IN
    SELECT
      fld
    FROM
      unnest(string_to_array(replace(current_setting('@extschema@.cache_index_fields'), ' ', ''), ',')) fld
    LOOP
      BEGIN
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %1$s_%2$s_idx ON @extschema@.%1$I (%2$I)', tbl, cln);
      EXCEPTION WHEN duplicate_table THEN
      END;
    END LOOP;
  EXCEPTION WHEN undefined_object THEN
    RAISE NOTICE 'incomplete cache configuration';
  END;

  PERFORM pg_advisory_unlock_all();

  RETURN tbl;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE FUNCTION drop_cache(tbl name) RETURNS name AS $$
BEGIN
  EXECUTE FORMAT('DROP TABLE IF EXISTS @extschema@.%I', $1);

  RETURN $1;
EXCEPTION WHEN read_only_sql_transaction THEN
  RAISE NOTICE 'caching on a replica is not supported';

  RETURN NULL;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE FUNCTION drop_cache(timestamp = now()) RETURNS name AS $$
  SELECT @extschema@.drop_cache(@extschema@.format_cache_table($1));
$$ LANGUAGE sql SECURITY DEFINER;


CREATE FUNCTION day_is_completed(timestamp) RETURNS boolean AS $$
  SELECT $1 AT TIME ZONE current_setting('log_timezone') < CURRENT_DATE AT TIME ZONE current_setting('log_timezone');
$$ LANGUAGE sql;


CREATE FUNCTION set_date(timestamp = now()) RETURNS date AS $$
DECLARE
  log_path text;
BEGIN
  log_path := @extschema@.log_path($1);

  EXECUTE FORMAT('ALTER TABLE @extschema@.%I OPTIONS (SET filename %L)',
                 'log',
                 log_path);

  RETURN $1;
EXCEPTION WHEN read_only_sql_transaction THEN
  DECLARE
    log_file text;
  BEGIN
    SELECT
      REGEXP_REPLACE(
        ftoptions::text,
        '^.*?filename=([^,]+).*?$',
        E'\\1'
      )
    FROM
      pg_catalog.pg_foreign_table
    WHERE
      ftrelid = '@extschema@.log'::regclass
    INTO
      log_file;

  IF log_path = log_file THEN
    RETURN $1;
  ELSE
    log_file = REGEXP_REPLACE(log_file, '^' || CURRENT_SETTING('log_directory') || '/', '');
  END IF;

  RAISE NOTICE 'Dynamic date passing is not allowed on a slave node, falling back to "%"', log_file
    USING ERRCODE = 'read_only_sql_transaction',
          HINT    = 'Mind controlling the date by calling @extschema@.set_date() on the master node';
  END;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


CREATE FUNCTION duration(message text) RETURNS numeric AS $$
  SELECT
    CASE WHEN $1 ~ '^duration: \d+' THEN
      REGEXP_REPLACE($1, '^duration: ([\d\.]+) ms.*', E'\\1')::numeric
    ELSE
      NULL
    END;
$$ LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER;


CREATE FUNCTION preparable_query(message text) RETURNS text AS $$
  SELECT
    REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE($1, '^(duration: [^:]+ (<unnamed>|statement|execute [^:]+): +)?', ''),
          '('')[\d\w\.:\-\+ ]+('')',
          E'\\1?\\2',
          'g'
        ),
        '([^\d\w])\d+([^\d\w])?',
        E'\\1?\\2',
        'g'
      ),
      '([^A-Za-z_]IN[^A-Za-z_]*\()[\''\?, ]+(\))',
      E'\\1?\\2',
      'g'
    );
$$ LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER;


CREATE FUNCTION summary(text, lead int = 30, trail int = NULL) RETURNS text AS $$
DECLARE
  str text;
BEGIN
  str := REGEXP_REPLACE($1, '^(duration: [^:]+ (<unnamed>|statement|execute [^:]+): +)?', '');

  IF $2 < 0 OR LENGTH(str) <= $2 THEN
    RETURN str;
  END IF;

  IF trail IS NULL THEN
    trail := lead;
  END IF;

  RETURN SUBSTRING(str, 1, lead) || ' ... ' || SUBSTRING(str, LENGTH(str) - trail + 1);
END
$$ LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER;


CREATE FUNCTION temporary_file_size(text) RETURNS bigint AS $$
  SELECT
    CASE WHEN $1 ~ '^temporary file:' THEN
      REGEXP_REPLACE($1, '^temporary file:.*? size (\d+)$', E'\\1')::bigint
    ELSE
      0
    END;
$$ LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER;


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
  elapsed                   numeric,
  wal_records               int,
  wal_full_page_images      int,
  wal_bytes                 bigint
);


-- in sync with output format as defined within the PostgreSQL source code:
-- src/access/heap/vacuumlazy.c
-- src/backend/utils/misc/pg_rusage.c

CREATE FUNCTION autovacuum(timestamp = now()) RETURNS SETOF autovacuum AS $$
DECLARE
  cpu_usage text;
  wal_usage text := '$';
  usr_idx   smallint;
  sys_idx   smallint;
  context   text;
BEGIN
  PERFORM @extschema@.set_date($1);

  IF CURRENT_SETTING('server_version_num')::int >= 130000 THEN
    wal_usage := '.*?WAL usage: (\d+) records, (\d+) full page images, (\d+) bytes$';
  END IF;

  IF CURRENT_SETTING('server_version_num')::int >= 100000 THEN
    cpu_usage := 'CPU: user: ([^ ]+) s, system: ([^ ]+) s, elapsed: ([^ ]+) s';
    usr_idx := 18;
    sys_idx := 19;
  ELSE
    cpu_usage := 'CPU ([\.\d]+)s/([\.\d]+)u sec elapsed ([\.\d]+) sec';
    usr_idx := 19;
    sys_idx := 18;
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
    m[20]::numeric,
    m[21]::int,
    m[22]::int,
    m[23]::bigint
  FROM (
    SELECT
      log_time,
      REGEXP_MATCHES(
        message,
        '^automatic(?: aggressive)? vacuum of table "([^\.]+)\.([^\.]+)\.([^\.]+)": index scans: (\d+).*?pages: (\d+) removed, (\d+) remain(?:, (\d+) skipped due to pins)?(?:, (\d+) skipped frozen)?.*?tuples: (\d+) removed, (\d+) remain(?:, (\d+) are dead but not yet removable)?(?:, oldest xmin: (\d+))?.*?buffer usage: (\d+) hits, (\d+) misses, (\d+) dirtied.*?avg read rate: ([^ ]+) MB/s, avg write rate: ([^ ]+) MB/s.*?system usage: ' || cpu_usage || wal_usage,
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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


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

  IF CURRENT_SETTING('server_version_num')::int < 100000 THEN
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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;
