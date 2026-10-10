:setvar DbName BankFas
/* ============================================================================
   BankFas - نشر قاعدة البيانات (وضع SQLCMD):  sqlcmd -S <server> -E -I -f 65001 -i db\deploy.sql -v DbName=BankFas   (الخيار -I = QUOTED_IDENTIFIER ON؛ مطلوب للفهارس المصفّاة)
   الترتيب ثابت؛ كله في جلسة واحدة (الجدول المؤقت #rls_tables يُستهلك في 010).
   الملفات في generated\tsql مولَّدة من النموذج: لا تُعدَّل يدويًا.
   ============================================================================ */
:on error exit
IF DB_ID(N'$(DbName)') IS NULL
    CREATE DATABASE [$(DbName)] COLLATE Arabic_100_CI_AS_SC;
GO
USE [$(DbName)];
GO
:r generated\tsql\000_schemas.sql
:r generated\tsql\001_tables.sql
:r generated\tsql\002_foreign_keys.sql
:r generated\tsql\003_indexes.sql
:r generated\tsql\004_rls_tables.sql
:r static\020_roles_and_grants.sql
:r generated\tsql\005_delete_grants.sql
:r generated\tsql\006_sensitive_columns.sql
:r static\010_rls.sql
:r static\030_session_context.sql
