:setvar DbName BankFas
/* ============================================================================
   BankFas - database deployment (SQLCMD mode)

   Run it from the db folder. sqlcmd resolves the relative paths in the :r lines from the current
   directory, not from the folder of this script, so starting it elsewhere fails at the first :r line.
   The wrappers change to the db folder for you:
       Windows:  tools\deploy\deploy.ps1 -Server <server>               (Windows authentication; not the production path)
       Linux:    tools/deploy/prepare_database.sh open, then SQL_SERVER=<server> SQL_USER=bankfas_migrator
                 tools/deploy/deploy.sh with SQLCMDPASSWORD read from the secret file, then prepare_database.sh close
                 (DOC-S11 section 5, ADR 0010). Never put the password on the command line.
   It needs db_owner in an existing BankFas only: an administrator creates the database first (prepare_database.sh).
   It does not run by hand: the wrappers run db/ops/deploy_preflight.sql and this script in one session, and the
   first batch below stops (50146) unless the preflight passed in that session (gate G4, ADR 0014; self-review E5).

   Forward slashes in the :r paths work on Windows and Linux alike. -I sets QUOTED_IDENTIFIER ON, which
   the filtered indexes need. The whole script runs in one session, because the temporary table #rls_tables
   created by 004 is used by 010. Files under generated/tsql are produced from the model; do not edit them.
   ============================================================================ */
:on error exit
IF SESSION_CONTEXT(N'bankfas.preflight') IS NULL
    THROW 50146, 'db/deploy.sql runs through tools/deploy/deploy.sh, after the deployment preflight in the same session (gate G4, ADR 0014)', 1;
IF DB_ID(N'$(DbName)') IS NULL
    THROW 50141, 'BankFas must exist in the collation Arabic_100_CI_AS_SC: an administrator prepares it with tools/deploy/prepare_database.sh prepare', 1;
GO
USE [$(DbName)];
GO
:r generated/tsql/000_schemas.sql
:r generated/tsql/001_tables.sql
:r generated/tsql/002_foreign_keys.sql
:r generated/tsql/003_indexes.sql
:r generated/tsql/004_rls_tables.sql
:r static/020_roles_and_grants.sql
:r generated/tsql/005_delete_grants.sql
:r generated/tsql/006_sensitive_columns.sql
:r generated/tsql/007_table_grants.sql
:r static/010_rls.sql
:r static/025_tenant_views.sql
:r static/028_tenant_settings.sql
:r static/029_audit_writer.sql
:r static/030_session_context.sql
:r static/035_account_security.sql
:r static/036_operator_and_support.sql
:r static/037_job_context.sql
:r static/038_tenant_onboarding.sql
:r static/039_numbering.sql
:r static/041_kyc_profile_versions.sql
:r static/042_data_export.sql
:r static/043_review_guards.sql
:r static/044_entry_guards.sql
:r static/045_financial_statements.sql
:r static/046_credit_assessment.sql
:r static/047_credit_engine.sql
:r static/048_presentation_versions.sql
:r static/049_credit_readiness.sql
:r static/050_fac_share_rule.sql
:r static/051_early_warning_job.sql
:r static/090_readonly_denies.sql
:r seed/100_platform_global.sql
:r seed/101_iso_reference.sql
:r seed/102_permissions.sql
:r seed/103_lc_reference.sql
:r seed/104_credit_scorecard.sql
