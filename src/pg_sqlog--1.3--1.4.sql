ALTER FUNCTION sqlog.autoanalyze         SECURITY DEFINER;
ALTER FUNCTION sqlog.duration            SECURITY DEFINER;
ALTER FUNCTION sqlog.log                 SECURITY DEFINER;
ALTER FUNCTION sqlog.log_path            SECURITY DEFINER;
ALTER FUNCTION sqlog.preparable_query    SECURITY DEFINER;
ALTER FUNCTION sqlog.set_date            SECURITY DEFINER;
ALTER FUNCTION sqlog.temporary_file_size SECURITY DEFINER;


ALTER TYPE sqlog.autovacuum ADD ATTRIBUTE wal_records          int;
ALTER TYPE sqlog.autovacuum ADD ATTRIBUTE wal_full_page_images int;
ALTER TYPE sqlog.autovacuum ADD ATTRIBUTE wal_bytes            bigint;


CREATE OR REPLACE FUNCTION sqlog.autovacuum(timestamp = now()) RETURNS SETOF sqlog.autovacuum AS $$
DECLARE
  cpu_usage text;
  wal_usage text := '$';
  usr_idx   smallint;
  sys_idx   smallint;
  context   text;
BEGIN
  PERFORM sqlog.set_date($1);

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
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;


CREATE FUNCTION sqlog.summary(text, lead int = 30, trail int = NULL) RETURNS text AS $$
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


DO $$
BEGIN
  IF CURRENT_SETTING('server_version_num')::int >= 130000 THEN
    ALTER FOREIGN TABLE sqlog.log ADD backend_type text;
  END IF;
END
$$ LANGUAGE plpgsql;
