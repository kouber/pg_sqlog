# SQLog #
An extension providing access to PostgreSQL logs through SQL interface.

## Description ##

`SQLog` allows to query a [foreign table](https://www.postgresql.org/docs/current/static/file-fdw.html), pointing to a log, recorded in a [CSV format](https://www.postgresql.org/docs/current/static/runtime-config-logging.html#RUNTIME-CONFIG-LOGGING-CSVLOG). It has special functions to extract the query duration of each query, as well as to group similar queries together.

## Prerequisites ##

```
log_destination   = 'syslog,csvlog' # 'csvlog' should be present
log_filename      = 'postgresql.%a' # any combination of %F, %Y, %m, %d and %a
logging_collector = 'on'
log_rotation_age  = '1d'            # at max 1 log file per day
log_rotation_size = 0
log_truncate_on_rotation = 'on'
```

## Tables ##

* `sqlog.log` - a template table, pointing to a log file, generated through a given day. It could be either queried through the special `sqlog.log()` _set of_ function, or directly in a combination with the `sqlog.set_date()` function. By default the date is set to the last call to `sqlog.log()` or `sqlog.set_date()`.

## Functions ##

* `sqlog.log([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving the contents of the PostgreSQL log file for a given day. If _interval_ is omitted, then the current day's log is returned. Calls `sqlog.set_date()` implicitly.
* `sqlog.set_date([timestamp])` - a function to control the `sqlog.log` _filename_ option. Once set to a given date, it stays that way until another call to it. Note that calling this function will influence the contents of the `sqlog.log` table for all the other concurrent sessions as well (if any).
* `sqlog.duration(text)` - extracts the query duration from the _message_ field in milliseconds.
* `sqlog.preparable_query(text)` - replaces all the possible arguments of a query found in the _message_ field with question marks, thus providing a preparable query, effectively grouping similar queries together.
* `sqlog.temporary_file_size(text)` - extracts the file size of each temporary file that has been created and logged, according to the `log_temp_files` configuration option.
* `sqlog.autovacuum([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving human readable report of the _autovacuum_ runs for a given day. Calls `sqlog.set_date()` implicitly.
* `sqlog.autoanalyze([timestamp])` - a [set returning](https://www.postgresql.org/docs/current/static/functions-srf.html) function, giving human readable report of the _autoanalyze_ runs for a given day. Calls `sqlog.set_date()` implicitly.

## Installation ##

After cloning the [postgresql-sql-schema](https://gitlab.mailjet.com/SQL/postgresql-sql-schema/) git project, enter the `extensions/sqlog` directory and run the building command.

`$ sudo make install`

## Examples ##

Setting the context of all functions and views to 1 June 2017. After that point the `sqlog.log` contents point to that date.

```
postgres=# SELECT sqlog.set_date('2017-06-01');
  set_date
------------
 2017-06-01
(1 row)

postgres=# SELECT error_severity, COUNT(*) FROM sqlog.log GROUP BY 1;
 error_severity | count
----------------+-------
 FATAL          |     6
 WARNING        |    27
 LOG            |   949
 ERROR          |    10
(4 rows)
```

Another way is to use the `sqlog.log()` function directly. After this call the context will be switched to the current day (5 June 2017).

```
postgres=# SELECT error_severity, COUNT(*) FROM sqlog.log() GROUP BY 1;
 error_severity | count
----------------+-------
 FATAL          |     8
 WARNING        |   101
 LOG            |  3703
 ERROR          |    72
(4 rows)

postgres=# SELECT ftoptions FROM pg_foreign_table WHERE ftrelid = 'sqlog.log'::regclass;
                              ftoptions
---------------------------------------------------------------------
 {filename=/var/log/postgresql/postgresql.2017-06-05.csv,format=csv}
(1 row)
```

Getting the top 5 slowest queries of the day.

```
postgres=# SELECT sqlog.duration(message), sqlog.preparable_query(message) FROM sqlog.log() ORDER BY 1 DESC NULLS LAST LIMIT 5;
 duration  |                                 preparable_query
-----------+----------------------------------------------------------------------------------
 10010.451 | select pg_sleep(?);
  4740.150 | prepare prepst?  as select id,user_id,ip_rw,pool,run_level from app order by id
  4511.554 | prepare prepst?  as select id,user_id,ip_rw,pool,run_level from app order by id
  3339.613 | prepare prepst?  as select id,user_id,ip_rw,pool,run_level from app order by id
  2694.001 | UPDATE app SET overdraft=?, credit=?, skipspamd=?, last_update=? WHERE user_id=?
(5 rows)
```

Getting the most frequently logged query, along with its average duration.

```
postgres=# SELECT sqlog.preparable_query(message), AVG(sqlog.duration(message)), COUNT(*) FROM sqlog.log('2017-06-01') GROUP BY 1 ORDER BY 2 DESC NULLS LAST LIMIT 1;
                       preparable_query                       |          avg          | count
--------------------------------------------------------------+-----------------------+-------
 UPDATE app SET credit=?+overdraft WHERE id=? and overdraft>? | 1158.1232790697674419 |    43
(1 row)
```

Getting a random _autovacuum_ report for the day.

```
postgres=# select * from sqlog.autovacuum() limit 1;
-[ RECORD 1 ]-------------+---------------------------
log_time                  | 2018-11-06 06:03:00.178+00
database                  | p0196500
schema_name               | public
table_name                | kafka_savepoint
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