# pg_sqlog #
An extension providing access to PostgreSQL logs through SQL interface.

## Description ##

`pg_sqlog` allows to query a [foreign table](https://www.postgresql.org/docs/current/static/file-fdw.html), pointing to a log, recorded in a [CSV format](https://www.postgresql.org/docs/current/static/runtime-config-logging.html#RUNTIME-CONFIG-LOGGING-CSVLOG). It has special functions to extract the query duration of each query, as well as to group similar queries together.

## Prerequisites ##

Set `log_min_duration_statement` to a non-negative value in order to record the slow queries.

```
log_min_duration_statement  = 1000  # logs every query taking more than 1 second
```

This extension depends on `file_fdw` as well as on the following configuration directives.

```
log_destination   = 'syslog,csvlog' # 'csvlog' should be present
log_filename      = 'postgresql.%F' # any combination of %F, %Y, %m, %d, %a
logging_collector = 'on'
log_rotation_age  = '1d'            # at max 1 log file per day
log_rotation_size = 0
log_truncate_on_rotation = 'on'
```

To use the special `autovacuum` and `autoanalyze` reports you need to set `log_autovacuum_min_duration` to a non-negative value.

```
log_autovacuum_min_duration = 0
```

## Tables ##

* `sqlog.log` - a template table, pointing to a log file, generated through a given day. It could be either queried through the special `sqlog.log()` _set of_ function, or directly in a combination with the `sqlog.set_date()` function. By default the date is set to the last call to `sqlog.log()` or `sqlog.set_date()`.

## Functions ##

* `sqlog.log([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving the contents of the PostgreSQL log file for a given day. If _interval_ is omitted, then the current day's log is returned. Calls `sqlog.set_date()` implicitly.
* `sqlog.set_date([timestamp])` - a function to control the `sqlog.log` _filename_ option. Once set to a given date, it stays that way until another call to it. Note that calling this function will influence the contents of the `sqlog.log` table for all the other concurrent sessions as well (if any).
* `sqlog.duration(text)` - extracts the query duration from the _message_ field in milliseconds.
* `sqlog.preparable_query(text)` - replaces all the possible arguments of a query found in the _message_ field with question marks, thus providing a preparable query, effectively grouping similar queries together.
* `sqlog.temporary_file_size(text)` - extracts the file size of each temporary file that has been created and logged, according to the `log_temp_files` configuration option. Pass `sqlog.message` as argument.
* `sqlog.autovacuum([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving human readable report of the _autovacuum_ runs for a given day. Calls `sqlog.set_date()` implicitly.
* `sqlog.autoanalyze([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving human readable report of the _autoanalyze_ runs for a given day. Calls `sqlog.set_date()` implicitly.

## Installation ##

After making the project, copy the `conf/pg_sqlog.conf` file to the `conf.d/` PostgreSQL directory (or make the appropriate changes to your `postgresql.conf` file directly) and restart the service.

## Examples ##

Get a summary of the errors reported for the day.

```
postgres=# SELECT error_severity, COUNT(*) FROM sqlog.log() GROUP BY 1;
 error_severity | count
----------------+-------
 FATAL          |     6
 WARNING        |    27
 LOG            |   949
 ERROR          |    10
(4 rows)
```

Get the top 3 slowest queries of the day.

```
SELECT
  AVG(sqlog.duration(message)),
  COUNT(*),
  sqlog.preparable_query(message)
FROM
  sqlog.log()
WHERE
  message ~ '^duration'
GROUP BY
  3
ORDER BY
  2 DESC
LIMIT
  3;

                       preparable_query                       |          avg          | count
--------------------------------------------------------------+-----------------------+-------
 SELECT pg_sleep(?)                                           | 9002.774              |     2
 SELECT id, name FROM invoice WHERE status > ?                | 4367.3729834738293848 |    12
 UPDATE app SET credit=?+overdraft WHERE id=? and overdraft>? | 1158.1232790697674419 |    43
(1 row)
```

Get a random _autovacuum_ report for the day.

```
postgres=# select * from sqlog.autovacuum() limit 1;
-[ RECORD 1 ]-------------+---------------------------
log_time                  | 2018-11-06 06:03:00.178+00
database                  | db
schema_name               | public
table_name                | account
idx_scans                 | 1
pages_removed             | 1
pages_remain              | 16
pages_skipped_pins        | 0
pages_skipped_frozen      | 0
tuples_removed            | 455
tuples_remain             | 27
tuples_dead_not_removable | 0
oldest_xmin               | 224250521
buffer_hits               | 187
buffer_misses             | 0
buffer_dirtied            | 7
read_mbs                  | 0.000
write_mbs                 | 0.033
cpu_user                  | 0.04
cpu_system                | 0.02
elapsed                   | 1.64
```

## Querying slave node logs ##

Analyzing queries on a slave node is also possible. In order to change the date make a call to `sqlog.set_date([date])` on the master node prior to querying `sqlog.log` on the slave.
