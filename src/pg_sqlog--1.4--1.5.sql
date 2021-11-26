DO $$
BEGIN
  IF CURRENT_SETTING('server_version_num')::int >= 140000 THEN
    ALTER FOREIGN TABLE sqlog.log ADD leader_pid int;
    ALTER FOREIGN TABLE sqlog.log ADD query_id   bigint;
  END IF;
END
$$ LANGUAGE plpgsql;
