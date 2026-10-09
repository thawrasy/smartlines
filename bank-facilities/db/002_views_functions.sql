/* BFMS - 002: عروض ودوال التحقق والتسعير والتنبيهات */
SET NOCOUNT ON;
GO
USE BankFacilities;
GO

/* ---- (أ) مخالفات سلامة الحدود: يجب أن تكون النتيجة فارغة ---------------- */
CREATE OR ALTER VIEW fac.vw_LimitIntegrityViolations AS
-- مجموع الحدود الرئيسية يتجاوز مبلغ التسهيل
SELECT f.FacilityId, CAST(NULL AS INT) AS LimitId, 'MAIN_LIMITS_EXCEED_FACILITY' AS Rule_,
       f.TotalAmount AS AllowedAmount, SUM(l.Amount) AS ActualAmount
FROM fac.Facility f JOIN fac.Limit l ON l.FacilityId = f.FacilityId AND l.ParentLimitId IS NULL AND l.Status <> 'CLOSED'
WHERE f.Status NOT IN ('CANCELLED','RENEWED')
GROUP BY f.FacilityId, f.TotalAmount HAVING SUM(l.Amount) > f.TotalAmount
UNION ALL
-- مجموع الحدود الجزئية يتجاوز الحد الأب
SELECT p.FacilityId, p.LimitId, 'SUBLIMITS_EXCEED_PARENT', p.Amount, SUM(c.Amount)
FROM fac.Limit p JOIN fac.Limit c ON c.ParentLimitId = p.LimitId AND c.Status <> 'CLOSED'
GROUP BY p.FacilityId, p.LimitId, p.Amount HAVING SUM(c.Amount) > p.Amount
UNION ALL
-- مجموع توزيعات الشركات الحالية يتجاوز الحد
SELECT l.FacilityId, l.LimitId, 'ALLOCATIONS_EXCEED_LIMIT', l.Amount, SUM(a.AllocatedAmount)
FROM fac.Limit l JOIN fac.LimitCompanyAllocation a ON a.LimitId = l.LimitId
  AND a.EffectiveFrom <= CAST(SYSUTCDATETIME() AS DATE) AND (a.EffectiveTo IS NULL OR a.EffectiveTo >= CAST(SYSUTCDATETIME() AS DATE))
GROUP BY l.FacilityId, l.LimitId, l.Amount HAVING SUM(a.AllocatedAmount) > l.Amount
UNION ALL
-- تاريخ انتهاء الحد بعد تاريخ انتهاء التسهيل
SELECT l.FacilityId, l.LimitId, 'LIMIT_ENDS_AFTER_FACILITY', NULL, NULL
FROM fac.Limit l JOIN fac.Facility f ON f.FacilityId = l.FacilityId
WHERE l.EndDate IS NOT NULL AND l.EndDate > f.EndDate
UNION ALL
-- منتج مسموح في الحد غير مسموح لنوع الحد
SELECT l.FacilityId, l.LimitId, 'PRODUCT_NOT_ALLOWED_FOR_LIMIT_TYPE', NULL, NULL
FROM fac.LimitProduct lp JOIN fac.Limit l ON l.LimitId = lp.LimitId
WHERE EXISTS (SELECT 1 FROM cat.LimitTypeProduct x WHERE x.LimitTypeId = l.LimitTypeId)
  AND NOT EXISTS (SELECT 1 FROM cat.LimitTypeProduct x WHERE x.LimitTypeId = l.LimitTypeId AND x.ProductId = lp.ProductId);
GO

/* ---- (ب) الرصيد المتاح لكل حد وشركة (آخر قراءة استخدام) ----------------- */
CREATE OR ALTER VIEW fac.vw_LimitAvailability AS
WITH lastUtil AS (
    SELECT u.LimitId, u.CompanyId, u.AsOfDate, SUM(u.UtilizedAmount) AS Utilized,
           ROW_NUMBER() OVER (PARTITION BY u.LimitId, u.CompanyId ORDER BY u.AsOfDate DESC) AS rn
    FROM fac.Utilization u GROUP BY u.LimitId, u.CompanyId, u.AsOfDate
)
SELECT l.FacilityId, l.LimitId, l.LimitNo, l.Amount AS LimitAmount, l.CurrencyCode,
       a.CompanyId, a.AllocatedAmount, lu.AsOfDate, ISNULL(lu.Utilized,0) AS Utilized,
       COALESCE(a.AllocatedAmount, l.Amount) - ISNULL(lu.Utilized,0) AS AvailableForCompany
FROM fac.Limit l
JOIN fac.LimitCompanyAllocation a ON a.LimitId = l.LimitId
     AND a.EffectiveFrom <= CAST(SYSUTCDATETIME() AS DATE) AND (a.EffectiveTo IS NULL OR a.EffectiveTo >= CAST(SYSUTCDATETIME() AS DATE))
LEFT JOIN lastUtil lu ON lu.LimitId = l.LimitId AND lu.CompanyId = a.CompanyId AND lu.rn = 1;
GO

/* ---- (ج) تنبيهات الاستحقاق خلال 90 يومًا -------------------------------- */
CREATE OR ALTER VIEW fac.vw_ExpiryAlerts AS
SELECT 'FACILITY_EXPIRY' AS AlertType, f.FacilityId, CAST(NULL AS INT) AS RefId, f.InternalNo AS Ref, f.EndDate AS DueDate,
       DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), f.EndDate) AS DaysLeft
FROM fac.Facility f WHERE f.Status = 'ACTIVE' AND f.EndDate <= DATEADD(DAY, 90, CAST(SYSUTCDATETIME() AS DATE))
UNION ALL
SELECT 'COVENANT_TEST_DUE', c.FacilityId, t.TestId, c.Title, t.DueDate, DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), t.DueDate)
FROM cov.CovenantTest t JOIN cov.Covenant c ON c.CovenantId = t.CovenantId
WHERE t.Result = 'PENDING' AND c.Status = 'ACTIVE' AND t.DueDate <= DATEADD(DAY, 90, CAST(SYSUTCDATETIME() AS DATE))
UNION ALL
SELECT 'CONDITION_DUE', k.FacilityId, k.ConditionId, k.Title, k.DueDate, DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), k.DueDate)
FROM fac.Condition k WHERE k.Status = 'OPEN' AND k.DueDate IS NOT NULL AND k.DueDate <= DATEADD(DAY, 90, CAST(SYSUTCDATETIME() AS DATE))
UNION ALL
SELECT 'COLLATERAL_EXPIRY', fc.FacilityId, cl.CollateralId, ISNULL(cl.ReferenceNo, cl.Description), cl.ExpiryDate, DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), cl.ExpiryDate)
FROM col.Collateral cl JOIN col.FacilityCollateral fc ON fc.CollateralId = cl.CollateralId AND fc.ReleaseDate IS NULL
WHERE cl.Status = 'ACTIVE' AND cl.ExpiryDate IS NOT NULL AND cl.ExpiryDate <= DATEADD(DAY, 90, CAST(SYSUTCDATETIME() AS DATE));
GO

/* ---- (د) تحديد سعر السارية لتسهيل/حد/منتج/شركة --------------------------
   الأولوية: (1) أقرب حد (الحد نفسه ثم أبوه ما دام PricingMode='INHERIT' ثم التسهيل)
             (2) قاعدة خاصة بالشركة  (3) قاعدة خاصة بالمنتج  (4) الأحدث تاريخ سريان
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION pr.fn_ResolvePricing (
    @FacilityId INT, @LimitId INT, @ProductId INT, @CompanyId INT,
    @ComponentKind VARCHAR(9), @FeeTypeId INT, @FinancingTypeId INT, @AsOf DATE)
RETURNS TABLE
AS RETURN
WITH chain AS (
    SELECT l.LimitId, l.ParentLimitId, l.PricingMode, 0 AS Depth
    FROM fac.Limit l WHERE l.LimitId = @LimitId AND l.FacilityId = @FacilityId
    UNION ALL
    SELECT p.LimitId, p.ParentLimitId, p.PricingMode, c.Depth + 1
    FROM chain c JOIN fac.Limit p ON p.LimitId = c.ParentLimitId
    WHERE c.PricingMode = 'INHERIT'
)
SELECT TOP (1) r.PricingRuleId, r.CalcMethod, r.BaseRateId, r.Tenor, r.MarginPct, r.RatePct, r.FixedAmount,
       r.MinAmount, r.MaxAmount, r.FloorRatePct, r.CapRatePct, r.Frequency, r.DayCount,
       r.LimitId AS SourceLimitId, r.ProductId AS SourceProductId, r.CompanyId AS SourceCompanyId
FROM pr.PricingRule r
LEFT JOIN chain c ON c.LimitId = r.LimitId
WHERE r.FacilityId = @FacilityId
  AND r.ComponentKind = @ComponentKind
  AND ((@ComponentKind = 'FEE' AND r.FeeTypeId = @FeeTypeId) OR (@ComponentKind = 'FINANCING' AND r.FinancingTypeId = @FinancingTypeId))
  AND (r.LimitId IS NULL OR c.LimitId IS NOT NULL)
  AND (r.ProductId IS NULL OR r.ProductId = @ProductId)
  AND (r.CompanyId IS NULL OR r.CompanyId = @CompanyId)
  AND r.EffectiveFrom <= @AsOf AND (r.EffectiveTo IS NULL OR r.EffectiveTo >= @AsOf)
ORDER BY ISNULL(c.Depth, 999) ASC,
         CASE WHEN r.CompanyId IS NOT NULL THEN 0 ELSE 1 END ASC,
         CASE WHEN r.ProductId IS NOT NULL THEN 0 ELSE 1 END ASC,
         r.EffectiveFrom DESC;
GO

/* ---- (هـ) السعر الفعلي لقاعدة BASE_PLUS_MARGIN في تاريخ معين ----------- */
CREATE OR ALTER FUNCTION pr.fn_AllInRate (@PricingRuleId INT, @AsOf DATE)
RETURNS DECIMAL(9,6)
AS BEGIN
    DECLARE @rate DECIMAL(9,6);
    SELECT @rate =
        CASE WHEN r.CalcMethod = 'BASE_PLUS_MARGIN' THEN
             (SELECT TOP (1) v.RatePct FROM ref.BaseRateValue v
               WHERE v.BaseRateId = r.BaseRateId AND v.Tenor = ISNULL(r.Tenor, v.Tenor) AND v.EffectiveDate <= @AsOf
               ORDER BY v.EffectiveDate DESC) + r.MarginPct
             ELSE r.RatePct END
    FROM pr.PricingRule r WHERE r.PricingRuleId = @PricingRuleId;
    RETURN (SELECT CASE WHEN @rate < r.FloorRatePct THEN r.FloorRatePct
                        WHEN @rate > r.CapRatePct   THEN r.CapRatePct ELSE @rate END
            FROM pr.PricingRule r WHERE r.PricingRuleId = @PricingRuleId);
END;
GO

/* ---- (و) حصص المقرضين: يوحّد التسهيل الثنائي والمشترك في شكل واحد -------- */
CREATE OR ALTER VIEW fac.vw_FacilityLenderShare AS
SELECT f.FacilityId, f.InstitutionId, CAST('SOLE' AS VARCHAR(12)) AS LenderRole,
       CAST(100 AS DECIMAL(9,6)) AS ParticipationPct, f.TotalAmount AS CommitmentAmount, f.CurrencyCode
FROM fac.Facility f WHERE f.IsSyndicated = 0
UNION ALL
SELECT f.FacilityId, l.InstitutionId, l.LenderRole, l.ParticipationPct,
       CAST(ROUND(f.TotalAmount * l.ParticipationPct / 100, 4) AS DECIMAL(19,4)), f.CurrencyCode
FROM fac.Facility f JOIN fac.FacilityLender l ON l.FacilityId = f.FacilityId
WHERE f.IsSyndicated = 1;
GO

/* ---- (ز) مخالفات التمويل المشترك: يجب أن يكون فارغًا قبل الاعتماد -------- */
CREATE OR ALTER VIEW fac.vw_SyndicationViolations AS
-- مجموع النسب لا يساوي 100%
SELECT f.FacilityId, 'SHARES_NOT_100' AS Rule_, CAST(SUM(l.ParticipationPct) AS DECIMAL(19,6)) AS Actual
FROM fac.Facility f LEFT JOIN fac.FacilityLender l ON l.FacilityId = f.FacilityId
WHERE f.IsSyndicated = 1
GROUP BY f.FacilityId HAVING ISNULL(SUM(l.ParticipationPct), 0) <> 100
UNION ALL
-- الجهة الرئيسية في التسهيل ليست ضمن المشاركين
SELECT f.FacilityId, 'LEAD_NOT_A_LENDER', NULL
FROM fac.Facility f
WHERE f.IsSyndicated = 1
  AND NOT EXISTS (SELECT 1 FROM fac.FacilityLender l WHERE l.FacilityId = f.FacilityId AND l.InstitutionId = f.InstitutionId)
UNION ALL
-- تسهيل غير مشترك لكن له صفوف مشاركين
SELECT f.FacilityId, 'LENDERS_ON_NON_SYNDICATED', CAST(COUNT(*) AS DECIMAL(19,6))
FROM fac.Facility f JOIN fac.FacilityLender l ON l.FacilityId = f.FacilityId
WHERE f.IsSyndicated = 0 GROUP BY f.FacilityId;
GO

/* ---- (ح) حالة التعهدات المسجلة: مقارنة النسبة المدخلة بالحد المطلوب ------ */
-- المرحلة 1: تُسجَّل النسب يدويًا ويُحسب الالتزام هنا. لاحقًا تُغذَّى النسب من القوائم المالية.
CREATE OR ALTER VIEW cov.vw_CovenantStatus AS
SELECT t.TestId, c.CovenantId, c.FacilityId, c.LimitId, c.TestedCompanyId, c.Title, c.MetricCode,
       t.PeriodEndDate, t.DueDate, t.SubmittedDate, t.ActualValue, c.Operator, c.ThresholdValue, t.Result AS RecordedResult,
       CASE WHEN t.ActualValue IS NULL OR c.Operator IS NULL THEN NULL
            WHEN (c.Operator = '>=' AND t.ActualValue >= c.ThresholdValue)
              OR (c.Operator = '<=' AND t.ActualValue <= c.ThresholdValue)
              OR (c.Operator = '>'  AND t.ActualValue >  c.ThresholdValue)
              OR (c.Operator = '<'  AND t.ActualValue <  c.ThresholdValue)
              OR (c.Operator = '='  AND t.ActualValue =  c.ThresholdValue) THEN 1 ELSE 0 END AS IsCompliant,
       CASE WHEN t.SubmittedDate IS NULL AND DATEADD(DAY, c.GracePeriodDays, t.DueDate) < CAST(SYSUTCDATETIME() AS DATE)
            THEN 1 ELSE 0 END AS IsOverdue
FROM cov.CovenantTest t JOIN cov.Covenant c ON c.CovenantId = t.CovenantId
WHERE c.Status = 'ACTIVE';
GO

-- تقرير الخروقات: قيمة مخالفة لم يُتنازل عنها، أو تقديم متأخر
CREATE OR ALTER VIEW cov.vw_CovenantBreaches AS
SELECT s.*, CASE WHEN s.IsCompliant = 0 THEN 'RATIO_BREACH' ELSE 'SUBMISSION_OVERDUE' END AS BreachKind
FROM cov.vw_CovenantStatus s
WHERE s.RecordedResult <> 'WAIVED' AND (s.IsCompliant = 0 OR s.IsOverdue = 1);
GO
