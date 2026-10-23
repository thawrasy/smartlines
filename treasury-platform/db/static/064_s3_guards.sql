/* 064_s3_guards.sql — what S3's reservations keep is kept in the database, not only in the application (S3 brief
   S3-GAP-14; BR-FAC-015, M13 §8).

     reservations  a CONVERTED or RELEASED fac.LimitReservation is final: its amount, its status and its links do not
                   change. A conversion names the utilisation that took its place (fac.convert_reservation) and a
                   release names its date and reason; a reservation released by mistake is not reopened, the request
                   reserves again under a new key. Only UpdatedAt and UpdatedBy may be touched, so that the request
                   copy trigger of 044, which reads the row, is unaffected. The trigger is built from sys.columns, so a
                   column added later is frozen too. Error 50177.

   The amendment checks of DQ-F16-7 (REJECTED with the beneficiary's rejection, WITHDRAWN while the response is
   pending) are checks of lc.LcAmendment in the model (16-*.model). */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
DECLARE @ci NVARCHAR(MAX), @cd NVARCHAR(MAX), @sql NVARCHAR(MAX);
SELECT @ci = STRING_AGG(N'i.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id),
       @cd = STRING_AGG(N'd.' + QUOTENAME(name), N', ') WITHIN GROUP (ORDER BY column_id)
  FROM sys.columns
 WHERE object_id = OBJECT_ID(N'fac.LimitReservation') AND is_computed = 0 AND system_type_id <> 189   -- not the row version
   AND name NOT IN (N'UpdatedAt', N'UpdatedBy');
SET @sql = N'CREATE OR ALTER TRIGGER fac.TR_LimitReservation_Final ON fac.LimitReservation
AFTER UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted AS d
               JOIN inserted AS i ON i.TenantId = d.TenantId AND i.LimitReservationId = d.LimitReservationId
               WHERE d.Status IN (''CONVERTED'', ''RELEASED'')
                 AND EXISTS (SELECT ' + @ci + N' EXCEPT SELECT ' + @cd + N'))
        THROW 50177, ''A converted or released reservation is final: the request reserves again under a new key (BR-FAC-015)'', 1;
END;';
EXEC sys.sp_executesql @sql;
GO
