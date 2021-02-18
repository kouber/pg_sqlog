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
