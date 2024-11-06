1.7
---
- Rename `sqlog.create_cache()` to `sqlog.cache()`;
- Introduce automatic cache expiry mechanism through `sqlog.expire_cache()` routine and `sqlog.cache_expire_interval` configuration option;
- Add `sqlog.today` and `sqlog.yesterday` views.

1.6
---
- Allow caching of daily logs.

1.5
---
- Provide PostgreSQL 14 support:
  - add `leader_pid` and `query_id` columns to `sqlog.log()` output.

1.4
---
- Provide PostgreSQL 13 support:
  - add `backend_type` column to `sqlog.log()` output;
  - add WAL usage data to `sqlog.autovacuum()` output.
- Make the functions' security _definer_, thus allowing roles with lower privileges to use the extension (when granted access to the _sqlog_ schema).
- Add `sqlog.summary()` function, allowing to strip meta data from the query and dispaying just the first N, the last N, or both characters of it.

1.3
---
- Allow querying of slave node logs.
- Optimise `sqlog.autoanalyze()` and `sqlog.autovacuum()` routines.

1.2
---
- Fix `sqlog.preparable_query()` regular expression incorrect handling of numbers within database identifiers.
- Make `sqlog.autovacuum()` support older PostgreSQL versions all the way down to 9.3.

1.1
---
- Fix `sqlog.preparable_query()` regular expression incorrect handling of timestamps and exotic data types within an IN list.

1.0
---
- Initial version.
