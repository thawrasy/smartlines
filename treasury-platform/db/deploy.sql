:setvar DbName BankFas
/* ============================================================================
   BankFas - database deployment (SQLCMD mode)

   Run it from the db folder. sqlcmd resolves the relative paths in the :r lines from the current
   directory, not from the folder of this script, so starting it elsewhere fails at the first :r line.
   The wrappers change to the db folder for you:
       Windows:  tools\deploy\deploy.ps1 -Server <server>               (Windows authentication)
       Linux:    SQL_SERVER=<server> SQL_USER=sa SQLCMDPASSWORD=... tools/deploy/deploy.sh
   Or by hand:  cd db  then  sqlcmd -S <server> -E -I -f 65001 -b -i deploy.sql

   Forward slashes in the :r paths work on Windows and Linux alike. -I sets QUOTED_IDENTIFIER ON, which
   the filtered indexes need. The whole script runs in one session, because the temporary table #rls_tables
   created by 004 is used by 010. Files under generated/tsql are produced from the model; do not edit them.
   ============================================================================ */
:on error exit
IF DB_ID(N'$(DbName)') IS NULL
    CREATE DATABASE [$(DbName)] COLLATE Arabic_100_CI_AS_SC;
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
:r static/050_fac_share_rule.sql
:r seed/100_platform_global.sql
:r seed/101_iso_reference.sql
:r seed/102_permissions.sql
:r seed/103_lc_reference.sql
