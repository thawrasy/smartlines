# db/migrations

Versioned schema changes for a database that is already deployed (tools/deploy/migrate.sh, ADR 0034, DOC-B11 section 6).

- One file per change: `Vnnnn__description.sql`. Numbers rise and are never reused. Any other file name is refused.
- A script carries what the repeatable scripts cannot: tables, columns, keys, indexes, and data that must move with
  them. Procedures, functions, views, triggers, row filters and grants belong to the repeatable scripts (db/static and
  generated/tsql 004 to 007). migrate.sh runs those again after the versioned scripts.
- The same change goes into the model (db/model), so a database built fresh by db/deploy.sql has the same fingerprint
  as one brought up by the scripts.
- A script runs inside the transaction migrate.sh opens for it: it neither commits nor opens another one.
- An applied script is never edited. A correction is a new script.

After release 1.0.7: V0001 the company number of a request (wfl.RequestCompanyNumber); V0002 the facility file of a company with a bank and the company code of a facility reference up to six characters.; V0003 the agreed rates and the volumes of the products of a bank relationship, and four more product families. A database deployed with 1.0.7 reaches the current schema with `migrate.sh apply`.
