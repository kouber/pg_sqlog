DROP FUNCTION IF EXISTS sqlog.create_cache;

CREATE OR REPLACE FUNCTION sqlog.cache(timestamp = now(), rebuild bool = false) RETURNS name AS $$
DECLARE
  tbl name;
  cln name;
BEGIN
  IF pg_is_in_recovery() THEN
    RAISE NOTICE 'caching on a replica is not supported';

    RETURN NULL;
  END IF;

  BEGIN
    PERFORM pg_advisory_lock(current_setting('sqlog.advisory_lock_key')::bigint);

    IF NOT current_setting('sqlog.cache')::bool THEN
      RAISE EXCEPTION 'Caching is disabled'
      USING HINT = 'Check sqlog.cache setting';
    END IF;

    tbl := sqlog.format_cache_table($1);

    RAISE NOTICE 'Building daily cache "%" ...', tbl;

    IF rebuild THEN
      EXECUTE FORMAT('DROP TABLE IF EXISTS sqlog.%I CASCADE', tbl);
    ELSE
      BEGIN
        PERFORM sqlog.expire_cache();
      EXCEPTION WHEN others THEN
        RAISE NOTICE 'Unable to expire old cache tables';
      END;
    END IF;

    EXECUTE FORMAT('
      CREATE UNLOGGED TABLE IF NOT EXISTS sqlog.%I (LIKE sqlog.log)',
      tbl
    );

    EXECUTE FORMAT('
      COPY sqlog.%I FROM %L CSV',
      tbl,
      sqlog.log_path($1)
    );

    -- create indexes
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

    -- switch sqlog.today & sqlog.yesterday
    IF $1::date >= CURRENT_DATE - '1 day'::interval THEN
      EXECUTE FORMAT('CREATE OR REPLACE VIEW sqlog.today AS SELECT * FROM sqlog.%I', tbl);

      IF sqlog.cache_exists($1 - '1 day'::interval) IS NOT NULL THEN
        EXECUTE FORMAT('CREATE OR REPLACE VIEW sqlog.yesterday AS SELECT * FROM sqlog.%I', sqlog.format_cache_table($1 - '1 day'::interval));
      END IF;
    END IF;
  EXCEPTION WHEN undefined_object THEN
    RAISE NOTICE 'incomplete cache configuration';
  END;

  PERFORM pg_advisory_unlock_all();

  RETURN tbl;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;


CREATE OR REPLACE FUNCTION sqlog.expire_cache(keep interval = NULL) RETURNS SETOF name AS $$
DECLARE
  tbl name;
BEGIN
  IF keep IS NULL THEN
    keep := current_setting('sqlog.cache_expire_interval')::interval;
  END IF;

  IF keep = '0 days' THEN
    RAISE NOTICE 'Cache expiry is disabled (sqlog.cache_expire_interval)';
    RETURN;
  END IF;

  tbl := sqlog.format_cache_table(CURRENT_DATE - keep);

  FOR tbl IN SELECT
    tablename
  FROM
    pg_tables
  WHERE
    schemaname = 'sqlog'
  AND
    tablename ~ '^log_\d+$'
  AND
    tablename < tbl
  LOOP
    PERFORM sqlog.drop_cache(tbl);
    RETURN NEXT tbl;
  END LOOP;

  RETURN;
END
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION sqlog.drop_cache(tbl name) RETURNS name AS $$
BEGIN
  EXECUTE FORMAT('DROP TABLE IF EXISTS sqlog.%I CASCADE', $1);

  RETURN $1;
EXCEPTION WHEN read_only_sql_transaction THEN
  RAISE NOTICE 'caching on a replica is not supported';

  RETURN NULL;
END
$$ LANGUAGE plpgsql SECURITY DEFINER;
