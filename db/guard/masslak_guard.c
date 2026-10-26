/*
 * masslak_guard: the settings the database trusts can be set only by the platform's own functions
 * (reviews of release 1.49.0, the residual path of finding C-01).
 *
 * Row-level security reads who is acting (user, company, scope) from transaction settings that sys.set_context writes
 * once it has checked the request's signed ticket, and the ledger, requirement, file-scan and cargo guards read flags
 * that the platform's functions raise for the length of one statement. Schema file 1080 withdrew set_config from every
 * role, so injected SQL cannot change them, but PostgreSQL still lets any login type SET app.scope = 'PLATFORM' as a
 * statement of its own: a setting nobody has defined is a placeholder, and anyone may set a placeholder.
 *
 * Loaded with the server (shared_preload_libraries), this module defines each of those settings with the superuser
 * context. A login without that right gets "permission denied to set parameter" for SET, SET LOCAL, RESET, a value
 * in its connection options, and ALTER ROLE ... SET. The functions that set them legitimately are SECURITY DEFINER and
 * owned by the superuser that applies the schema, so they keep working. Reading a setting is not restricted: the row
 * rules read them in every statement, on the primary and on the read-only standbys alike, at no extra cost.
 *
 * The list is the single place the protected names are written in C; sys.guarded_settings() (1084) returns the same
 * list to the database, and backend/tests/test_settings_guard.py checks that every custom setting the schema trusts
 * is on it.
 */
#include "postgres.h"

#include "fmgr.h"
#include "utils/guc.h"

PG_MODULE_MAGIC;

static const char *const guarded[] = {
	/* the request context (sys.set_context, 1080) */
	"app.user_id",
	"app.company_id",
	"app.scope",
	"app.api_client_id",
	"app.request_id",
	"app.ip",
	"app.session_id",
	"app.party_id",
	/* rows the current transaction created, which their creator may read back (sys.created_here, 1084) */
	"app.new_rows",
	/* flags the platform's functions raise while they work */
	"fin.posting_entry",			/* a ledger posting may change a wallet balance (1039, 1052) */
	"masslak.requirement_change",	/* an approved change of a configurable requirement (1044) */
	"masslak.cargo_backfill",		/* the cargo capacity backfill (1067) */
	"masslak.migrating",			/* a schema migration is running (1047, 1048) */
};

#define N_GUARDED ((int) lengthof(guarded))

static char *values[N_GUARDED];

void		_PG_init(void);

void
_PG_init(void)
{
	for (int i = 0; i < N_GUARDED; i++)
		DefineCustomStringVariable(guarded[i],
								   "Masslak: set only by the platform's own functions (db/guard).",
								   NULL,
								   &values[i],
								   "",
								   PGC_SUSET,
								   GUC_NOT_IN_SAMPLE,
								   NULL, NULL, NULL);
}
