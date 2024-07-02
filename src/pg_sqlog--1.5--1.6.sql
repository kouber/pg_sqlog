CREATE OR REPLACE FUNCTION sqlog.format_cache_table(timestamp) RETURNS name AS $$
  SELECT 'log_' || TO_CHAR($1, 'YYYYMMDD');
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION sqlog.create_cache(timestamp = now(), rebuild bool = false) RETURNS name AS $$
DECLARE
  tbl name;
  cln name;
BEGIN
  BEGIN
    SET sqlog.caching_in_progress TO on;

    PERFORM pg_advisory_lock(current_setting('sqlog.advisory_lock_key')::bigint);

    IF NOT current_setting('sqlog.cache')::bool THEN
      RAISE EXCEPTION 'Caching is disabled'
      USING HINT = 'Check sqlog.cache setting';
    END IF;

    tbl := sqlog.format_cache_table($1);

    RAISE NOTICE 'Building daily cache "%" ...', tbl;

    IF rebuild THEN
      EXECUTE FORMAT('DROP TABLE IF EXISTS sqlog.%I', tbl);
    END IF;

    EXECUTE FORMAT('
      CREATE UNLOGGED TABLE IF NOT EXISTS sqlog.%I AS SELECT * FROM sqlog.log(%L)',
      tbl,
      $1
    );

    FOR cln
      IN
    SELECT
      fld
    FROM
      unnest(string_to_array(replace(current_setting('sqlog.cache_index_fields'), ' ', ''), ',')) fld
    LOOP
      BEGIN
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %1$s_%2$s_idx ON sqlog.%1$I (%2$I)', tbl, cln);
      EXCEPTION WHEN duplicate_table THEN
      END;
    END LOOP;
  EXCEPTION WHEN undefined_object THEN
    RAISE NOTICE 'incomplete cache configuration';
  END;

  SET sqlog.caching_in_progress TO off;

  PERFORM pg_advisory_unlock_all();

  RETURN tbl;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION sqlog.drop_cache(tbl name) RETURNS name AS $$
BEGIN
  EXECUTE FORMAT('DROP TABLE IF EXISTS sqlog.%I', $1);

  RETURN $1;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION sqlog.drop_cache(timestamp = now()) RETURNS name AS $$
  SELECT sqlog.drop_cache(sqlog.format_cache_table($1));
$$ LANGUAGE sql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION sqlog.day_is_completed(timestamp) RETURNS boolean AS $$
  SELECT $1 AT TIME ZONE current_setting('log_timezone') < CURRENT_DATE AT TIME ZONE current_setting('log_timezone');
$$ LANGUAGE sql;


CREATE OR REPLACE FUNCTION sqlog.set_date(timestamp = now()) RETURNS date AS $$
DECLARE
  log_path text;
BEGIN
  log_path := sqlog.log_path($1);

  EXECUTE FORMAT('ALTER TABLE sqlog.%I OPTIONS (SET filename %L)',
                 'log',
                 log_path);

  IF current_setting('sqlog.cache', true)::bool AND current_setting('sqlog.cache_auto', true)::bool AND current_setting('sqlog.caching_in_progress', true)::bool IS DISTINCT FROM TRUE THEN
    IF sqlog.day_is_completed($1) THEN
      PERFORM sqlog.create_cache($1);
    END IF;
  END IF;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION sqlog.log(timestamp = now()) RETURNS SETOF sqlog.log AS $$
DECLARE
  context text;
  tbl     name;
BEGIN
  PERFORM sqlog.set_date($1);

  tbl := sqlog.format_cache_table($1);

  PERFORM NULL FROM pg_tables WHERE schemaname = 'sqlog' AND tablename = tbl;

  IF FOUND THEN
    IF NOT sqlog.day_is_completed($1) THEN
      RAISE NOTICE 'Using cache "%"', tbl;
    END IF;

    RETURN QUERY EXECUTE FORMAT(REGEXP_REPLACE(current_query(), 'sqlog\.log ?\(.*?\)', 'sqlog.%s'), tbl);
  END IF;

  RETURN QUERY SELECT * FROM sqlog.log;
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
