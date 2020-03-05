CREATE OR REPLACE FUNCTION sqlog.preparable_query(message text) RETURNS text AS $$
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
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION sqlog.autovacuum(timestamp = now()) RETURNS SETOF sqlog.autovacuum AS $$
DECLARE
  mask_suffix text;
  usr_idx     smallint;
  sys_idx     smallint;
  context     text;
BEGIN
  PERFORM sqlog.set_date($1);

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
