/* ============================================================================
   نظام إدارة التسهيلات البنكية (Bank Facilities Management System - BFMS)
   سكربت إنشاء قاعدة البيانات - الإصدار 0.1 (نواة المرحلة الأولى)
   المنصة المستهدفة : Microsoft SQL Server 2019+ على Windows (يعمل أيضًا على 2022)
   الترميز          : احفظ الملف بصيغة UTF-8 with BOM، أو نفّذه عبر: sqlcmd -f 65001
   التنفيذ          : 001_schema.sql ثم 002_views_functions.sql ثم 003_seed_reference.sql
   ملاحظة          : السكربت قابل لإعادة التنفيذ على قاعدة فارغة فقط (غير تدميري).
   ============================================================================ */
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
IF DB_ID(N'BankFacilities') IS NULL
    CREATE DATABASE BankFacilities COLLATE Arabic_100_CI_AS;
GO
USE BankFacilities;
GO
-- ---------------------------------------------------------------------------
-- المخططات (Schemas)
-- ---------------------------------------------------------------------------
DECLARE @s TABLE (n sysname);
INSERT @s VALUES (N'ref'),(N'org'),(N'fin'),(N'cat'),(N'fac'),(N'pr'),(N'cov'),(N'col'),(N'doc'),(N'sec'),(N'aud');
DECLARE @n sysname, @sql nvarchar(200);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT n FROM @s;
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF SCHEMA_ID(@n) IS NULL
    BEGIN
        SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@n) + N' AUTHORIZATION dbo;';
        EXEC (@sql);
    END
    FETCH NEXT FROM c INTO @n;
END
CLOSE c; DEALLOCATE c;
GO

/* ===========================================================================
   1) ref : جداول مرجعية عامة
   =========================================================================== */
CREATE TABLE ref.Currency (
    CurrencyCode   CHAR(3)       NOT NULL CONSTRAINT PK_Currency PRIMARY KEY,
    NameAr         NVARCHAR(100) NOT NULL,
    NameEn         NVARCHAR(100) NOT NULL,
    DecimalPlaces  TINYINT       NOT NULL CONSTRAINT DF_Currency_Dec DEFAULT 2,
    IsActive       BIT           NOT NULL CONSTRAINT DF_Currency_Act DEFAULT 1
);

-- أنواع المنشآت: بنك / شركة تمويل / شركة خاصة / فرد
CREATE TABLE ref.EntityType (
    EntityTypeId   SMALLINT      NOT NULL CONSTRAINT PK_EntityType PRIMARY KEY,
    Code           VARCHAR(30)   NOT NULL CONSTRAINT UQ_EntityType_Code UNIQUE,
    NameAr         NVARCHAR(100) NOT NULL,
    NameEn         NVARCHAR(100) NOT NULL,
    IsFinancier    BIT           NOT NULL,          -- هل يصلح كجهة ممولة
    IsActive       BIT           NOT NULL CONSTRAINT DF_EntityType_Act DEFAULT 1
);

-- قوائم قيم قابلة للتوسعة (أدوار الاتصال، أنواع الأقسام، أنواع الشروط ...)
CREATE TABLE ref.Lookup (
    LookupId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Lookup PRIMARY KEY,
    LookupGroup    VARCHAR(40)   NOT NULL,          -- CONTACT_ROLE, DEPARTMENT_TYPE, CONDITION_TYPE
    Code           VARCHAR(40)   NOT NULL,
    NameAr         NVARCHAR(150) NOT NULL,
    NameEn         NVARCHAR(150) NOT NULL,
    SortOrder      SMALLINT      NOT NULL CONSTRAINT DF_Lookup_Sort DEFAULT 0,
    IsActive       BIT           NOT NULL CONSTRAINT DF_Lookup_Act DEFAULT 1,
    CONSTRAINT UQ_Lookup UNIQUE (LookupGroup, Code)
);
GO

/* ===========================================================================
   2) org : الشركات (قابضة / تابعة / مستقلة)
   =========================================================================== */
CREATE TABLE org.Company (
    CompanyId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Company PRIMARY KEY,
    Code              VARCHAR(20)   NOT NULL CONSTRAINT UQ_Company_Code UNIQUE,
    NameAr            NVARCHAR(200) NOT NULL,
    NameEn            NVARCHAR(200) NULL,
    ParentCompanyId   INT           NULL CONSTRAINT FK_Company_Parent REFERENCES org.Company(CompanyId),
    IsHolding         BIT           NOT NULL CONSTRAINT DF_Company_Hold DEFAULT 0,
    CommercialRegNo   VARCHAR(30)   NULL,
    TaxNo             VARCHAR(30)   NULL,
    CountryCode       CHAR(2)       NOT NULL CONSTRAINT DF_Company_Ctry DEFAULT 'SA',
    FunctionalCurrency CHAR(3)      NOT NULL CONSTRAINT FK_Company_Cur REFERENCES ref.Currency(CurrencyCode),
    IsActive          BIT           NOT NULL CONSTRAINT DF_Company_Act DEFAULT 1,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Company_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Company_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT CK_Company_NotSelf CHECK (ParentCompanyId IS NULL OR ParentCompanyId <> CompanyId)
);
CREATE UNIQUE INDEX UX_Company_CR ON org.Company(CommercialRegNo) WHERE CommercialRegNo IS NOT NULL;
GO

/* ===========================================================================
   3) fin : الجهات الممولة (بنوك / شركات تمويل / ...) وأقسامها وجهات الاتصال
   =========================================================================== */
CREATE TABLE fin.Institution (
    InstitutionId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Institution PRIMARY KEY,
    Code           VARCHAR(20)   NOT NULL CONSTRAINT UQ_Institution_Code UNIQUE,
    NameAr         NVARCHAR(200) NOT NULL,
    NameEn         NVARCHAR(200) NULL,
    EntityTypeId   SMALLINT      NOT NULL CONSTRAINT FK_Institution_Type REFERENCES ref.EntityType(EntityTypeId),
    CountryCode    CHAR(2)       NOT NULL CONSTRAINT DF_Institution_Ctry DEFAULT 'SA',
    SwiftCode      VARCHAR(11)   NULL,
    LicenseNo      VARCHAR(50)   NULL,
    Website        VARCHAR(200)  NULL,
    Address        NVARCHAR(400) NULL,
    Notes          NVARCHAR(1000) NULL,
    IsActive       BIT           NOT NULL CONSTRAINT DF_Institution_Act DEFAULT 1,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Institution_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Institution_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL
);

-- الأقسام التي يتم التواصل معها (تمويل تجاري، ضمانات، خزينة، ائتمان ...)
CREATE TABLE fin.Department (
    DepartmentId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Department PRIMARY KEY,
    InstitutionId    INT           NOT NULL CONSTRAINT FK_Department_Inst REFERENCES fin.Institution(InstitutionId),
    DepartmentTypeId INT           NOT NULL CONSTRAINT FK_Department_Type REFERENCES ref.Lookup(LookupId),
    NameAr           NVARCHAR(200) NOT NULL,
    NameEn           NVARCHAR(200) NULL,
    Phone            VARCHAR(30)   NULL,
    Email            VARCHAR(200)  NULL,
    IsActive         BIT           NOT NULL CONSTRAINT DF_Department_Act DEFAULT 1,
    CONSTRAINT UQ_Department UNIQUE (InstitutionId, DepartmentId),
    CONSTRAINT UQ_Department_Name UNIQUE (InstitutionId, NameAr)
);

-- جهات الاتصال: مدير علاقة، مدير فريق، مدير إقليمي، مدير إدارة ...
CREATE TABLE fin.Contact (
    ContactId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Contact PRIMARY KEY,
    InstitutionId    INT           NOT NULL CONSTRAINT FK_Contact_Inst REFERENCES fin.Institution(InstitutionId),
    DepartmentId     INT           NULL,
    ContactRoleId    INT           NOT NULL CONSTRAINT FK_Contact_Role REFERENCES ref.Lookup(LookupId),
    FullNameAr       NVARCHAR(200) NOT NULL,
    FullNameEn       NVARCHAR(200) NULL,
    JobTitle         NVARCHAR(150) NULL,
    ReportsToContactId INT         NULL,           -- التسلسل الإداري داخل الجهة الممولة
    Phone            VARCHAR(30)   NULL,
    Mobile           VARCHAR(30)   NULL,
    Email            VARCHAR(200)  NULL,
    IsActive         BIT           NOT NULL CONSTRAINT DF_Contact_Act DEFAULT 1,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Contact_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Contact_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT UQ_Contact UNIQUE (InstitutionId, ContactId),
    CONSTRAINT FK_Contact_Dept   FOREIGN KEY (InstitutionId, DepartmentId)      REFERENCES fin.Department(InstitutionId, DepartmentId),
    CONSTRAINT FK_Contact_Parent FOREIGN KEY (InstitutionId, ReportsToContactId) REFERENCES fin.Contact(InstitutionId, ContactId)
);
GO

/* ===========================================================================
   4) ref : أسعار الأساس (SIBOR / TARIFF ...)
   =========================================================================== */
CREATE TABLE ref.BaseRate (
    BaseRateId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_BaseRate PRIMARY KEY,
    Code           VARCHAR(30)   NOT NULL CONSTRAINT UQ_BaseRate_Code UNIQUE,
    NameAr         NVARCHAR(150) NOT NULL,
    NameEn         NVARCHAR(150) NOT NULL,
    RateKind       VARCHAR(15)   NOT NULL CONSTRAINT CK_BaseRate_Kind CHECK (RateKind IN ('MARKET','BANK_INTERNAL')),
    InstitutionId  INT           NULL CONSTRAINT FK_BaseRate_Inst REFERENCES fin.Institution(InstitutionId), -- مالك السعر إن كان سعر بنك
    CurrencyCode   CHAR(3)       NOT NULL CONSTRAINT FK_BaseRate_Cur REFERENCES ref.Currency(CurrencyCode),
    IsActive       BIT           NOT NULL CONSTRAINT DF_BaseRate_Act DEFAULT 1,
    CONSTRAINT CK_BaseRate_Owner CHECK (RateKind = 'MARKET' OR InstitutionId IS NOT NULL)
);

CREATE TABLE ref.BaseRateValue (
    BaseRateValueId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_BaseRateValue PRIMARY KEY,
    BaseRateId     INT           NOT NULL CONSTRAINT FK_BRV_Rate REFERENCES ref.BaseRate(BaseRateId),
    Tenor          VARCHAR(10)   NOT NULL,           -- ON, 1M, 3M, 6M, 12M
    EffectiveDate  DATE          NOT NULL,
    RatePct        DECIMAL(9,6)  NOT NULL,
    Source         NVARCHAR(100) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_BaseRateValue_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_BaseRateValue_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT UQ_BRV UNIQUE (BaseRateId, Tenor, EffectiveDate)
);
GO

/* ===========================================================================
   5) cat : الكتالوجات (التعريفات)
   =========================================================================== */
CREATE TABLE cat.FacilityType (
    FacilityTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FacilityType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_FacilityType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    Description NVARCHAR(500) NULL,
    IsActive BIT NOT NULL CONSTRAINT DF_FacilityType_Act DEFAULT 1
);

-- أنواع الحدود: رئيسي أو جزئي (Sub Limit Line)؛ الجزئي يتبع نوعًا رئيسيًا
CREATE TABLE cat.LimitType (
    LimitTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LimitType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_LimitType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    IsSubLimit BIT NOT NULL CONSTRAINT DF_LimitType_Sub DEFAULT 0,
    ParentLimitTypeId INT NULL CONSTRAINT FK_LimitType_Parent REFERENCES cat.LimitType(LimitTypeId),
    IsActive BIT NOT NULL CONSTRAINT DF_LimitType_Act DEFAULT 1,
    CONSTRAINT CK_LimitType_Parent CHECK (IsSubLimit = 1 OR ParentLimitTypeId IS NULL)
);

CREATE TABLE cat.Product (
    ProductId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Product PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_Product_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    ProductGroup VARCHAR(20) NOT NULL
        CONSTRAINT CK_Product_Group CHECK (ProductGroup IN ('TRADE','FINANCING','GUARANTEE','CASH_MGMT','TREASURY','OTHER')),
    Description NVARCHAR(500) NULL,
    IsActive BIT NOT NULL CONSTRAINT DF_Product_Act DEFAULT 1
);

CREATE TABLE cat.FeeType (
    FeeTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FeeType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_FeeType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    FeeCategory VARCHAR(20) NOT NULL
        CONSTRAINT CK_FeeType_Cat CHECK (FeeCategory IN ('ISSUANCE','COMMISSION','UPFRONT','ADMIN','AMENDMENT','PENALTY','OTHER')),
    IsActive BIT NOT NULL CONSTRAINT DF_FeeType_Act DEFAULT 1
);

CREATE TABLE cat.FinancingType (
    FinancingTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FinancingType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_FinancingType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    IsIslamic BIT NOT NULL CONSTRAINT DF_FinType_Isl DEFAULT 0,   -- يحدد مسمى العائد: فائدة / ربح
    IsActive BIT NOT NULL CONSTRAINT DF_FinType_Act DEFAULT 1
);

-- ربط المنتج بأنواع المصاريف وأنواع التمويل المسموحة له
CREATE TABLE cat.ProductFeeType (
    ProductId INT NOT NULL CONSTRAINT FK_PFT_Product REFERENCES cat.Product(ProductId),
    FeeTypeId INT NOT NULL CONSTRAINT FK_PFT_Fee REFERENCES cat.FeeType(FeeTypeId),
    IsMandatory BIT NOT NULL CONSTRAINT DF_PFT_Man DEFAULT 0,
    SortOrder SMALLINT NOT NULL CONSTRAINT DF_PFT_Sort DEFAULT 0,
    CONSTRAINT PK_ProductFeeType PRIMARY KEY (ProductId, FeeTypeId)
);
CREATE TABLE cat.ProductFinancingType (
    ProductId INT NOT NULL CONSTRAINT FK_PFin_Product REFERENCES cat.Product(ProductId),
    FinancingTypeId INT NOT NULL CONSTRAINT FK_PFin_Fin REFERENCES cat.FinancingType(FinancingTypeId),
    CONSTRAINT PK_ProductFinancingType PRIMARY KEY (ProductId, FinancingTypeId)
);
-- المنتجات المسموح بها لكل نوع حد
CREATE TABLE cat.LimitTypeProduct (
    LimitTypeId INT NOT NULL CONSTRAINT FK_LTP_LT REFERENCES cat.LimitType(LimitTypeId),
    ProductId   INT NOT NULL CONSTRAINT FK_LTP_Prod REFERENCES cat.Product(ProductId),
    CONSTRAINT PK_LimitTypeProduct PRIMARY KEY (LimitTypeId, ProductId)
);

CREATE TABLE cat.CollateralType (
    CollateralTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CollateralType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_CollateralType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    Category VARCHAR(25) NOT NULL
        CONSTRAINT CK_CollType_Cat CHECK (Category IN ('REAL_ESTATE','PERSONAL_GUARANTEE','CORPORATE_GUARANTEE','PROMISSORY_NOTE','CASH','RECEIVABLE_ASSIGNMENT','DISCOUNT_AUTHORIZATION','VEHICLE_EQUIPMENT','SECURITIES','OTHER')),
    RequiresValuation BIT NOT NULL CONSTRAINT DF_CollType_Val DEFAULT 0,
    AttributesTemplate NVARCHAR(MAX) NULL CONSTRAINT CK_CollType_Json CHECK (AttributesTemplate IS NULL OR ISJSON(AttributesTemplate) = 1),
    IsActive BIT NOT NULL CONSTRAINT DF_CollType_Act DEFAULT 1
);

CREATE TABLE cat.CovenantType (
    CovenantTypeId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CovenantType PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_CovenantType_Code UNIQUE,
    NameAr NVARCHAR(150) NOT NULL, NameEn NVARCHAR(150) NOT NULL,
    Category VARCHAR(20) NOT NULL
        CONSTRAINT CK_CovType_Cat CHECK (Category IN ('FINANCIAL_RATIO','REPORTING','OPERATIONAL','OTHER')),
    MetricUnit VARCHAR(10) NOT NULL CONSTRAINT DF_CovType_Unit DEFAULT 'NONE'
        CONSTRAINT CK_CovType_Unit CHECK (MetricUnit IN ('RATIO','PERCENT','AMOUNT','DAYS','NONE')),
    DefaultOperator VARCHAR(3) NULL CONSTRAINT CK_CovType_Op CHECK (DefaultOperator IN ('>=','<=','>','<','=')),
    IsActive BIT NOT NULL CONSTRAINT DF_CovType_Act DEFAULT 1
);
GO

-- المنتجات التي يتعامل بها مع كل جهة ممولة + جهة الاتصال الافتراضية (إعداد سريع عند تعريف البنك)
CREATE TABLE fin.InstitutionProduct (
    InstitutionId INT NOT NULL CONSTRAINT FK_InstProd_Inst REFERENCES fin.Institution(InstitutionId),
    ProductId     INT NOT NULL CONSTRAINT FK_InstProd_Prod REFERENCES cat.Product(ProductId),
    DefaultContactId INT NULL,
    Notes         NVARCHAR(500) NULL,
    IsActive      BIT NOT NULL CONSTRAINT DF_InstProd_Act DEFAULT 1,
    CONSTRAINT PK_InstitutionProduct PRIMARY KEY (InstitutionId, ProductId),
    CONSTRAINT FK_InstProd_Contact FOREIGN KEY (InstitutionId, DefaultContactId) REFERENCES fin.Contact(InstitutionId, ContactId)
);
GO

/* ===========================================================================
   6) fac : التسهيلات والحدود
   (الجداول الزمنية Temporal تحفظ سجل كل تعديل تلقائيًا)
   =========================================================================== */
CREATE TABLE fac.Facility (
    FacilityId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Facility PRIMARY KEY,
    InternalNo       VARCHAR(30)   NOT NULL CONSTRAINT UQ_Facility_Internal UNIQUE,   -- رقمنا الداخلي
    BankReferenceNo  VARCHAR(60)   NULL,                                              -- رقم مرجع البنك
    InstitutionId    INT           NOT NULL CONSTRAINT FK_Facility_Inst REFERENCES fin.Institution(InstitutionId), -- الجهة المانحة، أو الوكيل/المرتب الرئيسي عند التمويل المشترك
    IsSyndicated     BIT           NOT NULL CONSTRAINT DF_Facility_Synd DEFAULT 0,  -- 1 = تحالف تمويلي (تفاصيل المشاركين في FacilityLender)
    FacilityTypeId   INT           NOT NULL CONSTRAINT FK_Facility_Type REFERENCES cat.FacilityType(FacilityTypeId),
    BorrowerCompanyId INT          NOT NULL CONSTRAINT FK_Facility_Borrower REFERENCES org.Company(CompanyId), -- الشركة المتعاقدة (قابضة أو تابعة)
    CurrencyCode     CHAR(3)       NOT NULL CONSTRAINT FK_Facility_Cur REFERENCES ref.Currency(CurrencyCode),
    TotalAmount      DECIMAL(19,4) NOT NULL,
    StartDate        DATE          NOT NULL,
    EndDate          DATE          NOT NULL,
    PreviousFacilityId INT         NULL CONSTRAINT FK_Facility_Prev REFERENCES fac.Facility(FacilityId), -- التجديد / التعديل
    Status           VARCHAR(20)   NOT NULL CONSTRAINT DF_Facility_Status DEFAULT 'DRAFT'
        CONSTRAINT CK_Facility_Status CHECK (Status IN ('DRAFT','PENDING_APPROVAL','ACTIVE','SUSPENDED','EXPIRED','CANCELLED','RENEWED')),
    ApprovedBy       NVARCHAR(128) NULL,
    ApprovedAt       DATETIME2(0)  NULL,
    Notes            NVARCHAR(2000) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Facility_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Facility_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    SysStart         DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    SysEnd           DATETIME2 GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStart, SysEnd),
    CONSTRAINT CK_Facility_Dates  CHECK (EndDate > StartDate),
    CONSTRAINT CK_Facility_Amount CHECK (TotalAmount >= 0)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = fac.FacilityHistory));
CREATE UNIQUE INDEX UX_Facility_BankRef ON fac.Facility(InstitutionId, BankReferenceNo) WHERE BankReferenceNo IS NOT NULL;
CREATE INDEX IX_Facility_Borrower ON fac.Facility(BorrowerCompanyId, Status) INCLUDE (EndDate);
CREATE INDEX IX_Facility_EndDate  ON fac.Facility(EndDate) WHERE Status = 'ACTIVE';

-- المشاركون في التمويل المشترك (تحالف بنوك في عقد واحد).
-- التسهيل الثنائي (IsSyndicated=0) لا يحتاج صفوفًا هنا: الجهة الوحيدة هي Facility.InstitutionId بنسبة 100%.
-- عند IsSyndicated=1 يجب أن يكون مجموع النسب 100% ، ووجود الجهة الرئيسية Facility.InstitutionId ضمن المشاركين (يُفحص في العرض).
CREATE TABLE fac.FacilityLender (
    FacilityLenderId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FacilityLender PRIMARY KEY,
    FacilityId       INT           NOT NULL CONSTRAINT FK_FL_Fac REFERENCES fac.Facility(FacilityId),
    InstitutionId    INT           NOT NULL CONSTRAINT FK_FL_Inst REFERENCES fin.Institution(InstitutionId),
    LenderRole       VARCHAR(12)   NOT NULL
        CONSTRAINT CK_FL_Role CHECK (LenderRole IN ('AGENT','ARRANGER','LEAD','PARTICIPANT')),
    ParticipationPct DECIMAL(9,6)  NOT NULL,                 -- نسبة المشاركة: 25.000000 = 25%
    ContactId        INT           NULL,                     -- جهة اتصال هذا المشارك في هذا التسهيل
    Notes            NVARCHAR(500) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_FacilityLender_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_FacilityLender_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT UQ_FL UNIQUE (FacilityId, InstitutionId),
    CONSTRAINT CK_FL_Pct CHECK (ParticipationPct > 0 AND ParticipationPct <= 100),
    CONSTRAINT FK_FL_Contact FOREIGN KEY (InstitutionId, ContactId) REFERENCES fin.Contact(InstitutionId, ContactId)
);
-- وكيل واحد فقط لكل تسهيل
CREATE UNIQUE INDEX UX_FL_OneAgent ON fac.FacilityLender(FacilityId) WHERE LenderRole = 'AGENT';

-- الحسابات المرتبطة بالتسهيل
CREATE TABLE fac.FacilityAccount (
    AccountId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FacilityAccount PRIMARY KEY,
    FacilityId  INT NOT NULL CONSTRAINT FK_FAcc_Fac REFERENCES fac.Facility(FacilityId),
    CompanyId   INT NULL CONSTRAINT FK_FAcc_Co REFERENCES org.Company(CompanyId),
    AccountNo   VARCHAR(40) NOT NULL,
    Iban        VARCHAR(34) NULL,
    AccountType VARCHAR(10) NOT NULL CONSTRAINT CK_FAcc_Type CHECK (AccountType IN ('CURRENT','LOAN','MARGIN','ESCROW','OTHER')),
    CurrencyCode CHAR(3) NOT NULL CONSTRAINT FK_FAcc_Cur REFERENCES ref.Currency(CurrencyCode),
    IsActive    BIT NOT NULL CONSTRAINT DF_FAcc_Act DEFAULT 1,
    CONSTRAINT UQ_FAcc UNIQUE (FacilityId, AccountNo)
);

-- الحد: رئيسي (ParentLimitId = NULL) أو جزئي (يشير إلى حد أب داخل نفس التسهيل)
CREATE TABLE fac.Limit (
    LimitId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Limit PRIMARY KEY,
    FacilityId    INT           NOT NULL CONSTRAINT FK_Limit_Fac REFERENCES fac.Facility(FacilityId),
    ParentLimitId INT           NULL,
    LimitTypeId   INT           NOT NULL CONSTRAINT FK_Limit_Type REFERENCES cat.LimitType(LimitTypeId),
    LimitNo       VARCHAR(20)   NOT NULL,                 -- ترقيم داخل التسهيل: 1 ، 1.1 ، 1.2 ، 2
    CurrencyCode  CHAR(3)       NOT NULL CONSTRAINT FK_Limit_Cur REFERENCES ref.Currency(CurrencyCode),
    Amount        DECIMAL(19,4) NOT NULL,
    StartDate     DATE          NULL,                     -- NULL = يرث من التسهيل
    EndDate       DATE          NULL,
    IsRevolving   BIT           NOT NULL CONSTRAINT DF_Limit_Rev DEFAULT 1,
    IsCommitted   BIT           NOT NULL CONSTRAINT DF_Limit_Com DEFAULT 0,
    MaxTenorDays  INT           NULL,
    PricingMode   VARCHAR(7)    NOT NULL CONSTRAINT DF_Limit_PM DEFAULT 'INHERIT'
        CONSTRAINT CK_Limit_PM CHECK (PricingMode IN ('INHERIT','OWN')),
    Status        VARCHAR(10)   NOT NULL CONSTRAINT DF_Limit_Status DEFAULT 'ACTIVE'
        CONSTRAINT CK_Limit_Status CHECK (Status IN ('ACTIVE','SUSPENDED','CLOSED')),
    Notes         NVARCHAR(1000) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Limit_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Limit_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    SysStart      DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    SysEnd        DATETIME2 GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStart, SysEnd),
    CONSTRAINT UQ_Limit_FacNo  UNIQUE (FacilityId, LimitNo),
    CONSTRAINT UQ_Limit_FacId  UNIQUE (LimitId, FacilityId),
    CONSTRAINT FK_Limit_Parent FOREIGN KEY (ParentLimitId, FacilityId) REFERENCES fac.Limit(LimitId, FacilityId),
    CONSTRAINT CK_Limit_Amount CHECK (Amount >= 0),
    CONSTRAINT CK_Limit_Dates  CHECK (StartDate IS NULL OR EndDate IS NULL OR EndDate > StartDate),
    CONSTRAINT CK_Limit_NotSelf CHECK (ParentLimitId IS NULL OR ParentLimitId <> LimitId)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = fac.LimitHistory));
CREATE INDEX IX_Limit_Parent ON fac.Limit(ParentLimitId);

-- المنتجات المسموح بها ضمن الحد (مع سقف اختياري للمنتج)
CREATE TABLE fac.LimitProduct (
    LimitId      INT NOT NULL CONSTRAINT FK_LP_Limit REFERENCES fac.Limit(LimitId),
    ProductId    INT NOT NULL CONSTRAINT FK_LP_Prod REFERENCES cat.Product(ProductId),
    MaxAmount    DECIMAL(19,4) NULL,
    MaxTenorDays INT NULL,
    CONSTRAINT PK_LimitProduct PRIMARY KEY (LimitId, ProductId)
);

-- توزيع الحد على الشركات (حد جزئي لكل شركة). AllocatedAmount = NULL تعني استخدام مشترك بلا سقف خاص
CREATE TABLE fac.LimitCompanyAllocation (
    AllocationId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LCA PRIMARY KEY,
    LimitId         INT NOT NULL CONSTRAINT FK_LCA_Limit REFERENCES fac.Limit(LimitId),
    CompanyId       INT NOT NULL CONSTRAINT FK_LCA_Co REFERENCES org.Company(CompanyId),
    AllocatedAmount DECIMAL(19,4) NULL,
    EffectiveFrom   DATE NOT NULL,
    EffectiveTo     DATE NULL,
    Notes           NVARCHAR(500) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_LimitCompanyAllocation_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_LimitCompanyAllocation_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT UQ_LCA UNIQUE (LimitId, CompanyId, EffectiveFrom),
    CONSTRAINT CK_LCA_Amount CHECK (AllocatedAmount IS NULL OR AllocatedAmount >= 0),
    CONSTRAINT CK_LCA_Dates  CHECK (EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom)
);

-- المستخدم من الحد (إدخال يدوي أو استيراد دوري في المرحلة الأولى؛ ليس نظامًا محاسبيًا)
CREATE TABLE fac.Utilization (
    UtilizationId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Utilization PRIMARY KEY,
    LimitId        INT NOT NULL CONSTRAINT FK_Util_Limit REFERENCES fac.Limit(LimitId),
    CompanyId      INT NOT NULL CONSTRAINT FK_Util_Co REFERENCES org.Company(CompanyId),
    ProductId      INT NULL CONSTRAINT FK_Util_Prod REFERENCES cat.Product(ProductId),
    AsOfDate       DATE NOT NULL,
    UtilizedAmount DECIMAL(19,4) NOT NULL,
    Source         VARCHAR(10) NOT NULL CONSTRAINT DF_Util_Src DEFAULT 'MANUAL'
        CONSTRAINT CK_Util_Src CHECK (Source IN ('MANUAL','IMPORT')),
    Notes          NVARCHAR(500) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Utilization_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Utilization_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT CK_Util_Amount CHECK (UtilizedAmount >= 0)
);
CREATE INDEX IX_Util_Limit ON fac.Utilization(LimitId, CompanyId, AsOfDate DESC);

-- الشروط البنكية
CREATE TABLE fac.Condition (
    ConditionId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Condition PRIMARY KEY,
    FacilityId    INT NOT NULL,
    LimitId       INT NULL,
    ConditionTypeId INT NOT NULL CONSTRAINT FK_Cond_Type REFERENCES ref.Lookup(LookupId),
    Title         NVARCHAR(250) NOT NULL,
    Description   NVARCHAR(2000) NULL,
    Nature        VARCHAR(10) NOT NULL CONSTRAINT CK_Cond_Nature CHECK (Nature IN ('PRECEDENT','ONGOING','SUBSEQUENT')),
    DueDate       DATE NULL,
    Status        VARCHAR(10) NOT NULL CONSTRAINT DF_Cond_Status DEFAULT 'OPEN'
        CONSTRAINT CK_Cond_Status CHECK (Status IN ('OPEN','SATISFIED','WAIVED','BREACHED')),
    SatisfiedDate DATE NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Condition_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Condition_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT FK_Cond_Fac   FOREIGN KEY (FacilityId) REFERENCES fac.Facility(FacilityId),
    CONSTRAINT FK_Cond_Limit FOREIGN KEY (LimitId, FacilityId) REFERENCES fac.Limit(LimitId, FacilityId)
);
GO

/* ===========================================================================
   7) pr : التسعير
   قاعدة التسعير تُربط بالتسهيل دائمًا، وبحد/منتج/شركة اختياريًا (الأكثر تحديدًا يفوز)
   =========================================================================== */
CREATE TABLE pr.PricingRule (
    PricingRuleId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PricingRule PRIMARY KEY,
    FacilityId     INT NOT NULL,
    LimitId        INT NULL,                 -- NULL = على مستوى التسهيل كله
    ProductId      INT NULL CONSTRAINT FK_PR_Prod REFERENCES cat.Product(ProductId),
    CompanyId      INT NULL CONSTRAINT FK_PR_Co REFERENCES org.Company(CompanyId),
    ComponentKind  VARCHAR(9) NOT NULL CONSTRAINT CK_PR_Kind CHECK (ComponentKind IN ('FEE','FINANCING')),
    FeeTypeId      INT NULL CONSTRAINT FK_PR_Fee REFERENCES cat.FeeType(FeeTypeId),
    FinancingTypeId INT NULL CONSTRAINT FK_PR_Fin REFERENCES cat.FinancingType(FinancingTypeId),
    CalcMethod     VARCHAR(20) NOT NULL
        CONSTRAINT CK_PR_Calc CHECK (CalcMethod IN ('PERCENT_OF_AMOUNT','FIXED_AMOUNT','BASE_PLUS_MARGIN','TIERED')),
    BaseRateId     INT NULL CONSTRAINT FK_PR_Base REFERENCES ref.BaseRate(BaseRateId),  -- SIBOR / TARIFF ...
    Tenor          VARCHAR(10) NULL,
    MarginPct      DECIMAL(9,6) NULL,        -- الهامش فوق سعر الأساس  (مثال 1.000000 = 1%)
    RatePct        DECIMAL(9,6) NULL,        -- نسبة ثابتة من المبلغ
    FixedAmount    DECIMAL(19,4) NULL,
    MinAmount      DECIMAL(19,4) NULL,
    MaxAmount      DECIMAL(19,4) NULL,
    FloorRatePct   DECIMAL(9,6) NULL,
    CapRatePct     DECIMAL(9,6) NULL,
    CurrencyCode   CHAR(3) NULL CONSTRAINT FK_PR_Cur REFERENCES ref.Currency(CurrencyCode),
    Frequency      VARCHAR(15) NOT NULL CONSTRAINT DF_PR_Freq DEFAULT 'ONE_TIME'
        CONSTRAINT CK_PR_Freq CHECK (Frequency IN ('ONE_TIME','PER_TRANSACTION','MONTHLY','QUARTERLY','SEMI_ANNUAL','ANNUAL','PER_ANNUM')),
    DayCount       VARCHAR(7) NULL CONSTRAINT CK_PR_DC CHECK (DayCount IN ('ACT/360','ACT/365','30/360')),
    EffectiveFrom  DATE NOT NULL,
    EffectiveTo    DATE NULL,
    Notes          NVARCHAR(500) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_PricingRule_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_PricingRule_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    SysStart       DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    SysEnd         DATETIME2 GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStart, SysEnd),
    CONSTRAINT FK_PR_Fac   FOREIGN KEY (FacilityId) REFERENCES fac.Facility(FacilityId),
    CONSTRAINT FK_PR_Limit FOREIGN KEY (LimitId, FacilityId) REFERENCES fac.Limit(LimitId, FacilityId),
    CONSTRAINT CK_PR_Component CHECK (
        (ComponentKind = 'FEE'       AND FeeTypeId IS NOT NULL AND FinancingTypeId IS NULL) OR
        (ComponentKind = 'FINANCING' AND FinancingTypeId IS NOT NULL AND FeeTypeId IS NULL)),
    CONSTRAINT CK_PR_Method CHECK (
        (CalcMethod = 'BASE_PLUS_MARGIN'   AND BaseRateId IS NOT NULL AND MarginPct IS NOT NULL) OR
        (CalcMethod = 'PERCENT_OF_AMOUNT'  AND RatePct IS NOT NULL) OR
        (CalcMethod = 'FIXED_AMOUNT'       AND FixedAmount IS NOT NULL) OR
        (CalcMethod = 'TIERED')),
    CONSTRAINT CK_PR_Dates CHECK (EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = pr.PricingRuleHistory));
CREATE INDEX IX_PR_Lookup ON pr.PricingRule(FacilityId, ComponentKind, LimitId, ProductId, CompanyId);

-- شرائح التسعير (للطريقة TIERED): RateOrMarginPct تُفسَّر كهامش أو كنسبة بحسب BaseRateId في القاعدة
CREATE TABLE pr.PricingTier (
    TierId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PricingTier PRIMARY KEY,
    PricingRuleId   INT NOT NULL CONSTRAINT FK_Tier_Rule REFERENCES pr.PricingRule(PricingRuleId),
    FromAmount      DECIMAL(19,4) NOT NULL,
    ToAmount        DECIMAL(19,4) NULL,
    RateOrMarginPct DECIMAL(9,6) NOT NULL,
    CONSTRAINT UQ_Tier UNIQUE (PricingRuleId, FromAmount),
    CONSTRAINT CK_Tier_Range CHECK (ToAmount IS NULL OR ToAmount > FromAmount)
);
GO

/* ===========================================================================
   8) cov : التعهدات المالية
   =========================================================================== */
CREATE TABLE cov.Covenant (
    CovenantId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Covenant PRIMARY KEY,
    FacilityId      INT NOT NULL,
    LimitId         INT NULL,
    CovenantTypeId  INT NOT NULL CONSTRAINT FK_Cov_Type REFERENCES cat.CovenantType(CovenantTypeId),
    TestedCompanyId INT NULL CONSTRAINT FK_Cov_Co REFERENCES org.Company(CompanyId), -- NULL = المقترض / القوائم الموحدة
    Title           NVARCHAR(250) NOT NULL,
    MetricCode      VARCHAR(40) NULL,                         -- CURRENT_RATIO, DEBT_TO_EQUITY ...
    Operator        VARCHAR(3) NULL CONSTRAINT CK_Cov_Op CHECK (Operator IN ('>=','<=','>','<','=')),
    ThresholdValue  DECIMAL(19,6) NULL,
    TestFrequency   VARCHAR(12) NOT NULL
        CONSTRAINT CK_Cov_Freq CHECK (TestFrequency IN ('MONTHLY','QUARTERLY','SEMI_ANNUAL','ANNUAL','ON_DEMAND','ONE_TIME')),
    FirstTestDate   DATE NULL,
    GracePeriodDays INT NOT NULL CONSTRAINT DF_Cov_Grace DEFAULT 0,
    ConsequenceText NVARCHAR(1000) NULL,
    Status          VARCHAR(10) NOT NULL CONSTRAINT DF_Cov_Status DEFAULT 'ACTIVE'
        CONSTRAINT CK_Cov_Status CHECK (Status IN ('ACTIVE','WAIVED','TERMINATED')),
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Covenant_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Covenant_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT FK_Cov_Fac   FOREIGN KEY (FacilityId) REFERENCES fac.Facility(FacilityId),
    CONSTRAINT FK_Cov_Limit FOREIGN KEY (LimitId, FacilityId) REFERENCES fac.Limit(LimitId, FacilityId),
    CONSTRAINT CK_Cov_Metric CHECK ((Operator IS NULL AND ThresholdValue IS NULL) OR (Operator IS NOT NULL AND ThresholdValue IS NOT NULL))
);

-- نتائج قياس التعهد في كل فترة
CREATE TABLE cov.CovenantTest (
    TestId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CovenantTest PRIMARY KEY,
    CovenantId    INT NOT NULL CONSTRAINT FK_CTest_Cov REFERENCES cov.Covenant(CovenantId),
    PeriodEndDate DATE NOT NULL,
    DueDate       DATE NOT NULL,
    SubmittedDate DATE NULL,
    ActualValue   DECIMAL(19,6) NULL,
    Result        VARCHAR(10) NOT NULL CONSTRAINT DF_CTest_Res DEFAULT 'PENDING'
        CONSTRAINT CK_CTest_Res CHECK (Result IN ('PENDING','PASSED','BREACHED','WAIVED')),
    WaiverRef     NVARCHAR(100) NULL,
    Notes         NVARCHAR(1000) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_CovenantTest_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_CovenantTest_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT UQ_CTest UNIQUE (CovenantId, PeriodEndDate)
);
GO

/* ===========================================================================
   9) col : الضمانات
   =========================================================================== */
CREATE TABLE col.Collateral (
    CollateralId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Collateral PRIMARY KEY,
    CollateralTypeId INT NOT NULL CONSTRAINT FK_Coll_Type REFERENCES cat.CollateralType(CollateralTypeId),
    ReferenceNo      VARCHAR(60) NULL,                 -- رقم الصك / السند / الكفالة
    Description      NVARCHAR(500) NOT NULL,
    OwnerCompanyId   INT NULL CONSTRAINT FK_Coll_OwnerCo REFERENCES org.Company(CompanyId),
    OwnerName        NVARCHAR(200) NULL,               -- مالك/كفيل من خارج المجموعة (فرد أو شركة)
    OwnerIdNo        VARCHAR(30) NULL,
    ValueAmount      DECIMAL(19,4) NULL,
    ValueCurrency    CHAR(3) NULL CONSTRAINT FK_Coll_Cur REFERENCES ref.Currency(CurrencyCode),
    ValuationDate    DATE NULL,
    ValuationBasis   NVARCHAR(200) NULL,
    ExpiryDate       DATE NULL,
    Attributes       NVARCHAR(MAX) NULL CONSTRAINT CK_Coll_Json CHECK (Attributes IS NULL OR ISJSON(Attributes) = 1), -- حقول خاصة بالنوع (رقم الصك، المساحة ...)
    Status           VARCHAR(10) NOT NULL CONSTRAINT DF_Coll_Status DEFAULT 'ACTIVE'
        CONSTRAINT CK_Coll_Status CHECK (Status IN ('ACTIVE','RELEASED','EXPIRED')),
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Collateral_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Collateral_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT CK_Coll_Owner CHECK (OwnerCompanyId IS NOT NULL OR OwnerName IS NOT NULL)
);

-- ربط الضمان بالتسهيل أو بحد معين (الضمان الواحد قد يغطي أكثر من تسهيل)
CREATE TABLE col.FacilityCollateral (
    FacilityCollateralId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_FacilityCollateral PRIMARY KEY,
    FacilityId     INT NOT NULL,
    LimitId        INT NULL,
    CollateralId   INT NOT NULL CONSTRAINT FK_FC_Coll REFERENCES col.Collateral(CollateralId),
    CoverageAmount DECIMAL(19,4) NULL,
    LienRank       TINYINT NULL,
    PledgedDate    DATE NULL,
    ReleaseDate    DATE NULL,
    LimitKey       AS ISNULL(LimitId, 0) PERSISTED,   -- لدعم فهرس التفرد عند غياب الحد
    Notes          NVARCHAR(500) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_FacilityCollateral_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_FacilityCollateral_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL,
    CONSTRAINT FK_FC_Fac   FOREIGN KEY (FacilityId) REFERENCES fac.Facility(FacilityId),
    CONSTRAINT FK_FC_Limit FOREIGN KEY (LimitId, FacilityId) REFERENCES fac.Limit(LimitId, FacilityId),
    CONSTRAINT CK_FC_Dates CHECK (ReleaseDate IS NULL OR PledgedDate IS NULL OR ReleaseDate >= PledgedDate)
);
CREATE UNIQUE INDEX UX_FC ON col.FacilityCollateral(FacilityId, LimitKey, CollateralId) WHERE ReleaseDate IS NULL;
GO

/* ===========================================================================
   10) doc / sec / aud : المرفقات، الصلاحيات، سجل التدقيق
   =========================================================================== */
CREATE TABLE doc.Attachment (
    AttachmentId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Attachment PRIMARY KEY,
    EntityName   VARCHAR(40)   NOT NULL,         -- Facility, Collateral, Covenant, Institution ...
    EntityId     INT           NOT NULL,
    FileName     NVARCHAR(260) NOT NULL,
    ContentType  VARCHAR(100)  NULL,
    StoragePath  NVARCHAR(500) NOT NULL,         -- مسار على خادم الملفات (UNC) ؛ الملفات خارج القاعدة
    Sha256       BINARY(32)    NULL,
    SizeBytes    BIGINT        NULL,
    Description  NVARCHAR(300) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_Attachment_CAt DEFAULT SYSUTCDATETIME(),
    CreatedBy NVARCHAR(128) NOT NULL CONSTRAINT DF_Attachment_CBy DEFAULT SUSER_SNAME(),
    UpdatedAt DATETIME2(0) NULL,
    UpdatedBy NVARCHAR(128) NULL
);
CREATE INDEX IX_Attachment_Entity ON doc.Attachment(EntityName, EntityId);

CREATE TABLE sec.AppUser (
    UserId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY,
    WindowsLogin NVARCHAR(256) NOT NULL CONSTRAINT UQ_AppUser_Login UNIQUE,   -- DOMAIN\user
    DisplayName  NVARCHAR(200) NOT NULL,
    Email        VARCHAR(200)  NULL,
    IsActive     BIT NOT NULL CONSTRAINT DF_AppUser_Act DEFAULT 1
);
CREATE TABLE sec.Role (
    RoleId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Role PRIMARY KEY,
    Code VARCHAR(30) NOT NULL CONSTRAINT UQ_Role_Code UNIQUE,
    NameAr NVARCHAR(100) NOT NULL, NameEn NVARCHAR(100) NOT NULL
);
CREATE TABLE sec.UserRole (
    UserId INT NOT NULL CONSTRAINT FK_UR_User REFERENCES sec.AppUser(UserId),
    RoleId INT NOT NULL CONSTRAINT FK_UR_Role REFERENCES sec.Role(RoleId),
    CONSTRAINT PK_UserRole PRIMARY KEY (UserId, RoleId)
);
-- نطاق البيانات: الشركات التي يحق للمستخدم رؤيتها (فارغ = لا شيء)
CREATE TABLE sec.UserCompanyScope (
    UserId    INT NOT NULL CONSTRAINT FK_UCS_User REFERENCES sec.AppUser(UserId),
    CompanyId INT NOT NULL CONSTRAINT FK_UCS_Co REFERENCES org.Company(CompanyId),
    CONSTRAINT PK_UserCompanyScope PRIMARY KEY (UserId, CompanyId)
);

-- يكتبه طبقة التطبيق (من، متى، ماذا تغيّر) ؛ الجداول الزمنية تحفظ النسخ الكاملة
CREATE TABLE aud.AuditLog (
    AuditId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLog PRIMARY KEY,
    OccurredAt  DATETIME2(0)  NOT NULL CONSTRAINT DF_Audit_At DEFAULT SYSUTCDATETIME(),
    UserLogin   NVARCHAR(256) NOT NULL,
    Action      VARCHAR(10)   NOT NULL CONSTRAINT CK_Audit_Action CHECK (Action IN ('INSERT','UPDATE','DELETE','APPROVE','LOGIN','EXPORT')),
    TableName   VARCHAR(80)   NOT NULL,
    KeyValue    VARCHAR(60)   NOT NULL,
    OldValues   NVARCHAR(MAX) NULL CONSTRAINT CK_Audit_Old CHECK (OldValues IS NULL OR ISJSON(OldValues)=1),
    NewValues   NVARCHAR(MAX) NULL CONSTRAINT CK_Audit_New CHECK (NewValues IS NULL OR ISJSON(NewValues)=1),
    ClientIp    VARCHAR(45)   NULL
);
CREATE INDEX IX_Audit_Table ON aud.AuditLog(TableName, KeyValue, OccurredAt DESC);
GO
