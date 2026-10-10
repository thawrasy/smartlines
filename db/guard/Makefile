# Builds masslak_guard.so against the server it will load into: make (or make with_llvm=no where clang is absent)
MODULES = masslak_guard
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
