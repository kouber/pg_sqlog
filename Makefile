EXTENSION = pg_sqlog

DATA = $(wildcard src/pg_sqlog--*.sql)

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
