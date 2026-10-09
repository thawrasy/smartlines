/* BFMS - 003: بيانات مرجعية أولية قابلة للتعديل (إعادة التنفيذ آمنة) */
SET NOCOUNT ON;
GO
USE BankFacilities;
GO
INSERT ref.Currency(CurrencyCode,NameAr,NameEn,DecimalPlaces)
SELECT v.* FROM (VALUES
 ('SAR',N'ريال سعودي',N'Saudi Riyal',2),('USD',N'دولار أمريكي',N'US Dollar',2),('EUR',N'يورو',N'Euro',2),
 ('AED',N'درهم إماراتي',N'UAE Dirham',2),('KWD',N'دينار كويتي',N'Kuwaiti Dinar',3),('BHD',N'دينار بحريني',N'Bahraini Dinar',3),
 ('QAR',N'ريال قطري',N'Qatari Riyal',2),('OMR',N'ريال عماني',N'Omani Rial',3),('EGP',N'جنيه مصري',N'Egyptian Pound',2),
 ('JOD',N'دينار أردني',N'Jordanian Dinar',3),('GBP',N'جنيه إسترليني',N'Pound Sterling',2)
) v(c,a,e,d) WHERE NOT EXISTS (SELECT 1 FROM ref.Currency x WHERE x.CurrencyCode=v.c);

INSERT ref.EntityType(EntityTypeId,Code,NameAr,NameEn,IsFinancier)
SELECT v.* FROM (VALUES
 (1,'BANK',N'بنك',N'Bank',1),(2,'FINANCE_CO',N'شركة تمويل',N'Finance Company',1),
 (3,'PRIVATE_CO',N'شركة خاصة',N'Private Company',1),(4,'INDIVIDUAL',N'فرد',N'Individual',1)
) v(i,c,a,e,f) WHERE NOT EXISTS (SELECT 1 FROM ref.EntityType x WHERE x.Code=v.c);

INSERT ref.Lookup(LookupGroup,Code,NameAr,NameEn,SortOrder)
SELECT v.* FROM (VALUES
 ('CONTACT_ROLE','RM',N'مدير علاقة',N'Relationship Manager',1),
 ('CONTACT_ROLE','TEAM_LEAD',N'مدير فريق',N'Team Leader',2),
 ('CONTACT_ROLE','REGIONAL_MGR',N'مدير إقليمي',N'Regional Manager',3),
 ('CONTACT_ROLE','DEPT_HEAD',N'مدير إدارة',N'Department Head',4),
 ('CONTACT_ROLE','OPS_OFFICER',N'مسؤول عمليات',N'Operations Officer',5),
 ('CONTACT_ROLE','OTHER',N'أخرى',N'Other',9),
 ('DEPARTMENT_TYPE','CORPORATE',N'الخدمات المصرفية للشركات',N'Corporate Banking',1),
 ('DEPARTMENT_TYPE','TRADE',N'التمويل التجاري',N'Trade Finance',2),
 ('DEPARTMENT_TYPE','GUARANTEES',N'الضمانات',N'Guarantees',3),
 ('DEPARTMENT_TYPE','TREASURY',N'الخزينة',N'Treasury',4),
 ('DEPARTMENT_TYPE','CREDIT',N'الائتمان',N'Credit',5),
 ('DEPARTMENT_TYPE','OPERATIONS',N'العمليات',N'Operations',6),
 ('DEPARTMENT_TYPE','OTHER',N'أخرى',N'Other',9),
 ('CONDITION_TYPE','PRECEDENT_DOC',N'مستند شرط سابق',N'Condition Precedent Document',1),
 ('CONDITION_TYPE','INSURANCE',N'تأمين',N'Insurance',2),
 ('CONDITION_TYPE','ACCOUNT_TURNOVER',N'حركة حسابات',N'Account Turnover',3),
 ('CONDITION_TYPE','REPORTING',N'تقارير دورية',N'Periodic Reporting',4),
 ('CONDITION_TYPE','USE_OF_FUNDS',N'غرض الاستخدام',N'Use of Funds',5),
 ('CONDITION_TYPE','OTHER',N'أخرى',N'Other',9)
) v(g,c,a,e,s) WHERE NOT EXISTS (SELECT 1 FROM ref.Lookup x WHERE x.LookupGroup=v.g AND x.Code=v.c);

-- أسعار الأساس: TARIFF هنا مثال لسعر بنك داخلي ويُعرَّف لكل بنك بعد إنشائه
INSERT ref.BaseRate(Code,NameAr,NameEn,RateKind,CurrencyCode)
SELECT v.* FROM (VALUES
 ('SIBOR',N'سعر الفائدة بين البنوك السعودي (سايبور)',N'Saudi Interbank Offered Rate','MARKET','SAR'),
 ('EIBOR',N'سعر الفائدة بين البنوك الإماراتي',N'Emirates Interbank Offered Rate','MARKET','AED'),
 ('SOFR',N'سعر التمويل المضمون لليلة واحدة',N'Secured Overnight Financing Rate','MARKET','USD'),
 ('EURIBOR',N'يوريبور',N'Euro Interbank Offered Rate','MARKET','EUR')
) v(c,a,e,k,cu) WHERE NOT EXISTS (SELECT 1 FROM ref.BaseRate x WHERE x.Code=v.c);

INSERT cat.FacilityType(Code,NameAr,NameEn)
SELECT v.* FROM (VALUES
 ('WORKING_CAPITAL',N'رأس مال عامل',N'Working Capital'),('TERM',N'تمويل لأجل',N'Term Financing'),
 ('TRADE',N'تمويل تجاري',N'Trade Finance'),('GUARANTEE',N'خطابات ضمان',N'Guarantee Line'),
 ('PROJECT',N'تمويل مشاريع',N'Project Financing'),('MIXED',N'تسهيل مختلط',N'Multi-purpose Facility')
) v(c,a,e) WHERE NOT EXISTS (SELECT 1 FROM cat.FacilityType x WHERE x.Code=v.c);

INSERT cat.Product(Code,NameAr,NameEn,ProductGroup)
SELECT v.* FROM (VALUES
 ('LC_SIGHT',N'اعتماد مستندي اطلاع',N'Documentary LC - Sight','TRADE'),
 ('LC_USANCE',N'اعتماد مستندي آجل',N'Documentary LC - Usance','TRADE'),
 ('LG_BID',N'خطاب ضمان ابتدائي',N'Bid Bond Guarantee','GUARANTEE'),
 ('LG_PERF',N'خطاب ضمان حسن تنفيذ',N'Performance Guarantee','GUARANTEE'),
 ('LG_ADV',N'خطاب ضمان دفعة مقدمة',N'Advance Payment Guarantee','GUARANTEE'),
 ('BILL_DISC',N'خصم أوراق تجارية',N'Bills Discounting','TRADE'),
 ('MURABAHA',N'مرابحة',N'Murabaha','FINANCING'),
 ('TAWARRUQ',N'تورق',N'Tawarruq','FINANCING'),
 ('WC_LOAN',N'قرض رأس مال عامل',N'Working Capital Loan','FINANCING'),
 ('TERM_LOAN',N'قرض لأجل',N'Term Loan','FINANCING'),
 ('OVERDRAFT',N'حساب جاري مدين',N'Overdraft','FINANCING'),
 ('FACTORING',N'تخصيم فواتير',N'Factoring','TRADE'),
 ('SCF',N'تمويل سلسلة الإمداد',N'Supply Chain Finance','TRADE'),
 ('SHIP_GTE',N'ضمان شحن',N'Shipping Guarantee','GUARANTEE'),
 ('FX_FWD',N'عقود صرف آجلة',N'FX Forward','TREASURY')
) v(c,a,e,g) WHERE NOT EXISTS (SELECT 1 FROM cat.Product x WHERE x.Code=v.c);

INSERT cat.FeeType(Code,NameAr,NameEn,FeeCategory)
SELECT v.* FROM (VALUES
 ('ISSUANCE_COMM',N'عمولة إصدار',N'Issuance Commission','ISSUANCE'),
 ('ACCEPTANCE_COMM',N'عمولة قبول',N'Acceptance Commission','COMMISSION'),
 ('NEGOTIATION_COMM',N'عمولة تداول مستندات',N'Negotiation Commission','COMMISSION'),
 ('AMENDMENT_FEE',N'رسوم تعديل',N'Amendment Fee','AMENDMENT'),
 ('ARRANGEMENT_FEE',N'رسوم ترتيب',N'Arrangement / Upfront Fee','UPFRONT'),
 ('COMMITMENT_FEE',N'عمولة التزام',N'Commitment Fee','COMMISSION'),
 ('SWIFT_FEE',N'رسوم سويفت',N'SWIFT Charges','ADMIN'),
 ('ADMIN_FEE',N'رسوم إدارية',N'Administrative Fee','ADMIN'),
 ('LATE_PENALTY',N'غرامة تأخير',N'Late Payment Penalty','PENALTY'),
 ('EARLY_SETTLE',N'رسوم سداد مبكر',N'Early Settlement Fee','PENALTY')
) v(c,a,e,k) WHERE NOT EXISTS (SELECT 1 FROM cat.FeeType x WHERE x.Code=v.c);

INSERT cat.FinancingType(Code,NameAr,NameEn,IsIslamic)
SELECT v.* FROM (VALUES
 ('CONV_LOAN',N'قرض تقليدي',N'Conventional Loan',0),('OVERDRAFT_INT',N'فائدة السحب على المكشوف',N'Overdraft Interest',0),
 ('MURABAHA_PROFIT',N'ربح مرابحة',N'Murabaha Profit',1),('TAWARRUQ_PROFIT',N'ربح تورق',N'Tawarruq Profit',1),
 ('IJARA',N'إجارة',N'Ijara',1),('DISCOUNT_RATE',N'معدل خصم',N'Discount Rate',0)
) v(c,a,e,i) WHERE NOT EXISTS (SELECT 1 FROM cat.FinancingType x WHERE x.Code=v.c);

INSERT cat.LimitType(Code,NameAr,NameEn,IsSubLimit)
SELECT v.* FROM (VALUES
 ('TRADE_MAIN',N'حد التمويل التجاري',N'Trade Finance Limit',0),
 ('FIN_MAIN',N'حد التمويل',N'Financing Limit',0),
 ('GUAR_MAIN',N'حد الضمانات',N'Guarantees Limit',0),
 ('TREAS_MAIN',N'حد الخزينة',N'Treasury Limit',0)
) v(c,a,e,s) WHERE NOT EXISTS (SELECT 1 FROM cat.LimitType x WHERE x.Code=v.c);
INSERT cat.LimitType(Code,NameAr,NameEn,IsSubLimit,ParentLimitTypeId)
SELECT v.c,v.a,v.e,1,p.LimitTypeId FROM (VALUES
 ('LC_SUB',N'حد جزئي - اعتمادات',N'LC Sub-limit','TRADE_MAIN'),
 ('BILLS_SUB',N'حد جزئي - خصم أوراق',N'Bills Sub-limit','TRADE_MAIN'),
 ('LG_SUB',N'حد جزئي - خطابات ضمان',N'LG Sub-limit','GUAR_MAIN'),
 ('MURABAHA_SUB',N'حد جزئي - مرابحة',N'Murabaha Sub-limit','FIN_MAIN'),
 ('OD_SUB',N'حد جزئي - مكشوف',N'Overdraft Sub-limit','FIN_MAIN')
) v(c,a,e,pc) JOIN cat.LimitType p ON p.Code=v.pc
WHERE NOT EXISTS (SELECT 1 FROM cat.LimitType x WHERE x.Code=v.c);

INSERT cat.CollateralType(Code,NameAr,NameEn,Category,RequiresValuation,AttributesTemplate)
SELECT v.* FROM (VALUES
 ('LAND_DEED',N'صك أرض',N'Land Title Deed','REAL_ESTATE',1,N'{"deedNo":"","city":"","district":"","areaSqm":0,"plotNo":""}'),
 ('BUILDING_DEED',N'صك عقار مبني',N'Building Title Deed','REAL_ESTATE',1,N'{"deedNo":"","city":"","areaSqm":0}'),
 ('PROMISSORY_NOTE',N'سند لأمر',N'Promissory Note','PROMISSORY_NOTE',0,N'{"noteNo":"","issueDate":"","maturity":""}'),
 ('PERSONAL_GUARANTEE',N'ضمان شخصي',N'Personal Guarantee','PERSONAL_GUARANTEE',0,N'{"guarantorNationalId":""}'),
 ('CORPORATE_GUARANTEE',N'ضمان شركة',N'Corporate Guarantee','CORPORATE_GUARANTEE',0,N'{"guarantorCR":""}'),
 ('DISCOUNT_AUTH',N'تفويض خصم',N'Direct Debit / Discount Authorization','DISCOUNT_AUTHORIZATION',0,N'{"accountNo":"","scope":""}'),
 ('CASH_MARGIN',N'تأمين نقدي',N'Cash Margin','CASH',0,NULL),
 ('RECEIVABLES',N'تنازل عن مستحقات',N'Assignment of Receivables','RECEIVABLE_ASSIGNMENT',0,N'{"contractNo":"","debtor":""}'),
 ('VEHICLES',N'مركبات / معدات',N'Vehicles / Equipment','VEHICLE_EQUIPMENT',1,N'{"serialNo":"","model":""}'),
 ('SHARES',N'أسهم / أوراق مالية',N'Shares / Securities','SECURITIES',1,N'{"issuer":"","quantity":0}')
) v(c,a,e,k,r,t) WHERE NOT EXISTS (SELECT 1 FROM cat.CollateralType x WHERE x.Code=v.c);

INSERT cat.CovenantType(Code,NameAr,NameEn,Category,MetricUnit,DefaultOperator)
SELECT v.* FROM (VALUES
 ('FS_ANNUAL',N'تقديم قوائم مالية سنوية مدققة',N'Audited Annual Financial Statements','REPORTING','NONE',NULL),
 ('FS_QUARTERLY',N'تقديم قوائم مالية ربع سنوية',N'Quarterly Financial Statements','REPORTING','NONE',NULL),
 ('CURRENT_RATIO',N'نسبة التداول',N'Current Ratio','FINANCIAL_RATIO','RATIO','>='),
 ('QUICK_RATIO',N'نسبة السيولة السريعة',N'Quick Ratio','FINANCIAL_RATIO','RATIO','>='),
 ('DEBT_TO_EQUITY',N'الرافعة المالية (الدين إلى حقوق الملكية)',N'Debt to Equity','FINANCIAL_RATIO','RATIO','<='),
 ('DSCR',N'نسبة تغطية خدمة الدين',N'Debt Service Coverage Ratio','FINANCIAL_RATIO','RATIO','>='),
 ('NET_WORTH',N'الحد الأدنى لصافي الثروة',N'Minimum Tangible Net Worth','FINANCIAL_RATIO','AMOUNT','>='),
 ('DIVIDEND_LIMIT',N'قيد على توزيع الأرباح',N'Dividend Restriction','OPERATIONAL','NONE',NULL),
 ('OWNERSHIP_CHANGE',N'عدم تغيير هيكل الملكية',N'No Change of Ownership','OPERATIONAL','NONE',NULL)
) v(c,a,e,k,u,o) WHERE NOT EXISTS (SELECT 1 FROM cat.CovenantType x WHERE x.Code=v.c);

-- ربط المنتجات بالمصاريف والتمويل (نموذج أولي)
INSERT cat.ProductFeeType(ProductId,FeeTypeId,IsMandatory,SortOrder)
SELECT p.ProductId, f.FeeTypeId, v.m, v.s FROM (VALUES
 ('LC_SIGHT','ISSUANCE_COMM',1,1),('LC_SIGHT','AMENDMENT_FEE',0,2),('LC_SIGHT','NEGOTIATION_COMM',0,3),('LC_SIGHT','SWIFT_FEE',0,4),
 ('LC_USANCE','ISSUANCE_COMM',1,1),('LC_USANCE','ACCEPTANCE_COMM',1,2),('LC_USANCE','AMENDMENT_FEE',0,3),('LC_USANCE','SWIFT_FEE',0,4),
 ('LG_BID','ISSUANCE_COMM',1,1),('LG_PERF','ISSUANCE_COMM',1,1),('LG_ADV','ISSUANCE_COMM',1,1),
 ('LG_PERF','AMENDMENT_FEE',0,2),('LG_ADV','AMENDMENT_FEE',0,2),
 ('MURABAHA','ARRANGEMENT_FEE',0,1),('TAWARRUQ','ARRANGEMENT_FEE',0,1),('TERM_LOAN','ARRANGEMENT_FEE',0,1),
 ('TERM_LOAN','EARLY_SETTLE',0,2),('WC_LOAN','ARRANGEMENT_FEE',0,1),('OVERDRAFT','COMMITMENT_FEE',0,1),
 ('BILL_DISC','ADMIN_FEE',0,1),('FACTORING','ADMIN_FEE',0,1),('SCF','ADMIN_FEE',0,1)
) v(pc,fc,m,s)
JOIN cat.Product p ON p.Code=v.pc JOIN cat.FeeType f ON f.Code=v.fc
WHERE NOT EXISTS (SELECT 1 FROM cat.ProductFeeType x WHERE x.ProductId=p.ProductId AND x.FeeTypeId=f.FeeTypeId);

INSERT cat.ProductFinancingType(ProductId,FinancingTypeId)
SELECT p.ProductId, f.FinancingTypeId FROM (VALUES
 ('LC_USANCE','CONV_LOAN'),('MURABAHA','MURABAHA_PROFIT'),('TAWARRUQ','TAWARRUQ_PROFIT'),
 ('WC_LOAN','CONV_LOAN'),('TERM_LOAN','CONV_LOAN'),('OVERDRAFT','OVERDRAFT_INT'),('BILL_DISC','DISCOUNT_RATE'),
 ('FACTORING','DISCOUNT_RATE'),('SCF','DISCOUNT_RATE')
) v(pc,fc)
JOIN cat.Product p ON p.Code=v.pc JOIN cat.FinancingType f ON f.Code=v.fc
WHERE NOT EXISTS (SELECT 1 FROM cat.ProductFinancingType x WHERE x.ProductId=p.ProductId AND x.FinancingTypeId=f.FinancingTypeId);

INSERT cat.LimitTypeProduct(LimitTypeId,ProductId)
SELECT l.LimitTypeId, p.ProductId FROM (VALUES
 ('TRADE_MAIN','LC_SIGHT'),('TRADE_MAIN','LC_USANCE'),('TRADE_MAIN','BILL_DISC'),('TRADE_MAIN','FACTORING'),('TRADE_MAIN','SCF'),('TRADE_MAIN','SHIP_GTE'),
 ('LC_SUB','LC_SIGHT'),('LC_SUB','LC_USANCE'),('BILLS_SUB','BILL_DISC'),
 ('GUAR_MAIN','LG_BID'),('GUAR_MAIN','LG_PERF'),('GUAR_MAIN','LG_ADV'),('LG_SUB','LG_BID'),('LG_SUB','LG_PERF'),('LG_SUB','LG_ADV'),
 ('FIN_MAIN','MURABAHA'),('FIN_MAIN','TAWARRUQ'),('FIN_MAIN','WC_LOAN'),('FIN_MAIN','TERM_LOAN'),('FIN_MAIN','OVERDRAFT'),
 ('MURABAHA_SUB','MURABAHA'),('OD_SUB','OVERDRAFT'),('TREAS_MAIN','FX_FWD')
) v(lc,pc)
JOIN cat.LimitType l ON l.Code=v.lc JOIN cat.Product p ON p.Code=v.pc
WHERE NOT EXISTS (SELECT 1 FROM cat.LimitTypeProduct x WHERE x.LimitTypeId=l.LimitTypeId AND x.ProductId=p.ProductId);

INSERT sec.Role(Code,NameAr,NameEn)
SELECT v.* FROM (VALUES
 ('ADMIN',N'مدير النظام',N'System Administrator'),
 ('FACILITY_MGR',N'مسؤول التسهيلات',N'Facility Manager'),
 ('APPROVER',N'معتمد',N'Approver'),
 ('VIEWER',N'عرض فقط',N'Read-only')
) v(c,a,e) WHERE NOT EXISTS (SELECT 1 FROM sec.Role x WHERE x.Code=v.c);
GO
