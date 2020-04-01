1.3
---
- Allow querying of slave node logs.
- Optimise `autoanalyze()` and `autovacuum()` routines.

1.2
---
- Fix `preparable_query()` regular expression incorrect handling of numbers within database identifiers.
- Make `autovacuum()` support older PostgreSQL versions all the way down to 9.3.

1.1
---
- Fix `preparable_query()` regular expression incorrect handling of timestamps and exotic data types within an IN list.

1.0
---
- Initial version.
