/* ============================================================================
   BankFas - 090: the reporting role reads tables and the reporting views, never the internal functions
   (self-review A5, 2026-10-18; PRED-04 in 020)

   020 grants tp_readonly SELECT on every schema, so that reports read the tenant's tables under the row filters. That
   grant also reaches the inline functions the procedures use internally. Some of them read what the role is denied:
   sec.fn_TenantOpen and sec.fn_JobAllowed read the status of any tenant from plat.Tenant, and
   lc.BeneficiaryIbanChange compares the IBAN hashes of two terms versions. tp_support is a member of tp_readonly.

   This script runs after every script that creates a function and denies tp_readonly every function of the
   internal schemas (rls, sec, plat, cfg) and lc.BeneficiaryIbanChange. The row filters still work: a security
   predicate does not need the reader's permission on its function. The procedures that use these functions are not
   affected, since an ownership chain skips the check. The reporting views (plat.v_CurrentTenant, plat.v_TenantModule,
   org.v_CompanyTaxIdentity, wfl.RequestCopyDrift, lc.ProformaTotalsDrift) stay readable.
   A function added later to these schemas is denied the next time the script runs; RF35 checks the list.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += CASE WHEN o.type = 'FN' THEN N'DENY EXECUTE ON ' ELSE N'DENY SELECT ON ' END
             + QUOTENAME(SCHEMA_NAME(o.schema_id)) + N'.' + QUOTENAME(o.name) + N' TO [tp_readonly];' + NCHAR(10)
FROM sys.objects AS o
WHERE o.type IN ('IF', 'TF', 'FN')
  AND (SCHEMA_NAME(o.schema_id) IN (N'rls', N'sec', N'plat', N'cfg')
       OR (SCHEMA_NAME(o.schema_id) = N'lc' AND o.name = N'BeneficiaryIbanChange'))
ORDER BY SCHEMA_NAME(o.schema_id), o.name;
EXEC sys.sp_executesql @sql;
GO
