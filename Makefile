EXTENSION = sqlog

DATA = $(wildcard src/sqlog--*.sql)

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
