CREATE OR REPLACE FUNCTION sqlog.set_date(timestamp = now()) RETURNS date AS $$
DECLARE
  log_path text;
BEGIN
  log_path := sqlog.log_path($1);

  EXECUTE FORMAT('
    ALTER TABLE sqlog.%I OPTIONS (SET filename %L)
  ', 'log', log_path);

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
      ftrelid = 'sqlog.log'::regclass
    INTO
      log_file;

  IF log_path = log_file THEN
    RETURN $1;
  ELSE
    log_file = REGEXP_REPLACE(log_file, '^' || CURRENT_SETTING('log_directory') || '/', '');
  END IF;

  RAISE NOTICE 'Dynamic date passing is not allowed on a slave node, falling back to "%"', log_file
    USING ERRCODE = 'read_only_sql_transaction',
          HINT    = 'Mind controlling the date by calling sqlog.set_date() on the master node';
  END;

  RETURN NULL;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION sqlog.autovacuum(timestamp = now()) RETURNS SETOF sqlog.autovacuum AS $$
DECLARE
  mask_suffix text;
  usr_idx     smallint;
  sys_idx     smallint;
  context     text;
BEGIN
  PERFORM sqlog.set_date($1);

  IF CURRENT_SETTING('server_version_num')::int < 100000 THEN
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
        '^automatic(?: aggressive)? vacuum of table "([^\.]+)\.([^\.]+)\.([^\.]+)": index scans: (\d+).*?pages: (\d+) removed, (\d+) remain(?:, (\d+) skipped due to pins)?(?:, (\d+) skipped frozen)?.*?tuples: (\d+) removed, (\d+) remain(?:, (\d+) are dead but not yet removable)?(?:, oldest xmin: (\d+))?.*?buffer usage: (\d+) hits, (\d+) misses, (\d+) dirtied.*?avg read rate: ([^ ]+) MB/s, avg write rate: ([^ ]+) MB/s.*?system usage: ' || mask_suffix,
        'g'
      ) AS m
    FROM
      sqlog.log
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


CREATE OR REPLACE FUNCTION sqlog.autoanalyze(timestamp = now()) RETURNS SETOF sqlog.autoanalyze AS $$
DECLARE
  mask_suffix text;
  usr_idx     smallint;
  sys_idx     smallint;
  context     text;
BEGIN
  PERFORM sqlog.set_date($1);

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
      sqlog.log
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
