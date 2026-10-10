# قاموس البيانات

> مُولَّد آليًا من نموذج البيانات بـ `tools/dbgen` — لا يُعدَّل يدويًا. الأعمدة المشتركة التي تضيفها اصطلاحات التوليد (TenantId، المعرّف، التدقيق) تظهر في كل جدول.

**عدد الجداول: 194**

| الوحدة | عدد الجداول |
|---|---|
| PLT-PLAT | 7 |
| PLT-SEC | 14 |
| PLT-AUD | 2 |
| PLT-DOC | 3 |
| PLT-CFG | 12 |
| ORG | 14 |
| PTY | 11 |
| REF | 2 |
| CAT | 26 |
| INS | 6 |
| ACC | 6 |
| FAC | 13 |
| PRC | 5 |
| CMP | 2 |
| COL | 7 |
| OBL | 8 |
| FIN | 7 |
| REQ | 8 |
| WFL | 11 |
| NTF | 7 |
| LC | 23 |

## PLT-PLAT

### `plat.Plan` — باقة: حزمة وحدات وحدود ناعمة (FR-PLT-003/004، Q-PLT-11)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **PlanId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(30) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| MaxUsers | INT | نعم |  |  | حد ناعم: ينبّه ولا يمنع (FR-PLT-004) |
| MaxCompanies | INT | نعم |  |  |  |
| MaxStorageGb | INT | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PlanId) · UQ(Code)

**قيود:** `MaxUsers IS NULL OR MaxUsers > 0` · `MaxCompanies IS NULL OR MaxCompanies > 0` · `MaxStorageGb IS NULL OR MaxStorageGb > 0`

### `plat.PlanModule` — وحدات الباقة (يحل محل Plan.IncludedModules json)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| PlanId | INT | لا |  | plat.Plan |  |
| ModuleCode | VARCHAR(12) | لا |  |  | enum: CORE, INSTITUTIONS, FACILITIES, COVENANTS, WORKFLOW, LC_PURCHASE, LC_SALES, REQUESTS, REPORTS |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PlanId, ModuleCode)

### `plat.Tenant` — جذر العزل: المشترك (FR-PLT-001/002/046، BR-PLT-001/002)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **TenantId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(30) | لا |  |  | العنوان الفرعي {Code}.bankfas.com؛ لاتيني وأرقام وشرطة؛ مجمَّد بعد التفعيل (FR-PLT-046) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| PlanId | INT | لا |  | plat.Plan |  |
| Status | VARCHAR(18) | لا | TRIAL |  | دورة الحياة (BR-PLT-002، §8) enum: TRIAL, ACTIVE, SUSPENDED, CLOSED, ARCHIVED_READ_ONLY |
| TrialEndsOn | DATE | نعم |  |  | نهاية التجربة: 30 يومًا افتراضيًا ويمدّدها المشغّل |
| HomeCountryId | INT | لا |  | ref.Country | الدولة الأم (BR-PTY-005) |
| DefaultLanguage | VARCHAR(10) | لا | en |  | الإنجليزية الأساس والعربية لاحقًا (FR-PLT-032) enum: ar, en |
| TimeZone | VARCHAR(64) | لا |  |  | تُعرض به الأوقات وتُحسب نافذة العمل (FR-PLT-034) |
| CalendarDisplay | VARCHAR(10) | لا | GREGORIAN |  | FR-PLT-033 enum: GREGORIAN, HIJRI, BOTH |
| DataRegion | VARCHAR(30) | نعم |  |  | إقامة البيانات (Q-PLT-03) |
| SuspendedReason | NVARCHAR(MAX) | نعم |  |  | سبب التعليق (إلزامي عند SUSPENDED) |
| ActivatedAt | DATETIME2(3) | نعم |  |  | أول تفعيل؛ بعده لا يتغير Code (يُفرض في التطبيق/محفّز) |
| ClosedAt | DATETIME2(3) | نعم |  |  | بدء مهلة التصدير 30 يومًا (BR-PLT-002) |
| ArchivedAt | DATETIME2(3) | نعم |  |  | = ClosedAt + 30 يومًا؛ القراءة فقط بلا كتابة ولا حذف |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId) · UQ(PublicId) · UQ(Code)

**قيود:** `Code NOT LIKE '%[^A-Za-z0-9-]%' AND Code NOT LIKE '-%' AND Code NOT LIKE '%-'` · `Status <> 'TRIAL' OR TrialEndsOn IS NOT NULL` · `Status <> 'SUSPENDED' OR SuspendedReason IS NOT NULL` · `Status NOT IN ('CLOSED','ARCHIVED_READ_ONLY') OR ClosedAt IS NOT NULL` · `Status <> 'ARCHIVED_READ_ONLY' OR ArchivedAt IS NOT NULL` · `ArchivedAt IS NULL OR (ClosedAt IS NOT NULL AND ArchivedAt >= ClosedAt)`

### `plat.ReservedSubdomain` — عناوين فرعية محجوزة للنظام: www · admin · api · app… (FR-PLT-046)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ReservedSubdomainId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Subdomain | VARCHAR(63) | لا |  |  | تسمية DNS واحدة؛ رفض Tenant.Code المطابق في التطبيق |
| Reason | NVARCHAR(200) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReservedSubdomainId) · UQ(Subdomain)

**قيود:** `Subdomain NOT LIKE '%[^a-z0-9-]%' AND Subdomain NOT LIKE '-%' AND Subdomain NOT LIKE '%-'`

### `plat.PlatformOperator` — حساب مشغّل المنصة: مخزن هوية منفصل عن AppUser (FR-PLT-006)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **PlatformOperatorId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Email | NVARCHAR(254) | لا |  |  |  |
| DisplayName | NVARCHAR(200) | نعم |  |  |  |
| Role | VARCHAR(16) | لا |  |  | enum: OPERATOR_ADMIN, OPERATOR_SUPPORT |
| Status | VARCHAR(10) | لا | INVITED |  | enum: INVITED, ACTIVE, LOCKED, DISABLED, ARCHIVED |
| PasswordHash | VARCHAR(255) | نعم |  |  | تجزئة بطيئة مملّحة (FR-PLT-010) 🔒 restricted |
| PasswordChangedAt | DATETIME2(3) | نعم |  |  |  |
| MfaEnabled | BIT | لا | 0 |  | MFA إلزامي للمشغّل |
| MfaSecretEnc | VARBINARY(256) | نعم |  |  | سر TOTP مشفَّر 🔒 restricted |
| MfaEnrolledAt | DATETIME2(3) | نعم |  |  |  |
| MfaLastUsedStep | BIGINT | نعم |  |  | آخر خطوة TOTP مقبولة (منع إعادة الاستعمال) |
| FailedAttempts | INT | لا | 0 |  |  |
| LockedUntil | DATETIME2(3) | نعم |  |  |  |
| LastLoginAt | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PlatformOperatorId) · UQ(PublicId) · UQ(Email)

**قيود:** `Status NOT IN ('ACTIVE','LOCKED') OR PasswordHash IS NOT NULL` · `Status <> 'ACTIVE' OR MfaEnabled = 1` · `MfaEnabled = 0 OR MfaSecretEnc IS NOT NULL` · `FailedAttempts >= 0`

### `plat.TenantModule` — الوحدات المفعّلة للمشترك (FR-PLT-003، BR-PLT-003)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TenantModuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ModuleCode | VARCHAR(12) | لا |  |  | enum: CORE, INSTITUTIONS, FACILITIES, COVENANTS, WORKFLOW, LC_PURCHASE, LC_SALES, REQUESTS, REPORTS |
| IsEnabled | BIT | لا | 1 |  | التعطيل يخفي الوحدة دون حذف بياناتها؛ الاعتماديات (00 §9-ب) في التطبيق |
| EnabledAt | DATETIME2(3) | نعم |  |  |  |
| EnabledBy | INT | نعم |  | plat.PlatformOperator | فارغ = تفعيل آلي من الباقة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantModuleId) · UQ(TenantId, ModuleCode)

**قيود:** `ModuleCode <> 'CORE' OR IsEnabled = 1`

### `plat.SupportAccessGrant` — وصول الدعم المؤقت يفعّله مدير حساب المشترك (FR-PLT-007، BR-PLT-017)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SupportAccessGrantId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OperatorId | INT | لا |  | plat.PlatformOperator |  |
| GrantedBy | BIGINT | لا |  | sec.AppUser |  |
| StartsAt | DATETIME2(3) | لا |  |  |  |
| EndsAt | DATETIME2(3) | لا |  |  | من ساعة إلى 72 ساعة (الافتراضي 4) — يُتحقق في التطبيق؛ ينتهي آليًا |
| Reason | NVARCHAR(500) | لا |  |  |  |
| RevokedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedBy | BIGINT | نعم |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SupportAccessGrantId)

**قيود:** `EndsAt > StartsAt`

## PLT-SEC

### `sec.AppUser` — مستخدم بوابة المشترك (FR-PLT-010..016، BR-PLT-004..006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AppUserId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Email | NVARCHAR(254) | لا |  |  |  |
| DisplayNameAr | NVARCHAR(200) | نعم |  |  |  |
| DisplayNameEn | NVARCHAR(200) | نعم |  |  |  |
| DepartmentId | BIGINT | نعم |  | org.Department |  |
| LineManagerUserId | BIGINT | نعم |  | sec.AppUser | المدير المباشر: يحل «المدير» في الموافقات (13) |
| CompanyScopeMode | VARCHAR(10) | لا | SELECTED |  | SELECTED = الرفض هو الأصل (FR-PLT-021) enum: ALL, SELECTED |
| PreferredLanguage | VARCHAR(10) | نعم |  |  | فارغ = DefaultLanguage للمشترك؛ تقرؤه 13 (FR-NTF-024) enum: ar, en |
| DigitsPreference | VARCHAR(12) | نعم |  |  | فارغ = تفضيل المشترك (Q-PLT-07) enum: WESTERN, ARABIC_INDIC |
| Status | VARCHAR(10) | لا | INVITED |  | §8 enum: INVITED, ACTIVE, LOCKED, DISABLED, ARCHIVED |
| PasswordHash | VARCHAR(255) | نعم |  |  | تجزئة بطيئة مملّحة؛ فارغ حتى إكمال الدعوة 🔒 restricted |
| PasswordChangedAt | DATETIME2(3) | نعم |  |  |  |
| MfaEnabled | BIT | لا | 0 |  | إعادة تعيين MFA تصفّره وتجبر على إعادة التسجيل (BR-PLT-006) |
| MfaSecretEnc | VARBINARY(256) | نعم |  |  | سر TOTP مشفَّر بمفتاح المشترك 🔒 restricted |
| MfaEnrolledAt | DATETIME2(3) | نعم |  |  |  |
| MfaLastUsedStep | BIGINT | نعم |  |  | آخر خطوة TOTP مقبولة (منع إعادة الاستعمال) |
| FailedAttempts | INT | لا | 0 |  | 5 خلال 15 دقيقة تقفل (BR-PLT-005) |
| FirstFailedAt | DATETIME2(3) | نعم |  |  | بداية نافذة المحاولات الفاشلة |
| LockedUntil | DATETIME2(3) | نعم |  |  |  |
| LockoutCount | INT | لا | 0 |  | عدد القفلات في نافذة 24 ساعة؛ الثالثة تحتاج فك المدير |
| LastLockoutAt | DATETIME2(3) | نعم |  |  |  |
| RequiresAdminUnlock | BIT | لا | 0 |  |  |
| LastLoginAt | DATETIME2(3) | نعم |  |  |  |
| ArchivedAt | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AppUserId) · UQ(PublicId) · UQ(TenantId, Email)

**قيود:** `LineManagerUserId IS NULL OR LineManagerUserId <> AppUserId` · `DisplayNameAr IS NOT NULL OR DisplayNameEn IS NOT NULL` · `Status NOT IN ('ACTIVE','LOCKED') OR PasswordHash IS NOT NULL` · `MfaEnabled = 0 OR MfaSecretEnc IS NOT NULL` · `Status <> 'ARCHIVED' OR ArchivedAt IS NOT NULL` · `Status <> 'LOCKED' OR LockedUntil IS NOT NULL OR RequiresAdminUnlock = 1` · `FailedAttempts >= 0 AND LockoutCount >= 0`

### `sec.Role` — دور يخصصه المشترك أو مبذور (FR-PLT-018)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RoleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(50) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Description | NVARCHAR(MAX) | نعم |  |  |  |
| IsSystem | BIT | لا | 0 |  | دور نظام مبذور (TM · FO · TA…) |
| IsActive | BIT | لا | 1 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  | للمبذور: يُحدَّث دون إلغاء تعديلات المشترك (FR-PLT-008) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RoleId) · UQ(PublicId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `IsSystem = 0 OR SeedKey IS NOT NULL`

### `sec.Permission` — كتالوج الصلاحيات تملكه المنصة؛ لا يضيف المشترك صلاحية (FR-PLT-017)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **PermissionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(100) | لا |  |  | مثل party.identity.reveal — بنصها الحرفي |
| ModuleCode | VARCHAR(12) | لا |  |  | enum: CORE, INSTITUTIONS, FACILITIES, COVENANTS, WORKFLOW, LC_PURCHASE, LC_SALES, REQUESTS, REPORTS |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsSensitive | BIT | لا | 0 |  |  |
| LockedToRoleCodes | NVARCHAR(MAX) | نعم |  |  | مثل ["TM","FO"]: الأدوار الوحيدة التي يجوز إسنادها إليها (BR-PLT-019) |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PermissionId) · UQ(Code)

**قيود:** `LockedToRoleCodes IS NULL OR IsSensitive = 1`

### `sec.RolePermission` — ربط دور-صلاحية؛ PERMISSION_LOCKED يُفرض في الخدمة (BR-PLT-019)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| RoleId | BIGINT | لا |  | sec.Role |  |
| PermissionId | INT | لا |  | sec.Permission |  |
| AssignedBy | BIGINT | نعم |  | sec.AppUser |  |
| AssignedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, RoleId, PermissionId)

### `sec.UserRole` — ربط مستخدم-دور؛ اتحاد الصلاحيات (BR-PLT-007، FR-PLT-018)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| RoleId | BIGINT | لا |  | sec.Role |  |
| AssignedBy | BIGINT | نعم |  | sec.AppUser |  |
| AssignedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, UserId, RoleId)

### `sec.UserCompanyScope` — شركات يراها المستخدم؛ تُهمل إن كان CompanyScopeMode=ALL (FR-PLT-020)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| CompanyId | BIGINT | لا |  | org.Company |  |
| IncludeDescendants | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, UserId, CompanyId)

### `sec.LoginAttempt` — محاولات الدخول لخنق المعدل ونوافذ القفل؛ الأثر الدائم في aud.AuditLog (BR-PLT-005)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LoginAttemptId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | نعم |  | sec.AppUser | فارغ لبريد غير موجود (رسالة موحّدة لا تكشف الوجود) |
| LoginName | NVARCHAR(200) | نعم |  |  | البريد المُدخل كما كُتب |
| Outcome | VARCHAR(15) | لا |  |  | enum: LOGIN_SUCCESS, FAILED_PASSWORD, DENIED_LOCKED, FAILED_MFA, LOCKOUT |
| IpAddress | VARCHAR(45) | نعم |  |  | تقييد المعدل لكل عنوان IP |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LoginAttemptId)

**قيود:** `UserId IS NOT NULL OR LoginName IS NOT NULL`

### `sec.UserSession` — جلسات المستخدم: خمول 30 دقيقة ومطلقة 12 ساعة (FR-PLT-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UserSessionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| TokenHash | VARBINARY(32) | لا |  |  | SHA-256 لمعرّف الجلسة؛ لا يُخزَّن الأصل 🔒 restricted |
| LastSeenAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| IdleExpiresAt | DATETIME2(3) | لا |  |  |  |
| AbsoluteExpiresAt | DATETIME2(3) | لا |  |  |  |
| MfaVerifiedAt | DATETIME2(3) | نعم |  |  |  |
| IpAddress | VARCHAR(45) | نعم |  |  |  |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| EndedAt | DATETIME2(3) | نعم |  |  |  |
| EndReason | VARCHAR(19) | نعم |  |  | enum: LOGOUT, IDLE_TIMEOUT, ABSOLUTE_TIMEOUT, TERMINATED_BY_ADMIN, PASSWORD_CHANGED, MFA_RESET, USER_DISABLED, TENANT_SUSPENDED |
| EndedBy | BIGINT | نعم |  | sec.AppUser | المدير الذي أنهى الجلسة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UserSessionId) · UQ(TenantId, TokenHash)

**قيود:** `(EndedAt IS NULL AND EndReason IS NULL) OR (EndedAt IS NOT NULL AND EndReason IS NOT NULL)`

### `sec.MfaRecoveryCode` — 10 رموز استرداد لمرة واحدة مُجزَّأة (FR-PLT-011، BR-PLT-006؛ بديل AppUser.RecoveryCodesHash json)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **MfaRecoveryCodeId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| CodeHash | VARBINARY(32) | لا |  |  | 🔒 restricted |
| UsedAt | DATETIME2(3) | نعم |  |  | الاستهلاك يلغيه ويُنبَّه المستخدم بالعدد الباقي |
| UsedIp | VARCHAR(45) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(MfaRecoveryCodeId) · UQ(TenantId, UserId, CodeHash)

### `sec.UserToken` — رابط دعوة (48 ساعة) أو إعادة تعيين كلمة المرور (30 دقيقة) لمرة واحدة (FR-PLT-013)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UserTokenId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| Purpose | VARCHAR(14) | لا |  |  | enum: INVITATION, PASSWORD_RESET |
| TokenHash | VARBINARY(32) | لا |  |  | الرابط مُجزَّأ في القاعدة ولا يحمل بيانات مقيّدة 🔒 restricted |
| ExpiresAt | DATETIME2(3) | لا |  |  |  |
| UsedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedAt | DATETIME2(3) | نعم |  |  |  |
| SentTo | NVARCHAR(254) | نعم |  |  | البريد وقت الإصدار |
| SendStatus | VARCHAR(10) | لا | PENDING |  | فشل الإرسال يُسجَّل في التدقيق enum: PENDING, SENT, FAILED |
| SendError | NVARCHAR(500) | نعم |  |  |  |
| RequestedByUserId | BIGINT | نعم |  | sec.AppUser | الداعي؛ فارغ لإعادة تعيين ذاتية |
| RequestIp | VARCHAR(45) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UserTokenId) · UQ(TenantId, TokenHash)

### `sec.UserPasswordHistory` — آخر 5 كلمات مرور لمنع إعادة استعمالها (BR-PLT-004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UserPasswordHistoryId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| PasswordHash | VARCHAR(255) | لا |  |  | 🔒 restricted |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UserPasswordHistoryId)

### `sec.ExternalIdentity` — ربط هوية خارجية OIDC/Entra بالمستخدم؛ جاهزية فقط (FR-PLT-015، §11)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ExternalIdentityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| Provider | VARCHAR(10) | لا |  |  | enum: OIDC, ENTRA_ID |
| Issuer | VARCHAR(300) | لا |  |  |  |
| Subject | NVARCHAR(200) | لا |  |  | مطالبة sub |
| IsActive | BIT | لا | 1 |  |  |
| LastLoginAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ExternalIdentityId) · UQ(TenantId, Issuer, Subject) · UQ(TenantId, UserId, Provider, Issuer)

### `sec.TenantKey` — سجل مفاتيح المشترك؛ المفتاح ملفوف بمفتاح رئيسي خارج القاعدة (FR-PLT-037، BR-PLT-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TenantKeyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Purpose | VARCHAR(11) | لا |  |  | DATA أعمدة مشفّرة · BLIND_INDEX فهرس HMAC · FILE ملفات المخزن enum: DATA, BLIND_INDEX, FILE |
| KeyVersion | INT | لا |  |  |  |
| Status | VARCHAR(10) | لا | PENDING |  | ACTIVE للكتابة؛ RETIRING أثناء إعادة التشفير enum: PENDING, ACTIVE, RETIRING, RETIRED, REVOKED |
| Algorithm | VARCHAR(30) | لا | AES-256-GCM |  |  |
| WrappedKey | VARBINARY(512) | لا |  |  | لا مادة مفتاح صريحة أبدًا 🔒 restricted |
| MasterKeyRef | VARCHAR(200) | لا |  |  | معرّف المفتاح الرئيسي في المخزن المنفصل |
| ActivatedAt | DATETIME2(3) | نعم |  |  |  |
| RetiredAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantKeyId) · UQ(TenantId, Purpose, KeyVersion) · UQ(TenantId, Purpose) WHERE Status = 'ACTIVE'

**قيود:** `KeyVersion >= 1`

### `sec.KeyEvent` — سجل أحداث المفاتيح: إنشاء وتدوير وإبطال (FR-PLT-037؛ شدة عالية BR-PLT-009)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **KeyEventId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| TenantKeyId | BIGINT | نعم |  | sec.TenantKey |  |
| EventType | VARCHAR(18) | لا |  |  | enum: CREATED, ACTIVATED, ROTATION_STARTED, ROTATION_COMPLETED, RETIRED, REVOKED, UNWRAP_FAILED, MASTER_KEY_CHANGED, BACKUP_VERIFIED |
| ActorType | VARCHAR(10) | لا | SYSTEM |  | enum: USER, OPERATOR, SYSTEM, JOB |
| ActorId | UNIQUEIDENTIFIER | نعم |  |  | PublicId للمستخدم أو المشغّل |
| Result | VARCHAR(10) | لا | SUCCESS |  | enum: SUCCESS, FAILED |
| Detail | NVARCHAR(MAX) | نعم |  |  |  |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(KeyEventId)

## PLT-AUD

### `aud.AuditLog` — للإدراج فقط؛ TenantId الفارغ = حدث منصة لا يراه أي مشترك؛ سياسة RLS خاصة (BR-PLT-001/009)

*مختلط النطاق*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **AuditLogId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ChainSeq | BIGINT | نعم |  |  | تسلسل السلسلة لكل مشترك (فارغ حتى تفعيل FR-PLT-025) |
| OccurredAt | DATETIME2(3) | لا |  |  |  |
| ActorType | VARCHAR(10) | لا |  |  | enum: USER, OPERATOR, SYSTEM, JOB |
| ActorId | UNIQUEIDENTIFIER | نعم |  |  | PublicId للمستخدم أو المشغّل؛ فارغ لمحاولة ببريد غير موجود |
| Action | VARCHAR(60) | لا |  |  | مثل LOGIN_SUCCESS · IDENTITY_REVEAL · AUDIT_VIEWED |
| Category | VARCHAR(15) | لا | SYSTEM |  | يقيّد audit.view.treasury (BR-PLT-008) enum: SECURITY, CONFIG, TREASURY, IDENTITY_ACCESS, PLATFORM, SYSTEM |
| Severity | VARCHAR(10) | لا | INFO |  | enum: INFO, HIGH |
| EntityType | VARCHAR(60) | نعم |  |  | قيمة لا مفتاح أجنبي |
| EntityId | BIGINT | نعم |  |  |  |
| CompanyId | BIGINT | نعم |  |  |  |
| BeforeJson | NVARCHAR(MAX) | نعم |  |  | القيم المقيّدة مقنَّعة أبدًا غير مكشوفة (FR-PLT-023) |
| AfterJson | NVARCHAR(MAX) | نعم |  |  |  |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| IpAddress | VARCHAR(45) | نعم |  |  |  |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| Result | VARCHAR(10) | لا | SUCCESS |  | enum: SUCCESS, DENIED, FAILED |
| PrevHash | VARBINARY(32) | نعم |  |  | بصمة السابق لنفس المشترك (BR-PLT-009) |
| RowHash | VARBINARY(32) | نعم |  |  | SHA-256(PrevHash ‖ تمثيل قانوني للصف) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuditLogId) · UQ(TenantId, ChainSeq) WHERE ChainSeq IS NOT NULL

### `aud.SensitiveAccessLog` — كشف الهويات والصور والتصدير والتنزيل المقيّد؛ لكشف الشذوذ >20/ساعة وR-PLT-3 (BR-PTY-009)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SensitiveAccessLogId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OccurredAt | DATETIME2(3) | لا |  |  |  |
| AccessKind | VARCHAR(27) | لا |  |  | enum: IDENTITY_REVEAL, IDENTITY_IMAGE_VIEW, SENSITIVE_DOCUMENT_DOWNLOAD, PACK_EXPORT, SENSITIVE_EXPORT, DATA_EXPORT, CUSTOM_FIELD_REVEAL |
| ActorType | VARCHAR(10) | لا | USER |  | enum: USER, OPERATOR, SYSTEM |
| ActorUserId | BIGINT | نعم |  | sec.AppUser |  |
| OperatorId | INT | نعم |  | plat.PlatformOperator | جلسة دعم تحاول الكشف: تُرفض وتُسجَّل (FR-PLT-007) |
| SubjectEntityType | VARCHAR(60) | لا |  |  | IdentityDocument · Document · DataExportJob… |
| SubjectEntityId | BIGINT | لا |  |  |  |
| SubjectPartyId | BIGINT | نعم |  |  | صاحب الرقم؛ قيمة لا مفتاح أجنبي لتبقى بعد الدمج |
| CompanyId | BIGINT | نعم |  |  |  |
| Result | VARCHAR(10) | لا |  |  | enum: GRANTED, DENIED |
| DenyReason | VARCHAR(40) | نعم |  |  | NO_PERMISSION · SUPPORT_SESSION · OUT_OF_SCOPE · TENANT_STATE |
| Reason | NVARCHAR(300) | نعم |  |  | سبب الكشف إن فعّله المشترك (Q-PTY-05) |
| IpAddress | VARCHAR(45) | نعم |  |  |  |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| AuditLogId | BIGINT | نعم |  |  | الحدث المقابل في AuditLog |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SensitiveAccessLogId)

**قيود:** `ActorType <> 'USER' OR ActorUserId IS NOT NULL` · `ActorType <> 'OPERATOR' OR OperatorId IS NOT NULL` · `Result = 'GRANTED' OR DenyReason IS NOT NULL`

## PLT-DOC

### `doc.Document` — المستند المنطقي: بيانات المستند وحالته؛ الملف في doc.DocumentVersion (FR-PLT-027/028، BR-PLT-011)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DocumentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DocumentTypeId | INT | لا |  | cat.DocumentType | يحمل RequiresExpiry وIsSensitive وAllowedMime وMaxSizeMb (11) |
| Title | NVARCHAR(200) | لا |  |  |  |
| DocumentNumber | NVARCHAR(100) | نعم |  |  |  |
| IssueDate | DATE | نعم |  |  |  |
| IssueDateHijriText | NVARCHAR(20) | نعم |  |  | النص الهجري كما في الوثيقة (BR-PLT-012) |
| ExpiryDate | DATE | نعم |  |  |  |
| ExpiryDateHijriText | NVARCHAR(20) | نعم |  |  |  |
| IssuingAuthority | NVARCHAR(200) | نعم |  |  |  |
| OwnerCompanyId | BIGINT | نعم |  | org.Company | مالك النطاق للرؤية (BR-PLT-007)؛ الربط بأي كيان عبر DocumentLink |
| Sensitivity | VARCHAR(12) | لا | CONFIDENTIAL |  | RESTRICTED إن كان النوع IsSensitive enum: PUBLIC, INTERNAL, CONFIDENTIAL, RESTRICTED |
| Status | VARCHAR(12) | لا | ACTIVE |  | enum: ACTIVE, SUPERSEDED, SOFT_DELETED |
| CurrentVersionId | BIGINT | نعم |  | doc.DocumentVersion | يجب أن يتبع الإصدارُ المستندَ نفسه (يُفرض في التطبيق) |
| SupersededByDocumentId | BIGINT | نعم |  | doc.Document |  |
| DeletedAt | DATETIME2(3) | نعم |  |  |  |
| DeletedBy | BIGINT | نعم |  | sec.AppUser |  |
| DeleteReason | NVARCHAR(500) | نعم |  |  | الحذف منطقي بسبب وصلاحية (BR-PLT-011) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DocumentId) · UQ(PublicId)

**قيود:** `IssueDate IS NULL OR ExpiryDate IS NULL OR ExpiryDate > IssueDate` · `Status <> 'SUPERSEDED' OR SupersededByDocumentId IS NOT NULL` · `Status <> 'SOFT_DELETED' OR (DeletedAt IS NOT NULL AND DeleteReason IS NOT NULL)` · `SupersededByDocumentId IS NULL OR SupersededByDocumentId <> DocumentId`

### `doc.DocumentVersion` — إصدار ثابت من الملف؛ لا يُستبدل بل يُنشأ إصدار جديد (FR-PLT-027، BR-PLT-011)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DocumentVersionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| VersionNo | INT | لا |  |  |  |
| StorageKey | VARCHAR(300) | لا |  |  | مسار معزول لكل مشترك في مخزن الملفات |
| FileName | NVARCHAR(260) | نعم |  |  |  |
| ContentType | VARCHAR(150) | نعم |  |  | يُفحص بالمحتوى لا بالامتداد (FR-PLT-029) |
| SizeBytes | BIGINT | لا |  |  |  |
| Sha256 | VARBINARY(32) | لا |  |  | يحسبها الخادم من البايتات المستلمة |
| KeyId | BIGINT | نعم |  | sec.TenantKey | مفتاح تشفير الملف |
| ScanStatus | VARCHAR(11) | لا | PENDING |  | لا يُنزَّل إلا CLEAN enum: PENDING, CLEAN, QUARANTINED |
| ScannedAt | DATETIME2(3) | نعم |  |  |  |
| ScanDetail | NVARCHAR(300) | نعم |  |  |  |
| IntegrityStatus | VARCHAR(10) | لا | UNVERIFIED |  | فحص السلامة الدوري (FR-PLT-031) enum: UNVERIFIED, OK, MISMATCH, MISSING |
| LastVerifiedAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DocumentVersionId) · UQ(TenantId, DocumentId, VersionNo) · UQ(TenantId, StorageKey)

**قيود:** `VersionNo >= 1` · `SizeBytes > 0` · `ScanStatus = 'PENDING' OR ScannedAt IS NOT NULL`

### `doc.DocumentLink` — ربط مستند بأي كيان بدور وصفحة مرجعية؛ إلغاء الربط منطقي (FR-PLT-028)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DocumentLinkId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| EntityType | VARCHAR(60) | لا |  |  | قيمة لا مفتاح أجنبي (متعدد الأنواع) |
| EntityId | BIGINT | لا |  |  |  |
| LinkRole | VARCHAR(11) | لا | ATTACHMENT |  | enum: SOURCE, ATTACHMENT, IMAGE_FRONT, IMAGE_BACK, IMAGE_OTHER |
| PageRef | NVARCHAR(30) | نعم |  |  | الصفحة المرجعية للمصدر |
| UnlinkedAt | DATETIME2(3) | نعم |  |  |  |
| UnlinkedBy | BIGINT | نعم |  | sec.AppUser |  |
| UnlinkReason | NVARCHAR(300) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DocumentLinkId) · UQ(TenantId, DocumentId, EntityType, EntityId, LinkRole) WHERE UnlinkedAt IS NULL

**قيود:** `(UnlinkedAt IS NULL AND UnlinkedBy IS NULL) OR (UnlinkedAt IS NOT NULL AND UnlinkedBy IS NOT NULL)`

## PLT-CFG

### `cfg.SettingDefinition` — تعريف مفتاح إعداد بحدود المنصة الدنيا والقصوى (BR-PLT-018، FR-PLT-043)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **SettingDefinitionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Key | VARCHAR(100) | لا |  |  | مفتاح محجوز في T-SQL: يُقتبس دائمًا |
| ModuleCode | VARCHAR(12) | لا | CORE |  | enum: CORE, INSTITUTIONS, FACILITIES, COVENANTS, WORKFLOW, LC_PURCHASE, LC_SALES, REQUESTS, REPORTS |
| ValueType | VARCHAR(10) | لا |  |  | enum: STRING, INT, DECIMAL, BOOL, TIME, DURATION, JSON |
| DefaultValueJson | NVARCHAR(MAX) | لا |  |  |  |
| MinValueJson | NVARCHAR(MAX) | نعم |  |  | الحد الأدنى للمنصة؛ الأضعف مرفوض |
| MaxValueJson | NVARCHAR(MAX) | نعم |  |  |  |
| IsSecurity | BIT | لا | 0 |  | تغييره يُدقَّق بالقيمتين القديمة والجديدة |
| IsTenantEditable | BIT | لا | 1 |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SettingDefinitionId) · UQ(Key)

### `cfg.TenantSetting` — إعدادات المشترك: سياسات الأمان والمهل والعتبات وwork.start/work.end (FR-PLT-043)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TenantSettingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Key | VARCHAR(100) | لا |  |  | مفتاح محجوز في T-SQL: يُقتبس دائمًا؛ work.end−work.start بين 4 و12 ساعة (BR-PLT-018) في التطبيق |
| ValueJson | NVARCHAR(MAX) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantSettingId) · UQ(TenantId, Key)

### `cfg.NumberSequenceDefinition` — تعريف نوع الترقيم بصيغة بوسوم مثل {seq:000}-{erp}-{yy} (FR-PLT-026)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NumberSequenceDefinitionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| SequenceKey | VARCHAR(50) | لا |  |  | مثل PROFORMA · REQUEST (BR-ORG-001 يشترط فعّاله) |
| Pattern | NVARCHAR(100) | لا |  |  |  |
| ScopeLevel | VARCHAR(10) | لا | TENANT |  | enum: TENANT, COMPANY |
| PeriodBasis | VARCHAR(13) | لا | CALENDAR_YEAR |  | BR-PLT-010 enum: CALENDAR_YEAR, FISCAL_YEAR, NONE |
| GapPolicy | VARCHAR(10) | لا | GAP_FREE |  | بلا فجوات للطلبات والبروفورما (Q-PLT-08) enum: GAP_FREE, ALLOW_GAPS |
| MinWidth | INT | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NumberSequenceDefinitionId) · UQ(TenantId, SequenceKey) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `PeriodBasis <> 'FISCAL_YEAR' OR ScopeLevel = 'COMPANY'` · `MinWidth IS NULL OR (MinWidth >= 1 AND MinWidth <= 18)`

### `cfg.NumberSequence` — عدّاد لكل (تعريف، شركة اختيارية، فترة)؛ يُقفل صفه عند التخصيص داخل معاملة المستدعي (BR-PLT-010)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NumberSequenceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DefinitionId | BIGINT | لا |  | cfg.NumberSequenceDefinition |  |
| CompanyId | BIGINT | نعم |  | org.Company | فارغ لنطاق المشترك |
| PeriodKey | VARCHAR(10) | لا |  |  | مثل 2026 أو ALL عند NONE |
| NextValue | BIGINT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NumberSequenceId) · UQ(TenantId, DefinitionId, PeriodKey) WHERE CompanyId IS NULL · UQ(TenantId, DefinitionId, CompanyId, PeriodKey) WHERE CompanyId IS NOT NULL

**قيود:** `NextValue >= 1`

### `cfg.NumberIssue` — الأرقام الصادرة؛ الملغى لا يُعاد استعماله (FR-PLT-026، BR-PLT-010)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NumberIssueId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| SequenceId | BIGINT | لا |  | cfg.NumberSequence |  |
| SeqValue | BIGINT | لا |  |  | قيمة العدّاد المخصَّصة (كشف الفجوات) |
| IssuedNumber | NVARCHAR(60) | لا |  |  |  |
| Status | VARCHAR(10) | لا | ISSUED |  | enum: ISSUED, VOID |
| VoidReason | NVARCHAR(MAX) | نعم |  |  | إلزامي عند VOID |
| VoidedAt | DATETIME2(3) | نعم |  |  |  |
| VoidedBy | BIGINT | نعم |  | sec.AppUser |  |
| EntityType | VARCHAR(60) | نعم |  |  | الكيان المستخدِم للرقم (قيمة) |
| EntityId | BIGINT | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NumberIssueId) · UQ(TenantId, SequenceId, SeqValue) · UQ(TenantId, SequenceId, IssuedNumber)

**قيود:** `(Status = 'ISSUED' AND VoidReason IS NULL AND VoidedAt IS NULL) OR (Status = 'VOID' AND VoidReason IS NOT NULL AND VoidedAt IS NOT NULL)` · `(EntityType IS NULL AND EntityId IS NULL) OR (EntityType IS NOT NULL AND EntityId IS NOT NULL)`

### `cfg.ExpiryAlertRule` — قاعدة تنبيه انتهاء لكل نوع عنصر (FR-PLT-038، BR-PLT-013)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ExpiryAlertRuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ItemType | VARCHAR(60) | لا |  |  | مثل COMPANY_DOCUMENT · IDENTITY_DOCUMENT · BODY_TERM · AUTHORITY_GRANT |
| LeadDays | NVARCHAR(MAX) | لا |  |  | تنازلي مثل [90,60,30,7] |
| RecipientRoles | NVARCHAR(MAX) | لا |  |  | رموز الأدوار؛ المستلمون داخل نطاق الشركة |
| ScopeByCompany | BIT | لا | 1 |  |  |
| ReminderAfterExpiryDays | INT | نعم |  |  | تذكير دوري بعد الانتهاء (7 افتراضيًا) |
| IsActive | BIT | لا | 1 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ExpiryAlertRuleId) · UQ(TenantId, ItemType) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `ReminderAfterExpiryDays IS NULL OR ReminderAfterExpiryDays > 0`

### `cfg.ExpiryAlertLog` — سجل التنبيهات المرسَلة: حدث واحد لكل (عنصر، عتبة) ولا تكرار في اليوم نفسه (FR-PLT-038)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ExpiryAlertLogId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ExpiryAlertRuleId | BIGINT | لا |  | cfg.ExpiryAlertRule |  |
| ItemId | BIGINT | لا |  |  |  |
| ExpiryDate | DATE | لا |  |  | تاريخ الانتهاء وقت الإرسال: التجديد (تاريخ جديد) يعيد ضبط العتبات بلا حذف |
| AlertKind | VARCHAR(10) | لا |  |  | enum: LEAD, EXPIRED, REMINDER |
| Threshold | INT | لا | 0 |  | أيام العتبة لـ LEAD؛ 0 لـ EXPIRED؛ رقم التذكير لـ REMINDER |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ExpiryAlertLogId) · UQ(TenantId, ExpiryAlertRuleId, ItemId, ExpiryDate, AlertKind, Threshold)

### `cfg.DataExportJob` — طلب تصدير بيانات المشترك (FR-PLT-039، BR-PLT-016)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DataExportJobId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestedBy | BIGINT | لا |  | sec.AppUser |  |
| RequestedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| Scope | VARCHAR(10) | لا | FULL |  | enum: FULL, PARTIAL |
| ScopeDetailJson | NVARCHAR(MAX) | نعم |  |  | الوحدات والصيغ (JSON/CSV) وتضمين الملفات عند PARTIAL |
| IncludesRestricted | BIT | لا | 0 |  | أرقام الهويات والصور: تحتاج موافقة حامل صلاحية الكشف |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedAt | DATETIME2(3) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | REQUESTED |  | enum: REQUESTED, APPROVED, RUNNING, READY, EXPIRED, FAILED |
| StartedAt | DATETIME2(3) | نعم |  |  |  |
| FinishedAt | DATETIME2(3) | نعم |  |  |  |
| ExpiresAt | DATETIME2(3) | نعم |  |  | READY تنتهي بعد 7 أيام (§8) |
| PackageDocumentId | BIGINT | نعم |  | doc.Document | الحزمة المختومة بكلمة يحددها الطالب (لا تُخزَّن الكلمة) |
| PackageSha256 | VARBINARY(32) | نعم |  |  |  |
| FailureReason | NVARCHAR(500) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DataExportJobId) · UQ(PublicId)

**قيود:** `IncludesRestricted = 0 OR Status NOT IN ('APPROVED','RUNNING','READY') OR ApprovedBy IS NOT NULL` · `Status <> 'READY' OR (PackageDocumentId IS NOT NULL AND PackageSha256 IS NOT NULL)` · `FinishedAt IS NULL OR StartedAt IS NULL OR FinishedAt >= StartedAt`

### `cfg.NonWorkingDay` — يوم غير عمل؛ TenantId الفارغ = عطلة المنصة للقراءة فقط (FR-PLT-035، BR-PLT-014)

*مختلط النطاق*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **NonWorkingDayId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CountryId | INT | لا |  | ref.Country |  |
| OnDate | DATE | لا |  |  |  |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Kind | VARCHAR(10) | لا | HOLIDAY |  | enum: HOLIDAY, BRIDGE, OTHER |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NonWorkingDayId) · UQ(TenantId, CountryId, OnDate)

### `cfg.OutboxEvent` — طابور الإرسال: تسليم مرة واحدة على الأقل؛ الحمولة معرّفات بلا بيانات مقيّدة (FR-PLT-042)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **OutboxEventId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| MessageId | UNIQUEIDENTIFIER | لا | NEWID() |  | مفتاح إزالة التكرار عند المستهلك |
| EventName | VARCHAR(100) | لا |  |  | domain.event_name بحروف صغيرة (00 §5) |
| AggregateType | VARCHAR(60) | نعم |  |  |  |
| AggregateId | BIGINT | نعم |  |  |  |
| PayloadJson | NVARCHAR(MAX) | لا |  |  |  |
| OccurredAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| Status | VARCHAR(10) | لا | PENDING |  | enum: PENDING, PROCESSING, DELIVERED, FAILED, DEAD |
| AttemptCount | INT | لا | 0 |  |  |
| NextAttemptAt | DATETIME2(3) | نعم |  |  |  |
| LockedBy | VARCHAR(60) | نعم |  |  | العامل الحاجز |
| LockedUntil | DATETIME2(3) | نعم |  |  |  |
| DeliveredAt | DATETIME2(3) | نعم |  |  |  |
| LastError | NVARCHAR(1000) | نعم |  |  |  |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(OutboxEventId) · UQ(TenantId, MessageId)

**قيود:** `AttemptCount >= 0` · `EventName LIKE '%.%'`

### `cfg.JobRun` — سجل تشغيل المهام الخلفية: آخر تشغيل ومدته ونتيجته ظاهر لمدير الحساب (FR-PLT-044)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **JobRunId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| JobKey | VARCHAR(80) | لا |  |  | مثل EXPIRY_ALERTS · FILE_INTEGRITY · AUDIT_CHAIN_VERIFY |
| TriggerKind | VARCHAR(10) | لا | SCHEDULED |  | enum: SCHEDULED, MANUAL, RETRY |
| Status | VARCHAR(10) | لا | RUNNING |  | enum: RUNNING, SUCCEEDED, FAILED, CANCELLED |
| AttemptNo | INT | لا | 1 |  |  |
| StartedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| FinishedAt | DATETIME2(3) | نعم |  |  |  |
| DurationMs | INT | نعم |  |  |  |
| NextRetryAt | DATETIME2(3) | نعم |  |  | إعادة المحاولة خلال ساعة عند الفشل |
| ResultSummary | NVARCHAR(1000) | نعم |  |  |  |
| ErrorMessage | NVARCHAR(2000) | نعم |  |  |  |
| DetailJson | NVARCHAR(MAX) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(JobRunId)

**قيود:** `AttemptNo >= 1` · `FinishedAt IS NULL OR FinishedAt >= StartedAt` · `(Status = 'RUNNING' AND FinishedAt IS NULL) OR (Status <> 'RUNNING' AND FinishedAt IS NOT NULL)`

### `cfg.SeedRun` — سجل تشغيل البذر المُرقَّم لكل حزمة؛ تكرار التشغيل لا يكرر شيئًا (FR-PLT-008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SeedRunId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PackKey | VARCHAR(80) | لا |  |  | حزمة كل وحدة (ITenantSeeder) |
| SeedVersion | INT | لا |  |  |  |
| RunKind | VARCHAR(10) | لا |  |  | enum: INITIAL, UPGRADE, RERUN |
| Status | VARCHAR(10) | لا |  |  | enum: SUCCEEDED, PARTIAL, FAILED |
| CreatedCount | INT | لا | 0 |  |  |
| UpdatedCount | INT | لا | 0 |  |  |
| SkippedModifiedCount | INT | لا | 0 |  | صفوف عدّلها المشترك فلا تُستبدل ويُعرض الفرق للمراجعة |
| DiffJson | NVARCHAR(MAX) | نعم |  |  |  |
| StartedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| FinishedAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SeedRunId)

**قيود:** `SeedVersion >= 1`

## ORG

### `org.Company` — الشركة: جذر الهيكل المؤسسي (FR-ORG-001..010، BR-ORG-001..004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyCode | VARCHAR(20) | لا |  |  | رمز داخلي فريد في المشترك (BR-ORG-001) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| PartyId | BIGINT | لا |  | pty.Party | Party المرآة تُنشأ آليًا وتبقى للقراءة (FR-PTY-003، BR-PTY-018) |
| LegalEntityTypeId | INT | لا |  | cat.LegalEntityType | الشكل القانوني؛ توافق دولته مع CountryId في التطبيق (BR-ORG-016) |
| IsHolding | BIT | لا | 0 |  | قابضة: علم مستقل عن الشكل القانوني (FR-ORG-003، BR-ORG-003) |
| ParentCompanyId | BIGINT | نعم |  | org.Company | الأم؛ منع الحلقات والعمق الأقصى 10 في التطبيق (FR-ORG-004، BR-ORG-002) |
| CountryId | INT | لا |  | ref.Country | بلد التأسيس |
| Status | VARCHAR(10) | لا | ACTIVE |  | الأرشفة ممنوعة مع استخدام نشط (FR-ORG-010) enum: ACTIVE, DORMANT, LIQUIDATED, ARCHIVED |
| EstablishedOn | DATE | نعم |  |  | تاريخ التأسيس |
| CrNumber | VARCHAR(30) | نعم |  |  | رقم السجل التجاري (FR-ORG-005) |
| CrDate | DATE | نعم |  |  |  |
| CrDateHijriText | NVARCHAR(20) | نعم |  |  | التاريخ الهجري كما في الوثيقة (X-DAT-2) |
| TaxNumber | VARCHAR(30) | نعم |  |  | الرقم الضريبي؛ التفصيل الضريبي (FATCA/CRS) في pty.TaxIdentity |
| ErpCompanyCode | NVARCHAR(20) | نعم |  |  | رمز ERP يدوي بعد التقليم؛ يحمله رقم البروفورما {seq}-{erp}-{yy} (BR-ORG-001) |
| ErpCodeNormalized | NVARCHAR(20) | نعم |  |  | مشتق مخزَّن: تقليم + حروف كبيرة + حذف الفراغات (=صيغة BR-LCE-002) |
| FiscalYearEndMonth | TINYINT | لا |  |  | 1..12 (FR-ORG-006، BR-ORG-004) |
| FiscalYearEndDay | TINYINT | نعم |  |  | فارغ = آخر الشهر |
| BaseCurrencyId | INT | نعم |  | ref.Currency | العملة الأساسية (FR-ORG-008)؛ المواصفة تسميه BaseCurrencyCode |
| OwnershipStatus | VARCHAR(12) | لا | UNDOCUMENTED |  | اكتمال توثيق الملكية (FR-ORG-016) enum: COMPLETE, UNDOCUMENTED |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyId) · UQ(PublicId) · UQ(TenantId, CompanyCode) · UQ(TenantId, PartyId) · UQ(TenantId, CountryId, CrNumber) WHERE CrNumber IS NOT NULL AND Status <> 'ARCHIVED' · UQ(TenantId, ErpCodeNormalized) WHERE ErpCodeNormalized IS NOT NULL AND Status <> 'ARCHIVED'

**قيود:** `FiscalYearEndMonth BETWEEN 1 AND 12` · `FiscalYearEndDay IS NULL OR FiscalYearEndDay BETWEEN 1 AND 31` · `ParentCompanyId IS NULL OR ParentCompanyId <> CompanyId` · `ErpCompanyCode IS NULL OR ErpCodeNormalized IS NOT NULL`

### `org.CompanyTaxRate` — نسبة ضريبة بتاريخ سريان؛ CompanyId فارغ = افتراضي المشترك (FR-ORG-007، BR-ORG-005)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyTaxRateId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | نعم |  | org.Company |  |
| TaxCode | VARCHAR(20) | لا |  |  | مثل VAT |
| RatePercent | DECIMAL(9,6) | لا |  |  | نقاط مئوية |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  | صف جديد يغلق السابق بيوم قبل بدايته |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyTaxRateId) · UQ(TenantId, CompanyId, TaxCode, EffectiveFrom) · UQ(TenantId, CompanyId, TaxCode) WHERE EffectiveTo IS NULL

**قيود:** `RatePercent >= 0 AND RatePercent <= 100` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom`

### `org.Department` — الإدارة (FR-ORG-014، BR-ORG-016، Q-ORG-09: على مستوى المشترك وشركة اختيارية)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DepartmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(20) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Function | VARCHAR(11) | لا |  |  | enum: PROCUREMENT, SALES, TREASURY, FINANCE, OTHER |
| IsTreasury | BIT | لا | 0 |  | يُنصح بإدارة واحدة على الأقل (تحذير في التطبيق) |
| CompanyId | BIGINT | نعم |  | org.Company |  |
| ParentDepartmentId | BIGINT | نعم |  | org.Department |  |
| HeadUserId | BIGINT | نعم |  | sec.AppUser |  |
| IsActive | BIT | لا | 1 |  | تعطيل إدارة فيها مستخدمون يُرفض في التطبيق |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DepartmentId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `ParentDepartmentId IS NULL OR ParentDepartmentId <> DepartmentId`

### `org.Shareholding` — حصة ملكية بتاريخ سريان؛ المالك Party فرد أو جهة (FR-ORG-015..018، BR-ORG-006..008، G-7)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ShareholdingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| HolderPartyId | BIGINT | لا |  | pty.Party |  |
| SharePercent | DECIMAL(9,6) | لا |  |  | (0,100]؛ مجموع الحصص السارية بمستوى Layer=1 = 100 تتحقق منه المعاملة (BR-ORG-006) |
| SharesCount | DECIMAL(19,4) | نعم |  |  |  |
| NominalValue | DECIMAL(19,4) | نعم |  |  | القيمة الاسمية للسهم |
| CurrencyId | INT | نعم |  | ref.Currency | عملة القيمة الاسمية (إلزامية عند وجودها) |
| Layer | TINYINT | لا | 1 |  | 1 = مالك مباشر؛ 2.. = غير مباشر عبر كيانات وسيطة (G-7) |
| IsBeneficialOwner | BIT | لا | 0 |  | مستفيد حقيقي >= 25% أو تحكم (G-7) |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  | القديم يُغلق بيوم قبل السريان الجديد (BR-ORG-007) |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ShareholdingId) · UQ(TenantId, CompanyId, HolderPartyId, Layer, EffectiveFrom) · UQ(TenantId, CompanyId, HolderPartyId, Layer) WHERE EffectiveTo IS NULL

**قيود:** `SharePercent > 0 AND SharePercent <= 100` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `Layer >= 1` · `SharesCount IS NULL OR SharesCount > 0` · `NominalValue IS NULL OR (NominalValue >= 0 AND CurrencyId IS NOT NULL)`

### `org.GoverningBody` — هيئة حوكمة (FR-ORG-019، BR-ORG-009)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **GoverningBodyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| BodyType | VARCHAR(18) | لا |  |  | enum: BOARD_OF_DIRECTORS, BOARD_OF_MANAGERS, MANAGEMENT, GENERAL_ASSEMBLY |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| TermStart | DATE | نعم |  |  |  |
| TermEnd | DATE | نعم |  |  |  |
| QuorumRuleText | NVARCHAR(MAX) | نعم |  |  | نص حر (لا تنفيذ آلي) |
| DecisionRuleText | NVARCHAR(MAX) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | ACTIVE |  | استبدال هيئة بمدة جديدة يغلق السابقة enum: ACTIVE, CLOSED |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(GoverningBodyId) · UQ(PublicId) · UQ(TenantId, CompanyId, BodyType) WHERE Status = 'ACTIVE'

**قيود:** `TermEnd IS NULL OR TermStart IS NULL OR TermEnd >= TermStart`

### `org.BodyMember` — عضوية في هيئة (FR-ORG-020، FR-ORG-021، BR-ORG-010)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BodyMemberId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company | مكرَّر من الهيئة لضمان سلامة الربط بالمنح (via)؛ يطابق CompanyId للهيئة بقيد مركّب |
| BodyId | BIGINT | لا |  | org.GoverningBody (via CompanyId) |  |
| PartyId | BIGINT | لا |  | pty.Party |  |
| PositionId | INT | لا |  | cat.Position |  |
| TermStart | DATE | لا |  |  |  |
| TermEnd | DATE | نعم |  |  | الافتراضي = نهاية مدة الهيئة (BR-ORG-010) |
| RepresentedPartyId | BIGINT | نعم |  | pty.Party | ممثل عن عضو اعتباري |
| ResignedOn | DATE | نعم |  |  |  |
| AppointmentDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BodyMemberId) · UQ(TenantId, BodyId, PartyId, PositionId, TermStart) · UQ(TenantId, BodyId, PartyId, PositionId) WHERE TermEnd IS NULL AND ResignedOn IS NULL

**قيود:** `TermEnd IS NULL OR TermEnd >= TermStart` · `ResignedOn IS NULL OR ResignedOn >= TermStart` · `RepresentedPartyId IS NULL OR RepresentedPartyId <> PartyId`

### `org.AuthorityGrant` — تفويض/منحة صلاحية لشركة (FR-ORG-023..028، BR-ORG-011..014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AuthorityGrantId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| GranteeKind | VARCHAR(11) | لا |  |  | enum: BODY, BODY_MEMBER, PARTY |
| BodyId | BIGINT | نعم |  | org.GoverningBody (via CompanyId) | واحد فقط بحسب GranteeKind |
| BodyMemberId | BIGINT | نعم |  | org.BodyMember (via CompanyId) |  |
| PartyId | BIGINT | نعم |  | pty.Party |  |
| PowerTypeId | INT | لا |  | cat.PowerType |  |
| InstitutionId | BIGINT | نعم |  | ins.Institution | تقييد ببنك؛ الفارغ = عام (FR-ORG-025، BR-ACC-015) |
| CeilingAmount | DECIMAL(19,4) | نعم |  |  | فارغ = غير محدد؛ الصفر مرفوض (BR-ORG-011) |
| CeilingCurrencyId | INT | نعم |  | ref.Currency | عملة السقف؛ المواصفة تسميه CeilingCurrency |
| RequiresJoint | BIT | لا | 0 |  | توقيع مشترك (BR-ORG-012) |
| JointMinSignatories | INT | نعم |  |  | >= 2 حين RequiresJoint (الافتراضي 2 من التطبيق) |
| JointNote | NVARCHAR(MAX) | نعم |  |  | نص شرط التوقيع المشترك («مع رئيس المجلس») |
| ValidFrom | DATE | لا |  |  |  |
| ValidFromHijriText | NVARCHAR(20) | نعم |  |  |  |
| ValidTo | DATE | نعم |  |  | فارغ = مفتوحة؛ الحالات المنتهية/تنتهي قريبًا مشتقة ولا تُخزَّن |
| Status | VARCHAR(16) | لا | DRAFT |  | enum: DRAFT, PENDING_APPROVAL, ACTIVE, SUPERSEDED, REVOKED |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser | الموافِق غير المنشئ عند تفعيل فصل المهام (BR-ORG-014) |
| ApprovedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedReason | NVARCHAR(MAX) | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document | وكالة/قرار مجلس (BR-ORG-013) |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ExceptionReason | NVARCHAR(500) | نعم |  |  | استثناء موثَّق بدل مستند المصدر يوافق عليه مدير الخزينة |
| SupersedesGrantId | BIGINT | نعم |  | org.AuthorityGrant | المنحة الجديدة تحل محل القديمة (BR-ORG-014) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuthorityGrantId) · UQ(PublicId)

**قيود:** `(GranteeKind = 'BODY' AND BodyId IS NOT NULL AND BodyMemberId IS NULL AND PartyId IS NULL) OR (GranteeKind = 'BODY_MEMBER' AND BodyId IS NULL AND BodyMemberId IS NOT NULL AND PartyId IS NULL) OR (GranteeKind = 'PARTY' AND BodyId IS NULL AND BodyMemberId IS NULL AND PartyId IS NOT NULL)` · `CeilingAmount IS NULL OR CeilingAmount > 0` · `(CeilingAmount IS NULL AND CeilingCurrencyId IS NULL) OR (CeilingAmount IS NOT NULL AND CeilingCurrencyId IS NOT NULL)` · `(RequiresJoint = 1 AND JointMinSignatories IS NOT NULL AND JointMinSignatories >= 2) OR (RequiresJoint = 0 AND JointMinSignatories IS NULL)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `Status IN ('DRAFT','PENDING_APPROVAL') OR SourceDocumentId IS NOT NULL OR ExceptionReason IS NOT NULL` · `Status <> 'REVOKED' OR (RevokedAt IS NOT NULL AND RevokedReason IS NOT NULL)` · `SupersedesGrantId IS NULL OR SupersedesGrantId <> AuthorityGrantId`

### `org.CompanyProfile` — ملف تعريف الشركة 1:1 (G-1)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyProfileId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| UnifiedNationalNo | VARCHAR(20) | نعم |  |  | الرقم الوطني الموحد |
| ForeignInvestmentLicenseNo | VARCHAR(40) | نعم |  |  | رخصة الاستثمار الأجنبي |
| ForeignInvestmentLicenseIssuedOn | DATE | نعم |  |  |  |
| ForeignInvestmentLicenseExpiresOn | DATE | نعم |  |  |  |
| GovernmentEntityId | VARCHAR(40) | نعم |  |  | رقم تعريف الجهات الحكومية |
| Lei | VARCHAR(20) | نعم |  |  | معرّف الكيانات القانونية (20 خانة) |
| HeadquartersCountryId | INT | نعم |  | ref.Country | بلد المقر الرئيسي |
| EntityKind | VARCHAR(19) | نعم |  |  | نوع المنشأة enum: COMPANY, SOLE_PROPRIETORSHIP, GOVERNMENT, OTHER |
| NationalityClass | VARCHAR(10) | نعم |  |  | جنسية المنشأة (محلية/خليجية/أخرى) نسبةً لدولة المشترك enum: DOMESTIC, GCC, OTHER |
| SectorId | INT | نعم |  | cat.LookupItem | القطاع (قائمة BUSINESS_SECTOR) |
| PrimaryActivityText | NVARCHAR(300) | نعم |  |  | النشاط الأساسي حسب السجل |
| ActivityNature | NVARCHAR(300) | نعم |  |  | طبيعة النشاط |
| ActivityDescription | NVARCHAR(MAX) | نعم |  |  | نبذة عن النشاط |
| EmployeeBandId | INT | نعم |  | cat.LookupItem | شريحة الموظفين (قائمة EMPLOYEE_BAND) |
| DeclaredBranchCount | INT | نعم |  |  | عدد الفروع والمستودعات المعلن؛ التفصيل في CompanyBranch |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyProfileId) · UQ(TenantId, CompanyId)

**قيود:** `Lei IS NULL OR Lei LIKE '____________________'` · `ForeignInvestmentLicenseExpiresOn IS NULL OR ForeignInvestmentLicenseIssuedOn IS NULL OR ForeignInvestmentLicenseExpiresOn > ForeignInvestmentLicenseIssuedOn` · `DeclaredBranchCount IS NULL OR DeclaredBranchCount >= 0`

### `org.CompanyBranch` — فرع/مستودع/تابعة خارج الحساب كنص (G-3)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyBranchId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| BranchKind | VARCHAR(19) | لا | BRANCH |  | التابعة داخل الحساب = Company بأم، لا صف هنا enum: BRANCH, WAREHOUSE, EXTERNAL_SUBSIDIARY |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| CountryId | INT | نعم |  | ref.Country |  |
| LocationText | NVARCHAR(300) | نعم |  |  |  |
| CrNumber | VARCHAR(30) | نعم |  |  | سجل الفرع التجاري |
| UnifiedNationalNo | VARCHAR(20) | نعم |  |  |  |
| ActivityText | NVARCHAR(300) | نعم |  |  |  |
| OwnershipPercent | DECIMAL(9,6) | نعم |  |  | للتابعة الخارجية فقط |
| Status | VARCHAR(10) | لا | ACTIVE |  | enum: ACTIVE, CLOSED |
| ClosedOn | DATE | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyBranchId) · UQ(TenantId, CompanyId, CrNumber) WHERE CrNumber IS NOT NULL

**قيود:** `NameAr IS NOT NULL OR NameEn IS NOT NULL` · `OwnershipPercent IS NULL OR (BranchKind = 'EXTERNAL_SUBSIDIARY' AND OwnershipPercent > 0 AND OwnershipPercent <= 100)` · `ClosedOn IS NULL OR Status = 'CLOSED'`

### `org.CompanyKycFinancialProfile` — الملف المالي KYC بتاريخ سريان: شريحة الإيرادات والغرض (G-4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyKycFinancialProfileId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  |  |
| RevenueBandId | INT | نعم |  | cat.LookupItem | شريحة الإيرادات السنوية (قائمة REVENUE_BAND) |
| AccountPurposeText | NVARCHAR(500) | نعم |  |  | الغرض من الحساب/المنتج |
| AccountCurrencyId | INT | نعم |  | ref.Currency | عملة الحساب الأساسية |
| PreferredLanguage | VARCHAR(10) | نعم |  |  | enum: ar, en |
| FundsTransferSource | NVARCHAR(300) | نعم |  |  | مصدر الأموال المحوَّلة للحساب |
| RequestedServices | NVARCHAR(300) | نعم |  |  | الخدمات المطلوبة (نص حر) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyKycFinancialProfileId) · UQ(TenantId, CompanyId, EffectiveFrom) · UQ(TenantId, CompanyId) WHERE EffectiveTo IS NULL

**قيود:** `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom`

### `org.CompanyExpectedFlow` — مصفوفة الحركة المتوقعة الشهرية CTP: اتجاه × 5 بنود (G-4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyExpectedFlowId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FinancialProfileId | BIGINT | لا |  | org.CompanyKycFinancialProfile |  |
| Direction | VARCHAR(10) | لا |  |  | enum: DEPOSIT, WITHDRAWAL |
| FlowKind | VARCHAR(22) | لا |  |  | enum: CASH, OTHER, LOCAL_TRANSFER, INTERNATIONAL_TRANSFER, CHEQUE |
| MonthlyAmount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyExpectedFlowId) · UQ(TenantId, FinancialProfileId, Direction, FlowKind)

**قيود:** `MonthlyAmount >= 0`

### `org.CompanyWealthSource` — مصادر الأموال والثروة: قائمة متعددة (G-4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| FinancialProfileId | BIGINT | لا |  | org.CompanyKycFinancialProfile |  |
| WealthSourceId | INT | لا |  | cat.LookupItem | قائمة WEALTH_SOURCE (تمويل داخلي، إيرادات تجارية، تسهيلات، بيع أصول...) |
| OtherText | NVARCHAR(200) | نعم |  |  | وصف عند «أخرى» |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, FinancialProfileId, WealthSourceId)

### `org.CompanyDisclosure` — إفصاحات الشركة (G-5)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyDisclosureId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| DisclosureKind | VARCHAR(23) | لا |  |  | enum: REGULATORY_DISCIPLINARY, TAX_ISSUE, LITIGATION, FACILITY_RESCHEDULING, CONVICTION, OTHER |
| Description | NVARCHAR(MAX) | لا |  |  |  |
| EventDate | DATE | نعم |  |  |  |
| Status | VARCHAR(10) | لا | OPEN |  | enum: OPEN, RESOLVED |
| ResolvedOn | DATE | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyDisclosureId)

**قيود:** `ResolvedOn IS NULL OR Status = 'RESOLVED'`

### `org.CompanyKeyRelation` — أصحاب العلاقة: مدققون، مستشار قانوني، جهات تنظيمية، أبرز العملاء/الموردين (G-6)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyKeyRelationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| RelationKind | VARCHAR(14) | لا |  |  | enum: AUDITOR, ACCOUNTANT, LEGAL_ADVISOR, REGULATOR, MAJOR_CUSTOMER, MAJOR_SUPPLIER, OTHER |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Note | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyKeyRelationId)

**قيود:** `NameAr IS NOT NULL OR NameEn IS NOT NULL`

## PTY

### `pty.Party` — شخص أو جهة؛ لا دور مخزَّن (FR-PTY-001..003، BR-PTY-001..004، BR-PTY-016..018)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PartyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyCode | VARCHAR(20) | لا |  |  | مُولَّد من NumberSequence |
| Kind | VARCHAR(12) | لا |  |  | enum: INDIVIDUAL, ORGANIZATION |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| NameNormalized | NVARCHAR(400) | نعم |  |  | الاسم العربي/الإنجليزي المطبَّع للبحث وفحص التشابه؛ يحسبه التطبيق عند الكتابة (FR-PTY-002، BR-PTY-004) |
| CountryId | INT | نعم |  | ref.Country | جنسية (فرد) أو دولة تأسيس (جهة) |
| ResidencyStatus | VARCHAR(12) | نعم |  |  | للأفراد enum: CITIZEN, RESIDENT, NON_RESIDENT, UNKNOWN |
| BirthDate | DATE | نعم |  |  | 🔒 confidential |
| BirthDateHijriText | NVARCHAR(20) | نعم |  |  | G-11 🔒 confidential |
| BirthPlace | NVARCHAR(100) | نعم |  |  | 🔒 confidential |
| BirthCountryId | INT | نعم |  | ref.Country | بلد الميلاد (05 قسم 1.2) |
| MaritalStatus | VARCHAR(10) | نعم |  |  | قيم مقترحة؛ المواصفة لا تعددها enum: SINGLE, MARRIED, DIVORCED, WIDOWED 🔒 confidential |
| Gender | VARCHAR(10) | نعم |  |  | اختياري يطلبه نموذج بنك (G-12، BR-PTY-019) enum: MALE, FEMALE 🔒 confidential |
| EducationLevelId | INT | نعم |  | cat.LookupItem | اختياري (G-12، س-14)؛ قائمة EDUCATION_LEVEL 🔒 confidential |
| LinkedCompanyId | BIGINT | نعم |  | org.Company | الشركة التي هذه مرآتها (FR-PTY-003) |
| IsActive | BIT | لا | 1 |  |  |
| MergedIntoPartyId | BIGINT | نعم |  | pty.Party | Merged لا تعود (BR-PTY-016) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PartyId) · UQ(PublicId) · UQ(TenantId, PartyCode) · UQ(TenantId, LinkedCompanyId) WHERE LinkedCompanyId IS NOT NULL

**قيود:** `NameAr IS NOT NULL OR NameEn IS NOT NULL` · `Kind = 'INDIVIDUAL' OR (ResidencyStatus IS NULL AND BirthDate IS NULL AND MaritalStatus IS NULL AND Gender IS NULL AND EducationLevelId IS NULL)` · `LinkedCompanyId IS NULL OR Kind = 'ORGANIZATION'` · `MergedIntoPartyId IS NULL OR (IsActive = 0 AND MergedIntoPartyId <> PartyId)`

### `pty.IdentityDocument` — وثيقة هوية؛ الرقم مشفّر والصور مستندات مقيَّدة (FR-PTY-004..009، FR-PTY-020..022، BR-PTY-002..008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **IdentityDocumentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| DocKind | VARCHAR(14) | لا |  |  | enum: NATIONAL_ID, RESIDENCE, PASSPORT, GCC_ID, COMMERCIAL_REG, OTHER_ORG |
| IssuingCountryId | INT | لا |  | ref.Country |  |
| IssuingAuthority | NVARCHAR(200) | نعم |  |  |  |
| IssuePlace | NVARCHAR(100) | نعم |  |  | مكان الإصدار (05 قسم 1.2) |
| NumberEnc | VARBINARY(512) | لا |  |  | الرقم مشفَّر بمفتاح المشترك (FR-PTY-006) 🔒 restricted |
| NumberMask | NVARCHAR(32) | لا |  |  | قناع العرض يُحسب عند الكتابة؛ آخر 4 خانات (BR-PTY-008) 🔒 restricted |
| NumberHash | VARBINARY(32) | لا |  |  | HMAC فهرس أعمى: النوع+الدولة+الرقم المطبَّع (BR-PTY-002) 🔒 restricted |
| IssueDate | DATE | نعم |  |  |  |
| IssueDateHijriText | NVARCHAR(20) | نعم |  |  | G-11 |
| ExpiryDate | DATE | نعم |  |  |  |
| ExpiryDateHijriText | NVARCHAR(20) | نعم |  |  | G-11 |
| IsPrimary | BIT | لا | 0 |  | أساسية واحدة بين غير المستبدلة (BR-PTY-005) |
| IsSuperseded | BIT | لا | 0 |  | «مستبدلة» مخزَّنة عند التجديد (القسم 8)؛ تُعلَّم أولًا ثم يُنشأ البديل ثم يُربط SupersededById ضمن معاملة التجديد (الرقم نفسه يتكرر في تجديد الهوية) |
| SupersededById | BIGINT | نعم |  | pty.IdentityDocument | التجديد ينشئ وثيقة جديدة تستبدل القديمة (FR-PTY-022، BR-PTY-006) |
| VerifiedAt | DATETIME2(3) | نعم |  |  | «تم التحقق من الأصل» (FR-PTY-020) |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IdentityDocumentId) · UQ(TenantId, DocKind, IssuingCountryId, NumberHash) WHERE IsSuperseded = 0 · UQ(TenantId, PartyId) WHERE IsPrimary = 1

**قيود:** `ExpiryDate IS NULL OR IssueDate IS NULL OR ExpiryDate > IssueDate` · `SupersededById IS NULL OR (SupersededById <> IdentityDocumentId AND IsSuperseded = 1)` · `IsSuperseded = 0 OR IsPrimary = 0` · `VerifiedBy IS NULL OR VerifiedAt IS NOT NULL`

### `pty.Address` — عنوان متعدد الملكية: OwnerType+OwnerId بلا FK (مزوّد المالك يتحقق منه التطبيق) (FR-PTY-011، BR-PTY-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AddressId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OwnerType | VARCHAR(11) | لا |  |  | قابل للتوسعة بمزوّد مالك enum: PARTY, INSTITUTION, UNIT, CONTACT |
| OwnerId | BIGINT | لا |  |  |  |
| AddressType | VARCHAR(11) | لا |  |  | enum: NATIONAL, RESIDENTIAL, WORK, PO_BOX, REGISTERED, OTHER |
| IsPrimary | BIT | لا | 0 |  |  |
| IsCurrent | BIT | لا | 1 |  |  |
| CountryId | INT | لا |  | ref.Country |  |
| Region | NVARCHAR(100) | نعم |  |  |  |
| City | NVARCHAR(100) | نعم |  |  |  |
| District | NVARCHAR(100) | نعم |  |  |  |
| Street | NVARCHAR(150) | نعم |  |  |  |
| BuildingNumber | NVARCHAR(20) | نعم |  |  |  |
| UnitNumber | NVARCHAR(20) | نعم |  |  |  |
| PostalCode | NVARCHAR(20) | نعم |  |  |  |
| AdditionalNumber | NVARCHAR(20) | نعم |  |  |  |
| ShortCode | NVARCHAR(20) | نعم |  |  |  |
| PoBoxNumber | NVARCHAR(30) | نعم |  |  |  |
| FreeText | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AddressId) · UQ(TenantId, OwnerType, OwnerId) WHERE IsPrimary = 1 AND IsCurrent = 1

**قيود:** `IsPrimary = 0 OR IsCurrent = 1` · `AddressType <> 'PO_BOX' OR PoBoxNumber IS NOT NULL`

### `pty.ContactMethod` — وسيلة اتصال متعددة الملكية (FR-PTY-012، BR-PTY-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ContactMethodId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OwnerType | VARCHAR(11) | لا |  |  | enum: PARTY, INSTITUTION, UNIT, CONTACT |
| OwnerId | BIGINT | لا |  |  |  |
| Kind | VARCHAR(10) | لا |  |  | enum: MOBILE, PHONE, EMAIL, FAX, WEBSITE, OTHER |
| Value | NVARCHAR(200) | لا |  |  |  |
| NormalizedValue | NVARCHAR(200) | لا |  |  | هاتف E.164 / بريد صغير الأحرف؛ مطلوب لتنفيذ الفرادة |
| Label | NVARCHAR(100) | نعم |  |  |  |
| IsPrimary | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ContactMethodId) · UQ(TenantId, OwnerType, OwnerId, Kind, NormalizedValue) · UQ(TenantId, OwnerType, OwnerId, Kind) WHERE IsPrimary = 1

### `pty.CustomFieldDefinition` — تعريف حقل مخصص (FR-PTY-013، BR-PTY-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CustomFieldDefinitionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FieldKey | VARCHAR(60) | لا |  |  |  |
| LabelAr | NVARCHAR(200) | لا |  |  |  |
| LabelEn | NVARCHAR(200) | لا |  |  |  |
| DataType | VARCHAR(10) | لا |  |  | enum: TEXT, NUMBER, DATE, LIST, BOOLEAN, AMOUNT |
| ListValues | NVARCHAR(MAX) | نعم |  |  |  |
| Sensitivity | VARCHAR(12) | لا | CONFIDENTIAL |  | المقيَّد يُشفَّر ويُقنَّع (FR-PTY-014) enum: CONFIDENTIAL, RESTRICTED |
| InstitutionId | BIGINT | نعم |  | ins.Institution | نطاق بنك اختياري |
| AppliesToKind | VARCHAR(12) | نعم |  |  | فارغ = الاثنان enum: INDIVIDUAL, ORGANIZATION |
| IsActive | BIT | لا | 1 |  | تعريف له قيم يُعطَّل ولا يُحذف |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CustomFieldDefinitionId) · UQ(TenantId, FieldKey) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(DataType = 'LIST' AND ListValues IS NOT NULL) OR (DataType <> 'LIST' AND ListValues IS NULL)`

### `pty.PartyCustomField` — قيمة حقل مخصص لشخص (FR-PTY-013، FR-PTY-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PartyCustomFieldId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| DefinitionId | BIGINT | لا |  | pty.CustomFieldDefinition |  |
| ValueText | NVARCHAR(1000) | نعم |  |  |  |
| ValueEnc | VARBINARY(512) | نعم |  |  | للحقل المقيَّد بدل ValueText 🔒 restricted |
| ValueMask | NVARCHAR(32) | نعم |  |  | قناع يُحسب عند الكتابة (BR-PTY-008) |
| CurrencyId | INT | نعم |  | ref.Currency | لنوع AMOUNT |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PartyCustomFieldId) · UQ(TenantId, PartyId, DefinitionId)

**قيود:** `ValueText IS NULL OR ValueEnc IS NULL` · `ValueEnc IS NULL OR ValueMask IS NOT NULL`

### `pty.KycProfile` — قائمة اكتمال KYC لكل بنك ودور (FR-PTY-023، BR-PTY-012..013، G-8، G-14)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **KycProfileId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | نعم |  | ins.Institution | فارغ فقط لملف الأساس IsBaseline (FR-PTY-023): المواصفة تجعله إلزاميًا |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| AppliesToRole | VARCHAR(11) | لا |  |  | enum: GUARANTOR, SHAREHOLDER, SIGNATORY, ANY |
| AppliesToKind | VARCHAR(12) | نعم |  |  | فارغ = الاثنان enum: INDIVIDUAL, ORGANIZATION |
| Version | INT | لا | 1 |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | تفعيل نسخة يسحب السابقة؛ الحسابات التاريخية تحتفظ بإصدارها enum: DRAFT, ACTIVE, RETIRED |
| IsBaseline | BIT | لا | 0 |  |  |
| OwnerThresholdPct | DECIMAL(9,6) | نعم |  |  | عتبة الملكية التي يُطلب عندها KYC للمالك: 25 أو 5 (G-8) |
| SourceDocumentId | BIGINT | نعم |  | doc.Document | نموذج KYC الممسوح |
| SeedKey | VARCHAR(80) | نعم |  |  | KYC-CORP-BASE / EXIM / SAB / RIYAD / PERSON-SIGNATORY / PERSON-OWNER / GUARANTOR (05 قسم 3) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(KycProfileId) · UQ(PublicId) · UQ(TenantId, InstitutionId, AppliesToRole, AppliesToKind, Version) · UQ(TenantId, InstitutionId, AppliesToRole, AppliesToKind) WHERE Status = 'ACTIVE' · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `InstitutionId IS NOT NULL OR IsBaseline = 1` · `Version >= 1` · `OwnerThresholdPct IS NULL OR (OwnerThresholdPct > 0 AND OwnerThresholdPct <= 100)`

### `pty.KycProfileItem` — بند اكتمال (FR-PTY-023، FR-PTY-024، G-14)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **KycProfileItemId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ProfileId | BIGINT | لا |  | pty.KycProfile |  |
| ItemKind | VARCHAR(17) | لا |  |  | آخر قيمتين إضافة لنماذج الشركات (05 G-14): حقل شركة/ملف مالي/إفصاح، ومجموعة أطراف (ملاك/مجلس/مفوّضون/مستفيدون) enum: PARTY_FIELD, IDENTITY_DOC, DOCUMENT_TYPE, ADDRESS_TYPE, CONTACT_KIND, CUSTOM_FIELD, COMPANY_FIELD, RELATED_PARTY_SET |
| RefCode | VARCHAR(60) | لا |  |  | رمز الحقل أو نوع الوثيقة أو نوع العنوان... |
| ConditionJson | NVARCHAR(MAX) | نعم |  |  |  |
| IsMandatory | BIT | لا | 1 |  |  |
| MinValidityDays | INT | نعم |  |  | أدنى مدة صلاحية متبقية (BR-PTY-012) |
| MaxAgeDays | INT | نعم |  |  | أقصى عمر للمستند منذ إصداره (مستخرج <= 30 يومًا، شهادة <= 365) (05 G-2، G-14) |
| RequiresImage | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| HelpTextAr | NVARCHAR(500) | نعم |  |  |  |
| HelpTextEn | NVARCHAR(500) | نعم |  |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(KycProfileItemId) · UQ(TenantId, ProfileId, ItemKind, RefCode) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `MinValidityDays IS NULL OR MinValidityDays >= 0` · `MaxAgeDays IS NULL OR MaxAgeDays > 0`

### `pty.KycProfileItemLegalForm` — شروط ظهور البند بحسب الشكل القانوني؛ غياب الصفوف = ينطبق على الكل (G-15)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| KycProfileItemId | BIGINT | لا |  | pty.KycProfileItem |  |
| LegalEntityTypeId | INT | لا |  | cat.LegalEntityType |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, KycProfileItemId, LegalEntityTypeId)

### `pty.PartyCompliance` — إقرارات امتثال بتاريخ لكل شخص بصفته: PEP، عقوبات، تحقيقات، حصانة (G-9)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PartyComplianceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| Capacity | VARCHAR(16) | لا |  |  | enum: OWNER, BENEFICIAL_OWNER, BOARD_MEMBER, EXECUTIVE, SIGNATORY, OTHER |
| CompanyId | BIGINT | نعم |  | org.Company | الشركة التي صدر الإقرار في سياق ملفها |
| DeclaredOn | DATE | لا |  |  |  |
| IsCurrent | BIT | لا | 1 |  | آخر إقرار لكل (شخص، صفة، شركة) |
| IsPep | BIT | لا | 0 |  | شخصية سياسية 🔒 restricted |
| IsRelatedToPep | BIT | لا | 0 |  | علاقة بشخصية سياسية 🔒 restricted |
| IsSanctioned | BIT | لا | 0 |  | 🔒 restricted |
| IsUnderInvestigation | BIT | لا | 0 |  | 🔒 restricted |
| HasImmunity | BIT | لا | 0 |  | 🔒 restricted |
| Details | NVARCHAR(MAX) | نعم |  |  | 🔒 restricted |
| SourceDocumentId | BIGINT | نعم |  | doc.Document | نموذج الإقرار الممسوح |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PartyComplianceId) · UQ(TenantId, PartyId, Capacity, CompanyId, DeclaredOn) · UQ(TenantId, PartyId, Capacity, CompanyId) WHERE IsCurrent = 1

### `pty.TaxIdentity` — الهوية الضريبية والإقرار الضريبي FATCA/CRS (G-13)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TaxIdentityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| CountryId | INT | لا |  | ref.Country | بلد الإقامة الضريبية |
| TaxNumber | VARCHAR(40) | نعم |  |  | الرقم الضريبي (Company.TaxNumber للمرآة يُزامَن منه) 🔒 confidential |
| VatNumber | VARCHAR(40) | نعم |  |  | رقم ضريبة القيمة المضافة 🔒 confidential |
| FatcaClassificationId | INT | نعم |  | cat.LookupItem | قائمة FATCA_CLASSIFICATION |
| CrsClassificationId | INT | نعم |  | cat.LookupItem | قائمة CRS_CLASSIFICATION |
| DeclarationDate | DATE | لا |  |  |  |
| IsCurrent | BIT | لا | 1 |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TaxIdentityId) · UQ(TenantId, PartyId, CountryId, DeclarationDate) · UQ(TenantId, PartyId, CountryId) WHERE IsCurrent = 1

**قيود:** `TaxNumber IS NOT NULL OR VatNumber IS NOT NULL OR FatcaClassificationId IS NOT NULL OR CrsClassificationId IS NOT NULL`

## REF

### `ref.Country` — الدولة: مرجع عالمي للقراءة فقط يديره مشغّل المنصة (FR-CAT-026، BR-CAT-018، BR-CAT-015)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CountryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Iso2 | CHAR(2) | لا |  |  | ISO 3166-1 alpha-2 |
| Iso3 | CHAR(3) | لا |  |  | ISO 3166-1 alpha-3 |
| NameAr | NVARCHAR(100) | لا |  |  |  |
| NameEn | NVARCHAR(100) | لا |  |  |  |
| IsGcc | BIT | لا | 0 |  | عضو مجلس التعاون: الدول الست فقط في البذرة (قيمة مقترحة تُراجَع) |
| WeekendDays | VARCHAR(20) | نعم |  |  | رموز أيام العطلة الأسبوعية MON..SUN مفصولة بفاصلة (مثل FRI,SAT)؛ فارغ = غير محدد |
| DialCode | VARCHAR(8) | نعم |  |  | رمز الاتصال الدولي مثل +966 |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CountryId) · UQ(Iso2) · UQ(Iso3)

**قيود:** `Iso2 NOT LIKE '%[^A-Z]%' AND Iso3 NOT LIKE '%[^A-Z]%'` · `DialCode IS NULL OR (DialCode LIKE '+[0-9]%' AND DialCode NOT LIKE '+%[^0-9]%' AND DialCode NOT LIKE '+_____%')` · `WeekendDays IS NULL OR WeekendDays NOT LIKE '%[^A-Z,]%'`

### `ref.Currency` — العملة: مرجع عالمي ISO 4217 للقراءة فقط (FR-CAT-021، Q-CAT-08)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CurrencyId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | CHAR(3) | لا |  |  | ISO alpha-3 |
| NumericCode | CHAR(3) | لا |  |  | ISO numeric |
| NameAr | NVARCHAR(100) | لا |  |  |  |
| NameEn | NVARCHAR(100) | لا |  |  |  |
| Decimals | TINYINT | لا |  |  | عدد الخانات العشرية 0..3 |
| Symbol | NVARCHAR(10) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CurrencyId) · UQ(Code) · UQ(NumericCode)

**قيود:** `Decimals BETWEEN 0 AND 3` · `Code NOT LIKE '%[^A-Z]%'` · `NumericCode NOT LIKE '%[^0-9]%'`

## CAT

### `cat.TenantCurrency` — العملات المفعّلة للمشترك: تفعيل مجموعة جزئية من المرجع العالمي (FR-CAT-023، Q-CAT-08) -- جدول بنيوي جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| CurrencyId | INT | لا |  | ref.Currency |  |
| IsEnabled | BIT | لا | 1 |  | غير المفعّلة لا تظهر في الاختيار وتبقى ظاهرة في السجلات |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, CurrencyId)

### `cat.InstitutionType` — نوع المنشأة المالية: بنك، شركة تمويل، استثمارية، مالية، فرد (FR-INS-001)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InstitutionTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| RequiresParty | BIT | لا | 0 |  | نوع «فرد» يشترط Party (BR-INS-003) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(InstitutionTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.AccountType` — نوع الحساب (FR-ACC-001)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AccountTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| IsVirtual | BIT | لا | 0 |  | علم الحساب الافتراضي: على VIRTUAL وحده (BR-ACC-004) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AccountTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LegalEntityType` — الشكل القانوني: الكيان وسماته يعرّفها 10 (FR-ORG-002، BR-CAT-017) وتبذره هذه الوحدة؛ أعمدة الكتالوج مكتوبة يدويًا لأن فرادة الرمز بالدولة (10 §6.2) لا فرادته وحده

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LegalEntityTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| AbbreviationAr | NVARCHAR(30) | نعم |  |  |  |
| AbbreviationEn | NVARCHAR(30) | نعم |  |  |  |
| CountryId | INT | نعم |  | ref.Country | فارغ = شكل عام لكل الدول |
| DefaultBodyTypes | NVARCHAR(MAX) | نعم |  |  | هيئات الحوكمة الافتراضية للشكل (قيم GoverningBody.BodyType) |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LegalEntityTypeId) · UQ(TenantId, Code, CountryId) · UQ(TenantId, SeedKey, CountryId) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.DocumentType` — نوع الوثيقة؛ يطبّق 10 أعلامه عند الرفع (FR-CAT-018، BR-CAT-016، FR-PLT-028)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DocumentTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| AppliesTo | VARCHAR(72) | لا |  |  | الكيانات المسموح بربط النوع بها |
| RequiresExpiry | BIT | لا | 0 |  | وثيقة بلا تاريخ انتهاء تُرفض (تطبّقه 10) |
| IsSensitive | BIT | لا | 0 |  | قيد TM/FO للعرض والتنزيل (صور الهوية، نموذج التوقيع، KYC) |
| AllowedMime | NVARCHAR(MAX) | نعم |  |  | مصفوفة أنواع MIME المسموحة؛ فارغ = الافتراضي في BR-PLT-011 |
| MaxSizeMb | INT | نعم |  |  | فارغ = الافتراضي (25) |
| RetentionYears | INT | نعم |  |  | مدد الاحتفاظ فارغة حتى يقرّرها مختص (Q-CAT-06) |
| MaxAgeDays | INT | نعم |  |  | أقصى عمر للمستند منذ إصداره: مستخرج <= 30 يومًا، شهادة <= 365 (05 G-2) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DocumentTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)` · `MaxSizeMb IS NULL OR MaxSizeMb > 0` · `RetentionYears IS NULL OR RetentionYears > 0` · `MaxAgeDays IS NULL OR MaxAgeDays > 0`

### `cat.Position` — المنصب: السمات يعرّفها 10 §6.2 وحده وتبذر هذه الوحدة صفوفه (FR-CAT-019، BR-CAT-017)؛ SortOrder من أساس الكتالوج

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PositionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| ApplicableBodyTypes | NVARCHAR(MAX) | نعم |  |  | قيم GoverningBody.BodyType التي يصح فيها المنصب |
| IsSingleHolder | BIT | لا | 0 |  | منصب أحادي الشاغل (CHAIRMAN) -- BR-ORG-010 |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PositionId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.PowerType` — نوع الصلاحية: السمات يعرّفها 10 §6.2 وحده وتبذر هذه الوحدة صفوفه (FR-CAT-019، FR-ORG-024)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PowerTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Category | VARCHAR(14) | نعم |  |  | enum: CONTRACTS, ACCOUNTS, BORROWING, GUARANTEES, TRADE, REPRESENTATION, ASSETS, OTHER |
| AllowsCeiling | BIT | لا | 0 |  | يسمح بسقف مبلغ في AuthorityGrant |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PowerTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.OperationType` — نوع العملية البنكية المفوَّض بها (FR-ACC-013، BR-CAT-014)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **OperationTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| SupportsCeiling | BIT | لا | 0 |  | يحدّد ظهور السقوف في SignatoryAuthority |
| OperationGroup | VARCHAR(14) | لا |  |  | enum: MONEY, CREDIT, REPRESENTATION, CHANNEL |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(OperationTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.OperationTypePowerType` — ربط عملية بنوع/أنواع صلاحية حوكمة؛ «أي واحد يكفي» (BR-CAT-014، FR-CAT-019، Q-ACC-05) -- جدول وسيط جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| OperationTypeId | INT | لا |  | cat.OperationType |  |
| PowerTypeId | INT | لا |  | cat.PowerType |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, OperationTypeId, PowerTypeId)

### `cat.ProductCategory` — تصنيف المنتجات: مسطّح (FR-CAT-007)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductCategoryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductCategoryId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.Product` — المنتج البنكي بأعلامه (FR-CAT-007، BR-CAT-004)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| ProductCategoryId | INT | لا |  | cat.ProductCategory |  |
| ProductFamily | VARCHAR(15) | لا |  |  | enum: LC, GUARANTEE, FINANCING, COLLECTION, FX, PAYMENT, CARD, ACCOUNT_SERVICE, OTHER |
| ConsumesCreditLimit | BIT | لا |  |  | يدخل فحص التسهيلات؛ تغييره بعد الاستخدام يتطلب تأكيد TM (BR-CAT-004، FR-CAT-022) |
| IsTradeFinance | BIT | لا | 0 |  |  |
| Compliance | VARCHAR(12) | لا |  |  | enum: CONVENTIONAL, ISLAMIC, NEUTRAL |
| VariantGroupCode | VARCHAR(40) | نعم |  |  | يزاوج النسختين التقليدية والإسلامية (منتج واحد لكل امتثال) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductId) · UQ(TenantId, VariantGroupCode, Compliance) WHERE VariantGroupCode IS NOT NULL · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.FeeType` — نوع المصروف: فئة عريضة لا بند تعرفة (FR-CAT-008، BR-CAT-005، Q-CAT-10)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FeeTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Nature | VARCHAR(18) | لا | FEE |  | العقوبة غير إيرادية في التقارير؛ تغييرها بعد الاستخدام بتأكيد TM enum: FEE, PENALTY_NON_INCOME |
| CalcHint | VARCHAR(11) | نعم |  |  | enum: PERCENT, FIXED, PER_MILLION, TIERED |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FeeTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.FinancingType` — نوع التمويل (FR-CAT-009، BR-CAT-006)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FinancingTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| IsIslamic | BIT | لا | 0 |  |  |
| ReturnLabel | VARCHAR(10) | نعم |  |  | تسمية العائد في الواجهة فقط (ربح/فائدة)؛ لا تغيّر الحساب enum: PROFIT, INTEREST |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FinancingTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.ProductFeeType` — المصاريف المسموحة للمنتج؛ تعطيل الربط = حذفه ولا يمس قواعد تسعير قائمة (FR-CAT-010، BR-CAT-007) -- يبقى بمفتاح بديل لأنه يحمل سمة

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductFeeTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ProductId | INT | لا |  | cat.Product |  |
| FeeTypeId | INT | لا |  | cat.FeeType |  |
| IsExpected | BIT | لا | 0 |  | تقرير نقص تسعير لا منع (FR-PRC-016) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductFeeTypeId) · UQ(TenantId, ProductId, FeeTypeId)

### `cat.ProductFinancingType` — أنواع التمويل المسموحة للمنتج (FR-CAT-010، BR-CAT-007)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductFinancingTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ProductId | INT | لا |  | cat.Product |  |
| FinancingTypeId | INT | لا |  | cat.FinancingType |  |
| IsDefault | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductFinancingTypeId) · UQ(TenantId, ProductId, FinancingTypeId) · UQ(TenantId, ProductId) WHERE IsDefault = 1

### `cat.FacilityType` — نوع التسهيل (FR-CAT-011)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Compliance | VARCHAR(12) | لا |  |  | قيم الامتثال كما في Product (المواصفة لا تعددها) enum: CONVENTIONAL, ISLAMIC, NEUTRAL |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LimitType` — نوع الحد: رئيسي/جزئي (FR-CAT-012، BR-CAT-008)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Kind | VARCHAR(10) | لا |  |  | enum: MAIN, SUB |
| ParentLimitTypeId | INT | نعم |  | cat.LimitType | إلزامي للجزئي وممنوع للرئيسي؛ أن يكون الأب رئيسيًا في التطبيق |
| DefaultDistributionMode | VARCHAR(13) | نعم |  |  | enum: SHARED_CAP, PARTITION, OUTSIDE_TOTAL |
| DefaultIsRevolving | BIT | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(Kind = 'MAIN' AND ParentLimitTypeId IS NULL) OR (Kind = 'SUB' AND ParentLimitTypeId IS NOT NULL)` · `ParentLimitTypeId IS NULL OR ParentLimitTypeId <> LimitTypeId` · `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LimitTypeProduct` — المنتجات المسموحة لنوع الحد؛ غياب الصفوف = أي منتج بعلامة ظاهرة (BR-CAT-008) -- جدول وسيط جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| LimitTypeId | INT | لا |  | cat.LimitType |  |
| ProductId | INT | لا |  | cat.Product |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, LimitTypeId, ProductId)

### `cat.CollateralType` — نوع الضمان بنوع بنية وقالب سمات (FR-CAT-013)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| StructureKind | VARCHAR(20) | لا |  |  | enum: GUARANTEE, PROMISSORY_NOTE, INSURANCE_ASSIGNMENT, CASH_MARGIN, REAL_ESTATE, SET_OFF, NEGATIVE_PLEDGE, GENERIC |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CollateralTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.CollateralTypeAttribute` — سمة في قالب نوع الضمان؛ لا تُحذف بل تُرمَّز Retired (BR-CAT-009) -- جدول جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralTypeAttributeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| CollateralTypeId | INT | لا |  | cat.CollateralType |  |
| AttrKey | VARCHAR(60) | لا |  |  |  |
| LabelAr | NVARCHAR(200) | لا |  |  |  |
| LabelEn | NVARCHAR(200) | لا |  |  |  |
| DataType | VARCHAR(10) | لا |  |  | enum: TEXT, NUMBER, DATE, AMOUNT, BOOLEAN, LIST, REFERENCE |
| IsRequired | BIT | لا | 0 |  |  |
| ListOptions | NVARCHAR(MAX) | نعم |  |  | خيارات النوع LIST |
| SortOrder | INT | لا | 0 |  |  |
| IsRetired | BIT | لا | 0 |  | تغيير القالب لا يمس القيم المخزَّنة؛ السمة المرمّزة تبقى مقروءة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CollateralTypeAttributeId) · UQ(TenantId, CollateralTypeId, AttrKey)

**قيود:** `DataType <> 'LIST' OR ListOptions IS NOT NULL`

### `cat.ObligationType` — نوع الالتزام بأربع عائلات (FR-CAT-014، BR-CAT-010)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ObligationTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Family | VARCHAR(23) | لا |  |  | enum: REPORTING, COVENANT, TRANSACTION_RESTRICTION, STATIC_CLAUSE |
| MeasureKind | VARCHAR(18) | نعم |  |  | NONE = تعهد وصفي enum: RATIO, AMOUNT, PERCENT_OF_REVENUE, AVERAGE_BALANCE, FLOW_VOLUME, NONE |
| IsQualitative | BIT | لا | 0 |  |  |
| DefaultDeadlineBasis | VARCHAR(21) | نعم |  |  | مطابقة لـ AnchorKind في 12 وتحملها التقارير enum: AFTER_PERIOD_END, AFTER_FISCAL_YEAR_END, BEFORE_EVENT, AFTER_EVENT, ON_DEMAND_REQUEST, FIXED_DATE |
| DefaultUnit | NVARCHAR(30) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ObligationTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Family <> 'COVENANT' OR MeasureKind IS NOT NULL` · `MeasureKind IS NULL OR MeasureKind <> 'NONE' OR IsQualitative = 1` · `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.BaseRate` — سعر الأساس: سوق (InstitutionId فارغ) أو داخلي لبنك (FR-CAT-015، BR-CAT-011)؛ الأسماء البديلة في BaseRateAlias

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BaseRateId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Kind | VARCHAR(13) | لا |  |  | enum: MARKET, BANK_INTERNAL |
| InstitutionId | BIGINT | نعم |  | ins.Institution | فارغ للسوق وإلزامي للداخلي |
| FamilyCode | VARCHAR(40) | لا |  |  | رمز العائلة مثل SAIBOR |
| Tenor | VARCHAR(10) | لا |  |  | enum: ON, 1M, 3M, 6M, 12M |
| CurrencyId | INT | نعم |  | ref.Currency |  |
| StaleAfterDays | INT | نعم |  |  | تنبيه التقادم NTF-CAT-01 (الافتراضي 35 مقترح) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BaseRateId) · UQ(TenantId, FamilyCode, Tenor, InstitutionId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(Kind = 'MARKET' AND InstitutionId IS NULL) OR (Kind = 'BANK_INTERNAL' AND InstitutionId IS NOT NULL)` · `StaleAfterDays IS NULL OR StaleAfterDays > 0` · `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.BaseRateAlias` — اسم بديل لسعر أساس (SIBOR ≡ SAIBOR) بحث بلا حساسية حالة وفريد ضمن النطاق (BR-CAT-011، FR-CAT-015) -- جدول وسيط جديد يحل «Aliases set»

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BaseRateAliasId** | INT IDENTITY | لا | | | مفتاح أساسي |
| BaseRateId | INT | لا |  | cat.BaseRate (via Tenor) | الربط المركّب يضمن أن الفترة المنسوخة تطابق الأب |
| Tenor | VARCHAR(10) | لا |  |  | نسخة من BaseRate.Tenor: حل الاسم يكون بـ (اسم بديل + فترة) في SVC-05 enum: ON, 1M, 3M, 6M, 12M |
| InstitutionId | BIGINT | نعم |  | ins.Institution | نسخة من BaseRate.InstitutionId (فارغ = سوق) تحفظها الخدمة؛ نطاق الفرادة |
| Alias | NVARCHAR(60) | لا |  |  |  |
| AliasKey | NVARCHAR(60) | نعم |  |  | مفتاح البحث والفرادة بلا حساسية حالة محسوب: `UPPER(Alias)` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BaseRateAliasId) · UQ(TenantId, InstitutionId, Tenor, AliasKey)

### `cat.BaseRateValue` — قيمة سعر الأساس بتاريخ سريان؛ لا حذف: التصحيح صف جديد والقديم SUPERSEDED (FR-CAT-016، BR-CAT-012/013)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BaseRateValueId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| BaseRateId | INT | لا |  | cat.BaseRate |  |
| EffectiveDate | DATE | لا |  |  |  |
| ValuePct | DECIMAL(9,6) | لا |  |  | نقاط مئوية؛ تُقبل الصفرية والسالبة (أرضية الصفر في التسعير 12)؛ الداخلية معلومة تجارية 🔒 confidential |
| Source | VARCHAR(10) | لا | MANUAL |  | FEED محجوز لمحوّل لاحق enum: MANUAL, FEED |
| SourceNote | NVARCHAR(300) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | VALID |  | enum: VALID, SUPERSEDED |
| SupersedesId | BIGINT | نعم |  | cat.BaseRateValue (via BaseRateId) | القيمة المصحَّحة من السعر نفسه |
| EnteredBy | BIGINT | لا |  | sec.AppUser |  |
| EnteredOn | DATETIME2(3) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BaseRateValueId) · UQ(TenantId, BaseRateId, EffectiveDate) WHERE Status = 'VALID'

**قيود:** `SupersedesId IS NULL OR SupersedesId <> BaseRateValueId`

### `cat.LookupList` — قائمة قيم؛ TenantId فارغ = قائمة عالمية يملكها المشغّل للقراءة (FR-CAT-020، BR-CAT-015)

*مختلط النطاق · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **LookupListId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Scope | VARCHAR(10) | لا |  |  | enum: GLOBAL, TENANT |
| AllowTenantItems | BIT | لا | 0 |  | هل يضيف المشترك بنودًا لقائمة عالمية؟ |
| AttributeSchema | NVARCHAR(MAX) | نعم |  |  | مخطط سمات البنود (JSON Schema مبسّط) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LookupListId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(Scope = 'GLOBAL' AND TenantId IS NULL) OR (Scope = 'TENANT' AND TenantId IS NOT NULL)` · `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LookupItem` — بند في قائمة قيم؛ TenantId فارغ = بند عالمي للقراءة فقط؛ أعمدة الكتالوج يدوية لأن فرادة الرمز داخل القائمة لا المشترك (FR-CAT-020)

*مختلط النطاق*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **LookupItemId** | INT IDENTITY | لا | | | مفتاح أساسي |
| LookupListId | INT | لا |  | cat.LookupList |  |
| Code | VARCHAR(80) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | ACTIVE |  | LEGACY يضعه مشغّل المنصة فقط ولا يُختار في جديد enum: ACTIVE, LEGACY |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Attributes | NVARCHAR(MAX) | نعم |  |  | قيم السمات مطابقة لمخطط القائمة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LookupItemId) · UQ(TenantId, LookupListId, Code) · UQ(TenantId, LookupListId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

## INS

### `ins.Institution` — المنشأة المالية (FR-INS-001..004، BR-INS-001..003، BR-INS-012)؛ Locality محلي/أجنبي مشتقة (BR-INS-002) فلا تُخزَّن

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InstitutionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  | رمز مطبَّع أحرف كبيرة بلا مسافات فريد في المشترك (BR-INS-001) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| InstitutionTypeId | INT | لا |  | cat.InstitutionType |  |
| CountryId | INT | لا |  | ref.Country | دولة المنشأة؛ المحلي/الأجنبي يُشتق بمقارنتها بدولة المشترك (FR-INS-003) |
| SwiftBic | VARCHAR(11) | نعم |  |  | 8 أو 11 خانة (BR-INS-001) |
| Website | NVARCHAR(300) | نعم |  |  |  |
| PartyId | BIGINT | نعم |  | pty.Party | للفرد الممول فقط؛ مزوّد استخدام Party (FR-INS-004، FR-INS-021، BR-INS-003) |
| Status | VARCHAR(10) | لا |  |  | DRAFT من المعالج؛ INACTIVE يتطلب إغلاق كل العلاقات (BR-INS-012) enum: DRAFT, ACTIVE, INACTIVE |
| DirectoryRef | VARCHAR(80) | نعم |  |  | محجوز لدليل منشآت مشترك لاحقًا (FR-INS-020) |
| Notes | NVARCHAR(2000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(InstitutionId) · UQ(PublicId) · UQ(TenantId, Code) · UQ(TenantId, PartyId) WHERE PartyId IS NOT NULL

**قيود:** `Code NOT LIKE '% %'` · `SwiftBic IS NULL OR SwiftBic LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z0-9][A-Z0-9]' OR SwiftBic LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]'`

### `ins.InstitutionUnit` — وحدة في هيكل المنشأة: إدارة/قسم/فرع، شجرة ذاتية حتى 4 مستويات (FR-INS-005/006، BR-INS-004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InstitutionUnitId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| ParentUnitId | BIGINT | نعم |  | ins.InstitutionUnit (via InstitutionId) | الأب من المنشأة نفسها (BR-INS-004)؛ العمق والحلقات وتسلسل الأنواع في التطبيق |
| UnitTypeId | INT | لا |  | cat.LookupItem | قائمة UNIT_TYPE (DEPARTMENT/SECTION/BRANCH) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  | الهاتف والبريد والموقع والعنوان عبر pty.ContactMethod/Address (OwnerType=UNIT) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(InstitutionUnitId) · UQ(TenantId, InstitutionId, ParentUnitId, NameAr)

**قيود:** `ParentUnitId IS NULL OR ParentUnitId <> InstitutionUnitId`

### `ins.Contact` — جهة اتصال لدى البنك: سجل خفيف بلا هوية، PartyId اختياري للترقية (FR-INS-007/008، BR-INS-005/006/014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ContactId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| UnitId | BIGINT | نعم |  | ins.InstitutionUnit (via InstitutionId) | وحدة من المنشأة نفسها |
| FullNameAr | NVARCHAR(200) | لا |  |  |  |
| FullNameEn | NVARCHAR(200) | نعم |  |  |  |
| JobTitleAr | NVARCHAR(200) | نعم |  |  |  |
| JobTitleEn | NVARCHAR(200) | نعم |  |  |  |
| ReportsToContactId | BIGINT | نعم |  | ins.Contact (via InstitutionId) | «يتبع لـ» من المنشأة نفسها؛ منع الذات والحلقة (BR-INS-005) |
| PartyId | BIGINT | نعم |  | pty.Party | فارغ افتراضيًا؛ عند الربط الهوية عبر Party ولا تُنسخ إلى Contact (BR-INS-014) |
| Status | VARCHAR(10) | لا | ACTIVE |  | enum: ACTIVE, INACTIVE |
| InactiveReason | VARCHAR(11) | نعم |  |  | enum: LEFT_BANK, TRANSFERRED, OTHER |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ContactId) · UQ(PublicId) · UQ(TenantId, InstitutionId, PartyId) WHERE PartyId IS NOT NULL

**قيود:** `ReportsToContactId IS NULL OR ReportsToContactId <> ContactId` · `Status <> 'INACTIVE' OR InactiveReason IS NOT NULL`

### `ins.Relationship` — علاقة شركة–منشأة (D-4)؛ فريدة مهما كانت حالتها (FR-INS-009، BR-INS-007/011)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RelationshipId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| CustomerNoAtBank | VARCHAR(40) | نعم |  |  | رقم العميل لدى البنك؛ تكراره داخل المنشأة تنبيه لا منع (BR-INS-007) |
| Status | VARCHAR(10) | لا |  |  | enum: PROSPECT, ACTIVE, SUSPENDED, CLOSED |
| StartedOn | DATE | نعم |  |  |  |
| ClosedOn | DATE | نعم |  |  |  |
| ClosureReason | NVARCHAR(300) | نعم |  |  |  |
| Notes | NVARCHAR(2000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RelationshipId) · UQ(PublicId) · UQ(TenantId, CompanyId, InstitutionId)

**قيود:** `Status <> 'CLOSED' OR (ClosedOn IS NOT NULL AND ClosureReason IS NOT NULL)` · `ClosedOn IS NULL OR StartedOn IS NULL OR ClosedOn >= StartedOn`

### `ins.RelationshipContact` — تغطية العلاقة (الطبقة الأولى): جهة اتصال بدور ورتبة وفترة (FR-INS-010، BR-INS-008/009)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RelationshipContactId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | لا |  | ins.Institution | مكرَّر من العلاقة لضمان أن الجهة من منشأة العلاقة نفسها (via) |
| RelationshipId | BIGINT | لا |  | ins.Relationship (via InstitutionId) |  |
| ContactId | BIGINT | لا |  | ins.Contact (via InstitutionId) | جهة من منشأة أخرى مرفوضة (BR-INS-008) |
| RoleId | INT | لا |  | cat.LookupItem | قائمة CONTACT_ROLE (RM/TEAM_LEAD/REGIONAL_MGR/DEPT_HEAD...) |
| Rank | INT | لا |  |  | أولوية؛ الافتراضي من الدور 1..4 (BR-INS-008) |
| IsPrimary | BIT | لا | 0 |  |  |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  | الاستبدال يغلق الصف بيوم قبل السريان الجديد (F-INS-2) |
| Notes | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RelationshipContactId) · UQ(TenantId, RelationshipId, ContactId, RoleId, ValidFrom) · UQ(TenantId, RelationshipId, Rank) WHERE ValidTo IS NULL · UQ(TenantId, RelationshipId, ContactId, RoleId) WHERE ValidTo IS NULL · UQ(TenantId, RelationshipId, RoleId) WHERE IsPrimary = 1 AND ValidTo IS NULL

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `Rank >= 1`

### `ins.RelationshipProduct` — منتج يُتعامل به ضمن علاقة مع جهة افتراضية وقناة (FR-INS-011..013، BR-INS-010)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RelationshipProductId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | لا |  | ins.Institution | مكرَّر من العلاقة لضمان أن الجهة الافتراضية من منشأة العلاقة (via) |
| RelationshipId | BIGINT | لا |  | ins.Relationship (via InstitutionId) |  |
| ProductId | INT | لا |  | cat.Product | المنتج نشط (التطبيق) |
| DefaultContactId | BIGINT | نعم |  | ins.Contact (via InstitutionId) | جهة من منشأة العلاقة (FR-INS-012)؛ الحل الفعلي BR-INS-009 |
| PreferredChannel | VARCHAR(18) | لا | MANUAL_FORM |  | DIRECT_INTEGRATION محجوز ويُرفض في التطبيق ما لم يُفعَّل محوّل (BR-INS-010) enum: BANK_PORTAL, MANUAL_FORM, DIRECT_INTEGRATION |
| ChannelNotes | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| SinceDate | DATE | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RelationshipProductId) · UQ(TenantId, RelationshipId, ProductId)

## ACC

### `acc.BankAccount` — حساب شركة لدى منشأة (FR-ACC-001..009، BR-ACC-001..006، BR-ACC-016)؛ الرقم وIBAN مشفّران بفهرس أعمى للفرادة

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BankAccountId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| RelationshipId | BIGINT | لا |  | ins.Relationship (via CompanyId,InstitutionId) | مشتقة من (CompanyId,InstitutionId) وتُخزَّن مفتاحًا؛ الربط المركّب يضمن تطابقها (BR-ACC-003) |
| AccountTypeId | INT | لا |  | cat.AccountType |  |
| MasterAccountId | BIGINT | نعم |  | acc.BankAccount (via CompanyId,InstitutionId,CurrencyId) | الافتراضي تحت رئيسي من الشركة والمنشأة والعملة نفسها (FR-ACC-006، BR-ACC-004) |
| CurrencyId | INT | لا |  | ref.Currency |  |
| Nickname | NVARCHAR(100) | نعم |  |  |  |
| AccountNoEnc | VARBINARY(512) | لا |  |  | الرقم مشفّر بمفتاح المشترك (BR-ACC-001، 12) 🔒 restricted |
| AccountNoMask | NVARCHAR(32) | لا |  |  | قناع العرض يُحسب عند الكتابة (BR-ACC-016) 🔒 restricted |
| AccountNoHash | VARBINARY(32) | لا |  |  | HMAC على الرقم المطبَّع (إزالة المسافات والشرطات + أحرف كبيرة) 🔒 restricted |
| AccountNoLast4 | VARCHAR(4) | لا |  |  | آخر 4 خانات للبحث 🔒 confidential |
| IbanEnc | VARBINARY(512) | نعم |  |  | اختياري؛ الطول وmod 97 في التطبيق (BR-ACC-002) 🔒 restricted |
| IbanMask | NVARCHAR(32) | نعم |  |  | مثل SA•• •••• •••• •••• •••• 7519 🔒 restricted |
| IbanHash | VARBINARY(32) | نعم |  |  | فرادة IBAN لكل مشترك 🔒 restricted |
| BranchUnitId | BIGINT | نعم |  | ins.InstitutionUnit (via InstitutionId) | فرع من المنشأة نفسها |
| SigningRuleText | NVARCHAR(500) | نعم |  |  | نص حر «أ مع ب» دون محرك آلي (FR-ACC-007) |
| MinSignatures | INT | لا | 1 |  | >= 1؛ تحذير إن زاد على المفوّضين المؤهلين (BR-ACC-005) |
| Status | VARCHAR(10) | لا | ACTIVE |  | CLOSED نهائي والحساب المغلق يحجز رقمه (BR-ACC-001/006) enum: ACTIVE, DORMANT, FROZEN, CLOSED |
| OpenedOn | DATE | نعم |  |  |  |
| ClosedOn | DATE | نعم |  |  |  |
| ClosureReason | NVARCHAR(300) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BankAccountId) · UQ(PublicId) · UQ(TenantId, InstitutionId, AccountNoHash) · UQ(TenantId, IbanHash) WHERE IbanHash IS NOT NULL

**قيود:** `MinSignatures >= 1` · `MasterAccountId IS NULL OR MasterAccountId <> BankAccountId` · `(IbanEnc IS NULL AND IbanMask IS NULL AND IbanHash IS NULL) OR (IbanEnc IS NOT NULL AND IbanMask IS NOT NULL AND IbanHash IS NOT NULL)` · `ClosedOn IS NULL OR OpenedOn IS NULL OR ClosedOn >= OpenedOn` · `Status <> 'CLOSED' OR (ClosedOn IS NOT NULL AND ClosureReason IS NOT NULL)` · `(ClosedOn IS NULL AND ClosureReason IS NULL) OR Status = 'CLOSED'`

### `acc.FacilityAccount` — ربط حساب بتسهيل بغرض (S2) (FR-ACC-010، BR-ACC-007)؛ يُملأ من شاشة التسهيل

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityAccountId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| BankAccountId | BIGINT | لا |  | acc.BankAccount (via CurrencyId) | الربط المركّب يضمن تطابق عملة الحساب مع CurrencyId |
| CurrencyId | INT | لا |  | ref.Currency | نسخة من عملة الحساب لإنفاذ «افتراضي واحد لكل (تسهيل، غرض، عملة)» (BR-ACC-007) |
| PurposeId | INT | لا |  | cat.LookupItem | قائمة ACCOUNT_PURPOSE (FACILITY/MARGIN_SETTLEMENT/BANK_CHARGES/REPAYMENT/LC_PROCEEDS_COLLECTION) |
| IsDefault | BIT | لا | 0 |  |  |
| ValidFrom | DATE | نعم |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| Notes | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityAccountId) · UQ(TenantId, FacilityId, BankAccountId, PurposeId) · UQ(TenantId, FacilityId, PurposeId, CurrencyId) WHERE IsDefault = 1 AND ValidTo IS NULL

**قيود:** `ValidTo IS NULL OR ValidFrom IS NULL OR ValidTo >= ValidFrom`

### `acc.Signatory` — تفويض شخص لدى علاقة (S1-ب) (FR-ACC-012، FR-ACC-023، BR-ACC-008/009) + إضافات docs/05 G-10

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SignatoryId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RelationshipId | BIGINT | لا |  | ins.Relationship |  |
| PartyId | BIGINT | لا |  | pty.Party | شخص طبيعي (التطبيق)؛ مزوّد استخدام Party يعاد توجيهه عند الدمج (FR-ACC-023) |
| SignatureClassId | INT | لا |  | cat.LookupItem | قائمة SIGNATURE_CLASS (A/B/C قابلة للتوسعة) |
| PositionId | INT | نعم |  | cat.Position |  |
| JobTitle | NVARCHAR(200) | نعم |  |  | المسمى الوظيفي لدى المنشأة كما في نماذج KYC (05 §1.2) |
| AuthorisationBasisId | INT | نعم |  | cat.LookupItem | أساس التفويض (05 G-10): قائمة AUTHORISATION_BASIS (وكالة، قرار مجلس، قرار شركاء، نظام أساسي، عقد تأسيس، تفويض معدّ داخل البنك)؛ الوثيقة وتاريخاها في AuthorizationDocumentId |
| SignatureType | VARCHAR(22) | نعم |  |  | نوع التوقيع (05 G-10): فردي أو مع المفوّض الأساسي enum: INDIVIDUAL, WITH_PRIMARY_SIGNATORY |
| CashWithdrawalMode | VARCHAR(11) | لا | UNSPECIFIED |  | حد السحب النقدي في نموذج KYC (05 G-10): بلا حد أو حد أقصى enum: LIMITED, UNLIMITED, UNSPECIFIED |
| CashWithdrawalLimit | DECIMAL(19,4) | نعم |  |  | مع LIMITED فقط؛ تفصيل العمليات في SignatoryAuthority 🔒 confidential |
| CashWithdrawalCurrencyId | INT | نعم |  | ref.Currency |  |
| AuthorizationDocumentId | BIGINT | نعم |  | doc.Document | وثيقة التفويض؛ تفعيل بلا وثيقة مرفوض (BR-ACC-009) |
| SpecimenDocumentId | BIGINT | نعم |  | doc.Document | صورة نموذج التوقيع حساسة بقيد صور الهوية (FR-ACC-022) |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| Status | VARCHAR(10) | لا | PENDING |  | EXPIRED آليًا بعد ValidTo؛ REVOKED نهائي؛ التجديد صف جديد enum: PENDING, ACTIVE, SUSPENDED, EXPIRED, REVOKED |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SignatoryId) · UQ(PublicId) · UQ(TenantId, RelationshipId, PartyId, SignatureClassId, ValidFrom) · UQ(TenantId, RelationshipId, PartyId, SignatureClassId) WHERE ValidTo IS NULL AND Status <> 'REVOKED'

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `Status NOT IN ('ACTIVE','SUSPENDED','EXPIRED') OR AuthorizationDocumentId IS NOT NULL` · `(CashWithdrawalMode = 'LIMITED' AND CashWithdrawalLimit IS NOT NULL AND CashWithdrawalLimit > 0 AND CashWithdrawalCurrencyId IS NOT NULL) OR (CashWithdrawalMode <> 'LIMITED' AND CashWithdrawalLimit IS NULL)`

### `acc.SignatoryAuthority` — صلاحية المفوّض لعملية على حساب أو على البنك (S1-ب) (FR-ACC-013/014/017، BR-ACC-010/011)؛ لا تعديل في مكانه: الإغلاق والفتح؛ حالتها مشتقة فلا تُخزَّن

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SignatoryAuthorityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RelationshipId | BIGINT | لا |  | ins.Relationship | مكرَّر من المفوّض لضمان أن الحساب من العلاقة نفسها (FR-ACC-013) |
| SignatoryId | BIGINT | لا |  | acc.Signatory (via RelationshipId) |  |
| BankAccountId | BIGINT | نعم |  | acc.BankAccount (via RelationshipId) | فارغ = على كل حسابات العلاقة (البنك) (BR-ACC-010) |
| OperationTypeId | INT | لا |  | cat.OperationType |  |
| CeilingMode | VARCHAR(11) | لا |  |  | LIMITED يتطلب مبلغًا وعملة (BR-ACC-011) enum: LIMITED, UNLIMITED, UNSPECIFIED |
| MaxPerTransaction | DECIMAL(19,4) | نعم |  |  | سقف العملية الواحدة 🔒 confidential |
| DailyLimit | DECIMAL(19,4) | نعم |  |  | السقف اليومي؛ يُسجَّل ولا يُتتبَّع استخدامه (Q-ACC-08) 🔒 confidential |
| CurrencyId | INT | نعم |  | ref.Currency | إلزامي مع LIMITED |
| IsJoint | BIT | لا | 0 |  | توقيع مشترك (BR-ACC-013) |
| JointMinCosigners | INT | نعم |  |  | أدنى عدد للمشاركين الآخرين |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SupersededById | BIGINT | نعم |  | acc.SignatoryAuthority (via SignatoryId) | الصف الذي حلّ محله (FR-ACC-017) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SignatoryAuthorityId) · UQ(TenantId, SignatoryId, OperationTypeId, BankAccountId, ValidFrom) · UQ(TenantId, SignatoryId, BankAccountId, OperationTypeId) WHERE ValidTo IS NULL AND SupersededById IS NULL

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `CeilingMode <> 'LIMITED' OR (CurrencyId IS NOT NULL AND ((MaxPerTransaction IS NOT NULL AND MaxPerTransaction > 0) OR (DailyLimit IS NOT NULL AND DailyLimit > 0)))` · `CeilingMode = 'LIMITED' OR (MaxPerTransaction IS NULL AND DailyLimit IS NULL)` · `MaxPerTransaction IS NULL OR MaxPerTransaction > 0` · `DailyLimit IS NULL OR DailyLimit > 0` · `MaxPerTransaction IS NULL OR DailyLimit IS NULL OR DailyLimit >= MaxPerTransaction` · `(IsJoint = 1 AND (JointMinCosigners IS NULL OR JointMinCosigners >= 1)) OR (IsJoint = 0 AND JointMinCosigners IS NULL)` · `SupersededById IS NULL OR SupersededById <> SignatoryAuthorityId`

### `acc.SignatoryAuthorityJointClass` — فئات التوقيع المطلوبة للتوقيع المشترك (JointClassIds) (BR-ACC-013) -- جدول وسيط جديد؛ لا حذف: التعديل بصف صلاحية جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| SignatoryAuthorityId | BIGINT | لا |  | acc.SignatoryAuthority |  |
| SignatureClassId | INT | لا |  | cat.LookupItem | قائمة SIGNATURE_CLASS |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, SignatoryAuthorityId, SignatureClassId)

### `acc.AuthorityConflict` — نتيجة مقارنة صلاحية المفوّض بالحوكمة وقرار المراجع (S1-ب) (FR-ACC-018، BR-ACC-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AuthorityConflictId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| SignatoryAuthorityId | BIGINT | لا |  | acc.SignatoryAuthority |  |
| ConflictCode | VARCHAR(25) | لا |  |  | enum: NO_GRANT, CEILING_EXCEEDS, JOINT_MISMATCH, GRANT_EXPIRED, GRANT_CEILING_UNSPECIFIED, NOT_COMPARABLE_CURRENCY, NOT_MAPPED |
| Fingerprint | VARCHAR(64) | لا |  |  | بصمة نسخة الصلاحية + نسخة المنحة؛ بصمة جديدة تفتح مثيلًا جديدًا (القسم 8) |
| Status | VARCHAR(12) | لا | OPEN |  | RESOLVED آليًا عند زوال السبب enum: OPEN, ACKNOWLEDGED, RESOLVED |
| Reason | NVARCHAR(500) | نعم |  |  | سبب إقرار المراجع (تحذير بإقرار مسجَّل، Q-ACC-06) |
| ReviewedBy | BIGINT | نعم |  | sec.AppUser | TM/FO |
| ReviewedOn | DATETIME2(3) | نعم |  |  |  |
| DetectedOn | DATETIME2(3) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuthorityConflictId) · UQ(TenantId, SignatoryAuthorityId, ConflictCode, Fingerprint)

**قيود:** `Status <> 'ACKNOWLEDGED' OR (ReviewedBy IS NOT NULL AND ReviewedOn IS NOT NULL AND Reason IS NOT NULL)` · `ReviewedBy IS NULL OR ReviewedOn IS NOT NULL`

## FAC

### `fac.Facility` — حزمة الاتفاقية الائتمانية: جذر التجميعة (FR-FAC-001..008، BR-FAC-001/005/006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityNo | VARCHAR(40) | لا |  |  | FAC-YY-NNN من NumberSequence (BR-FAC-001) |
| BankReferenceNo | NVARCHAR(80) | نعم |  |  | مرجع البنك: نص حر بلا صيغة (Q-FAC-01) |
| BankStructureNo | NVARCHAR(80) | نعم |  |  | رقم هيكل البنك: نص حر (Q-FAC-01) |
| BorrowerCompanyId | BIGINT | لا |  | org.Company |  |
| FacilityTypeId | INT | لا |  | cat.FacilityType |  |
| CurrencyId | INT | لا |  | ref.Currency | عملة واحدة لكل التسهيل (BR-FAC-002) |
| TotalAmount | DECIMAL(19,4) | لا |  |  | Cap(Facility) (BR-FAC-009) |
| IsSyndicated | BIT | لا | 0 |  | تمويل مشترك: مقرضان فأكثر (BR-FAC-007) |
| PrecedenceLanguage | VARCHAR(10) | لا |  |  | لغة الأسبقية (FR-FAC-002) enum: AR, EN, EQUAL |
| PrecedenceClauseRef | NVARCHAR(100) | نعم |  |  | مرجع بند الأسبقية |
| AgreementDate | DATE | نعم |  |  |  |
| AgreementDateHijri | NVARCHAR(20) | نعم |  |  | النص الهجري كما في الوثيقة (X-DAT-2) |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveFromHijri | NVARCHAR(20) | نعم |  |  |  |
| ExpiryDate | DATE | لا |  |  | التنبيهات على الميلادي المخزَّن (BR-FAC-001، Q-FAC-10) |
| ExpiryDateHijri | NVARCHAR(20) | نعم |  |  |  |
| OperativeCalendar | VARCHAR(10) | لا | GREGORIAN |  | التقويم المعتمد في الاتفاقية (FR-FAC-002) enum: GREGORIAN, HIJRI |
| HijriAdjusted | BIT | لا | 0 |  | إضافة: علم «معدَّل» للمقابل الميلادي (FR-FAC-002) |
| HijriAdjustReason | NVARCHAR(300) | نعم |  |  | إضافة: سبب التعديل اليدوي (FR-FAC-002) |
| PreviousFacilityId | BIGINT | نعم |  | fac.Facility | سلسلة التجديد الخطية (BR-FAC-006) |
| LifecycleStatus | VARCHAR(10) | لا | DRAFT |  | §8؛ مؤشر السريان مشتق لا يُخزَّن enum: DRAFT, ACTIVE, SUSPENDED, EXPIRED, TERMINATED, SUPERSEDED |
| LifecycleReason | NVARCHAR(500) | نعم |  |  | إضافة: سبب التعليق/الانتهاء/الإنهاء (§8، FR-FAC-008) |
| BankUnilateralRights | VARCHAR(43) | نعم |  |  | حقوق البنك المنفردة (FR-FAC-023) |
| NoticeDays | INT | نعم |  |  | مهلة الإخطار؛ 0 = «بلا» (FR-FAC-023) |
| UsageBlockOnBreach | BIT | لا | 0 |  | إيقاف الاستخدام عند خرق (FR-FAC-029) |
| UsageBlockOnUnconfirmed | BIT | لا | 0 |  | منع الحجز عند NOT_CONFIRMED (Q-FAC-03، BR-FAC-015) |
| AlertLeadDays | VARCHAR(40) | نعم |  |  | أيام ما قبل الانتهاء مفصولة بفواصل؛ الفارغ = افتراضي ExpiryAlertRule (FR-FAC-008) |
| ApprovedRevisionNo | INT | لا | 0 |  | آخر مراجعة معتمدة؛ 0 = لا مراجعة معتمدة بعد (BR-FAC-003) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityId) · UQ(PublicId) · UQ(TenantId, FacilityNo) · UQ(TenantId, PreviousFacilityId) WHERE PreviousFacilityId IS NOT NULL

**قيود:** `ExpiryDate >= EffectiveFrom` · `AgreementDate IS NULL OR AgreementDate <= EffectiveFrom` · `TotalAmount > 0` · `PreviousFacilityId IS NULL OR PreviousFacilityId <> FacilityId` · `NoticeDays IS NULL OR NoticeDays >= 0` · `BankUnilateralRights IS NULL OR BankUnilateralRights NOT LIKE '%CHANGE_PRICING%' OR NoticeDays IS NOT NULL` · `HijriAdjusted = 0 OR HijriAdjustReason IS NOT NULL` · `LifecycleStatus NOT IN ('SUSPENDED','EXPIRED','TERMINATED') OR LifecycleReason IS NOT NULL` · `ApprovedRevisionNo >= 0` · `LifecycleStatus = 'DRAFT' OR ApprovedRevisionNo >= 1` · `AlertLeadDays IS NULL OR AlertLeadDays NOT LIKE '%[^0-9,]%'`

### `fac.FacilityRevision` — مراجعة معدّ/معتمِد لشروط التسهيل (FR-FAC-024، BR-FAC-003/004، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityRevisionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| RevisionNo | INT | لا |  |  | يبدأ من 1 |
| ReasonKind | VARCHAR(12) | لا |  |  | enum: INITIAL, AMENDMENT, EXTENSION, CORRECTION, RENEWAL_COPY |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, SUBMITTED, APPROVED, REJECTED, DISCARDED |
| EffectiveOn | DATE | لا |  |  | المراجعة تحكم متى تُلزِم والسريان بالتاريخ يحكم من أي يوم (BR-FAC-003) |
| ChangeSummary | NVARCHAR(1000) | نعم |  |  |  |
| HeaderChanges | NVARCHAR(MAX) | نعم |  |  | إضافة: تغييرات رأس التسهيل المقترحة تُطبَّق على Facility عند الاعتماد (الرأس غير [R]) |
| SubmittedBy | BIGINT | نعم |  | sec.AppUser |  |
| SubmittedOn | DATETIME2(3) | نعم |  |  |  |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| RejectionReason | NVARCHAR(1000) | نعم |  |  |  |
| IntegrityResult | NVARCHAR(MAX) | نعم |  |  | نتيجة فحوص السلامة V-FAC-* عند التقديم (BR-FAC-004) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityRevisionId) · UQ(TenantId, FacilityId, RevisionNo) · UQ(TenantId, FacilityId) WHERE Status IN ('DRAFT','SUBMITTED','REJECTED')

**قيود:** `RevisionNo >= 1` · `ReasonKind <> 'INITIAL' OR RevisionNo = 1` · `Status NOT IN ('SUBMITTED','APPROVED') OR (SubmittedBy IS NOT NULL AND SubmittedOn IS NOT NULL)` · `Status <> 'APPROVED' OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `Status <> 'REJECTED' OR RejectionReason IS NOT NULL`

### `fac.FacilityDocument` — وثيقة ضمن الحزمة بأسبقية (FR-FAC-004، BR-FAC-008، V-FAC-03)؛ نوعها من doc.Document.DocumentTypeId

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityDocumentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| DocumentDate | DATE | نعم |  |  |  |
| DocumentDateHijri | NVARCHAR(20) | نعم |  |  |  |
| Language | VARCHAR(10) | لا |  |  | enum: AR, EN, BILINGUAL |
| PrecedenceRank | INT | لا |  |  | الأصغر يغلب (BR-FAC-008) |
| AmendsFacilityDocumentId | BIGINT | نعم |  | fac.FacilityDocument (via FacilityId) | «تعدّل وثيقة» داخل الحزمة نفسها |
| PageCount | INT | نعم |  |  |  |
| IsSignedCopy | BIT | لا | 0 |  |  |
| IsScanned | BIT | لا | 0 |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.FacilityDocument |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityDocumentId) · UQ(TenantId, FacilityId, DocumentId) WHERE ToRevision IS NULL · UQ(TenantId, FacilityId, PrecedenceRank) WHERE ToRevision IS NULL

**قيود:** `PrecedenceRank >= 1` · `PageCount IS NULL OR PageCount > 0` · `AmendsFacilityDocumentId IS NULL OR AmendsFacilityDocumentId <> FacilityDocumentId` · `ToRevision IS NULL OR ToRevision >= FromRevision`

### `fac.FacilityLender` — مقرض وحصته (FR-FAC-003، BR-FAC-007، V-FAC-02)؛ مجموع الحصص 100 ووكيل واحد يتحقق منهما التطبيق

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityLenderId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| Roles | VARCHAR(40) | لا |  |  |  |
| SharePct | DECIMAL(9,6) | لا |  |  | 0 < x <= 100؛ CommitmentAmount = TotalAmount x SharePct / 100 مشتق لا يُخزَّن |
| ContactId | BIGINT | نعم |  | ins.Contact (via InstitutionId) | جهة اتصال المشارك من المنشأة نفسها |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.FacilityLender |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityLenderId) · UQ(TenantId, FacilityId, InstitutionId) WHERE ToRevision IS NULL

**قيود:** `SharePct > 0 AND SharePct <= 100` · `Roles <> ''` · `Roles NOT LIKE '%SOLE%' OR SharePct = 100` · `ToRevision IS NULL OR ToRevision >= FromRevision`

### `fac.OutstandingSnapshot` — لقطة الرصيد المعترف به (FR-FAC-009، BR-FAC-017)؛ PctOfLimit مشتق لا يُخزَّن

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **OutstandingSnapshotId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) |  |
| ProductId | INT | نعم |  | cat.Product |  |
| AsOfDate | DATE | لا |  |  |  |
| AcknowledgedAmount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| SourceKind | VARCHAR(23) | لا |  |  | enum: RENEWAL_ACKNOWLEDGEMENT, BANK_STATEMENT, INTERNAL |
| StatedPct | DECIMAL(9,6) | نعم |  |  | النسبة المنصوص عليها في المصدر؛ فرق >= 0.005 عن المحسوبة يُعلَّم (BR-FAC-017) |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(OutstandingSnapshotId) · UQ(TenantId, FacilityId, LimitId, ProductId, AsOfDate, SourceKind)

**قيود:** `AcknowledgedAmount >= 0` · `StatedPct IS NULL OR StatedPct >= 0` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `fac.Limit` — عقدة شجرة الحدود (FR-FAC-010/011، BR-FAC-009/010، V-FAC-04..07)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| ParentLimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | فارغ = جذر (أبوه التسهيل)؛ عمق <= 6 وبلا حلقات في التطبيق |
| LimitTypeId | INT | لا |  | cat.LimitType |  |
| Code | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| BankStructureNo | NVARCHAR(80) | نعم |  |  | نص حر اختياري على الحد (Q-FAC-01) |
| AmountBasis | VARCHAR(13) | لا | ABSOLUTE |  | enum: ABSOLUTE, PCT_OF_PARENT |
| Amount | DECIMAL(19,4) | نعم |  |  | بعملة التسهيل؛ إلزامي مع ABSOLUTE |
| PctOfParent | DECIMAL(9,6) | نعم |  |  | (0,100] مع PCT_OF_PARENT؛ الأب = التسهيل للجذور (BR-FAC-009) |
| EffectiveAmount | DECIMAL(19,4) | نعم |  |  | مخبأ: السقف الفعلي Cap(n) يُحسب عند الكتابة ويُعاد عند تغيّر الأب (BR-FAC-009) |
| DistributionMode | VARCHAR(13) | لا | SHARED_CAP |  | الافتراضي من LimitType (FR-FAC-011) enum: SHARED_CAP, PARTITION, OUTSIDE_TOTAL |
| IsRevolving | BIT | لا |  |  |  |
| IsCommitted | BIT | نعم |  |  |  |
| StartDate | DATE | نعم |  |  |  |
| EndDate | DATE | نعم |  |  |  |
| DueDate | DATE | نعم |  |  |  |
| PricingMode | VARCHAR(10) | لا | INHERIT |  | OWN يقطع الصعود إلى الأب (BR-PRC-010) enum: INHERIT, OWN |
| CompanyAllocationMode | VARCHAR(10) | لا | NONE |  | تخصيص الشركات (BR-FAC-012) enum: NONE, PARTITION, SHARED_CAP |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.Limit |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitId) · UQ(TenantId, FacilityId, Code) WHERE ToRevision IS NULL

**قيود:** `(AmountBasis = 'ABSOLUTE' AND Amount IS NOT NULL AND PctOfParent IS NULL) OR (AmountBasis = 'PCT_OF_PARENT' AND PctOfParent IS NOT NULL AND Amount IS NULL)` · `Amount IS NULL OR Amount >= 0` · `PctOfParent IS NULL OR (PctOfParent > 0 AND PctOfParent <= 100)` · `EffectiveAmount IS NULL OR EffectiveAmount >= 0` · `ParentLimitId IS NULL OR ParentLimitId <> LimitId` · `StartDate IS NULL OR EndDate IS NULL OR EndDate >= StartDate` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `fac.LimitProductLine` — خط منتج داخل حد: سقف اختياري SHARED_CAP دائمًا (FR-FAC-012، V-FAC-08)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitProductLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | لا |  | fac.Limit (via FacilityId) |  |
| ProductId | INT | لا |  | cat.Product | من المنتجات المسموحة للحد؛ فارغة = أي منتج بتحذير (SVC-08) |
| BankProductCode | NVARCHAR(60) | نعم |  |  | رمز منتج البنك |
| AmountBasis | VARCHAR(13) | نعم |  |  | سقف الخط؛ فارغ = بلا سقف خاص enum: ABSOLUTE, PCT_OF_PARENT |
| Amount | DECIMAL(19,4) | نعم |  |  |  |
| PctOfParent | DECIMAL(9,6) | نعم |  |  |  |
| IsRevolving | BIT | نعم |  |  | فارغ = يرث من الحد |
| DueDate | DATE | نعم |  |  | الاستحقاق <= نهاية الحد (V-FAC-08) |
| IsActive | BIT | لا | 1 |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.LimitProductLine |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitProductLineId) · UQ(TenantId, LimitId, ProductId, BankProductCode) WHERE ToRevision IS NULL

**قيود:** `(AmountBasis IS NULL AND Amount IS NULL AND PctOfParent IS NULL) OR (AmountBasis IS NOT NULL AND ((AmountBasis = 'ABSOLUTE' AND Amount IS NOT NULL AND PctOfParent IS NULL) OR (AmountBasis = 'PCT_OF_PARENT' AND PctOfParent IS NOT NULL AND Amount IS NULL)))` · `Amount IS NULL OR Amount >= 0` · `PctOfParent IS NULL OR (PctOfParent > 0 AND PctOfParent <= 100)` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `fac.LimitCompanyRule` — قيد شركة على حد: مسموح/مستثنى/تخصيص (FR-FAC-013، BR-FAC-012، V-FAC-09)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitCompanyRuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | لا |  | fac.Limit (via FacilityId) |  |
| CompanyId | BIGINT | لا |  | org.Company |  |
| RuleKind | VARCHAR(10) | لا |  |  | enum: ALLOWED, EXCLUDED, ALLOCATION |
| AllocationAmount | DECIMAL(19,4) | نعم |  |  | بعملة التسهيل؛ إلزامي للتخصيص (مبلغ أو نسبة) |
| AllocationPct | DECIMAL(9,6) | نعم |  |  |  |
| Reason | NVARCHAR(500) | نعم |  |  |  |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.LimitCompanyRule |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitCompanyRuleId) · UQ(TenantId, LimitId, CompanyId, RuleKind, ValidFrom) WHERE ToRevision IS NULL

**قيود:** `RuleKind <> 'ALLOCATION' OR (AllocationAmount IS NOT NULL AND AllocationPct IS NULL) OR (AllocationAmount IS NULL AND AllocationPct IS NOT NULL)` · `RuleKind = 'ALLOCATION' OR (AllocationAmount IS NULL AND AllocationPct IS NULL)` · `AllocationAmount IS NULL OR AllocationAmount > 0` · `AllocationPct IS NULL OR (AllocationPct > 0 AND AllocationPct <= 100)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `fac.ProductLineTerm` — شروط العملية لخط المنتج بتواريخ سريان؛ الفارغ = «غير محدد» لا صفر (FR-FAC-014، BR-FAC-016)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductLineTermId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitProductLineId | BIGINT | لا |  | fac.LimitProductLine (via FacilityId) |  |
| MaxTotalTenorDays | INT | نعم |  |  | أقصى مدة شاملة التأجيل (TENOR) |
| MaxDeferralDays | INT | نعم |  |  | أقصى تأجيل (DEFERRAL) |
| MaxPostDeferralFinancingDays | INT | نعم |  |  | أقصى تمويل بعد التأجيل (POST_DEFERRAL) |
| LcValidityDays | INT | نعم |  |  | صلاحية الاعتماد المستندي (LC_VALIDITY) |
| CashCoverPct | DECIMAL(9,6) | نعم |  |  | الغطاء النقدي الأدنى % (CASH_COVER) |
| FinancingRatioPct | DECIMAL(9,6) | نعم |  |  | نسبة التمويل الأقصى % (FINANCING_RATIO) |
| AdvanceNoticeDays | INT | نعم |  |  | مهلة الإخطار (NOTICE) |
| AdvanceNoticeUnit | VARCHAR(10) | لا | BUSINESS |  | يوم عمل افتراضيًا حسب BR-FAC-016 enum: BUSINESS, CALENDAR |
| CheckMode | VARCHAR(10) | لا | WARN |  | الآلية الوحيدة لشدة الفحص (FR-FAC-015، Q-FAC-02) enum: OFF, WARN, BLOCK |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | fac.ProductLineTerm |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductLineTermId) · UQ(TenantId, LimitProductLineId, EffectiveFrom) WHERE ToRevision IS NULL

**قيود:** `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `MaxTotalTenorDays IS NULL OR MaxTotalTenorDays >= 0` · `MaxDeferralDays IS NULL OR MaxDeferralDays >= 0` · `MaxPostDeferralFinancingDays IS NULL OR MaxPostDeferralFinancingDays >= 0` · `LcValidityDays IS NULL OR LcValidityDays >= 0` · `AdvanceNoticeDays IS NULL OR AdvanceNoticeDays >= 0` · `CashCoverPct IS NULL OR (CashCoverPct >= 0 AND CashCoverPct <= 100)` · `FinancingRatioPct IS NULL OR (FinancingRatioPct >= 0 AND FinancingRatioPct <= 100)` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `fac.Utilization` — بند استخدام فعّال: يدوي أو مرتبط باعتماد مستندي؛ لا حذف (FR-FAC-016/030، BR-FAC-013/020)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UtilizationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | لا |  | fac.Limit (via FacilityId) |  |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) | الخط من الحد نفسه |
| CompanyId | BIGINT | لا |  | org.Company |  |
| Reference | NVARCHAR(100) | لا |  |  | = LcNumberText لبند LC المحوَّل |
| Description | NVARCHAR(300) | نعم |  |  |  |
| Amount | DECIMAL(19,4) | لا |  |  | بعملة Currency؛ المبلغ بعملة التسهيل مشتق (BR-FAC-002) ولا يُخزَّن |
| CurrencyId | INT | لا |  | ref.Currency |  |
| RateToFacilityCcy | DECIMAL(19,8) | نعم |  |  | سعر تحويل يدوي مثبَّت؛ إلزامي إن اختلفت العملة (يتحقق التطبيق، BR-FAC-002) |
| StartDate | DATE | لا |  |  |  |
| MaturityDate | DATE | نعم |  |  |  |
| SourceType | VARCHAR(13) | لا | MANUAL |  | enum: MANUAL, LC, OTHER_REQUEST |
| SourceRefId | BIGINT | نعم |  |  | LcId أو RequestId؛ فارغ ابتداءً لبند LC ويُعبَّأ مرة واحدة من فارغ إلى قيمة (IMMUTABLE_SOURCE يفرضه التطبيق) |
| Status | VARCHAR(10) | لا | ACTIVE |  | RELEASED نهائية (§8) enum: ACTIVE, RELEASED |
| ReleasedOn | DATE | نعم |  |  |  |
| ReleaseReason | NVARCHAR(500) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UtilizationId) · UQ(PublicId) · UQ(TenantId, SourceType, SourceRefId) WHERE SourceRefId IS NOT NULL

**قيود:** `Amount >= 0` · `Status = 'RELEASED' OR Amount > 0` · `RateToFacilityCcy IS NULL OR RateToFacilityCcy > 0` · `MaturityDate IS NULL OR MaturityDate >= StartDate` · `Status <> 'RELEASED' OR (ReleasedOn IS NOT NULL AND ReleaseReason IS NOT NULL)` · `Status = 'RELEASED' OR (ReleasedOn IS NULL AND ReleaseReason IS NULL)`

### `fac.LimitReservation` — حجز مبلغ لطلب = ExposureAmount (FR-FAC-017/018/020، BR-FAC-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitReservationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | لا |  | fac.Limit (via FacilityId) |  |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) | الخط من الحد نفسه |
| CompanyId | BIGINT | لا |  | org.Company |  |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| Amount | DECIMAL(19,4) | لا |  |  | = ExposureAmount الوحيد الممرَّر (BR-FAC-015) |
| CurrencyId | INT | لا |  | ref.Currency |  |
| RateToFacilityCcy | DECIMAL(19,8) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | ACTIVE |  | CONVERTED وRELEASED نهائيتان (§8) enum: ACTIVE, CONVERTED, RELEASED |
| ExpiresOn | DATE | نعم |  |  |  |
| ConvertedUtilizationId | BIGINT | نعم |  | fac.Utilization (via FacilityId) | يعبَّأ عند التحويل (fac.convert_reservation) |
| ReleasedOn | DATE | نعم |  |  |  |
| ReleaseReason | VARCHAR(10) | نعم |  |  | enum: REJECTED, CANCELLED, EXPIRED, SUPERSEDED, MANUAL |
| OverLimit | BIT | لا | 0 |  | حجز فوق المتاح بتجاوز مدوَّن (FR-FAC-020) |
| OverrideReason | NVARCHAR(500) | نعم |  |  |  |
| AcknowledgedWarnings | NVARCHAR(MAX) | نعم |  |  |  |
| IdempotencyKey | VARCHAR(100) | لا |  |  | = RequestId لأمر الحجز؛ إعادة الحجز بعد الفك تشتق مفتاحًا جديدًا في التطبيق |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitReservationId) · UQ(TenantId, IdempotencyKey) · UQ(TenantId, RequestId) WHERE Status = 'ACTIVE' · UQ(TenantId, ConvertedUtilizationId) WHERE ConvertedUtilizationId IS NOT NULL

**قيود:** `Amount > 0` · `RateToFacilityCcy IS NULL OR RateToFacilityCcy > 0` · `Status <> 'CONVERTED' OR ConvertedUtilizationId IS NOT NULL` · `Status = 'CONVERTED' OR ConvertedUtilizationId IS NULL` · `Status <> 'RELEASED' OR (ReleasedOn IS NOT NULL AND ReleaseReason IS NOT NULL)` · `Status = 'RELEASED' OR (ReleasedOn IS NULL AND ReleaseReason IS NULL)` · `OverLimit = 0 OR OverrideReason IS NOT NULL`

### `fac.LimitMovement` — سجل حركة على حجز أو استخدام؛ لا تعديل ولا حذف؛ مفتاح عدم التكرار (BR-FAC-015/020)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LimitMovementId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility | إضافة: مفتاح النطاق |
| TargetKind | VARCHAR(11) | لا |  |  | enum: RESERVATION, UTILIZATION |
| LimitReservationId | BIGINT | نعم |  | fac.LimitReservation (via FacilityId) | بدل TargetId متعدد الأشكال لضمان السلامة المرجعية |
| UtilizationId | BIGINT | نعم |  | fac.Utilization (via FacilityId) |  |
| TargetId | BIGINT | نعم |  |  | مشتق: مطابق لـ TargetId في المواصفة محسوب: `CASE WHEN LimitReservationId IS NOT NULL THEN LimitReservationId ELSE UtilizationId END` |
| OpKind | VARCHAR(10) | لا |  |  | enum: CREATE, ADJUST, CONVERT, RELEASE |
| CurrencyId | INT | لا |  | ref.Currency | إضافة: عملة المبالغ أدناه (عملة الهدف) |
| RequestedDelta | DECIMAL(19,4) | نعم |  |  |  |
| AppliedDelta | DECIMAL(19,4) | نعم |  |  |  |
| AmountBefore | DECIMAL(19,4) | نعم |  |  |  |
| AmountAfter | DECIMAL(19,4) | نعم |  |  |  |
| Reason | NVARCHAR(500) | نعم |  |  |  |
| IdempotencyKey | VARCHAR(100) | لا |  |  |  |
| ActorUserId | BIGINT | لا |  | sec.AppUser |  |
| At | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitMovementId) · UQ(TenantId, IdempotencyKey)

**قيود:** `(TargetKind = 'RESERVATION' AND LimitReservationId IS NOT NULL AND UtilizationId IS NULL) OR (TargetKind = 'UTILIZATION' AND UtilizationId IS NOT NULL AND LimitReservationId IS NULL)` · `AmountAfter IS NULL OR AmountAfter >= 0` · `AppliedDelta IS NULL OR RequestedDelta IS NULL OR ABS(AppliedDelta) <= ABS(RequestedDelta)` · `OpKind <> 'ADJUST' OR AmountBefore IS NULL OR AmountAfter IS NULL OR AppliedDelta IS NULL OR AmountAfter = AmountBefore + AppliedDelta`

### `fac.ValueConflict` — تعارض قيمتين لحقل واحد وحسمه (FR-FAC-026، BR-FAC-019، BR-FAC-008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ValueConflictId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility | إضافة: مفتاح النطاق |
| TargetEntity | VARCHAR(60) | لا |  |  | الكيان المستهدف مثل fac.Limit أو prc.PricingRule (رابط متعدد الأشكال) |
| TargetId | BIGINT | لا |  |  |  |
| FieldName | VARCHAR(80) | لا |  |  |  |
| CandidateAValue | NVARCHAR(1000) | لا |  |  | القيمة + ختم المصدر (A) |
| CandidateASourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CandidateASourcePage | VARCHAR(40) | نعم |  |  |  |
| CandidateAReadFromScan | BIT | لا | 0 |  |  |
| CandidateAOriginalText | NVARCHAR(2000) | نعم |  |  |  |
| CandidateAConfidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| CandidateBValue | NVARCHAR(1000) | لا |  |  | القيمة + ختم المصدر (B) |
| CandidateBSourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CandidateBSourcePage | VARCHAR(40) | نعم |  |  |  |
| CandidateBReadFromScan | BIT | لا | 0 |  |  |
| CandidateBOriginalText | NVARCHAR(2000) | نعم |  |  |  |
| CandidateBConfidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| Status | VARCHAR(10) | لا | OPEN |  | enum: OPEN, RESOLVED |
| ChosenSide | VARCHAR(10) | نعم |  |  | enum: A, B, OTHER |
| ResolvedValue | NVARCHAR(1000) | نعم |  |  |  |
| ResolutionReason | NVARCHAR(1000) | نعم |  |  |  |
| ResolvedBy | BIGINT | نعم |  | sec.AppUser |  |
| ResolvedOn | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ValueConflictId) · UQ(TenantId, TargetEntity, TargetId, FieldName) WHERE Status = 'OPEN'

**قيود:** `Status <> 'RESOLVED' OR (ChosenSide IS NOT NULL AND ResolutionReason IS NOT NULL AND ResolvedBy IS NOT NULL AND ResolvedOn IS NOT NULL)` · `Status = 'RESOLVED' OR (ChosenSide IS NULL AND ResolvedBy IS NULL AND ResolvedOn IS NULL)` · `ChosenSide IS NULL OR ChosenSide <> 'OTHER' OR ResolvedValue IS NOT NULL` · `CandidateASourceDocumentId IS NOT NULL AND CandidateASourcePage IS NOT NULL OR (CandidateASourceDocumentId IS NULL AND CandidateAConfidence = 'ENTERED_NO_DOCUMENT')` · `CandidateBSourceDocumentId IS NOT NULL AND CandidateBSourcePage IS NOT NULL OR (CandidateBSourceDocumentId IS NULL AND CandidateBConfidence = 'ENTERED_NO_DOCUMENT')`

## PRC

### `prc.TariffSchedule` — إصدار جدول رسوم لبنك؛ بخاص بتسهيل اختياريًا (FR-PRC-001، BR-PRC-001، V-PRC-01)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TariffScheduleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| FacilityId | BIGINT | نعم |  | fac.Facility | فارغ = جدول عام للبنك؛ الخاص بالتسهيل يغلب (BR-PRC-001) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  | إضافة: ثنائية الاسم |
| VersionNo | INT | لا |  |  |  |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | اعتماد TM؛ المعتمد ثابت (FR-PRC-001) enum: DRAFT, APPROVED, SUPERSEDED |
| SourceDocumentId | BIGINT | نعم |  | doc.Document | ملحق التعرفة |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TariffScheduleId) · UQ(PublicId) · UQ(TenantId, InstitutionId, FacilityId, VersionNo) · UQ(TenantId, InstitutionId, FacilityId) WHERE Status = 'APPROVED' AND EffectiveTo IS NULL

**قيود:** `VersionNo >= 1` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `Status <> 'APPROVED' OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)`

### `prc.TariffItem` — بند رسم في جدول التعرفة (FR-PRC-002، BR-PRC-002..005)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TariffItemId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ScheduleId | BIGINT | لا |  | prc.TariffSchedule |  |
| FeeTypeId | INT | لا |  | cat.FeeType |  |
| ItemCode | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| ProductId | INT | نعم |  | cat.Product |  |
| ChargeKind | VARCHAR(11) | لا |  |  | enum: PERCENT, FIXED, PER_MILLION, TIERED |
| Rate | DECIMAL(9,6) | نعم |  |  | PERCENT (نقاط مئوية) |
| FixedAmount | DECIMAL(19,4) | نعم |  |  | FIXED |
| PerMillionAmount | DECIMAL(19,4) | نعم |  |  | PER_MILLION |
| PeriodBasis | VARCHAR(18) | لا | FLAT |  | enum: FLAT, PER_ANNUM, PER_PERIOD_OR_PART |
| PeriodDays | INT | نعم |  |  | طول الفترة؛ إلزامي لـ PER_PERIOD_OR_PART (FR-PRC-002) |
| MinAmount | DECIMAL(19,4) | نعم |  |  |  |
| MaxAmount | DECIMAL(19,4) | نعم |  |  |  |
| Locality | VARCHAR(12) | لا | ANY |  | enum: ANY, INSIDE_BANK, OUTSIDE_BANK |
| TierCalcMode | VARCHAR(10) | نعم | BAND |  | Q-PRC-02 enum: BAND, WHOLE |
| PerMillionMode | VARCHAR(15) | نعم | PRORATA |  | Q-PRC-03 enum: PRORATA, STARTED_MILLION |
| VatTreatment | VARCHAR(10) | لا | EXCLUSIVE |  | enum: EXCLUSIVE, INCLUSIVE, EXEMPT |
| CurrencyId | INT | نعم |  | ref.Currency | فارغ = عملة التسهيل عند الحل |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TariffItemId) · UQ(TenantId, ScheduleId, ItemCode)

**قيود:** `ChargeKind <> 'PERCENT' OR (Rate IS NOT NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `ChargeKind <> 'FIXED' OR (FixedAmount IS NOT NULL AND Rate IS NULL AND PerMillionAmount IS NULL)` · `ChargeKind <> 'PER_MILLION' OR (PerMillionAmount IS NOT NULL AND Rate IS NULL AND FixedAmount IS NULL)` · `ChargeKind <> 'TIERED' OR (Rate IS NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `Rate IS NULL OR (Rate >= 0 AND Rate <= 100)` · `PeriodBasis <> 'PER_PERIOD_OR_PART' OR PeriodDays IS NOT NULL` · `PeriodDays IS NULL OR PeriodDays > 0` · `MinAmount IS NULL OR MinAmount >= 0` · `MinAmount IS NULL OR MaxAmount IS NULL OR MinAmount <= MaxAmount` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `prc.TariffTier` — شريحة بند تعرفة بالمبلغ و/أو المدة (FR-PRC-003، BR-PRC-002)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TariffTierId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| TariffItemId | BIGINT | لا |  | prc.TariffItem |  |
| AmountFrom | DECIMAL(19,4) | نعم |  |  |  |
| AmountTo | DECIMAL(19,4) | نعم |  |  |  |
| PeriodFromDays | INT | نعم |  |  |  |
| PeriodToDays | INT | نعم |  |  |  |
| Rate | DECIMAL(9,6) | نعم |  |  |  |
| FixedAmount | DECIMAL(19,4) | نعم |  |  |  |
| MinAmount | DECIMAL(19,4) | نعم |  |  |  |
| SortOrder | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TariffTierId) · UQ(TenantId, TariffItemId, SortOrder) · UQ(TenantId, TariffItemId, AmountFrom, PeriodFromDays)

**قيود:** `AmountFrom IS NULL OR AmountFrom >= 0` · `AmountTo IS NULL OR AmountFrom IS NULL OR AmountTo > AmountFrom` · `PeriodFromDays IS NULL OR PeriodFromDays >= 0` · `PeriodToDays IS NULL OR PeriodFromDays IS NULL OR PeriodToDays >= PeriodFromDays` · `Rate IS NOT NULL OR FixedAmount IS NOT NULL` · `Rate IS NULL OR FixedAmount IS NULL` · `Rate IS NULL OR (Rate >= 0 AND Rate <= 100)` · `MinAmount IS NULL OR MinAmount >= 0`

### `prc.PricingRule` — قاعدة تسعير بنطاق ووراثة وطرق (FR-PRC-006..017، BR-PRC-006..012، V-PRC-02)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PricingRuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| ScopeLimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | بلا نطاق = مستوى التسهيل |
| ScopeLimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId) |  |
| ScopeProductId | INT | نعم |  | cat.Product |  |
| ScopeCompanyId | BIGINT | نعم |  | org.Company |  |
| ComponentKind | VARCHAR(18) | لا |  |  | enum: FEE, FINANCING_RETURN, PENALTY_NON_INCOME |
| RateState | VARCHAR(26) | لا | SET |  | غير محدد ⇒ حقول المعدل فارغة وتُستبعد من ResolvePricing (BR-PRC-012) enum: SET, NOT_SPECIFIED_IN_AGREEMENT |
| FeeTypeId | INT | نعم |  | cat.FeeType | لـ FEE وPENALTY_NON_INCOME |
| FinancingTypeId | INT | نعم |  | cat.FinancingType | لـ FINANCING_RETURN (FR-PRC-013) |
| Method | VARCHAR(17) | لا |  |  | enum: TARIFF_AS_IS, TARIFF_PLUS_ADDON, BASE_PLUS_MARGIN, PERCENT_OF_AMOUNT, FIXED_AMOUNT, PER_MILLION, TIERED |
| TariffItemId | BIGINT | نعم |  | prc.TariffItem | لـ TARIFF_AS_IS وTARIFF_PLUS_ADDON |
| AddOnPct | DECIMAL(9,6) | نعم |  |  | نقاط مئوية على معدل البند (BR-PRC-004) |
| BaseRateId | INT | نعم |  | cat.BaseRate | لـ BASE_PLUS_MARGIN |
| MarginPct | DECIMAL(9,6) | نعم |  |  | الهامش السالب تحذير (V-PRC-02) فلا قيد نطاق |
| BaseFloorPct | DECIMAL(9,6) | نعم |  |  | أرضية سعر الأساس؛ 0 = أرضية صفرية والفارغ بلا أرضية (FR-PRC-009) |
| RatePct | DECIMAL(9,6) | نعم |  |  | لـ PERCENT_OF_AMOUNT (ثابت للتسهيل: Q-PRC-05) |
| RateRangeLowPct | DECIMAL(9,6) | نعم |  |  | مدى بدل نقطة (BR-PRC-007) |
| RateRangeHighPct | DECIMAL(9,6) | نعم |  |  |  |
| FixedAmount | DECIMAL(19,4) | نعم |  |  | لـ FIXED_AMOUNT (بعملة CurrencyId) |
| PerMillionAmount | DECIMAL(19,4) | نعم |  |  | لـ PER_MILLION |
| CurrencyId | INT | نعم |  | ref.Currency | إضافة: عملة المبالغ الثابتة والحدود؛ فارغ = عملة التسهيل |
| PeriodBasis | VARCHAR(18) | نعم |  |  | enum: FLAT, PER_ANNUM, PER_PERIOD_OR_PART |
| PeriodDays | INT | نعم |  |  | إضافة: طول الفترة لـ PER_PERIOD_OR_PART على مستوى القاعدة (BR-PRC-002) |
| MinFeeAmount | DECIMAL(19,4) | نعم |  |  |  |
| MaxFeeAmount | DECIMAL(19,4) | نعم |  |  |  |
| RateFixing | VARCHAR(18) | نعم |  |  | لأساس+هامش (FR-PRC-008) enum: FIXED_FOR_CONTRACT, FLOATING |
| RepricingMonths | INT | نعم |  |  | دورية إعادة التسعير للمتغيّر |
| DayCount | VARCHAR(10) | نعم |  |  | إلزامي للزمني بلا افتراض صامت (BR-PRC-009) enum: ACT_360, ACT_365 |
| VatExclusive | BIT | لا | 1 |  | الضريبة سطر مستقل (BR-PRC-009) |
| BenchmarkReplacement | VARCHAR(15) | لا | NONE |  | شرط استبدال المؤشر (FR-PRC-009) enum: NONE, BANK_DETERMINES, NAMED_FALLBACK |
| ReplacementText | NVARCHAR(1000) | نعم |  |  |  |
| BankMayChange | VARCHAR(21) | لا | NO |  | حق البنك في التغيير (FR-PRC-010) enum: NO, WITH_NOTICE_OBJECTION, UNILATERAL |
| ObjectionDays | INT | نعم |  |  |  |
| ObjectionDaysKind | VARCHAR(10) | نعم |  |  | enum: CALENDAR, BUSINESS |
| TriggerEvent | VARCHAR(35) | نعم |  |  | حدث إطلاق العقوبة (FR-PRC-012) enum: LATE_PAYMENT, LATE_GUARANTEE_PAYMENT_AFTER_DEMAND, OTHER |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  | النسخة الجديدة بـ F تغلق السابقة عند F-1 (BR-PRC-011) |
| Retroactive | BIT | لا | 0 |  | أثر رجعي بسبب (FR-PRC-014) |
| RetroactiveReason | NVARCHAR(500) | نعم |  |  | إضافة: سبب الإدخال بأثر رجعي (BR-PRC-011) |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | prc.PricingRule |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PricingRuleId) · UQ(TenantId, FacilityId, FeeTypeId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, EffectiveFrom) WHERE ToRevision IS NULL AND FeeTypeId IS NOT NULL · UQ(TenantId, FacilityId, FinancingTypeId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, EffectiveFrom) WHERE ToRevision IS NULL AND FeeTypeId IS NULL

**قيود:** `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `ComponentKind <> 'FINANCING_RETURN' OR FeeTypeId IS NULL` · `ComponentKind = 'FINANCING_RETURN' OR (FeeTypeId IS NOT NULL AND FinancingTypeId IS NULL)` · `ComponentKind <> 'PENALTY_NON_INCOME' OR TriggerEvent IS NOT NULL` · `ComponentKind = 'PENALTY_NON_INCOME' OR TriggerEvent IS NULL` · `RateState <> 'NOT_SPECIFIED_IN_AGREEMENT' OR (AddOnPct IS NULL AND MarginPct IS NULL AND RatePct IS NULL AND RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `RateState <> 'SET' OR Method <> 'TARIFF_AS_IS' OR TariffItemId IS NOT NULL` · `RateState <> 'SET' OR Method <> 'TARIFF_PLUS_ADDON' OR (TariffItemId IS NOT NULL AND AddOnPct IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'BASE_PLUS_MARGIN' OR (BaseRateId IS NOT NULL AND MarginPct IS NOT NULL AND RateFixing IS NOT NULL AND DayCount IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'PERCENT_OF_AMOUNT' OR RatePct IS NOT NULL OR (RateRangeLowPct IS NOT NULL AND RateRangeHighPct IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'FIXED_AMOUNT' OR FixedAmount IS NOT NULL` · `RateState <> 'SET' OR Method <> 'PER_MILLION' OR PerMillionAmount IS NOT NULL` · `Method IN ('TARIFF_AS_IS','TARIFF_PLUS_ADDON') OR TariffItemId IS NULL` · `Method = 'TARIFF_PLUS_ADDON' OR AddOnPct IS NULL` · `Method = 'BASE_PLUS_MARGIN' OR (BaseRateId IS NULL AND MarginPct IS NULL AND BaseFloorPct IS NULL AND RateFixing IS NULL AND RepricingMonths IS NULL)` · `Method = 'PERCENT_OF_AMOUNT' OR (RatePct IS NULL AND RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL)` · `Method = 'FIXED_AMOUNT' OR FixedAmount IS NULL` · `Method = 'PER_MILLION' OR PerMillionAmount IS NULL` · `RatePct IS NULL OR (RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL)` · `(RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL) OR (RateRangeLowPct IS NOT NULL AND RateRangeHighPct IS NOT NULL AND RateRangeLowPct <= RateRangeHighPct)` · `RatePct IS NULL OR (RatePct >= 0 AND RatePct <= 100)` · `FixedAmount IS NULL OR FixedAmount >= 0` · `PerMillionAmount IS NULL OR PerMillionAmount >= 0` · `MinFeeAmount IS NULL OR MinFeeAmount >= 0` · `MinFeeAmount IS NULL OR MaxFeeAmount IS NULL OR MinFeeAmount <= MaxFeeAmount` · `PeriodDays IS NULL OR PeriodDays > 0` · `PeriodBasis IS NULL OR PeriodBasis <> 'PER_PERIOD_OR_PART' OR PeriodDays IS NOT NULL OR Method IN ('TARIFF_AS_IS','TARIFF_PLUS_ADDON','TIERED')` · `PeriodBasis IS NULL OR PeriodBasis <> 'PER_ANNUM' OR DayCount IS NOT NULL` · `RepricingMonths IS NULL OR RepricingMonths > 0` · `RateFixing IS NULL OR RateFixing <> 'FLOATING' OR RateState <> 'SET' OR RepricingMonths IS NOT NULL` · `BenchmarkReplacement <> 'NAMED_FALLBACK' OR ReplacementText IS NOT NULL` · `BankMayChange <> 'WITH_NOTICE_OBJECTION' OR (ObjectionDays IS NOT NULL AND ObjectionDaysKind IS NOT NULL)` · `ObjectionDays IS NULL OR ObjectionDays >= 0` · `Retroactive = 0 OR RetroactiveReason IS NOT NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `prc.PricingTier` — شريحة قاعدة TIERED بالمبلغ و/أو المدة (FR-PRC-003، BR-PRC-002)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PricingTierId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility | إضافة: مفتاح النطاق |
| PricingRuleId | BIGINT | لا |  | prc.PricingRule (via FacilityId) |  |
| AmountFrom | DECIMAL(19,4) | نعم |  |  |  |
| AmountTo | DECIMAL(19,4) | نعم |  |  |  |
| PeriodFromDays | INT | نعم |  |  |  |
| PeriodToDays | INT | نعم |  |  |  |
| RatePct | DECIMAL(9,6) | نعم |  |  |  |
| MarginPct | DECIMAL(9,6) | نعم |  |  |  |
| FixedAmount | DECIMAL(19,4) | نعم |  |  |  |
| SortOrder | INT | لا |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | prc.PricingTier |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PricingTierId) · UQ(TenantId, PricingRuleId, SortOrder) WHERE ToRevision IS NULL

**قيود:** `AmountFrom IS NULL OR AmountFrom >= 0` · `AmountTo IS NULL OR AmountFrom IS NULL OR AmountTo > AmountFrom` · `PeriodFromDays IS NULL OR PeriodFromDays >= 0` · `PeriodToDays IS NULL OR PeriodFromDays IS NULL OR PeriodToDays >= PeriodFromDays` · `(CASE WHEN RatePct IS NULL THEN 0 ELSE 1 END + CASE WHEN MarginPct IS NULL THEN 0 ELSE 1 END + CASE WHEN FixedAmount IS NULL THEN 0 ELSE 1 END) = 1` · `RatePct IS NULL OR (RatePct >= 0 AND RatePct <= 100)` · `FixedAmount IS NULL OR FixedAmount >= 0` · `ToRevision IS NULL OR ToRevision >= FromRevision`

## CMP

### `cmp.TermType` — مفتاح شرط قابل للمقارنة (FR-CMP-001)؛ الرمز بنمط PRC.MARGIN_PCT؛ النظامي لا يُحذف ولا تتغير وحدته (IsSystem)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TermTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Category | VARCHAR(10) | لا |  |  | الترتيب 1,2,3,4,9 (تسعير ← مدد ← ضمانات ← تعهدات ← أخرى) enum: PRICING, DURATION, COLLATERAL, COVENANT, OTHER |
| ValueKind | VARCHAR(10) | لا |  |  | enum: PERCENT, AMOUNT, DAYS, MONTHS, COUNT, BOOLEAN, ENUM, TEXT |
| Unit | VARCHAR(20) | لا |  |  | الرمز والوحدة ثابتان (BR-CMP-001) |
| DefaultBound | VARCHAR(10) | لا | EXACT |  | enum: EXACT, MAX, MIN |
| Direction | VARCHAR(13) | لا | NEUTRAL |  | اتجاه التفضيل (BR-CMP-003) enum: LOWER_BETTER, HIGHER_BETTER, NEUTRAL |
| ScopeKinds | VARCHAR(44) | لا |  |  | مجال النطاق المسموح |
| SourceBinding | NVARCHAR(200) | نعم |  |  | مسار الحقل المنمّط المُسقَط منه مثل prc.PricingRule.MarginPct (BR-CMP-004) |
| EnumOptions | NVARCHAR(MAX) | نعم |  |  | خيارات ValueKind=ENUM |
| IsComparable | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TermTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `ScopeKinds <> ''` · `ValueKind <> 'ENUM' OR EnumOptions IS NOT NULL` · `ValueKind = 'ENUM' OR EnumOptions IS NULL`

### `cmp.TermValue` — قيمة شرط في تسهيل بنطاقها ومصدرها (FR-CMP-002..006، BR-CMP-001..006، V-CMP-01)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TermValueId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| TermTypeId | INT | لا |  | cmp.TermType | مفتاح OTHER + OtherLabel لشرط خارج الكتالوج (FR-CMP-004) |
| OtherLabel | NVARCHAR(200) | نعم |  |  |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) |  |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId) |  |
| ProductId | INT | نعم |  | cat.Product |  |
| CompanyId | BIGINT | نعم |  | org.Company |  |
| ValueState | VARCHAR(26) | لا | SPECIFIED |  | غير المحددة لا تُعامل صفرًا (BR-CMP-002) enum: SPECIFIED, NOT_SPECIFIED_IN_AGREEMENT, NOT_APPLICABLE, UNKNOWN |
| ValueNumber | DECIMAL(19,6) | نعم |  |  | حسب ValueKind: نسبة/مبلغ/أيام/أشهر/عدد |
| ValueText | NVARCHAR(1000) | نعم |  |  |  |
| ValueBool | BIT | نعم |  |  |  |
| ValueEnum | NVARCHAR(100) | نعم |  |  |  |
| Unit | VARCHAR(20) | لا |  |  | وحدة النوع (V-CMP-01) |
| CurrencyId | INT | نعم |  | ref.Currency | إضافة: للقيم المالية فقط (ValueKind=AMOUNT) |
| Bound | VARCHAR(10) | لا | EXACT |  | لا مقارنة بحدّ مختلف (BR-CMP-005) enum: EXACT, MAX, MIN |
| NormalizedValue | DECIMAL(19,6) | نعم |  |  | أيام للمدد (الشهر = 30 تقريبي) ونقاط مئوية للنسب (BR-CMP-001) |
| Origin | VARCHAR(10) | لا | ENTERED |  | PROJECTED للقراءة فقط (BR-CMP-004) enum: ENTERED, PROJECTED |
| ProjectedFrom | VARCHAR(120) | نعم |  |  | مسار الصف/الحقل المصدر للإسقاط |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | cmp.TermValue |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TermValueId) · UQ(TenantId, FacilityId, TermTypeId, OtherLabel, LimitId, LimitProductLineId, ProductId, CompanyId, Bound, EffectiveFrom) WHERE ToRevision IS NULL

**قيود:** `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `ValueState = 'SPECIFIED' OR (ValueNumber IS NULL AND ValueText IS NULL AND ValueBool IS NULL AND ValueEnum IS NULL AND NormalizedValue IS NULL)` · `ValueState <> 'SPECIFIED' OR (CASE WHEN ValueNumber IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueText IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueBool IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueEnum IS NULL THEN 0 ELSE 1 END) = 1` · `NormalizedValue IS NULL OR ValueNumber IS NOT NULL` · `Origin <> 'PROJECTED' OR ProjectedFrom IS NOT NULL` · `Origin = 'PROJECTED' OR ProjectedFrom IS NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

## COL

### `col.Collateral` — سجل ضمان؛ اعتماد مستقل عن مراجعة التسهيل والتعديل نسخة جديدة (FR-COL-001/014، V-COL-01، §8)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralTypeId | INT | لا |  | cat.CollateralType | بنية النوع وقالب السمات من 11 (FR-CAT-013) |
| TitleAr | NVARCHAR(300) | لا |  |  |  |
| Description | NVARCHAR(2000) | نعم |  |  |  |
| OwnerPartyId | BIGINT | نعم |  | pty.Party | مزوّد استخدام Collateral owner؛ شركة المجموعة بـ Party المرآة (FR-COL-015) |
| Attributes | NVARCHAR(MAX) | نعم |  |  | سمات القالب؛ منها الهامش النقدي وحسابه وسمات العقار السبع (FR-COL-007/008) |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, ACTIVE, RELEASED, EXPIRED |
| ApprovalState | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser | إضافة: لازم لعقد المُعِدّ/المعتمِد (FR-COL-014، §12) |
| ApprovedOn | DATETIME2(3) | نعم |  |  | إضافة |
| SupersedesId | BIGINT | نعم |  | col.Collateral | النسخة الجديدة DRAFT تشير إلى المعتمدة (FR-COL-014) |
| GrantedOn | DATE | نعم |  |  |  |
| ReleasedOn | DATE | نعم |  |  | الفك بتاريخ وسبب ووثيقة بلا حذف (FR-COL-010) |
| ReleaseReason | NVARCHAR(500) | نعم |  |  |  |
| ReleaseDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CollateralId) · UQ(PublicId)

**قيود:** `Status = 'DRAFT' OR ApprovalState = 'APPROVED'` · `ApprovalState <> 'APPROVED' OR Status <> 'DRAFT'` · `ApprovalState <> 'APPROVED' OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `Status <> 'RELEASED' OR (ReleasedOn IS NOT NULL AND ReleaseReason IS NOT NULL)` · `Status = 'RELEASED' OR (ReleasedOn IS NULL AND ReleaseReason IS NULL AND ReleaseDocumentId IS NULL)` · `GrantedOn IS NULL OR ReleasedOn IS NULL OR ReleasedOn >= GrantedOn` · `SupersedesId IS NULL OR SupersedesId <> CollateralId` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `col.CollateralLink` — ربط ضمان بتسهيل أو حد؛ ضمان واحد لعدة تسهيلات (FR-COL-002، BR-COL-005)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralLinkId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral |  |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | حد من التسهيل نفسه؛ فارغ = على مستوى التسهيل |
| CoverageAmount | DECIMAL(19,4) | نعم |  |  | بعملة التسهيل (BR-FAC-002) |
| LienRank | INT | نعم |  |  | رتبة الرهن |
| LinkedOn | DATE | لا |  |  |  |
| UnlinkedOn | DATE | نعم |  |  | فك الربط يضع التاريخ ولا يحذف (FR-COL-002) |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | col.CollateralLink |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CollateralLinkId) · UQ(TenantId, CollateralId, FacilityId, LimitId) WHERE UnlinkedOn IS NULL AND ToRevision IS NULL

**قيود:** `CoverageAmount IS NULL OR CoverageAmount > 0` · `LienRank IS NULL OR LienRank >= 1` · `UnlinkedOn IS NULL OR UnlinkedOn >= LinkedOn` · `ToRevision IS NULL OR ToRevision >= FromRevision`

### `col.Guarantee` — كفالة 1:1 مع Collateral؛ الكفيل Party دائمًا ولا أرقام هوية هنا (FR-COL-003/004، BR-COL-001)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **GuaranteeId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral |  |
| GuarantorPartyId | BIGINT | لا |  | pty.Party | فرد أو جهة؛ نوع الكفيل مشتق من Party.Kind ولا يُخزَّن؛ مزوّد Guarantee (FR-COL-015) |
| GuarantorIdentityDocumentId | BIGINT | نعم |  | pty.IdentityDocument | الوثيقة المقيَّدة وقت التوقيع (BR-PTY-006)؛ انتماؤها للكفيل يتحقق منه التطبيق |
| GuaranteeForm | VARCHAR(33) | لا |  |  | enum: JOINT_SEVERAL_PAYMENT_PERFORMANCE, SIMPLE, OTHER |
| IsJointSeveral | BIT | لا |  |  |  |
| AmountMode | VARCHAR(11) | لا |  |  | UNSPECIFIED تُعدّ ولا تُجمع (BR-COL-001) enum: SPECIFIED, UNSPECIFIED |
| Amount | DECIMAL(19,4) | نعم |  |  |  |
| CurrencyId | INT | نعم |  | ref.Currency |  |
| SignedOn | DATE | نعم |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| DeedDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(GuaranteeId) · UQ(TenantId, CollateralId)

**قيود:** `AmountMode <> 'SPECIFIED' OR (Amount IS NOT NULL AND CurrencyId IS NOT NULL)` · `AmountMode <> 'UNSPECIFIED' OR (Amount IS NULL AND CurrencyId IS NULL)` · `Amount IS NULL OR Amount > 0` · `SignedOn IS NULL OR ValidTo IS NULL OR ValidTo >= SignedOn` · `GuaranteeForm <> 'JOINT_SEVERAL_PAYMENT_PERFORMANCE' OR IsJointSeveral = 1`

### `col.PromissoryNote` — سند لأمر 1:1؛ مبلغ مستقل قد يفوق الحد (FR-COL-005، BR-COL-002)؛ NextRenewalDue وPNRatio مشتقان

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PromissoryNoteId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral |  |
| NoteAmount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| IssuedOn | DATE | لا |  |  |  |
| DueKind | VARCHAR(10) | لا |  |  | enum: ON_DEMAND, FIXED_DATE |
| DueDate | DATE | نعم |  |  |  |
| RenewalCycle | VARCHAR(10) | لا |  |  | enum: NONE, ANNUAL |
| LastRenewedOn | DATE | نعم |  |  |  |
| CustodyKind | VARCHAR(10) | لا |  |  | موضع الحفظ enum: BANK, COMPANY, OTHER |
| NoteDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PromissoryNoteId) · UQ(TenantId, CollateralId)

**قيود:** `NoteAmount > 0` · `DueKind <> 'FIXED_DATE' OR (DueDate IS NOT NULL AND DueDate >= IssuedOn)` · `DueKind <> 'ON_DEMAND' OR DueDate IS NULL` · `LastRenewedOn IS NULL OR LastRenewedOn >= IssuedOn` · `RenewalCycle <> 'NONE' OR LastRenewedOn IS NULL`

### `col.PromissoryNoteSigner` — موقّعو السند (SignerPartyIds) -- جدول وسيط جديد؛ مزوّد PromissoryNote signer (FR-COL-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| PromissoryNoteId | BIGINT | لا |  | col.PromissoryNote |  |
| PartyId | BIGINT | لا |  | pty.Party | الدمج (FR-PTY-016) يعيد التوجيه ويحذف المكرر لذا الحذف مسموح للتطبيق |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, PromissoryNoteId, PartyId)

### `col.InsurancePolicyAssignment` — تجيير وثيقة تأمين؛ مفتاح الفرادة (CollateralId,PolicyNo) يسمح بتجديد الوثيقة (FR-COL-006، BR-COL-003)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InsurancePolicyAssignmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral |  |
| PolicyNo | NVARCHAR(60) | لا |  |  |  |
| InsurerName | NVARCHAR(200) | لا |  |  |  |
| AssignedToInstitutionId | BIGINT | لا |  | ins.Institution |  |
| CoverageBasis | VARCHAR(12) | لا |  |  | enum: PCT_OF_LIMIT, FIXED_AMOUNT, FULL_LIMITS |
| CoveragePct | DECIMAL(9,6) | نعم |  |  |  |
| CoverageAmount | DECIMAL(19,4) | نعم |  |  |  |
| SumInsured | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency | إضافة: عملة وثيقة التأمين (المواصفة بلا عملة) |
| PolicyStart | DATE | نعم |  |  |  |
| PolicyExpiry | DATE | لا |  |  |  |
| AssignmentDate | DATE | نعم |  |  |  |
| PolicyDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(InsurancePolicyAssignmentId) · UQ(TenantId, CollateralId, PolicyNo)

**قيود:** `SumInsured > 0` · `PolicyStart IS NULL OR PolicyExpiry >= PolicyStart` · `CoverageBasis <> 'PCT_OF_LIMIT' OR (CoveragePct IS NOT NULL AND CoveragePct > 0 AND CoverageAmount IS NULL)` · `CoverageBasis <> 'FIXED_AMOUNT' OR (CoverageAmount IS NOT NULL AND CoverageAmount > 0 AND CoveragePct IS NULL)` · `CoverageBasis <> 'FULL_LIMITS' OR (CoveragePct IS NULL AND CoverageAmount IS NULL)`

### `col.ValuationSchedule` — مراحل تقييم عقار (FR-COL-008، BR-COL-004)؛ مثل 3 مقيّمين في السنة الأولى ثم مقيّم سنويًا

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ValuationScheduleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral |  |
| PhaseNo | INT | لا |  |  |  |
| FromYear | INT | لا |  |  | سنوات من ReferenceDate |
| ToYear | INT | نعم |  |  | فارغ = مفتوحة إلى النهاية |
| RequiredValuerCount | INT | لا |  |  |  |
| FrequencyMonths | INT | لا |  |  | 0 = مرة واحدة |
| ReferenceDate | DATE | لا |  |  |  |
| LastValuationOn | DATE | نعم |  |  |  |
| LastValuationAmount | DECIMAL(19,4) | نعم |  |  |  |
| CurrencyId | INT | نعم |  | ref.Currency | إضافة: عملة آخر تقييم |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ValuationScheduleId) · UQ(TenantId, CollateralId, PhaseNo) · UQ(TenantId, CollateralId) WHERE ToYear IS NULL

**قيود:** `PhaseNo >= 1` · `FromYear >= 1` · `ToYear IS NULL OR ToYear >= FromYear` · `RequiredValuerCount >= 1` · `FrequencyMonths >= 0` · `LastValuationAmount IS NULL OR (LastValuationAmount > 0 AND LastValuationOn IS NOT NULL AND CurrencyId IS NOT NULL)` · `LastValuationOn IS NULL OR LastValuationAmount IS NOT NULL`

## OBL

### `obl.Obligation` — التزام على تسهيل (أو حد/خط/شركات)؛ العائلة من ObligationType ولا تُحرَّر (FR-OBL-001، BR-OBL-001)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ObligationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| ObligationTypeId | INT | لا |  | cat.ObligationType | عائلته: REPORTING/COVENANT/TRANSACTION_RESTRICTION/STATIC_CLAUSE (BR-CAT-010) |
| TitleAr | NVARCHAR(300) | لا |  |  |  |
| TitleEn | NVARCHAR(300) | نعم |  |  |  |
| Phase | VARCHAR(10) | لا | ONGOING |  | enum: PRECEDENT, ONGOING, SUBSEQUENT |
| ScopeLimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | حد من التسهيل نفسه |
| ScopeProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId) | خط من التسهيل نفسه؛ اتساقه مع ScopeLimitId يتحقق منه التطبيق |
| ClauseRef | NVARCHAR(100) | نعم |  |  |  |
| ClauseText | NVARCHAR(MAX) | نعم |  |  |  |
| ConsequenceText | NVARCHAR(2000) | نعم |  |  |  |
| GraceDays | INT | نعم |  |  | مهلة سماح (FR-OBL-010) |
| CureDays | INT | نعم |  |  | مهلة علاج الخرق (FR-OBL-010، BR-OBL-009) |
| ParamValue | DECIMAL(19,6) | نعم |  |  | بند ثابت برقم (FR-OBL-008) |
| ParamUnit | VARCHAR(13) | نعم |  |  | enum: DAYS, BUSINESS_DAYS, MONTHS, PCT, AMOUNT |
| ParamCurrencyId | INT | نعم |  | ref.Currency | إضافة: عملة ParamValue حين ParamUnit=AMOUNT |
| TriggerField | VARCHAR(100) | نعم |  |  | حقل الاعتماد المستندي المقيَّم (FR-OBL-009) |
| TriggerValues | NVARCHAR(MAX) | نعم |  |  | قيم المشغّل (مصفوفة) |
| CheckMode | VARCHAR(10) | نعم |  |  | فارغ = افتراضي المشترك (FR-OBL-009) enum: OFF, WARN, BLOCK |
| Status | VARCHAR(10) | لا | ACTIVE |  | enum: ACTIVE, SUSPENDED, ENDED |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | obl.Obligation |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ObligationId) · UQ(PublicId)

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `GraceDays IS NULL OR GraceDays >= 0` · `CureDays IS NULL OR CureDays >= 0` · `(ParamValue IS NULL AND ParamUnit IS NULL) OR (ParamValue IS NOT NULL AND ParamUnit IS NOT NULL)` · `ParamValue IS NULL OR ParamValue >= 0` · `ParamUnit IS NULL OR ParamUnit <> 'AMOUNT' OR ParamCurrencyId IS NOT NULL` · `ParamCurrencyId IS NULL OR ParamUnit = 'AMOUNT'` · `TriggerValues IS NULL OR TriggerField IS NOT NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

### `obl.ObligationCompany` — AppliesToCompanyIds -- جدول وسيط جديد؛ الحذف لصفوف مسودة المراجعة فقط (يفرضه التطبيق)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| ObligationId | BIGINT | لا |  | obl.Obligation |  |
| CompanyId | BIGINT | لا |  | org.Company |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, ObligationId, CompanyId)

### `obl.ReportingObligation` — قاعدة استحقاق تقرير/إخطار 1:1 مع Obligation (FR-OBL-002/003، BR-OBL-002، V-OBL-01)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReportingObligationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ObligationId | BIGINT | لا |  | obl.Obligation |  |
| Frequency | VARCHAR(11) | لا |  |  | enum: ANNUAL, SEMIANNUAL, QUARTERLY, MONTHLY, ONE_TIME, EVENT_BASED, ON_DEMAND |
| AnchorKind | VARCHAR(21) | لا |  |  | مطابقة لـ ObligationType.DefaultDeadlineBasis enum: AFTER_PERIOD_END, AFTER_FISCAL_YEAR_END, BEFORE_EVENT, AFTER_EVENT, ON_DEMAND_REQUEST, FIXED_DATE |
| OffsetValue | INT | نعم |  |  | فارغ مع FIXED_DATE فقط |
| OffsetUnit | VARCHAR(13) | لا | CALENDAR_DAYS |  | يُهمل مع FIXED_DATE enum: CALENDAR_DAYS, BUSINESS_DAYS, MONTHS |
| FixedDueDate | DATE | نعم |  |  | إلزامي مع FIXED_DATE ولا يُستعمل Offset |
| Direction | VARCHAR(10) | لا |  |  | enum: WE_SUBMIT, WE_RESPOND |
| DocumentBasis | VARCHAR(14) | لا |  |  | enum: AUDITED, INTERNAL, ANY, NOT_APPLICABLE |
| StatementScope | VARCHAR(12) | نعم |  |  | enum: STANDALONE, CONSOLIDATED, ANY |
| SubmissionChannelId | INT | نعم |  | cat.LookupItem | قائمة قنوات التقديم (منصة تنظيمية...) |
| ChannelNote | NVARCHAR(300) | نعم |  |  |  |
| AlertLeadDays | VARCHAR(40) | نعم | 30,14,7,3,1 |  | أيام ما قبل الاستحقاق مفصولة بفواصل (NTF-OBL-01) |
| FirstPeriodEnd | DATE | نعم |  |  |  |
| HorizonMonths | INT | نعم | 24 |  | أفق التوليد (FR-OBL-003) |
| ExpectsEvidence | BIT | لا |  |  | الدليل إلزامي عند التقديم (FR-OBL-004) |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | obl.ReportingObligation |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReportingObligationId) · UQ(TenantId, ObligationId) WHERE ToRevision IS NULL

**قيود:** `AnchorKind <> 'FIXED_DATE' OR (FixedDueDate IS NOT NULL AND OffsetValue IS NULL)` · `AnchorKind = 'FIXED_DATE' OR (FixedDueDate IS NULL AND OffsetValue IS NOT NULL)` · `OffsetValue IS NULL OR OffsetValue >= 0` · `HorizonMonths IS NULL OR HorizonMonths > 0` · `Frequency <> 'EVENT_BASED' OR AnchorKind IN ('BEFORE_EVENT','AFTER_EVENT')` · `AnchorKind NOT IN ('BEFORE_EVENT','AFTER_EVENT') OR Frequency = 'EVENT_BASED'` · `Frequency <> 'ON_DEMAND' OR AnchorKind = 'ON_DEMAND_REQUEST'` · `AnchorKind <> 'ON_DEMAND_REQUEST' OR Frequency = 'ON_DEMAND'` · `AlertLeadDays IS NULL OR AlertLeadDays NOT LIKE '%[^0-9,]%'` · `ToRevision IS NULL OR ToRevision >= FromRevision`

### `obl.ReportingInstance` — بند أجندة مولَّد أو مسجَّل لحدث (FR-OBL-003..005، BR-OBL-003، §8)؛ DUE_SOON/OVERDUE مشتقتان

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReportingInstanceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ReportingObligationId | BIGINT | لا |  | obl.ReportingObligation |  |
| PeriodStart | DATE | نعم |  |  |  |
| PeriodEnd | DATE | نعم |  |  |  |
| EventDate | DATE | نعم |  |  |  |
| DueDate | DATE | لا |  |  |  |
| DueDateOverrideReason | NVARCHAR(500) | نعم |  |  | تعديل موعد بسبب (SCR-OBL-02) |
| Status | VARCHAR(14) | لا | SCHEDULED |  | enum: SCHEDULED, SUBMITTED, WAIVED, NOT_APPLICABLE, CANCELLED |
| StatusReason | NVARCHAR(500) | نعم |  |  | إضافة: سبب NOT_APPLICABLE/CANCELLED (§8) |
| SubmittedOn | DATE | نعم |  |  |  |
| SubmissionChannelUsedId | INT | نعم |  | cat.LookupItem |  |
| SubmissionRef | NVARCHAR(100) | نعم |  |  | مرجع الاستلام |
| EvidenceDocumentId | BIGINT | نعم |  | doc.Document | إلزامي حيث ExpectsEvidence (يتحقق التطبيق) |
| ReportedAmount | DECIMAL(19,4) | نعم |  |  | مثل نتيجة تقييم عقار |
| CurrencyId | INT | نعم |  | ref.Currency |  |
| GeneratedBy | VARCHAR(12) | لا | JOB |  | enum: JOB, MANUAL_EVENT |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReportingInstanceId) · UQ(PublicId) · UQ(TenantId, ReportingObligationId, PeriodEnd) WHERE PeriodEnd IS NOT NULL · UQ(TenantId, ReportingObligationId, EventDate) WHERE PeriodEnd IS NULL AND EventDate IS NOT NULL · UQ(TenantId, ReportingObligationId, DueDate) WHERE PeriodEnd IS NULL AND EventDate IS NULL

**قيود:** `PeriodStart IS NULL OR (PeriodEnd IS NOT NULL AND PeriodEnd >= PeriodStart)` · `GeneratedBy <> 'MANUAL_EVENT' OR EventDate IS NOT NULL` · `Status <> 'SUBMITTED' OR SubmittedOn IS NOT NULL` · `Status = 'SUBMITTED' OR (SubmittedOn IS NULL AND SubmissionChannelUsedId IS NULL AND SubmissionRef IS NULL)` · `Status NOT IN ('NOT_APPLICABLE','CANCELLED') OR StatusReason IS NOT NULL` · `ReportedAmount IS NULL OR CurrencyId IS NOT NULL` · `CurrencyId IS NULL OR ReportedAmount IS NOT NULL`

### `obl.Covenant` — نسخة تعهد بتواريخ؛ الحدود المتدرجة = عدة نسخ (FR-OBL-006، BR-OBL-001/005/006، Q-OBL-01)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CovenantId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ObligationId | BIGINT | لا |  | obl.Obligation |  |
| MeasureKind | VARCHAR(18) | لا |  |  | NONE = وصفي بلا صيغة ولا حد enum: RATIO, AMOUNT, PERCENT_OF_REVENUE, AVERAGE_BALANCE, FLOW_VOLUME, NONE |
| FormulaId | BIGINT | نعم |  | fin.MeasureFormula | إلزامي للثلاثة الأولى؛ انتماؤها للتسهيل أو قالب يتحقق منه التطبيق |
| Operator | VARCHAR(10) | نعم |  |  | enum: GE, LE, GT, LT, EQ |
| ThresholdState | VARCHAR(26) | لا |  |  | الحكم لا يصدر إلا لـ SET (BR-OBL-006) enum: SET, NOT_SPECIFIED_IN_AGREEMENT, TO_BE_DETERMINED |
| ThresholdValue | DECIMAL(19,6) | نعم |  |  | نسبة أو مبلغ أو نقاط مئوية بحسب ThresholdUnit |
| ThresholdUnit | VARCHAR(10) | نعم |  |  | enum: RATIO, AMOUNT, PERCENT |
| CurrencyId | INT | نعم |  | ref.Currency | لعتبة المبلغ |
| TestFrequency | VARCHAR(11) | لا |  |  | enum: MONTHLY, QUARTERLY, SEMIANNUAL, ANNUAL, ROLLING_12M |
| AggregationMode | VARCHAR(14) | نعم |  |  | BR-FIN-005 enum: POINT_IN_TIME, PERIOD_AVERAGE, EACH_MONTH_MIN, PERIOD_SUM |
| AnnualWindowBasis | VARCHAR(13) | نعم |  |  | BR-FIN-007 enum: FISCAL_YEAR, CALENDAR_YEAR, FACILITY_YEAR |
| StatementBasis | VARCHAR(12) | نعم |  |  | أساس القائمة المطلوبة؛ لا بديل صامت (BR-FIN-003، Q-FIN-02) enum: STANDALONE, CONSOLIDATED |
| RequiredAssurance | VARCHAR(14) | نعم |  |  | FR-FIN-007 enum: AUDITED_ONLY, PREFER_AUDITED, ANY |
| RevenueBasisRule | VARCHAR(15) | نعم |  |  | الافتراضي التطبيقي SAME_PERIOD (BR-FIN-008) enum: SAME_PERIOD, PRIOR_YEAR, MANUAL_ESTIMATE |
| AccountScopeKind | VARCHAR(28) | نعم |  |  | BR-FIN-006 enum: ALL_COMPANY_ACCOUNTS_AT_BANK, SELECTED_ACCOUNTS, GROUP_ACCOUNTS |
| TestedCompanyId | BIGINT | لا |  | org.Company |  |
| SubmissionLagDays | INT | نعم |  |  | فارغ = افتراضي المشترك 30 (BR-OBL-005، Q-OBL-04) |
| FirstTestPeriodEnd | DATE | لا |  |  |  |
| EarlyWarningPct | DECIMAL(9,6) | نعم |  |  | فارغ = افتراضي المشترك 10 (BR-OBL-007) |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | obl.Covenant |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CovenantId) · UQ(TenantId, ObligationId, ValidFrom) WHERE ToRevision IS NULL

**قيود:** `MeasureKind NOT IN ('RATIO','AMOUNT','PERCENT_OF_REVENUE') OR FormulaId IS NOT NULL` · `MeasureKind <> 'NONE' OR (FormulaId IS NULL AND Operator IS NULL AND ThresholdValue IS NULL AND ThresholdState <> 'SET')` · `ThresholdState <> 'SET' OR (Operator IS NOT NULL AND ThresholdValue IS NOT NULL)` · `ThresholdState = 'SET' OR ThresholdValue IS NULL` · `ThresholdState <> 'SET' OR ThresholdUnit IS NULL OR ThresholdUnit <> 'AMOUNT' OR CurrencyId IS NOT NULL` · `CurrencyId IS NULL OR ThresholdUnit = 'AMOUNT'` · `RevenueBasisRule IS NULL OR MeasureKind = 'PERCENT_OF_REVENUE'` · `SubmissionLagDays IS NULL OR SubmissionLagDays >= 0` · `EarlyWarningPct IS NULL OR (EarlyWarningPct >= 0 AND EarlyWarningPct <= 100)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `ToRevision IS NULL OR ToRevision >= FromRevision`

### `obl.CovenantAccount` — AccountIds لـ SELECTED_ACCOUNTS -- جدول وسيط جديد؛ الحذف لصفوف مسودة المراجعة فقط (يفرضه التطبيق)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| CovenantId | BIGINT | لا |  | obl.Covenant |  |
| BankAccountId | BIGINT | لا |  | acc.BankAccount |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, CovenantId, BankAccountId)

### `obl.CovenantTest` — تقييم تعهد لفترة وإصدار تقييم؛ المخزَّن لا يُعدَّل (FR-OBL-011، FR-FIN-012/013، BR-OBL-006/007، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CovenantTestId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CovenantId | BIGINT | لا |  | obl.Covenant |  |
| PeriodStart | DATE | لا |  |  |  |
| PeriodEnd | DATE | لا |  |  |  |
| DueDate | DATE | لا |  |  | PeriodEnd + SubmissionLagDays (BR-OBL-005) |
| EvaluationNo | INT | لا | 1 |  | إعادة التقييم تضيف رقمًا ولا تعدّل القديم (BR-OBL-011) |
| State | VARCHAR(12) | لا | SCHEDULED |  | enum: SCHEDULED, PENDING_DATA, EVALUATED, REVIEWED |
| Result | VARCHAR(25) | نعم |  |  | enum: COMPLIANT, WARNING, BREACH, MISSING_DATA, NOT_ASSESSED_NO_THRESHOLD, NOT_COMPARABLE, MANUAL_COMPLIANT, MANUAL_NON_COMPLIANT, UNDER_REVIEW |
| Method | VARCHAR(13) | لا |  |  | enum: AUTO, MANUAL_VALUE, MANUAL_STATUS |
| ActualValue | DECIMAL(19,6) | نعم |  |  |  |
| ThresholdApplied | DECIMAL(19,6) | نعم |  |  | العتبة والمشغّل المطبَّقان وقت التقييم (BR-FIN-010) |
| OperatorApplied | VARCHAR(10) | نعم |  |  | enum: GE, LE, GT, LT, EQ |
| Headroom | DECIMAL(19,6) | نعم |  |  | a-t أو t-a (BR-OBL-007) |
| HeadroomPct | DECIMAL(19,6) | نعم |  |  | قد يتجاوز 999.999999 عند عتبة صغيرة جدًا فلا rate |
| InputsSnapshot | NVARCHAR(MAX) | نعم |  |  | لقطة المدخلات؛ إلزامية مع EVALUATED/REVIEWED ثابتة بعد الحفظ (BR-FIN-010) |
| FormulaVersion | INT | نعم |  |  |  |
| EvaluatedAt | DATETIME2(3) | نعم |  |  |  |
| EvaluatedBy | BIGINT | نعم |  | sec.AppUser | فارغ = المحرك الآلي |
| EvidenceDocumentId | BIGINT | نعم |  | doc.Document |  |
| ReviewNote | NVARCHAR(1000) | نعم |  |  |  |
| ReviewedBy | BIGINT | نعم |  | sec.AppUser |  |
| ReviewedOn | DATETIME2(3) | نعم |  |  |  |
| NextReviewOn | DATE | نعم |  |  | المراجعة الفائتة = مراجعة متأخرة (FR-OBL-007، BR-OBL-008) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CovenantTestId) · UQ(PublicId) · UQ(TenantId, CovenantId, PeriodEnd, EvaluationNo)

**قيود:** `EvaluationNo >= 1` · `PeriodEnd >= PeriodStart` · `DueDate >= PeriodEnd` · `State <> 'SCHEDULED' OR (Result IS NULL AND EvaluatedAt IS NULL)` · `State NOT IN ('EVALUATED','REVIEWED') OR (Result IS NOT NULL AND EvaluatedAt IS NOT NULL AND InputsSnapshot IS NOT NULL)` · `State <> 'REVIEWED' OR (ReviewedBy IS NOT NULL AND ReviewedOn IS NOT NULL)` · `Result NOT IN ('COMPLIANT','WARNING','BREACH') OR (ActualValue IS NOT NULL AND ThresholdApplied IS NOT NULL AND OperatorApplied IS NOT NULL)` · `Result <> 'NOT_ASSESSED_NO_THRESHOLD' OR ThresholdApplied IS NULL` · `ThresholdApplied IS NULL OR OperatorApplied IS NOT NULL` · `Headroom IS NULL OR (ActualValue IS NOT NULL AND ThresholdApplied IS NOT NULL)` · `HeadroomPct IS NULL OR Headroom IS NOT NULL` · `Result NOT IN ('MANUAL_COMPLIANT','MANUAL_NON_COMPLIANT','UNDER_REVIEW') OR Method = 'MANUAL_STATUS'` · `Method <> 'MANUAL_STATUS' OR Result IS NULL OR Result IN ('MANUAL_COMPLIANT','MANUAL_NON_COMPLIANT','UNDER_REVIEW')` · `FormulaVersion IS NULL OR FormulaVersion >= 1`

### `obl.ObligationBreach` — سجل خرق وعلاجه وتنازله (FR-OBL-012، BR-OBL-009/011، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ObligationBreachId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ObligationId | BIGINT | لا |  | obl.Obligation |  |
| Kind | VARCHAR(21) | لا |  |  | enum: COVENANT_BREACH, LATE_REPORT, RESTRICTION_VIOLATION, OTHER |
| CovenantTestId | BIGINT | نعم |  | obl.CovenantTest | اتساق اختبار الخرق مع الالتزام يتحقق منه التطبيق |
| ReportingInstanceId | BIGINT | نعم |  | obl.ReportingInstance |  |
| DetectedOn | DATE | لا |  |  |  |
| Description | NVARCHAR(2000) | نعم |  |  |  |
| Status | VARCHAR(16) | لا | OPEN |  | enum: OPEN, IN_CURE, CURED, WAIVED, CLOSED_NO_ACTION |
| CureDeadline | DATE | نعم |  |  | DetectedOn + CureDays (BR-OBL-009) |
| BankNotifiedOn | DATE | نعم |  |  |  |
| WaiverRef | NVARCHAR(100) | نعم |  |  |  |
| WaiverDate | DATE | نعم |  |  |  |
| WaiverBankContactId | BIGINT | نعم |  | ins.Contact |  |
| WaiverConditions | NVARCHAR(2000) | نعم |  |  |  |
| WaiverValidUntil | DATE | نعم |  |  |  |
| WaiverDocumentId | BIGINT | نعم |  | doc.Document |  |
| ConsequenceApplied | NVARCHAR(1000) | نعم |  |  |  |
| ResolvedOn | DATE | نعم |  |  |  |
| NeedsReview | BIT | لا | 0 |  | تعليم إعادة العرض لا يغيّر الحالة (BR-OBL-011) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ObligationBreachId) · UQ(PublicId) · UQ(TenantId, CovenantTestId) WHERE CovenantTestId IS NOT NULL AND Status IN ('OPEN','IN_CURE') · UQ(TenantId, ReportingInstanceId) WHERE ReportingInstanceId IS NOT NULL AND Status IN ('OPEN','IN_CURE')

**قيود:** `CovenantTestId IS NULL OR Kind = 'COVENANT_BREACH'` · `ReportingInstanceId IS NULL OR Kind = 'LATE_REPORT'` · `CureDeadline IS NULL OR CureDeadline >= DetectedOn` · `Status <> 'IN_CURE' OR CureDeadline IS NOT NULL` · `Status NOT IN ('CURED','WAIVED','CLOSED_NO_ACTION') OR ResolvedOn IS NOT NULL` · `Status IN ('CURED','WAIVED','CLOSED_NO_ACTION') OR ResolvedOn IS NULL` · `ResolvedOn IS NULL OR ResolvedOn >= DetectedOn` · `Status <> 'WAIVED' OR (WaiverRef IS NOT NULL AND WaiverDate IS NOT NULL AND WaiverBankContactId IS NOT NULL)` · `Status = 'WAIVED' OR (WaiverRef IS NULL AND WaiverDate IS NULL AND WaiverBankContactId IS NULL AND WaiverConditions IS NULL AND WaiverValidUntil IS NULL AND WaiverDocumentId IS NULL)` · `WaiverValidUntil IS NULL OR WaiverDate IS NULL OR WaiverValidUntil >= WaiverDate`

## FIN

### `fin.LineCatalogItem` — بند معياري للقوائم؛ 39 بندًا مزروعًا؛ النظامي في الصيغ لا يُحذف (FR-FIN-001، CatalogBase)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LineCatalogItemId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| Section | VARCHAR(12) | لا |  |  | enum: BS_ASSET, BS_LIABILITY, BS_EQUITY, IS, CF |
| IsTotal | BIT | لا | 0 |  | إجمالي محسوب من رموز مكوّناته (BR-FIN-001) |
| TotalFormula | NVARCHAR(500) | نعم |  |  | مثل GROSS_PROFIT - OPEX؛ نحو الإجماليات البسيط |
| IsRequired | BIT | لا | 0 |  | الفارغ منه يمنع التقديم (BR-FIN-002) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LineCatalogItemId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `IsTotal = 0 OR TotalFormula IS NOT NULL` · `IsTotal = 1 OR TotalFormula IS NULL` · `NameEn IS NOT NULL` · `Code NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)`

### `fin.LineCatalogItemAlias` — الأسماء البديلة للبند (Aliases) للصق والمطابقة -- جدول جديد يحل «Aliases set» (FR-FIN-003)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LineCatalogItemAliasId** | INT IDENTITY | لا | | | مفتاح أساسي |
| LineCatalogItemId | INT | لا |  | fin.LineCatalogItem |  |
| Alias | NVARCHAR(200) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LineCatalogItemAliasId) · UQ(TenantId, Alias)

**قيود:** `Alias <> ''`

### `fin.FinancialStatement` — رأس قائمة مالية؛ سري جدًا (FR-FIN-002/005/006، BR-FIN-001..004، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FinancialStatementId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| PeriodType | VARCHAR(10) | لا |  |  | enum: ANNUAL, SEMIANNUAL, QUARTERLY, MONTHLY |
| PeriodStart | DATE | نعم |  |  |  |
| PeriodEnd | DATE | لا |  |  |  |
| FiscalYear | INT | لا |  |  |  |
| Basis | VARCHAR(12) | لا |  |  | enum: STANDALONE, CONSOLIDATED |
| Assurance | VARCHAR(10) | لا |  |  | enum: AUDITED, REVIEWED, MANAGEMENT |
| CurrencyId | INT | لا |  | ref.Currency |  |
| UnitScale | INT | لا | 1 |  | المدخل بوحدة 1/1000/1000000 والمخزَّن مضروب فيها (BR-FIN-002) |
| AccountingStandard | NVARCHAR(100) | نعم |  |  |  |
| VersionNo | INT | لا | 1 |  |  |
| VersionReason | VARCHAR(10) | لا | ORIGINAL |  | سبب الإصدار إلزامي (BR-FIN-004) enum: ORIGINAL, RESTATED, CORRECTION |
| SupersedesId | BIGINT | نعم |  | fin.FinancialStatement | الإصدار السابق |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, SUBMITTED, APPROVED, SUPERSEDED, REJECTED |
| EntryMethod | VARCHAR(10) | لا |  |  | enum: MANUAL, PASTE |
| BalanceReason | NVARCHAR(500) | نعم |  |  | سبب عدم التوازن للتقديم؛ BalanceDifference مشتق (FR-FIN-004) |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| PreparedBy | BIGINT | نعم |  | sec.AppUser |  |
| PreparedOn | DATETIME2(3) | نعم |  |  |  |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FinancialStatementId) · UQ(PublicId) · UQ(TenantId, CompanyId, PeriodType, PeriodEnd, Basis, Assurance, VersionNo) · UQ(TenantId, CompanyId, Basis, Assurance, PeriodType, PeriodEnd) WHERE Status = 'APPROVED'

**قيود:** `UnitScale IN (1,1000,1000000)` · `PeriodStart IS NULL OR PeriodEnd >= PeriodStart` · `FiscalYear BETWEEN 1900 AND 2200` · `VersionNo >= 1` · `VersionReason <> 'ORIGINAL' OR SupersedesId IS NULL` · `SupersedesId IS NULL OR (VersionNo > 1 AND VersionReason <> 'ORIGINAL' AND SupersedesId <> FinancialStatementId)` · `Status NOT IN ('SUBMITTED','APPROVED','SUPERSEDED') OR (PreparedBy IS NOT NULL AND PreparedOn IS NOT NULL)` · `Status NOT IN ('APPROVED','SUPERSEDED') OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)`

### `fin.StatementLine` — سطر قائمة؛ بعملة الرأس والمخزَّن = المُدخل x UnitScale؛ Variance مشتق؛ سري جدًا (BR-FIN-001/002)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **StatementLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StatementId | BIGINT | لا |  | fin.FinancialStatement |  |
| LineCatalogItemId | INT | لا |  | fin.LineCatalogItem |  |
| EnteredAmount | DECIMAL(19,4) | نعم |  |  | الخانة الفارغة لغير الإلزامي تُحفظ صفرًا صريحًا عند التقديم (BR-FIN-002) 🔒 confidential |
| ComputedAmount | DECIMAL(19,4) | نعم |  |  | للإجماليات 🔒 confidential |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StatementLineId) · UQ(TenantId, StatementId, LineCatalogItemId)

### `fin.AccountMonthlyStat` — رصيد شهري لحساب بعملة الحساب (FR-FIN-008، BR-FIN-005/006، V-FIN-02)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AccountMonthlyStatId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| BankAccountId | BIGINT | لا |  | acc.BankAccount |  |
| MonthEnd | DATE | لا |  |  | نهاية الشهر؛ الشهر المستقبلي وخارج OpenedOn..ClosedOn يمنعه التطبيق |
| AvgDailyBalance | DECIMAL(19,4) | لا |  |  |  |
| MinBalance | DECIMAL(19,4) | نعم |  |  |  |
| EndBalance | DECIMAL(19,4) | نعم |  |  |  |
| SourceKind | VARCHAR(14) | لا |  |  | enum: BANK_STATEMENT, BANK_NOTICE, INTERNAL_CALC |
| SourceRef | NVARCHAR(100) | نعم |  |  |  |
| DocumentId | BIGINT | نعم |  | doc.Document |  |
| Note | NVARCHAR(500) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, CONFIRMED |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AccountMonthlyStatId) · UQ(PublicId) · UQ(TenantId, BankAccountId, MonthEnd)

### `fin.BankFlowEntry` — مبلغ محوَّل للبنك في شهر؛ تجميع سنوي آلي (FR-FIN-009/010، BR-FIN-007/008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BankFlowEntryId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| FacilityId | BIGINT | نعم |  | fac.Facility |  |
| MonthEnd | DATE | لا |  |  |  |
| FlowKindId | INT | لا |  | cat.LookupItem | قائمة FLOW_KIND؛ الافتراضي التطبيقي TRANSFERRED_TO_BANK |
| Amount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| BasisNote | NVARCHAR(500) | نعم |  |  | أساس الاحتساب بنص حر (03 §3.3) |
| DocumentId | BIGINT | نعم |  | doc.Document |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BankFlowEntryId) · UQ(PublicId) · UQ(TenantId, CompanyId, InstitutionId, FacilityId, MonthEnd, FlowKindId)

**قيود:** `Amount >= 0`

### `fin.MeasureFormula` — صيغة مقياس: قالب أو نسخة اتفاقية بإصدارات؛ لا تُنفَّذ نصًا (FR-FIN-011، BR-FIN-009، §12)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **MeasureFormulaId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(60) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Scope | VARCHAR(13) | لا |  |  | enum: TEMPLATE, FACILITY_COPY |
| FacilityId | BIGINT | نعم |  | fac.Facility | لنسخة الاتفاقية فقط؛ فارغ للقالب |
| BaseTemplateId | BIGINT | نعم |  | fin.MeasureFormula | القالب المنسوخ منه؛ كونه TEMPLATE يتحقق منه التطبيق |
| Expression | NVARCHAR(2000) | لا |  |  | نحو مقيَّد يُحلَّل إلى شجرة (BR-FIN-009) |
| InputKinds | VARCHAR(40) | لا |  |  |  |
| ResultUnit | VARCHAR(10) | لا |  |  | على غرار Covenant.ThresholdUnit (المواصفة لا تعدّد القيم) enum: RATIO, AMOUNT, PERCENT |
| DefinitionNote | NVARCHAR(1000) | نعم |  |  | مثل: هل يشمل الدين التزامات الإيجار |
| VersionNo | INT | لا | 1 |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED, SUPERSEDED |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  |  |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(MeasureFormulaId) · UQ(TenantId, Code, FacilityId, VersionNo) · UQ(TenantId, Code, FacilityId) WHERE Status = 'APPROVED'

**قيود:** `Scope <> 'TEMPLATE' OR FacilityId IS NULL` · `Scope <> 'FACILITY_COPY' OR FacilityId IS NOT NULL` · `Scope = 'FACILITY_COPY' OR BaseTemplateId IS NULL` · `BaseTemplateId IS NULL OR BaseTemplateId <> MeasureFormulaId` · `InputKinds <> ''` · `VersionNo >= 1` · `Code NOT LIKE '%[^A-Z0-9_]%'` · `Status NOT IN ('APPROVED','SUPERSEDED') OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)`

## REQ

### `wfl.RequestType` — تعريف نوع الطلب (FR-REQ-001، BR-REQ-001، V-REQ-01)؛ الأنواع الجديدة بلا كود (FR-REQ-021)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  | رمز النوع: LC_AMENDMENT · PURCHASE_LC · …؛ فريد بالمشترك |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| Category | VARCHAR(10) | لا |  |  | تصنيف مشتريات/مبيعات الموحّد (لا استيراد/تصدير) enum: PURCHASE, SALES, TREASURY, GENERAL, CHILD |
| ParentEntityType | VARCHAR(40) | نعم |  |  | نوع الكائن الأب للأنواع الفرعية (اعتماد صادر مثلًا) (FR-REQ-012، BR-REQ-008) |
| DefaultTemplateKey | VARCHAR(60) | لا |  |  | مفتاح القالب الافتراضي؛ النسخة المعتمدة هي IsCurrent (BR-WFL-019) |
| NumberSequenceKey | VARCHAR(50) | لا |  |  | = req:<Code> يقابل cfg.NumberSequenceDefinition.SequenceKey (BR-WFL-013، X-DAT-8) |
| AmountFieldKey | VARCHAR(60) | نعم |  |  | مفاتيح حقول الفهرسة في النموذج (FR-REQ-009) |
| CurrencyFieldKey | VARCHAR(60) | نعم |  |  |  |
| ProductFieldKey | VARCHAR(60) | نعم |  |  |  |
| ConsumesCreditLimit | BIT | لا | 0 |  | تقابل Product.ConsumesCreditLimit؛ يفعّل خطاف الحجز ولوحة التوفر (BR-REQ-009) |
| LimitCheckMode | VARCHAR(18) | لا | NONE |  | وضع لوحة التوفر للنوع؛ غير CheckMode لخط المنتج في 12 enum: NONE, ADVISORY, REQUIRED_SELECTION |
| RequiresSignedOriginal | BIT | لا | 0 |  | الأصل الموقّع إلزامي (FR-WFL-025) |
| IsActive | BIT | لا | 0 |  | التفعيل يلزمه قالب منشور وجمهور ومفتاح ترقيم (BR-REQ-001) يتحقق منه التطبيق |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  | للأنواع المبذورة؛ إعادة البذر لا تكرر (FR-WFL-002) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestTypeId) · UQ(PublicId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Category <> 'CHILD' OR ParentEntityType IS NOT NULL` · `ConsumesCreditLimit = 1 OR LimitCheckMode = 'NONE'`

### `wfl.RequestTypeAudience` — جمهور النوع: من يحق له الطلب؛ غياب الصفوف = لا أحد (فشل مغلق) (FR-REQ-007)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestTypeAudienceId** | INT IDENTITY | لا | | | مفتاح أساسي |
| RequestTypeId | INT | لا |  | wfl.RequestType |  |
| SubjectKind | VARCHAR(10) | لا |  |  | enum: ROLE, DEPARTMENT, USER |
| RoleId | BIGINT | نعم |  | sec.Role | SubjectKind=ROLE (بدل SubjectId متعدد الأشكال لضمان السلامة المرجعية) |
| DepartmentId | BIGINT | نعم |  | org.Department | SubjectKind=DEPARTMENT |
| UserId | BIGINT | نعم |  | sec.AppUser | SubjectKind=USER |
| SubjectId | BIGINT | نعم |  |  | مشتق: مطابق لـ SubjectId في المواصفة محسوب: `CASE WHEN RoleId IS NOT NULL THEN RoleId WHEN DepartmentId IS NOT NULL THEN DepartmentId ELSE UserId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestTypeAudienceId) · UQ(TenantId, RequestTypeId, RoleId) WHERE RoleId IS NOT NULL · UQ(TenantId, RequestTypeId, DepartmentId) WHERE DepartmentId IS NOT NULL · UQ(TenantId, RequestTypeId, UserId) WHERE UserId IS NOT NULL

**قيود:** `(SubjectKind = 'ROLE' AND RoleId IS NOT NULL AND DepartmentId IS NULL AND UserId IS NULL) OR (SubjectKind = 'DEPARTMENT' AND DepartmentId IS NOT NULL AND RoleId IS NULL AND UserId IS NULL) OR (SubjectKind = 'USER' AND UserId IS NOT NULL AND RoleId IS NULL AND DepartmentId IS NULL)`

### `wfl.TemplateField` — حقل في نسخة قالب يولّد النموذج بلا كود واجهة (FR-REQ-002..005، BR-REQ-003/004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TemplateFieldId** | INT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate |  |
| FieldKey | VARCHAR(60) | لا |  |  |  |
| LabelAr | NVARCHAR(200) | لا |  |  |  |
| LabelEn | NVARCHAR(200) | لا |  |  |  |
| HelpAr | NVARCHAR(500) | نعم |  |  |  |
| HelpEn | NVARCHAR(500) | نعم |  |  |  |
| SectionKey | VARCHAR(40) | نعم |  |  |  |
| SeqNo | INT | لا | 0 |  |  |
| DataType | VARCHAR(15) | لا |  |  | enum: TEXT, LONGTEXT, INTEGER, DECIMAL, AMOUNT, PERCENT, DATE, BOOLEAN, LIST, MULTILIST, CATALOG_REF, USER_REF, EXTERNAL_REF, FILE_SLOT, TABLE, MODULE_FORM, LIMIT_SELECTION |
| ConfigJson | NVARCHAR(MAX) | نعم |  |  | قوائم · نطاق · كتالوج · ComponentKey (MODULE_FORM يحفظ معرّف الكيان لا نسخة) |
| IsRequired | BIT | لا | 0 |  |  |
| RequiredWhenJson | NVARCHAR(MAX) | نعم |  |  | eq · ne · in · gt · gte · lt · lte · empty + all/any/not (FR-REQ-004) |
| VisibleWhenJson | NVARCHAR(MAX) | نعم |  |  |  |
| VisibleStagesJson | NVARCHAR(MAX) | نعم |  |  | StageKey المرئية فيها |
| EditableStagesJson | NVARCHAR(MAX) | نعم |  |  |  |
| Sensitivity | VARCHAR(12) | لا | NORMAL |  | المقيّد مشفّر ولا يدخل SearchText ولا الشروط (FR-REQ-024، V-WFL-03) enum: NORMAL, CONFIDENTIAL, RESTRICTED |
| IndexRole | VARCHAR(17) | لا | NONE |  | ينسخ إلى أعمدة الطلب (FR-REQ-009) enum: NONE, TITLE, AMOUNT, CURRENCY, COUNTERPARTY_NAME, COUNTERPARTY_CODE, PRODUCT, REQUIRED_BY_DATE |
| KeepWhenHidden | BIT | لا | 0 |  | الحقل المخفي شرطيًا لا يُحفظ ما لم يُعلَّم (BR-REQ-004) |
| ValidationJson | NVARCHAR(MAX) | نعم |  |  | طول · نطاق · نمط آمن · مقارنة حقلين (FR-REQ-005) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TemplateFieldId) · UQ(TenantId, TemplateId, FieldKey) · UQ(TenantId, TemplateId, IndexRole) WHERE IndexRole <> 'NONE'

**قيود:** `IndexRole <> 'AMOUNT' OR DataType = 'AMOUNT'` · `IndexRole <> 'TITLE' OR DataType = 'TEXT'` · `IndexRole <> 'REQUIRED_BY_DATE' OR DataType = 'DATE'` · `Sensitivity <> 'RESTRICTED' OR IndexRole = 'NONE'`

### `wfl.TemplateAttachmentRule` — قاعدة مرفق على نسخة قالب (FR-REQ-006، BR-REQ-005، FR-WFL-024/025)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TemplateAttachmentRuleId** | INT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate |  |
| SlotKey | VARCHAR(40) | لا |  |  |  |
| LabelAr | NVARCHAR(200) | نعم |  |  |  |
| LabelEn | NVARCHAR(200) | نعم |  |  |  |
| DocumentTypeId | INT | لا |  | cat.DocumentType | مثل SIGNED_REQUEST_ORIGINAL |
| MinCount | INT | لا | 0 |  |  |
| MaxCount | INT | نعم |  |  |  |
| RequiredBeforeStageKey | VARCHAR(40) | نعم |  |  | يلزم قبل مغادرة هذه المرحلة (BR-WFL-014) |
| RequiredWhenJson | NVARCHAR(MAX) | نعم |  |  |  |
| VisibleToRequester | BIT | لا | 0 |  | الافتراضي داخلي ما لم تُعلَّم (BR-REQ-005) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TemplateAttachmentRuleId) · UQ(TenantId, TemplateId, SlotKey)

**قيود:** `MinCount >= 0` · `MaxCount IS NULL OR (MaxCount >= 1 AND MaxCount >= MinCount)` · `MinCount = 0 OR RequiredBeforeStageKey IS NOT NULL` · `LabelAr IS NOT NULL OR LabelEn IS NOT NULL`

### `wfl.Request` — الطلب: أكثر الجداول ازدحامًا؛ الحالة الداخلية منفصلة عن المرحلة الظاهرة (FR-WFL-001، FR-REQ-009، D-6، BR-REQ-002/003)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DraftRef | VARCHAR(20) | لا |  |  | رقم مسودة D-xxxxxx خارج التسلسل (BR-WFL-013) |
| RequestNo | NVARCHAR(40) | نعم |  |  | بعد الترقيم عند NumberOnStageKey؛ الملغى بعد الترقيم يبقى رقمه (BR-WFL-013) |
| NumberYear | SMALLINT | نعم |  |  | سنة التسلسل المخصَّص (نسخة من cfg.NumberIssue) |
| NumberSeq | INT | نعم |  |  | قيمة التسلسل لكل نوع وسنة بلا فجوات (GAP_FREE، Q-PLT-08) |
| RequestTypeId | INT | لا |  | wfl.RequestType |  |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate (via RequestTypeId) | للمسودة: الحالية، ويُثبَّت عند أول تقديم (BR-WFL-019) |
| CompanyId | BIGINT | لا |  | org.Company | من نطاق المنشئ والطالب معًا (BR-REQ-002، V-REQ-02) |
| DepartmentId | BIGINT | نعم |  | org.Department | من الطالب |
| RequesterUserId | BIGINT | لا |  | sec.AppUser | صاحب الحاجة |
| CreatedByUserId | BIGINT | لا |  | sec.AppUser | المنشئ قد يختلف عن الطالب (BR-REQ-002) |
| SubmittedByUserId | BIGINT | نعم |  | sec.AppUser | مقدِّم الطلب: يحدد اكتمال خانة ORIGINATOR (BR-WFL-004، Q-WFL-03) |
| Title | NVARCHAR(200) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | §8 enum: DRAFT, ACTIVE, COMPLETED, REJECTED, CANCELLED |
| CurrentStageId | INT | نعم |  | wfl.WorkflowStage (via TemplateId) | إضافة: المرحلة الحالية مخبأة للفهارس ولوحات الطابور؛ تتبع القالب الملتقَط نفسه |
| CurrentStageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance | مثيل المرحلة الحالي؛ يتبع الطلب نفسه (يتحقق منه التطبيق) |
| ExternalPhaseId | INT | لا |  | wfl.ExternalPhase | المرحلة الظاهرة للطالب (BR-WFL-011) |
| SubStatusKey | VARCHAR(40) | نعم |  |  | الحالة الفرعية الداخلية؛ لا يراها الطالب (FR-WFL-015) |
| AssigneeUserId | BIGINT | نعم |  | sec.AppUser | المُسنَد؛ فارغ في الطابور (BR-WFL-005/007) |
| QueueEnteredAt | DATETIME2(3) | نعم |  |  | قِدَم الطابور تراكمي لا يُصفَّر بالتحرير (BR-WFL-007) |
| ClaimedAt | DATETIME2(3) | نعم |  |  |  |
| DueAt | DATETIME2(3) | نعم |  |  | استحقاق المرحلة الحالية بساعات العمل (BR-WFL-012) |
| SlaState | VARCHAR(10) | لا | NONE |  | enum: ON_TRACK, AT_RISK, OVERDUE, PAUSED, NONE |
| Priority | VARCHAR(10) | لا | NORMAL |  | BR-REQ-011 enum: NORMAL, URGENT |
| UrgentReason | NVARCHAR(500) | نعم |  |  |  |
| RequiredByDate | DATE | نعم |  |  |  |
| CycleNo | INT | لا | 1 |  | يزيد عند إعادة التقديم بعد إرجاع للطالب (FR-WFL-011) |
| SubmittedAt | DATETIME2(3) | نعم |  |  |  |
| CompletedAt | DATETIME2(3) | نعم |  |  | وقت الانتهاء لأي نتيجة نهائية: إكمال أو رفض أو إلغاء |
| OutcomeReason | NVARCHAR(500) | نعم |  |  | سبب الرفض/الإلغاء الظاهر عند الانتهاء؛ الأصل في RequestAction (FR-WFL-012) |
| Amount | DECIMAL(19,4) | نعم |  |  | الأنواع التعديلية: فرق Delta موقَّع قد يكون سالبًا (BR-REQ-008) |
| CurrencyId | INT | نعم |  | ref.Currency | عملة المبلغ (مواصفة: CurrencyCode)؛ هي عملة الحجز أيضًا (Q-REQ-06) |
| ProductId | INT | نعم |  | cat.Product | إضافة: دور الفهرسة PRODUCT يُنسخ إلى عمود الطلب (FR-REQ-009) |
| CounterpartyName | NVARCHAR(200) | نعم |  |  |  |
| CounterpartyCode | NVARCHAR(60) | نعم |  |  |  |
| SearchText | NVARCHAR(MAX) | نعم |  |  | نص مطبَّع (BR-PTY-004)؛ فهرس نصي كامل يُنشأ عند النشر؛ لا مقيَّد (BR-REQ-003) |
| FormDataJson | NVARCHAR(MAX) | نعم |  |  | النموذج بمفاتيح الحقول؛ الحقول المقيَّدة مشفّرة (BR-REQ-003، FR-REQ-024) 🔒 confidential |
| ParentEntityType | VARCHAR(40) | نعم |  |  | كائن أب من وحدة أخرى؛ يطابق RequestType.ParentEntityType (BR-REQ-008) |
| ParentEntityId | BIGINT | نعم |  |  |  |
| ParentRequestId | BIGINT | نعم |  | wfl.Request | أو طلب أب (طلب فرعي) |
| CopiedFromRequestId | BIGINT | نعم |  | wfl.Request | إضافة: الطلب المنسوخ منه (FR-REQ-025) |
| LcId | BIGINT | نعم |  | lc.LetterOfCredit | الاعتماد المرتبط: الأب للطلب الفرعي أو الصادر عن الطلب بعد ISSUANCE (BR-WFL-018) |
| FacilityId | BIGINT | نعم |  | fac.Facility | التخصيص (AllocFacilityId في المواصفة): اختيار الخزينة في FACILITY_SELECTION |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | AllocLimitId؛ الحد من التسهيل نفسه |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) | AllocProductLineId (LineId في fac.reserve_limit) |
| InstitutionId | BIGINT | نعم |  | ins.Institution | AllocInstitutionId |
| ExecutionChannel | VARCHAR(18) | نعم |  |  | تقترحه 11 SVC-02 ويعدّله المنفّذ (FR-WFL-027) enum: BANK_PORTAL, MANUAL_FORM, DIRECT_INTEGRATION |
| ReservationId | BIGINT | نعم |  | fac.LimitReservation | آخر حجز؛ بلا via لأن إعادة الاختيار تسبق إعادة الحجز (BR-WFL-017) |
| ReservedAmount | DECIMAL(19,4) | نعم |  |  | ما أعادته fac.reserve_limit = ExposureAmount المحجوز بعملة الطلب |
| ReservationState | VARCHAR(10) | لا | NONE |  | §8؛ LOST عند إفراج م5 خارجيًا (BR-WFL-017) enum: NONE, RESERVED, CONVERTED, RELEASED, LOST |
| HasSodException | BIT | لا | 0 |  | استخدام استثناء فصل المهام: إنذار للمدير عند أول مرة (BR-WFL-026) |
| ArchivedAt | DATETIME2(3) | نعم |  |  | أرشفة المسودة الخاملة 90 يومًا؛ تُسترجع (BR-REQ-012، FR-WFL-040) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestId) · UQ(PublicId) · UQ(TenantId, DraftRef) · UQ(TenantId, RequestNo) WHERE RequestNo IS NOT NULL · UQ(TenantId, RequestTypeId, NumberYear, NumberSeq) WHERE NumberSeq IS NOT NULL

**قيود:** `(RequestNo IS NULL AND NumberYear IS NULL AND NumberSeq IS NULL) OR (RequestNo IS NOT NULL AND NumberYear IS NOT NULL AND NumberSeq IS NOT NULL)` · `DraftRef LIKE 'D-%'` · `Status NOT IN ('ACTIVE','COMPLETED','REJECTED') OR SubmittedAt IS NOT NULL` · `(Status IN ('DRAFT','ACTIVE') AND CompletedAt IS NULL) OR (Status IN ('COMPLETED','REJECTED','CANCELLED') AND CompletedAt IS NOT NULL)` · `CompletedAt IS NULL OR SubmittedAt IS NULL OR CompletedAt >= SubmittedAt` · `Status <> 'ACTIVE' OR (CurrentStageInstanceId IS NOT NULL AND CurrentStageId IS NOT NULL)` · `Status <> 'COMPLETED' OR RequestNo IS NOT NULL` · `ArchivedAt IS NULL OR Status = 'DRAFT'` · `Priority <> 'URGENT' OR UrgentReason IS NOT NULL` · `CycleNo >= 1` · `Amount IS NULL OR CurrencyId IS NOT NULL` · `SlaState NOT IN ('ON_TRACK','AT_RISK','OVERDUE') OR DueAt IS NOT NULL` · `(ReservationState = 'NONE' AND ReservationId IS NULL AND ReservedAmount IS NULL) OR (ReservationState <> 'NONE' AND ReservationId IS NOT NULL AND ReservedAmount IS NOT NULL)` · `ReservedAmount IS NULL OR (ReservedAmount > 0 AND CurrencyId IS NOT NULL)` · `LimitId IS NULL OR FacilityId IS NOT NULL` · `LimitProductLineId IS NULL OR LimitId IS NOT NULL` · `(ParentEntityType IS NULL AND ParentEntityId IS NULL) OR (ParentEntityType IS NOT NULL AND ParentEntityId IS NOT NULL)` · `ParentRequestId IS NULL OR ParentRequestId <> RequestId` · `CopiedFromRequestId IS NULL OR CopiedFromRequestId <> RequestId`

### `wfl.RequestComment` — تعليق ظاهر للطالب أو داخلي؛ غير قابل للتعديل (سحب مع بقاء الأصل) (FR-REQ-017، BR-REQ-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestCommentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance (via RequestId) |  |
| Visibility | VARCHAR(17) | لا | INTERNAL |  | الداخلي لا يدخل RequesterView أبدًا (BR-WFL-024) enum: INTERNAL, REQUESTER_VISIBLE |
| Body | NVARCHAR(4000) | لا |  |  | نص صِرف بلا HTML حتى 4000 حرف |
| AuthorUserId | BIGINT | لا |  | sec.AppUser |  |
| ParentCommentId | BIGINT | نعم |  | wfl.RequestComment (via RequestId) | رد بمستوى واحد (يتحقق منه التطبيق) |
| RetractedAt | DATETIME2(3) | نعم |  |  |  |
| RetractedBy | BIGINT | نعم |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestCommentId)

**قيود:** `ParentCommentId IS NULL OR ParentCommentId <> RequestCommentId` · `(RetractedAt IS NULL AND RetractedBy IS NULL) OR (RetractedAt IS NOT NULL AND RetractedBy IS NOT NULL)`

### `wfl.RequestAttachment` — ربط مستند بطلب ينشئ DocumentLink (EntityType=Request) (FR-REQ-006، BR-REQ-005)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestAttachmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| SlotKey | VARCHAR(40) | نعم |  |  | فتحة قاعدة المرفق؛ الإصدار الجديد يحل محل الفعّال ويبقى السابق |
| StageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance (via RequestId) | المرحلة التي أُرفق فيها |
| Visibility | VARCHAR(17) | لا | INTERNAL |  | مرفقات الخزينة داخلية ما لم تُعلَّم (BR-REQ-005) enum: INTERNAL, REQUESTER_VISIBLE |
| IsActive | BIT | لا | 1 |  | إزالة منطقية؛ حذف الأصل الموقّع بعد اجتياز مرحلته مرفوض (FR-WFL-025) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestAttachmentId) · UQ(TenantId, RequestId, DocumentId)

### `wfl.RequestExternalRef` — مرجع خارجي بنص حر؛ تعديل بالإحلال ويبقى التاريخ؛ بلا تحقق خارجي (FR-REQ-010، X-DAT-7، BR-REQ-006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestExternalRefId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| SystemCode | NVARCHAR(40) | لا |  |  | نص حر مثل ERP |
| RefType | NVARCHAR(60) | لا |  |  | نص حر مثل PURCHASE_REQUEST |
| RefValue | NVARCHAR(100) | لا |  |  | القيمة كما أُدخلت للعرض |
| NormalizedValue | NVARCHAR(100) | لا |  |  | تقليم · أرقام 0-9 · لاتينية كبيرة · بلا فراغات وشرطات (BR-REQ-006) |
| EnteredAtStageKey | VARCHAR(40) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| SupersededById | BIGINT | نعم |  | wfl.RequestExternalRef (via RequestId) | الصف الذي أحلّ محله |
| EnteredBy | BIGINT | نعم |  | sec.AppUser |  |
| EnteredAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestExternalRefId)

**قيود:** `IsActive = 0 OR SupersededById IS NULL` · `SupersededById IS NULL OR SupersededById <> RequestExternalRefId`

## WFL

### `wfl.ExternalPhase` — المرحلة الظاهرة للطالب: DRAFT · IN_APPROVAL · RETURNED · AWAITING_REQUESTER · IN_PROGRESS · COMPLETED · REJECTED · CANCELLED (BR-WFL-011، D-6)

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ExternalPhaseId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(80) | لا |  |  | رمز الكتالوج |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| IsSystem | BIT | لا | 0 |  |  |
| IsLocked | BIT | لا | 0 |  |  |
| SortOrder | INT | لا | 0 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| ExternalCode | VARCHAR(80) | نعم |  |  |  |
| ColorKey | VARCHAR(30) | نعم |  |  | مفتاح لون العرض |
| RequiresRequesterAction | BIT | لا | 0 |  | تتطلب إجراءً من الطالب (بانتظار إجراء منك / معاد للتعديل) |
| IsFinal | BIT | لا | 0 |  | نهائية: مكتمل · مرفوض · ملغى |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ExternalPhaseId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `RequiresRequesterAction = 0 OR IsFinal = 0`

### `wfl.WorkflowTemplate` — نسخة قالب دورة عمل؛ المنشورة ثابتة (FR-WFL-001/028، BR-WFL-019، AC-WFL-6)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **WorkflowTemplateId** | INT IDENTITY | لا | | | مفتاح أساسي |
| RequestTypeId | INT | لا |  | wfl.RequestType | قالب لكل نوع؛ CHILD_STANDARD المشترك يُبذر نسخة لكل نوع (انظر تقرير الكاتب) |
| TemplateKey | VARCHAR(60) | لا |  |  |  |
| VersionNo | INT | لا |  |  | تصاعدي لكل TemplateKey بلا فجوات |
| Status | VARCHAR(10) | لا | DRAFT |  | §8 enum: DRAFT, PUBLISHED, RETIRED |
| IsCurrent | BIT | لا | 0 |  | واحدة لكل مفتاح؛ تعيينها عند النشر والسابقة تصير RETIRED |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| NumberOnStageKey | VARCHAR(40) | نعم |  |  | StageKey الذي يُخصَّص عند دخوله رقم الطلب (BR-WFL-013، Q-WFL-02) |
| ResetApprovalsOnResubmit | BIT | لا | 1 |  | الموافقات تبدأ من جديد بعد الإرجاع (BR-WFL-008) |
| AutoReassignOnOverdue | BIT | لا | 0 |  | إعادة الإسناد التلقائي عند التأخر معطّلة (BR-WFL-022) |
| SodAllowSamePerson | BIT | لا | 0 |  | wf.sod.allow_same_person: يتيح لشخص واحد أكثر من دور ويوسم استثناء (FR-WFL-041، BR-WFL-026) |
| ChangeNote | NVARCHAR(MAX) | نعم |  |  |  |
| PublishedAt | DATETIME2(3) | نعم |  |  |  |
| PublishedBy | BIGINT | نعم |  | sec.AppUser | الناشر غير المحرِّر ما لم يُفعَّل الاستثناء (Q-WFL-14) يتحقق منه التطبيق |
| RetiredAt | DATETIME2(3) | نعم |  |  |  |
| IsTenantModified | BIT | لا | 0 |  | تعديل المشترك لقالب مبذور ينشئ نسخة مملوكة له (FR-WFL-030) |
| SourceSeedVersion | INT | نعم |  |  | نسخة البذرة المشتقة منها |
| SeedKey | VARCHAR(80) | نعم |  |  | PURCHASE_LC · CHILD_STANDARD · …؛ على الصف المبذور الأصلي فقط (FR-WFL-002) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(WorkflowTemplateId) · UQ(PublicId) · UQ(TenantId, TemplateKey, VersionNo) · UQ(TenantId, TemplateKey) WHERE IsCurrent = 1 · UQ(TenantId, RequestTypeId, SeedKey, SourceSeedVersion) WHERE SeedKey IS NOT NULL

**قيود:** `VersionNo >= 1` · `IsCurrent = 0 OR Status = 'PUBLISHED'` · `Status <> 'PUBLISHED' OR PublishedAt IS NOT NULL` · `Status <> 'DRAFT' OR PublishedAt IS NULL` · `(Status = 'RETIRED' AND RetiredAt IS NOT NULL) OR (Status <> 'RETIRED' AND RetiredAt IS NULL)` · `IsTenantModified = 0 OR SeedKey IS NULL` · `SeedKey IS NULL OR SourceSeedVersion IS NOT NULL` · `NameAr IS NOT NULL OR NameEn IS NOT NULL`

### `wfl.WorkflowStage` — مرحلة في نسخة قالب (FR-WFL-003/004/005، BR-WFL-002/010/012)؛ حذف فعلي لمسودة النسخة فقط

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **WorkflowStageId** | INT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate |  |
| StageKey | VARCHAR(40) | لا |  |  | ثابت عبر النسخ |
| NameAr | NVARCHAR(200) | لا |  |  | الاسم الداخلي (لا يراه الطالب، BR-WFL-024) |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Kind | VARCHAR(14) | لا |  |  | enum: DRAFT, TASK, APPROVAL, TREASURY_QUEUE, TERMINAL |
| SeqNo | INT | لا | 0 |  |  |
| ExternalPhaseId | INT | لا |  | wfl.ExternalPhase | النشر بلا مرحلة ظاهرة مرفوض (FR-WFL-003) |
| AssigneeRule | VARCHAR(17) | نعم |  |  | فارغ لمرحلة APPROVAL (الخانات تحدد) وللنهائية enum: ROLE, USER, DEPARTMENT, REQUESTER, REQUESTER_MANAGER, CLAIMER |
| AssigneeRoleId | BIGINT | نعم |  | sec.Role | AssigneeRef للقاعدة ROLE: دور |
| PoolPermissionId | INT | نعم |  | sec.Permission | أو صلاحية تحدد المجموعة المؤهلة (req.claim · req.facility.select) (FR-WFL-041، §5.5) |
| AssigneeUserId | BIGINT | نعم |  | sec.AppUser | AssigneeRef للقاعدة USER |
| AssigneeDepartmentId | BIGINT | نعم |  | org.Department | AssigneeRef للقاعدة DEPARTMENT |
| FallbackRoleId | BIGINT | نعم |  | sec.Role | FallbackRule: الدور البديل ثم TM (FR-WFL-005، BR-WFL-005) |
| ApprovalMode | VARCHAR(10) | لا | NONE |  | enum: NONE, ANY, ALL |
| SlaHours | DECIMAL(7,2) | نعم |  |  | ساعات عمل (BR-WFL-012) |
| ClaimSlaHours | DECIMAL(7,2) | نعم |  |  | مهلة السحب من الطابور |
| SlaMode | VARCHAR(10) | لا | BUSINESS |  | enum: BUSINESS, CALENDAR |
| IsTerminal | BIT | لا | 0 |  |  |
| TerminalOutcome | VARCHAR(10) | نعم |  |  | enum: COMPLETED, REJECTED, CANCELLED |
| AllowRequesterCancel | BIT | لا | 0 |  |  |
| AllowReturn | BIT | لا | 0 |  |  |
| RequiresComment | BIT | لا | 0 |  |  |
| IsReservationPoint | BIT | لا | 0 |  | نقطة الحجز: موافقة TM تستدعي fac.reserve_limit (FR-WFL-022) |
| SodAllowSamePerson | BIT | نعم |  |  | تجاوز اختياري لإعداد القالب؛ الفارغ = يرث القالب (BR-WFL-026) |
| SubStatusSetJson | NVARCHAR(MAX) | نعم |  |  | الحالات الفرعية: مفتاح · اسم Ar/En · PausesSla (BR-WFL-010) |
| EditableFieldKeysJson | NVARCHAR(MAX) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(WorkflowStageId) · UQ(TenantId, TemplateId, StageKey) · UQ(TenantId, TemplateId) WHERE Kind = 'DRAFT'

**قيود:** `(Kind = 'TERMINAL' AND IsTerminal = 1) OR (Kind <> 'TERMINAL' AND IsTerminal = 0)` · `(IsTerminal = 1 AND TerminalOutcome IS NOT NULL) OR (IsTerminal = 0 AND TerminalOutcome IS NULL)` · `(Kind = 'APPROVAL' AND ApprovalMode <> 'NONE') OR (Kind <> 'APPROVAL' AND ApprovalMode = 'NONE')` · `SlaHours IS NULL OR SlaHours > 0` · `ClaimSlaHours IS NULL OR (ClaimSlaHours > 0 AND Kind = 'TREASURY_QUEUE')` · `IsReservationPoint = 0 OR Kind = 'APPROVAL'` · `Kind <> 'TREASURY_QUEUE' OR (AssigneeRule IS NOT NULL AND AssigneeRule = 'ROLE' AND (AssigneeRoleId IS NOT NULL OR PoolPermissionId IS NOT NULL))` · `(AssigneeRoleId IS NULL AND PoolPermissionId IS NULL) OR AssigneeRule = 'ROLE'` · `AssigneeRoleId IS NULL OR PoolPermissionId IS NULL` · `AssigneeUserId IS NULL OR AssigneeRule = 'USER'` · `AssigneeDepartmentId IS NULL OR AssigneeRule = 'DEPARTMENT'` · `AssigneeRule <> 'USER' OR AssigneeUserId IS NOT NULL` · `AssigneeRule <> 'DEPARTMENT' OR AssigneeDepartmentId IS NOT NULL` · `AssigneeRule <> 'ROLE' OR AssigneeRoleId IS NOT NULL OR PoolPermissionId IS NOT NULL`

### `wfl.StageApprover` — خانة موافقة في مرحلة APPROVAL؛ ALL = كل الخانات، ودور بشخصين يلزمان معًا = خانتان (FR-WFL-007/041، BR-WFL-003/004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **StageApproverId** | INT IDENTITY | لا | | | مفتاح أساسي |
| StageId | INT | لا |  | wfl.WorkflowStage |  |
| SlotKey | VARCHAR(30) | لا |  |  | مثل ORIGINATOR · MANAGER · TM |
| LabelAr | NVARCHAR(200) | نعم |  |  |  |
| LabelEn | NVARCHAR(200) | نعم |  |  |  |
| WorkflowRole | VARCHAR(10) | لا | APPROVER |  | دور سير العمل: منشئ · مدقّق · معتمِد (FR-WFL-041) enum: CREATOR, AUDITOR, APPROVER, OTHER |
| SubjectRule | VARCHAR(17) | لا |  |  | enum: REQUESTER, REQUESTER_MANAGER, ROLE, USER, DEPARTMENT_HEAD |
| RoleId | BIGINT | نعم |  | sec.Role | SubjectRef للقاعدة ROLE |
| UserId | BIGINT | نعم |  | sec.AppUser | SubjectRef للقاعدة USER |
| DepartmentId | BIGINT | نعم |  | org.Department | SubjectRef لرئيس إدارة محددة (الفارغ = إدارة الطالب) |
| FallbackRoleId | BIGINT | نعم |  | sec.Role | FallbackRule (BR-WFL-005) |
| AutoCompleteBySubmitter | BIT | لا | 0 |  | خانة ORIGINATOR تكتمل بالتقديم إن قدّمه الطالب نفسه (BR-WFL-004) |
| AllowDelegation | BIT | لا | 1 |  | صلاحيات الكشف الحساسة لا تُفوَّض (BR-WFL-021) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StageApproverId) · UQ(TenantId, StageId, SlotKey)

**قيود:** `SubjectRule <> 'ROLE' OR RoleId IS NOT NULL` · `SubjectRule <> 'USER' OR UserId IS NOT NULL` · `RoleId IS NULL OR SubjectRule = 'ROLE'` · `UserId IS NULL OR SubjectRule = 'USER'` · `DepartmentId IS NULL OR SubjectRule = 'DEPARTMENT_HEAD'` · `AutoCompleteBySubmitter = 0 OR SubjectRule = 'REQUESTER'` · `LabelAr IS NOT NULL OR LabelEn IS NOT NULL`

### `wfl.WorkflowTransition` — انتقال بين مرحلتين بشرط وأولوية؛ دورة خطية بتفرع شرطي بسيط (FR-WFL-006، BR-WFL-001، D-8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **WorkflowTransitionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate |  |
| FromStageId | INT | لا |  | wfl.WorkflowStage (via TemplateId) | الرسم كله داخل القالب نفسه |
| Action | VARCHAR(10) | لا |  |  | enum: SUBMIT, APPROVE, COMPLETE, RETURN, REJECT, CANCEL, RESUBMIT |
| ToStageId | INT | لا |  | wfl.WorkflowStage (via TemplateId) | RESUBMIT يعيد إلى ResumeStage المحفوظة في مثيل المرحلة (BR-WFL-008) |
| Priority | INT | لا | 1 |  | تصاعدي: يُنفَّذ أول شرط محقق (BR-WFL-001) |
| ConditionJson | NVARCHAR(MAX) | نعم |  |  | تعبير مقيَّد بلا شيفرة؛ الفارغ = دائمًا (FR-REQ-004) |
| ResumeStageId | INT | نعم |  | wfl.WorkflowStage (via TemplateId) | مرحلة الاستئناف عند RETURN (FR-WFL-010) |
| LabelAr | NVARCHAR(200) | نعم |  |  |  |
| LabelEn | NVARCHAR(200) | نعم |  |  |  |
| RequiresComment | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(WorkflowTransitionId) · UQ(TenantId, FromStageId, Action, Priority)

**قيود:** `Priority >= 1` · `FromStageId <> ToStageId` · `ResumeStageId IS NULL OR Action IN ('RETURN','RESUBMIT')` · `Action NOT IN ('RETURN','REJECT') OR RequiresComment = 1`

### `wfl.WorkflowStageHook` — خطاف مسجَّل بالكود على مرحلة: مفتاح ومعاملات لا شيفرة (FR-WFL-021، BR-WFL-015، §5.4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **WorkflowStageHookId** | INT IDENTITY | لا | | | مفتاح أساسي |
| StageId | INT | لا |  | wfl.WorkflowStage |  |
| TriggerKind | VARCHAR(10) | لا |  |  | Trigger في المواصفة؛ الاسم محجوز في T-SQL enum: ON_ENTER, ON_EXIT, ON_ACTION |
| ActionFilter | VARCHAR(10) | نعم |  |  | للمشغّل ON_ACTION فقط؛ REJECT وCANCEL صفّان enum: SUBMIT, APPROVE, COMPLETE, RETURN, REJECT, CANCEL, RESUBMIT |
| HookKey | VARCHAR(60) | لا |  |  | مثل fac.reserve_limit · lc.validate_terms · ntf.emit |
| ParamsJson | NVARCHAR(MAX) | نعم |  |  |  |
| ExecMode | VARCHAR(12) | لا | SYNC_TX |  | enum: SYNC_TX, AFTER_COMMIT |
| OnFailure | VARCHAR(10) | لا | BLOCK |  | enum: BLOCK, WARN |
| SeqNo | INT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(WorkflowStageHookId) · UQ(TenantId, StageId, TriggerKind, ActionFilter, HookKey)

**قيود:** `(TriggerKind = 'ON_ACTION' AND ActionFilter IS NOT NULL) OR (TriggerKind <> 'ON_ACTION' AND ActionFilter IS NULL)` · `HookKey LIKE '%.%'`

### `wfl.RequestStageInstance` — دخول طلب إلى مرحلة؛ مصدر مقاييس الأزمنة والسحب والـ SLA (BR-WFL-002/007/012، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestStageInstanceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageId | INT | لا |  | wfl.WorkflowStage |  |
| CycleNo | INT | لا | 1 |  |  |
| Status | VARCHAR(17) | لا |  |  | §8: مثيل المرحلة (المهمة المسندة مباشرة تُعدّ CLAIMED) enum: QUEUED, CLAIMED, AWAITING_APPROVAL, DONE, RETURNED, REJECTED, CANCELLED |
| EnteredAt | DATETIME2(3) | لا |  |  |  |
| QueuedAt | DATETIME2(3) | نعم |  |  |  |
| ClaimedAt | DATETIME2(3) | نعم |  |  |  |
| ExitedAt | DATETIME2(3) | نعم |  |  |  |
| ExitAction | VARCHAR(10) | نعم |  |  | الإجراء الذي أنهى المرحلة enum: SUBMIT, APPROVE, COMPLETE, RETURN, REJECT, CANCEL, RESUBMIT |
| AssigneeUserId | BIGINT | نعم |  | sec.AppUser |  |
| DueAt | DATETIME2(3) | نعم |  |  |  |
| ClaimDueAt | DATETIME2(3) | نعم |  |  | مهلة السحب (ClaimSlaHours) من QueuedAt (BR-WFL-012) |
| SlaPausedSeconds | INT | لا | 0 |  | مجموع الإيقاف في حالات PausesSla (BR-WFL-010) |
| SlaState | VARCHAR(10) | لا | NONE |  | enum: ON_TRACK, AT_RISK, OVERDUE, PAUSED, NONE |
| SlaMet | BIT | نعم |  |  | نتيجة SLA عند الخروج: 1 قبل DueAt · 0 بعده · فارغ بلا SLA (§8، R-WFL-01) |
| ReleaseCount | INT | لا | 0 |  | التحرير لا يصفّر قِدَم الطابور (BR-WFL-007) |
| ReassignCount | INT | لا | 0 |  |  |
| ResumeStageId | INT | نعم |  | wfl.WorkflowStage | مرحلة الاستئناف عند الإرجاع (FR-WFL-010) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestStageInstanceId) · UQ(TenantId, RequestId) WHERE ExitedAt IS NULL

**قيود:** `(ExitedAt IS NULL AND ExitAction IS NULL AND Status IN ('QUEUED','CLAIMED','AWAITING_APPROVAL')) OR (ExitedAt IS NOT NULL AND ExitAction IS NOT NULL AND Status IN ('DONE','RETURNED','REJECTED','CANCELLED'))` · `Status <> 'RETURNED' OR ExitAction = 'RETURN'` · `Status <> 'REJECTED' OR ExitAction = 'REJECT'` · `Status <> 'CANCELLED' OR ExitAction = 'CANCEL'` · `Status <> 'QUEUED' OR AssigneeUserId IS NULL` · `Status <> 'CLAIMED' OR AssigneeUserId IS NOT NULL` · `ClaimedAt IS NULL OR QueuedAt IS NOT NULL` · `ExitedAt IS NULL OR ExitedAt >= EnteredAt` · `QueuedAt IS NULL OR QueuedAt >= EnteredAt` · `ClaimedAt IS NULL OR QueuedAt IS NULL OR ClaimedAt >= QueuedAt` · `SlaPausedSeconds >= 0 AND ReleaseCount >= 0 AND ReassignCount >= 0` · `CycleNo >= 1`

### `wfl.RequestApproval` — خانة موافقة تُنشأ لكل دخول ودورة؛ الدورة الجديدة بخانات جديدة (BR-WFL-003، FR-WFL-007/008/011)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestApprovalId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageInstanceId | BIGINT | لا |  | wfl.RequestStageInstance (via RequestId) |  |
| CycleNo | INT | لا | 1 |  |  |
| SlotKey | VARCHAR(30) | لا |  |  | StageApprover.SlotKey وقت الإنشاء |
| AssignedUserId | BIGINT | نعم |  | sec.AppUser | مُسنَد مجمَّد (مدير الطالب · الطالب · مستخدم محدد) (BR-WFL-005) |
| AssignedRoleId | BIGINT | نعم |  | sec.Role | أو مجموعة بدور |
| Decision | VARCHAR(10) | لا | PENDING |  | §8 enum: PENDING, APPROVED, RETURNED, REJECTED, VOIDED, SUPERSEDED |
| Source | VARCHAR(10) | نعم |  |  | SUBMISSION لـ ORIGINATOR (BR-WFL-004) enum: USER, SUBMISSION, DELEGATE, SYSTEM |
| ActedByUserId | BIGINT | نعم |  | sec.AppUser |  |
| OnBehalfOfUserId | BIGINT | نعم |  | sec.AppUser | المفوِّض عند التنفيذ نيابةً (FR-WFL-020، BR-WFL-021) |
| DelegationId | BIGINT | نعم |  | wfl.UserDelegation | التفويض الذي استُند إليه |
| ActedAt | DATETIME2(3) | نعم |  |  |  |
| Comment | NVARCHAR(2000) | نعم |  |  |  |
| SnapshotHash | VARBINARY(32) | نعم |  |  | بصمة ما رآه الموافق (BR-WFL-003) |
| ClientIp | VARCHAR(45) | نعم |  |  | عنوان الشبكة لعدم الإنكار (§12) |
| AckWarningsJson | NVARCHAR(MAX) | نعم |  |  | إقرار تحذيرات شروط العملية عند WARN (FR-REQ-014، BR-REQ-010) 🔒 confidential |
| AvailabilitySnapshotJson | NVARCHAR(MAX) | نعم |  |  | ما أرجعته 12 للوحة التوفر لحظة الموافقة (FR-REQ-013) 🔒 confidential |
| OverrideRequested | BIT | لا | 0 |  | طلب تجاوز الحد المُمرَّر إلى fac.reserve_limit (BR-WFL-016) |
| OverrideReason | NVARCHAR(500) | نعم |  |  |  |
| IsSodException | BIT | لا | 0 |  | وسم استثناء فصل المهام (FR-WFL-041، BR-WFL-026) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestApprovalId) · UQ(TenantId, StageInstanceId, SlotKey)

**قيود:** `(Decision = 'PENDING' AND ActedAt IS NULL) OR (Decision <> 'PENDING' AND ActedAt IS NOT NULL)` · `AssignedUserId IS NOT NULL OR AssignedRoleId IS NOT NULL` · `Decision NOT IN ('APPROVED','RETURNED','REJECTED') OR ActedByUserId IS NOT NULL` · `Decision <> 'APPROVED' OR SnapshotHash IS NOT NULL` · `Source <> 'DELEGATE' OR (DelegationId IS NOT NULL AND OnBehalfOfUserId IS NOT NULL)` · `OverrideRequested = 0 OR OverrideReason IS NOT NULL` · `CycleNo >= 1`

### `wfl.RequestAction` — سجل إجراءات للإضافة فقط يغطي كل حدث؛ غير AuditLog الأمني (FR-WFL-033/034، §6.2)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestActionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance (via RequestId) |  |
| CycleNo | INT | نعم |  |  |  |
| ActionType | VARCHAR(18) | لا |  |  | enum: CREATED, SUBMITTED, RESUBMITTED, NUMBER_ASSIGNED, FIELD_EDITED, APPROVED, RETURNED, REJECTED, CANCELLED, STAGE_CHANGED, SUBSTATUS_CHANGED, CLAIMED, RELEASED, REASSIGNED, COMMENT_ADDED, ATTACHMENT_ADDED, ATTACHMENT_REMOVED, EXTREF_ADDED, EXTREF_CHANGED, HOOK_EXECUTED, HOOK_FAILED, SLA_AT_RISK, SLA_BREACHED, ESCALATED, DELEGATED_ACTION, CHILD_CREATED, PRIORITY_CHANGED, TEMPLATE_MIGRATED, RESERVATION_LOST, DRAFT_ARCHIVED, DRAFT_RESTORED, CHANNEL_CHANGED, SOD_EXCEPTION_USED, DELEGATION_CREATED, DELEGATION_REVOKED |
| FromStageKey | VARCHAR(40) | نعم |  |  |  |
| ToStageKey | VARCHAR(40) | نعم |  |  |  |
| ActorType | VARCHAR(10) | لا | USER |  | SYSTEM للمهام (JOB-WFL-ASSIGN) وSERVICE لمحوّلات الربط (§11) enum: USER, SYSTEM, SERVICE |
| ActorUserId | BIGINT | نعم |  | sec.AppUser | ActorId في المواصفة |
| OnBehalfOfUserId | BIGINT | نعم |  | sec.AppUser |  |
| OccurredAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| Visibility | VARCHAR(17) | لا | INTERNAL |  | الخط الزمني للطالب يعرض الظاهر فقط (BR-WFL-024) enum: INTERNAL, REQUESTER_VISIBLE |
| Comment | NVARCHAR(4000) | نعم |  |  | سبب الإرجاع/الرفض/الإلغاء أو ملاحظة |
| MetaJson | NVARCHAR(MAX) | نعم |  |  | مصدر حل المُسنَد · مدة الحالة السابقة · نتيجة الخطاف (BR-WFL-005/010) |
| SnapshotJson | NVARCHAR(MAX) | نعم |  |  | لقطة النموذج عند التقديم وإعادته (FR-WFL-011) 🔒 confidential |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| IdempotencyKey | VARCHAR(100) | نعم |  |  | Idempotency-Key للإجراء: التكرار لا ينتج أثرًا ثانيًا (FR-WFL-035، BR-WFL-023) |
| IsSodException | BIT | لا | 0 |  | وسم استثناء فصل المهام في سجل الطلب (FR-WFL-041) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestActionId) · UQ(TenantId, RequestId, IdempotencyKey) WHERE IdempotencyKey IS NOT NULL

**قيود:** `ActorType <> 'USER' OR ActorUserId IS NOT NULL` · `ActionType NOT IN ('RETURNED','REJECTED') OR Comment IS NOT NULL`

### `wfl.HookExecution` — تنفيذ خطاف بمفتاح عدم تكرار يعيد النتيجة المخزَّنة (FR-WFL-021، BR-WFL-015) -- جدول جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **HookExecutionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageInstanceId | BIGINT | لا |  | wfl.RequestStageInstance (via RequestId) |  |
| HookKey | VARCHAR(60) | لا |  |  |  |
| TriggerKind | VARCHAR(10) | لا |  |  | enum: ON_ENTER, ON_EXIT, ON_ACTION |
| ActionFilter | VARCHAR(10) | نعم |  |  | enum: SUBMIT, APPROVE, COMPLETE, RETURN, REJECT, CANCEL, RESUBMIT |
| ExecMode | VARCHAR(12) | لا |  |  | enum: SYNC_TX, AFTER_COMMIT |
| OnFailure | VARCHAR(10) | لا |  |  | enum: BLOCK, WARN |
| Status | VARCHAR(10) | لا | PENDING |  | GAVE_UP بعد 5 محاولات AFTER_COMMIT ثم ينبَّه TM enum: PENDING, SUCCEEDED, FAILED, GAVE_UP |
| AttemptCount | INT | لا | 0 |  |  |
| IdempotencyKey | VARCHAR(100) | نعم |  |  | المفتاح المُمرَّر إلى fac.* وlc.* (§5.4) |
| ResultJson | NVARCHAR(MAX) | نعم |  |  | النتيجة المخزَّنة: ReservationId · UtilizationId · LcId … |
| ErrorCode | VARCHAR(60) | نعم |  |  | INSUFFICIENT_AVAILABLE · LIMIT_NOT_ACTIVE · … |
| LastError | NVARCHAR(1000) | نعم |  |  |  |
| ExecutedAt | DATETIME2(3) | نعم |  |  |  |
| NextAttemptAt | DATETIME2(3) | نعم |  |  |  |
| TmNotifiedAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(HookExecutionId) · UQ(TenantId, RequestId, StageInstanceId, HookKey, TriggerKind)

**قيود:** `AttemptCount >= 0` · `Status <> 'SUCCEEDED' OR ExecutedAt IS NOT NULL` · `Status <> 'GAVE_UP' OR (ExecMode = 'AFTER_COMMIT' AND AttemptCount >= 5)`

### `wfl.UserDelegation` — تفويض مهام بفترة ونطاق؛ لا تفويض متسلسل (FR-WFL-020، BR-WFL-021، V-WFL-06)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UserDelegationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FromUserId | BIGINT | لا |  | sec.AppUser | المفوِّض |
| ToUserId | BIGINT | لا |  | sec.AppUser | المفوَّض |
| StartsOn | DATE | لا |  |  |  |
| EndsOn | DATE | لا |  |  | أقصى مدة 90 يومًا قابلة للضبط (BR-WFL-021، BR-WFL-025) يتحقق منها التطبيق |
| Scope | VARCHAR(14) | لا | ALL |  | enum: ALL, APPROVALS_ONLY, REQUEST_TYPE |
| RequestTypeId | INT | نعم |  | wfl.RequestType |  |
| Reason | NVARCHAR(500) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | SCHEDULED |  | §8، JOB-WFL-DELEGATION enum: SCHEDULED, ACTIVE, ENDED, REVOKED |
| RevokedAt | DATETIME2(3) | نعم |  |  | الإلغاء فوري (BR-WFL-021) |
| RevokedBy | BIGINT | نعم |  | sec.AppUser |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UserDelegationId) · UQ(PublicId)

**قيود:** `FromUserId <> ToUserId` · `EndsOn >= StartsOn` · `(Scope = 'REQUEST_TYPE' AND RequestTypeId IS NOT NULL) OR (Scope <> 'REQUEST_TYPE' AND RequestTypeId IS NULL)` · `(Status = 'REVOKED' AND RevokedAt IS NOT NULL) OR (Status <> 'REVOKED' AND RevokedAt IS NULL)`

## NTF

### `ntf.NotificationEventType` — كتالوج الأحداث؛ تملكه 13 لكل الوحدات وتبذر فيه الوحدات أحداثها (FR-NTF-001، §9.2، §9.2-ب)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationEventTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(60) | لا |  |  | مثل REQ.APPROVAL_NEEDED · LC.ISSUED · FAC.EXPIRY_DUE |
| OwnerModule | VARCHAR(20) | لا |  |  | WFL · REQ · LCI · LCE · FAC · OBL · COL · CMP · FIN · ORG · PTY · ACC · INS · CAT · PLT · NTF (قد يتعدد في §9.2) |
| GroupKey | VARCHAR(30) | لا |  |  | مجموعة التفضيلات والملخصات (FR-NTF-010) |
| NameAr | NVARCHAR(200) | نعم |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| DefaultSeverity | VARCHAR(10) | لا | INFO |  | enum: INFO, WARNING, HIGH |
| IsMandatory | BIT | لا | 0 |  | «إ»: لا إيقاف في التطبيق؛ المصدر الوحيد للعلم (BR-NTF-003) |
| IsActionRequired | BIT | لا | 0 |  | «ط»: ينشئ إشعار «يلزم إجراء» (BR-NTF-007) |
| DefaultChannels | NVARCHAR(MAX) | نعم |  |  | مثل ["IN_APP","EMAIL"] (BR-NTF-014) |
| AllowedPlaceholdersJson | NVARCHAR(MAX) | نعم |  |  | القائمة البيضاء للعناصر النائبة (BR-NTF-008، V-NTF-01) |
| DedupWindowMinutes | INT | نعم |  |  |  |
| CoalesceWindowMinutes | INT | نعم |  |  | دمج الأحداث المتقاربة (BR-NTF-005) |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationEventTypeId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code LIKE '%.%'` · `NameAr IS NOT NULL OR NameEn IS NOT NULL` · `DedupWindowMinutes IS NULL OR DedupWindowMinutes >= 0` · `CoalesceWindowMinutes IS NULL OR CoalesceWindowMinutes = 0 OR (IsMandatory = 0 AND DefaultSeverity <> 'HIGH')`

### `ntf.NotificationRule` — قاعدة مستلمين لحدث؛ التعديل يسري على الأحداث التالية فقط (FR-NTF-003، BR-NTF-001، V-NTF-02)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationRuleId** | INT IDENTITY | لا | | | مفتاح أساسي |
| EventTypeId | INT | لا |  | ntf.NotificationEventType |  |
| RecipientKind | VARCHAR(17) | لا |  |  | enum: ROLE, PERMISSION, USER, REQUESTER, REQUESTER_MANAGER, ASSIGNEE, STAGE_APPROVERS, DEPARTMENT_HEAD |
| RoleId | BIGINT | نعم |  | sec.Role | RecipientRef للنوع ROLE |
| PermissionId | INT | نعم |  | sec.Permission | RecipientRef للنوع PERMISSION (مثل req.claim) |
| UserId | BIGINT | نعم |  | sec.AppUser | RecipientRef للنوع USER |
| ConditionJson | NVARCHAR(MAX) | نعم |  |  |  |
| RequireCompanyScope | BIT | لا | 1 |  | الحدث بلا شركة يتجاوز الخطوة (BR-NTF-001) |
| ChannelsOverride | NVARCHAR(MAX) | نعم |  |  |  |
| IsMandatory | BIT | لا | 0 |  | لا يزيله TA (V-NTF-02) |
| IsActive | BIT | لا | 1 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationRuleId) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(RecipientKind = 'ROLE' AND RoleId IS NOT NULL AND PermissionId IS NULL AND UserId IS NULL) OR (RecipientKind = 'PERMISSION' AND PermissionId IS NOT NULL AND RoleId IS NULL AND UserId IS NULL) OR (RecipientKind = 'USER' AND UserId IS NOT NULL AND RoleId IS NULL AND PermissionId IS NULL) OR (RecipientKind NOT IN ('ROLE','PERMISSION','USER') AND RoleId IS NULL AND PermissionId IS NULL AND UserId IS NULL)` · `IsMandatory = 0 OR IsActive = 1`

### `ntf.NotificationTemplate` — قالب رسالة لكل (حدث، قناة، لغة)؛ الحذف = العودة إلى قالب البذرة (FR-NTF-012، FR-NTF-025)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationTemplateId** | INT IDENTITY | لا | | | مفتاح أساسي |
| EventTypeId | INT | لا |  | ntf.NotificationEventType |  |
| Channel | VARCHAR(10) | لا |  |  | enum: IN_APP, EMAIL |
| Lang | VARCHAR(10) | لا |  |  | enum: ar, en |
| SubjectTemplate | NVARCHAR(300) | لا |  |  | عنوان الإشعار؛ عناصر نائبة من القائمة البيضاء فقط |
| BodyTemplate | NVARCHAR(MAX) | لا |  |  |  |
| IsTenantOverride | BIT | لا | 0 |  | 0 = بذرة المنصة · 1 = تجاوز المشترك |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationTemplateId) · UQ(TenantId, EventTypeId, Channel, Lang, IsTenantOverride)

### `ntf.NotificationPreference` — تفضيل المستخدم لكل مجموعة أحداث وقناة (FR-NTF-010، BR-NTF-003/014)؛ الإلزامي لا يُوقَف في التطبيق

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationPreferenceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| GroupKey | VARCHAR(30) | لا |  |  | = NotificationEventType.GroupKey |
| Channel | VARCHAR(10) | لا |  |  | enum: IN_APP, EMAIL |
| Mode | VARCHAR(13) | لا | IMMEDIATE |  | enum: IMMEDIATE, DIGEST_DAILY, DIGEST_WEEKLY, OFF |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationPreferenceId) · UQ(TenantId, UserId, GroupKey, Channel)

### `ntf.DigestBatch` — دفعة ملخص لمستخدم وقناة وفترة؛ لا يُرسل فارغًا (FR-NTF-014، BR-NTF-004، JOB-NTF-DIGEST) -- جدول جديد يحل DigestBatchId

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DigestBatchId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| Channel | VARCHAR(10) | لا | EMAIL |  | enum: IN_APP, EMAIL |
| Kind | VARCHAR(10) | لا |  |  | يوميًا 07:30 وأسبوعيًا الأحد 07:30 بتوقيت المشترك (Q-NTF-02) enum: DAILY, WEEKLY |
| PeriodStart | DATETIME2(3) | لا |  |  |  |
| PeriodEnd | DATETIME2(3) | لا |  |  |  |
| Status | VARCHAR(13) | لا | PENDING |  | enum: PENDING, SENT, SKIPPED_EMPTY, FAILED |
| ItemCount | INT | لا | 0 |  |  |
| GroupSummaryJson | NVARCHAR(MAX) | نعم |  |  | لكل مجموعة: عدّاد وأعلى 5 عناصر ورابط (BR-NTF-004) |
| ScheduledFor | DATETIME2(3) | نعم |  |  |  |
| SentAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DigestBatchId) · UQ(TenantId, UserId, Channel, Kind, PeriodEnd)

**قيود:** `PeriodEnd > PeriodStart` · `ItemCount >= 0` · `Status <> 'SENT' OR (SentAt IS NOT NULL AND ItemCount > 0)` · `Status <> 'SKIPPED_EMPTY' OR ItemCount = 0`

### `ntf.Notification` — إشعار لمستخدم؛ المحتوى بلا قيم مقيّدة (FR-NTF-005/006/007/021، BR-NTF-001/002/007/008/011)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| EventTypeId | INT | لا |  | ntf.NotificationEventType |  |
| CompanyId | BIGINT | نعم |  | org.Company | فارغ للحدث بلا شركة |
| Severity | VARCHAR(10) | لا |  |  | enum: INFO, WARNING, HIGH |
| Title | NVARCHAR(300) | لا |  |  | بلغة المستلم من القالب (FR-NTF-024) |
| Body | NVARCHAR(2000) | لا |  |  |  |
| TargetEntityType | VARCHAR(60) | لا |  |  | هدف الرابط العميق؛ يتحقق من الصلاحية عند الفتح (FR-NTF-005) |
| TargetEntityId | BIGINT | لا |  |  |  |
| DeepLink | NVARCHAR(300) | نعم |  |  |  |
| ActionRequired | BIT | لا | 0 |  |  |
| ActionState | VARCHAR(10) | لا | NONE |  | §8؛ RESOLVED لا يُحتسب في «يلزم إجراء» (BR-NTF-007) enum: NONE, OPEN, RESOLVED |
| ResolvedAt | DATETIME2(3) | نعم |  |  |  |
| ReadAt | DATETIME2(3) | نعم |  |  | القراءة: UNREAD → READ → ARCHIVED (§8) |
| ArchivedAt | DATETIME2(3) | نعم |  |  | الإلزامي غير المقروء لا يُؤرشف آليًا (BR-NTF-011) |
| DedupKey | VARCHAR(200) | نعم |  |  | {EventCode}:{TargetType}:{TargetId}:{Threshold/Cycle}:{ItemVersion} (BR-NTF-002) |
| CoalescedCount | INT | لا | 1 |  | دمج 15 دقيقة (BR-NTF-005) |
| ReminderCount | INT | لا | 0 |  | تذكير 24/48/72 ساعة عمل بحد 3 (BR-NTF-006) |
| NextReminderAt | DATETIME2(3) | نعم |  |  | يحسبها AddBusinessHours؛ المهمة تعتمد حدثًا مخزَّنًا (BR-NTF-010) |
| PayloadJson | NVARCHAR(MAX) | نعم |  |  | معرّفات فقط (FR-NTF-002/021) |
| SourceEventId | UNIQUEIDENTIFIER | نعم |  |  | = cfg.OutboxEvent.MessageId؛ بلا FK لأن الصندوق قابل للحذف |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationId) · UQ(PublicId) · UQ(TenantId, UserId, DedupKey) WHERE DedupKey IS NOT NULL

**قيود:** `(ActionRequired = 0 AND ActionState = 'NONE') OR (ActionRequired = 1 AND ActionState IN ('OPEN','RESOLVED'))` · `(ActionState = 'RESOLVED' AND ResolvedAt IS NOT NULL) OR (ActionState <> 'RESOLVED' AND ResolvedAt IS NULL)` · `CoalescedCount >= 1` · `ReminderCount >= 0 AND ReminderCount <= 3` · `NextReminderAt IS NULL OR ActionState = 'OPEN'`

### `ntf.NotificationDelivery` — تسليم الإشعار لكل قناة بحالاته وإعادة المحاولة (FR-NTF-019، BR-NTF-009، §8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **NotificationDeliveryId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| NotificationId | BIGINT | لا |  | ntf.Notification |  |
| Channel | VARCHAR(10) | لا |  |  | enum: IN_APP, EMAIL |
| Status | VARCHAR(10) | لا | PENDING |  | enum: PENDING, SENT, FAILED, DEAD, SUPPRESSED, DIGESTED |
| Attempts | INT | لا | 0 |  | التراجع: 1د · 5د · 30د · 2س · 12س ثم DEAD (BR-NTF-009) |
| NextAttemptAt | DATETIME2(3) | نعم |  |  |  |
| SentAt | DATETIME2(3) | نعم |  |  |  |
| DigestBatchId | BIGINT | نعم |  | ntf.DigestBatch |  |
| ProviderMessageId | VARCHAR(200) | نعم |  |  |  |
| LastError | NVARCHAR(500) | نعم |  |  | بلا بيانات شخصية |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(NotificationDeliveryId) · UQ(TenantId, NotificationId, Channel)

**قيود:** `Attempts >= 0` · `Status = 'SENT' OR SentAt IS NULL` · `Status <> 'SENT' OR SentAt IS NOT NULL` · `Status <> 'FAILED' OR NextAttemptAt IS NOT NULL` · `Status <> 'DIGESTED' OR DigestBatchId IS NOT NULL` · `DigestBatchId IS NULL OR Status IN ('DIGESTED','SENT')`

## LC

### `ref.Incoterm` — مصطلح تسليم Incoterms: مرجع عالمي للقراءة فقط يديره المشغّل؛ القديم LEGACY للعرض لا للاختيار (FR-LCT-013، FR-CAT-021، BR-CAT-015)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **IncotermId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | CHAR(3) | لا |  |  | EXW FCA CPT CIP DAP DPU DDP FAS FOB CFR CIF (2020) + القديمة DAT DAF DES DEQ DDU |
| NameEn | NVARCHAR(100) | لا |  |  |  |
| NameAr | NVARCHAR(100) | نعم |  |  |  |
| RulesVersion | VARCHAR(10) | لا | '2020' |  | إصدار قواعد ICC: 2020 للنشطة وأقدم للقديمة |
| Status | VARCHAR(10) | لا | ACTIVE |  | LEGACY لا يُختار في جديد ويُعرض في القديم enum: ACTIVE, LEGACY |
| IsSeaOnly | BIT | لا | 0 |  | بحري/نهري فقط FAS FOB CFR CIF: مع وسيلة غير SEA تحذير V-LCT-08 (BR-LCT-010) |
| RequiresInsurance | BIT | لا | 0 |  | CIF/CIP: يُقترح BENEFICIARY وتلزم وثيقة تأمين (BR-LCT-010) |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IncotermId) · UQ(Code)

**قيود:** `Code NOT LIKE '%[^A-Z]%'`

### `ref.UcpArticle` — مادة UCP 600 مرجعية: TenantId الفارغ = صف عام للقراءة فقط ينشره المشغّل وحده (FR-LCT-006، BR-LCT-018، BR-PLT-001)

*مختلط النطاق*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **UcpArticleId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Version | VARCHAR(10) | لا | UCP600 |  | إصدار القواعد |
| ArticleNo | VARCHAR(10) | لا |  |  | رقم المادة (1..39)؛ الفقرة (أ/ب/ج) تُحفظ في وسيط المرجع لا هنا |
| TitleAr | NVARCHAR(300) | لا |  |  |  |
| TitleEn | NVARCHAR(300) | لا |  |  |  |
| TopicAr | NVARCHAR(200) | نعم |  |  |  |
| VerificationStatus | VARCHAR(10) | لا | UNVERIFIED |  | UNVERIFIED تُظهر الشارة والحاشية ولا تُطفأ ما دامت مادة مستخدمة غير مُتحقَّق (BR-LCT-018) enum: UNVERIFIED, VERIFIED |
| VerifiedBy | INT | نعم |  | plat.PlatformOperator | مشغّل المنصة وحده يملك lc.ucp.verify |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| VerifierNote | NVARCHAR(MAX) | نعم |  |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UcpArticleId) · UQ(TenantId, Version, ArticleNo) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `VerificationStatus <> 'VERIFIED' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `VerificationStatus = 'VERIFIED' OR (VerifiedBy IS NULL AND VerifiedOn IS NULL)`

### `lc.LcFieldDefinition` — تعريف حقل في شروط الاعتماد: بيانات تُبذر لكل مشترك (FR-LCT-004، BR-LCT-002)؛ مراجع UCP في lc.LcFieldUcpRef

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcFieldDefinitionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FieldKey | VARCHAR(60) | لا |  |  | مفتاح الحقل كما في قاموس §6.2 (lcType, expiryRule, ...) |
| SectionKey | VARCHAR(40) | لا |  |  | قسم المحرر (PAYMENT, PARTIES, AMOUNT, DATES, SHIPPING, GOODS, DOCUMENTS, CHARGES, TREASURY, PREVIOUS_LC) |
| LabelAr | NVARCHAR(200) | لا |  |  |  |
| LabelEn | NVARCHAR(200) | لا |  |  |  |
| HelpAr | NVARCHAR(500) | نعم |  |  |  |
| HelpEn | NVARCHAR(500) | نعم |  |  |  |
| DataType | VARCHAR(10) | لا |  |  | قيم مشتقة من نوع القاموس: المواصفة لا تعدّدها enum: STRING, TEXT, INT, DECIMAL, DATE, BOOL, ENUM, LIST, REF, COMPUTED |
| ListCode | VARCHAR(80) | نعم |  |  | رمز قائمة القيم cat.LookupList.Code للنوع LIST/ENUM |
| ApplicabilityJson | NVARCHAR(MAX) | لا |  |  | {LcClass:{Scope:{Purpose: REQUIRED/OPTIONAL/HIDDEN}}} (BR-LCT-002) |
| VisibleToRequester | BIT | لا | 1 |  | حقل الخزينة = 0: لا يراه الطالب (FR-LCT-021، BR-LCI-014) |
| IsLocked | BIT | لا | 0 |  | المقفل لا يقبل HIDDEN ولا يعدّله المشترك (FR-LCT-004) |
| SwiftTagHint | VARCHAR(10) | نعم |  |  | إرشادي لربط MT700/707 لاحقًا (FR-LCT-035) |
| ValidationJson | NVARCHAR(MAX) | نعم |  |  |  |
| DefaultValue | NVARCHAR(500) | نعم |  |  |  |
| SortOrder | INT | لا | 0 |  |  |
| IsActive | BIT | لا | 1 |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcFieldDefinitionId) · UQ(TenantId, FieldKey) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `FieldKey NOT LIKE '% %'` · `IsLocked = 0 OR IsActive = 1` · `ListCode IS NULL OR DataType IN ('LIST','ENUM')`

### `lc.LcFieldUcpRef` — مرجع UCP لحقل: مادة + فقرة (UcpRefs في المواصفة)؛ يغذّي الشارة وR-LCT-01 وBR-LCT-018 -- وسيط جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcFieldUcpRefId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcFieldDefinitionId | BIGINT | لا |  | lc.LcFieldDefinition |  |
| UcpArticleId | INT | لا |  | ref.UcpArticle |  |
| Paragraph | NVARCHAR(20) | نعم |  |  | الفقرة مثل «ب» أو «أ-3» (6-ب، 7-أ-3)؛ الفارغ = المادة كلها |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcFieldUcpRefId) · UQ(TenantId, LcFieldDefinitionId, UcpArticleId, Paragraph)

### `lc.Counterparty` — الطرف المقابل: مورّد/عميل خفيف بلا هوية؛ يُرقّى إلى Party عند الحاجة (FR-LCT-036/037، BR-LCT-022، Q-PTY-03)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CounterpartyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(20) | لا |  |  | يُولَّد تلقائيًا (BR-LCT-022) |
| Kind | VARCHAR(10) | لا |  |  | enum: SUPPLIER, CUSTOMER, BOTH |
| NameEn | NVARCHAR(300) | لا |  |  |  |
| NameAr | NVARCHAR(300) | نعم |  |  |  |
| NameNormalized | NVARCHAR(300) | لا |  |  | اسم مطبَّع بتطبيع عربي (BR-PTY-004) لبحث الاسم وتحذير تكرار الاسم + البلد (BR-LCT-022) |
| CountryId | INT | لا |  | ref.Country |  |
| City | NVARCHAR(100) | نعم |  |  |  |
| AddressLine | NVARCHAR(300) | نعم |  |  |  |
| PoBox | NVARCHAR(30) | نعم |  |  |  |
| PostalCode | NVARCHAR(20) | نعم |  |  |  |
| Phone | NVARCHAR(40) | نعم |  |  | وسائل الاتصال: سرّية تجارية 🔒 confidential |
| Fax | NVARCHAR(40) | نعم |  |  | 🔒 confidential |
| Email | NVARCHAR(254) | نعم |  |  | 🔒 confidential |
| ErpCode | NVARCHAR(40) | نعم |  |  | رمز ERP (حساب الذمم/المورّد) نصي يدوي قابل للبحث |
| ErpCodeNormalized | NVARCHAR(40) | نعم |  |  | مطبَّع: أرقام عربية-هندية → لاتينية + حروف كبيرة + بلا فراغات (BR-REQ-006) |
| TaxNumber | NVARCHAR(50) | نعم |  |  |  |
| PartyId | BIGINT | نعم |  | pty.Party | فارغ ما لم يُرقَّ؛ عند التعبئة يصير مزوّد استخدام Party (FR-LCT-037، BR-PTY-001) |
| MergedIntoId | BIGINT | نعم |  | lc.Counterparty | الدمج: الباقي بعد إعادة توجيه الاعتمادات والبروفورمات (BR-LCT-022) |
| IsActive | BIT | لا | 1 |  | التعطيل لا الحذف عند وجود مراجع |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CounterpartyId) · UQ(PublicId) · UQ(TenantId, Code)

**قيود:** `ErpCode IS NULL OR ErpCodeNormalized IS NOT NULL` · `MergedIntoId IS NULL OR (MergedIntoId <> CounterpartyId AND IsActive = 0)`

### `lc.LcDocumentClause` — مكتبة بنود المستندات بإصدارات: نص قالب بمعاملات (FR-LCT-017..019، BR-LCT-012)؛ مراجع UCP في lc.LcDocumentClauseUcpRef

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDocumentClauseId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  | COMMERCIAL_INVOICE DELIVERY_NOTE BL_SEA AWB_AIR ROAD_CONSIGNMENT MULTIMODAL_TD INSURANCE_POLICY CERT_ORIGIN PACKING_LIST WEIGHT_CERT BENEFICIARY_CERT_CONTAINER_LABEL FCR OTHER_FREE_TEXT |
| VersionNo | INT | لا | 1 |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Category | VARCHAR(20) | لا |  |  | enum: COMMERCIAL_INVOICE, DELIVERY_NOTE, TRANSPORT_SEA, TRANSPORT_AIR, TRANSPORT_ROAD, TRANSPORT_MULTIMODAL, INSURANCE, ORIGIN, PACKING, WEIGHT, BENEFICIARY_CERT, FCR, OTHER |
| Scope | VARCHAR(13) | لا | ANY |  | enum: ANY, DOMESTIC, INTERNATIONAL |
| ApplicableModes | NVARCHAR(MAX) | نعم |  |  | أكواد TRANSPORT_MODE التي يُقترح لها البند (BR-LCT-013) |
| TemplateTextEn | NVARCHAR(MAX) | لا |  |  | نص القالب بعناصر نائبة {param} (BR-LCT-012) |
| TemplateTextAr | NVARCHAR(MAX) | لا |  |  |  |
| ParamSchemaJson | NVARCHAR(MAX) | لا |  |  | مخطط المعاملات: النوع والإلزام والقيم المسموحة |
| DefaultOriginals | INT | نعم |  |  |  |
| DefaultCopies | INT | نعم |  |  |  |
| InstitutionId | BIGINT | نعم |  | ins.Institution | تخصيص لبنك (Q-LCT-09)؛ فارغ = عام للمشترك |
| LegalReviewStatus | VARCHAR(10) | لا | UNREVIEWED |  | UNREVIEWED تطبع لافتة «لم تُراجَع قانونيًا» (FR-LCT-019) enum: UNREVIEWED, REVIEWED |
| ReviewedByText | NVARCHAR(200) | نعم |  |  |  |
| ReviewedOn | DATE | نعم |  |  |  |
| Status | VARCHAR(10) | لا | ACTIVE |  | enum: ACTIVE, RETIRED |
| SeedKey | VARCHAR(80) | نعم |  |  | المبذور 13 بندًا (11 من 02 B29..B39 + DELIVERY_NOTE + MULTIMODAL_TD) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDocumentClauseId) · UQ(PublicId) · UQ(TenantId, Code, VersionNo) · UQ(TenantId, SeedKey, VersionNo) WHERE SeedKey IS NOT NULL

**قيود:** `Code NOT LIKE '%[^A-Z0-9_]%'` · `VersionNo >= 1` · `DefaultOriginals IS NULL OR DefaultOriginals >= 0` · `DefaultCopies IS NULL OR DefaultCopies >= 0` · `LegalReviewStatus <> 'REVIEWED' OR (ReviewedByText IS NOT NULL AND ReviewedOn IS NOT NULL)`

### `lc.LcDocumentClauseUcpRef` — مرجع UCP لبند مستند: مادة + فقرة (UcpRefs في المواصفة) -- وسيط جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDocumentClauseUcpRefId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcDocumentClauseId | BIGINT | لا |  | lc.LcDocumentClause |  |
| UcpArticleId | INT | لا |  | ref.UcpArticle |  |
| Paragraph | NVARCHAR(20) | نعم |  |  | الفقرة؛ الفارغ = المادة كلها |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDocumentClauseUcpRefId) · UQ(TenantId, LcDocumentClauseId, UcpArticleId, Paragraph)

### `lc.LcTerms` — إصدار شروط اعتماد: صف لكل نسخة بأعمدة قاموس §6.2؛ مشترك بين البروفورما والطلب والاعتماد والتعديل (FR-LCT-001..035)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcTermsId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OwnerType | VARCHAR(16) | لا |  |  | enum: REQUEST, PROFORMA, LETTER_OF_CREDIT, AMENDMENT |
| OwnerId | BIGINT | نعم |  |  | معرّف المالك متعدد الأشكال بلا FK؛ إلزامي لـ REQUEST ويُعبَّأ لغيره بعد إنشاء المالك في المعاملة نفسها |
| Purpose | VARCHAR(11) | لا |  |  | ما نطلبه من العميل / من البنك / الصادر / المستلَم / لقطة التعديل enum: PROFORMA, APPLICATION, ISSUED, RECEIVED, AMENDMENT |
| VersionNo | INT | لا | 1 |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | DRAFT → LOCKED → SUPERSEDED؛ لا رجوع من LOCKED (§8) enum: DRAFT, LOCKED, SUPERSEDED |
| FieldSetVersion | INT | لا | 1 |  | رقم إصدار تعريفات الحقول وقت الحفظ ليبقى العرض ممكنًا (§6.1) |
| LcClass | VARCHAR(10) | لا |  |  | A1: من نوع المالك enum: PURCHASE, SALES |
| Scope | VARCHAR(13) | لا |  |  | A2: يُشتق من البلدين ويجوز تجاوزه بسبب (BR-LCT-001) enum: DOMESTIC, INTERNATIONAL |
| ScopeOverrideReason | NVARCHAR(500) | نعم |  |  |  |
| UcpVersion | VARCHAR(10) | لا | UCP600 |  | A3: ثابت لا يُحرَّر enum: UCP600 |
| LcType | VARCHAR(16) | نعم |  |  | A4 (LC_TYPE) enum: SIGHT, DEFERRED_PAYMENT, ACCEPTANCE, NEGOTIATION, MIXED |
| DeferralDays | INT | نعم |  |  | A5: 1..720؛ فارغ لـ SIGHT (BR-LCT-009) |
| MaturityBasis | VARCHAR(22) | نعم |  |  | A6: الخمسة (BR-LCT-008) enum: SHIPMENT_DATE, DELIVERY_NOTE_DATE, INVOICE_DATE, DOCUMENTS_RECEIPT_DATE, ACCEPTANCE_DATE |
| MixedPaymentText | NVARCHAR(500) | نعم |  |  | A7: وصف التقسيم لـ MIXED |
| AvailableWith | VARCHAR(14) | نعم | ADVISING_BANK |  | A8 enum: ISSUING_BANK, ADVISING_BANK, NOMINATED_BANK, ANY_BANK |
| DraftRequired | BIT | نعم |  |  | A9: SIGHT قد لا تتطلب كمبيالة؛ القبول والتداول يتطلبانها (BR-LCT-011) |
| DraftDrawee | VARCHAR(15) | نعم |  |  | المسحوب عليه لا يكون الطالب أبدًا (6-ج، V-LCT-03) فالقائمة تستبعده enum: ISSUING_BANK, ADVISING_BANK, CONFIRMING_BANK |
| Confirmation | VARCHAR(10) | نعم |  |  | A10 (LC_CONFIRMATION)؛ المحلي WITHOUT افتراضيًا (V-LCT-17 تحذير) enum: CONFIRMED, MAY_ADD, WITHOUT |
| ConfirmingBankName | NVARCHAR(200) | نعم |  |  | A11 |
| ConfirmingBankBic | VARCHAR(11) | نعم |  |  |  |
| ApplicantCompanyId | BIGINT | نعم |  | org.Company | B1: الطالب شركتنا في المشتريات |
| ApplicantCounterpartyId | BIGINT | نعم |  | lc.Counterparty | B1: الطالب عميلنا في المبيعات |
| BeneficiaryCompanyId | BIGINT | نعم |  | org.Company | B2: المستفيد شركتنا في المبيعات |
| BeneficiaryCounterpartyId | BIGINT | نعم |  | lc.Counterparty | B2: المستفيد المورّد في المشتريات |
| BeneficiaryAccountIbanEnc | VARBINARY(512) | نعم |  |  | B3: IBAN المستفيد مشفّر (FR-REQ-024؛ 02 B9 🔴) 🔒 restricted |
| BeneficiaryAccountIbanMask | NVARCHAR(40) | نعم |  |  | 🔒 restricted |
| BeneficiaryAccountIbanHash | VARBINARY(32) | نعم |  |  | 🔒 restricted |
| AdvisingBankName | NVARCHAR(200) | نعم |  |  | B4 (د عدا PF) |
| AdvisingBankAddress | NVARCHAR(300) | نعم |  |  |  |
| AdvisingBankBic | VARCHAR(11) | نعم |  |  |  |
| CurrencyId | INT | نعم |  | ref.Currency | C1 |
| Amount | DECIMAL(19,4) | نعم |  |  | C2: > 0 بخانات العملة |
| AmountInWordsAr | NVARCHAR(1000) | نعم |  |  | C3: مولَّد لا يُحرَّر ويُجمَّد عند القفل (BR-LCT-003) |
| AmountInWordsEn | NVARCHAR(1000) | نعم |  |  |  |
| ToleranceMode | VARCHAR(10) | لا | NONE |  | C4: ABOUT = ±10 ثابتة (مادة 30) enum: NONE, ABOUT, PLUS_MINUS |
| TolerancePlusPct | DECIMAL(9,6) | لا | 0 |  |  |
| ToleranceMinusPct | DECIMAL(9,6) | لا | 0 |  |  |
| ExpiryRule | VARCHAR(16) | نعم |  |  | D1 (BR-LCT-005) enum: ABSOLUTE, DAYS_AFTER_ISSUE |
| ExpiryDate | DATE | نعم |  |  | المطلق؛ ويُحسب للنسبي حين يُعرف تاريخ الإصدار |
| ExpiryDateHijri | NVARCHAR(20) | نعم |  |  | النص الهجري المُدخل كما هو (FR-LCT-032) |
| ExpiryDaysAfterIssue | INT | نعم |  |  |  |
| ExpiryPlace | NVARCHAR(200) | نعم |  |  | D2 |
| EarliestShipmentDate | DATE | نعم |  |  | D3 |
| LatestShipmentRule | VARCHAR(16) | نعم |  |  | D4 (BR-LCT-006) enum: ABSOLUTE, DAYS_AFTER_ISSUE |
| LatestShipmentDate | DATE | نعم |  |  |  |
| LatestShipmentDateHijri | NVARCHAR(20) | نعم |  |  | FR-LCT-032 |
| LatestShipmentDaysAfterIssue | INT | نعم |  |  |  |
| PresentationDays | INT | نعم | 21 |  | D5: 1..90؛ فوق 21 تحذير V-LCT-16 (lc.presentation.default_days) |
| PresentationBasis | VARCHAR(18) | نعم |  |  | D6 (BR-LCT-008) enum: SHIPMENT_DATE, DELIVERY_NOTE_DATE, INVOICE_DATE |
| ExpectedIssueDate | DATE | نعم |  |  | D7: لحساب النسبي والإخطار قبل الإصدار |
| PartialShipments | VARCHAR(11) | نعم | ALLOWED |  | E1 enum: ALLOWED, NOT_ALLOWED |
| InstallmentShipments | NVARCHAR(300) | نعم |  |  | E2 |
| Transhipment | VARCHAR(14) | نعم |  |  | E3: المحلي NOT_APPLICABLE enum: ALLOWED, NOT_ALLOWED, NOT_APPLICABLE |
| TransportMode | VARCHAR(17) | نعم |  |  | E4 (TRANSPORT_MODE) enum: SEA, AIR, ROAD, RAIL, COURIER, MULTIMODAL, DOMESTIC_DELIVERY |
| PlaceOfDispatch | NVARCHAR(150) | نعم |  |  | E5: مكان الاستلام (02 A12) |
| PlaceOfFinalDestination | NVARCHAR(150) | نعم |  |  | E5: مكان التسليم |
| PortOfLoading | NVARCHAR(150) | نعم |  |  | E6 (SEA دولي) |
| PortOfDischarge | NVARCHAR(150) | نعم |  |  |  |
| AirportOfDeparture | NVARCHAR(150) | نعم |  |  | E7 (AIR) |
| AirportOfDestination | NVARCHAR(150) | نعم |  |  |  |
| IncotermId | INT | نعم |  | ref.Incoterm | E8: النشط فقط في الجديد (V-LCT-09) |
| IncotermPlace | NVARCHAR(150) | نعم |  |  | نقطة التسمية (BR-LCT-010) |
| GoodsCategory | VARCHAR(80) | نعم |  |  | F1: رمز بند من GOODS_CATEGORY (قائمة قابلة للتعديل) |
| GoodsDescription | NVARCHAR(2000) | نعم |  |  | F2: يطابق وصف الفاتورة |
| SupplierProformaNo | NVARCHAR(60) | نعم |  |  | F3 |
| SupplierProformaDate | DATE | نعم |  |  |  |
| InsuranceResponsibility | VARCHAR(21) | نعم |  |  | F4: يُقترح من Incoterm (BR-LCT-010) enum: BENEFICIARY, APPLICANT, NOT_REQUIRED_BY_TERMS |
| InsuranceMinPct | DECIMAL(9,6) | نعم |  |  | F5: الافتراضي 110 حين InsurancePctStated=0؛ المنصوص عليه يحلّ محله |
| InsurancePctStated | BIT | لا | 0 |  | 1 = النسبة منصوص عليها في الاعتماد نفسه (V-LCT-04: تحذير بدل خطأ) |
| InsuranceClauses | NVARCHAR(300) | نعم |  |  | F6 |
| BankMayArrangeInsurance | BIT | نعم |  |  | تفويض البنك بترتيب بوليصة (02 B28) |
| AdditionalConditions | NVARCHAR(2000) | نعم |  |  | G2: تحذير لشرط بلا مستند (V-LCT-18) |
| IsTransferable | BIT | نعم |  |  | H1 (Could) |
| AssignmentOfProceedsText | NVARCHAR(500) | نعم |  |  |  |
| LcTextLanguage | VARCHAR(10) | لا | EN |  | H2: لغة تصيير البنود والطباعة (FR-LCT-033) enum: EN, AR, BOTH |
| MarginPct | DECIMAL(9,6) | نعم |  |  | I1 خزينة: 0..100؛ الافتراضي من CashCoverPct (BR-LCT-015) |
| DebitAuthorization | VARCHAR(18) | نعم |  |  | I2 خزينة (AP) enum: CHARGES_AND_MARGIN, FULL_LC_VALUE |
| MarginHeldCurrency | VARCHAR(10) | نعم |  |  | I2 enum: LOCAL, FOREIGN |
| FacilityAccountId | BIGINT | نعم |  | acc.BankAccount | I3 خزينة: من حسابات التسهيل (FR-ACC-010) |
| MarginSettlementAccountId | BIGINT | نعم |  | acc.BankAccount |  |
| ChargesAccountId | BIGINT | نعم |  | acc.BankAccount |  |
| PostDeferralFinancingDays | INT | نعم |  |  | I4 خزينة: يُمرَّر لفحص TENOR (BR-FAC-016، Q-LCT-11) |
| BankSpecificClauses | NVARCHAR(MAX) | نعم |  |  | بنود خاصة بالبنك: حقل خزينة لا يراه الطالب (FR-LCI-007) -- إضافة |
| PrevLcNumber | NVARCHAR(60) | نعم |  |  | J1: الاعتماد السابق يدوي بلا ربط بالسجلات (FR-LCT-022) |
| PrevLcAmount | DECIMAL(19,4) | نعم |  |  |  |
| PrevLcCurrencyId | INT | نعم |  | ref.Currency |  |
| PrevLcUtilizedAmount | DECIMAL(19,4) | نعم |  |  |  |
| PrevLcOpenedBy | NVARCHAR(200) | نعم |  |  |  |
| SnapshotHash | VARBINARY(32) | نعم |  |  | SHA-256 لحقول الطالب + البنود + الرسوم عند القفل (BR-LCT-019) |
| TreasuryHash | VARBINARY(32) | نعم |  |  | يُقفل بها حقل الخزينة بعد موافقة TM |
| LockedAt | DATETIME2(3) | نعم |  |  |  |
| LockedBy | BIGINT | نعم |  | sec.AppUser |  |
| SupersedesTermsId | BIGINT | نعم |  | lc.LcTerms | النسخة السابقة التي حلّت هذه محلها |
| CopiedFromTermsId | BIGINT | نعم |  | lc.LcTerms | نسخة عند الانتقال طلب ← اعتماد/بروفورما (BR-LCT-019) |
| ChangeReason | NVARCHAR(MAX) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcTermsId) · UQ(PublicId) · UQ(TenantId, OwnerType, OwnerId, Purpose, VersionNo) WHERE OwnerId IS NOT NULL · UQ(TenantId, OwnerType, OwnerId, Purpose) WHERE OwnerId IS NOT NULL AND Status <> 'SUPERSEDED'

**قيود:** `VersionNo >= 1` · `VersionNo = 1 OR SupersedesTermsId IS NOT NULL` · `SupersedesTermsId IS NULL OR SupersedesTermsId <> LcTermsId` · `CopiedFromTermsId IS NULL OR CopiedFromTermsId <> LcTermsId` · `(Purpose = 'PROFORMA' AND OwnerType IN ('REQUEST','PROFORMA')) OR (Purpose = 'APPLICATION' AND OwnerType = 'REQUEST') OR (Purpose IN ('ISSUED','RECEIVED') AND OwnerType = 'LETTER_OF_CREDIT') OR (Purpose = 'AMENDMENT' AND OwnerType IN ('REQUEST','AMENDMENT'))` · `(Purpose NOT IN ('APPLICATION','ISSUED') OR LcClass = 'PURCHASE') AND (Purpose NOT IN ('PROFORMA','RECEIVED') OR LcClass = 'SALES')` · `OwnerType <> 'REQUEST' OR OwnerId IS NOT NULL` · `Status = 'DRAFT' OR (SnapshotHash IS NOT NULL AND LockedAt IS NOT NULL)` · `TreasuryHash IS NULL OR SnapshotHash IS NOT NULL` · `Status = 'DRAFT' OR (LcType IS NOT NULL AND CurrencyId IS NOT NULL AND Amount IS NOT NULL AND ExpiryRule IS NOT NULL AND AmountInWordsAr IS NOT NULL AND AmountInWordsEn IS NOT NULL)` · `Amount IS NULL OR Amount > 0` · `TolerancePlusPct BETWEEN 0 AND 100 AND ToleranceMinusPct BETWEEN 0 AND 100` · `Status = 'DRAFT' OR ToleranceMode <> 'NONE' OR (TolerancePlusPct = 0 AND ToleranceMinusPct = 0)` · `Status = 'DRAFT' OR ToleranceMode <> 'ABOUT' OR (TolerancePlusPct = 10 AND ToleranceMinusPct = 10)` · `DeferralDays IS NULL OR DeferralDays BETWEEN 1 AND 720` · `Status = 'DRAFT' OR LcType <> 'SIGHT' OR (DeferralDays IS NULL AND MaturityBasis IS NULL)` · `Status = 'DRAFT' OR LcType NOT IN ('DEFERRED_PAYMENT','ACCEPTANCE') OR (DeferralDays IS NOT NULL AND MaturityBasis IS NOT NULL)` · `Status = 'DRAFT' OR LcType <> 'MIXED' OR MixedPaymentText IS NOT NULL` · `Status = 'DRAFT' OR DraftDrawee IS NULL OR (DraftRequired IS NOT NULL AND DraftRequired = 1)` · `Status = 'DRAFT' OR LcType NOT IN ('ACCEPTANCE','NEGOTIATION') OR (DraftRequired IS NOT NULL AND DraftRequired = 1)` · `Status = 'DRAFT' OR ConfirmingBankBic IS NULL OR ((ConfirmingBankBic LIKE '________' OR ConfirmingBankBic LIKE '___________') AND ConfirmingBankBic NOT LIKE '%[^A-Z0-9]%')` · `Status = 'DRAFT' OR AdvisingBankBic IS NULL OR ((AdvisingBankBic LIKE '________' OR AdvisingBankBic LIKE '___________') AND AdvisingBankBic NOT LIKE '%[^A-Z0-9]%')` · `(BeneficiaryAccountIbanEnc IS NULL AND BeneficiaryAccountIbanMask IS NULL AND BeneficiaryAccountIbanHash IS NULL) OR (BeneficiaryAccountIbanEnc IS NOT NULL AND BeneficiaryAccountIbanMask IS NOT NULL AND BeneficiaryAccountIbanHash IS NOT NULL)` · `LcClass = 'SALES' OR (ApplicantCounterpartyId IS NULL AND BeneficiaryCompanyId IS NULL)` · `LcClass = 'PURCHASE' OR (ApplicantCompanyId IS NULL AND BeneficiaryCounterpartyId IS NULL)` · `Status = 'DRAFT' OR (LcClass = 'PURCHASE' AND ApplicantCompanyId IS NOT NULL AND BeneficiaryCounterpartyId IS NOT NULL) OR (LcClass = 'SALES' AND ApplicantCounterpartyId IS NOT NULL AND BeneficiaryCompanyId IS NOT NULL)` · `ExpiryDaysAfterIssue IS NULL OR ExpiryDaysAfterIssue > 0` · `LatestShipmentDaysAfterIssue IS NULL OR LatestShipmentDaysAfterIssue > 0` · `Status = 'DRAFT' OR ExpiryRule IS NULL OR (ExpiryRule = 'ABSOLUTE' AND ExpiryDate IS NOT NULL AND ExpiryDaysAfterIssue IS NULL) OR (ExpiryRule = 'DAYS_AFTER_ISSUE' AND ExpiryDaysAfterIssue IS NOT NULL)` · `Status = 'DRAFT' OR (LatestShipmentRule IS NULL AND LatestShipmentDate IS NULL AND LatestShipmentDaysAfterIssue IS NULL) OR (LatestShipmentRule = 'ABSOLUTE' AND LatestShipmentDate IS NOT NULL AND LatestShipmentDaysAfterIssue IS NULL) OR (LatestShipmentRule = 'DAYS_AFTER_ISSUE' AND LatestShipmentDaysAfterIssue IS NOT NULL)` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR EarliestShipmentDate IS NULL OR LatestShipmentDate IS NULL OR EarliestShipmentDate <= LatestShipmentDate` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR ExpiryDate IS NULL OR LatestShipmentDate IS NULL OR ExpiryDate >= LatestShipmentDate` · `PresentationDays IS NULL OR PresentationDays BETWEEN 1 AND 90` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR IncotermId IS NULL OR IncotermPlace IS NOT NULL` · `InsurancePctStated = 0 OR InsuranceMinPct IS NOT NULL` · `InsuranceMinPct IS NULL OR InsuranceMinPct > 0` · `MarginPct IS NULL OR MarginPct BETWEEN 0 AND 100` · `Status = 'DRAFT' OR DebitAuthorization IS NULL OR DebitAuthorization <> 'FULL_LC_VALUE' OR (MarginPct IS NOT NULL AND MarginPct = 100)` · `PostDeferralFinancingDays IS NULL OR PostDeferralFinancingDays >= 0` · `PrevLcAmount IS NULL OR PrevLcAmount >= 0` · `PrevLcUtilizedAmount IS NULL OR PrevLcUtilizedAmount >= 0` · `PrevLcAmount IS NULL OR PrevLcUtilizedAmount IS NULL OR PrevLcUtilizedAmount <= PrevLcAmount` · `(PrevLcAmount IS NULL AND PrevLcUtilizedAmount IS NULL) OR PrevLcCurrencyId IS NOT NULL`

### `lc.LcTermsDocument` — بند مستند مختار في الشروط ومعاملاته؛ النص المصيَّر يُجمَّد عند القفل (FR-LCT-018، BR-LCT-012) -- جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcTermsDocumentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcTermsId | BIGINT | لا |  | lc.LcTerms |  |
| SeqNo | INT | لا |  |  |  |
| ClauseId | BIGINT | لا |  | lc.LcDocumentClause | إصدار البند المستخدم (يُحصى في R-LCT-02) |
| ClauseVersion | INT | لا |  |  | نسخة من LcDocumentClause.VersionNo لثبات العرض |
| Originals | INT | نعم |  |  |  |
| Copies | INT | نعم |  |  |  |
| ParamsJson | NVARCHAR(MAX) | نعم |  |  | قيم المعاملات: أصول، نسخ، جهة تصديق، أجرة، إخطار، نسبة تأمين... |
| RenderedTextEn | NVARCHAR(MAX) | نعم |  |  | يُجمَّد عند القفل |
| RenderedTextAr | NVARCHAR(MAX) | نعم |  |  |  |
| IsFreeText | BIT | لا | 0 |  | بند حر (OTHER_FREE_TEXT) |
| FreeText | NVARCHAR(MAX) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcTermsDocumentId) · UQ(TenantId, LcTermsId, SeqNo)

**قيود:** `SeqNo >= 1` · `ClauseVersion >= 1` · `Originals IS NULL OR Originals >= 0` · `Copies IS NULL OR Copies >= 0` · `(IsFreeText = 1 AND FreeText IS NOT NULL) OR (IsFreeText = 0 AND FreeText IS NULL)`

### `lc.LcChargesMatrix` — رسوم الشروط: صف لكل فئة (6 صفوف كاملة يتحقق منها التطبيق V-LCT-12) (FR-LCT-020، BR-LCT-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcChargesMatrixId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcTermsId | BIGINT | لا |  | lc.LcTerms |  |
| ChargeCategory | VARCHAR(22) | لا |  |  | CHARGE_CATEGORY enum: ISSUING_BANK_LOCAL, ADVISING, CONFIRMATION, NEGOTIATION_SETTLEMENT, AMENDMENT, OTHER_OUTSIDE_ISSUING |
| Payer | VARCHAR(11) | لا |  |  | CHARGE_PAYER enum: APPLICANT, BENEFICIARY, SHARED |
| ApplicantSharePct | DECIMAL(9,6) | نعم |  |  | ★ مع SHARED: ∈ (0,100) والافتراضي 50 |
| PresetCode | VARCHAR(30) | نعم |  |  | OWN_BANK ALL_APPLICANT ALL_BENEFICIARY SPLIT_50 CUSTOM (§5.5) |
| Note | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcChargesMatrixId) · UQ(TenantId, LcTermsId, ChargeCategory)

**قيود:** `Payer <> 'SHARED' OR (ApplicantSharePct IS NOT NULL AND ApplicantSharePct > 0 AND ApplicantSharePct < 100)` · `Payer = 'SHARED' OR ApplicantSharePct IS NULL`

### `lc.LcFormTemplate` — قالب نموذج بنك/منتج/نوع نموذج بإصدار وفترة نفاذ وملحق عقدي (FR-LCT-026، BR-LCT-017، 02 F-14)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcFormTemplateId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| VersionNo | INT | لا | 1 |  |  |
| FormKind | VARCHAR(16) | لا |  |  | enum: LC_APPLICATION, LC_AMENDMENT, PROFORMA, COLLECTION_COVER |
| InstitutionId | BIGINT | نعم |  | ins.Institution | فارغ = قالب موحّد احتياطي للمشترك |
| ProductId | INT | نعم |  | cat.Product |  |
| CompanyId | BIGINT | نعم |  | org.Company | ترويسة البروفورما لشركة بعينها (Q-LCE-07) |
| Scope | VARCHAR(13) | لا | ANY |  | enum: ANY, DOMESTIC, INTERNATIONAL |
| Channel | VARCHAR(11) | لا | ANY |  | enum: ANY, MANUAL_FORM, BANK_PORTAL |
| LayoutKind | VARCHAR(17) | لا |  |  | PDF_ACROFORM_FILL Could (FR-LCT-030) enum: SYSTEM_PRINT, PDF_ACROFORM_FILL |
| Language | VARCHAR(10) | نعم |  |  | enum: ar, en, both |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document | نموذج البنك الفارغ |
| AnnexDocumentId | BIGINT | نعم |  | doc.Document | الصفحة العقدية الثابتة |
| AnnexVersion | NVARCHAR(20) | نعم |  |  | إصدار الملحق يُسجَّل في المطبوع (02 F-14) |
| LetterheadDocumentId | BIGINT | نعم |  | doc.Document |  |
| FooterTextAr | NVARCHAR(500) | نعم |  |  |  |
| FooterTextEn | NVARCHAR(500) | نعم |  |  |  |
| LegalReviewStatus | VARCHAR(10) | لا | UNREVIEWED |  | لافتة طباعة حتى التعليم (Q-LCT-12) enum: UNREVIEWED, REVIEWED |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, ACTIVE, RETIRED |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcFormTemplateId) · UQ(PublicId) · UQ(TenantId, Code, VersionNo) · UQ(TenantId, InstitutionId, ProductId, CompanyId, FormKind, Scope, Channel, EffectiveFrom) WHERE Status = 'ACTIVE'

**قيود:** `VersionNo >= 1` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `LayoutKind <> 'PDF_ACROFORM_FILL' OR SourceDocumentId IS NOT NULL` · `AnnexDocumentId IS NULL OR AnnexVersion IS NOT NULL`

### `lc.LcFormFieldMap` — تعيين حقل نظام إلى حقل PDF أو بند في ورقة البوابة (FR-LCT-027، BR-LCT-020) -- جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcFormFieldMapId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | BIGINT | لا |  | lc.LcFormTemplate |  |
| TargetName | NVARCHAR(120) | لا |  |  | اسم حقل PDF أو بند ورقة البوابة |
| SourceExpr | NVARCHAR(200) | لا |  |  | مسار من جذور مسموحة فقط؛ لا تنفيذ شيفرة (BR-LCT-020) |
| Transform | VARCHAR(15) | لا | NONE |  | enum: NONE, UPPER, DATE_DMY, DATE_HIJRI, AMOUNT_WORDS_AR, AMOUNT_WORDS_EN, CHECKBOX_EQ, CONCAT_DOCS, CHARGES_SUMMARY |
| TransformArg | NVARCHAR(100) | نعم |  |  |  |
| IsRequired | BIT | لا | 0 |  | هدف إلزامي بلا مصدر يمنع الطباعة الرسمية (BR-LCT-020) |
| SeqNo | INT | نعم |  |  | ترتيب ورقة البوابة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcFormFieldMapId) · UQ(TenantId, TemplateId, TargetName)

**قيود:** `SourceExpr LIKE 'terms.%' OR SourceExpr LIKE 'company.%' OR SourceExpr LIKE 'counterparty.%' OR SourceExpr LIKE 'facility.%' OR SourceExpr LIKE 'relationship.%' OR SourceExpr LIKE 'request.%' OR SourceExpr LIKE 'lc.%'` · `SourceExpr NOT LIKE '%[^A-Za-z0-9._]%'` · `Transform <> 'CHECKBOX_EQ' OR TransformArg IS NOT NULL` · `SeqNo IS NULL OR SeqNo >= 1`

### `lc.LetterOfCredit` — سجل الاعتماد للجانبين: مشتريات (نحن الطالب) ومبيعات (نحن المستفيد) (FR-LCI-011..016، FR-LCE-009، BR-LCI-004/008/016، BR-LCE-007/009)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LetterOfCreditId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcClass | VARCHAR(10) | لا |  |  | مشتريات/مبيعات enum: PURCHASE, SALES |
| Scope | VARCHAR(13) | لا |  |  | محلي/دولي (BR-LCT-001) enum: DOMESTIC, INTERNATIONAL |
| CompanyId | BIGINT | لا |  | org.Company | الطالب في المشتريات والمستفيد في المبيعات |
| LcNumber | NVARCHAR(60) | لا |  |  |  |
| LcNumberNormalized | NVARCHAR(60) | لا |  |  | تقليم + حروف لاتينية كبيرة + حذف الفراغات؛ الشرطات تُحفظ (BR-LCI-016) |
| InternalRef | NVARCHAR(40) | نعم |  |  | مرجع داخلي: رقم الطلب LCP-YY-NNNN للمشتريات ورقم تسلسلي للمسجَّل مباشرة -- إضافة |
| Status | VARCHAR(10) | لا | ACTIVE |  | §8؛ CLOSED/CANCELLED نهائيتان enum: ACTIVE, EXPIRED, CLOSED, CANCELLED |
| CounterpartyId | BIGINT | لا |  | lc.Counterparty | المورّد (مشتريات) أو العميل (مبيعات) |
| InstitutionId | BIGINT | نعم |  | ins.Institution | مشتريات: بنك الإصدار؛ مبيعات: بنكنا المبلّغ/المحصّل |
| RelationshipId | BIGINT | نعم |  | ins.Relationship (via CompanyId,InstitutionId) | علاقة الشركة بالمنشأة نفسها (يطابقها الربط المركّب) |
| OtherBankText | NVARCHAR(200) | نعم |  |  | مبيعات: بنك العميل نص + BIC (Q-LCE-08) |
| OtherBankBic | VARCHAR(11) | نعم |  |  |  |
| IssuingBranch | NVARCHAR(150) | نعم |  |  | فرع الإصدار من نموذج lc.issuance (FR-LCI-011) -- إضافة |
| BankReference | NVARCHAR(60) | نعم |  |  |  |
| Channel | VARCHAR(18) | نعم |  |  | DIRECT_INTEGRATION محجوزة غير مفعّلة (FR-LCT-025) enum: BANK_PORTAL, MANUAL_FORM, DIRECT_INTEGRATION |
| ProductId | INT | نعم |  | cat.Product | LC_PURCHASE_CONV / LC_PURCHASE_MURABAHA / LC_SALES_RECEIVED |
| FacilityId | BIGINT | نعم |  | fac.Facility |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | يعاد ربطه بصف الحد الجديد عند اعتماد مراجعة التسهيل مع Utilization (12) |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) |  |
| UtilizationId | BIGINT | نعم |  | fac.Utilization (via FacilityId) | ناتج fac.convert_reservation؛ تعبّئ lc.record_issuance Utilization.SourceRefId = LcId (FR-LCI-012) |
| RequestId | BIGINT | نعم |  | wfl.Request (via CompanyId) | طلب الإصدار (مشتريات)؛ فارغ للمسجَّل مباشرة والقائم السابق |
| ProformaId | BIGINT | نعم |  | lc.ProformaInvoice (via CompanyId) | بروفورما مبيعات واحدة قد تُربط باعتمادات عدة (BR-LCE-018) |
| CurrentTermsId | BIGINT | لا |  | lc.LcTerms | الشروط الحالية: ISSUED/RECEIVED أو لقطة آخر تعديل مطبَّق |
| CurrencyId | INT | لا |  | ref.Currency |  |
| Amount | DECIMAL(19,4) | لا |  |  | الحالي بعد التعديلات المطبَّقة |
| OriginalAmount | DECIMAL(19,4) | لا |  |  |  |
| TolerancePlusPct | DECIMAL(9,6) | لا | 0 |  | نسخة من الشروط الحالية لحساب ExposureAmount |
| ToleranceMinusPct | DECIMAL(9,6) | لا | 0 |  |  |
| ExposureAmount | DECIMAL(19,4) | نعم |  |  | مخبأ: ⌈Amount × (1 + Plus/100)⌉ إن lc.reserve.include_tolerance وإلا Amount؛ المبلغ الوحيد الممرَّر لـ 12 (BR-LCI-004/019) |
| MarginPct | DECIMAL(9,6) | نعم |  |  |  |
| MarginAmount | DECIMAL(19,4) | نعم |  |  |  |
| DrawnAmount | DECIMAL(19,4) | لا | 0 |  | مخبأ مطابَق: Σ السحوب غير REFUSED/CANCELLED (BR-LCI-008، BR-LCE-009) |
| SettledAmount | DECIMAL(19,4) | لا | 0 |  | مخبأ مطابَق: Σ SettledAmount للسحوب |
| EarmarkedRemaining | DECIMAL(19,4) | لا | 0 |  | مبيعات فقط: Σ(Amount − Converted − Released) للأوامر الفعالة (BR-LCE-009) |
| IssueDate | DATE | نعم |  |  | مشتريات |
| ReceivedDate | DATE | نعم |  |  | مبيعات |
| ExpiryDate | DATE | لا |  |  |  |
| LatestShipmentDate | DATE | نعم |  |  |  |
| AmendmentNo | INT | لا | 0 |  | رقم آخر تعديل مطبَّق |
| UndrawnReleasedOn | DATE | نعم |  |  | فك غير المسحوب عند الانتهاء أو الإغلاق (BR-LCI-009) |
| ClosedOn | DATE | نعم |  |  |  |
| ClosedReason | NVARCHAR(500) | نعم |  |  |  |
| LegacyEntry | BIT | لا | 0 |  | اعتماد قائم سابق مسجَّل بلا طلب (FR-LCI-029، BR-LCI-017) |
| AnnexVersion | NVARCHAR(20) | نعم |  |  | إصدار الملحق العقدي المطبوع (للمرابحة) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LetterOfCreditId) · UQ(PublicId) · UQ(TenantId, InstitutionId, LcNumberNormalized) WHERE LcClass = 'PURCHASE' AND InstitutionId IS NOT NULL · UQ(TenantId, InternalRef) WHERE InternalRef IS NOT NULL · UQ(TenantId, UtilizationId) WHERE UtilizationId IS NOT NULL · UQ(TenantId, RequestId) WHERE RequestId IS NOT NULL · UQ(TenantId, CurrentTermsId)

**قيود:** `Amount > 0 AND OriginalAmount > 0` · `TolerancePlusPct BETWEEN 0 AND 100 AND ToleranceMinusPct BETWEEN 0 AND 100` · `DrawnAmount >= 0 AND SettledAmount >= 0 AND SettledAmount <= DrawnAmount` · `EarmarkedRemaining >= 0` · `ExposureAmount IS NULL OR ExposureAmount >= Amount` · `(LcClass = 'PURCHASE' AND IssueDate IS NOT NULL AND ReceivedDate IS NULL) OR (LcClass = 'SALES' AND ReceivedDate IS NOT NULL AND IssueDate IS NULL)` · `IssueDate IS NULL OR ExpiryDate >= IssueDate` · `LimitId IS NULL OR FacilityId IS NOT NULL` · `LimitProductLineId IS NULL OR LimitId IS NOT NULL` · `UtilizationId IS NULL OR FacilityId IS NOT NULL` · `RelationshipId IS NULL OR InstitutionId IS NOT NULL` · `LcClass = 'PURCHASE' OR (FacilityId IS NULL AND UtilizationId IS NULL AND ExposureAmount IS NULL AND MarginPct IS NULL AND MarginAmount IS NULL)` · `LcClass = 'SALES' OR ExposureAmount IS NOT NULL` · `LcClass = 'SALES' OR (ProformaId IS NULL AND OtherBankText IS NULL AND OtherBankBic IS NULL AND EarmarkedRemaining = 0)` · `MarginPct IS NULL OR MarginPct BETWEEN 0 AND 100` · `MarginAmount IS NULL OR MarginAmount >= 0` · `Status NOT IN ('CLOSED','CANCELLED') OR (ClosedOn IS NOT NULL AND ClosedReason IS NOT NULL)` · `Status IN ('CLOSED','CANCELLED') OR (ClosedOn IS NULL AND ClosedReason IS NULL)` · `UndrawnReleasedOn IS NULL OR Status IN ('EXPIRED','CLOSED','CANCELLED')` · `LegacyEntry = 0 OR RequestId IS NULL` · `OtherBankBic IS NULL OR ((OtherBankBic LIKE '________' OR OtherBankBic LIKE '___________') AND OtherBankBic NOT LIKE '%[^A-Z0-9]%')` · `AmendmentNo >= 0` · `LcNumberNormalized NOT LIKE '% %'`

### `lc.LcExternalRef` — مرجع خارجي للاعتماد (ERP...)؛ بلا تفرّد؛ البحث بالمطبَّع (FR-LCI-013، BR-REQ-006) -- جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcExternalRefId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit |  |
| SystemCode | NVARCHAR(40) | لا |  |  | نص حر مثل ERP |
| RefType | NVARCHAR(60) | لا |  |  | نص حر مثل PURCHASE_ORDER |
| RefValue | NVARCHAR(100) | لا |  |  |  |
| NormalizedValue | NVARCHAR(100) | لا |  |  | أرقام عربية-هندية → لاتينية + تقليم + حروف كبيرة (BR-REQ-006) |
| IsActive | BIT | لا | 1 |  |  |
| SupersededById | BIGINT | نعم |  | lc.LcExternalRef (via LcId) | المرجع الذي حلّ محله على الاعتماد نفسه |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcExternalRefId)

**قيود:** `SupersededById IS NULL OR (IsActive = 0 AND SupersededById <> LcExternalRefId)`

### `lc.LcAmendment` — تعديل اعتماد صادر أو مستلَم (FR-LCI-018/019، FR-LCE-020، BR-LCI-011/012، BR-LCE-014)؛ الحالات §8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcAmendmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) | عملة التعديل = عملة الاعتماد |
| AmendmentNo | INT | نعم |  |  | رقم البنك أو تسلسل المنصة؛ يُسجَّل عند BANK_ISSUED |
| Origin | VARCHAR(22) | لا |  |  | enum: OUR_REQUEST, RECEIVED_FROM_CUSTOMER |
| ChangeKinds | VARCHAR(87) | لا |  |  | قائمة قيم ثابتة (المواصفة json) |
| RequestId | BIGINT | نعم |  | wfl.Request | الطلب الفرعي LC_AMENDMENT |
| TermsId | BIGINT | لا |  | lc.LcTerms | شروط غرض AMENDMENT (لقطة ما بعد التعديل) |
| ChangedFieldsJson | NVARCHAR(MAX) | نعم |  |  | الفروق بمفاتيح الحقول مقارنةً بالحالي |
| CurrencyId | INT | لا |  | ref.Currency |  |
| AmountDelta | DECIMAL(19,4) | لا |  |  | موقَّع: فرق ExposureAmount (BR-LCI-011) |
| NewAmount | DECIMAL(19,4) | نعم |  |  |  |
| NewExpiryDate | DATE | نعم |  |  |  |
| Status | VARCHAR(11) | لا | DRAFT |  | §8: في التصدير REQUESTED = طلبنا من العميل وBANK_ISSUED = إشعار مستلَم enum: DRAFT, REQUESTED, BANK_ISSUED, APPLIED, REJECTED, WITHDRAWN |
| BankAmendmentRef | NVARCHAR(60) | نعم |  |  |  |
| BankIssuedOn | DATE | نعم |  |  |  |
| BeneficiaryResponse | VARCHAR(10) | نعم | PENDING |  | enum: PENDING, ACCEPTED, REJECTED |
| RespondedOn | DATE | نعم |  |  |  |
| AppliedOn | DATETIME2(3) | نعم |  |  |  |
| AppliedBy | BIGINT | نعم |  | sec.AppUser |  |
| ReservationDeltaApplied | DECIMAL(19,4) | نعم |  |  | فرق الحجز/الاستغلال المطبَّق فعلًا على 12 |
| Reason | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcAmendmentId) · UQ(TenantId, LcId, AmendmentNo) WHERE AmendmentNo IS NOT NULL · UQ(TenantId, RequestId) WHERE RequestId IS NOT NULL · UQ(TenantId, TermsId)

**قيود:** `AmendmentNo IS NULL OR AmendmentNo >= 1` · `ChangeKinds <> ''` · `ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' OR ChangeKinds NOT LIKE '%DECREASE_AMOUNT%'` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' OR AmountDelta > 0` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%DECREASE_AMOUNT%' OR AmountDelta < 0` · `Status = 'DRAFT' OR (ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' AND ChangeKinds NOT LIKE '%DECREASE_AMOUNT%') OR NewAmount IS NOT NULL` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%EXTEND_EXPIRY%' OR NewExpiryDate IS NOT NULL` · `NewAmount IS NULL OR NewAmount > 0` · `Status NOT IN ('BANK_ISSUED','APPLIED') OR (AmendmentNo IS NOT NULL AND BankIssuedOn IS NOT NULL)` · `Status <> 'APPLIED' OR (BeneficiaryResponse = 'ACCEPTED' AND AppliedOn IS NOT NULL AND AppliedBy IS NOT NULL)` · `BeneficiaryResponse IS NULL OR BeneficiaryResponse = 'PENDING' OR RespondedOn IS NOT NULL`

### `lc.LcDrawing` — سحب/تقديم مستندات تحت اعتماد؛ في التصدير يشمل تحويل التخصيص (FR-LCI-023، BR-LCI-013، BR-LCE-011)؛ الحالات §8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDrawingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) | عملة السحب = عملة الاعتماد (BR-LCI-013) |
| DrawingNo | INT | لا |  |  |  |
| Amount | DECIMAL(19,4) | لا |  |  | Drawn + Amount ≤ ExposureAmount يتحقق منه التطبيق (V-LCI-05) |
| CurrencyId | INT | لا |  | ref.Currency |  |
| PresentationDate | DATE | لا |  |  |  |
| BankAdviceRef | NVARCHAR(60) | نعم |  |  | مرجع إشعار البنك |
| InvoiceRefsText | NVARCHAR(1000) | نعم |  |  | مراجع الفواتير/سندات التسليم نصًا (FR-LCE-016) |
| Status | VARCHAR(10) | لا | PRESENTED |  | REFUSED وCANCELLED لا تُحتسبان في المسحوب enum: PRESENTED, DISCREPANT, ACCEPTED, SETTLED, REFUSED, CANCELLED |
| MaturityBasisDate | DATE | نعم |  |  | تاريخ أساس الاستحقاق للآجل (BR-LCT-009) |
| MaturityDate | DATE | نعم |  |  | MaturityBasisDate + deferralDays |
| ExaminationDeadline | DATE | نعم |  |  | PresentationDate + lc.drawing.exam_banking_days (BR-LCI-013) |
| SettledAmount | DECIMAL(19,4) | لا | 0 |  | التسديد الجزئي يزيده |
| LastSettledOn | DATE | نعم |  |  |  |
| SettlementAccountId | BIGINT | نعم |  | acc.BankAccount |  |
| RequestId | BIGINT | نعم |  | wfl.Request | طلب مستندات التحصيل في التصدير (lc.convert_earmark) |
| OverrideReason | NVARCHAR(500) | نعم |  |  | تجاوز TM لتقديم بعد الانتهاء (V-LCI-06) |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDrawingId) · UQ(TenantId, LcId, DrawingNo) · UQ(TenantId, RequestId) WHERE RequestId IS NOT NULL

**قيود:** `Amount > 0` · `SettledAmount >= 0 AND SettledAmount <= Amount` · `Status <> 'SETTLED' OR SettledAmount = Amount` · `Status NOT IN ('REFUSED','CANCELLED') OR SettledAmount = 0` · `SettledAmount = 0 OR LastSettledOn IS NOT NULL` · `MaturityDate IS NULL OR MaturityBasisDate IS NULL OR MaturityDate >= MaturityBasisDate` · `ExaminationDeadline IS NULL OR ExaminationDeadline >= PresentationDate`

### `lc.LcSalesOrder` — تخصيص أمر بيع على اعتماد مستلَم؛ لا يقابله حد ائتماني (FR-LCE-013..015، BR-LCE-009..013)؛ الحالات §8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcSalesOrderId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) | عملة الأمر = عملة الاعتماد (V-LCE-06) |
| RequestId | BIGINT | لا |  | wfl.Request | طلب SALES_ORDER_APPROVAL؛ خطاف lc.earmark_sales_order متكرر الأمان |
| OrderRef | NVARCHAR(60) | لا |  |  | مرجع أمر البيع نصًا؛ تكراره على الاعتماد تحذير V-LCE-08 |
| OrderDate | DATE | لا |  |  |  |
| Amount | DECIMAL(19,4) | لا |  |  | Amount ≤ Available تحت قفل صف الاعتماد (BR-LCE-010) |
| CurrencyId | INT | لا |  | ref.Currency |  |
| ConvertedAmount | DECIMAL(19,4) | لا | 0 |  |  |
| ReleasedAmount | DECIMAL(19,4) | لا | 0 |  |  |
| Status | VARCHAR(19) | لا | EARMARKED |  | enum: EARMARKED, PARTIALLY_CONVERTED, CONVERTED, RELEASED, CANCELLED |
| DeliveryDate | DATE | نعم |  |  | بعد آخر شحن تحذير V-LCE-08 |
| ClosedOn | DATE | نعم |  |  |  |
| ClosedReason | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcSalesOrderId) · UQ(TenantId, RequestId)

**قيود:** `Amount > 0` · `ConvertedAmount >= 0 AND ReleasedAmount >= 0 AND Amount >= ConvertedAmount + ReleasedAmount` · `Status <> 'EARMARKED' OR (ConvertedAmount = 0 AND ReleasedAmount = 0)` · `Status <> 'PARTIALLY_CONVERTED' OR (ConvertedAmount > 0 AND ConvertedAmount < Amount)` · `Status <> 'CONVERTED' OR ConvertedAmount = Amount` · `Status <> 'RELEASED' OR ReleasedAmount > 0` · `Status <> 'CANCELLED' OR (ConvertedAmount = 0 AND ReleasedAmount = 0)` · `Status NOT IN ('RELEASED','CANCELLED') OR (ClosedOn IS NOT NULL AND ClosedReason IS NOT NULL)`

### `lc.LcDrawingAllocation` — توزيع سحب تصدير على أوامر بيع (FR-LCE-016/017، BR-LCE-011/013) -- جديد؛ Σ التوزيع ≤ مبلغ السحب وكل جزء ≤ متبقي أمره يتحقق منهما التطبيق

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDrawingAllocationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) |  |
| DrawingId | BIGINT | لا |  | lc.LcDrawing (via LcId,CurrencyId) | السحب من الاعتماد نفسه وبعملته |
| SalesOrderId | BIGINT | لا |  | lc.LcSalesOrder (via LcId,CurrencyId) | الأمر من الاعتماد نفسه وبعملته |
| Amount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDrawingAllocationId) · UQ(TenantId, DrawingId, SalesOrderId)

**قيود:** `Amount > 0`

### `lc.LcDiscrepancy` — مخالفة على مستندات سحب أو اعتماد؛ القرار يتطلب lc.discrepancy.decide (FR-LCI-024، FR-LCE-021، §8) -- جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDiscrepancyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| LcId | BIGINT | لا |  | lc.LetterOfCredit |  |
| DrawingId | BIGINT | نعم |  | lc.LcDrawing (via LcId) | السحب من الاعتماد نفسه |
| Source | VARCHAR(11) | لا |  |  | enum: BANK_NOTICE, INTERNAL |
| Description | NVARCHAR(MAX) | لا |  |  |  |
| Status | VARCHAR(10) | لا | OPEN |  | enum: OPEN, WAIVED, CORRECTED, REFUSED |
| DecidedBy | BIGINT | نعم |  | sec.AppUser |  |
| DecidedOn | DATETIME2(3) | نعم |  |  |  |
| DecisionNote | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDiscrepancyId)

**قيود:** `Status = 'OPEN' OR (DecidedBy IS NOT NULL AND DecidedOn IS NOT NULL AND DecisionNote IS NOT NULL)` · `Status <> 'OPEN' OR (DecidedBy IS NULL AND DecidedOn IS NULL)`

### `lc.ProformaInvoice` — البروفورما الصادرة: لا تعديل بعد الإصدار؛ الرقم {seq:000}-{erp}-{yy} (FR-LCE-005..008، BR-LCE-001..006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProformaInvoiceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| ProformaNo | NVARCHAR(30) | لا |  |  | يُمنح عند الإصدار فقط؛ يحمل رمز ERP فيتفرد بين الشركات (BR-LCE-002) |
| NumberYear | SMALLINT | لا |  |  | سنة الإصدار كاملة بتوقيت المشترك؛ yy آخر خانتين منها جزء من الرقم -- إضافة |
| NumberSeq | INT | لا |  |  | seq لكل (مشترك، شركة، سنة) بلا فجوات؛ النسخة من cfg.NumberIssue (FR-PLT-026) -- إضافة |
| RequestId | BIGINT | لا |  | wfl.Request (via CompanyId) | طلب PROFORMA_REQUEST (لشركة الطلب نفسها) |
| ErpCompanyCodeSnapshot | NVARCHAR(20) | لا |  |  | لقطة Company.ErpCodeNormalized يوم الإصدار (BR-LCE-005) |
| BranchCode | NVARCHAR(40) | نعم |  |  | الفرع نص بلا كيان مرجعي (FR-LCE-001) |
| BranchName | NVARCHAR(200) | نعم |  |  |  |
| ProjectCode | NVARCHAR(40) | نعم |  |  | المشروع نص بلا كيان مرجعي |
| ProjectName | NVARCHAR(200) | نعم |  |  |  |
| ProjectSite | NVARCHAR(200) | نعم |  |  |  |
| CustomerId | BIGINT | لا |  | lc.Counterparty |  |
| CustomerSnapshotJson | NVARCHAR(MAX) | لا |  |  | لقطة الاسم والعنوان والاتصال عند الإصدار (BR-LCE-005) 🔒 confidential |
| IssueDate | DATE | لا |  |  |  |
| OfferValidityDays | INT | نعم |  |  | ValidUntil = IssueDate + OfferValidityDays مشتق (BR-LCE-018) |
| CurrencyId | INT | لا |  | ref.Currency |  |
| Subtotal | DECIMAL(19,4) | لا |  |  |  |
| VatRatePct | DECIMAL(9,6) | لا |  |  | من CompanyTaxRate الساري يوم الإصدار؛ الصفر قيمة صريحة (BR-LCE-001) |
| VatAmount | DECIMAL(19,4) | لا |  |  |  |
| Total | DECIMAL(19,4) | لا |  |  |  |
| LcPaymentPct | DECIMAL(9,6) | لا | 100 |  | نسبة الدفع بالاعتماد (BR-LCE-006) |
| PlacesJson | NVARCHAR(MAX) | نعم |  |  | مكانا الاستلام والتسليم |
| TermsId | BIGINT | لا |  | lc.LcTerms | شروط غرض PROFORMA مقفلة (نسخة عند الإصدار، BR-LCT-019) |
| ProceedsAccountId | BIGINT | لا |  | acc.BankAccount (via CompanyId) | حساب LC_COLLECTION للشركة نفسها (BR-LCE-004) |
| PrintLanguage | VARCHAR(10) | لا | both |  | enum: ar, en, both |
| DocumentId | BIGINT | لا |  | doc.Document | PDF بنوع PROFORMA_ISSUED (FR-LCE-005) |
| Status | VARCHAR(10) | لا | ISSUED |  | §8 enum: ISSUED, VOID, SUPERSEDED |
| VoidReason | NVARCHAR(500) | نعم |  |  |  |
| SupersededById | BIGINT | نعم |  | lc.ProformaInvoice (via CompanyId) | الإصدار البديل لشركة الطلب نفسها (BR-LCE-003) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProformaInvoiceId) · UQ(PublicId) · UQ(TenantId, ProformaNo) · UQ(TenantId, CompanyId, NumberYear, NumberSeq) · UQ(TenantId, RequestId) · UQ(TenantId, TermsId) · UQ(TenantId, DocumentId)

**قيود:** `ProformaNo LIKE '[0-9][0-9][0-9]%-%-[0-9][0-9]'` · `NumberSeq >= 1 AND NumberYear BETWEEN 2000 AND 2999` · `Subtotal >= 0 AND VatAmount >= 0` · `Total = Subtotal + VatAmount` · `VatRatePct BETWEEN 0 AND 100` · `LcPaymentPct > 0 AND LcPaymentPct <= 100` · `OfferValidityDays IS NULL OR OfferValidityDays > 0` · `Status <> 'VOID' OR VoidReason IS NOT NULL` · `VoidReason IS NULL OR Status = 'VOID'` · `(Status = 'SUPERSEDED' AND SupersededById IS NOT NULL) OR (Status <> 'SUPERSEDED' AND SupersededById IS NULL)` · `SupersededById IS NULL OR SupersededById <> ProformaInvoiceId`

### `lc.ProformaLine` — بند في البروفورما (FR-LCE-003، BR-LCE-001)؛ يُثبَّت بعد الإصدار

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProformaLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ProformaId | BIGINT | لا |  | lc.ProformaInvoice (via CurrencyId) | عملة البند = عملة البروفورما |
| LineNo | INT | لا |  |  |  |
| Description | NVARCHAR(MAX) | لا |  |  |  |
| Qty | DECIMAL(19,4) | لا |  |  | > 0 |
| UnitCode | VARCHAR(80) | لا |  |  | رمز بند من UNIT_OF_MEASURE (LOT PCS M M2 KG TON LITRE SET) |
| UnitPrice | DECIMAL(19,4) | لا |  |  | ≥ 0 |
| LineTotal | DECIMAL(19,4) | لا |  |  | round(Qty × UnitPrice, d) بالتقريب لأبعد (BR-LCE-001) يحسبه التطبيق |
| CurrencyId | INT | لا |  | ref.Currency |  |
| Notes | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProformaLineId) · UQ(TenantId, ProformaId, LineNo)

**قيود:** `LineNo >= 1` · `Qty > 0` · `UnitPrice >= 0 AND LineTotal >= 0`

### `lc.LcTermsComparison` — نتيجة مقارنة شروط الاعتماد المستلَم بالبروفورما (FR-LCT-031، FR-LCE-023، BR-LCT-021) -- جديد (Could)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcTermsComparisonId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| BaselineTermsId | BIGINT | لا |  | lc.LcTerms | شروط البروفورما (غرض PROFORMA) |
| ReceivedTermsId | BIGINT | لا |  | lc.LcTerms | شروط الاعتماد المستلَم (غرض RECEIVED) |
| RunAt | DATETIME2(3) | لا |  |  |  |
| RunBy | BIGINT | نعم |  | sec.AppUser |  |
| SummaryJson | NVARCHAR(MAX) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | OPEN |  | enum: OPEN, REVIEWED |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcTermsComparisonId) · UQ(TenantId, BaselineTermsId, ReceivedTermsId, RunAt)

**قيود:** `BaselineTermsId <> ReceivedTermsId`

### `lc.LcTermsComparisonLine` — فرق حقل واحد وحكمه وقرار الخزينة (FR-LCT-031، BR-LCT-021) -- جديد (Could)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcTermsComparisonLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ComparisonId | BIGINT | لا |  | lc.LcTermsComparison |  |
| FieldKey | VARCHAR(60) | لا |  |  |  |
| BaselineValue | NVARCHAR(MAX) | نعم |  |  |  |
| ReceivedValue | NVARCHAR(MAX) | نعم |  |  |  |
| Verdict | VARCHAR(15) | لا |  |  | enum: MATCH, MORE_FAVOURABLE, LESS_FAVOURABLE, ADDED, MISSING, REVIEW |
| Decision | VARCHAR(17) | نعم |  |  | enum: ACCEPT, REQUEST_AMENDMENT, IGNORE |
| DecisionNote | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcTermsComparisonLineId) · UQ(TenantId, ComparisonId, FieldKey)

**قيود:** `Decision IS NULL OR Verdict <> 'MATCH'`
