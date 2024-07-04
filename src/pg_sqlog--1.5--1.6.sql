CREATE OR REPLACE FUNCTION sqlog.format_cache_table(timestamp) RETURNS name AS $$
  SELECT 'log_' || TO_CHAR($1, 'YYYYMMDD');
$$ LANGUAGE sql IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION sqlog.create_cache(timestamp = now(), rebuild bool = false) RETURNS name AS $$
DECLARE
  tbl name;
  cln name;
BEGIN
  BEGIN
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
