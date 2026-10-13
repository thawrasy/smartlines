/* ============================================================================
   Fixes of the design-review findings approved by the owner on 2026-10-13 (O-15, docs/32-review-findings-decisions.md,
   docs/adr/0011-design-review-fixes.md).
   RF1  a list column (set{}) takes only distinct allowed values, in capitals, with no empty item or space (DR-32)

   Run against a deployed BankFas database that holds no real data, with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/review_fixes_tests.sql
   Every case rolls back what it writes. Each prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
GO
/* RF1: ref.Country.WeekendDays and cfg.JobDefinition.RunsInStatuses (global lists, written here as dbo) */
DECLARE @bad TABLE (v VARCHAR(40));
INSERT @bad VALUES ('XYZ'), ('FRI,FRI'), ('fri,sat'), (''), ('FRI, SAT'), ('FRI,SAT,'), (',FRI');
DECLARE @v VARCHAR(40), @refused INT = 0, @tried INT = 0, @good INT = 0, @job INT = 0;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT v FROM @bad;
OPEN c; FETCH NEXT FROM c INTO @v;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @tried += 1;
    BEGIN TRANSACTION;
    BEGIN TRY UPDATE ref.Country SET WeekendDays = @v WHERE Iso2 = 'SA'; END TRY
    BEGIN CATCH IF ERROR_NUMBER() = 547 SET @refused += 1; END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    FETCH NEXT FROM c INTO @v;
END;
CLOSE c; DEALLOCATE c;
BEGIN TRANSACTION;
BEGIN TRY UPDATE ref.Country SET WeekendDays = 'SAT,FRI' WHERE Iso2 = 'SA'; SET @good = @@ROWCOUNT; END TRY BEGIN CATCH SET @good = -1; END CATCH;
BEGIN TRY UPDATE cfg.JobDefinition SET RunsInStatuses = 'TRIAL,ACTIVE,TRIAL' WHERE JobKey = 'JOB-PLT-ONBOARD'; END TRY
BEGIN CATCH SET @job = ERROR_NUMBER(); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
IF @refused = @tried AND @good = 1 AND @job = 547
    PRINT CONCAT('PASS RF1: a list column refuses ', @tried, ' malformed values (unknown, repeated, lower case, empty, spaced) and takes distinct allowed ones in any order');
ELSE PRINT CONCAT('FAIL RF1: refused ', @refused, ' of ', @tried, ', valid list ', @good, ', repeated job status ', @job);
GO
