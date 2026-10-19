/* ============================================================================
   BankFas - 047: the credit assessment engine, version 2 (owner requests of 2026-10-18 and 2026-10-19;
   docs/35-credit-assessment-methodology.md, ADR 0017 and ADR 0018, spec 12 FR-FIN-020 to FR-FIN-030)

   The computation in three layers, each the T-SQL twin of a function of tools/dbgen/credit_reference.py, so the tests
   expect the numbers the reference gives for the same fixtures:
     fin.usp_CreditCore        one evaluation of a statement: the analytical statement and its reconciliation, the
                               named quantities, every metric by its pattern or rule, the factors, the item levels, the
                               data completeness, the adjustments, the grades, the liquidity label and the facility
                               grade. It reads and writes temporary tables its caller creates (below), and nothing else
                               but the methodology tables.
     fin.usp_CreditEvaluate    the core on the statement, then on the two scenarios of the company's activity (the
                               resilience overlay), then on the pro-forma statement of each remedy the findings call for.
     fin.usp_ComputeCreditAssessment (end of this script) reads a draft assessment from the tables: its statement and
                               comparison statement, its inputs, guarantors and bureau report, the company's product lines
                               and activity, and the platform's facilities and collateral on the assessment date; it
                               runs the evaluation and writes the results, findings and snapshot.

   The temporary tables (created by the caller, as in fin.usp_ComputeCreditAssessment and the tests):
     #crX     one row: the context of the evaluation (scorecard, period types, rate, assurance, opinion, flags, the
              breach, the platform aggregates, the bureau report, the guarantors, the qualitative scores, the product
              measures, support and override)
     #crL     the lines of the statement (Code, Amount in the statement currency, as entered)
     #crP     the lines of the comparison statement
     #crColl  the collateral covering the facilities (Kind, Cover in the statement currency)
   and, written by the core: #crQ quantities, #crM metrics, #crF factors, #crI item levels, #crA adjustments that
   apply, #crR reconciliation rows, #crD the disclosures asked for and given, #crS the summary.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
/* The score of a value on a grid of nine boundaries, best cap first (docs/35 section 3): 0.5 at the best cap or
   beyond, 20.5 at the worst cap or beyond, linear between two boundaries, whose scores are 0.5, 1.5, 4.5, 7.5,
   10.5, 13.5, 16.5, 19.5 and 20.5. The grid's order gives the direction. */
CREATE OR ALTER FUNCTION fin.fn_CreditGridScore (@v FLOAT, @b0 FLOAT, @b1 FLOAT, @b2 FLOAT, @b3 FLOAT, @b4 FLOAT, @b5 FLOAT, @b6 FLOAT, @b7 FLOAT, @b8 FLOAT)
RETURNS TABLE
AS RETURN
SELECT CAST(ROUND(CASE
         WHEN @v IS NULL OR @b0 IS NULL OR @b8 IS NULL THEN NULL
         WHEN @b0 < @b8 THEN
              CASE WHEN @v <= @b0 THEN 0.5 WHEN @v >= @b8 THEN 20.5
                   WHEN @v < @b1 THEN 0.5  + (@v - @b0) / (@b1 - @b0) * 1
                   WHEN @v < @b2 THEN 1.5  + (@v - @b1) / (@b2 - @b1) * 3
                   WHEN @v < @b3 THEN 4.5  + (@v - @b2) / (@b3 - @b2) * 3
                   WHEN @v < @b4 THEN 7.5  + (@v - @b3) / (@b4 - @b3) * 3
                   WHEN @v < @b5 THEN 10.5 + (@v - @b4) / (@b5 - @b4) * 3
                   WHEN @v < @b6 THEN 13.5 + (@v - @b5) / (@b6 - @b5) * 3
                   WHEN @v < @b7 THEN 16.5 + (@v - @b6) / (@b7 - @b6) * 3
                   ELSE               19.5 + (@v - @b7) / (@b8 - @b7) * 1 END
         ELSE CASE WHEN @v >= @b0 THEN 0.5 WHEN @v <= @b8 THEN 20.5
                   WHEN @v > @b1 THEN 0.5  + (@b0 - @v) / (@b0 - @b1) * 1
                   WHEN @v > @b2 THEN 1.5  + (@b1 - @v) / (@b1 - @b2) * 3
                   WHEN @v > @b3 THEN 4.5  + (@b2 - @v) / (@b2 - @b3) * 3
                   WHEN @v > @b4 THEN 7.5  + (@b3 - @v) / (@b3 - @b4) * 3
                   WHEN @v > @b5 THEN 10.5 + (@b4 - @v) / (@b4 - @b5) * 3
                   WHEN @v > @b6 THEN 13.5 + (@b5 - @v) / (@b5 - @b6) * 3
                   WHEN @v > @b7 THEN 16.5 + (@b6 - @v) / (@b6 - @b7) * 3
                   ELSE               19.5 + (@b7 - @v) / (@b7 - @b8) * 1 END
       END, 4) AS DECIMAL(9,4)) AS Score;
GO
/* The risk level of a value under the four thresholds of an item rule; a value on a threshold belongs to the worse
   level (docs/35 section 6). */
CREATE OR ALTER FUNCTION fin.fn_CreditItemLevel (@v FLOAT, @t1 FLOAT, @t2 FLOAT, @t3 FLOAT, @t4 FLOAT)
RETURNS TABLE
AS RETURN
SELECT CAST(CASE
         WHEN @v IS NULL THEN NULL
         WHEN @t1 < @t4 THEN CASE WHEN @v < @t1 THEN 'LOW' WHEN @v < @t2 THEN 'MODERATE' WHEN @v < @t3 THEN 'ELEVATED' WHEN @v < @t4 THEN 'HIGH' ELSE 'CRITICAL' END
         ELSE CASE WHEN @v > @t1 THEN 'LOW' WHEN @v > @t2 THEN 'MODERATE' WHEN @v > @t3 THEN 'ELEVATED' WHEN @v > @t4 THEN 'HIGH' ELSE 'CRITICAL' END
       END AS VARCHAR(8)) AS RiskLevel;
GO
CREATE OR ALTER PROCEDURE fin.usp_CreditCore
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @card INT, @pt VARCHAR(10), @ppt VARCHAR(10), @hasPrior BIT, @fx FLOAT, @assurance VARCHAR(10), @opinion VARCHAR(11), @goingConcern BIT,
            @holdco BIT, @breach VARCHAR(16), @breachAtPe BIT, @flowShortfall BIT, @ageMonths INT, @restatedPct FLOAT, @industry INT, @marketSize FLOAT,
            @rollFactor FLOAT, @resilienceNotch BIT, @proforma BIT, @evSub BIT, @evCap BIT,
            @pfLimits FLOAT, @pfOut FLOAT, @pfUndrawn FLOAT, @pfLargest FLOAT, @pfExpiring FLOAT, @pfLenders INT,
            @bu BIT, @buOut FLOAT, @buLimits FLOAT, @buLenders INT, @buDpd12 INT, @buDefault BIT, @buDefaults24 INT, @buBouncedN INT, @buBouncedAmt FLOAT,
            @buJudg FLOAT, @buRestructured BIT, @buInquiries INT, @buMonthsAfterPe INT,
            @qualBp FLOAT, @qualFp FLOAT, @docBp BIT, @docFp BIT, @prodCfq FLOAT, @prodConc FLOAT, @invCrisis FLOAT, @invDays FLOAT,
            @support INT, @parentNotch INT, @override INT, @guLiquid FLOAT, @guNetWorth FLOAT, @guGiven FLOAT, @guGuaranteed FLOAT, @guMaxLev FLOAT;
    SELECT @card = ScorecardId, @pt = PeriodType, @ppt = PriorPeriodType, @hasPrior = HasPrior, @fx = Fx, @assurance = Assurance, @opinion = Opinion,
           @goingConcern = GoingConcern, @holdco = HoldingStandalone, @breach = Breach, @breachAtPe = BreachAtPeriodEnd, @flowShortfall = FlowShortfall,
           @ageMonths = StatementAgeMonths, @restatedPct = RestatedPct, @industry = IndustryId, @marketSize = MarketSize, @rollFactor = RolloverFactor,
           @resilienceNotch = ResilienceNotch, @proforma = Proforma, @evSub = EvSub, @evCap = EvCap,
           @pfLimits = PfLimits, @pfOut = PfOutstanding, @pfUndrawn = PfCommittedUndrawn, @pfLargest = PfLargestLenderShare,
           @pfExpiring = PfExpiring12mShare, @pfLenders = PfLenders,
           @bu = BuPresent, @buOut = BuOutstanding, @buLimits = BuLimits, @buLenders = BuLenders, @buDpd12 = BuDpd12m, @buDefault = BuCurrentDefault,
           @buDefaults24 = BuDefaults24m, @buBouncedN = BuBouncedCount, @buBouncedAmt = BuBouncedAmount, @buJudg = BuJudgments,
           @buRestructured = BuRestructured, @buInquiries = BuInquiries6m, @buMonthsAfterPe = BuMonthsAfterPeriodEnd,
           @qualBp = QualBp, @qualFp = QualFp, @docBp = DocBp, @docFp = DocFp, @prodCfq = ProdCashFlowQuality, @prodConc = ProdConcentration,
           @invCrisis = InvCrisisValue, @invDays = InvDaysStagnant,
           @support = Support, @parentNotch = ParentNotch, @override = Override,
           @guLiquid = GuLiquid, @guNetWorth = GuNetWorth, @guGiven = GuGiven, @guGuaranteed = GuGuaranteed, @guMaxLev = GuMaxLeverage
    FROM #crX;
    DELETE #crQ; DELETE #crM; DELETE #crF; DELETE #crI; DELETE #crA; DELETE #crR; DELETE #crD; DELETE #crS;

    -- The card's parameters (docs/35 section 5).
    DECLARE @unit FLOAT, @minCov FLOAT, @qualBound INT, @cardCode VARCHAR(40);
    SELECT @unit = AmountUnit, @minCov = MinCoveragePct, @qualBound = QualitativeBoundNotches, @cardCode = Code FROM fin.Scorecard WHERE ScorecardId = @card;
    DECLARE @prm TABLE (GroupCode VARCHAR(20) COLLATE DATABASE_DEFAULT, ParamKey VARCHAR(40) COLLATE DATABASE_DEFAULT, Value FLOAT, Value2 FLOAT, PRIMARY KEY (GroupCode, ParamKey));
    INSERT @prm SELECT GroupCode, ParamKey, Value, Value2 FROM fin.ScorecardParameter WHERE ScorecardId = @card;
    DECLARE @eosbPct FLOAT, @maintCapex FLOAT, @invSlowHaircut FLOAT, @arFallbackDso FLOAT, @stiLiq FLOAT, @partnersLiq FLOAT, @rollPct FLOAT, @rollMaxExp FLOAT,
            @urPct FLOAT, @urFloor FLOAT, @rateShock FLOAT, @govExtra FLOAT, @retExtra FLOAT, @notchFloor INT, @hiddenPct FLOAT,
            @sgl1 FLOAT, @sgl2 FLOAT, @sgl3 FLOAT, @severe FLOAT, @staffFixed FLOAT, @sellFixed FLOAT, @gaStaff FLOAT, @fbFixed FLOAT,
            @lgdMaxUp INT, @lgdMaxUpNear INT, @lgdBestNotch INT;
    SELECT @eosbPct = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'eosb_debt_pct' THEN Value END),
           @maintCapex = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'maint_capex_factor' THEN Value END),
           @invSlowHaircut = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'inv_slow_haircut' THEN Value END),
           @arFallbackDso = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'ar_fallback_dso_days' THEN Value END),
           @stiLiq = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'sti_liquidity_pct' THEN Value END),
           @partnersLiq = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'partners_liquidity_pct' THEN Value END),
           @rollPct = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'rollover_pct' THEN Value END),
           @rollMaxExp = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'rollover_max_expiring_pct' THEN Value END),
           @urPct = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'unsecured_recovery_pct' THEN Value END),
           @urFloor = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'unsecured_recovery_floor_pct' THEN Value END),
           @rateShock = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'rate_shock_pct' THEN Value END),
           @govExtra = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'gov_over365_extra_haircut' THEN Value END),
           @retExtra = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'retentions_overdue_extra_haircut' THEN Value END),
           @notchFloor = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'NOTCH_FLOOR' THEN Value END),
           @hiddenPct = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'HIDDEN_DEBT_PCT' THEN Value END),
           @lgdMaxUp = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'LGD_MAX_UP' THEN Value END),
           @lgdMaxUpNear = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'LGD_MAX_UP_NEAR_DEFAULT' THEN Value END),
           @lgdBestNotch = MAX(CASE WHEN GroupCode = 'CARD' AND ParamKey = 'LGD_BEST_FACILITY_NOTCH' THEN Value END),
           @sgl1 = MAX(CASE WHEN GroupCode = 'SGL' AND ParamKey = 'SGL1' THEN Value END), @sgl2 = MAX(CASE WHEN GroupCode = 'SGL' AND ParamKey = 'SGL2' THEN Value END),
           @sgl3 = MAX(CASE WHEN GroupCode = 'SGL' AND ParamKey = 'SGL3' THEN Value END), @severe = MAX(CASE WHEN GroupCode = 'SGL' AND ParamKey = 'SEVERE' THEN Value END),
           @staffFixed = MAX(CASE WHEN GroupCode = 'FIXED_COST' AND ParamKey = 'staff_fixed_pct' THEN Value END),
           @sellFixed = MAX(CASE WHEN GroupCode = 'FIXED_COST' AND ParamKey = 'selling_fixed_pct' THEN Value END),
           @gaStaff = MAX(CASE WHEN GroupCode = 'FIXED_COST' AND ParamKey = 'ga_staff_share_pct' THEN Value END),
           @fbFixed = MAX(CASE WHEN GroupCode = 'FIXED_COST' AND ParamKey = 'fallback_opex_fixed_pct' THEN Value END)
    FROM @prm;
    DECLARE @H TABLE (Bucket VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Keep FLOAT);   -- 1 - haircut
    INSERT @H SELECT ParamKey, 1 - Value / 100 FROM @prm WHERE GroupCode = 'REALISABLE_HAIRCUT';

    -- The lines: a LINE absent is zero, a TOTAL absent unknown, a breakdown or disclosure absent unknown, an OF_WHICH
    -- above its parent (by more than one unit) unknown; flows are annualised (docs/35 section 4).
    DECLARE @k FLOAT = 12.0 / CASE @pt WHEN 'ANNUAL' THEN 12 WHEN 'SEMIANNUAL' THEN 6 WHEN 'QUARTERLY' THEN 3 ELSE 1 END,
            @pk FLOAT = 12.0 / CASE @ppt WHEN 'ANNUAL' THEN 12 WHEN 'SEMIANNUAL' THEN 6 WHEN 'QUARTERLY' THEN 3 ELSE 1 END;
    DECLARE @raw TABLE (Which CHAR(1) NOT NULL, Code VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, Amount FLOAT NULL, PRIMARY KEY (Which, Code));
    INSERT @raw SELECT 'C', Code, Amount FROM #crL WHERE Amount IS NOT NULL;
    INSERT @raw SELECT 'P', Code, Amount FROM #crP WHERE Amount IS NOT NULL AND @hasPrior = 1;
    DECLARE @V TABLE (Which CHAR(1) NOT NULL, Code VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, V FLOAT NULL, Inconsistent BIT NOT NULL, PRIMARY KEY (Which, Code));
    INSERT @V (Which, Code, V, Inconsistent)
    SELECT w.Which, sl.Code,
           CASE WHEN r.Amount IS NULL THEN CASE WHEN sl.LineKind = 'LINE' THEN 0.0 END
                WHEN sl.LineKind = 'OF_WHICH' AND par.Amount IS NOT NULL AND r.Amount > par.Amount + 1 THEN NULL
                ELSE r.Amount * CASE WHEN sl.Section IN ('IS','CF') THEN CASE w.Which WHEN 'C' THEN @k ELSE @pk END ELSE 1 END END,
           CASE WHEN r.Amount IS NOT NULL AND sl.LineKind = 'OF_WHICH' AND par.Amount IS NOT NULL AND r.Amount > par.Amount + 1 THEN 1 ELSE 0 END
    FROM fin.StandardLine AS sl
    CROSS JOIN (VALUES ('C'), ('P')) AS w (Which)
    LEFT JOIN @raw AS r ON r.Which = w.Which AND r.Code = sl.Code
    OUTER APPLY (SELECT CASE WHEN sl.ParentCode = 'AR_GROSS' AND NOT EXISTS (SELECT 1 FROM @raw AS g WHERE g.Which = w.Which AND g.Code = 'AR_GROSS')
                             THEN (SELECT a.Amount FROM @raw AS a WHERE a.Which = w.Which AND a.Code = 'AR')
                                  + ISNULL((SELECT e.Amount FROM @raw AS e WHERE e.Which = w.Which AND e.Code = 'AR_ECL_ALLOWANCE'), 0)
                             ELSE (SELECT pr.Amount FROM @raw AS pr WHERE pr.Which = w.Which AND pr.Code = sl.ParentCode) END AS Amount) AS par
    WHERE w.Which = 'C' OR @hasPrior = 1;
    -- a TOTAL absent is the sum of its components, as the statement module computes it
    DECLARE @totOrd TABLE (n INT PRIMARY KEY, Code VARCHAR(40) COLLATE DATABASE_DEFAULT);
    INSERT @totOrd VALUES (1, 'TOTAL_CA'), (2, 'TOTAL_ASSETS'), (3, 'TOTAL_CL'), (4, 'TOTAL_LIABS'), (5, 'TOTAL_EQUITY'), (6, 'GROSS_PROFIT'),
                       (7, 'OPERATING_PROFIT'), (8, 'EBITDA'), (9, 'NET_PROFIT');
    DECLARE @totN INT = 1, @totC VARCHAR(40);
    WHILE @totN <= 9
    BEGIN
        SELECT @totC = Code FROM @totOrd WHERE n = @totN;
        UPDATE v SET V = ISNULL((SELECT SUM(c.Sign * ISNULL(x.V, 0)) FROM fin.StandardLineTotal AS c JOIN @V AS x ON x.Which = v.Which AND x.Code = c.ComponentCode
                                 WHERE c.TotalCode = v.Code), 0)
        FROM @V AS v WHERE v.Code = @totC AND v.V IS NULL;
        SET @totN += 1;
    END;
    DECLARE @CASH FLOAT, @CASH_RESTRICTED FLOAT, @CASH_PLEDGED FLOAT, @SHORT_TERM_INVESTMENTS FLOAT, @AR FLOAT, @AR_GROSS FLOAT,
            @AR_ECL_ALLOWANCE FLOAT, @AR_GOVERNMENT FLOAT, @AR_SEMI_GOVERNMENT FLOAT, @AR_RELATED_TRADE FLOAT, @AR_AGE_0_90 FLOAT, @AR_AGE_91_180 FLOAT,
            @AR_AGE_181_365 FLOAT, @AR_AGE_OVER_365 FLOAT, @AR_AGE_OVER_365_GOV FLOAT, @AR_INSURED FLOAT, @AR_NOTES_PDC FLOAT, @AR_FACTORED_RECOURSE FLOAT,
            @AR_TOP5 FLOAT, @CONTRACT_ASSETS FLOAT, @RETENTIONS FLOAT, @RETENTIONS_OVERDUE FLOAT, @INVENTORY FLOAT, @INV_RAW FLOAT,
            @INV_WIP FLOAT, @INV_FINISHED FLOAT, @INV_SPARES FLOAT, @INV_IN_TRANSIT FLOAT, @INV_SLOW_MOVING FLOAT, @INV_PROVISION FLOAT,
            @DUE_FROM_RELATED FLOAT, @DUE_FROM_SHAREHOLDERS FLOAT, @OTHER_CA FLOAT, @ADVANCES_TO_SUPPLIERS FLOAT, @ADVANCES_TO_RELATED FLOAT, @PREPAYMENTS FLOAT,
            @VAT_RECEIVABLE FLOAT, @TOTAL_CA FLOAT, @PPE FLOAT, @PPE_LAND_BUILDINGS FLOAT, @PPE_MACHINERY FLOAT, @PPE_VEHICLES FLOAT,
            @PPE_CWIP FLOAT, @PPE_GROSS FLOAT, @PPE_ACC_DEPRECIATION FLOAT, @PPE_REVALUATION_SURPLUS FLOAT, @ROU_ASSETS FLOAT, @INVESTMENT_PROPERTY FLOAT,
            @INVESTMENTS_IN_ASSOCIATES FLOAT, @LT_INVESTMENTS FLOAT, @INTANGIBLES FLOAT, @GOODWILL FLOAT, @LT_RECEIVABLES FLOAT, @OTHER_NCA FLOAT,
            @ASSETS_PLEDGED FLOAT, @TOTAL_ASSETS FLOAT, @ST_LOANS FLOAT, @BANK_ACCEPTANCES FLOAT, @CURRENT_PORTION_LTD FLOAT, @LEASE_LIABS_CURRENT FLOAT,
            @AP FLOAT, @AP_OVERDUE FLOAT, @AP_RELATED FLOAT, @AP_TOP5 FLOAT, @SUPPLIER_FINANCE FLOAT, @AP_NOTES FLOAT,
            @CONTRACT_LIABILITIES FLOAT, @DUE_TO_RELATED FLOAT, @PARTNERS_CURRENT_ACCOUNTS FLOAT, @DIVIDENDS_PAYABLE FLOAT, @ZAKAT_TAX_PAYABLE FLOAT, @OTHER_CL FLOAT,
            @TOTAL_CL FLOAT, @LT_LOANS FLOAT, @LEASE_LIABS FLOAT, @SHAREHOLDER_LOANS_SUB FLOAT, @SHAREHOLDER_LOANS_UNSUB FLOAT, @EOSB FLOAT,
            @OTHER_NCL FLOAT, @TOTAL_LIABS FLOAT, @DEBT_SECURED FLOAT, @DEBT_FLOATING FLOAT, @DEBT_FOREIGN_CCY FLOAT, @DEBT_DUE_1Y FLOAT,
            @DEBT_DUE_1_2Y FLOAT, @DEBT_DUE_2_5Y FLOAT, @DEBT_DUE_OVER_5Y FLOAT, @SHARE_CAPITAL FLOAT, @STATUTORY_RESERVE FLOAT, @CAPITAL_CONTRIBUTIONS FLOAT,
            @RETAINED_EARNINGS FLOAT, @REVALUATION_RESERVE FLOAT, @OTHER_EQUITY FLOAT, @TREASURY_SHARES FLOAT, @MINORITY_INTEREST FLOAT, @TOTAL_EQUITY FLOAT,
            @REVENUE FLOAT, @REV_GOVERNMENT FLOAT, @REV_SEMI_GOVERNMENT FLOAT, @REV_EXPORT FLOAT, @REV_CASH FLOAT, @REV_RELATED FLOAT,
            @REV_RECURRING FLOAT, @REV_TOP_CUSTOMER FLOAT, @REV_TOP5 FLOAT, @COGS FLOAT, @COGS_MATERIALS FLOAT, @COGS_LABOUR FLOAT,
            @COGS_DEPRECIATION FLOAT, @PURCHASES_RELATED FLOAT, @PURCHASES_TOP5 FLOAT, @PURCHASES_IMPORTED FLOAT, @GROSS_PROFIT FLOAT, @OPEX FLOAT,
            @SELLING_DISTRIBUTION FLOAT, @GENERAL_ADMIN FLOAT, @STAFF_COSTS FLOAT, @RENT_SHORT_TERM FLOAT, @ECL_CHARGE FLOAT, @IMPAIRMENTS FLOAT,
            @RND_EXPENSE FLOAT, @OPERATING_PROFIT FLOAT, @DEPR_AMORT FLOAT, @EBITDA FLOAT, @FINANCE_COSTS FLOAT, @CAPITALISED_INTEREST FLOAT,
            @BANK_CHARGES_LC_LG FLOAT, @OTHER_INCOME FLOAT, @NONRECURRING_GAINS FLOAT, @NONRECURRING_LOSSES FLOAT, @SHARE_OF_ASSOCIATES FLOAT, @ZAKAT_TAX FLOAT,
            @NET_PROFIT FLOAT, @CFO_BEFORE_WC FLOAT, @OP_CASH_FLOW FLOAT, @CAPEX FLOAT, @ACQUISITIONS FLOAT, @ASSET_DISPOSALS FLOAT,
            @DEBT_DRAWDOWNS FLOAT, @PRINCIPAL_REPAID FLOAT, @INTEREST_PAID FLOAT, @DIVIDENDS FLOAT, @PARTNER_DRAWINGS FLOAT, @CAPITAL_INJECTION FLOAT,
            @LC_OUTSTANDING FLOAT, @LG_PERFORMANCE FLOAT, @LG_ADVANCE_PAYMENT FLOAT, @LG_FINANCIAL FLOAT, @GUARANTEES_GIVEN FLOAT, @GUARANTEES_GIVEN_RELATED FLOAT,
            @ZAKAT_DISPUTED FLOAT, @CAPITAL_COMMITMENTS FLOAT, @LEGAL_CLAIMS FLOAT, @DERIVATIVES_NOTIONAL FLOAT, @NET_FX_OPEN_POSITION FLOAT, @BACKLOG FLOAT,
            @EMPLOYEES FLOAT;
    SELECT @CASH = MAX(CASE WHEN Code = 'CASH' THEN V END), @CASH_RESTRICTED = MAX(CASE WHEN Code = 'CASH_RESTRICTED' THEN V END), @CASH_PLEDGED = MAX(CASE WHEN Code = 'CASH_PLEDGED' THEN V END),
           @SHORT_TERM_INVESTMENTS = MAX(CASE WHEN Code = 'SHORT_TERM_INVESTMENTS' THEN V END), @AR = MAX(CASE WHEN Code = 'AR' THEN V END), @AR_GROSS = MAX(CASE WHEN Code = 'AR_GROSS' THEN V END),
           @AR_ECL_ALLOWANCE = MAX(CASE WHEN Code = 'AR_ECL_ALLOWANCE' THEN V END), @AR_GOVERNMENT = MAX(CASE WHEN Code = 'AR_GOVERNMENT' THEN V END), @AR_SEMI_GOVERNMENT = MAX(CASE WHEN Code = 'AR_SEMI_GOVERNMENT' THEN V END),
           @AR_RELATED_TRADE = MAX(CASE WHEN Code = 'AR_RELATED_TRADE' THEN V END), @AR_AGE_0_90 = MAX(CASE WHEN Code = 'AR_AGE_0_90' THEN V END), @AR_AGE_91_180 = MAX(CASE WHEN Code = 'AR_AGE_91_180' THEN V END),
           @AR_AGE_181_365 = MAX(CASE WHEN Code = 'AR_AGE_181_365' THEN V END), @AR_AGE_OVER_365 = MAX(CASE WHEN Code = 'AR_AGE_OVER_365' THEN V END), @AR_AGE_OVER_365_GOV = MAX(CASE WHEN Code = 'AR_AGE_OVER_365_GOV' THEN V END),
           @AR_INSURED = MAX(CASE WHEN Code = 'AR_INSURED' THEN V END), @AR_NOTES_PDC = MAX(CASE WHEN Code = 'AR_NOTES_PDC' THEN V END), @AR_FACTORED_RECOURSE = MAX(CASE WHEN Code = 'AR_FACTORED_RECOURSE' THEN V END),
           @AR_TOP5 = MAX(CASE WHEN Code = 'AR_TOP5' THEN V END), @CONTRACT_ASSETS = MAX(CASE WHEN Code = 'CONTRACT_ASSETS' THEN V END), @RETENTIONS = MAX(CASE WHEN Code = 'RETENTIONS' THEN V END),
           @RETENTIONS_OVERDUE = MAX(CASE WHEN Code = 'RETENTIONS_OVERDUE' THEN V END), @INVENTORY = MAX(CASE WHEN Code = 'INVENTORY' THEN V END), @INV_RAW = MAX(CASE WHEN Code = 'INV_RAW' THEN V END),
           @INV_WIP = MAX(CASE WHEN Code = 'INV_WIP' THEN V END), @INV_FINISHED = MAX(CASE WHEN Code = 'INV_FINISHED' THEN V END), @INV_SPARES = MAX(CASE WHEN Code = 'INV_SPARES' THEN V END),
           @INV_IN_TRANSIT = MAX(CASE WHEN Code = 'INV_IN_TRANSIT' THEN V END), @INV_SLOW_MOVING = MAX(CASE WHEN Code = 'INV_SLOW_MOVING' THEN V END), @INV_PROVISION = MAX(CASE WHEN Code = 'INV_PROVISION' THEN V END),
           @DUE_FROM_RELATED = MAX(CASE WHEN Code = 'DUE_FROM_RELATED' THEN V END), @DUE_FROM_SHAREHOLDERS = MAX(CASE WHEN Code = 'DUE_FROM_SHAREHOLDERS' THEN V END), @OTHER_CA = MAX(CASE WHEN Code = 'OTHER_CA' THEN V END),
           @ADVANCES_TO_SUPPLIERS = MAX(CASE WHEN Code = 'ADVANCES_TO_SUPPLIERS' THEN V END), @ADVANCES_TO_RELATED = MAX(CASE WHEN Code = 'ADVANCES_TO_RELATED' THEN V END), @PREPAYMENTS = MAX(CASE WHEN Code = 'PREPAYMENTS' THEN V END),
           @VAT_RECEIVABLE = MAX(CASE WHEN Code = 'VAT_RECEIVABLE' THEN V END), @TOTAL_CA = MAX(CASE WHEN Code = 'TOTAL_CA' THEN V END), @PPE = MAX(CASE WHEN Code = 'PPE' THEN V END),
           @PPE_LAND_BUILDINGS = MAX(CASE WHEN Code = 'PPE_LAND_BUILDINGS' THEN V END), @PPE_MACHINERY = MAX(CASE WHEN Code = 'PPE_MACHINERY' THEN V END), @PPE_VEHICLES = MAX(CASE WHEN Code = 'PPE_VEHICLES' THEN V END),
           @PPE_CWIP = MAX(CASE WHEN Code = 'PPE_CWIP' THEN V END), @PPE_GROSS = MAX(CASE WHEN Code = 'PPE_GROSS' THEN V END), @PPE_ACC_DEPRECIATION = MAX(CASE WHEN Code = 'PPE_ACC_DEPRECIATION' THEN V END),
           @PPE_REVALUATION_SURPLUS = MAX(CASE WHEN Code = 'PPE_REVALUATION_SURPLUS' THEN V END), @ROU_ASSETS = MAX(CASE WHEN Code = 'ROU_ASSETS' THEN V END), @INVESTMENT_PROPERTY = MAX(CASE WHEN Code = 'INVESTMENT_PROPERTY' THEN V END),
           @INVESTMENTS_IN_ASSOCIATES = MAX(CASE WHEN Code = 'INVESTMENTS_IN_ASSOCIATES' THEN V END), @LT_INVESTMENTS = MAX(CASE WHEN Code = 'LT_INVESTMENTS' THEN V END), @INTANGIBLES = MAX(CASE WHEN Code = 'INTANGIBLES' THEN V END),
           @GOODWILL = MAX(CASE WHEN Code = 'GOODWILL' THEN V END), @LT_RECEIVABLES = MAX(CASE WHEN Code = 'LT_RECEIVABLES' THEN V END), @OTHER_NCA = MAX(CASE WHEN Code = 'OTHER_NCA' THEN V END),
           @ASSETS_PLEDGED = MAX(CASE WHEN Code = 'ASSETS_PLEDGED' THEN V END), @TOTAL_ASSETS = MAX(CASE WHEN Code = 'TOTAL_ASSETS' THEN V END), @ST_LOANS = MAX(CASE WHEN Code = 'ST_LOANS' THEN V END),
           @BANK_ACCEPTANCES = MAX(CASE WHEN Code = 'BANK_ACCEPTANCES' THEN V END), @CURRENT_PORTION_LTD = MAX(CASE WHEN Code = 'CURRENT_PORTION_LTD' THEN V END), @LEASE_LIABS_CURRENT = MAX(CASE WHEN Code = 'LEASE_LIABS_CURRENT' THEN V END),
           @AP = MAX(CASE WHEN Code = 'AP' THEN V END), @AP_OVERDUE = MAX(CASE WHEN Code = 'AP_OVERDUE' THEN V END), @AP_RELATED = MAX(CASE WHEN Code = 'AP_RELATED' THEN V END),
           @AP_TOP5 = MAX(CASE WHEN Code = 'AP_TOP5' THEN V END), @SUPPLIER_FINANCE = MAX(CASE WHEN Code = 'SUPPLIER_FINANCE' THEN V END), @AP_NOTES = MAX(CASE WHEN Code = 'AP_NOTES' THEN V END),
           @CONTRACT_LIABILITIES = MAX(CASE WHEN Code = 'CONTRACT_LIABILITIES' THEN V END), @DUE_TO_RELATED = MAX(CASE WHEN Code = 'DUE_TO_RELATED' THEN V END), @PARTNERS_CURRENT_ACCOUNTS = MAX(CASE WHEN Code = 'PARTNERS_CURRENT_ACCOUNTS' THEN V END),
           @DIVIDENDS_PAYABLE = MAX(CASE WHEN Code = 'DIVIDENDS_PAYABLE' THEN V END), @ZAKAT_TAX_PAYABLE = MAX(CASE WHEN Code = 'ZAKAT_TAX_PAYABLE' THEN V END), @OTHER_CL = MAX(CASE WHEN Code = 'OTHER_CL' THEN V END),
           @TOTAL_CL = MAX(CASE WHEN Code = 'TOTAL_CL' THEN V END), @LT_LOANS = MAX(CASE WHEN Code = 'LT_LOANS' THEN V END), @LEASE_LIABS = MAX(CASE WHEN Code = 'LEASE_LIABS' THEN V END),
           @SHAREHOLDER_LOANS_SUB = MAX(CASE WHEN Code = 'SHAREHOLDER_LOANS_SUB' THEN V END), @SHAREHOLDER_LOANS_UNSUB = MAX(CASE WHEN Code = 'SHAREHOLDER_LOANS_UNSUB' THEN V END), @EOSB = MAX(CASE WHEN Code = 'EOSB' THEN V END),
           @OTHER_NCL = MAX(CASE WHEN Code = 'OTHER_NCL' THEN V END), @TOTAL_LIABS = MAX(CASE WHEN Code = 'TOTAL_LIABS' THEN V END), @DEBT_SECURED = MAX(CASE WHEN Code = 'DEBT_SECURED' THEN V END),
           @DEBT_FLOATING = MAX(CASE WHEN Code = 'DEBT_FLOATING' THEN V END), @DEBT_FOREIGN_CCY = MAX(CASE WHEN Code = 'DEBT_FOREIGN_CCY' THEN V END), @DEBT_DUE_1Y = MAX(CASE WHEN Code = 'DEBT_DUE_1Y' THEN V END),
           @DEBT_DUE_1_2Y = MAX(CASE WHEN Code = 'DEBT_DUE_1_2Y' THEN V END), @DEBT_DUE_2_5Y = MAX(CASE WHEN Code = 'DEBT_DUE_2_5Y' THEN V END), @DEBT_DUE_OVER_5Y = MAX(CASE WHEN Code = 'DEBT_DUE_OVER_5Y' THEN V END),
           @SHARE_CAPITAL = MAX(CASE WHEN Code = 'SHARE_CAPITAL' THEN V END), @STATUTORY_RESERVE = MAX(CASE WHEN Code = 'STATUTORY_RESERVE' THEN V END), @CAPITAL_CONTRIBUTIONS = MAX(CASE WHEN Code = 'CAPITAL_CONTRIBUTIONS' THEN V END),
           @RETAINED_EARNINGS = MAX(CASE WHEN Code = 'RETAINED_EARNINGS' THEN V END), @REVALUATION_RESERVE = MAX(CASE WHEN Code = 'REVALUATION_RESERVE' THEN V END), @OTHER_EQUITY = MAX(CASE WHEN Code = 'OTHER_EQUITY' THEN V END),
           @TREASURY_SHARES = MAX(CASE WHEN Code = 'TREASURY_SHARES' THEN V END), @MINORITY_INTEREST = MAX(CASE WHEN Code = 'MINORITY_INTEREST' THEN V END), @TOTAL_EQUITY = MAX(CASE WHEN Code = 'TOTAL_EQUITY' THEN V END),
           @REVENUE = MAX(CASE WHEN Code = 'REVENUE' THEN V END), @REV_GOVERNMENT = MAX(CASE WHEN Code = 'REV_GOVERNMENT' THEN V END), @REV_SEMI_GOVERNMENT = MAX(CASE WHEN Code = 'REV_SEMI_GOVERNMENT' THEN V END),
           @REV_EXPORT = MAX(CASE WHEN Code = 'REV_EXPORT' THEN V END), @REV_CASH = MAX(CASE WHEN Code = 'REV_CASH' THEN V END), @REV_RELATED = MAX(CASE WHEN Code = 'REV_RELATED' THEN V END),
           @REV_RECURRING = MAX(CASE WHEN Code = 'REV_RECURRING' THEN V END), @REV_TOP_CUSTOMER = MAX(CASE WHEN Code = 'REV_TOP_CUSTOMER' THEN V END), @REV_TOP5 = MAX(CASE WHEN Code = 'REV_TOP5' THEN V END),
           @COGS = MAX(CASE WHEN Code = 'COGS' THEN V END), @COGS_MATERIALS = MAX(CASE WHEN Code = 'COGS_MATERIALS' THEN V END), @COGS_LABOUR = MAX(CASE WHEN Code = 'COGS_LABOUR' THEN V END),
           @COGS_DEPRECIATION = MAX(CASE WHEN Code = 'COGS_DEPRECIATION' THEN V END), @PURCHASES_RELATED = MAX(CASE WHEN Code = 'PURCHASES_RELATED' THEN V END), @PURCHASES_TOP5 = MAX(CASE WHEN Code = 'PURCHASES_TOP5' THEN V END),
           @PURCHASES_IMPORTED = MAX(CASE WHEN Code = 'PURCHASES_IMPORTED' THEN V END), @GROSS_PROFIT = MAX(CASE WHEN Code = 'GROSS_PROFIT' THEN V END), @OPEX = MAX(CASE WHEN Code = 'OPEX' THEN V END),
           @SELLING_DISTRIBUTION = MAX(CASE WHEN Code = 'SELLING_DISTRIBUTION' THEN V END), @GENERAL_ADMIN = MAX(CASE WHEN Code = 'GENERAL_ADMIN' THEN V END), @STAFF_COSTS = MAX(CASE WHEN Code = 'STAFF_COSTS' THEN V END),
           @RENT_SHORT_TERM = MAX(CASE WHEN Code = 'RENT_SHORT_TERM' THEN V END), @ECL_CHARGE = MAX(CASE WHEN Code = 'ECL_CHARGE' THEN V END), @IMPAIRMENTS = MAX(CASE WHEN Code = 'IMPAIRMENTS' THEN V END),
           @RND_EXPENSE = MAX(CASE WHEN Code = 'RND_EXPENSE' THEN V END), @OPERATING_PROFIT = MAX(CASE WHEN Code = 'OPERATING_PROFIT' THEN V END), @DEPR_AMORT = MAX(CASE WHEN Code = 'DEPR_AMORT' THEN V END),
           @EBITDA = MAX(CASE WHEN Code = 'EBITDA' THEN V END), @FINANCE_COSTS = MAX(CASE WHEN Code = 'FINANCE_COSTS' THEN V END), @CAPITALISED_INTEREST = MAX(CASE WHEN Code = 'CAPITALISED_INTEREST' THEN V END),
           @BANK_CHARGES_LC_LG = MAX(CASE WHEN Code = 'BANK_CHARGES_LC_LG' THEN V END), @OTHER_INCOME = MAX(CASE WHEN Code = 'OTHER_INCOME' THEN V END), @NONRECURRING_GAINS = MAX(CASE WHEN Code = 'NONRECURRING_GAINS' THEN V END),
           @NONRECURRING_LOSSES = MAX(CASE WHEN Code = 'NONRECURRING_LOSSES' THEN V END), @SHARE_OF_ASSOCIATES = MAX(CASE WHEN Code = 'SHARE_OF_ASSOCIATES' THEN V END), @ZAKAT_TAX = MAX(CASE WHEN Code = 'ZAKAT_TAX' THEN V END),
           @NET_PROFIT = MAX(CASE WHEN Code = 'NET_PROFIT' THEN V END), @CFO_BEFORE_WC = MAX(CASE WHEN Code = 'CFO_BEFORE_WC' THEN V END), @OP_CASH_FLOW = MAX(CASE WHEN Code = 'OP_CASH_FLOW' THEN V END),
           @CAPEX = MAX(CASE WHEN Code = 'CAPEX' THEN V END), @ACQUISITIONS = MAX(CASE WHEN Code = 'ACQUISITIONS' THEN V END), @ASSET_DISPOSALS = MAX(CASE WHEN Code = 'ASSET_DISPOSALS' THEN V END),
           @DEBT_DRAWDOWNS = MAX(CASE WHEN Code = 'DEBT_DRAWDOWNS' THEN V END), @PRINCIPAL_REPAID = MAX(CASE WHEN Code = 'PRINCIPAL_REPAID' THEN V END), @INTEREST_PAID = MAX(CASE WHEN Code = 'INTEREST_PAID' THEN V END),
           @DIVIDENDS = MAX(CASE WHEN Code = 'DIVIDENDS' THEN V END), @PARTNER_DRAWINGS = MAX(CASE WHEN Code = 'PARTNER_DRAWINGS' THEN V END), @CAPITAL_INJECTION = MAX(CASE WHEN Code = 'CAPITAL_INJECTION' THEN V END),
           @LC_OUTSTANDING = MAX(CASE WHEN Code = 'LC_OUTSTANDING' THEN V END), @LG_PERFORMANCE = MAX(CASE WHEN Code = 'LG_PERFORMANCE' THEN V END), @LG_ADVANCE_PAYMENT = MAX(CASE WHEN Code = 'LG_ADVANCE_PAYMENT' THEN V END),
           @LG_FINANCIAL = MAX(CASE WHEN Code = 'LG_FINANCIAL' THEN V END), @GUARANTEES_GIVEN = MAX(CASE WHEN Code = 'GUARANTEES_GIVEN' THEN V END), @GUARANTEES_GIVEN_RELATED = MAX(CASE WHEN Code = 'GUARANTEES_GIVEN_RELATED' THEN V END),
           @ZAKAT_DISPUTED = MAX(CASE WHEN Code = 'ZAKAT_DISPUTED' THEN V END), @CAPITAL_COMMITMENTS = MAX(CASE WHEN Code = 'CAPITAL_COMMITMENTS' THEN V END), @LEGAL_CLAIMS = MAX(CASE WHEN Code = 'LEGAL_CLAIMS' THEN V END),
           @DERIVATIVES_NOTIONAL = MAX(CASE WHEN Code = 'DERIVATIVES_NOTIONAL' THEN V END), @NET_FX_OPEN_POSITION = MAX(CASE WHEN Code = 'NET_FX_OPEN_POSITION' THEN V END), @BACKLOG = MAX(CASE WHEN Code = 'BACKLOG' THEN V END),
           @EMPLOYEES = MAX(CASE WHEN Code = 'EMPLOYEES' THEN V END)
    FROM @V WHERE Which = 'C';
    DECLARE @P_TOTAL_ASSETS FLOAT, @P_REVENUE FLOAT, @P_COGS FLOAT, @P_AP FLOAT, @P_AR FLOAT, @P_CONTRACT_ASSETS FLOAT, @P_INVENTORY FLOAT, @P_OP_CASH_FLOW FLOAT, @P_CURRENT_PORTION_LTD FLOAT, @P_LEASE_LIABS_CURRENT FLOAT, @P_DIVIDENDS FLOAT, @P_PARTNER_DRAWINGS FLOAT, @P_DUE_FROM_RELATED FLOAT, @P_GROSS_PROFIT FLOAT;
    SELECT @P_TOTAL_ASSETS = MAX(CASE WHEN Code = 'TOTAL_ASSETS' THEN V END), @P_REVENUE = MAX(CASE WHEN Code = 'REVENUE' THEN V END), @P_COGS = MAX(CASE WHEN Code = 'COGS' THEN V END),
           @P_AP = MAX(CASE WHEN Code = 'AP' THEN V END), @P_AR = MAX(CASE WHEN Code = 'AR' THEN V END), @P_CONTRACT_ASSETS = MAX(CASE WHEN Code = 'CONTRACT_ASSETS' THEN V END),
           @P_INVENTORY = MAX(CASE WHEN Code = 'INVENTORY' THEN V END), @P_OP_CASH_FLOW = MAX(CASE WHEN Code = 'OP_CASH_FLOW' THEN V END), @P_CURRENT_PORTION_LTD = MAX(CASE WHEN Code = 'CURRENT_PORTION_LTD' THEN V END),
           @P_LEASE_LIABS_CURRENT = MAX(CASE WHEN Code = 'LEASE_LIABS_CURRENT' THEN V END), @P_DIVIDENDS = MAX(CASE WHEN Code = 'DIVIDENDS' THEN V END), @P_PARTNER_DRAWINGS = MAX(CASE WHEN Code = 'PARTNER_DRAWINGS' THEN V END),
           @P_DUE_FROM_RELATED = MAX(CASE WHEN Code = 'DUE_FROM_RELATED' THEN V END), @P_GROSS_PROFIT = MAX(CASE WHEN Code = 'GROSS_PROFIT' THEN V END)
    FROM @V WHERE Which = 'P';

    -- The analytical statement (docs/35 section 6): adjusted EBITDA, interest, funds from operations, debt, cash,
    -- equity, tangible net worth, working capital, each with its reconciliation row.
    DECLARE @ebitdaA FLOAT = @OPERATING_PROFIT + @DEPR_AMORT + ISNULL(@IMPAIRMENTS, 0),
            @interest FLOAT = CASE WHEN @FINANCE_COSTS + ISNULL(@CAPITALISED_INTEREST, 0) >= @INTEREST_PAID THEN @FINANCE_COSTS + ISNULL(@CAPITALISED_INTEREST, 0) ELSE @INTEREST_PAID END,
            @cf BIT = CASE WHEN @OP_CASH_FLOW <> 0 OR @CFO_BEFORE_WC <> 0 OR @CAPEX <> 0 OR @PRINCIPAL_REPAID <> 0 OR @INTEREST_PAID <> 0 OR @DIVIDENDS <> 0
                                OR @PARTNER_DRAWINGS <> 0 THEN 1 ELSE 0 END,
            @restricted FLOAT = ISNULL(@CASH_RESTRICTED, 0),
            @shlSubEq FLOAT = CASE WHEN @evSub = 1 THEN @SHAREHOLDER_LOANS_SUB ELSE 0 END,
            @shlSubDebt FLOAT = CASE WHEN @evSub = 1 THEN 0 ELSE @SHAREHOLDER_LOANS_SUB END,
            @ccDebt FLOAT = CASE WHEN @evCap = 1 THEN 0 ELSE @CAPITAL_CONTRIBUTIONS END,
            @fact FLOAT = ISNULL(@AR_FACTORED_RECOURSE, 0),
            @reclass FLOAT = CASE WHEN @breachAtPe = 1 THEN @LT_LOANS ELSE 0 END,
            @supplier FLOAT = ISNULL(@SUPPLIER_FINANCE, 0);
    DECLARE @ffo FLOAT = CASE WHEN @CFO_BEFORE_WC <> 0 THEN @CFO_BEFORE_WC ELSE @ebitdaA - @interest - @ZAKAT_TAX END,
            @cashAdj FLOAT = @CASH - @restricted,
            @eosbA FLOAT = @EOSB * @eosbPct / 100;
    DECLARE @stDebt FLOAT = @ST_LOANS + @BANK_ACCEPTANCES + @CURRENT_PORTION_LTD + @LEASE_LIABS_CURRENT + @DUE_TO_RELATED + @SHAREHOLDER_LOANS_UNSUB
                            + @PARTNERS_CURRENT_ACCOUNTS + @supplier + @DIVIDENDS_PAYABLE + @fact + @reclass,
            @debt FLOAT = @ST_LOANS + @BANK_ACCEPTANCES + @CURRENT_PORTION_LTD + @LEASE_LIABS_CURRENT + @LT_LOANS + @LEASE_LIABS + @DUE_TO_RELATED
                          + @SHAREHOLDER_LOANS_UNSUB + @PARTNERS_CURRENT_ACCOUNTS + @supplier + @DIVIDENDS_PAYABLE + @eosbA + @shlSubDebt + @ccDebt + @fact,
            @bankDebt FLOAT = @ST_LOANS + @BANK_ACCEPTANCES + @CURRENT_PORTION_LTD + @LT_LOANS + @fact + @supplier,
            @hidden FLOAT = 0;
    -- the credit bureau: debt in SIMAH above the statement's bank debt, within six months of the period end
    IF @bu = 1 AND ISNULL(@buMonthsAfterPe, 0) <= 6
        SET @hidden = CASE WHEN @bankDebt > 0 AND (@buOut - @bankDebt) / @bankDebt * 100 > @hiddenPct THEN @buOut - @bankDebt
                           WHEN @bankDebt = 0 AND @buOut > 0 THEN @buOut ELSE 0 END;
    SET @debt = @debt + @hidden;
    DECLARE @quasi FLOAT = @TOTAL_EQUITY + @shlSubEq - @ccDebt,
            @related FLOAT = @DUE_FROM_RELATED + ISNULL(@ADVANCES_TO_RELATED, 0),
            @over365 FLOAT = ISNULL(@AR_AGE_OVER_365, 0), @gov365 FLOAT = ISNULL(@AR_AGE_OVER_365_GOV, 0);
    DECLARE @impairAr FLOAT = CASE WHEN @over365 - @gov365 - ISNULL(@AR_ECL_ALLOWANCE, 0) > 0 THEN @over365 - @gov365 - ISNULL(@AR_ECL_ALLOWANCE, 0) ELSE 0 END,
            @slow FLOAT = CASE WHEN ISNULL(@INV_SLOW_MOVING, 0) - ISNULL(@INV_PROVISION, 0) > 0 THEN ISNULL(@INV_SLOW_MOVING, 0) - ISNULL(@INV_PROVISION, 0) ELSE 0 END * @invSlowHaircut / 100,
            @reval FLOAT = CASE WHEN @REVALUATION_RESERVE >= ISNULL(@PPE_REVALUATION_SURPLUS, 0) THEN @REVALUATION_RESERVE ELSE @PPE_REVALUATION_SURPLUS END;
    DECLARE @tangQuasi FLOAT = @quasi - @INTANGIBLES;
    DECLARE @adjTnw FLOAT = @tangQuasi - @reval - @related - @impairAr - @slow,
            @adjCa FLOAT = @TOTAL_CA - @related - @impairAr - @gov365 - @slow - ISNULL(@RETENTIONS_OVERDUE, 0),
            @adjCl FLOAT = @TOTAL_CL + @SHAREHOLDER_LOANS_UNSUB + @reclass + @fact,
            @adjTl FLOAT = @TOTAL_LIABS - @shlSubEq + @ccDebt + @fact;
    INSERT #crR (AdjCode, LineCode, Bucket, Amount)
    SELECT v.AdjCode, v.LineCode, v.Bucket, v.Amount
    FROM (VALUES ('ADJ_IMPAIRMENTS', 'IMPAIRMENTS', 'EBITDA', ISNULL(@IMPAIRMENTS, 0)),
                 ('ADJ_CAP_INTEREST', 'CAPITALISED_INTEREST', 'INTEREST', ISNULL(@CAPITALISED_INTEREST, 0)),
                 ('ADJ_RESTRICTED_CASH', 'CASH_RESTRICTED', 'NOT_CASH', @restricted),
                 ('ADJ_SHL_SUB', 'SHAREHOLDER_LOANS_SUB', CASE WHEN @evSub = 1 THEN 'EQUITY' ELSE 'DEBT' END, @SHAREHOLDER_LOANS_SUB),
                 ('ADJ_CAPITAL_CONTRIB', 'CAPITAL_CONTRIBUTIONS', CASE WHEN @evCap = 1 THEN 'EQUITY' ELSE 'DEBT' END, @CAPITAL_CONTRIBUTIONS),
                 ('ADJ_LEASE', 'LEASE_LIABS', 'DEBT', @LEASE_LIABS + @LEASE_LIABS_CURRENT),
                 ('ADJ_EOSB', 'EOSB', 'DEBT', @eosbA),
                 ('ADJ_RELATED_DEBT', 'DUE_TO_RELATED', 'ST_DEBT', @DUE_TO_RELATED),
                 ('ADJ_SHL_UNSUB', 'SHAREHOLDER_LOANS_UNSUB', 'ST_DEBT', @SHAREHOLDER_LOANS_UNSUB),
                 ('ADJ_PARTNERS', 'PARTNERS_CURRENT_ACCOUNTS', 'ST_DEBT', @PARTNERS_CURRENT_ACCOUNTS),
                 ('ADJ_SUPPLIER_FIN', 'SUPPLIER_FINANCE', 'ST_DEBT', @supplier),
                 ('ADJ_DIVIDENDS', 'DIVIDENDS_PAYABLE', 'ST_DEBT', @DIVIDENDS_PAYABLE),
                 ('ADJ_FACTORING', 'AR_FACTORED_RECOURSE', 'ST_DEBT', @fact),
                 ('ADJ_BREACH_RECLASS', 'LT_LOANS', 'ST_DEBT', @reclass),
                 ('ADJ_BUREAU_HIDDEN_DEBT', 'ST_LOANS', 'DEBT', @hidden),
                 ('ADJ_INTANGIBLES', 'INTANGIBLES', 'NOT_TNW', @INTANGIBLES),
                 ('ADJ_REVALUATION', 'REVALUATION_RESERVE', 'NOT_TNW', @reval),
                 ('ADJ_RELATED', 'DUE_FROM_RELATED', 'NOT_TNW', @related),
                 ('ADJ_AR_IMPAIR', 'AR_AGE_OVER_365', 'NOT_TNW', @impairAr),
                 ('ADJ_AR_GOV_NONCURRENT', 'AR_AGE_OVER_365_GOV', 'NON_CURRENT', @gov365),
                 ('ADJ_INV_SLOW', 'INV_SLOW_MOVING', 'NOT_TNW', @slow),
                 ('ADJ_RETENTIONS', 'RETENTIONS_OVERDUE', 'NON_CURRENT', ISNULL(@RETENTIONS_OVERDUE, 0))) AS v (AdjCode, LineCode, Bucket, Amount)
    WHERE v.Amount <> 0;

    -- The break-up value: each asset after the haircut of its kind (card parameters, docs/35 section 6).
    DECLARE @hk TABLE (B VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, K FLOAT);
    INSERT @hk SELECT Bucket, Keep FROM @H;
    DECLARE @K_CASH FLOAT = (SELECT K FROM @hk WHERE B = 'CASH'), @K_CASH_RESTRICTED FLOAT = (SELECT K FROM @hk WHERE B = 'CASH_RESTRICTED'),
            @K_STI FLOAT = (SELECT K FROM @hk WHERE B = 'SHORT_TERM_INVESTMENTS'), @K_AR_GOV FLOAT = (SELECT K FROM @hk WHERE B = 'AR_GOVERNMENT'),
            @K_AR_0_180 FLOAT = (SELECT K FROM @hk WHERE B = 'AR_PRIVATE_0_180'), @K_AR_181_365 FLOAT = (SELECT K FROM @hk WHERE B = 'AR_PRIVATE_181_365'),
            @K_AR_365 FLOAT = (SELECT K FROM @hk WHERE B = 'AR_PRIVATE_OVER_365'), @K_AR_REL FLOAT = (SELECT K FROM @hk WHERE B = 'AR_RELATED'),
            @K_CA FLOAT = (SELECT K FROM @hk WHERE B = 'CONTRACT_ASSETS'), @K_RET FLOAT = (SELECT K FROM @hk WHERE B = 'RETENTIONS'),
            @K_INV_FIN FLOAT = (SELECT K FROM @hk WHERE B = 'INVENTORY_FINISHED'), @K_INV_RAW FLOAT = (SELECT K FROM @hk WHERE B = 'INVENTORY_RAW'),
            @K_INV_WIP FLOAT = (SELECT K FROM @hk WHERE B = 'INVENTORY_WIP'), @K_INV_SLOW FLOAT = (SELECT K FROM @hk WHERE B = 'INVENTORY_SLOW'),
            @K_ADV FLOAT = (SELECT K FROM @hk WHERE B = 'ADVANCES_TO_SUPPLIERS'), @K_PREP FLOAT = (SELECT K FROM @hk WHERE B = 'PREPAYMENTS_OTHER'),
            @K_DFR FLOAT = (SELECT K FROM @hk WHERE B = 'DUE_FROM_RELATED'), @K_PPE_LB FLOAT = (SELECT K FROM @hk WHERE B = 'PPE_LAND_BUILDINGS'),
            @K_PPE_MA FLOAT = (SELECT K FROM @hk WHERE B = 'PPE_MACHINERY'), @K_PPE_VE FLOAT = (SELECT K FROM @hk WHERE B = 'PPE_VEHICLES'),
            @K_PPE_CW FLOAT = (SELECT K FROM @hk WHERE B = 'PPE_CWIP'), @K_PPE_OT FLOAT = (SELECT K FROM @hk WHERE B = 'PPE_OTHER'),
            @K_ROU FLOAT = (SELECT K FROM @hk WHERE B = 'ROU_ASSETS'), @K_IP FLOAT = (SELECT K FROM @hk WHERE B = 'INVESTMENT_PROPERTY'),
            @K_IA FLOAT = (SELECT K FROM @hk WHERE B = 'INVESTMENTS_IN_ASSOCIATES'), @K_LTI FLOAT = (SELECT K FROM @hk WHERE B = 'LT_INVESTMENTS'),
            @K_INT FLOAT = (SELECT K FROM @hk WHERE B = 'INTANGIBLES'), @K_LTR FLOAT = (SELECT K FROM @hk WHERE B = 'LT_RECEIVABLES'),
            @K_ONCA FLOAT = (SELECT K FROM @hk WHERE B = 'OTHER_NCA'), @H_AR_GOV FLOAT = (SELECT Value FROM @prm WHERE GroupCode = 'REALISABLE_HAIRCUT' AND ParamKey = 'AR_GOVERNMENT'),
            @H_RET FLOAT = (SELECT Value FROM @prm WHERE GroupCode = 'REALISABLE_HAIRCUT' AND ParamKey = 'RETENTIONS');
    DECLARE @gov FLOAT = ISNULL(@AR_GOVERNMENT, 0) + ISNULL(@AR_SEMI_GOVERNMENT, 0), @relt FLOAT = ISNULL(@AR_RELATED_TRADE, 0),
            @dsoFb FLOAT = CASE WHEN @REVENUE > 0 THEN (@AR + @CONTRACT_ASSETS) / @REVENUE * 365 ELSE 999 END, @real FLOAT, @rest FLOAT;
    SET @real = GREATEST(@cashAdj, 0.0) * @K_CASH + GREATEST(@restricted, 0.0) * @K_CASH_RESTRICTED + GREATEST(@SHORT_TERM_INVESTMENTS, 0.0) * @K_STI;
    IF @AR_AGE_OVER_365 IS NOT NULL AND @AR_AGE_181_365 IS NOT NULL
    BEGIN
        DECLARE @ng365 FLOAT = GREATEST(@over365 - @gov365 - ISNULL(@AR_ECL_ALLOWANCE, 0), 0.0);
        SET @rest = GREATEST(@AR - @ng365 - @gov365 - @AR_AGE_181_365 - @relt, 0.0);
        DECLARE @govYoung FLOAT = LEAST(GREATEST(@gov - @gov365, 0.0), @rest);
        SET @real = @real + @ng365 * @K_AR_365 + @gov365 * (1 - LEAST(100.0, @H_AR_GOV + @govExtra) / 100)
                    + GREATEST(@AR_AGE_181_365, 0.0) * @K_AR_181_365 + @relt * @K_AR_REL + @govYoung * @K_AR_GOV + GREATEST(@rest - @govYoung, 0.0) * @K_AR_0_180;
    END
    ELSE
        SET @real = @real + GREATEST(@gov, 0.0) * @K_AR_GOV + GREATEST(@relt, 0.0) * @K_AR_REL
                    + GREATEST(@AR - @gov - @relt, 0.0) * CASE WHEN @dsoFb > @arFallbackDso THEN @K_AR_181_365 ELSE @K_AR_0_180 END;
    IF @RETENTIONS IS NOT NULL
        SET @real = @real + GREATEST(@CONTRACT_ASSETS - @RETENTIONS, 0.0) * @K_CA + GREATEST(@RETENTIONS - ISNULL(@RETENTIONS_OVERDUE, 0), 0.0) * @K_RET
                    + ISNULL(@RETENTIONS_OVERDUE, 0) * (1 - LEAST(100.0, @H_RET + @retExtra) / 100);
    ELSE
        SET @real = @real + GREATEST(@CONTRACT_ASSETS, 0.0) * @K_RET;
    IF @INV_RAW IS NOT NULL OR @INV_WIP IS NOT NULL OR @INV_FINISHED IS NOT NULL OR @INV_SLOW_MOVING IS NOT NULL
    BEGIN
        DECLARE @sl FLOAT = GREATEST(ISNULL(@INV_SLOW_MOVING, 0) - ISNULL(@INV_PROVISION, 0), 0.0), @wip FLOAT = ISNULL(@INV_WIP, 0),
                @rawm FLOAT = ISNULL(@INV_RAW, 0) + ISNULL(@INV_SPARES, 0), @fin FLOAT = ISNULL(@INV_FINISHED, 0) + ISNULL(@INV_IN_TRANSIT, 0);
        SET @rest = GREATEST(@INVENTORY - @sl - @wip - @rawm - @fin, 0.0);
        SET @real = @real + @sl * @K_INV_SLOW + GREATEST(@wip, 0.0) * @K_INV_WIP + GREATEST(@rawm + @rest, 0.0) * @K_INV_RAW + GREATEST(@fin, 0.0) * @K_INV_FIN;
    END
    ELSE
        SET @real = @real + GREATEST(@INVENTORY, 0.0) * @K_INV_RAW;
    DECLARE @advRel FLOAT = ISNULL(@ADVANCES_TO_RELATED, 0), @advSup FLOAT = ISNULL(@ADVANCES_TO_SUPPLIERS, 0), @vat FLOAT = ISNULL(@VAT_RECEIVABLE, 0);
    SET @real = @real + GREATEST(@advRel, 0.0) * @K_DFR + GREATEST(@advSup, 0.0) * @K_ADV + GREATEST(@vat, 0.0) * @K_AR_GOV
                + GREATEST(@OTHER_CA - @advRel - @advSup - @vat, 0.0) * @K_PREP + GREATEST(@DUE_FROM_RELATED, 0.0) * @K_DFR;
    DECLARE @ppeNet FLOAT = @PPE - ISNULL(@PPE_REVALUATION_SURPLUS, 0);
    IF @PPE_LAND_BUILDINGS IS NOT NULL OR @PPE_MACHINERY IS NOT NULL OR @PPE_VEHICLES IS NOT NULL OR @PPE_CWIP IS NOT NULL
        SET @real = @real + GREATEST(ISNULL(@PPE_LAND_BUILDINGS, 0), 0.0) * @K_PPE_LB + GREATEST(ISNULL(@PPE_MACHINERY, 0), 0.0) * @K_PPE_MA
                    + GREATEST(ISNULL(@PPE_VEHICLES, 0), 0.0) * @K_PPE_VE + GREATEST(ISNULL(@PPE_CWIP, 0), 0.0) * @K_PPE_CW
                    + GREATEST(@ppeNet - ISNULL(@PPE_LAND_BUILDINGS, 0) - ISNULL(@PPE_MACHINERY, 0) - ISNULL(@PPE_VEHICLES, 0) - ISNULL(@PPE_CWIP, 0), 0.0) * @K_PPE_OT;
    ELSE
        SET @real = @real + GREATEST(@ppeNet, 0.0) * @K_PPE_MA;
    SET @real = @real + GREATEST(@ROU_ASSETS, 0.0) * @K_ROU + GREATEST(@INVESTMENT_PROPERTY, 0.0) * @K_IP + GREATEST(@INVESTMENTS_IN_ASSOCIATES, 0.0) * @K_IA
                + GREATEST(@LT_INVESTMENTS, 0.0) * @K_LTI + GREATEST(@INTANGIBLES, 0.0) * @K_INT + GREATEST(@LT_RECEIVABLES, 0.0) * @K_LTR
                + GREATEST(@OTHER_NCA, 0.0) * @K_ONCA;

    -- Liquidity: the twelve-month sources and uses (docs/35 section 9); trade lines backed by trade assets roll over.
    DECLARE @arBb FLOAT = GREATEST(@AR - @over365 - @relt, 0.0) * @K_AR_0_180, @invBb FLOAT = GREATEST(@INVENTORY - ISNULL(@INV_SLOW_MOVING, 0), 0.0) * @K_INV_FIN,
            @trade FLOAT = @ST_LOANS + @BANK_ACCEPTANCES;
    DECLARE @roll FLOAT = CASE WHEN @breachAtPe = 0 AND ISNULL(@pfExpiring, 0) <= @rollMaxExp
                               THEN @rollPct / 100 * @rollFactor * LEAST(@trade, @arBb + @invBb) ELSE 0 END;
    DECLARE @lqSt FLOAT = @ST_LOANS + @BANK_ACCEPTANCES + @CURRENT_PORTION_LTD + @LEASE_LIABS_CURRENT + @DUE_TO_RELATED
                          + @partnersLiq / 100 * (@PARTNERS_CURRENT_ACCOUNTS + @SHAREHOLDER_LOANS_UNSUB) + @supplier + @DIVIDENDS_PAYABLE + @reclass + @fact;
    DECLARE @pdiv FLOAT = CASE WHEN @hasPrior = 1 AND @P_DIVIDENDS <> 0 THEN @P_DIVIDENDS ELSE @DIVIDENDS END,
            @pdraw FLOAT = CASE WHEN @hasPrior = 1 AND @P_PARTNER_DRAWINGS <> 0 THEN @P_PARTNER_DRAWINGS ELSE @PARTNER_DRAWINGS END;
    DECLARE @sources FLOAT = @cashAdj + @stiLiq / 100 * @SHORT_TERM_INVESTMENTS + GREATEST(@ffo, 0.0) + ISNULL(@pfUndrawn, 0),
            @uses FLOAT = @lqSt - @roll + @DEPR_AMORT * @maintCapex + @pdiv + @pdraw + GREATEST(-@ffo, 0.0);

    -- Fixed costs and the breakeven (the card's fixed_cost_rule).
    DECLARE @fixed FLOAT = CASE WHEN @GENERAL_ADMIN IS NULL AND @SELLING_DISTRIBUTION IS NULL
                                THEN @DEPR_AMORT + @FINANCE_COSTS + @fbFixed / 100 * GREATEST(@OPEX - @DEPR_AMORT + ISNULL(@COGS_DEPRECIATION, 0), 0.0)
                                ELSE @DEPR_AMORT + @FINANCE_COSTS + ISNULL(@RENT_SHORT_TERM, 0) + ISNULL(@GENERAL_ADMIN, 0)
                                     + @staffFixed / 100 * GREATEST(ISNULL(@STAFF_COSTS, 0) - @gaStaff / 100 * ISNULL(@GENERAL_ADMIN, 0), 0.0)
                                     + @sellFixed / 100 * ISNULL(@SELLING_DISTRIBUTION, 0) END,
            @totalCosts FLOAT = @COGS + @OPEX + @FINANCE_COSTS;
    SET @fixed = LEAST(@fixed, @totalCosts);

    -- The named quantities every metric reads (docs/35 section 4).
    DECLARE @cfo FLOAT = @OP_CASH_FLOW;
    DECLARE @cavg FLOAT = CASE WHEN @hasPrior = 1 AND @P_OP_CASH_FLOW <> 0 THEN (@cfo + @P_OP_CASH_FLOW) / 2 ELSE @cfo END,
            @principal FLOAT = CASE WHEN @hasPrior = 1 THEN @P_CURRENT_PORTION_LTD + @P_LEASE_LIABS_CURRENT ELSE @CURRENT_PORTION_LTD + @LEASE_LIABS_CURRENT END,
            @contKnown BIT = CASE WHEN @LC_OUTSTANDING IS NULL AND @LG_PERFORMANCE IS NULL AND @LG_ADVANCE_PAYMENT IS NULL AND @LG_FINANCIAL IS NULL
                                       AND @GUARANTEES_GIVEN IS NULL THEN 0 ELSE 1 END;
    INSERT #crQ (Code, Value)
    SELECT v.Code, v.Value FROM (VALUES
        ('REVENUE', @REVENUE), ('COGS', @COGS), ('OPEX', @OPEX), ('GROSS_PROFIT', @GROSS_PROFIT), ('OPERATING_PROFIT', @OPERATING_PROFIT),
        ('DEPR_AMORT', @DEPR_AMORT), ('NET_PROFIT', @NET_PROFIT), ('EBITDA', @ebitdaA), ('INTEREST', @interest), ('ZAKAT_TAX', @ZAKAT_TAX), ('FFO', @ffo),
        ('CFO', CASE WHEN @cf = 1 THEN @cfo END), ('CFO_AVG', CASE WHEN @cf = 1 THEN @cavg END), ('CAPEX', CASE WHEN @cf = 1 THEN @CAPEX END),
        ('FCF', CASE WHEN @cf = 1 THEN @cfo - @CAPEX - @DIVIDENDS END), ('FCF_PARTNERS', CASE WHEN @cf = 1 THEN @cfo - @CAPEX - @DIVIDENDS - @PARTNER_DRAWINGS END),
        ('RCF', @ffo - @DIVIDENDS - @PARTNER_DRAWINGS), ('EBITDA_LESS_TAX', @ebitdaA - @ZAKAT_TAX), ('DEBT_SERVICE', @principal + @interest),
        ('CPLTD', @CURRENT_PORTION_LTD), ('DEBT', @debt), ('ST_DEBT', @stDebt), ('BANK_DEBT', @bankDebt), ('HIDDEN_DEBT', @hidden),
        ('NET_DEBT', @debt - @cashAdj - @SHORT_TERM_INVESTMENTS), ('CASH_ADJ', @cashAdj), ('LIQUID', @cashAdj + @SHORT_TERM_INVESTMENTS),
        ('MONTHLY_CASH_COSTS', (@COGS + @OPEX - @DEPR_AMORT) / 12), ('QUASI', @quasi), ('TANG_QUASI', @tangQuasi), ('ADJ_TNW', @adjTnw),
        ('ADJ_TL', @adjTl), ('ADJ_CA', @adjCa), ('ADJ_CL', @adjCl), ('NWC_ADJ', @adjCa - @adjCl), ('DEBT_PLUS_QUASI', @debt + @quasi), ('RELATED', @related),
        ('TOTAL_ASSETS', @TOTAL_ASSETS), ('INTANGIBLES', @INTANGIBLES), ('REALISABLE', @real), ('REALISABLE_NW', @real - @adjTl),
        ('LIQ_SOURCES', @sources), ('LIQ_USES', @uses), ('ROLLOVER', @roll),
        ('AVG_ASSETS', CASE WHEN @hasPrior = 1 AND @P_TOTAL_ASSETS <> 0 THEN (@TOTAL_ASSETS + @P_TOTAL_ASSETS) / 2 ELSE @TOTAL_ASSETS END),
        ('AVG_DEBT', @debt), ('NET_PROFIT_RECURRING', @NET_PROFIT - ISNULL(@NONRECURRING_GAINS, 0) + ISNULL(@NONRECURRING_LOSSES, 0)),
        ('AR_TRADE', @AR + @CONTRACT_ASSETS), ('AR', @AR), ('INVENTORY', @INVENTORY), ('AP', @AP), ('CA', @TOTAL_CA), ('OTHER_CA', @OTHER_CA),
        ('CONTRACT_ASSETS', @CONTRACT_ASSETS), ('CONTRACT_LIABILITIES', @CONTRACT_LIABILITIES),
        ('LIQUID_ASSETS', @cashAdj + @SHORT_TERM_INVESTMENTS + @AR + @INVENTORY),
        ('NONOP_ASSETS', @INVESTMENT_PROPERTY + @LT_INVESTMENTS + @INVESTMENTS_IN_ASSOCIATES + @DUE_FROM_RELATED + @OTHER_NCA),
        ('PPE', @PPE), ('PPE_GROSS', @PPE_GROSS), ('PPE_ACC_DEP', ABS(@PPE_ACC_DEPRECIATION)), ('PPE_CWIP', @PPE_CWIP), ('ASSETS_PLEDGED', @ASSETS_PLEDGED),
        ('TRADE_ASSETS', @AR + @INVENTORY), ('BANK_ST_DEBT', @trade), ('TRADE_FINANCE', @BANK_ACCEPTANCES + ISNULL(@LC_OUTSTANDING, 0)),
        ('REV_TOP5', @REV_TOP5), ('REV_TOP_CUSTOMER', @REV_TOP_CUSTOMER),
        ('REV_GOV', CASE WHEN @REV_GOVERNMENT IS NULL AND @REV_SEMI_GOVERNMENT IS NULL THEN NULL ELSE ISNULL(@REV_GOVERNMENT, 0) + ISNULL(@REV_SEMI_GOVERNMENT, 0) END),
        ('REV_EXPORT', @REV_EXPORT), ('REV_CASH', @REV_CASH), ('REV_RELATED', @REV_RELATED), ('REV_RECURRING', @REV_RECURRING), ('BACKLOG', @BACKLOG),
        ('AR_TOP5', @AR_TOP5), ('AR_RELATED', @AR_RELATED_TRADE), ('AP_OVERDUE', @AP_OVERDUE), ('SUPPLIER_FINANCE', @SUPPLIER_FINANCE),
        ('STAFF_COSTS', @STAFF_COSTS), ('ECL_CHARGE', @ECL_CHARGE), ('NONRECURRING_GAINS', @NONRECURRING_GAINS), ('DEBT_SECURED', @DEBT_SECURED),
        ('DEBT_DUE_1Y', @DEBT_DUE_1Y),
        ('DEBT_PROFILE', CASE WHEN @DEBT_DUE_1Y IS NULL THEN NULL ELSE @DEBT_DUE_1Y + ISNULL(@DEBT_DUE_1_2Y, 0) + ISNULL(@DEBT_DUE_2_5Y, 0) + ISNULL(@DEBT_DUE_OVER_5Y, 0) END),
        ('FLOAT_SHOCK', @DEBT_FLOATING * @rateShock / 100), ('FX_OPEN', ISNULL(@NET_FX_OPEN_POSITION, @DEBT_FOREIGN_CCY)),
        ('DUE_FROM_SHAREHOLDERS', @DUE_FROM_SHAREHOLDERS), ('DUE_TO_RELATED', @DUE_TO_RELATED), ('EOSB', @EOSB), ('ZAKAT_DISPUTED', @ZAKAT_DISPUTED),
        ('GUARANTEES_GIVEN', @GUARANTEES_GIVEN), ('LEGAL_CLAIMS', @LEGAL_CLAIMS), ('PURCHASES_RELATED', @PURCHASES_RELATED),
        ('PARTNERS_ON_DEMAND', @PARTNERS_CURRENT_ACCOUNTS + @SHAREHOLDER_LOANS_UNSUB),
        ('CONTINGENT', CASE WHEN @contKnown = 1 THEN ISNULL(@LC_OUTSTANDING, 0) + ISNULL(@LG_PERFORMANCE, 0) + ISNULL(@LG_ADVANCE_PAYMENT, 0) + ISNULL(@LG_FINANCIAL, 0)
                                                     + ISNULL(@GUARANTEES_GIVEN, 0) END),
        ('P_REVENUE', CASE WHEN @hasPrior = 1 THEN @P_REVENUE END), ('DPO_DAYS', CASE WHEN @COGS > 0 THEN @AP / @COGS * 365 END),
        ('P_DPO_DAYS', CASE WHEN @hasPrior = 1 AND @P_COGS <> 0 THEN @P_AP / @P_COGS * 365 END),
        ('FAC_LIMITS', ISNULL(@pfLimits, 0)), ('FAC_OUTSTANDING', ISNULL(@pfOut, 0)), ('UNDRAWN_COMMITTED', ISNULL(@pfUndrawn, 0)),
        ('GUARANTOR_LIQUID', @guLiquid), ('GUARANTEED', @guGuaranteed), ('GUARANTOR_GIVEN', @guGiven), ('GUARANTOR_NET_WORTH', @guNetWorth),
        ('FIXED_COSTS', @fixed), ('TOTAL_COSTS', @totalCosts)) AS v (Code, Value);

    -- The metrics whose rule fits no pattern (VALUE), as credit_reference.metric_values.
    DECLARE @val TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(14) NOT NULL, Value FLOAT NULL);
    DECLARE @gross FLOAT = CASE WHEN @AR_GROSS IS NOT NULL THEN @AR_GROSS ELSE @AR + ISNULL(@AR_ECL_ALLOWANCE, 0) END,
            @dso FLOAT = CASE WHEN @REVENUE > 0 THEN (@AR + @CONTRACT_ASSETS) / @REVENUE * 365 END,
            @dio FLOAT = CASE WHEN @COGS > 0 THEN @INVENTORY / @COGS * 365 END,
            @dpo FLOAT = CASE WHEN @COGS > 0 THEN @AP / @COGS * 365 END,
            @privOver FLOAT = @AR_AGE_OVER_365 - ISNULL(@AR_AGE_OVER_365_GOV, 0),
            @dd FLOAT = @DIVIDENDS + @PARTNER_DRAWINGS, @netDebt FLOAT = @debt - @cashAdj - @SHORT_TERM_INVESTMENTS, @rcf FLOAT = @ffo - @DIVIDENDS - @PARTNER_DRAWINGS,
            @varCosts FLOAT = GREATEST(@totalCosts - @fixed, 0.0);
    DECLARE @cm FLOAT = CASE WHEN @REVENUE > 0 THEN (@REVENUE - @varCosts) / @REVENUE ELSE -1 END,
            @pArTrade FLOAT = CASE WHEN @hasPrior = 1 THEN @P_AR + @P_CONTRACT_ASSETS END,
            @apBase FLOAT = CASE WHEN @COGS_MATERIALS IS NOT NULL AND @COGS_MATERIALS > 0 THEN @COGS_MATERIALS ELSE @COGS END,
            @expo FLOAT = GREATEST(ISNULL(@pfLimits, 0), ISNULL(@pfOut, 0)),
            @collRec FLOAT = (SELECT SUM(c.Cover * (1 - h.Value / 100)) FROM #crColl AS c JOIN @prm AS h ON h.GroupCode = 'COLLATERAL_HAIRCUT' AND h.ParamKey = c.Kind),
            @genericKeep FLOAT = 1 - (SELECT Value / 100 FROM @prm WHERE GroupCode = 'COLLATERAL_HAIRCUT' AND ParamKey = 'GENERIC');
    INSERT @val (Code, State, Value)
    SELECT v.Code, v.State, CASE WHEN v.State = 'COMPUTED' THEN v.Value END
    FROM (VALUES
        ('MARKET_SHARE', CASE WHEN ISNULL(@marketSize, 0) <= 0 OR @REVENUE <= 0 OR @REVENUE / @marketSize * 100 > 100 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END,
                         @REVENUE / NULLIF(@marketSize, 0) * 100),
        ('RESTRICTED_CASH_SHARE', CASE WHEN @CASH = 0 THEN 'COMPUTED' WHEN @CASH_RESTRICTED IS NOT NULL THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                                  CASE WHEN @CASH = 0 THEN 0 ELSE @CASH_RESTRICTED / NULLIF(@CASH, 0) * 100 END),
        ('CASH_CYCLE', CASE WHEN @dso IS NULL OR @dio IS NULL OR @dpo IS NULL THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END, @dso + @dio - @dpo),
        ('AR_OVER_180_SHARE', CASE WHEN @AR = 0 THEN 'COMPUTED' WHEN @AR_AGE_181_365 IS NOT NULL AND @AR_AGE_OVER_365 IS NOT NULL AND @gross > 0 THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                              CASE WHEN @AR = 0 THEN 0 ELSE (@AR_AGE_181_365 + @AR_AGE_OVER_365) / NULLIF(@gross, 0) * 100 END),
        ('AR_OVER_365_SHARE', CASE WHEN @AR = 0 THEN 'COMPUTED' WHEN @AR_AGE_OVER_365 IS NOT NULL AND @gross > 0 THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                              CASE WHEN @AR = 0 THEN 0 ELSE @AR_AGE_OVER_365 / NULLIF(@gross, 0) * 100 END),
        ('ECL_COVERAGE_365', CASE WHEN @AR_AGE_OVER_365 IS NULL OR @AR_ECL_ALLOWANCE IS NULL THEN 'NOT_COMPUTABLE' WHEN @privOver <= 0 THEN 'BEST' ELSE 'COMPUTED' END,
                             @AR_ECL_ALLOWANCE / NULLIF(@privOver, 0) * 100),
        ('AR_GROWTH_VS_REVENUE', CASE WHEN @hasPrior = 0 OR @pArTrade IS NULL OR @pArTrade <= 0 OR ISNULL(@P_REVENUE, 0) <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END,
                                 ((@AR + @CONTRACT_ASSETS) - @pArTrade) / NULLIF(@pArTrade, 0) * 100 - (@REVENUE - @P_REVENUE) / NULLIF(@P_REVENUE, 0) * 100),
        ('INV_GROWTH_VS_COGS', CASE WHEN @hasPrior = 0 OR @P_INVENTORY IS NULL OR @P_INVENTORY <= 0 OR ISNULL(@P_COGS, 0) <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END,
                               (@INVENTORY - @P_INVENTORY) / NULLIF(@P_INVENTORY, 0) * 100 - (@COGS - @P_COGS) / NULLIF(@P_COGS, 0) * 100),
        ('INV_SLOW_SHARE', CASE WHEN @INVENTORY = 0 THEN 'COMPUTED' WHEN @INV_SLOW_MOVING IS NOT NULL THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                           CASE WHEN @INVENTORY = 0 THEN 0 ELSE @INV_SLOW_MOVING / NULLIF(@INVENTORY, 0) * 100 END),
        ('INV_PROVISION_COVERAGE', CASE WHEN @INV_SLOW_MOVING IS NULL OR @INV_PROVISION IS NULL THEN 'NOT_COMPUTABLE' WHEN @INV_SLOW_MOVING = 0 THEN 'BEST' ELSE 'COMPUTED' END,
                                   @INV_PROVISION / NULLIF(@INV_SLOW_MOVING, 0) * 100),
        ('RETENTIONS_OVERDUE_SHARE', CASE WHEN @RETENTIONS > 0 AND @RETENTIONS_OVERDUE IS NOT NULL THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                                     @RETENTIONS_OVERDUE / NULLIF(@RETENTIONS, 0) * 100),
        ('DOUBLE_LEVERAGE', CASE WHEN @holdco = 0 THEN 'NOT_COMPUTABLE' WHEN @INVESTMENTS_IN_ASSOCIATES = 0 THEN 'COMPUTED' WHEN @quasi <= 0 THEN 'WORST' ELSE 'COMPUTED' END,
                            CASE WHEN @INVESTMENTS_IN_ASSOCIATES = 0 THEN 0 ELSE @INVESTMENTS_IN_ASSOCIATES / NULLIF(@quasi, 0) * 100 END),
        ('AP_TOP5_SHARE', CASE WHEN @PURCHASES_TOP5 IS NOT NULL THEN CASE WHEN @apBase <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END
                               WHEN @AP_TOP5 IS NOT NULL THEN CASE WHEN @AP <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END ELSE 'NOT_COMPUTABLE' END,
                          CASE WHEN @PURCHASES_TOP5 IS NOT NULL THEN @PURCHASES_TOP5 / NULLIF(@apBase, 0) * 100 ELSE @AP_TOP5 / NULLIF(@AP, 0) * 100 END),
        ('LARGEST_LENDER_SHARE', CASE WHEN ISNULL(@pfLimits, 0) <> 0 THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END, @pfLargest),
        ('FACILITIES_EXPIRING_12M_SHARE', CASE WHEN ISNULL(@pfLimits, 0) <> 0 THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END, @pfExpiring),
        ('COLLATERAL_COVERAGE', CASE WHEN EXISTS (SELECT 1 FROM #crColl) THEN CASE WHEN @expo <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END
                                     WHEN @DEBT_SECURED > 0 AND @ASSETS_PLEDGED IS NOT NULL THEN 'COMPUTED' ELSE 'NOT_COMPUTABLE' END,
                                CASE WHEN EXISTS (SELECT 1 FROM #crColl) THEN ISNULL(@collRec, 0) / NULLIF(@expo, 0)
                                     ELSE @ASSETS_PLEDGED * @genericKeep / NULLIF(@DEBT_SECURED, 0) END),
        ('PARTNER_DRAWINGS_TO_CFO', CASE WHEN @cf = 0 THEN 'NOT_COMPUTABLE' WHEN @dd = 0 THEN 'COMPUTED' WHEN @ffo <= 0 THEN 'WORST' ELSE 'COMPUTED' END,
                                    CASE WHEN @dd = 0 THEN 0 ELSE @dd / NULLIF(@ffo, 0) * 100 END),
        ('BREAKEVEN_SAFETY_MARGIN', CASE WHEN @cm <= 0 THEN 'WORST' ELSE 'COMPUTED' END,
                                    CASE WHEN @fixed = 0 THEN 100 ELSE (@REVENUE - @fixed / NULLIF(@cm, 0)) / NULLIF(@REVENUE, 0) * 100 END),
        ('RCF_TO_NET_DEBT', CASE WHEN @netDebt <= 0 THEN CASE WHEN @rcf >= 0 THEN 'BEST' ELSE 'NOT_COMPUTABLE' END ELSE 'COMPUTED' END, @rcf / NULLIF(@netDebt, 0) * 100),
        ('ACC_LOSS_TO_CAPITAL', CASE WHEN @RETAINED_EARNINGS >= 0 THEN 'BEST' WHEN @SHARE_CAPITAL <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END,
                                -@RETAINED_EARNINGS / NULLIF(@SHARE_CAPITAL, 0) * 100),
        ('GROSS_MARGIN_CHANGE', CASE WHEN @hasPrior = 0 OR @REVENUE <= 0 OR ISNULL(@P_REVENUE, 0) <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END,
                                @GROSS_PROFIT / NULLIF(@REVENUE, 0) * 100 - @P_GROSS_PROFIT / NULLIF(@P_REVENUE, 0) * 100),
        ('CFO_TO_EBITDA', CASE WHEN @cf = 0 THEN 'NOT_COMPUTABLE' WHEN @ebitdaA <= 0 THEN CASE WHEN @cfo < 0 THEN 'WORST' ELSE 'NOT_COMPUTABLE' END ELSE 'COMPUTED' END,
                          @cfo / NULLIF(@ebitdaA, 0) * 100),
        ('PAYOUT_RATIO', CASE WHEN @DIVIDENDS = 0 THEN CASE WHEN @NET_PROFIT > 0 THEN 'BEST' ELSE 'NOT_COMPUTABLE' END WHEN @NET_PROFIT <= 0 THEN 'WORST' ELSE 'COMPUTED' END,
                         @DIVIDENDS / NULLIF(@NET_PROFIT, 0) * 100),
        ('PRODUCT_CASH_FLOW_QUALITY', CASE WHEN @prodCfq IS NULL THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END, @prodCfq),
        ('PRODUCT_CONCENTRATION', CASE WHEN @prodConc IS NULL THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END, @prodConc),
        ('INVENTORY_CRISIS_VALUE', CASE WHEN @invCrisis IS NULL THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END, @invCrisis),
        ('INVENTORY_DAYS_TO_SELL_STAGNANT', CASE WHEN @invDays IS NULL THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END, @invDays),
        ('BUREAU_DEBT_GAP', CASE WHEN @bu = 0 THEN 'NOT_COMPUTABLE' WHEN @bankDebt <= 0 THEN CASE WHEN @buOut = 0 THEN 'COMPUTED' ELSE 'WORST' END ELSE 'COMPUTED' END,
                            CASE WHEN @bankDebt <= 0 THEN 0 ELSE (@buOut - @bankDebt) / NULLIF(@bankDebt, 0) * 100 END)
    ) AS v (Code, State, Value);

    -- Every metric: by its pattern from the quantities (docs/35 section 4), or its value above. The order of the rules:
    -- an unknown term, then a zero denominator, a zero numerator, a negative denominator, a negative numerator.
    INSERT #crM (Code, State, Value)
    SELECT m.Code, r.State, CASE WHEN r.State = 'COMPUTED' THEN r.Value END
    FROM fin.CreditMetric AS m
    LEFT JOIN #crQ AS qn ON qn.Code = m.NumQty
    LEFT JOIN #crQ AS qd ON qd.Code = m.DenQty
    LEFT JOIN @val AS vv ON vv.Code = m.Code
    CROSS APPLY (SELECT qn.Value AS n, qd.Value AS d) AS t
    CROSS APPLY (SELECT CASE
        WHEN m.Pattern = 'VALUE' THEN vv.State
        WHEN t.n IS NULL OR (m.DenQty IS NOT NULL AND t.d IS NULL) THEN 'NOT_COMPUTABLE'
        WHEN m.Pattern = 'AMOUNT' THEN CASE WHEN t.n <= 0 AND m.IfNumNeg = 'WORST' THEN 'WORST' ELSE 'COMPUTED' END
        WHEN m.Pattern = 'DIFF' THEN 'COMPUTED'
        WHEN m.Pattern = 'GROWTH' THEN CASE WHEN t.d <= 0 THEN 'NOT_COMPUTABLE' ELSE 'COMPUTED' END
        WHEN t.d = 0 THEN CASE WHEN m.IfDenZero = 'BEST' OR (m.IfDenZero = 'BEST_IF_NUM_POS' AND t.n > 0) OR (m.IfDenZero = 'BEST_IF_NUM_NONNEG' AND t.n >= 0) THEN 'BEST'
                               WHEN m.IfDenZero IN ('WORST','BEST_IF_NUM_POS','BEST_IF_NUM_NONNEG') THEN 'WORST' ELSE 'NOT_COMPUTABLE' END
        WHEN t.n = 0 AND m.IfNumZero = 'VALUE0' THEN 'COMPUTED'
        WHEN t.n = 0 AND m.IfNumZero = 'WORST' THEN 'WORST'
        WHEN t.n = 0 AND m.IfNumZero = 'BEST_IF_DEN_POS' AND t.d > 0 THEN 'BEST'
        WHEN t.d < 0 AND m.IfDenNeg = 'WORST' THEN 'WORST'
        WHEN t.d < 0 AND m.IfDenNeg = 'NA' THEN 'NOT_COMPUTABLE'
        WHEN t.n < 0 AND m.IfNumNeg = 'WORST' THEN 'WORST'
        WHEN t.n < 0 AND m.IfNumNeg = 'NA' THEN 'NOT_COMPUTABLE'
        WHEN t.n < 0 AND m.IfNumNeg = 'BEST_IF_DEN_POS' AND t.d > 0 THEN 'BEST'
        ELSE 'COMPUTED' END AS State) AS s
    CROSS APPLY (SELECT CASE s.State WHEN 'BEST' THEN 'BEST' WHEN 'WORST' THEN 'WORST' ELSE s.State END AS State,
                        CASE WHEN m.Pattern = 'VALUE' THEN vv.Value
                             WHEN m.Pattern = 'AMOUNT' THEN t.n * @fx / @unit
                             WHEN m.Pattern = 'DIFF' THEN t.n - t.d
                             WHEN m.Pattern = 'GROWTH' THEN (t.n - t.d) / NULLIF(t.d, 0) * 100
                             WHEN t.n = 0 AND m.IfNumZero = 'VALUE0' THEN 0
                             ELSE t.n / NULLIF(t.d, 0) * m.Scale END AS Value) AS r
    WHERE m.Kind = 'QUANTITATIVE';

    -- The factors: each scorecard metric scored on its grid, or the qualitative score of the context; a missing metric's
    -- weight goes to the scored metrics of its own factor first (docs/35 section 3).
    INSERT #crF (MetricId, Code, Kind, FactorCode, Weight, Status, Value, Score, SortOrder)
    SELECT sm.MetricId, cm.Code, cm.Kind, sm.FactorCode, sm.Weight,
           CASE WHEN cm.Kind = 'QUALITATIVE' THEN CASE WHEN q.Score IS NULL THEN 'NOT_COMPUTABLE' ELSE 'ANALYST' END
                WHEN m.State = 'COMPUTED' THEN 'COMPUTED' WHEN m.State IN ('BEST','WORST') THEN 'EXTREME' ELSE 'NOT_COMPUTABLE' END,
           CASE WHEN cm.Kind = 'QUANTITATIVE' AND m.State = 'COMPUTED' THEN m.Value END,
           CASE WHEN cm.Kind = 'QUALITATIVE' THEN CAST(ROUND(q.Score, 4) AS DECIMAL(9,4))
                WHEN m.State = 'BEST' THEN 0.5 WHEN m.State = 'WORST' THEN 20.5 WHEN m.State = 'COMPUTED' THEN gs.Score END,
           sm.SortOrder
    FROM fin.ScorecardMetric AS sm
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = sm.MetricId
    LEFT JOIN #crM AS m ON m.Code = cm.Code
    OUTER APPLY (SELECT CASE cm.Code WHEN 'BUSINESS_PROFILE' THEN @qualBp WHEN 'FINANCIAL_POLICY' THEN @qualFp END AS Score) AS q
    OUTER APPLY fin.fn_CreditGridScore(m.Value, sm.B0, sm.B1, sm.B2, sm.B3, sm.B4, sm.B5, sm.B6, sm.B7, sm.B8) AS gs
    WHERE sm.ScorecardId = @card;
    UPDATE f SET EffectiveWeight = CASE WHEN f.Score IS NULL THEN 0 ELSE f.Weight + g.Missing * f.Weight / g.Scored END
    FROM #crF AS f
    JOIN (SELECT FactorCode, SUM(CASE WHEN Score IS NULL THEN Weight ELSE 0 END) AS Missing, SUM(CASE WHEN Score IS NOT NULL THEN Weight END) AS Scored
          FROM #crF GROUP BY FactorCode) AS g ON g.FactorCode = f.FactorCode;
    DECLARE @coverage FLOAT = ROUND((SELECT SUM(CASE WHEN Score IS NOT NULL THEN Weight ELSE 0 END) FROM #crF WHERE Kind = 'QUANTITATIVE') * 100
                                    / (SELECT SUM(Weight) FROM #crF WHERE Kind = 'QUANTITATIVE'), 2);

    -- The level of each item rule (docs/35 section 7).
    INSERT #crI (MetricCode, LineCode, Level, Value, SortOrder)
    SELECT cm.Code, r.LineCode,
           CASE WHEN m.State = 'NOT_COMPUTABLE' OR m.State IS NULL THEN 'NOT_ASSESSED' WHEN m.State = 'BEST' THEN 'LOW' WHEN m.State = 'WORST' THEN 'CRITICAL' ELSE il.RiskLevel END,
           CASE WHEN m.State = 'COMPUTED' THEN m.Value END, r.SortOrder
    FROM fin.ScorecardItemRule AS r
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = r.MetricId
    LEFT JOIN #crM AS m ON m.Code = cm.Code
    OUTER APPLY fin.fn_CreditItemLevel(m.Value, r.T1, r.T2, r.T3, r.T4) AS il
    WHERE r.ScorecardId = @card;

    -- The disclosures asked for and given (docs/35 section 11).
    INSERT #crD (Code, Given)
    SELECT v.Code, v.Given FROM (VALUES
        ('AR_AGING', CASE WHEN @AR > 0.05 * @TOTAL_ASSETS THEN 1 END,
                     CASE WHEN @AR_AGE_0_90 IS NOT NULL AND @AR_AGE_91_180 IS NOT NULL AND @AR_AGE_181_365 IS NOT NULL AND @AR_AGE_OVER_365 IS NOT NULL THEN 1 ELSE 0 END),
        ('AR_ALLOWANCE', CASE WHEN @AR > 0.05 * @TOTAL_ASSETS THEN 1 END, CASE WHEN @AR_GROSS IS NOT NULL OR @AR_ECL_ALLOWANCE IS NOT NULL THEN 1 ELSE 0 END),
        ('CUSTOMER_CONCENTRATION', CASE WHEN @REVENUE > 0 THEN 1 END, CASE WHEN @REV_TOP5 IS NOT NULL OR @REV_TOP_CUSTOMER IS NOT NULL THEN 1 ELSE 0 END),
        ('INVENTORY_BREAKDOWN', CASE WHEN @INVENTORY > 0.05 * @TOTAL_ASSETS THEN 1 END, CASE WHEN @INV_SLOW_MOVING IS NOT NULL THEN 1 ELSE 0 END),
        ('RESTRICTED_CASH', CASE WHEN @BANK_ACCEPTANCES > 0 OR ISNULL(@LC_OUTSTANDING, 0) > 0 OR ISNULL(@LG_PERFORMANCE, 0) > 0 OR ISNULL(@LG_FINANCIAL, 0) > 0
                                      OR ISNULL(@LG_ADVANCE_PAYMENT, 0) > 0 THEN 1 END, CASE WHEN @CASH_RESTRICTED IS NOT NULL THEN 1 ELSE 0 END),
        ('DEBT_MATURITY', CASE WHEN @debt > 0 THEN 1 END, CASE WHEN @DEBT_DUE_1Y IS NOT NULL THEN 1 ELSE 0 END),
        ('DEBT_SECURED', CASE WHEN @debt > 0 THEN 1 END, CASE WHEN @DEBT_SECURED IS NOT NULL THEN 1 ELSE 0 END),
        ('COST_BREAKDOWN', 1, CASE WHEN @STAFF_COSTS IS NOT NULL AND (@GENERAL_ADMIN IS NOT NULL OR @SELLING_DISTRIBUTION IS NOT NULL) THEN 1 ELSE 0 END),
        ('CONTINGENTS', 1, CAST(@contKnown AS INT)),
        ('RETENTIONS', CASE WHEN @CONTRACT_ASSETS > 0 THEN 1 END, CASE WHEN @RETENTIONS IS NOT NULL THEN 1 ELSE 0 END),
        ('BACKLOG', CASE WHEN @cardCode = 'CONTRACTING' THEN 1 END, CASE WHEN @BACKLOG IS NOT NULL THEN 1 ELSE 0 END),
        ('RELATED_BREAKDOWN', CASE WHEN @DUE_FROM_RELATED > 0 THEN 1 END, CASE WHEN @DUE_FROM_SHAREHOLDERS IS NOT NULL THEN 1 ELSE 0 END),
        ('PPE_BREAKDOWN', CASE WHEN @PPE > 0.1 * @TOTAL_ASSETS THEN 1 END,
                          CASE WHEN @PPE_LAND_BUILDINGS IS NOT NULL OR @PPE_MACHINERY IS NOT NULL OR @PPE_VEHICLES IS NOT NULL THEN 1 ELSE 0 END)
    ) AS v (Code, Asked, Given)
    WHERE v.Asked = 1;
    DECLARE @completeness FLOAT = CASE WHEN EXISTS (SELECT 1 FROM #crD) THEN ROUND(CAST((SELECT SUM(CAST(Given AS INT)) FROM #crD) AS FLOAT) / (SELECT COUNT(*) FROM #crD) * 100, 2) ELSE 100 END;

    -- The liquidity label (SGL) from the coverage (docs/35 section 9).
    DECLARE @lcState VARCHAR(14), @lcValue FLOAT;
    SELECT @lcState = State, @lcValue = Value FROM #crM WHERE Code = 'LIQUIDITY_COVERAGE';
    DECLARE @sgl VARCHAR(5) = CASE WHEN @lcState = 'NOT_COMPUTABLE' THEN NULL WHEN @lcState = 'BEST' THEN 'SGL-1' WHEN @lcState = 'WORST' THEN 'SGL-4'
                                   WHEN @lcValue >= @sgl1 THEN 'SGL-1' WHEN @lcValue >= @sgl2 THEN 'SGL-2' WHEN @lcValue >= @sgl3 THEN 'SGL-3' ELSE 'SGL-4' END;

    -- The financial and weighted aggregates (docs/35 section 3).
    DECLARE @state VARCHAR(17), @finScore FLOAT, @finNotch INT, @agg FLOAT, @n0 INT;
    IF @coverage < @minCov
        SET @state = 'INSUFFICIENT_DATA';
    ELSE
    BEGIN
        SET @finScore = ROUND((SELECT SUM(Score * EffectiveWeight) / SUM(EffectiveWeight) FROM #crF WHERE Kind = 'QUANTITATIVE' AND Score IS NOT NULL), 4);
        SET @finNotch = CASE WHEN FLOOR(@finScore - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(@finScore - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(@finScore - 0.5) + 1 END;
        IF EXISTS (SELECT 1 FROM #crF WHERE Kind = 'QUALITATIVE' AND Score IS NULL)
            SET @state = 'INDICATIVE';
        ELSE
        BEGIN
            IF @proforma = 0 AND EXISTS (SELECT 1 FROM #crF
                                         WHERE Kind = 'QUALITATIVE'
                                           AND ABS(CASE WHEN FLOOR(Score - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(Score - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(Score - 0.5) + 1 END - @finNotch) > @qualBound
                                           AND NOT ((Code = 'BUSINESS_PROFILE' AND @docBp = 1) OR (Code = 'FINANCIAL_POLICY' AND @docFp = 1)))
                THROW 50065, 'A qualitative grade more than the scorecard''s bound from the financial grade needs a supporting document (BR-FIN-021)', 1;
            SET @state = 'RATED';
            SET @agg = ROUND((SELECT SUM(Score * EffectiveWeight) / SUM(EffectiveWeight) FROM #crF WHERE Score IS NOT NULL), 4);
            SET @n0 = CASE WHEN FLOOR(@agg - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(@agg - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(@agg - 0.5) + 1 END;
        END
    END

    -- The adjustments that apply, in the order of credit_reference.applied_adjustments (docs/35 section 8).
    DECLARE @n1 INT, @n2 INT, @n3 INT, @n4 INT, @n5 INT, @notches INT, @rawN INT, @capS INT, @capA INT;
    IF @state = 'RATED'
    BEGIN
        DECLARE @P TABLE (RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, P FLOAT);
        INSERT @P SELECT RuleCode, ParamValue FROM fin.ScorecardAdjustment WHERE ScorecardId = @card AND IsActive = 1;
        DECLARE @accState VARCHAR(14), @accValue FLOAT, @tcState VARCHAR(14), @tcValue FLOAT, @blState VARCHAR(14), @blValue FLOAT, @fxState VARCHAR(14), @fxValue FLOAT,
                @rsState VARCHAR(14), @rsValue FLOAT;
        SELECT @accState = State, @accValue = Value FROM #crM WHERE Code = 'ACC_LOSS_TO_CAPITAL';
        SELECT @tcState = State, @tcValue = Value FROM #crM WHERE Code = 'REV_TOP_CUSTOMER_SHARE';
        SELECT @blState = State, @blValue = Value FROM #crM WHERE Code = 'BACKLOG_COVERAGE';
        SELECT @fxState = State, @fxValue = Value FROM #crM WHERE Code = 'FX_EXPOSURE_TO_TNW';
        SELECT @rsState = State, @rsValue = Value FROM #crM WHERE Code = 'REVENUE_SIZE';
        DECLARE @lost BIT = CASE WHEN @accState = 'COMPUTED' AND @accValue >= (SELECT P FROM @P WHERE RuleCode = 'HALF_CAPITAL_LOST') THEN 1 ELSE 0 END,
                @cured BIT = CASE WHEN @quasi >= @SHARE_CAPITAL THEN 1 ELSE 0 END,
                @relExp FLOAT = @related + CASE WHEN @GUARANTEES_GIVEN_RELATED IS NOT NULL THEN @GUARANTEES_GIVEN_RELATED ELSE ISNULL(@GUARANTEES_GIVEN, 0) END;
        DECLARE @relOn BIT = CASE WHEN @relExp > 0 AND (@adjTnw <= 0 OR @relExp > (SELECT P FROM @P WHERE RuleCode = 'RELATED_PARTY_EXPOSURE') / 100 * @adjTnw) THEN 1 ELSE 0 END,
                @concOn BIT = CASE WHEN @tcState = 'COMPUTED' AND @tcValue > (SELECT P FROM @P WHERE RuleCode = 'CUSTOMER_CONCENTRATION')
                                        AND NOT (@REV_GOVERNMENT IS NOT NULL AND @REV_GOVERNMENT >= @REV_TOP_CUSTOMER AND @blState = 'COMPUTED' AND @blValue >= 1) THEN 1 ELSE 0 END,
                @drain FLOAT = @PARTNER_DRAWINGS + CASE WHEN @hasPrior = 1 THEN GREATEST(@DUE_FROM_RELATED - @P_DUE_FROM_RELATED, 0.0) ELSE 0 END,
                @fxOpen FLOAT = ISNULL(ISNULL(@NET_FX_OPEN_POSITION, @DEBT_FOREIGN_CCY), 0);
        DECLARE @app TABLE (Ord INT PRIMARY KEY, RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL);
        INSERT @app (Ord, RuleCode)
        SELECT v.Ord, v.RuleCode FROM (VALUES
            (1, 'UNAUDITED_ANNUAL', CASE WHEN @assurance = 'MANAGEMENT' AND @pt = 'ANNUAL' THEN 1 ELSE 0 END),
            (2, 'AUDIT_QUALIFIED', CASE WHEN @opinion = 'QUALIFIED' THEN 1 ELSE 0 END),
            (3, 'STALE_STATEMENT', CASE WHEN @ageMonths > (SELECT P FROM @P WHERE RuleCode = 'STALE_STATEMENT') THEN 1 ELSE 0 END),
            (4, 'INCOMPLETE_STATEMENT', CASE WHEN @cf = 0 THEN 1 ELSE 0 END),
            (5, 'RESTATEMENT', CASE WHEN @restatedPct > (SELECT P FROM @P WHERE RuleCode = 'RESTATEMENT') THEN 1 ELSE 0 END),
            (6, 'HOLDCO_STANDALONE', CASE WHEN @holdco = 1 THEN 1 ELSE 0 END),
            (7, 'OPEN_BREACH', CASE WHEN @breach = 'OPEN' THEN 1 ELSE 0 END),
            (8, 'BREACH_WAIVER_REQUESTED', CASE WHEN @breach = 'WAIVER_REQUESTED' THEN 1 ELSE 0 END),
            (9, 'FLOW_SHORTFALL', CASE WHEN @flowShortfall = 1 THEN 1 ELSE 0 END),
            (10, 'HALF_CAPITAL_LOST_CURED', CASE WHEN @lost = 1 AND @cured = 1 THEN 1 ELSE 0 END),
            (11, 'RELATED_PARTY_EXPOSURE', CAST(@relOn AS INT)),
            (12, 'LIQUIDITY_SGL4', CASE WHEN @sgl = 'SGL-4' THEN 1 ELSE 0 END),
            (13, 'LIQUIDITY_SEVERE', CASE WHEN @sgl = 'SGL-4' AND (@lcState = 'WORST' OR (@lcState = 'COMPUTED' AND @lcValue < @severe)) THEN 1 ELSE 0 END),
            (14, 'CUSTOMER_CONCENTRATION', CAST(@concOn AS INT)),
            (15, 'CUSTOMER_CONCENTRATION_HIGH', CASE WHEN @concOn = 1 AND @tcValue > (SELECT P FROM @P WHERE RuleCode = 'CUSTOMER_CONCENTRATION_HIGH') THEN 1 ELSE 0 END),
            (16, 'INFORMATION_RISK', CASE WHEN @completeness < (SELECT P FROM @P WHERE RuleCode = 'INFORMATION_RISK') THEN 1 ELSE 0 END),
            (17, 'INFORMATION_RISK_SEVERE', CASE WHEN @completeness < (SELECT P FROM @P WHERE RuleCode = 'INFORMATION_RISK_SEVERE') THEN 1 ELSE 0 END),
            (18, 'RELATED_PARTY_DRAIN', CASE WHEN @drain > 0 AND (@ffo <= 0 OR @drain > (SELECT P FROM @P WHERE RuleCode = 'RELATED_PARTY_DRAIN') / 100 * @ffo) AND @relOn = 0
                                             THEN 1 ELSE 0 END),
            (19, 'FX_UNHEDGED', CASE WHEN (@fxState = 'WORST' OR (@fxState = 'COMPUTED' AND @fxValue > (SELECT P FROM @P WHERE RuleCode = 'FX_UNHEDGED')))
                                          AND NOT (ISNULL(@DERIVATIVES_NOTIONAL, 0) >= 0.5 * @fxOpen) THEN 1 ELSE 0 END),
            (20, 'BUREAU_CURRENT_DEFAULT', CASE WHEN @bu = 1 AND @buDefault = 1 THEN 1 ELSE 0 END),
            (21, 'BUREAU_DPD90_12M', CASE WHEN @bu = 1 AND @buDpd12 >= 90 AND @buDefault = 0 THEN 1 ELSE 0 END),
            (22, 'BUREAU_DPD60_89', CASE WHEN @bu = 1 AND @buDpd12 >= 60 AND @buDpd12 < 90 THEN 1 ELSE 0 END),
            (23, 'BUREAU_DPD30_59', CASE WHEN @bu = 1 AND @buDpd12 >= 30 AND @buDpd12 < 60 THEN 1 ELSE 0 END),
            (24, 'BUREAU_DEFAULT_24M', CASE WHEN @bu = 1 AND @buDefaults24 > 0 AND @buDefault = 0 AND @buDpd12 < 90 THEN 1 ELSE 0 END),
            (25, 'BUREAU_BOUNCED_CHEQUES_SEVERE', CASE WHEN @bu = 1 AND (@buBouncedN >= 6 OR (@REVENUE > 0 AND @buBouncedAmt > 0.02 * @REVENUE)) THEN 1 ELSE 0 END),
            (26, 'BUREAU_BOUNCED_CHEQUES', CASE WHEN @bu = 1 AND NOT (@buBouncedN >= 6 OR (@REVENUE > 0 AND @buBouncedAmt > 0.02 * @REVENUE))
                                                     AND (@buBouncedN >= 3 OR (@REVENUE > 0 AND @buBouncedAmt > 0.005 * @REVENUE)) THEN 1 ELSE 0 END),
            (27, 'BUREAU_JUDGMENTS_MATERIAL', CASE WHEN @bu = 1 AND @buJudg > 0 AND @adjTnw > 0 AND @buJudg > 0.10 * @adjTnw THEN 1 ELSE 0 END),
            (28, 'BUREAU_JUDGMENTS', CASE WHEN @bu = 1 AND @buJudg > 0 AND NOT (@adjTnw > 0 AND @buJudg > 0.10 * @adjTnw)
                                               AND ((@adjTnw > 0 AND @buJudg > 0.02 * @adjTnw) OR (@adjTnw <= 0 AND @buJudg > 1000000)) THEN 1 ELSE 0 END),
            (29, 'BUREAU_RESTRUCTURED', CASE WHEN @bu = 1 AND @buRestructured = 1 THEN 1 ELSE 0 END),
            (30, 'BUREAU_INQUIRIES', CASE WHEN @bu = 1 AND @buInquiries > 6 THEN 1 ELSE 0 END),
            (31, 'BUREAU_LENDERS_NOT_ON_PLATFORM', CASE WHEN @bu = 1 AND (@buLenders >= ISNULL(@pfLenders, 0) + 2 OR (ISNULL(@pfLimits, 0) <> 0 AND @buLimits > 1.25 * @pfLimits))
                                                        THEN 1 ELSE 0 END),
            (32, 'BUREAU_HIDDEN_DEBT', CASE WHEN @hidden > 0 THEN 1 ELSE 0 END),
            (33, 'RESILIENCE', CASE WHEN @resilienceNotch = 1 THEN 1 ELSE 0 END),
            (34, 'HALF_CAPITAL_LOST', CASE WHEN @lost = 1 AND @cured = 0 THEN 1 ELSE 0 END),
            (35, 'GOING_CONCERN', CASE WHEN @goingConcern = 1 THEN 1 ELSE 0 END),
            (36, 'NEGATIVE_EQUITY', CASE WHEN @quasi <= 0 THEN 1 ELSE 0 END),
            (37, 'SIZE_CEILING', CASE WHEN @rsState = 'WORST' OR (@rsState = 'COMPUTED' AND @rsValue < (SELECT P FROM @P WHERE RuleCode = 'SIZE_CEILING')) THEN 1 ELSE 0 END),
            (38, 'SIZE_CEILING_MID', CASE WHEN @rsState = 'WORST' OR (@rsState = 'COMPUTED' AND @rsValue < (SELECT P FROM @P WHERE RuleCode = 'SIZE_CEILING_MID')) THEN 1 ELSE 0 END),
            (39, 'SIZE_CEILING_SMALL', CASE WHEN @rsState = 'WORST' OR (@rsState = 'COMPUTED' AND @rsValue < (SELECT P FROM @P WHERE RuleCode = 'SIZE_CEILING_SMALL')) THEN 1 ELSE 0 END),
            (40, 'LIQUIDITY_SGL4_CAP', CASE WHEN @sgl = 'SGL-4' THEN 1 ELSE 0 END),
            (41, 'SECTOR_CEILING', 1),
            (42, 'INDUSTRY_CEILING', CASE WHEN EXISTS (SELECT 1 FROM fin.IndustryProfile WHERE IndustryId = @industry AND CeilingGradeId IS NOT NULL) THEN 1 ELSE 0 END),
            (43, 'AUDIT_ADVERSE', CASE WHEN @opinion IN ('ADVERSE','DISCLAIMER') THEN 1 ELSE 0 END),
            (44, 'SOVEREIGN_CEILING', 1)
        ) AS v (Ord, RuleCode, Applies)
        WHERE v.Applies = 1 AND EXISTS (SELECT 1 FROM @P AS p WHERE p.RuleCode = v.RuleCode);
        INSERT #crA (Ord, RuleCode, Stage, Notches, CapNotch, ParamValue)
        SELECT ap.Ord, ap.RuleCode, a.Stage, a.Notches,
               CASE WHEN ap.RuleCode = 'INDUSTRY_CEILING' THEN (SELECT g.NotchNo FROM fin.IndustryProfile AS ip JOIN fin.RatingGrade AS g ON g.RatingGradeId = ip.CeilingGradeId
                                                                 WHERE ip.IndustryId = @industry)
                    ELSE g.NotchNo END, a.ParamValue
        FROM @app AS ap
        JOIN fin.ScorecardAdjustment AS a ON a.ScorecardId = @card AND a.RuleCode = ap.RuleCode
        LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = a.CapGradeId;
        SET @rawN = ISNULL((SELECT SUM(Notches) FROM #crA WHERE Stage = 'NOTCH'), 0);
        SET @notches = CASE WHEN @rawN < @notchFloor THEN @notchFloor ELSE @rawN END;
        SET @capS = ISNULL((SELECT MAX(CapNotch) FROM #crA WHERE Stage = 'STANDALONE'), 1);
        SET @capA = ISNULL((SELECT MAX(CapNotch) FROM #crA WHERE Stage = 'ABSOLUTE'), 1);
        SET @n1 = @n0 - @notches;
        SET @n2 = CASE WHEN @n1 < @capS THEN @capS ELSE @n1 END;
        SET @n3 = CASE WHEN @support IS NULL THEN @n2
                       ELSE CASE WHEN @n2 < CASE WHEN @n2 - @support > @parentNotch THEN @n2 - @support ELSE @parentNotch END THEN @n2
                                 ELSE CASE WHEN @n2 - @support > @parentNotch THEN @n2 - @support ELSE @parentNotch END END END;
        SET @n4 = @n3 - ISNULL(@override, 0);
        SET @n5 = CASE WHEN @n4 < @capA THEN @capA ELSE @n4 END;
        SET @n5 = CASE WHEN @n5 > 20 THEN 20 WHEN @n5 < 1 THEN 1 ELSE @n5 END;
    END

    -- The facility grade: the loss given default of the company's facilities after the collateral haircuts and the
    -- unsecured recovery, its band moving the obligor grade, guarantors lifting it (docs/35 section 10).
    DECLARE @facLgd FLOAT, @facBand VARCHAR(4), @facNotch INT, @facUr FLOAT;
    IF @state = 'RATED' AND (EXISTS (SELECT 1 FROM #crColl) OR ISNULL(@pfLimits, 0) <> 0) AND @expo > 0
    BEGIN
        DECLARE @sec FLOAT = LEAST(@expo, ISNULL(@collRec, 0));
        SET @facUr = CASE WHEN @ASSETS_PLEDGED IS NOT NULL AND @TOTAL_ASSETS > 0 THEN GREATEST(@urFloor, @urPct * (1 - @ASSETS_PLEDGED / @TOTAL_ASSETS))
                          WHEN @DEBT_SECURED IS NOT NULL AND @debt > 0 THEN GREATEST(@urFloor, @urPct * (1 - @DEBT_SECURED / @debt))
                          ELSE @urPct END;
        SET @facLgd = 100 * (1 - (@sec + @facUr / 100 * (@expo - @sec)) / @expo);
        DECLARE @up INT, @gup INT = 0;
        SELECT TOP (1) @facBand = ParamKey, @up = CAST(Value2 AS INT) FROM @prm WHERE GroupCode = 'LGD_BAND' AND @facLgd <= Value + 1e-9 ORDER BY Value;
        IF @guLiquid IS NOT NULL
            SELECT @gup = ISNULL(MAX(CAST(c.Value2 AS INT)), 0)
            FROM @prm AS c JOIN @prm AS l ON l.GroupCode = 'CARD' AND l.ParamKey = REPLACE(c.ParamKey, '_COVERAGE', '_LEVERAGE')
            WHERE c.GroupCode = 'CARD' AND c.ParamKey LIKE 'GUARANTOR%[_]COVERAGE' AND @guLiquid / @expo >= c.Value AND @guMaxLev <= l.Value;
        DECLARE @tot INT = @up + @gup;
        IF @tot > 0
        BEGIN
            SET @tot = CASE WHEN @tot > CASE WHEN @n5 < 19 THEN @lgdMaxUp ELSE @lgdMaxUpNear END THEN CASE WHEN @n5 < 19 THEN @lgdMaxUp ELSE @lgdMaxUpNear END ELSE @tot END;
            SET @facNotch = CASE WHEN @n5 - @tot < @lgdBestNotch THEN @lgdBestNotch ELSE @n5 - @tot END;
        END
        ELSE
            SET @facNotch = CASE WHEN @n5 - @tot > 20 THEN 20 ELSE @n5 - @tot END;
    END

    INSERT #crS (State, Coverage, FinancialScore, FinancialNotch, WeightedScore, IndicatedNotch, NotchesRaw, Notches, CapStandalone, CapAbsolute,
                 StandaloneNotch, SupportedNotch, OverriddenNotch, FinalNotch, Liquidity, Completeness, FacilityLgd, FacilityBand, FacilityNotch, UnsecuredRecovery,
                 AdjustedDebt, AdjustedTnw, RealisableNetWorth, Ebitda, Revenue, Inventory)
    VALUES (@state, @coverage, @finScore, @finNotch, @agg, @n0, @rawN, @notches, @capS, @capA, CASE WHEN @n2 > 20 THEN 20 ELSE @n2 END, @n3, @n4, @n5, @sgl, @completeness,
            @facLgd, @facBand, @facNotch, @facUr, @debt, @adjTnw, @real - @adjTl, @ebitdaA, @REVENUE, @INVENTORY);
END;
GO

/* The balance sheet totals of #crL rebuilt from their lines, in the order a total can use the one before it; with
   @Income = 1 the income statement totals too (a scenario changes the income lines), else they stay as reported
   (credit_reference.rebuild_totals and stress_lines). */
CREATE OR ALTER PROCEDURE fin.usp_CreditRebuildTotals @Income BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t VARCHAR(40), @i INT = 1;
    DECLARE @order TABLE (n INT PRIMARY KEY, Code VARCHAR(40) COLLATE DATABASE_DEFAULT, IsIncome BIT);
    INSERT @order VALUES (1, 'TOTAL_CA', 0), (2, 'TOTAL_ASSETS', 0), (3, 'TOTAL_CL', 0), (4, 'TOTAL_LIABS', 0), (5, 'TOTAL_EQUITY', 0),
                         (6, 'GROSS_PROFIT', 1), (7, 'OPERATING_PROFIT', 1), (8, 'EBITDA', 1), (9, 'NET_PROFIT', 1);
    WHILE @i <= 9
    BEGIN
        SELECT @t = Code FROM @order WHERE n = @i AND (IsIncome = 0 OR @Income = 1);
        IF @t IS NOT NULL
        BEGIN
            DECLARE @v FLOAT = (SELECT SUM(c.Sign * ISNULL(l.Amount, 0)) FROM fin.StandardLineTotal AS c JOIN #crL AS l ON l.Code = c.ComponentCode
                                WHERE c.TotalCode = @t);
            DELETE #crL WHERE Code = @t;
            INSERT #crL (Code, Amount) VALUES (@t, ISNULL(@v, 0));
        END;
        SET @t = NULL; SET @i += 1;
    END;
END;
GO

/* A remedy's steps on #crL (credit_reference.apply_steps): each step moves its reference line (read before the remedy,
   from @Base) times its share from the lines it decreases to the lines it increases, capped by the smallest balance
   sheet LINE it decreases; the balance sheet totals are rebuilt and the income statement totals stay. The amount
   moved is returned. */
CREATE OR ALTER PROCEDURE fin.usp_CreditApplyRemedy @RemedyId INT, @Moved FLOAT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @Moved = 0;
    DECLARE @base TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    INSERT @base SELECT Code, Amount FROM #crL;
    DECLARE @n INT = 1, @last INT = (SELECT MAX(StepNo) FROM fin.CreditRemedyStep WHERE RemedyId = @RemedyId);
    WHILE @n <= ISNULL(@last, 0)
    BEGIN
        DECLARE @amt FLOAT = NULL;
        DECLARE @dec TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY);
        DECLARE @inc TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY);
        DELETE @dec; DELETE @inc;
        SELECT @amt = ISNULL(b.Amount, 0) * st.Pct / 100
        FROM fin.CreditRemedyStep AS st LEFT JOIN @base AS b ON b.Code = st.RefLine
        WHERE st.RemedyId = @RemedyId AND st.StepNo = @n;
        IF @amt IS NOT NULL
        BEGIN
            INSERT @dec SELECT DISTINCT v.Code FROM fin.CreditRemedyStep AS st CROSS APPLY (VALUES (st.Dec1), (st.Dec2), (st.Dec3)) AS v (Code)
            WHERE st.RemedyId = @RemedyId AND st.StepNo = @n AND v.Code IS NOT NULL;
            INSERT @inc SELECT DISTINCT v.Code FROM fin.CreditRemedyStep AS st CROSS APPLY (VALUES (st.Inc1), (st.Inc2), (st.Inc3)) AS v (Code)
            WHERE st.RemedyId = @RemedyId AND st.StepNo = @n AND v.Code IS NOT NULL;
            DECLARE @cap FLOAT = (SELECT MIN(CASE WHEN ISNULL(l.Amount, 0) > 0 THEN l.Amount ELSE 0 END)
                                  FROM @dec AS d JOIN fin.StandardLine AS sl ON sl.Code = d.Code AND sl.LineKind = 'LINE' AND sl.Section LIKE 'BS%'
                                  LEFT JOIN #crL AS l ON l.Code = d.Code);
            IF @cap IS NOT NULL AND @cap < @amt SET @amt = @cap;
            IF @amt > 0
            BEGIN
                UPDATE l SET Amount = ISNULL(l.Amount, 0) - @amt FROM #crL AS l JOIN @dec AS d ON d.Code = l.Code;
                INSERT #crL (Code, Amount)
                SELECT d.Code, -@amt FROM @dec AS d JOIN fin.StandardLine AS sl ON sl.Code = d.Code AND sl.LineKind = 'LINE'
                WHERE NOT EXISTS (SELECT 1 FROM #crL AS l WHERE l.Code = d.Code);
                UPDATE l SET Amount = ISNULL(l.Amount, 0) + @amt FROM #crL AS l JOIN @inc AS i ON i.Code = l.Code;
                INSERT #crL (Code, Amount) SELECT i.Code, @amt FROM @inc AS i WHERE NOT EXISTS (SELECT 1 FROM #crL AS l WHERE l.Code = i.Code);
                SET @Moved += @amt;
            END;
        END;
        SET @n += 1;
    END;
    EXEC fin.usp_CreditRebuildTotals @Income = 0;
END;
GO

/* The statement of #crL under a scenario of the company's activity (credit_reference.scenario_params and stress_lines,
   docs/35 section 13): revenue and gross margin change, the variable part of the operating expenses follows revenue,
   floating debt costs more, receivables stretch and private aged receivables are lost, inventory is written down; the
   cash effect goes to cash and then to short-term loans, the losses to retained earnings. The product lines of #crMix
   give the revenue change and the inventory write-down when the company has them. */
CREATE OR ALTER PROCEDURE fin.usp_CreditStressLines @Scenario VARCHAR(20), @Withdrawn FLOAT OUTPUT, @ArLoss FLOAT OUTPUT, @InvWd FLOAT OUTPUT,
                                                     @Dfin FLOAT OUTPUT, @Stretch FLOAT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @card INT, @industry INT;
    SELECT @card = ScorecardId, @industry = IndustryId FROM #crX;
    -- the parameters: the activity's, the revenue change and inventory write-down from the product mix
    DECLARE @revPct FLOAT, @gmPp FLOAT, @dso FLOAT, @rateBp FLOAT, @privLoss FLOAT, @invWdPct FLOAT;
    SELECT @revPct = RevenuePct, @gmPp = GrossMarginPp, @dso = DsoDays, @Withdrawn = StLinesWithdrawnPct, @rateBp = RateBp, @privLoss = PrivateArLossPct
    FROM fin.IndustryScenario WHERE IndustryId = @industry AND Scenario = @Scenario;
    IF EXISTS (SELECT 1 FROM #crMix)
    BEGIN
        DECLARE @rw FLOAT = (SELECT SUM(RevenueSharePct) FROM #crMix), @iw FLOAT = (SELECT SUM(InventorySharePct) FROM #crMix);
        SELECT @revPct = SUM(CASE @Scenario WHEN 'STAGNANT_MARKET' THEN pc.RevStagnantPct ELSE pc.RevCrisisPct END * m.RevenueSharePct) / @rw,
               @invWdPct = SUM((pc.InvValueNormalPct - CASE @Scenario WHEN 'STAGNANT_MARKET' THEN pc.InvValueStagnantPct ELSE pc.InvValueCrisisPct END)
                               * m.InventorySharePct) / CASE WHEN @iw = 0 THEN 1 ELSE @iw END
        FROM #crMix AS m JOIN fin.ProductCategory AS pc ON pc.ProductCategoryId = m.ProductCategoryId;
        IF @Scenario = 'FINANCIAL_CRISIS'
        BEGIN
            DECLARE @mixDso FLOAT = (SELECT SUM(pc.CrisisExtraDso * m.RevenueSharePct) / @rw FROM #crMix AS m
                                     JOIN fin.ProductCategory AS pc ON pc.ProductCategoryId = m.ProductCategoryId);
            IF @mixDso > @dso SET @dso = @mixDso;
        END;
    END
    ELSE
        SELECT @invWdPct = AVG(pc.InvValueNormalPct - CASE @Scenario WHEN 'STAGNANT_MARKET' THEN pc.InvValueStagnantPct ELSE pc.InvValueCrisisPct END)
        FROM fin.IndustryProfile AS ip
        CROSS APPLY STRING_SPLIT(ip.ProductCategories, ',') AS c
        JOIN fin.ProductCategory AS pc ON pc.Code = c.value
        WHERE ip.IndustryId = @industry;
    -- the lines as the reference's Stmt reads them: a LINE absent is zero, another line absent or an OF_WHICH above its
    -- parent unknown
    DECLARE @d TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT, Kind VARCHAR(10), V FLOAT);
    INSERT @d (Code, Amount, Kind, V)
    SELECT sl.Code, l.Amount, sl.LineKind,
           CASE WHEN l.Code IS NULL OR l.Amount IS NULL THEN CASE WHEN sl.LineKind = 'LINE' THEN 0.0 END
                WHEN sl.LineKind = 'OF_WHICH' AND par.Amount IS NOT NULL AND l.Amount > par.Amount + 1 THEN NULL
                ELSE l.Amount END
    FROM fin.StandardLine AS sl
    LEFT JOIN #crL AS l ON l.Code = sl.Code
    OUTER APPLY (SELECT CASE WHEN sl.ParentCode = 'AR_GROSS' AND NOT EXISTS (SELECT 1 FROM #crL WHERE Code = 'AR_GROSS' AND Amount IS NOT NULL)
                             THEN (SELECT a.Amount FROM #crL AS a WHERE a.Code = 'AR') + ISNULL((SELECT e.Amount FROM #crL AS e WHERE e.Code = 'AR_ECL_ALLOWANCE'), 0)
                             ELSE (SELECT p.Amount FROM #crL AS p WHERE p.Code = sl.ParentCode) END AS Amount) AS par;
    DECLARE @REVENUE FLOAT, @COGS FLOAT, @OPEX FLOAT, @GA FLOAT, @SD FLOAT, @RENT FLOAT, @FLOAT FLOAT, @ST FLOAT, @BA FLOAT, @CPLTD FLOAT, @LT FLOAT,
            @AR FLOAT, @A181 FLOAT, @A365 FLOAT, @A365G FLOAT, @ECL FLOAT, @ARGOV FLOAT, @INV FLOAT, @FIN FLOAT, @OI FLOAT, @IP FLOAT, @CFO FLOAT,
            @CFOWC FLOAT, @CASH FLOAT, @RESTR FLOAT, @RE FLOAT;
    SELECT @REVENUE = MAX(CASE Code WHEN 'REVENUE' THEN V END), @COGS = MAX(CASE Code WHEN 'COGS' THEN V END), @OPEX = MAX(CASE Code WHEN 'OPEX' THEN V END),
           @GA = MAX(CASE Code WHEN 'GENERAL_ADMIN' THEN V END), @SD = MAX(CASE Code WHEN 'SELLING_DISTRIBUTION' THEN V END),
           @RENT = MAX(CASE Code WHEN 'RENT_SHORT_TERM' THEN V END), @FLOAT = MAX(CASE Code WHEN 'DEBT_FLOATING' THEN V END),
           @ST = MAX(CASE Code WHEN 'ST_LOANS' THEN V END), @BA = MAX(CASE Code WHEN 'BANK_ACCEPTANCES' THEN V END),
           @CPLTD = MAX(CASE Code WHEN 'CURRENT_PORTION_LTD' THEN V END), @LT = MAX(CASE Code WHEN 'LT_LOANS' THEN V END),
           @AR = MAX(CASE Code WHEN 'AR' THEN V END), @A181 = MAX(CASE Code WHEN 'AR_AGE_181_365' THEN V END),
           @A365 = MAX(CASE Code WHEN 'AR_AGE_OVER_365' THEN V END), @A365G = MAX(CASE Code WHEN 'AR_AGE_OVER_365_GOV' THEN V END),
           @ECL = MAX(CASE Code WHEN 'AR_ECL_ALLOWANCE' THEN V END), @ARGOV = MAX(CASE Code WHEN 'AR_GOVERNMENT' THEN V END),
           @INV = MAX(CASE Code WHEN 'INVENTORY' THEN V END), @FIN = MAX(CASE Code WHEN 'FINANCE_COSTS' THEN V END),
           @OI = MAX(CASE Code WHEN 'OTHER_INCOME' THEN V END), @IP = MAX(CASE Code WHEN 'INTEREST_PAID' THEN V END),
           @CFO = MAX(CASE Code WHEN 'OP_CASH_FLOW' THEN V END), @CFOWC = MAX(CASE Code WHEN 'CFO_BEFORE_WC' THEN V END),
           @CASH = MAX(CASE Code WHEN 'CASH' THEN V END), @RESTR = MAX(CASE Code WHEN 'CASH_RESTRICTED' THEN V END),
           @RE = MAX(CASE Code WHEN 'RETAINED_EARNINGS' THEN V END)
    FROM @d;
    DECLARE @staffFixed FLOAT, @sellFixed FLOAT, @fbFixed FLOAT;
    SELECT @sellFixed = MAX(CASE WHEN ParamKey = 'selling_fixed_pct' THEN Value END), @fbFixed = MAX(CASE WHEN ParamKey = 'fallback_opex_fixed_pct' THEN Value END)
    FROM fin.ScorecardParameter WHERE ScorecardId = @card AND GroupCode = 'FIXED_COST';
    DECLARE @gm FLOAT = (@REVENUE - @COGS) / NULLIF(@REVENUE, 0);
    DECLARE @rev2 FLOAT = @REVENUE * (1 + @revPct / 100);
    DECLARE @gp2 FLOAT = @rev2 * (@gm + @gmPp / 100);
    DECLARE @opexFixed FLOAT = CASE WHEN @GA IS NULL AND @SD IS NULL THEN @fbFixed / 100 * @OPEX
                                    ELSE LEAST(@OPEX, ISNULL(@GA, 0) + @sellFixed / 100 * ISNULL(@SD, 0) + ISNULL(@RENT, 0)) END;
    DECLARE @opex2 FLOAT = @opexFixed + (@OPEX - @opexFixed) * @rev2 / @REVENUE;
    DECLARE @floating FLOAT = CASE WHEN @FLOAT IS NOT NULL THEN @FLOAT ELSE 0.6 * (@ST + @BA + @CPLTD + @LT) END;
    SET @Dfin = @floating * @rateBp / 10000;
    SET @Stretch = @dso * @rev2 / 365 + (@AR / @REVENUE) * (@rev2 - @REVENUE);
    DECLARE @priv180 FLOAT = CASE WHEN @A181 IS NOT NULL AND @A365 IS NOT NULL THEN GREATEST(0.0, @A181 + @A365 - ISNULL(@A365G, 0) - ISNULL(@ECL, 0))
                                  ELSE 0.10 * GREATEST(0.0, @AR - ISNULL(@ARGOV, 0)) END;
    SET @ArLoss = @priv180 * @privLoss / 100;
    SET @InvWd = @INV * @invWdPct / 100;
    DECLARE @dEbitda FLOAT = (@gp2 - @opex2) - (@REVENUE - @COGS - @OPEX);
    DECLARE @flow FLOAT = @dEbitda - @Dfin - @Stretch;
    -- the new lines: the totals go and are rebuilt
    DELETE l FROM #crL AS l JOIN fin.StandardLine AS sl ON sl.Code = l.Code WHERE sl.LineKind = 'TOTAL';
    DECLARE @set TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    INSERT @set VALUES ('REVENUE', @rev2), ('COGS', @rev2 - @gp2), ('OPEX', @opex2), ('FINANCE_COSTS', @FIN + @Dfin), ('OTHER_INCOME', @OI - @ArLoss - @InvWd),
                       ('AR', @AR + @Stretch - @ArLoss), ('INVENTORY', @INV - @InvWd);
    IF @IP <> 0 INSERT @set VALUES ('INTEREST_PAID', @IP + @Dfin);
    IF @CFO <> 0 OR @CFOWC <> 0
    BEGIN
        INSERT @set VALUES ('OP_CASH_FLOW', @CFO + @flow);
        IF @CFOWC <> 0 INSERT @set VALUES ('CFO_BEFORE_WC', @CFOWC + @dEbitda - @Dfin);
    END;
    DECLARE @cash2 FLOAT = @CASH + @flow, @stAdd FLOAT = 0, @free FLOAT = @CASH - ISNULL(@RESTR, 0);
    IF @free + @flow < 0
        SELECT @stAdd = -(@free + @flow), @cash2 = ISNULL(@RESTR, 0);
    INSERT @set VALUES ('CASH', @cash2), ('ST_LOANS', @ST + @stAdd), ('RETAINED_EARNINGS', @RE + @dEbitda - @Dfin - @ArLoss - @InvWd);
    MERGE #crL AS t USING @set AS s ON t.Code = s.Code
    WHEN MATCHED THEN UPDATE SET Amount = s.Amount
    WHEN NOT MATCHED THEN INSERT (Code, Amount) VALUES (s.Code, s.Amount);
    -- the receivables ageing takes the stretch; the inventory breakdown follows the write-down; the revenue breakdowns
    -- follow revenue
    IF EXISTS (SELECT 1 FROM #crL WHERE Code = 'AR_AGE_91_180')
    BEGIN
        IF @Stretch >= 0
            UPDATE #crL SET Amount = Amount + @Stretch WHERE Code = 'AR_AGE_91_180';
        ELSE
            UPDATE #crL SET Amount = GREATEST(0.0, Amount + @Stretch) WHERE Code = 'AR_AGE_0_90';
    END;
    IF EXISTS (SELECT 1 FROM #crL WHERE Code = 'AR_GROSS') AND EXISTS (SELECT 1 FROM #crL WHERE Code = 'AR_AGE_0_90')
        UPDATE #crL SET Amount = GREATEST(Amount, (SELECT SUM(ISNULL(Amount, 0)) FROM #crL WHERE Code IN ('AR_AGE_0_90','AR_AGE_91_180','AR_AGE_181_365','AR_AGE_OVER_365')))
        WHERE Code = 'AR_GROSS';
    DECLARE @inv2 FLOAT = @INV - @InvWd;
    UPDATE #crL SET Amount = LEAST(@inv2, Amount) WHERE Code = 'INV_SLOW_MOVING';
    UPDATE #crL SET Amount = CASE WHEN @INV <> 0 THEN Amount * @inv2 / @INV ELSE 0 END WHERE Code IN ('INV_FINISHED','INV_RAW','INV_WIP','INV_IN_TRANSIT');
    UPDATE #crL SET Amount = Amount * @rev2 / @REVENUE WHERE Code IN ('REV_TOP5','REV_TOP_CUSTOMER','REV_GOVERNMENT','REV_CASH','REV_EXPORT');
    EXEC fin.usp_CreditRebuildTotals @Income = 1;
END;
GO

/* The inverse of the grid score between the caps: the value a grid gives at a score (for the triggers). */
CREATE OR ALTER FUNCTION fin.fn_CreditGridValue (@s FLOAT, @b0 FLOAT, @b1 FLOAT, @b2 FLOAT, @b3 FLOAT, @b4 FLOAT, @b5 FLOAT, @b6 FLOAT, @b7 FLOAT, @b8 FLOAT)
RETURNS TABLE
AS RETURN
SELECT CASE WHEN x.s <= 1.5 THEN @b0 + (x.s - 0.5) / 1 * (@b1 - @b0)
            WHEN x.s <= 4.5 THEN @b1 + (x.s - 1.5) / 3 * (@b2 - @b1)
            WHEN x.s <= 7.5 THEN @b2 + (x.s - 4.5) / 3 * (@b3 - @b2)
            WHEN x.s <= 10.5 THEN @b3 + (x.s - 7.5) / 3 * (@b4 - @b3)
            WHEN x.s <= 13.5 THEN @b4 + (x.s - 10.5) / 3 * (@b5 - @b4)
            WHEN x.s <= 16.5 THEN @b5 + (x.s - 13.5) / 3 * (@b6 - @b5)
            WHEN x.s <= 19.5 THEN @b6 + (x.s - 16.5) / 3 * (@b7 - @b6)
            ELSE @b7 + (x.s - 19.5) / 1 * (@b8 - @b7) END AS Value
FROM (SELECT CASE WHEN @s < 0.5 THEN 0.5 WHEN @s > 20.5 THEN 20.5 ELSE @s END AS s) AS x;
GO

/* The strengthening plans (credit_reference.plans, docs/35 section 12): each package applies its remedies, among those
   #evRem proposes with an amount or evidence, one after another to the pro-forma statement before, the whole core
   running again after each; each best plan picks at every step the remedy that improves the grade most (then the
   weighted score) and stops when none improves the grade, or the score by @MinGain, or after @MaxSteps. A later best
   plan is kept only when it reaches a better grade than an earlier one. The balance sheet's gap is checked at every
   step against the statement's own. #crL holds the statement and #crX its context on entry and on exit. */
CREATE OR ALTER PROCEDURE fin.usp_CreditPlans @BaseNotch INT, @BaseScore FLOAT, @MaxSteps INT, @MinGain FLOAT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @base TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    INSERT @base SELECT Code, Amount FROM #crL;
    SELECT * INTO #plX0 FROM #crX;
    EXEC fin.usp_CreditRebuildTotals @Income = 0;
    DECLARE @baseGap FLOAT = (SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY'));
    -- the candidates, in the remedies' order
    DECLARE @cand TABLE (Ord INT PRIMARY KEY, RemedyId INT NOT NULL, Funding VARCHAR(20) COLLATE DATABASE_DEFAULT, SetsEvidence VARCHAR(30) COLLATE DATABASE_DEFAULT,
                         HasSteps BIT);
    INSERT @cand SELECT r.SortOrder, r.CreditRemedyId, r.Funding, r.SetsEvidence,
                        CASE WHEN EXISTS (SELECT 1 FROM fin.CreditRemedyStep AS st WHERE st.RemedyId = r.CreditRemedyId) THEN 1 ELSE 0 END
    FROM #evRem AS e JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = e.RemedyId WHERE e.Moved IS NOT NULL;
    -- a plan's state: its statement and evidence; a trial: the state after one more remedy
    DECLARE @st TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    DECLARE @try TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    DECLARE @best TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    DECLARE @sSub BIT, @sCap BIT, @sBreach VARCHAR(16), @sBape BIT, @tSub BIT, @tCap BIT, @tBreach VARCHAR(16), @tBape BIT;
    DECLARE @plan INT, @kind VARCHAR(10), @excl VARCHAR(100), @pord INT, @steps INT, @lastN INT, @lastS FLOAT, @maxGap FLOAT, @rid INT, @ord INT,
            @se VARCHAR(30), @hs BIT, @moved FLOAT, @bears BIT, @tN INT, @tS FLOAT, @tGap FLOAT, @bN INT, @bS FLOAT, @bRid INT, @bMoved FLOAT, @bGap FLOAT,
            @bOrd INT, @bSub BIT, @bCap BIT, @bBreach VARCHAR(16), @bBape BIT;
    DECLARE @optBest INT = NULL;
    DECLARE @used TABLE (RemedyId INT PRIMARY KEY);
    DECLARE pc CURSOR LOCAL FAST_FORWARD FOR SELECT StrengtheningPlanId, Kind, ExcludeFunding FROM fin.StrengtheningPlan WHERE IsActive = 1 ORDER BY SortOrder;
    OPEN pc; FETCH NEXT FROM pc INTO @plan, @kind, @excl;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE @st; INSERT @st SELECT Code, Amount FROM @base;
        SELECT @sSub = EvSub, @sCap = EvCap, @sBreach = Breach, @sBape = BreachAtPeriodEnd FROM #plX0;
        SELECT @steps = 0, @lastN = @BaseNotch, @lastS = @BaseScore, @maxGap = 0;
        DELETE @used;
        WHILE 1 = 1
        BEGIN
            -- the remedies to try at this step: the next member of a package, or every unused candidate of a best plan
            DECLARE @trial TABLE (Ord INT PRIMARY KEY, RemedyId INT);
            DELETE @trial;
            IF @kind = 'PACKAGE'
                INSERT @trial SELECT TOP (1) c.Ord, c.RemedyId FROM fin.StrengtheningPlanMember AS m JOIN @cand AS c ON c.RemedyId = m.RemedyId
                WHERE m.PlanId = @plan AND NOT EXISTS (SELECT 1 FROM @used AS u WHERE u.RemedyId = m.RemedyId) ORDER BY m.SortOrder;
            ELSE IF @steps < @MaxSteps
                INSERT @trial SELECT c.Ord, c.RemedyId FROM @cand AS c
                WHERE NOT EXISTS (SELECT 1 FROM @used AS u WHERE u.RemedyId = c.RemedyId)
                  AND (@excl IS NULL OR c.Funding NOT IN (SELECT value FROM STRING_SPLIT(@excl, ',')));
            IF NOT EXISTS (SELECT 1 FROM @trial) BREAK;
            SELECT @bRid = NULL, @bN = NULL, @bS = NULL;
            DECLARE tc CURSOR LOCAL FAST_FORWARD FOR SELECT Ord, RemedyId FROM @trial ORDER BY Ord;
            OPEN tc; FETCH NEXT FROM tc INTO @ord, @rid;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF @kind = 'PACKAGE' INSERT @used VALUES (@rid);   -- a package tries each member once
                SELECT @se = SetsEvidence, @hs = HasSteps FROM @cand WHERE RemedyId = @rid;
                DELETE #crL; INSERT #crL SELECT Code, Amount FROM @st;
                SET @bears = CASE WHEN @se = 'SUBORDINATION' AND ISNULL((SELECT Amount FROM @st WHERE Code = 'SHAREHOLDER_LOANS_SUB'), 0) > 0 AND @sSub = 0 THEN 1
                                  WHEN @se = 'CAPITAL_RESOLUTION' AND ISNULL((SELECT Amount FROM @st WHERE Code = 'CAPITAL_CONTRIBUTIONS'), 0) > 0 AND @sCap = 0 THEN 1
                                  WHEN @se = 'WAIVER_BEFORE_PERIOD_END' AND (@sBreach IS NOT NULL OR @sBape = 1) THEN 1 ELSE 0 END;
                SET @moved = 0;
                IF @hs = 1 EXEC fin.usp_CreditApplyRemedy @rid, @moved OUTPUT;
                IF @moved > 0 OR @bears = 1
                BEGIN
                    SELECT @tSub = CASE WHEN @se = 'SUBORDINATION' THEN 1 ELSE @sSub END, @tCap = CASE WHEN @se = 'CAPITAL_RESOLUTION' THEN 1 ELSE @sCap END,
                           @tBreach = CASE WHEN @se = 'WAIVER_BEFORE_PERIOD_END' THEN NULL ELSE @sBreach END,
                           @tBape = CASE WHEN @se = 'WAIVER_BEFORE_PERIOD_END' THEN 0 ELSE @sBape END;
                    DELETE @try; INSERT @try SELECT Code, Amount FROM #crL;
                    SET @tGap = ABS((SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL
                                     WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY')) - @baseGap);
                    DELETE #crX; INSERT #crX SELECT * FROM #plX0;
                    UPDATE #crX SET Proforma = 1, EvSub = @tSub, EvCap = @tCap, Breach = @tBreach, BreachAtPeriodEnd = @tBape;
                    EXEC fin.usp_CreditCore;
                    SELECT @tN = FinalNotch, @tS = WeightedScore FROM #crS;
                    IF @tN IS NOT NULL AND (@bRid IS NULL OR @tN < @bN OR (@tN = @bN AND @tS < @bS))
                    BEGIN
                        SELECT @bRid = @rid, @bN = @tN, @bS = @tS, @bMoved = @moved, @bGap = @tGap, @bOrd = @ord, @bSub = @tSub, @bCap = @tCap,
                               @bBreach = @tBreach, @bBape = @tBape;
                        DELETE @best; INSERT @best SELECT Code, Amount FROM @try;
                    END;
                END;
                FETCH NEXT FROM tc INTO @ord, @rid;
            END;
            CLOSE tc; DEALLOCATE tc;
            IF @kind = 'PACKAGE' AND @bRid IS NULL CONTINUE;   -- this member moved nothing: the next one
            IF @bRid IS NULL BREAK;
            IF @kind = 'OPTIMAL' AND NOT (@bN < @lastN OR @bS <= @lastS - @MinGain) BREAK;
            IF @kind = 'OPTIMAL' INSERT @used VALUES (@bRid);
            SET @steps += 1;
            INSERT #evPlanStep (PlanId, StepNo, RemedyId, Moved, FinalNotch, Score) VALUES (@plan, @steps, @bRid, @bMoved, @bN, @bS);
            SELECT @lastN = @bN, @lastS = @bS, @maxGap = CASE WHEN @bGap > @maxGap THEN @bGap ELSE @maxGap END,
                   @sSub = @bSub, @sCap = @bCap, @sBreach = @bBreach, @sBape = @bBape;
            DELETE @st; INSERT @st SELECT Code, Amount FROM @best;
        END;
        IF @steps > 0 AND (@kind = 'PACKAGE' OR @optBest IS NULL OR @lastN < @optBest)
            INSERT #evPlan (PlanId, StepCount, FinalNotch, FinalScore, NotchesGained, IsBalanced)
            VALUES (@plan, @steps, @lastN, @lastS, @BaseNotch - @lastN, CASE WHEN @maxGap <= 1.0 THEN 1 ELSE 0 END);
        ELSE IF @steps > 0
            DELETE #evPlanStep WHERE PlanId = @plan;
        IF @kind = 'OPTIMAL' AND @steps > 0 AND (@optBest IS NULL OR @lastN < @optBest) SET @optBest = @lastN;
        FETCH NEXT FROM pc INTO @plan, @kind, @excl;
    END;
    CLOSE pc; DEALLOCATE pc;
    DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
    DELETE #crX; INSERT #crX SELECT * FROM #plX0;
END;
GO

/* The evaluation (credit_reference.assess with its scenarios, remedies and plans): the core on the statement, on the two
   scenarios of the company's activity (the resilience overlay when the stagnant market costs too many notches), on the
   pro-forma statement of each remedy the findings call for and, when asked, on each step of the strengthening plans;
   then the triggers of the grade and the outlook. The caller creates the core's tables, #crMix (the product lines) and
   the result tables #evScen, #evRem, #evPlan, #evPlanStep, #evTrig and #evSum (as fin.usp_ComputeCreditAssessment and
   the tests do); at the end the core's tables hold the result on the statement itself. */
CREATE OR ALTER PROCEDURE fin.usp_CreditEvaluate @WithScenarios BIT = 1, @WithRemedies BIT = 1, @WithPlans BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DELETE #evScen; DELETE #evRem; DELETE #evPlan; DELETE #evPlanStep; DELETE #evTrig; DELETE #evSum;
    DECLARE @base TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT);
    INSERT @base SELECT Code, Amount FROM #crL;
    SELECT * INTO #crX0 FROM #crX;
    DECLARE @card INT, @industry INT, @resNotch BIT, @breach VARCHAR(16), @bape BIT, @evSub BIT, @evCap BIT, @hasPrior BIT;
    SELECT @card = ScorecardId, @industry = IndustryId, @resNotch = ResilienceNotch, @breach = Breach, @bape = BreachAtPeriodEnd, @evSub = EvSub,
           @evCap = EvCap, @hasPrior = HasPrior
    FROM #crX;
    DECLARE @prm TABLE (ParamKey VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value FLOAT);
    INSERT @prm SELECT ParamKey, Value FROM fin.ScorecardParameter WHERE ScorecardId = @card AND GroupCode = 'CARD';
    DECLARE @resP FLOAT = (SELECT ParamValue FROM fin.ScorecardAdjustment WHERE ScorecardId = @card AND RuleCode = 'RESILIENCE'),
            @maxSteps INT = (SELECT Value FROM @prm WHERE ParamKey = 'PLAN_MAX_STEPS'),
            @minGain FLOAT = (SELECT Value FROM @prm WHERE ParamKey = 'PLAN_MIN_GAIN'),
            @headroom FLOAT = (SELECT Value FROM @prm WHERE ParamKey = 'OUTLOOK_HEADROOM_PCT') / 100,
            @stagLoss INT = (SELECT Value FROM @prm WHERE ParamKey = 'OUTLOOK_STAGNANT_LOSS');

    -- the balance sheet's own gap (assets less liabilities and equity, the totals rebuilt from the lines): a pro-forma
    -- statement keeps it
    EXEC fin.usp_CreditRebuildTotals @Income = 0;
    DECLARE @baseGap FLOAT = (SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY'));
    DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
    EXEC fin.usp_CreditCore;
    DECLARE @state VARCHAR(20), @n5 INT, @agg FLOAT, @resilience VARCHAR(10) = NULL;
    SELECT @state = State, @n5 = FinalNotch, @agg = WeightedScore FROM #crS;

    -- the scenarios of the activity
    IF @state = 'RATED' AND @WithScenarios = 1 AND @industry IS NOT NULL AND ISNULL((SELECT Proforma FROM #crX0), 0) = 0
    BEGIN
        DECLARE @sc VARCHAR(20), @k INT = 1;
        WHILE @k <= 2
        BEGIN
            SET @sc = CASE @k WHEN 1 THEN 'STAGNANT_MARKET' ELSE 'FINANCIAL_CRISIS' END;
            DECLARE @wd FLOAT, @arLoss FLOAT, @invWd FLOAT, @dfin FLOAT, @stretch FLOAT;
            DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
            EXEC fin.usp_CreditStressLines @sc, @wd OUTPUT, @arLoss OUTPUT, @invWd OUTPUT, @dfin OUTPUT, @stretch OUTPUT;
            UPDATE #crX SET RolloverFactor = 1 - @wd / 100, Proforma = 1, ResilienceNotch = 0;
            EXEC fin.usp_CreditCore;
            INSERT #evScen (Scenario, State, FinalNotch, WeightedScore, Liquidity, NotchesLost, Revenue, Ebitda, Inventory, ArLoss, InventoryWritedown,
                            ExtraFinanceCost, ReceivablesStretch, BalanceGap)
            SELECT @sc, s.State, s.FinalNotch, s.WeightedScore, s.Liquidity, s.FinalNotch - @n5, (SELECT Amount FROM #crL WHERE Code = 'REVENUE'),
                   (SELECT Value FROM #crQ WHERE Code = 'EBITDA'), (SELECT Amount FROM #crL WHERE Code = 'INVENTORY'), @arLoss, @invWd, @dfin, @stretch,
                   (SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY')) - @baseGap
            FROM #crS AS s;
            DELETE #crX; INSERT #crX SELECT * FROM #crX0;
            SET @k += 1;
        END;
        DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
        DECLARE @lost INT = (SELECT NotchesLost FROM #evScen WHERE Scenario = 'STAGNANT_MARKET');
        IF @lost IS NOT NULL AND @lost > @resP AND @resNotch = 0
        BEGIN
            UPDATE #crX SET ResilienceNotch = 1;
            UPDATE #crX0 SET ResilienceNotch = 1;
            SET @resNotch = 1; SET @resilience = 'VULNERABLE';
            EXEC fin.usp_CreditCore;
            SELECT @state = State, @n5 = FinalNotch, @agg = WeightedScore FROM #crS;
        END
        ELSE
        BEGIN
            SET @resilience = CASE WHEN @lost IS NULL THEN NULL WHEN @lost <= 1 THEN 'RESILIENT' ELSE 'MODERATE' END;
            EXEC fin.usp_CreditCore;   -- the core's tables hold the statement's result again
        END;
    END;

    -- the remedies the findings call for, each with its pro-forma grade (credit_reference.remedies)
    IF @state = 'RATED' AND @WithRemedies = 1 AND ISNULL((SELECT Proforma FROM #crX0), 0) = 0
    BEGIN
        DECLARE @lv TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Lvl INT);
        INSERT @lv
        SELECT MetricCode, MAX(CASE Level WHEN 'LOW' THEN 1 WHEN 'MODERATE' THEN 2 WHEN 'ELEVATED' THEN 3 WHEN 'HIGH' THEN 4 WHEN 'CRITICAL' THEN 5 END)
        FROM #crI WHERE Level IN ('LOW','MODERATE','ELEVATED','HIGH','CRITICAL') GROUP BY MetricCode;
        DECLARE @applied TABLE (RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY);
        INSERT @applied SELECT RuleCode FROM #crA;
        DECLARE @rid INT, @rseq INT = 0, @hit VARCHAR(40), @hitLvl VARCHAR(12), @se VARCHAR(30), @moved FLOAT, @bears BIT, @hasSteps BIT;
        DECLARE rc CURSOR LOCAL FAST_FORWARD FOR SELECT CreditRemedyId FROM fin.CreditRemedy WHERE IsActive = 1 ORDER BY SortOrder;
        OPEN rc; FETCH NEXT FROM rc INTO @rid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @hit = NULL, @hitLvl = NULL;
            SELECT TOP (1) @hit = t.TriggerCode,
                   @hitLvl = CASE WHEN l.Lvl >= mn.Lvl THEN CASE l.Lvl WHEN 1 THEN 'LOW' WHEN 2 THEN 'MODERATE' WHEN 3 THEN 'ELEVATED' WHEN 4 THEN 'HIGH' ELSE 'CRITICAL' END
                                  ELSE 'ADJUSTMENT' END
            FROM fin.CreditRemedyTrigger AS t
            JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = t.RemedyId
            CROSS APPLY (SELECT CASE r.MinLevel WHEN 'MODERATE' THEN 2 WHEN 'ELEVATED' THEN 3 WHEN 'HIGH' THEN 4 ELSE 5 END AS Lvl) AS mn
            LEFT JOIN @lv AS l ON l.Code = t.TriggerCode
            WHERE t.RemedyId = @rid AND (l.Lvl >= mn.Lvl OR EXISTS (SELECT 1 FROM @applied AS a WHERE a.RuleCode = t.TriggerCode))
            ORDER BY t.SortOrder;
            IF @hit IS NOT NULL
            BEGIN
                SELECT @se = SetsEvidence FROM fin.CreditRemedy WHERE CreditRemedyId = @rid;
                SET @hasSteps = CASE WHEN EXISTS (SELECT 1 FROM fin.CreditRemedyStep WHERE RemedyId = @rid) THEN 1 ELSE 0 END;
                IF @hasSteps = 0 AND @se IS NULL
                BEGIN
                    SET @rseq += 1;
                    INSERT #evRem (SeqNo, RemedyId, TriggerCode, TriggerLevel, Moved, FinalNotch, WeightedScore, NotchesGained, BalanceGap)
                    VALUES (@rseq, @rid, @hit, @hitLvl, NULL, NULL, NULL, NULL, NULL);
                END
                ELSE
                BEGIN
                    DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
                    SET @moved = 0;
                    IF @hasSteps = 1 EXEC fin.usp_CreditApplyRemedy @rid, @moved OUTPUT;
                    SET @bears = CASE WHEN @se = 'SUBORDINATION' AND ISNULL((SELECT Amount FROM @base WHERE Code = 'SHAREHOLDER_LOANS_SUB'), 0) > 0 AND @evSub = 0 THEN 1
                                      WHEN @se = 'CAPITAL_RESOLUTION' AND ISNULL((SELECT Amount FROM @base WHERE Code = 'CAPITAL_CONTRIBUTIONS'), 0) > 0 AND @evCap = 0 THEN 1
                                      WHEN @se = 'WAIVER_BEFORE_PERIOD_END' AND (@breach IS NOT NULL OR @bape = 1) THEN 1 ELSE 0 END;
                    IF @moved > 0 OR @bears = 1
                    BEGIN
                        UPDATE #crX SET Proforma = 1, EvSub = CASE WHEN @se = 'SUBORDINATION' THEN 1 ELSE EvSub END,
                                        EvCap = CASE WHEN @se = 'CAPITAL_RESOLUTION' THEN 1 ELSE EvCap END,
                                        Breach = CASE WHEN @se = 'WAIVER_BEFORE_PERIOD_END' THEN NULL ELSE Breach END,
                                        BreachAtPeriodEnd = CASE WHEN @se = 'WAIVER_BEFORE_PERIOD_END' THEN 0 ELSE BreachAtPeriodEnd END;
                        EXEC fin.usp_CreditCore;
                        SET @rseq += 1;
                        INSERT #evRem (SeqNo, RemedyId, TriggerCode, TriggerLevel, Moved, FinalNotch, WeightedScore, NotchesGained, BalanceGap)
                        SELECT @rseq, @rid, @hit, @hitLvl, @moved, s.FinalNotch, s.WeightedScore, @n5 - s.FinalNotch,
                               (SELECT SUM(CASE Code WHEN 'TOTAL_ASSETS' THEN Amount ELSE -Amount END) FROM #crL WHERE Code IN ('TOTAL_ASSETS','TOTAL_LIABS','TOTAL_EQUITY')) - @baseGap
                        FROM #crS AS s;
                        DELETE #crX; INSERT #crX SELECT * FROM #crX0;
                    END;
                END;
            END;
            FETCH NEXT FROM rc INTO @rid;
        END;
        CLOSE rc; DEALLOCATE rc;
        DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;

        -- the strengthening plans, when asked (credit_reference.plans)
        IF @WithPlans = 1
            EXEC fin.usp_CreditPlans @BaseNotch = @n5, @BaseScore = @agg, @MaxSteps = @maxSteps, @MinGain = @minGain;
    END;

    -- the metrics of the comparison statement, for the trend of the outlook
    DECLARE @pD FLOAT, @pDs VARCHAR(14), @pE FLOAT, @pEs VARCHAR(14);
    IF @state = 'RATED' AND @hasPrior = 1
    BEGIN
        DELETE #crL; INSERT #crL SELECT Code, Amount FROM #crP;
        UPDATE #crX SET HasPrior = 0, PeriodType = PriorPeriodType, BuPresent = 0, HoldingStandalone = 0, BreachAtPeriodEnd = 0, RolloverFactor = 1,
                        Proforma = 1, Breach = NULL;
        EXEC fin.usp_CreditCore;
        SELECT @pDs = State, @pD = Value FROM #crM WHERE Code = 'DEBT_TO_EBITDA';
        SELECT @pEs = State, @pE = Value FROM #crM WHERE Code = 'EBITDA_MARGIN';
        DELETE #crX; INSERT #crX SELECT * FROM #crX0;
        DELETE #crL; INSERT #crL SELECT Code, Amount FROM @base;
    END;

    -- the result on the statement itself
    EXEC fin.usp_CreditCore;
    IF @state = 'RATED'
    BEGIN
        -- the triggers: the value of each computed metric at which the weighted score crosses to the next grade
        DECLARE @n0 INT = (SELECT IndicatedNotch FROM #crS), @W FLOAT = (SELECT SUM(EffectiveWeight) FROM #crF WHERE Score IS NOT NULL);
        INSERT #evTrig (MetricId, MetricCode, Direction, CurrentValue, TriggerValue, Score, TargetScore)
        SELECT f.MetricId, f.Code, w.Direction, f.Value, ROUND(gv.Value, 6), f.Score, ROUND(w.Target, 4)
        FROM #crF AS f
        JOIN fin.ScorecardMetric AS sm ON sm.ScorecardId = @card AND sm.MetricId = f.MetricId
        CROSS APPLY (VALUES ('UP', f.Score + ((@n0 - 0.5) - @agg) * @W / f.EffectiveWeight, CASE WHEN @n0 > 1 THEN 1 ELSE 0 END),
                            ('DOWN', f.Score + ((@n0 + 0.5) - @agg) * @W / f.EffectiveWeight, CASE WHEN @n0 < 20 THEN 1 ELSE 0 END)) AS w (Direction, Target, Ok)
        CROSS APPLY fin.fn_CreditGridValue(w.Target, sm.B0, sm.B1, sm.B2, sm.B3, sm.B4, sm.B5, sm.B6, sm.B7, sm.B8) AS gv
        WHERE f.Kind = 'QUANTITATIVE' AND f.Status = 'COMPUTED' AND f.EffectiveWeight > 0 AND sm.B0 IS NOT NULL AND w.Ok = 1
          AND w.Target >= 0.5 - 1e-9 AND w.Target <= 20.5 + 1e-9;
        -- the outlook (credit_reference.outlook)
        DECLARE @up FLOAT = CASE WHEN @n0 > 1 THEN ROUND(@agg - (@n0 - 0.5), 4) END, @down FLOAT = CASE WHEN @n0 < 20 THEN ROUND((@n0 + 0.5) - @agg, 4) END,
                @liq VARCHAR(6) = (SELECT Liquidity FROM #crS), @trend VARCHAR(3) = NULL;
        DECLARE @cD FLOAT, @cDs VARCHAR(14), @cE FLOAT, @cEs VARCHAR(14), @g FLOAT, @gs VARCHAR(14);
        SELECT @cDs = State, @cD = Value FROM #crM WHERE Code = 'DEBT_TO_EBITDA';
        SELECT @cEs = State, @cE = Value FROM #crM WHERE Code = 'EBITDA_MARGIN';
        SELECT @gs = State, @g = Value FROM #crM WHERE Code = 'REVENUE_GROWTH';
        IF @hasPrior = 1 AND @cDs = 'COMPUTED' AND @pDs = 'COMPUTED' AND @cEs = 'COMPUTED' AND @pEs = 'COMPUTED'
            SET @trend = CASE WHEN @cD > @pD AND @cE < @pE THEN 'NEG' WHEN @cD < @pD AND @cE > @pE AND @gs = 'COMPUTED' AND @g > 0 THEN 'POS' END;
        DECLARE @rules TABLE (n INT, Code VARCHAR(20) COLLATE DATABASE_DEFAULT);
        INSERT @rules SELECT v.n, v.Code FROM (VALUES
            (1, 'NEG_LIQUIDITY', CASE WHEN @liq IN ('SGL-3','SGL-4') THEN 1 ELSE 0 END),
            (2, 'NEG_SCENARIO', CASE WHEN (SELECT NotchesLost FROM #evScen WHERE Scenario = 'STAGNANT_MARKET') >= @stagLoss THEN 1 ELSE 0 END),
            (3, 'NEG_HEADROOM', CASE WHEN @down IS NOT NULL AND @down < @headroom THEN 1 ELSE 0 END),
            (4, 'NEG_TREND', CASE WHEN @trend = 'NEG' THEN 1 ELSE 0 END),
            (5, 'NEG_BREACH', CASE WHEN @breach IN ('OPEN','WAIVER_REQUESTED') THEN 1 ELSE 0 END),
            (6, 'POS_HEADROOM', CASE WHEN @up IS NOT NULL AND @up < @headroom THEN 1 ELSE 0 END),
            (7, 'POS_TREND', CASE WHEN @trend = 'POS' THEN 1 ELSE 0 END),
            (8, 'POS_RESILIENT', CASE WHEN @resilience = 'RESILIENT' AND @liq = 'SGL-1' AND EXISTS (SELECT 1 FROM #evScen)
                                           AND NOT EXISTS (SELECT 1 FROM #evScen WHERE ISNULL(NotchesLost, 0) > 1) THEN 1 ELSE 0 END)
        ) AS v (n, Code, Hit) WHERE v.Hit = 1;
        DECLARE @neg INT = (SELECT COUNT(*) FROM @rules WHERE Code LIKE 'NEG%'), @pos INT = (SELECT COUNT(*) FROM @rules WHERE Code LIKE 'POS%');
        INSERT #evSum (Resilience, Outlook, OutlookRules, IndicatedNotch, UpHeadroom, DownHeadroom)
        VALUES (@resilience, CASE WHEN @neg > 0 AND @pos > 0 THEN 'DEVELOPING' WHEN @neg > 0 THEN 'NEGATIVE' WHEN @pos >= 2 THEN 'POSITIVE' ELSE 'STABLE' END,
                (SELECT STRING_AGG(Code, ',') WITHIN GROUP (ORDER BY n) FROM @rules), @n0, @up, @down);
    END
    ELSE
        INSERT #evSum (Resilience, Outlook, OutlookRules, IndicatedNotch, UpHeadroom, DownHeadroom) VALUES (NULL, NULL, NULL, NULL, NULL, NULL);
    DELETE #crX; INSERT #crX SELECT * FROM #crX0;
    UPDATE #crX SET ResilienceNotch = (SELECT ResilienceNotch FROM #crX0);
END;
GO

/* ---------------------------------------------------------------------------------------------------------------
   The computation of a draft assessment (FR-FIN-020 to FR-FIN-030, BR-FIN-018 to BR-FIN-030; docs/35 sections 3 to 15).
   It reads the assessment, its statement and comparison statement (the lines whose codes are standard lines), the
   analyst's inputs, the guarantors and the bureau report, the company's activity and product lines, the covenant
   breaches and bank flows, and the company's facilities and collateral on the platform on the assessment date; runs
   fin.usp_CreditEvaluate; and writes the results. Runs as the caller: the row filters keep it to the bound tenant,
   and the ownership chain lets it write what the application role may not (the DENYs at the end).
   --------------------------------------------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE fin.usp_ComputeCreditAssessment
    @AssessmentId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tenant INT, @company BIGINT, @stmt BIGINT, @priorIn BIGINT, @prior BIGINT, @card INT, @asOf DATE, @fxIn DECIMAL(19,8),
            @status VARCHAR(10), @wantPlans BIT, @user BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
    DECLARE @pt VARCHAR(10), @pe DATE, @fy INT, @basis VARCHAR(12), @assurance VARCHAR(10), @opinion VARCHAR(11), @goingConcern BIT, @cur INT,
            @sstatus VARCHAR(10), @versionReason VARCHAR(10), @supersedes BIGINT, @isHolding BIT, @industry INT, @ppt VARCHAR(10), @cardStatus VARCHAR(8),
            @cardCur INT, @supportAge INT, @cardCode VARCHAR(40), @cardVer INT, @minCov DECIMAL(5,2), @fx FLOAT;

    BEGIN TRANSACTION;
    SELECT @tenant = TenantId, @company = CompanyId, @stmt = StatementId, @priorIn = PriorStatementId, @card = ScorecardId,
           @asOf = AssessmentDate, @fxIn = FxRateToScorecard, @status = Status, @wantPlans = StrengtheningRequested
    FROM fin.CreditAssessment WITH (UPDLOCK, HOLDLOCK)
    WHERE CreditAssessmentId = @AssessmentId;                       -- the row filter shows the bound tenant's only
    IF @tenant IS NULL THROW 50064, 'No credit assessment with this id for this tenant', 1;
    IF @status <> 'DRAFT' THROW 50063, 'Only a draft assessment is computed (BR-FIN-024)', 1;

    SELECT @pt = s.PeriodType, @pe = s.PeriodEnd, @fy = s.FiscalYear, @basis = s.Basis, @assurance = s.Assurance, @opinion = s.AuditOpinion,
           @goingConcern = s.GoingConcernUncertainty, @cur = s.CurrencyId, @sstatus = s.Status, @versionReason = s.VersionReason,
           @supersedes = s.SupersedesId, @isHolding = c.IsHolding, @industry = c.IndustryId
    FROM fin.FinancialStatement AS s
    JOIN org.Company AS c ON c.TenantId = s.TenantId AND c.CompanyId = s.CompanyId
    WHERE s.TenantId = @tenant AND s.FinancialStatementId = @stmt;
    IF @sstatus <> 'APPROVED' THROW 50064, 'An assessment reads an approved statement (BR-FIN-019)', 1;
    SELECT @cardStatus = Status, @cardCur = CurrencyId, @supportAge = SupportMaxAgeMonths, @cardCode = Code, @cardVer = VersionNo, @minCov = MinCoveragePct
    FROM fin.Scorecard WHERE ScorecardId = @card;
    IF @cardStatus <> 'APPROVED' THROW 50064, 'An assessment uses an approved scorecard (BR-FIN-023)', 1;
    IF @cur <> @cardCur AND @fxIn IS NULL
        THROW 50064, 'The statement''s currency differs from the scorecard''s: give the exchange rate (BR-FIN-019)', 1;
    SET @fx = CASE WHEN @cur = @cardCur THEN 1 ELSE @fxIn END;

    -- The comparison statement: the one given, else the approved statement of the same company, basis and period type
    -- a year earlier (audited first).
    IF @priorIn IS NOT NULL
    BEGIN
        SELECT @prior = FinancialStatementId, @ppt = PeriodType FROM fin.FinancialStatement
        WHERE TenantId = @tenant AND FinancialStatementId = @priorIn AND CompanyId = @company AND Basis = @basis
          AND Status = 'APPROVED' AND PeriodEnd < @pe;
        IF @prior IS NULL THROW 50064, 'The comparison statement is an approved, earlier statement of the same company and basis (BR-FIN-019)', 1;
    END
    ELSE
        SELECT TOP (1) @prior = FinancialStatementId, @ppt = PeriodType FROM fin.FinancialStatement
        WHERE TenantId = @tenant AND CompanyId = @company AND Basis = @basis AND PeriodType = @pt AND Status = 'APPROVED'
          AND PeriodEnd = EOMONTH(@pe, -12)
        ORDER BY CASE Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END, VersionNo DESC;

    -- The engine's tables.
    CREATE TABLE #crX (ScorecardId INT, PeriodType VARCHAR(10) COLLATE DATABASE_DEFAULT, PriorPeriodType VARCHAR(10) COLLATE DATABASE_DEFAULT, HasPrior BIT,
        Fx FLOAT, Assurance VARCHAR(10) COLLATE DATABASE_DEFAULT, Opinion VARCHAR(11) COLLATE DATABASE_DEFAULT, GoingConcern BIT, HoldingStandalone BIT,
        Breach VARCHAR(16) COLLATE DATABASE_DEFAULT, BreachAtPeriodEnd BIT, FlowShortfall BIT, StatementAgeMonths INT, RestatedPct FLOAT, IndustryId INT,
        MarketSize FLOAT, RolloverFactor FLOAT, ResilienceNotch BIT, Proforma BIT, EvSub BIT, EvCap BIT, PfLimits FLOAT, PfOutstanding FLOAT,
        PfCommittedUndrawn FLOAT, PfLargestLenderShare FLOAT, PfExpiring12mShare FLOAT, PfLenders INT, BuPresent BIT, BuOutstanding FLOAT, BuLimits FLOAT,
        BuLenders INT, BuDpd12m INT, BuCurrentDefault BIT, BuDefaults24m INT, BuBouncedCount INT, BuBouncedAmount FLOAT, BuJudgments FLOAT, BuRestructured BIT,
        BuInquiries6m INT, BuMonthsAfterPeriodEnd INT, QualBp FLOAT, QualFp FLOAT, DocBp BIT, DocFp BIT, ProdCashFlowQuality FLOAT, ProdConcentration FLOAT,
        InvCrisisValue FLOAT, InvDaysStagnant FLOAT, Support INT, ParentNotch INT, Override INT, GuLiquid FLOAT, GuNetWorth FLOAT, GuGiven FLOAT,
        GuGuaranteed FLOAT, GuMaxLeverage FLOAT);
    CREATE TABLE #crL (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT NULL);
    CREATE TABLE #crP (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT NULL);
    CREATE TABLE #crColl (Kind VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, Cover FLOAT NOT NULL);
    CREATE TABLE #crMix (ProductCategoryId INT NOT NULL, RevenueSharePct FLOAT NOT NULL, InventorySharePct FLOAT NOT NULL);
    CREATE TABLE #crQ (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value FLOAT NULL);
    CREATE TABLE #crM (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(14) COLLATE DATABASE_DEFAULT NOT NULL, Value FLOAT NULL);
    CREATE TABLE #crF (MetricId INT, Code VARCHAR(40) COLLATE DATABASE_DEFAULT, Kind VARCHAR(12) COLLATE DATABASE_DEFAULT, FactorCode VARCHAR(30) COLLATE DATABASE_DEFAULT,
        Weight FLOAT, EffectiveWeight FLOAT, Status VARCHAR(14) COLLATE DATABASE_DEFAULT, Value FLOAT, Score FLOAT, SortOrder INT);
    CREATE TABLE #crI (MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Level VARCHAR(12) COLLATE DATABASE_DEFAULT,
        Value FLOAT, SortOrder INT);
    CREATE TABLE #crA (Ord INT PRIMARY KEY, RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Stage VARCHAR(10) COLLATE DATABASE_DEFAULT, Notches INT, CapNotch INT,
        ParamValue FLOAT);
    CREATE TABLE #crR (AdjCode VARCHAR(40) COLLATE DATABASE_DEFAULT, LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Bucket VARCHAR(20) COLLATE DATABASE_DEFAULT, Amount FLOAT);
    CREATE TABLE #crD (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Given BIT NOT NULL);
    CREATE TABLE #crS (State VARCHAR(20) COLLATE DATABASE_DEFAULT, Coverage FLOAT, FinancialScore FLOAT, FinancialNotch INT, WeightedScore FLOAT, IndicatedNotch INT,
        NotchesRaw INT, Notches INT, CapStandalone INT, CapAbsolute INT, StandaloneNotch INT, SupportedNotch INT, OverriddenNotch INT, FinalNotch INT,
        Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT, Completeness FLOAT, FacilityLgd FLOAT, FacilityBand VARCHAR(4) COLLATE DATABASE_DEFAULT, FacilityNotch INT,
        UnsecuredRecovery FLOAT, AdjustedDebt FLOAT, AdjustedTnw FLOAT, RealisableNetWorth FLOAT, Ebitda FLOAT, Revenue FLOAT, Inventory FLOAT);
    CREATE TABLE #evScen (Scenario VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(20) COLLATE DATABASE_DEFAULT, FinalNotch INT, WeightedScore FLOAT,
        Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT, NotchesLost INT, Revenue FLOAT, Ebitda FLOAT, Inventory FLOAT, ArLoss FLOAT, InventoryWritedown FLOAT,
        ExtraFinanceCost FLOAT, ReceivablesStretch FLOAT, BalanceGap FLOAT);
    CREATE TABLE #evRem (SeqNo INT PRIMARY KEY, RemedyId INT NOT NULL, TriggerCode VARCHAR(40) COLLATE DATABASE_DEFAULT, TriggerLevel VARCHAR(12) COLLATE DATABASE_DEFAULT,
        Moved FLOAT, FinalNotch INT, WeightedScore FLOAT, NotchesGained INT, BalanceGap FLOAT);
    CREATE TABLE #evPlan (PlanId INT PRIMARY KEY, StepCount INT, FinalNotch INT, FinalScore FLOAT, NotchesGained INT, IsBalanced BIT);
    CREATE TABLE #evPlanStep (PlanId INT, StepNo INT, RemedyId INT, Moved FLOAT, FinalNotch INT, Score FLOAT, PRIMARY KEY (PlanId, StepNo));
    CREATE TABLE #evTrig (MetricId INT, MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Direction VARCHAR(4) COLLATE DATABASE_DEFAULT, CurrentValue FLOAT,
        TriggerValue FLOAT, Score FLOAT, TargetScore FLOAT);
    CREATE TABLE #evSum (Resilience VARCHAR(10) COLLATE DATABASE_DEFAULT, Outlook VARCHAR(10) COLLATE DATABASE_DEFAULT, OutlookRules VARCHAR(200) COLLATE DATABASE_DEFAULT,
        IndicatedNotch INT, UpHeadroom FLOAT, DownHeadroom FLOAT);

    -- The lines: an entered amount, else the computed one, of the lines whose codes are standard lines. A blank cell is
    -- not read: a line absent counts as zero, a breakdown or a disclosure absent is unknown (BR-FIN-002).
    INSERT #crL (Code, Amount)
    SELECT li.Code, CAST(COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS FLOAT)
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    JOIN fin.StandardLine AS sl ON sl.Code = li.Code
    WHERE ln.TenantId = @tenant AND ln.StatementId = @stmt AND COALESCE(ln.EnteredAmount, ln.ComputedAmount) IS NOT NULL;
    INSERT #crP (Code, Amount)
    SELECT li.Code, CAST(COALESCE(ln.EnteredAmount, ln.ComputedAmount) AS FLOAT)
    FROM fin.StatementLine AS ln
    JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
    JOIN fin.StandardLine AS sl ON sl.Code = li.Code
    WHERE ln.TenantId = @tenant AND ln.StatementId = @prior AND COALESCE(ln.EnteredAmount, ln.ComputedAmount) IS NOT NULL;

    -- A restatement: the largest change of the net profit or the equity against the version it replaces.
    DECLARE @restated FLOAT = NULL;
    IF @versionReason = 'RESTATED' AND @supersedes IS NOT NULL
    BEGIN
        DECLARE @oNp FLOAT, @oEq FLOAT, @cNp FLOAT = (SELECT Amount FROM #crL WHERE Code = 'NET_PROFIT'), @cEq FLOAT = (SELECT Amount FROM #crL WHERE Code = 'TOTAL_EQUITY');
        SELECT @oNp = MAX(CASE WHEN li.Code = 'NET_PROFIT' THEN COALESCE(ln.EnteredAmount, ln.ComputedAmount) END),
               @oEq = MAX(CASE WHEN li.Code = 'TOTAL_EQUITY' THEN COALESCE(ln.EnteredAmount, ln.ComputedAmount) END)
        FROM fin.StatementLine AS ln
        JOIN fin.LineCatalogItem AS li ON li.TenantId = ln.TenantId AND li.LineCatalogItemId = ln.LineCatalogItemId
        WHERE ln.TenantId = @tenant AND ln.StatementId = @supersedes;
        SET @restated = (SELECT MAX(x) FROM (VALUES (CASE WHEN @oNp = 0 THEN CASE WHEN @cNp <> 0 THEN 100 ELSE 0 END ELSE ABS(@cNp - @oNp) * 100 / ABS(@oNp) END),
                                                   (CASE WHEN @oEq = 0 THEN CASE WHEN @cEq <> 0 THEN 100 ELSE 0 END ELSE ABS(@cEq - @oEq) * 100 / ABS(@oEq) END)) AS v (x));
    END;

    -- The analyst's inputs: qualitative factors (a grade, or the average of graded sub-factors with the computed sector
    -- risk for the business profile), evidence, market size, rates of facility currencies.
    DECLARE @subMin INT = (SELECT Value FROM fin.ScorecardParameter WHERE ScorecardId = @card AND GroupCode = 'CARD' AND ParamKey = 'SUBFACTOR_MINIMUM');
    DECLARE @sector FLOAT = (SELECT CAST(CASE ip.SectorRisk WHEN 1 THEN 6 WHEN 2 THEN 9 WHEN 3 THEN 12 WHEN 4 THEN 14 ELSE 16 END
                                         + CASE ip.Cyclicality WHEN 'HIGH' THEN 1 WHEN 'LOW' THEN -1 ELSE 0 END AS FLOAT)
                             FROM fin.IndustryProfile AS ip WHERE ip.IndustryId = @industry);
    DECLARE @q TABLE (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Score FLOAT, Documented BIT);
    INSERT @q (Code, Score, Documented)
    SELECT cm.Code,
           CASE WHEN d.Mid IS NULL AND ISNULL(s.n, 0) < @subMin THEN NULL
                ELSE ROUND((CASE WHEN d.Mid IS NOT NULL THEN d.Mid * CASE WHEN ns.n > 1 THEN ns.n ELSE 1 END ELSE s.Total END
                            + CASE WHEN cm.Code = 'BUSINESS_PROFILE' AND @sector IS NOT NULL THEN @sector ELSE 0 END)
                           / ((CASE WHEN d.Mid IS NOT NULL THEN CASE WHEN ns.n > 1 THEN ns.n ELSE 1 END ELSE s.n END)
                              + CASE WHEN cm.Code = 'BUSINESS_PROFILE' AND @sector IS NOT NULL THEN 1 ELSE 0 END), 4) END,
           CASE WHEN d.Doc = 1 OR s.Doc = 1 THEN 1 ELSE 0 END
    FROM fin.ScorecardMetric AS sm
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = sm.MetricId AND cm.Kind = 'QUALITATIVE'
    OUTER APPLY (SELECT COUNT(*) AS n FROM fin.ScorecardSubfactor AS x WHERE x.ScorecardId = @card AND x.MetricId = sm.MetricId) AS ns
    OUTER APPLY (SELECT (g.ScoreFrom + g.ScoreTo) / 2.0 AS Mid, CASE WHEN i.DocumentId IS NOT NULL THEN 1 ELSE 0 END AS Doc
                 FROM fin.CreditAssessmentInput AS i JOIN fin.RatingGrade AS g ON g.RatingGradeId = i.GradeId
                 WHERE i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind = 'QUALITATIVE' AND i.MetricId = sm.MetricId) AS d
    OUTER APPLY (SELECT COUNT(*) AS n, SUM((g.ScoreFrom + g.ScoreTo) / 2.0) AS Total, MAX(CASE WHEN i.DocumentId IS NOT NULL THEN 1 ELSE 0 END) AS Doc
                 FROM fin.CreditAssessmentInput AS i
                 JOIN fin.ScorecardSubfactor AS x ON x.ScorecardSubfactorId = i.SubfactorId AND x.MetricId = sm.MetricId
                 JOIN fin.RatingGrade AS g ON g.RatingGradeId = i.GradeId
                 WHERE i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind = 'SUBFACTOR') AS s
    WHERE sm.ScorecardId = @card;
    DECLARE @evSub BIT = CASE WHEN EXISTS (SELECT 1 FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'EVIDENCE'
                                                AND EvidenceCode = 'SUBORDINATION') THEN 1 ELSE 0 END,
            @evCap BIT = CASE WHEN EXISTS (SELECT 1 FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'EVIDENCE'
                                                AND EvidenceCode = 'CAPITAL_RESOLUTION') THEN 1 ELSE 0 END,
            @evWaiver BIT = CASE WHEN EXISTS (SELECT 1 FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'EVIDENCE'
                                                   AND EvidenceCode = 'WAIVER_BEFORE_PERIOD_END') THEN 1 ELSE 0 END,
            @market FLOAT = (SELECT CAST(Amount AS FLOAT) FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'MARKET_SIZE');

    -- Group support and the override (BR-FIN-022).
    DECLARE @support INT, @parentNotch INT, @parentDate DATE, @override INT;
    SELECT @support = i.Notches, @parentNotch = pg.NotchNo, @parentDate = p.AssessmentDate
    FROM fin.CreditAssessmentInput AS i
    JOIN fin.CreditAssessment AS p ON p.TenantId = i.TenantId AND p.CreditAssessmentId = i.ParentAssessmentId
    JOIN fin.RatingGrade AS pg ON pg.RatingGradeId = p.FinalGradeId
    WHERE i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind = 'GROUP_SUPPORT' AND p.Status = 'APPROVED';
    IF @support IS NOT NULL AND (@parentDate > @asOf OR DATEDIFF(MONTH, @parentDate, @asOf) > @supportAge)
        THROW 50065, 'Group support reads a parent assessment of the twelve months before the assessment date (BR-FIN-022)', 1;
    SELECT @override = Notches FROM fin.CreditAssessmentInput WHERE TenantId = @tenant AND AssessmentId = @AssessmentId AND Kind = 'OVERRIDE';

    -- The covenant breaches open on the assessment date, and whether one was open at the period end; the bank flows.
    DECLARE @breaches TABLE (Waiver BIT NOT NULL, AtPeriodEnd BIT NOT NULL);
    INSERT @breaches (Waiver, AtPeriodEnd)
    SELECT CASE WHEN b.WaiverRef IS NOT NULL THEN 1 ELSE 0 END, CASE WHEN b.DetectedOn <= @pe THEN 1 ELSE 0 END
    FROM obl.ObligationBreach AS b
    JOIN obl.Obligation AS o ON o.TenantId = b.TenantId AND o.ObligationId = b.ObligationId
    LEFT JOIN fac.Facility AS fa ON fa.TenantId = o.TenantId AND fa.FacilityId = o.FacilityId
    WHERE b.TenantId = @tenant AND b.Status IN ('OPEN','IN_CURE') AND b.Kind IN ('COVENANT_BREACH','RESTRICTION_VIOLATION') AND b.DetectedOn <= @asOf
      AND (fa.BorrowerCompanyId = @company
           OR EXISTS (SELECT 1 FROM obl.Covenant AS c WHERE c.TenantId = b.TenantId AND c.RootId = b.CovenantRootId AND c.TestedCompanyId = @company)
           OR EXISTS (SELECT 1 FROM obl.ObligationCompany AS oc WHERE oc.TenantId = o.TenantId AND oc.ObligationId = o.ObligationId AND oc.CompanyId = @company));
    DECLARE @breach VARCHAR(16) = CASE WHEN EXISTS (SELECT 1 FROM @breaches WHERE Waiver = 0) THEN 'OPEN'
                                       WHEN EXISTS (SELECT 1 FROM @breaches) THEN 'WAIVER_REQUESTED' END,
            @bape BIT = CASE WHEN @evWaiver = 0 AND EXISTS (SELECT 1 FROM @breaches WHERE AtPeriodEnd = 1 AND Waiver = 0) THEN 1 ELSE 0 END;
    DECLARE @flows TABLE (CovenantId BIGINT, PerformanceState VARCHAR(10), Achieved FLOAT, Required FLOAT, MonthsElapsed INT, MonthsInWindow INT, AchievementPct FLOAT);
    INSERT @flows SELECT p.CovenantId, p.PerformanceState, p.Achieved, p.Required, p.MonthsElapsed, p.MonthsInWindow, p.AchievementPct
                  FROM fin.fn_BankFlowPerformance(@asOf) AS p WHERE p.TenantId = @tenant AND p.CompanyId = @company;
    DECLARE @flowP FLOAT = (SELECT ParamValue FROM fin.ScorecardAdjustment WHERE ScorecardId = @card AND RuleCode = 'FLOW_SHORTFALL');
    DECLARE @flowShort BIT = CASE WHEN EXISTS (SELECT 1 FROM @flows WHERE PerformanceState = 'BEHIND' AND Required > 0 AND MonthsInWindow > 0
                                                      AND Achieved < (1 - @flowP / 100) * Required * MonthsElapsed / MonthsInWindow) THEN 1 ELSE 0 END;

    -- The company's facilities on the platform on the assessment date (the approved revision), in the statement
    -- currency: limit, outstanding, the main lender, commitment, expiry, and the collateral linked to them by kind
    -- (a personal guarantee when the guarantor is an individual) (docs/35 section 10).
    DECLARE @fac TABLE (FacilityId BIGINT PRIMARY KEY, CurrencyId INT, Rate FLOAT, LimitAmount FLOAT, Outstanding FLOAT, Lender INT, LenderShare FLOAT,
                        IsCommitted BIT, ExpiryDate DATE, Secured FLOAT, Recoverable FLOAT, IsIncluded BIT, Reason NVARCHAR(300));
    INSERT @fac (FacilityId, CurrencyId, Rate, LimitAmount, Outstanding, Lender, LenderShare, IsCommitted, ExpiryDate, Secured, Recoverable, IsIncluded, Reason)
    SELECT f.FacilityId, f.CurrencyId, r.Rate, f.TotalAmount, ISNULL(u.Amount, 0), l.InstitutionId, l.SharePct, ISNULL(cm.IsCommitted, 0), f.ExpiryDate,
           ISNULL(cv.Secured, 0), ISNULL(cv.Recoverable, 0), CASE WHEN r.Rate IS NULL THEN 0 ELSE 1 END,
           CASE WHEN r.Rate IS NULL THEN N'لا سعر لعملة التسهيل بعملة القائمة في مدخلات التقييم' END
    FROM fac.Facility AS f
    OUTER APPLY (SELECT CASE WHEN f.CurrencyId = @cur THEN 1.0
                             ELSE (SELECT CAST(i.Rate AS FLOAT) FROM fin.CreditAssessmentInput AS i
                                   WHERE i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind = 'FX_RATE' AND i.CurrencyId = f.CurrencyId) END AS Rate) AS r
    OUTER APPLY (SELECT SUM(CASE WHEN x.CurrencyId = f2.CurrencyId THEN x.Amount ELSE x.Amount * x.RateToFacilityCcy END) AS Amount
                 FROM fac.Utilization AS x JOIN fac.Facility AS f2 ON f2.TenantId = x.TenantId AND f2.FacilityId = x.FacilityId
                 WHERE x.TenantId = f.TenantId AND x.FacilityId = f.FacilityId AND x.Status = 'ACTIVE' AND x.StartDate <= @asOf) AS u
    OUTER APPLY (SELECT TOP (1) x.InstitutionId, x.SharePct FROM fac.FacilityLender AS x
                 WHERE x.TenantId = f.TenantId AND x.FacilityId = f.FacilityId AND x.FromRevision <= f.ApprovedRevisionNo
                   AND (x.ToRevision IS NULL OR x.ToRevision >= f.ApprovedRevisionNo)
                 ORDER BY x.SharePct DESC, x.InstitutionId) AS l
    OUTER APPLY (SELECT MAX(CASE WHEN x.IsCommitted = 1 THEN 1 ELSE 0 END) AS IsCommitted FROM fac.Limit AS x
                 WHERE x.TenantId = f.TenantId AND x.FacilityId = f.FacilityId AND x.ParentLimitId IS NULL AND x.FromRevision <= f.ApprovedRevisionNo
                   AND (x.ToRevision IS NULL OR x.ToRevision >= f.ApprovedRevisionNo)) AS cm
    OUTER APPLY (SELECT SUM(k.CoverageAmount) AS Secured, SUM(k.CoverageAmount * (1 - h.Value / 100)) AS Recoverable
                 FROM col.CollateralLink AS k
                 JOIN col.Collateral AS c ON c.TenantId = k.TenantId AND c.RootId = k.CollateralId AND c.ApprovalState = 'APPROVED' AND c.Status = 'ACTIVE'
                 OUTER APPLY (SELECT CASE WHEN c.StructureKind = 'GUARANTEE' AND EXISTS (SELECT 1 FROM col.Guarantee AS g JOIN pty.Party AS p
                                                                                        ON p.TenantId = g.TenantId AND p.PartyId = g.GuarantorPartyId
                                                                                        WHERE g.TenantId = c.TenantId AND g.CollateralId = c.CollateralId
                                                                                          AND p.Kind = 'INDIVIDUAL')
                                          THEN 'GUARANTEE_PERSONAL' ELSE c.StructureKind END AS Kind) AS kd
                 JOIN fin.ScorecardParameter AS h ON h.ScorecardId = @card AND h.GroupCode = 'COLLATERAL_HAIRCUT' AND h.ParamKey = kd.Kind
                 WHERE k.TenantId = f.TenantId AND k.FacilityId = f.FacilityId AND k.CoverageAmount IS NOT NULL AND k.LinkedOn <= @asOf
                   AND (k.UnlinkedOn IS NULL OR k.UnlinkedOn > @asOf) AND k.FromRevision <= f.ApprovedRevisionNo
                   AND (k.ToRevision IS NULL OR k.ToRevision >= f.ApprovedRevisionNo)) AS cv
    WHERE f.TenantId = @tenant AND f.BorrowerCompanyId = @company AND f.LifecycleStatus IN ('ACTIVE','SUSPENDED')
      AND f.EffectiveFrom <= @asOf AND f.ExpiryDate >= @asOf;
    INSERT #crColl (Kind, Cover)
    SELECT kd.Kind, SUM(k.CoverageAmount * fa.Rate)
    FROM @fac AS fa
    JOIN fac.Facility AS f ON f.TenantId = @tenant AND f.FacilityId = fa.FacilityId
    JOIN col.CollateralLink AS k ON k.TenantId = f.TenantId AND k.FacilityId = f.FacilityId
    JOIN col.Collateral AS c ON c.TenantId = k.TenantId AND c.RootId = k.CollateralId AND c.ApprovalState = 'APPROVED' AND c.Status = 'ACTIVE'
    OUTER APPLY (SELECT CASE WHEN c.StructureKind = 'GUARANTEE' AND EXISTS (SELECT 1 FROM col.Guarantee AS g JOIN pty.Party AS p
                                                                            ON p.TenantId = g.TenantId AND p.PartyId = g.GuarantorPartyId
                                                                            WHERE g.TenantId = c.TenantId AND g.CollateralId = c.CollateralId AND p.Kind = 'INDIVIDUAL')
                              THEN 'GUARANTEE_PERSONAL' ELSE c.StructureKind END AS Kind) AS kd
    WHERE fa.IsIncluded = 1 AND k.CoverageAmount IS NOT NULL AND k.LinkedOn <= @asOf AND (k.UnlinkedOn IS NULL OR k.UnlinkedOn > @asOf)
      AND k.FromRevision <= f.ApprovedRevisionNo AND (k.ToRevision IS NULL OR k.ToRevision >= f.ApprovedRevisionNo)
    GROUP BY kd.Kind;
    DECLARE @pfLimits FLOAT, @pfOut FLOAT, @pfUndrawn FLOAT, @pfLargest FLOAT, @pfExpiring FLOAT, @pfLenders INT;
    SELECT @pfLimits = SUM(LimitAmount * Rate), @pfOut = SUM(Outstanding * Rate),
           @pfUndrawn = SUM(CASE WHEN IsCommitted = 1 AND LimitAmount > Outstanding THEN (LimitAmount - Outstanding) * Rate ELSE 0 END),
           @pfExpiring = SUM(CASE WHEN ExpiryDate <= DATEADD(MONTH, 12, @asOf) THEN LimitAmount * Rate ELSE 0 END) * 100 / NULLIF(SUM(LimitAmount * Rate), 0),
           @pfLenders = COUNT(DISTINCT Lender)
    FROM @fac WHERE IsIncluded = 1;
    SET @pfLargest = (SELECT TOP (1) SUM(LimitAmount * Rate * LenderShare / 100) * 100 / NULLIF(@pfLimits, 0) FROM @fac WHERE IsIncluded = 1 AND Lender IS NOT NULL
                      GROUP BY Lender ORDER BY SUM(LimitAmount * Rate * LenderShare / 100) DESC);

    -- The guarantors, the bureau report, the product lines of the statement's year.
    DECLARE @guLiquid FLOAT, @guNw FLOAT, @guGiven FLOAT, @guGtd FLOAT, @guLev FLOAT;
    SELECT @guLiquid = SUM(LiquidAssets), @guNw = SUM(NetWorth), @guGiven = SUM(GuaranteesGiven), @guGtd = SUM(GuaranteedAmount),
           @guLev = MAX(CASE WHEN NetWorth > 0 THEN GuaranteesGiven * 100.0 / NetWorth ELSE 999 END)
    FROM fin.CreditAssessmentGuarantor WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    INSERT #crMix (ProductCategoryId, RevenueSharePct, InventorySharePct)
    SELECT ProductCategoryId, RevenueSharePct, InventorySharePct FROM fin.CompanyProductLine WHERE TenantId = @tenant AND CompanyId = @company AND FiscalYear = @fy;
    DECLARE @cfq FLOAT, @conc FLOAT, @crisis FLOAT, @days FLOAT, @rw FLOAT, @iw FLOAT;
    SELECT @rw = SUM(RevenueSharePct), @iw = SUM(InventorySharePct) FROM #crMix;
    IF EXISTS (SELECT 1 FROM #crMix)
        SELECT @cfq = CASE WHEN @rw > 0 THEN SUM(pc.CashFlowQuality * m.RevenueSharePct) / @rw END,
               @conc = CASE WHEN @rw > 0 THEN MAX(m.RevenueSharePct) / @rw * 100 END,
               @crisis = SUM(pc.InvValueCrisisPct * CASE WHEN @iw > 0 THEN m.InventorySharePct ELSE 1 END) / SUM(CASE WHEN @iw > 0 THEN m.InventorySharePct ELSE 1 END),
               @days = SUM(pc.DaysToSellStagnant * CASE WHEN @iw > 0 THEN m.InventorySharePct ELSE 1 END) / SUM(CASE WHEN @iw > 0 THEN m.InventorySharePct ELSE 1 END)
        FROM #crMix AS m JOIN fin.ProductCategory AS pc ON pc.ProductCategoryId = m.ProductCategoryId;
    ELSE
        SELECT @crisis = AVG(CAST(pc.InvValueCrisisPct AS FLOAT)), @days = AVG(CAST(pc.DaysToSellStagnant AS FLOAT))
        FROM fin.IndustryProfile AS ip CROSS APPLY STRING_SPLIT(ip.ProductCategories, ',') AS c JOIN fin.ProductCategory AS pc ON pc.Code = c.value
        WHERE ip.IndustryId = @industry;

    INSERT #crX (ScorecardId, PeriodType, PriorPeriodType, HasPrior, Fx, Assurance, Opinion, GoingConcern, HoldingStandalone, Breach, BreachAtPeriodEnd,
                 FlowShortfall, StatementAgeMonths, RestatedPct, IndustryId, MarketSize, RolloverFactor, ResilienceNotch, Proforma, EvSub, EvCap, PfLimits,
                 PfOutstanding, PfCommittedUndrawn, PfLargestLenderShare, PfExpiring12mShare, PfLenders, BuPresent, BuOutstanding, BuLimits, BuLenders, BuDpd12m,
                 BuCurrentDefault, BuDefaults24m, BuBouncedCount, BuBouncedAmount, BuJudgments, BuRestructured, BuInquiries6m, BuMonthsAfterPeriodEnd, QualBp,
                 QualFp, DocBp, DocFp, ProdCashFlowQuality, ProdConcentration, InvCrisisValue, InvDaysStagnant, Support, ParentNotch, Override, GuLiquid,
                 GuNetWorth, GuGiven, GuGuaranteed, GuMaxLeverage)
    SELECT @card, @pt, ISNULL(@ppt, 'ANNUAL'), CASE WHEN @prior IS NULL THEN 0 ELSE 1 END, @fx, @assurance, ISNULL(@opinion, 'UNQUALIFIED'), @goingConcern,
           CASE WHEN @isHolding = 1 AND @basis = 'STANDALONE' THEN 1 ELSE 0 END, @breach, @bape, @flowShort, DATEDIFF(MONTH, @pe, @asOf), @restated, @industry,
           @market, 1, 0, 0, @evSub, @evCap, @pfLimits, @pfOut, @pfUndrawn, @pfLargest, @pfExpiring, @pfLenders,
           CASE WHEN b.CreditAssessmentBureauId IS NULL THEN 0 ELSE 1 END, b.TotalOutstanding, b.TotalLimits, b.LenderCount, b.WorstDpd12m, ISNULL(b.CurrentDefault, 0),
           b.Defaults24mCount, b.BouncedCheques12mCount, b.BouncedCheques12mAmount, b.JudgmentsAmount, ISNULL(b.Restructured, 0), b.Inquiries6m,
           DATEDIFF(MONTH, @pe, b.ReportDate),
           (SELECT Score FROM @q WHERE Code = 'BUSINESS_PROFILE'), (SELECT Score FROM @q WHERE Code = 'FINANCIAL_POLICY'),
           ISNULL((SELECT Documented FROM @q WHERE Code = 'BUSINESS_PROFILE'), 0), ISNULL((SELECT Documented FROM @q WHERE Code = 'FINANCIAL_POLICY'), 0),
           @cfq, @conc, @crisis, @days, @support, @parentNotch, ISNULL(@override, 0), @guLiquid, @guNw, @guGiven, @guGtd, @guLev
    FROM (SELECT 1 AS one) AS d
    LEFT JOIN fin.CreditAssessmentBureau AS b ON b.TenantId = @tenant AND b.AssessmentId = @AssessmentId;

    EXEC fin.usp_CreditEvaluate @WithScenarios = 1, @WithRemedies = 1, @WithPlans = @wantPlans;

    DECLARE @state VARCHAR(20), @coverage FLOAT, @finScore FLOAT, @finNotch INT, @agg FLOAT, @n0 INT, @notches INT, @capS INT, @capA INT, @n2 INT, @n3 INT,
            @n4 INT, @n5 INT, @liq VARCHAR(6), @comp FLOAT, @lgd FLOAT, @band VARCHAR(4), @facNotch INT, @adjDebt FLOAT, @adjTnw FLOAT, @realNw FLOAT;
    SELECT @state = State, @coverage = Coverage, @finScore = FinancialScore, @finNotch = FinancialNotch, @agg = WeightedScore, @n0 = IndicatedNotch,
           @notches = Notches, @capS = CapStandalone, @capA = CapAbsolute, @n2 = StandaloneNotch, @n3 = SupportedNotch, @n4 = OverriddenNotch, @n5 = FinalNotch,
           @liq = Liquidity, @comp = Completeness, @lgd = FacilityLgd, @band = FacilityBand, @facNotch = FacilityNotch, @adjDebt = AdjustedDebt,
           @adjTnw = AdjustedTnw, @realNw = RealisableNetWorth
    FROM #crS;
    DECLARE @rated BIT = CASE WHEN @state = 'RATED' THEN 1 ELSE 0 END;
    DECLARE @n1 INT = @n0 - @notches;
    DECLARE @wScored FLOAT = (SELECT SUM(EffectiveWeight) FROM #crF WHERE Score IS NOT NULL AND (@rated = 1 OR Kind = 'QUANTITATIVE'));
    DECLARE @typ INT = (SELECT g.NotchNo FROM fin.IndustryProfile AS ip JOIN fin.RatingGrade AS g ON g.RatingGradeId = ip.ExpectedTypicalGradeId WHERE ip.IndustryId = @industry);
    DECLARE @resilience VARCHAR(10), @outlook VARCHAR(10), @rules VARCHAR(200), @up FLOAT, @down FLOAT;
    SELECT @resilience = Resilience, @outlook = Outlook, @rules = OutlookRules, @up = UpHeadroom, @down = DownHeadroom FROM #evSum;

    -- The findings, in the order of the report (docs/35 section 8).
    DECLARE @x TABLE (Ord INT IDENTITY(1,1) PRIMARY KEY, Kind VARCHAR(13), Source VARCHAR(10), RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT,
                      LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, RiskLevel VARCHAR(8), Value FLOAT, PriorValue FLOAT, Notches INT, RefId BIGINT,
                      TextAr NVARCHAR(1000), TextEn NVARCHAR(1000));
    -- the scorecard: A or better is a strength, B or worse a weakness
    INSERT @x (Kind, Source, RuleCode, Value, TextAr, TextEn)
    SELECT CASE WHEN f.Score <= 7.5 THEN 'STRENGTH' ELSE 'WEAKNESS' END, 'SCORECARD', f.Code, f.Value,
           CASE WHEN f.Status = 'EXTREME' THEN CONCAT(cm.NameAr, N': ', CASE WHEN f.Score <= 0.5 THEN N'في أفضل طرف' ELSE N'في أسوأ طرف' END, N' (', g.Code, N')')
                ELSE REPLACE(REPLACE(CASE WHEN f.Score <= 7.5 THEN cm.StrengthTextAr ELSE cm.WeaknessTextAr END, N'{v}', ISNULL(fv.Txt, N'')), N'{g}', g.Code) END,
           CASE WHEN f.Status = 'EXTREME' THEN CONCAT(cm.NameEn, N': ', g.Code)
                ELSE REPLACE(REPLACE(CASE WHEN f.Score <= 7.5 THEN cm.StrengthTextEn ELSE cm.WeaknessTextEn END, N'{v}', ISNULL(fv.Txt, N'')), N'{g}', g.Code) END
    FROM #crF AS f
    JOIN fin.CreditMetric AS cm ON cm.CreditMetricId = f.MetricId
    JOIN fin.RatingGrade AS g ON g.NotchNo = CASE WHEN FLOOR(f.Score - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(f.Score - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(f.Score - 0.5) + 1 END
    OUTER APPLY (SELECT FORMAT(f.Value, CASE WHEN cm.Unit IN ('DAYS','AMOUNT') THEN 'N0' ELSE 'N2' END, 'en-US') AS Txt) AS fv
    WHERE f.Score IS NOT NULL AND (f.Score <= 7.5 OR f.Score > 13.5)
    ORDER BY CASE WHEN f.Score <= 7.5 THEN 0 ELSE 1 END, f.SortOrder;
    -- the balance sheet items and their rules
    INSERT @x (Kind, Source, RuleCode, LineCode, RiskLevel, Value, TextAr, TextEn)
    SELECT CASE WHEN i.Level = 'NOT_ASSESSED' THEN 'INFO' WHEN i.Level = 'LOW' AND r.ReportStrength = 1 THEN 'STRENGTH' WHEN i.Level IN ('LOW','MODERATE') THEN 'INFO'
                WHEN i.Level = 'ELEVATED' THEN 'WATCH' WHEN i.Level = 'HIGH' THEN 'WEAKNESS' ELSE 'CRITICAL_RISK' END,
           'ITEM_RULE', i.MetricCode, i.LineCode, CASE WHEN i.Level <> 'NOT_ASSESSED' THEN i.Level END, i.Value,
           CASE WHEN i.Level = 'NOT_ASSESSED' THEN CONCAT(cm.NameAr, N': لم يُقيَّم لنقص البيانات')
                WHEN i.Value IS NULL THEN CONCAT(cm.NameAr, CASE WHEN i.Level = 'LOW' THEN N': في أفضل طرف' ELSE N': في أسوأ طرف' END)
                ELSE REPLACE(REPLACE(CASE WHEN i.Level = 'LOW' THEN cm.StrengthTextAr ELSE cm.WeaknessTextAr END, N' ({g})', N''), N'{v}', ISNULL(fv.Txt, N'')) END,
           CASE WHEN i.Level = 'NOT_ASSESSED' THEN CONCAT(cm.NameEn, N': not assessed')
                WHEN i.Value IS NULL THEN cm.NameEn
                ELSE REPLACE(REPLACE(CASE WHEN i.Level = 'LOW' THEN cm.StrengthTextEn ELSE cm.WeaknessTextEn END, N' ({g})', N''), N'{v}', ISNULL(fv.Txt, N'')) END
    FROM #crI AS i
    JOIN fin.CreditMetric AS cm ON cm.Code = i.MetricCode
    JOIN fin.ScorecardItemRule AS r ON r.ScorecardId = @card AND r.MetricId = cm.CreditMetricId AND r.LineCode = i.LineCode
    OUTER APPLY (SELECT FORMAT(i.Value, CASE WHEN cm.Unit IN ('DAYS','AMOUNT') THEN 'N0' ELSE 'N2' END, 'en-US') AS Txt) AS fv
    ORDER BY CASE i.Level WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1 WHEN 'ELEVATED' THEN 2 WHEN 'LOW' THEN 3 WHEN 'MODERATE' THEN 4 ELSE 5 END, i.SortOrder;
    -- liquidity and the facility grade
    INSERT @x (Kind, Source, RuleCode, Value, TextAr, TextEn)
    SELECT CASE @liq WHEN 'SGL-1' THEN 'STRENGTH' WHEN 'SGL-2' THEN 'INFO' WHEN 'SGL-3' THEN 'WATCH' ELSE 'CRITICAL_RISK' END, 'LIQUIDITY', @liq,
           (SELECT Value FROM #crM WHERE Code = 'LIQUIDITY_COVERAGE'), CONCAT(t.NameAr, N' (', @liq, N'): ', t.TextAr), CONCAT(t.NameEn, N' (', @liq, N'): ', t.TextEn)
    FROM fin.CreditText AS t WHERE t.Domain = 'LIQUIDITY' AND t.Code = @liq;
    INSERT @x (Kind, Source, RuleCode, Value, TextAr, TextEn)
    SELECT CASE WHEN @facNotch < @n5 THEN 'STRENGTH' WHEN @facNotch > @n5 THEN 'WEAKNESS' ELSE 'INFO' END, 'FACILITY', @band, @lgd,
           CONCAT(N'درجة التسهيلات ', g.Code, N': الخسارة المتوقعة عند التعثر ', FORMAT(@lgd, 'N1', 'en-US'), N'% (', @band, N')، بعد الضمانات المرتبطة بالتسهيلات على المنصة وخصوماتها'),
           CONCAT(N'Facility grade ', g.Code, N': loss given default ', FORMAT(@lgd, 'N1', 'en-US'), N'% (', @band, N') after the collateral linked to the facilities and its haircuts')
    FROM fin.RatingGrade AS g WHERE g.NotchNo = @facNotch AND @rated = 1;
    -- the data the report asks for: disclosures missing, the bureau report, the product lines, the activity and its own
    -- disclosures, inconsistent lines
    INSERT @x (Kind, Source, RuleCode, TextAr, TextEn)
    SELECT 'WATCH', 'DATA', r.Code, CONCAT(N'مطلوب — ', t.NameAr, N': ', t.TextAr), CONCAT(N'Requested — ', t.NameEn, N': ', t.TextEn)
    FROM (SELECT d.Code, 'DISCLOSURE' AS Domain, 1 AS g FROM #crD AS d WHERE d.Given = 0
          UNION ALL SELECT 'BUREAU_REPORT', 'REQUEST', 2 WHERE NOT EXISTS (SELECT 1 FROM fin.CreditAssessmentBureau WHERE TenantId = @tenant AND AssessmentId = @AssessmentId)
          UNION ALL SELECT 'PRODUCT_MIX', 'REQUEST', 3 WHERE NOT EXISTS (SELECT 1 FROM #crMix)
          UNION ALL SELECT 'INDUSTRY', 'REQUEST', 4 WHERE @industry IS NULL) AS r
    JOIN fin.CreditText AS t ON t.Domain = r.Domain AND t.Code = r.Code
    ORDER BY r.g, r.Code;
    INSERT @x (Kind, Source, RuleCode, LineCode, TextAr, TextEn)
    SELECT 'WATCH', 'DATA', 'INDUSTRY_DISCLOSURE', sl.Code, CONCAT(N'مطلوب — ', t.TextAr, N' ', sl.NameAr), CONCAT(N'Requested — ', t.TextEn, N' ', sl.NameEn)
    FROM fin.IndustryProfile AS ip CROSS APPLY STRING_SPLIT(ip.ExtraDisclosures, ',') AS c
    JOIN fin.StandardLine AS sl ON sl.Code = c.value
    JOIN fin.CreditText AS t ON t.Domain = 'REQUEST' AND t.Code = 'INDUSTRY_DISCLOSURE'
    WHERE ip.IndustryId = @industry AND NOT EXISTS (SELECT 1 FROM #crL AS l WHERE l.Code = sl.Code)
    ORDER BY sl.SortOrder;
    INSERT @x (Kind, Source, RuleCode, LineCode, Value, TextAr, TextEn)
    SELECT 'WATCH', 'DATA', 'INCONSISTENT', sl.Code, l.Amount, CONCAT(t.NameAr, N': ', sl.NameAr, N' — ', t.TextAr), CONCAT(t.NameEn, N': ', sl.NameEn, N' — ', t.TextEn)
    FROM fin.StandardLine AS sl
    JOIN #crL AS l ON l.Code = sl.Code
    JOIN fin.CreditText AS t ON t.Domain = 'REQUEST' AND t.Code = 'INCONSISTENT'
    OUTER APPLY (SELECT CASE WHEN sl.ParentCode = 'AR_GROSS' AND NOT EXISTS (SELECT 1 FROM #crL WHERE Code = 'AR_GROSS')
                             THEN (SELECT a.Amount FROM #crL AS a WHERE a.Code = 'AR') + ISNULL((SELECT e.Amount FROM #crL AS e WHERE e.Code = 'AR_ECL_ALLOWANCE'), 0)
                             ELSE (SELECT p.Amount FROM #crL AS p WHERE p.Code = sl.ParentCode) END AS Amount) AS par
    WHERE sl.LineKind = 'OF_WHICH' AND par.Amount IS NOT NULL AND l.Amount > par.Amount + 1
    ORDER BY sl.SortOrder;
    -- the covenants tested on this statement: their latest evaluation (FR-FIN-022)
    INSERT @x (Kind, Source, RuleCode, Value, RefId, TextAr, TextEn)
    SELECT CASE WHEN t.Result = 'BREACH' THEN 'CRITICAL_RISK' WHEN t.Result = 'WARNING' THEN 'WATCH'
                WHEN t.HeadroomPct IS NOT NULL AND t.HeadroomPct < 10 THEN 'WATCH' WHEN t.HeadroomPct >= 25 THEN 'STRENGTH' ELSE 'INFO' END,
           'COVENANT', CONCAT('COVENANT_', t.Result), t.ActualValue, t.CovenantTestId,
           CONCAT(N'تعهد ', ISNULL(mf.NameAr, c.MeasureKind), N' (', o.ClauseRef, N'): ',
                  CASE t.Result WHEN 'BREACH' THEN N'خرق' WHEN 'WARNING' THEN N'إنذار مبكر' ELSE N'ملتزم' END,
                  N'؛ الفعلي ', FORMAT(t.ActualValue, 'N2', 'en-US'), N' والحد ', op.Sym, N' ', FORMAT(t.ThresholdApplied, 'N2', 'en-US'),
                  CASE WHEN t.HeadroomPct IS NOT NULL THEN CONCAT(N'، والهامش ', FORMAT(t.HeadroomPct, 'N1', 'en-US'), N'%') END),
           CONCAT(N'Covenant ', ISNULL(mf.NameEn, c.MeasureKind), N': ', t.Result, N', actual ', FORMAT(t.ActualValue, 'N2', 'en-US'),
                  N' against ', op.Sym, N' ', FORMAT(t.ThresholdApplied, 'N2', 'en-US'))
    FROM (SELECT x.*, ROW_NUMBER() OVER (PARTITION BY x.CovenantRootId, x.PeriodEnd ORDER BY x.EvaluationNo DESC) AS rn
          FROM obl.CovenantTest AS x
          JOIN obl.CovenantTestStatement AS ts ON ts.TenantId = x.TenantId AND ts.CovenantTestId = x.CovenantTestId
          WHERE ts.TenantId = @tenant AND ts.StatementId = @stmt AND x.State IN ('EVALUATED','REVIEWED')) AS t
    JOIN obl.Covenant AS c ON c.TenantId = t.TenantId AND c.CovenantId = t.CovenantId
    JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
    LEFT JOIN fin.MeasureFormula AS mf ON mf.TenantId = t.TenantId AND mf.MeasureFormulaId = t.FormulaId
    CROSS APPLY (SELECT CASE t.OperatorApplied WHEN 'GE' THEN N'≥' WHEN 'LE' THEN N'≤' WHEN 'GT' THEN N'>' WHEN 'LT' THEN N'<' ELSE N'=' END AS Sym) AS op
    WHERE t.rn = 1 AND t.Result IN ('COMPLIANT','WARNING','BREACH')
    ORDER BY CASE t.Result WHEN 'BREACH' THEN 0 WHEN 'WARNING' THEN 1 ELSE 2 END, t.CovenantTestId;
    -- the liquidity routed to the bank on the assessment date (FR-FIN-018)
    INSERT @x (Kind, Source, RuleCode, Value, RefId, TextAr, TextEn)
    SELECT CASE p.PerformanceState WHEN 'BEHIND' THEN 'WATCH' WHEN 'MET' THEN 'STRENGTH' ELSE 'INFO' END,
           'BANK_FLOW', CONCAT('FLOW_', p.PerformanceState), p.AchievementPct, p.CovenantId,
           CONCAT(N'تحويل السيولة إلى البنك: ', CASE p.PerformanceState WHEN 'BEHIND' THEN N'متأخر' WHEN 'MET' THEN N'مستوفى' WHEN 'ON_TRACK' THEN N'على المسار'
                                                        WHEN 'NO_DATA' THEN N'بلا تحويلات مؤكدة' ELSE N'بلا إيراد يُقاس عليه' END,
                  N'؛ المؤكَّد ', FORMAT(p.Achieved, 'N0', 'en-US'), N' من ', FORMAT(p.Required, 'N0', 'en-US'),
                  CASE WHEN p.AchievementPct IS NOT NULL THEN CONCAT(N' (', FORMAT(p.AchievementPct, 'N1', 'en-US'), N'%)') END,
                  N' حتى ', CONVERT(CHAR(10), @asOf, 23)),
           CONCAT(N'Liquidity routed to the bank: ', p.PerformanceState, N', confirmed ', FORMAT(p.Achieved, 'N0', 'en-US'), N' of ', FORMAT(p.Required, 'N0', 'en-US'))
    FROM @flows AS p
    ORDER BY CASE p.PerformanceState WHEN 'BEHIND' THEN 0 ELSE 1 END, p.CovenantId;
    -- the adjustments: each notch, each cap the scorecard always reports, and each other cap that binds
    INSERT @x (Kind, Source, RuleCode, Notches, TextAr, TextEn)
    SELECT 'ADJUSTMENT', 'ADJUSTMENT', a.RuleCode, a.Notches,
           REPLACE(sa.TextAr, N'{p}', ISNULL(FORMAT(a.ParamValue, 'G', 'en-US'), N'')), REPLACE(sa.TextEn, N'{p}', ISNULL(FORMAT(a.ParamValue, 'G', 'en-US'), N''))
    FROM #crA AS a
    JOIN fin.ScorecardAdjustment AS sa ON sa.ScorecardId = @card AND sa.RuleCode = a.RuleCode
    WHERE a.Stage = 'NOTCH' OR sa.ShowWhen = 'ALWAYS'
       OR (a.Stage = 'STANDALONE' AND @n1 < a.CapNotch) OR (a.Stage = 'ABSOLUTE' AND @n4 < a.CapNotch)
    ORDER BY a.Ord;
    INSERT @x (Kind, Source, RuleCode, Notches, TextAr, TextEn)
    SELECT 'ADJUSTMENT', 'ANALYST', i.Kind, CASE WHEN i.Kind = 'OVERRIDE' THEN i.Notches ELSE @n2 - @n3 END,
           CONCAT(CASE i.Kind WHEN 'GROUP_SUPPORT' THEN N'دعم المجموعة: ' ELSE N'تجاوز المحلل: ' END, i.Justification),
           CONCAT(CASE i.Kind WHEN 'GROUP_SUPPORT' THEN N'Group support: ' ELSE N'Analyst override: ' END, i.Justification)
    FROM fin.CreditAssessmentInput AS i
    WHERE @rated = 1 AND i.TenantId = @tenant AND i.AssessmentId = @AssessmentId AND i.Kind IN ('GROUP_SUPPORT','OVERRIDE')
    ORDER BY i.Kind;

    -- The summary, in both languages.
    DECLARE @ig VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @n0),
            @sg VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = CASE WHEN @n2 > 20 THEN 20 ELSE @n2 END),
            @fg VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @n5),
            @fing VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @finNotch),
            @facg VARCHAR(4) = (SELECT Code FROM fin.RatingGrade WHERE NotchNo = @facNotch),
            @rb VARCHAR(11) = (SELECT RiskBand FROM fin.RatingGrade WHERE NotchNo = @n5),
            @ol NVARCHAR(40) = (SELECT NameAr FROM fin.CreditText WHERE Domain = 'OUTLOOK_VIEW' AND Code = @outlook),
            @olEn NVARCHAR(40) = (SELECT NameEn FROM fin.CreditText WHERE Domain = 'OUTLOOK_VIEW' AND Code = @outlook);
    DECLARE @cS INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'STRENGTH'), @cW INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'WATCH'),
            @cK INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'WEAKNESS'), @cR INT = (SELECT COUNT(*) FROM @x WHERE Kind = 'CRITICAL_RISK');
    DECLARE @sumAr NVARCHAR(1000) = CASE
            WHEN @state = 'RATED' THEN
            CONCAT(N'الدرجة النهائية ', @fg, N' (مخاطر ', CASE @rb WHEN 'LOW' THEN N'منخفضة' WHEN 'MODERATE' THEN N'معتدلة' WHEN 'SUBSTANTIAL' THEN N'جوهرية'
                   WHEN 'HIGH' THEN N'مرتفعة' ELSE N'مرتفعة جدًا' END, N')، النظرة ', @ol, N'؛ المؤشرة ', @ig, N' بمجموع ', FORMAT(@agg, 'N2', 'en-US'),
                   N'، والمنفردة ', @sg, N'، والمالية وحدها ', @fing, CASE WHEN @facg IS NOT NULL THEN CONCAT(N'، ودرجة التسهيلات ', @facg) END,
                   N'؛ السيولة ', @liq, N'، واكتمال الإفصاح ', FORMAT(@comp, 'N0', 'en-US'), N'%. نقاط القوة ', @cS, N'، ونقاط المراقبة ', @cW,
                   N'، ونقاط الضعف ', @cK, N'، والمخاطر الحرجة ', @cR, N'.')
            WHEN @state = 'INDICATIVE' THEN
            CONCAT(N'درجة مالية استرشادية ', @fing, N' بمجموع ', FORMAT(@finScore, 'N2', 'en-US'), N'، ولا درجة نهائية قبل أن يُدخل المحلل العوامل النوعية.')
            ELSE CONCAT(N'لا درجة: المقاييس الكمية ذات الدرجة تغطي ', FORMAT(@coverage, 'N0', 'en-US'), N'% من أوزانها، والحد الأدنى ', FORMAT(@minCov, 'N0', 'en-US'), N'%.') END;
    DECLARE @sumEn NVARCHAR(1000) = CASE
            WHEN @state = 'RATED' THEN
            CONCAT(N'Final grade ', @fg, N' (', LOWER(REPLACE(@rb, '_', ' ')), N' risk), outlook ', LOWER(@olEn), N'; indicated ', @ig, N' at ', FORMAT(@agg, 'N2', 'en-US'),
                   N', standalone ', @sg, N', financial only ', @fing, CASE WHEN @facg IS NOT NULL THEN CONCAT(N', facility grade ', @facg) END, N'; liquidity ', @liq,
                   N', disclosure ', FORMAT(@comp, 'N0', 'en-US'), N'%. ', @cS, N' strengths, ', @cW, N' points to watch, ', @cK, N' weaknesses, ', @cR, N' critical risks.')
            WHEN @state = 'INDICATIVE' THEN
            CONCAT(N'Indicative financial grade ', @fing, N' at ', FORMAT(@finScore, 'N2', 'en-US'), N'; no final grade until the analyst grades the qualitative factors.')
            ELSE CONCAT(N'Not rated: the scored quantitative metrics cover ', FORMAT(@coverage, 'N0', 'en-US'), N'% of their weights, below the minimum of ', FORMAT(@minCov, 'N0', 'en-US'), N'%.') END;

    DECLARE @snapshot NVARCHAR(MAX) = (
        SELECT @cardCode AS scorecard, @cardVer AS scorecardVersion, @stmt AS statementId, @prior AS priorStatementId, @pt AS periodType, @fx AS fxRate,
               JSON_QUERY((SELECT * FROM #crX FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS context,
               (SELECT l.Code AS code, l.Amount AS amount FROM #crL AS l ORDER BY l.Code FOR JSON PATH) AS lines,
               (SELECT l.Code AS code, l.Amount AS amount FROM #crP AS l ORDER BY l.Code FOR JSON PATH) AS priorLines,
               (SELECT q.Code AS code, q.Value AS value FROM #crQ AS q WHERE q.Value IS NOT NULL ORDER BY q.Code FOR JSON PATH) AS quantities,
               (SELECT c.Kind AS kind, c.Cover AS cover FROM #crColl AS c ORDER BY c.Kind FOR JSON PATH) AS collateral,
               (SELECT pc.Code AS category, m.RevenueSharePct AS revenueSharePct, m.InventorySharePct AS inventorySharePct
                FROM #crMix AS m JOIN fin.ProductCategory AS pc ON pc.ProductCategoryId = m.ProductCategoryId ORDER BY pc.Code FOR JSON PATH) AS productMix
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    -- The results replace those of an earlier computation of the draft.
    DELETE fin.CreditAssessmentFinding WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentFactor WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentReclass WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentFacility WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentRemedy WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentScenario WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentPlanStep WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentPlan WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    DELETE fin.CreditAssessmentTrigger WHERE TenantId = @tenant AND AssessmentId = @AssessmentId;
    INSERT fin.CreditAssessmentFactor (TenantId, AssessmentId, MetricId, FactorCode, Weight, EffectiveWeight, Status, Value, Score, GradeId, Contribution, Reason, CreatedBy)
    SELECT @tenant, @AssessmentId, f.MetricId, f.FactorCode, f.Weight,
           CASE WHEN f.Score IS NOT NULL AND (@rated = 1 OR f.Kind = 'QUANTITATIVE') THEN CAST(f.EffectiveWeight * 100 / @wScored AS DECIMAL(9,4)) END,
           f.Status, CASE WHEN f.Status = 'COMPUTED' THEN CAST(f.Value AS DECIMAL(19,6)) END, CAST(f.Score AS DECIMAL(9,4)), g.RatingGradeId,
           CASE WHEN f.Score IS NOT NULL AND (@rated = 1 OR f.Kind = 'QUANTITATIVE') THEN CAST(f.EffectiveWeight * f.Score / @wScored AS DECIMAL(9,4)) END,
           CASE f.Status WHEN 'EXTREME' THEN CASE WHEN f.Score <= 0.5 THEN N'لا معنى للنسبة لصالح الشركة فتأخذ أفضل طرف (مثل: لا دين)'
                                                  ELSE N'لا معنى للنسبة ضد الشركة فتأخذ أسوأ طرف (مثل: EBITDA أو حقوق ملكية غير موجبة)' END
                         WHEN 'NOT_COMPUTABLE' THEN CASE WHEN f.Kind = 'QUALITATIVE' THEN N'لم يُدخل المحلل درجة العامل أو عوامله الفرعية'
                                                         ELSE N'البنود اللازمة لحسابه غير مدخلة' END END,
           @user
    FROM #crF AS f
    LEFT JOIN fin.RatingGrade AS g ON f.Score IS NOT NULL
         AND g.NotchNo = CASE WHEN FLOOR(f.Score - 0.5) + 1 > 20 THEN 20 WHEN FLOOR(f.Score - 0.5) + 1 < 1 THEN 1 ELSE FLOOR(f.Score - 0.5) + 1 END;
    INSERT fin.CreditAssessmentFinding (TenantId, AssessmentId, SeqNo, Kind, Source, RuleCode, LineCode, RiskLevel, Value, PriorValue, Notches, RefId, TextAr, TextEn, CreatedBy)
    SELECT @tenant, @AssessmentId, x.Ord, x.Kind, x.Source, x.RuleCode, x.LineCode, x.RiskLevel, CAST(x.Value AS DECIMAL(19,6)), CAST(x.PriorValue AS DECIMAL(19,6)),
           x.Notches, x.RefId, x.TextAr, x.TextEn, @user
    FROM @x AS x;
    INSERT fin.CreditAssessmentReclass (TenantId, AssessmentId, SeqNo, AdjCode, LineCode, Bucket, Amount, TextAr, TextEn, CreatedBy)
    SELECT @tenant, @AssessmentId, ROW_NUMBER() OVER (ORDER BY sl.SortOrder, r.AdjCode), r.AdjCode, r.LineCode, r.Bucket, CAST(r.Amount AS DECIMAL(19,4)),
           ISNULL(t.TextAr, r.AdjCode), t.TextEn, @user
    FROM #crR AS r
    LEFT JOIN fin.StandardLine AS sl ON sl.Code = r.LineCode
    LEFT JOIN fin.CreditText AS t ON t.Domain = 'RECLASS' AND t.Code = r.AdjCode;
    INSERT fin.CreditAssessmentFacility (TenantId, AssessmentId, FacilityId, LenderInstitutionId, CurrencyId, RateToStatement, LimitAmount, OutstandingAmount,
                                         SecuredCover, RecoverableCover, IsCommitted, ExpiryDate, IsIncluded, ExclusionReason, CreatedBy)
    SELECT @tenant, @AssessmentId, FacilityId, Lender, CurrencyId, Rate, LimitAmount, Outstanding, Secured, Recoverable, IsCommitted, ExpiryDate, IsIncluded, Reason, @user
    FROM @fac;
    INSERT fin.CreditAssessmentRemedy (TenantId, AssessmentId, SeqNo, RemedyId, TriggerCode, TriggerLevel, MovedAmount, ProFormaScore, ProFormaGradeId, NotchesGained, CreatedBy)
    SELECT @tenant, @AssessmentId, r.SeqNo, r.RemedyId, r.TriggerCode, r.TriggerLevel, CAST(r.Moved AS DECIMAL(19,4)), CAST(r.WeightedScore AS DECIMAL(9,4)), g.RatingGradeId,
           CASE WHEN g.RatingGradeId IS NOT NULL THEN r.NotchesGained END, @user
    FROM #evRem AS r LEFT JOIN fin.RatingGrade AS g ON g.NotchNo = r.FinalNotch;
    INSERT fin.CreditAssessmentScenario (TenantId, AssessmentId, Scenario, RevenueAfter, EbitdaAfter, InventoryValueAfter, Score, GradeId, LiquidityLabel, NotchesLost, CreatedBy)
    SELECT @tenant, @AssessmentId, s.Scenario, CAST(s.Revenue AS DECIMAL(19,4)), CAST(s.Ebitda AS DECIMAL(19,4)), CAST(s.Inventory AS DECIMAL(19,4)),
           CAST(s.WeightedScore AS DECIMAL(9,4)), g.RatingGradeId, s.Liquidity, s.NotchesLost, @user
    FROM #evScen AS s LEFT JOIN fin.RatingGrade AS g ON g.NotchNo = s.FinalNotch;
    INSERT fin.CreditAssessmentPlan (TenantId, AssessmentId, PlanId, StepCount, FinalScore, FinalGradeId, NotchesGained, IsBalanced, CreatedBy)
    SELECT @tenant, @AssessmentId, p.PlanId, p.StepCount, CAST(p.FinalScore AS DECIMAL(9,4)), g.RatingGradeId, p.NotchesGained, p.IsBalanced, @user
    FROM #evPlan AS p JOIN fin.RatingGrade AS g ON g.NotchNo = p.FinalNotch;
    INSERT fin.CreditAssessmentPlanStep (TenantId, AssessmentId, PlanId, StepNo, RemedyId, MovedAmount, Score, GradeId, CreatedBy)
    SELECT @tenant, @AssessmentId, s.PlanId, s.StepNo, s.RemedyId, CAST(s.Moved AS DECIMAL(19,4)), CAST(s.Score AS DECIMAL(9,4)), g.RatingGradeId, @user
    FROM #evPlanStep AS s JOIN #evPlan AS p ON p.PlanId = s.PlanId JOIN fin.RatingGrade AS g ON g.NotchNo = s.FinalNotch;
    INSERT fin.CreditAssessmentTrigger (TenantId, AssessmentId, MetricId, Direction, CurrentValue, TriggerValue, Score, TargetScore, CreatedBy)
    SELECT @tenant, @AssessmentId, t.MetricId, t.Direction, CAST(t.CurrentValue AS DECIMAL(19,6)), CAST(t.TriggerValue AS DECIMAL(19,6)), CAST(t.Score AS DECIMAL(9,4)),
           CAST(t.TargetScore AS DECIMAL(9,4)), @user
    FROM #evTrig AS t;
    UPDATE a
       SET ComputedAt = SYSUTCDATETIME(), InputsHash = h.InputsHash, UsedPriorStatementId = @prior, ResultState = @state, CoveragePct = @coverage,
           FinancialScore = @finScore, FinancialGradeId = (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @finNotch),
           WeightedScore = @agg, IndicatedGradeId = (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @n0),
           AdjustmentNotches = CASE WHEN @rated = 1 THEN @notches END,
           CapGradeId = CASE WHEN @rated = 1 AND (CASE WHEN @capA > @capS THEN @capA ELSE @capS END) > 1
                             THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = CASE WHEN @capA > @capS THEN @capA ELSE @capS END) END,
           StandaloneGradeId = CASE WHEN @rated = 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = CASE WHEN @n2 > 20 THEN 20 ELSE @n2 END) END,
           SupportNotches = CASE WHEN @rated = 1 AND @support IS NOT NULL THEN @n2 - @n3 END,
           OverrideNotches = CASE WHEN @rated = 1 THEN @override END,
           FinalGradeId = CASE WHEN @rated = 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @n5) END,
           FacilityGradeId = CASE WHEN @rated = 1 THEN (SELECT RatingGradeId FROM fin.RatingGrade WHERE NotchNo = @facNotch) END,
           LgdPct = CASE WHEN @rated = 1 THEN CAST(ROUND(@lgd, 2) AS DECIMAL(5,2)) END, LgdBand = CASE WHEN @rated = 1 THEN @band END,
           LiquidityLabel = @liq, CompletenessPct = CAST(ROUND(@comp, 2) AS DECIMAL(5,2)),
           AdjustedDebt = CAST(@adjDebt AS DECIMAL(19,4)), AdjustedTnw = CAST(@adjTnw AS DECIMAL(19,4)), RealisableNetWorth = CAST(@realNw AS DECIMAL(19,4)),
           IndustryId = @industry,
           SectorPosition = CASE WHEN @rated = 0 OR @typ IS NULL THEN NULL WHEN @n5 < @typ - 1 THEN 'ABOVE' WHEN @n5 > @typ + 1 THEN 'BELOW' ELSE 'WITHIN' END,
           Resilience = @resilience, Outlook = @outlook, OutlookRules = @rules, UpHeadroom = CAST(@up AS DECIMAL(9,4)), DownHeadroom = CAST(@down AS DECIMAL(9,4)),
           SummaryAr = @sumAr, SummaryEn = @sumEn, Snapshot = @snapshot, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @user
    FROM fin.CreditAssessment AS a
    CROSS APPLY fin.fn_CreditAssessmentInputsHash(a.TenantId, a.CreditAssessmentId) AS h
    WHERE a.TenantId = @tenant AND a.CreditAssessmentId = @AssessmentId;
    COMMIT TRANSACTION;
END;
GO
/* ---------------------------------------------------------------------------------------------------------------
   The report (FR-FIN-023 to FR-FIN-030): readable by tp_app; the row filters of the tables they read apply.
   --------------------------------------------------------------------------------------------------------------- */
CREATE OR ALTER VIEW fin.v_CreditAssessmentReport
AS
SELECT a.TenantId, a.CreditAssessmentId, a.PublicId, a.CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn, co.IsHolding,
       a.StatementId, s.Basis, s.PeriodType, s.PeriodStart, s.PeriodEnd, s.FiscalYear, s.Assurance, s.AuditorName, s.AuditOpinion,
       s.VersionNo AS StatementVersionNo, s.Status AS StatementStatus, a.PriorStatementId, a.UsedPriorStatementId,
       sc.Code AS ScorecardCode, sc.VersionNo AS ScorecardVersionNo, sc.NameAr AS ScorecardNameAr, sc.NameEn AS ScorecardNameEn,
       a.AssessmentDate, a.FxRateToScorecard, a.Status, a.ResultState, a.CoveragePct, a.FinancialScore, fng.Code AS FinancialGrade, a.WeightedScore,
       ig.Code AS IndicatedGrade, a.AdjustmentNotches, cg.Code AS CapGrade, sg.Code AS StandaloneGrade, a.SupportNotches, a.OverrideNotches,
       fg.Code AS FinalGrade, fg.NotchNo AS FinalNotch, fg.Category AS FinalCategory, fg.RiskBand, fg.IsInvestmentGrade, fg.FitchEquivalent AS FitchGrade,
       fg.DescriptionAr AS FinalGradeDescriptionAr, fg.DescriptionEn AS FinalGradeDescriptionEn,
       facg.Code AS FacilityGrade, facg.FitchEquivalent AS FacilityFitchGrade, a.LgdPct, a.LgdBand,
       CASE WHEN a.LgdBand IS NOT NULL THEN CONCAT('RR', RIGHT(a.LgdBand, 1)) END AS FitchRecoveryRating,
       a.LiquidityLabel, lq.NameAr AS LiquidityNameAr, lq.NameEn AS LiquidityNameEn, a.CompletenessPct,
       a.AdjustedDebt, a.AdjustedTnw, a.RealisableNetWorth,
       a.IndustryId, ind.Code AS IndustryCode, ind.NameAr AS IndustryNameAr, ind.NameEn AS IndustryNameEn, ip.SectorRisk, ip.Cyclicality,
       eb.Code AS SectorBestGrade, et.Code AS SectorTypicalGrade, ew.Code AS SectorWorstGrade, ec.Code AS SectorCeilingGrade, a.SectorPosition,
       a.Resilience, rs.NameAr AS ResilienceNameAr, a.Outlook, ol.NameAr AS OutlookNameAr, ol.NameEn AS OutlookNameEn, a.OutlookRules, a.UpHeadroom, a.DownHeadroom,
       a.StrengtheningRequested,
       n.Strengths, n.PointsToWatch, n.Weaknesses, n.CriticalRisks, n.DataRequests,
       a.SummaryAr, a.SummaryEn, sc.DisclaimerAr, sc.DisclaimerEn,
       CAST(CASE WHEN a.ComputedAt IS NOT NULL AND a.InputsHash = h.InputsHash THEN 1 ELSE 0 END AS BIT) AS IsCurrent,
       a.ComputedAt, a.PreparedBy, a.PreparedOn, a.ApprovedBy, a.ApprovedOn, a.RejectionReason
FROM fin.CreditAssessment AS a
JOIN org.Company AS co ON co.TenantId = a.TenantId AND co.CompanyId = a.CompanyId
JOIN fin.FinancialStatement AS s ON s.TenantId = a.TenantId AND s.FinancialStatementId = a.StatementId
JOIN fin.Scorecard AS sc ON sc.ScorecardId = a.ScorecardId
LEFT JOIN fin.RatingGrade AS fng ON fng.RatingGradeId = a.FinancialGradeId
LEFT JOIN fin.RatingGrade AS ig ON ig.RatingGradeId = a.IndicatedGradeId
LEFT JOIN fin.RatingGrade AS cg ON cg.RatingGradeId = a.CapGradeId
LEFT JOIN fin.RatingGrade AS sg ON sg.RatingGradeId = a.StandaloneGradeId
LEFT JOIN fin.RatingGrade AS fg ON fg.RatingGradeId = a.FinalGradeId
LEFT JOIN fin.RatingGrade AS facg ON facg.RatingGradeId = a.FacilityGradeId
LEFT JOIN ref.Industry AS ind ON ind.IndustryId = a.IndustryId
LEFT JOIN fin.IndustryProfile AS ip ON ip.IndustryId = a.IndustryId
LEFT JOIN fin.RatingGrade AS eb ON eb.RatingGradeId = ip.ExpectedBestGradeId
LEFT JOIN fin.RatingGrade AS et ON et.RatingGradeId = ip.ExpectedTypicalGradeId
LEFT JOIN fin.RatingGrade AS ew ON ew.RatingGradeId = ip.ExpectedWorstGradeId
LEFT JOIN fin.RatingGrade AS ec ON ec.RatingGradeId = ip.CeilingGradeId
LEFT JOIN fin.CreditText AS lq ON lq.Domain = 'LIQUIDITY' AND lq.Code = a.LiquidityLabel
LEFT JOIN fin.CreditText AS rs ON rs.Domain = 'RESILIENCE' AND rs.Code = a.Resilience
LEFT JOIN fin.CreditText AS ol ON ol.Domain = 'OUTLOOK_VIEW' AND ol.Code = a.Outlook
CROSS APPLY fin.fn_CreditAssessmentInputsHash(a.TenantId, a.CreditAssessmentId) AS h
OUTER APPLY (SELECT SUM(CASE WHEN x.Kind = 'STRENGTH' THEN 1 ELSE 0 END) AS Strengths, SUM(CASE WHEN x.Kind = 'WATCH' AND x.Source <> 'DATA' THEN 1 ELSE 0 END) AS PointsToWatch,
                    SUM(CASE WHEN x.Kind = 'WEAKNESS' THEN 1 ELSE 0 END) AS Weaknesses, SUM(CASE WHEN x.Kind = 'CRITICAL_RISK' THEN 1 ELSE 0 END) AS CriticalRisks,
                    SUM(CASE WHEN x.Source = 'DATA' THEN 1 ELSE 0 END) AS DataRequests
             FROM fin.CreditAssessmentFinding AS x WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId) AS n;
GO
CREATE OR ALTER VIEW fin.v_CreditAssessmentFactors
AS
SELECT f.TenantId, f.AssessmentId, f.CreditAssessmentFactorId, f.FactorCode,
       CASE f.FactorCode WHEN 'SCALE' THEN N'الحجم' WHEN 'BUSINESS_PROFILE' THEN N'ملف الأعمال' WHEN 'PROFITABILITY_EFFICIENCY' THEN N'الربحية والكفاءة'
            WHEN 'LEVERAGE_COVERAGE' THEN N'الرفع المالي والتغطية' WHEN 'CAPITAL_SOLVENCY' THEN N'رأس المال والملاءة'
            WHEN 'LIQUIDITY_FUNDING' THEN N'السيولة وهيكل التمويل' WHEN 'BALANCE_SHEET_QUALITY' THEN N'جودة الميزانية' ELSE N'السياسة المالية' END AS FactorNameAr,
       m.Code AS MetricCode, m.NameAr AS MetricNameAr, m.NameEn AS MetricNameEn, m.Unit, m.Direction, m.ThemeCode, f.Weight, f.EffectiveWeight,
       f.Status, f.Value, f.Score, g.Code AS Grade, g.Category AS GradeCategory, f.Contribution, f.Reason, sm.SortOrder
FROM fin.CreditAssessmentFactor AS f
JOIN fin.CreditMetric AS m ON m.CreditMetricId = f.MetricId
JOIN fin.CreditAssessment AS a ON a.TenantId = f.TenantId AND a.CreditAssessmentId = f.AssessmentId
LEFT JOIN fin.ScorecardMetric AS sm ON sm.ScorecardId = a.ScorecardId AND sm.MetricId = f.MetricId
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = f.GradeId;
GO
CREATE OR ALTER VIEW fin.v_CreditAssessmentFindings
AS
SELECT x.TenantId, x.AssessmentId, x.SeqNo, x.Kind, x.Source, x.RuleCode, x.LineCode, x.RiskLevel, x.Value, x.PriorValue, x.Notches, x.RefId,
       x.TextAr, x.TextEn,
       CASE WHEN x.Source = 'DATA' THEN N'بيانات مطلوبة' WHEN x.Kind = 'STRENGTH' THEN N'نقطة قوة' WHEN x.Kind = 'INFO' THEN N'ملاحظة' WHEN x.Kind = 'WATCH' THEN N'للمراقبة'
            WHEN x.Kind = 'WEAKNESS' THEN N'نقطة ضعف' WHEN x.Kind = 'CRITICAL_RISK' THEN N'خطر حرج' ELSE N'تعديل على الدرجة' END AS KindAr
FROM fin.CreditAssessmentFinding AS x;
GO
/* The register of the balance sheet items: each item rule of the assessment's scorecard on its line, with the metric's
   theme, its weight in the scorecard, the risk level the assessment found, and what the item does to cash and to
   solvency (docs/35 section 7). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentItemRegister
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, r.LineCode, sl.NameAr AS LineNameAr, sl.NameEn AS LineNameEn, sl.Section, sl.SortOrder AS LineSortOrder,
       m.Code AS MetricCode, m.NameAr AS MetricNameAr, m.NameEn AS MetricNameEn, m.ThemeCode, m.Unit, m.Direction, r.T1, r.T2, r.T3, r.T4,
       sm.FactorCode, sm.Weight AS ScorecardWeight, x.RiskLevel, x.Kind AS FindingKind, x.Value, x.TextAr AS FindingTextAr,
       m.CashEffectAr, m.CashEffectEn, m.SolvencyEffectAr, m.SolvencyEffectEn, r.SortOrder
FROM fin.CreditAssessment AS a
JOIN fin.ScorecardItemRule AS r ON r.ScorecardId = a.ScorecardId
JOIN fin.CreditMetric AS m ON m.CreditMetricId = r.MetricId
JOIN fin.StandardLine AS sl ON sl.Code = r.LineCode
LEFT JOIN fin.ScorecardMetric AS sm ON sm.ScorecardId = a.ScorecardId AND sm.MetricId = r.MetricId
OUTER APPLY (SELECT TOP (1) f.RiskLevel, f.Kind, f.Value, f.TextAr FROM fin.CreditAssessmentFinding AS f
             WHERE f.TenantId = a.TenantId AND f.AssessmentId = a.CreditAssessmentId AND f.Source = 'ITEM_RULE' AND f.RuleCode = m.Code AND f.LineCode = r.LineCode
             ORDER BY f.SeqNo) AS x;
GO
/* Each line of the assessed statement with its comparison line, its change, its share, and the risk level of its item
   rule in this assessment. */
CREATE OR ALTER VIEW fin.v_CreditAssessmentItems
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, ia.LineCode, ia.NameAr, ia.NameEn, ia.Section, ia.IsTotal, ia.SortOrder,
       ia.Amount, ia.PriorAmount, ia.Change, ia.ChangePct, ia.SharePct, ia.ShareBase,
       r.RuleCode AS ItemRuleCode, r.RiskLevel, r.Kind AS FindingKind, r.TextAr AS FindingTextAr
FROM fin.CreditAssessment AS a
CROSS APPLY fin.fn_StatementItemAnalysis(a.StatementId, a.UsedPriorStatementId) AS ia
OUTER APPLY (SELECT TOP (1) x.RuleCode, x.RiskLevel, x.Kind, x.TextAr
             FROM fin.CreditAssessmentFinding AS x
             WHERE x.TenantId = a.TenantId AND x.AssessmentId = a.CreditAssessmentId AND x.Source = 'ITEM_RULE' AND x.LineCode = ia.LineCode
             ORDER BY CASE x.RiskLevel WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1 WHEN 'ELEVATED' THEN 2 WHEN 'MODERATE' THEN 3 ELSE 4 END, x.SeqNo) AS r
WHERE ia.TenantId = a.TenantId;
GO
/* The reconciliation of the analytical statement: what each standard adjustment moved, from which line, to which
   analytical bucket, and why (docs/35 section 6). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentReclass
AS
SELECT r.TenantId, r.AssessmentId, r.SeqNo, r.AdjCode, t.NameAr AS AdjNameAr, t.NameEn AS AdjNameEn, r.LineCode, sl.NameAr AS LineNameAr, r.Bucket, r.Amount,
       r.TextAr, r.TextEn
FROM fin.CreditAssessmentReclass AS r
LEFT JOIN fin.StandardLine AS sl ON sl.Code = r.LineCode
LEFT JOIN fin.CreditText AS t ON t.Domain = 'RECLASS' AND t.Code = r.AdjCode;
GO
/* The remedies the report proposes: the finding each answers, what it needs, its text and evidence, and the grade
   its pro-forma statement gets (docs/35 section 12). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentRemedies
AS
SELECT r.TenantId, r.AssessmentId, r.SeqNo, cr.Code AS RemedyCode, cr.Kind, cr.NameAr, cr.NameEn, cr.TextAr, cr.TextEn, cr.EvidenceAr, cr.EvidenceEn,
       cr.Funding, fk.NameAr AS FundingNameAr, cr.SetsEvidence, r.TriggerCode, r.TriggerLevel, r.MovedAmount, r.ProFormaScore, g.Code AS ProFormaGrade,
       r.NotchesGained
FROM fin.CreditAssessmentRemedy AS r
JOIN fin.CreditRemedy AS cr ON cr.CreditRemedyId = r.RemedyId
LEFT JOIN fin.CreditText AS fk ON fk.Domain = 'FUNDING' AND fk.Code = cr.Funding
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = r.ProFormaGradeId;
GO
/* The two scenarios of the company's activity (docs/35 section 13). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentScenarios
AS
SELECT s.TenantId, s.AssessmentId, s.Scenario, CASE s.Scenario WHEN 'STAGNANT_MARKET' THEN N'ركود السوق' ELSE N'أزمة مالية' END AS ScenarioNameAr,
       sc.RevenuePct, sc.GrossMarginPp, sc.DsoDays, sc.StLinesWithdrawnPct, sc.RateBp, sc.PrivateArLossPct,
       s.RevenueAfter, s.EbitdaAfter, s.InventoryValueAfter, s.Score, g.Code AS Grade, s.LiquidityLabel, s.NotchesLost
FROM fin.CreditAssessmentScenario AS s
JOIN fin.CreditAssessment AS a ON a.TenantId = s.TenantId AND a.CreditAssessmentId = s.AssessmentId
LEFT JOIN fin.IndustryScenario AS sc ON sc.IndustryId = a.IndustryId AND sc.Scenario = s.Scenario
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = s.GradeId;
GO
/* The facilities read from the platform on the assessment date, with their collateral cover (docs/35 section 10). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentFacilities
AS
SELECT f.TenantId, f.AssessmentId, f.FacilityId, fa.FacilityNo, f.LenderInstitutionId, f.CurrencyId, f.RateToStatement, f.LimitAmount, f.OutstandingAmount,
       f.SecuredCover, f.RecoverableCover, f.IsCommitted, f.ExpiryDate, f.IsIncluded, f.ExclusionReason
FROM fin.CreditAssessmentFacility AS f
JOIN fac.Facility AS fa ON fa.TenantId = f.TenantId AND fa.FacilityId = f.FacilityId;
GO
/* The strengthening plans computed when the customer asked for them, step by step (docs/35 section 12). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentPlans
AS
SELECT p.TenantId, p.AssessmentId, sp.Code AS PlanCode, sp.Kind AS PlanKind, sp.NameAr AS PlanNameAr, sp.NameEn AS PlanNameEn, sp.TextAr AS PlanTextAr,
       p.StepCount, p.FinalScore, g.Code AS FinalGrade, p.NotchesGained, p.IsBalanced, s.StepNo, cr.Code AS RemedyCode, cr.NameAr AS RemedyNameAr,
       cr.Funding, s.MovedAmount, s.Score AS StepScore, sg.Code AS StepGrade, sp.SortOrder
FROM fin.CreditAssessmentPlan AS p
JOIN fin.StrengtheningPlan AS sp ON sp.StrengtheningPlanId = p.PlanId
JOIN fin.RatingGrade AS g ON g.RatingGradeId = p.FinalGradeId
JOIN fin.CreditAssessmentPlanStep AS s ON s.TenantId = p.TenantId AND s.AssessmentId = p.AssessmentId AND s.PlanId = p.PlanId
JOIN fin.CreditRemedy AS cr ON cr.CreditRemedyId = s.RemedyId
JOIN fin.RatingGrade AS sg ON sg.RatingGradeId = s.GradeId;
GO
/* What would move the scorecard grade one notch (docs/35 section 15). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentTriggers
AS
SELECT t.TenantId, t.AssessmentId, m.Code AS MetricCode, m.NameAr AS MetricNameAr, m.NameEn AS MetricNameEn, m.Unit, m.Direction AS MetricDirection,
       t.Direction, t.CurrentValue, t.TriggerValue, t.Score, t.TargetScore
FROM fin.CreditAssessmentTrigger AS t
JOIN fin.CreditMetric AS m ON m.CreditMetricId = t.MetricId;
GO
/* The covenants tested on the assessed statement (their latest evaluation) and the breach record of each. */
CREATE OR ALTER VIEW fin.v_CreditAssessmentCovenants
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, t.CovenantTestId, t.CovenantRootId, t.CovenantId, c.MeasureKind,
       mf.Code AS FormulaCode, mf.NameAr AS FormulaNameAr, o.ClauseRef, o.FacilityId, t.PeriodStart, t.PeriodEnd, t.EvaluationNo, t.Result,
       t.ActualValue, t.OperatorApplied, t.ThresholdApplied, t.Headroom, t.HeadroomPct, b.ObligationBreachId, b.Status AS BreachStatus
FROM fin.CreditAssessment AS a
JOIN obl.CovenantTestStatement AS ts ON ts.TenantId = a.TenantId AND ts.StatementId = a.StatementId
JOIN obl.CovenantTest AS t ON t.TenantId = ts.TenantId AND t.CovenantTestId = ts.CovenantTestId
JOIN obl.Covenant AS c ON c.TenantId = t.TenantId AND c.CovenantId = t.CovenantId
JOIN obl.Obligation AS o ON o.TenantId = c.TenantId AND o.ObligationId = c.ObligationId
LEFT JOIN fin.MeasureFormula AS mf ON mf.TenantId = t.TenantId AND mf.MeasureFormulaId = t.FormulaId
OUTER APPLY (SELECT TOP (1) x.ObligationBreachId, x.Status
             FROM obl.ObligationBreach AS x
             WHERE x.TenantId = t.TenantId AND x.CovenantRootId = t.CovenantRootId AND x.TestPeriodEnd = t.PeriodEnd
             ORDER BY CASE WHEN x.Status IN ('OPEN','IN_CURE') THEN 0 ELSE 1 END, x.ObligationBreachId DESC) AS b
WHERE t.State IN ('EVALUATED','REVIEWED')
  AND t.EvaluationNo = (SELECT MAX(y.EvaluationNo) FROM obl.CovenantTest AS y
                        WHERE y.TenantId = t.TenantId AND y.CovenantRootId = t.CovenantRootId AND y.PeriodEnd = t.PeriodEnd AND y.State IN ('EVALUATED','REVIEWED'));
GO
/* For an assessment of a consolidated statement: each unit, with the latest approved assessment of its own standalone
   statement for the period (FR-FIN-015, FR-FIN-022). */
CREATE OR ALTER VIEW fin.v_CreditAssessmentGroupUnits
AS
SELECT a.TenantId, a.CreditAssessmentId AS AssessmentId, u.MemberCompanyId, u.Role, u.Method, u.OwnershipPct, u.RecordedOwnershipPct,
       u.StandaloneStatementId, ua.CreditAssessmentId AS UnitAssessmentId, g.Code AS UnitFinalGrade, g.RiskBand AS UnitRiskBand
FROM fin.CreditAssessment AS a
JOIN fin.v_ConsolidationUnits AS u ON u.TenantId = a.TenantId AND u.StatementId = a.StatementId
OUTER APPLY (SELECT TOP (1) x.CreditAssessmentId, x.FinalGradeId
             FROM fin.CreditAssessment AS x
             WHERE x.TenantId = a.TenantId AND x.StatementId = u.StandaloneStatementId AND x.Status = 'APPROVED') AS ua
LEFT JOIN fin.RatingGrade AS g ON g.RatingGradeId = ua.FinalGradeId;
GO
GRANT EXECUTE ON fin.usp_ComputeCreditAssessment TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentReport TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentFactors TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentFindings TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentItemRegister TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentItems TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentReclass TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentRemedies TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentScenarios TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentFacilities TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentPlans TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentTriggers TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentCovenants TO [tp_app];
GRANT SELECT ON fin.v_CreditAssessmentGroupUnits TO [tp_app];
GRANT SELECT ON fin.fn_StatementItemAnalysis TO [tp_app];
GO
-- The application writes the assessment's own fields and inputs; its results only the computation writes.
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentFactor] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentFinding] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentReclass] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentFacility] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentRemedy] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentScenario] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentPlan] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentPlanStep] TO [tp_app];
DENY INSERT, UPDATE, DELETE ON [fin].[CreditAssessmentTrigger] TO [tp_app];
DENY UPDATE ON [fin].[CreditAssessment]([ComputedAt], [InputsHash], [UsedPriorStatementId], [ResultState], [CoveragePct], [FinancialScore], [FinancialGradeId],
    [WeightedScore], [IndicatedGradeId], [AdjustmentNotches], [CapGradeId], [StandaloneGradeId], [SupportNotches], [OverrideNotches], [FinalGradeId],
    [FacilityGradeId], [LgdPct], [LgdBand], [LiquidityLabel], [CompletenessPct], [AdjustedDebt], [AdjustedTnw], [RealisableNetWorth], [IndustryId],
    [SectorPosition], [Resilience], [Outlook], [OutlookRules], [UpHeadroom], [DownHeadroom], [SummaryAr], [SummaryEn], [Snapshot]) TO [tp_app];
GO
