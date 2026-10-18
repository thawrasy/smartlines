/* ============================================================================
   BankFas - the database administrator's part of a deployment (DOC-S11 section 6.1, DQ-S11-1; DOC-S08 sections 3
   and 9; docs/adr/0010-deployment-as-db-owner.md)

   Run once per server, before the first db/deploy.sql, by an administrator who may create databases and logins.
   tools/deploy/prepare_database.sh fills the $(...) values in a private temporary copy and deletes it afterwards.
     - BankFas, empty, in the collation the Arabic search needs (Arabic_100_CI_AS_SC), with its files in the given
       folders when they are given, and RECURSIVE_TRIGGERS OFF. An existing database in another collation stops the
       run (50110).
     - bankfas_owner: the owner of the database (dbo), a login nobody uses. Its random password is made here and kept
       nowhere, and the login stays disabled, so no person is dbo.
     - bankfas_migrator: the deployment login, a member of db_owner in BankFas and of no server role. It is left
       disabled: the deployment window enables it and closes it again (prepare_database.sh open, close).
   deploy.sql then runs as bankfas_migrator: it finds the database, so it creates nothing at server level, and every
   schema, role and module it creates is owned by dbo (AUTHORIZATION dbo), never by the deployment login.
   Safe to run again: the migrator takes the new secret, the rest stays.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
DECLARE @data NVARCHAR(400) = N'$(BANKFAS_DATA_DIR)', @log NVARCHAR(400) = N'$(BANKFAS_LOG_DIR)', @sql NVARCHAR(MAX);
IF DB_ID(N'BankFas') IS NULL
BEGIN
    SET @sql = N'CREATE DATABASE [BankFas]'
             + CASE WHEN @data <> N'' AND @log <> N''
                    THEN N' ON PRIMARY (NAME = N''BankFas'', FILENAME = N''' + @data + N'/BankFas.mdf'')'
                       + N' LOG ON (NAME = N''BankFas_log'', FILENAME = N''' + @log + N'/BankFas_log.ldf'')'
                    ELSE N'' END
             + N' COLLATE Arabic_100_CI_AS_SC;';
    EXEC (@sql);
END
ELSE IF CAST(DATABASEPROPERTYEX(N'BankFas', 'Collation') AS NVARCHAR(128)) <> N'Arabic_100_CI_AS_SC'
    THROW 50110, 'BankFas exists in another collation; the Arabic search needs Arabic_100_CI_AS_SC', 1;
-- The copy triggers of 044 hold only while a trigger does not fire itself again (self-review A7; preflight 50145).
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'BankFas' AND is_recursive_triggers_on = 1)
    ALTER DATABASE [BankFas] SET RECURSIVE_TRIGGERS OFF;
GO
-- The owner: a login nobody can use.
IF SUSER_ID(N'bankfas_owner') IS NULL
BEGIN
    DECLARE @pw NVARCHAR(100) = CONCAT(CONVERT(NVARCHAR(64), CRYPT_GEN_RANDOM(32), 2), N'aZ9-'), @sql NVARCHAR(400);
    SET @sql = N'CREATE LOGIN [bankfas_owner] WITH PASSWORD = N''' + @pw + N''', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
    EXEC (@sql);
END;
ALTER LOGIN [bankfas_owner] DISABLE;
IF (SELECT SUSER_SNAME(owner_sid) FROM sys.databases WHERE name = N'BankFas') <> N'bankfas_owner'
    ALTER AUTHORIZATION ON DATABASE::[BankFas] TO [bankfas_owner];
GO
-- The deployment login, closed until a deployment window opens it.
IF SUSER_ID(N'bankfas_migrator') IS NULL
    CREATE LOGIN [bankfas_migrator] WITH PASSWORD = N'$(BANKFAS_MIGRATOR_PASSWORD)', DEFAULT_DATABASE = [BankFas], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [bankfas_migrator] WITH PASSWORD = N'$(BANKFAS_MIGRATOR_PASSWORD)';
ALTER LOGIN [bankfas_migrator] DISABLE;
IF EXISTS (SELECT 1 FROM sys.server_role_members AS m JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id
           WHERE p.name IN (N'bankfas_migrator', N'bankfas_owner'))
    THROW 50111, 'The deployment login and the owner login must not be members of a server role', 1;
GO
USE [BankFas];
GO
IF DATABASE_PRINCIPAL_ID(N'bankfas_migrator') IS NULL CREATE USER [bankfas_migrator] FOR LOGIN [bankfas_migrator];
IF IS_ROLEMEMBER(N'db_owner', N'bankfas_migrator') <> 1 ALTER ROLE [db_owner] ADD MEMBER [bankfas_migrator];
PRINT 'BankFas prepared: owner bankfas_owner (disabled), deployment login bankfas_migrator in db_owner (disabled until a window opens)';
GO
