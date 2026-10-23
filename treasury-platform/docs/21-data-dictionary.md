# قاموس البيانات

> مُولَّد آليًا من نموذج البيانات بـ `tools/dbgen` — لا يُعدَّل يدويًا. الأعمدة المشتركة التي تضيفها اصطلاحات التوليد (TenantId، المعرّف، التدقيق) تظهر في كل جدول.

**عدد الجداول: 255**

| الوحدة | عدد الجداول |
|---|---|
| PLT-PLAT | 9 |
| PLT-SEC | 16 |
| PLT-AUD | 4 |
| PLT-DOC | 3 |
| PLT-CFG | 14 |
| ORG | 14 |
| PTY | 11 |
| REF | 2 |
| CAT | 27 |
| INS | 6 |
| ACC | 6 |
| FAC | 14 |
| PRC | 5 |
| CMP | 2 |
| COL | 7 |
| OBL | 9 |
| FIN | 57 |
| REQ | 8 |
| WFL | 11 |
| NTF | 7 |
| LC | 23 |

## PLT-PLAT

### `plat.Plan` — Subscription plan: a bundle of modules and soft limits (FR-PLT-003/004, Q-PLT-11)

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

### `plat.PlanModule` — Modules included in a plan (replaces the Plan.IncludedModules JSON column)

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

### `plat.Tenant` — No direct access for the tenant application (it reads its row through plat.v_CurrentTenant); isolation root: the tenant (FR-PLT-001/002/046, BR-PLT-001/002)

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
| SuspendedAt | DATETIME2(3) | نعم |  |  | بداية التعليق: منحة دعم أُنشئت قبله تبقى للقراءة (DOC-F04 §7.4) |
| ActivatedAt | DATETIME2(3) | نعم |  |  | أول تفعيل؛ بعده لا يتغير Code (يُفرض في التطبيق/محفّز) |
| ClosedAt | DATETIME2(3) | نعم |  |  | بدء مهلة التصدير 30 يومًا (BR-PLT-002) |
| ArchivedAt | DATETIME2(3) | نعم |  |  | = ClosedAt + 30 يومًا؛ القراءة فقط بلا كتابة ولا حذف |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId) · UQ(PublicId) · UQ(Code)

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Za-z0-9-]%' AND Code NOT LIKE '-%' AND Code NOT LIKE '%-'` · `Status <> 'TRIAL' OR TrialEndsOn IS NOT NULL` · `Status <> 'SUSPENDED' OR SuspendedReason IS NOT NULL` · `Status <> 'SUSPENDED' OR SuspendedAt IS NOT NULL` · `Status NOT IN ('CLOSED','ARCHIVED_READ_ONLY') OR ClosedAt IS NOT NULL` · `Status <> 'ARCHIVED_READ_ONLY' OR ArchivedAt IS NOT NULL` · `ArchivedAt IS NULL OR (ClosedAt IS NOT NULL AND ArchivedAt >= ClosedAt)`

### `plat.ReservedSubdomain` — Subdomains reserved for the system: www, admin, api, app and others (FR-PLT-046)

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

### `plat.PlatformOperator` — Platform operator account: not readable by the tenant application (tp_app); identity store separate from AppUser (FR-PLT-006)

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
| MfaSecretEnc | VARBINARY(256) | نعم |  |  | سر TOTP مشفَّر بمفتاح المنصة 🔒 restricted |
| MfaKeyRef | VARCHAR(200) | نعم |  |  | مرجع مفتاح المنصة في KMS وإصداره (لا مفتاح مشترك للمشغّلين) |
| MfaEnrolledAt | DATETIME2(3) | نعم |  |  |  |
| MfaLastUsedStep | BIGINT | نعم |  |  | آخر خطوة TOTP مقبولة (منع إعادة الاستعمال) |
| FailedAttempts | INT | لا | 0 |  |  |
| FirstFailedAt | DATETIME2(3) | نعم |  |  | بداية نافذة الإخفاقات (15 دقيقة)؛ الخامس يقفل حتى يفك مدير مشغّلين آخر (DOC-S04 §12) |
| LockedUntil | DATETIME2(3) | نعم |  |  |  |
| LastLoginAt | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PlatformOperatorId) · UQ(PublicId) · UQ(Email)

**قيود:** `Status NOT IN ('ACTIVE','LOCKED') OR PasswordHash IS NOT NULL` · `Status <> 'ACTIVE' OR MfaEnabled = 1` · `MfaEnabled = 0 OR MfaSecretEnc IS NOT NULL` · `MfaSecretEnc IS NULL OR MfaKeyRef IS NOT NULL` · `MfaSecretEnc IS NULL OR DATALENGTH(MfaSecretEnc) >= 29` · `FailedAttempts >= 0` · `PasswordHash IS NULL OR PasswordHash LIKE '$argon2id$v=19$m=%,t=%,p=%$%$%'`

### `plat.TenantModule` — Modules enabled per tenant; owned by the platform only: written by platform operators, read by the tenant through a restricted view (DR-01)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **TenantModuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| TenantId | INT | لا |  | plat.Tenant | المشترك المالك (صريح لأن الجدول عالمي) |
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

### `plat.SupportAccessGrant` — Temporary support access, activated by the tenant's account administrator (FR-PLT-007, BR-PLT-017)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **SupportAccessGrantId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OperatorId | INT | لا |  | plat.PlatformOperator |  |
| GrantedBy | BIGINT | لا |  | sec.AppUser |  |
| StartsAt | DATETIME2(3) | لا |  |  |  |
| EndsAt | DATETIME2(3) | لا |  |  | من ساعة إلى 72 ساعة (الافتراضي 4، BR-PLT-017): قيد في الجدول (DR-15)، وsec.usp_SetSupportContext لا يربط بمنحة أطول؛ ينتهي آليًا |
| Reason | NVARCHAR(500) | لا |  |  |  |
| RevokedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedBy | BIGINT | نعم |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SupportAccessGrantId)

**قيود:** `EndsAt > StartsAt` · `EndsAt >= DATEADD(HOUR, 1, StartsAt) AND EndsAt <= DATEADD(HOUR, 72, StartsAt)` · `(RevokedAt IS NULL AND RevokedBy IS NULL) OR (RevokedAt IS NOT NULL AND RevokedBy IS NOT NULL)`

### `plat.OperatorToken` — One-time operator set-up links: password and MFA (FR-PLT-006)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **OperatorTokenId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OperatorId | INT | لا |  | plat.PlatformOperator |  |
| Purpose | VARCHAR(10) | لا |  |  | enum: INVITATION, RESET |
| TokenHash | VARBINARY(32) | لا |  |  | SHA-256 للرابط؛ لا يُخزَّن الأصل 🔒 restricted |
| ExpiresAt | DATETIME2(3) | لا |  |  | الدعوة 48 ساعة، والإعادة 24 ساعة |
| UsedAt | DATETIME2(3) | نعم |  |  |  |
| RevokedAt | DATETIME2(3) | نعم |  |  |  |
| SentTo | NVARCHAR(254) | نعم |  |  | البريد الذي أُرسل إليه الرابط |
| RequestedBy | INT | نعم |  | plat.PlatformOperator | فارغ للمشغّل الأول عند النشر |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(OperatorTokenId) · UQ(TokenHash)

### `plat.OperatorSession` — Platform operator sessions: 15-minute idle and 8-hour absolute timeout (FR-PLT-006)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **OperatorSessionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| OperatorId | INT | لا |  | plat.PlatformOperator |  |
| TokenHash | VARBINARY(32) | لا |  |  | SHA-256 لمعرّف الجلسة؛ لا يُخزَّن الأصل 🔒 restricted |
| LastSeenAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| IdleExpiresAt | DATETIME2(3) | لا |  |  |  |
| AbsoluteExpiresAt | DATETIME2(3) | لا |  |  |  |
| MfaVerifiedAt | DATETIME2(3) | نعم |  |  |  |
| IpAddress | VARCHAR(45) | نعم |  |  |  |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| EndedAt | DATETIME2(3) | نعم |  |  |  |
| EndReason | VARCHAR(19) | نعم |  |  | enum: LOGOUT, TERMINATED_BY_ADMIN, MFA_FAILED, OPERATOR_DISABLED, OPERATOR_RESET |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(OperatorSessionId) · UQ(TokenHash)

**قيود:** `(EndedAt IS NULL AND EndReason IS NULL) OR (EndedAt IS NOT NULL AND EndReason IS NOT NULL)`

## PLT-SEC

### `sec.AppUser` — Tenant portal user (FR-PLT-010..016, BR-PLT-004..006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AppUserId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Email | NVARCHAR(254) | لا |  |  |  |
| DisplayNameAr | NVARCHAR(200) | نعم |  |  |  |
| DisplayNameEn | NVARCHAR(200) | نعم |  |  |  |
| DepartmentId | BIGINT | نعم |  | org.Department |  |
| LineManagerUserId | BIGINT | نعم |  | sec.AppUser | المدير المباشر: يُستعمل لتحديد «المدير» في الموافقات (13) |
| CompanyScopeMode | VARCHAR(10) | لا | SELECTED |  | SELECTED = الرفض هو الأصل (FR-PLT-021) enum: ALL, SELECTED |
| PreferredLanguage | VARCHAR(10) | نعم |  |  | فارغ = DefaultLanguage للمشترك؛ تقرؤه 13 (FR-NTF-024) enum: ar, en |
| DigitsPreference | VARCHAR(12) | نعم |  |  | فارغ = تفضيل المشترك (Q-PLT-07) enum: WESTERN, ARABIC_INDIC |
| Status | VARCHAR(10) | لا | INVITED |  | §8 enum: INVITED, ACTIVE, LOCKED, DISABLED, ARCHIVED |
| IsSystemUser | BIT | لا | 0 |  | حساب خدمة للمشترك (المهام والتكامل ومحرّك الإشعارات)؛ يُنشأ عند التهيئة؛ بلا كلمة مرور ولا دخول تفاعلي (BR-PLT-004) |
| PasswordHash | VARCHAR(255) | نعم |  |  | تجزئة بطيئة مملّحة؛ فارغ حتى إكمال الدعوة 🔒 restricted |
| PasswordChangedAt | DATETIME2(3) | نعم |  |  |  |
| MfaEnabled | BIT | لا | 0 |  | إعادة تعيين MFA تصفّره وتجبر على إعادة التسجيل (BR-PLT-006) |
| MfaSecretEnc | VARBINARY(256) | نعم |  |  | سر TOTP مشفَّر بمفتاح المشترك 🔒 restricted |
| MfaKeyPurpose | VARCHAR(11) | لا | DATA |  | غرض المفتاح الذي شُفِّر به السر (ثابت؛ يُطابَق بالمفتاح المركّب) enum: DATA |
| MfaKeyId | BIGINT | نعم |  | sec.TenantKey (via MfaKeyPurpose) | مفتاح DATA الذي شُفِّر به سر MFA (DR-02) |
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

**قيود:** `LineManagerUserId IS NULL OR LineManagerUserId <> AppUserId` · `DisplayNameAr IS NOT NULL OR DisplayNameEn IS NOT NULL` · `IsSystemUser = 1 OR Status NOT IN ('ACTIVE','LOCKED') OR PasswordHash IS NOT NULL` · `MfaEnabled = 0 OR MfaSecretEnc IS NOT NULL` · `MfaSecretEnc IS NULL OR MfaKeyId IS NOT NULL` · `MfaSecretEnc IS NULL OR DATALENGTH(MfaSecretEnc) >= 29` · `IsSystemUser = 0 OR (PasswordHash IS NULL AND MfaEnabled = 0)` · `Status <> 'ARCHIVED' OR ArchivedAt IS NOT NULL` · `Status <> 'LOCKED' OR LockedUntil IS NOT NULL OR RequiresAdminUnlock = 1` · `FailedAttempts >= 0 AND LockoutCount >= 0` · `PasswordHash IS NULL OR PasswordHash LIKE '$argon2id$v=19$m=%,t=%,p=%$%$%'`

### `sec.Role` — Role defined by the tenant or seeded (FR-PLT-018)

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

### `sec.Permission` — Permission catalogue owned by the platform; a tenant cannot add a permission (FR-PLT-017)

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

### `sec.RolePermission` — Role–permission link; a locked permission goes only to the system roles it names, enforced by sec.TR_RolePermission_Locked (043, BR-PLT-019, DR-16)

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

### `sec.UserRole` — User–role link; permissions are the union of the roles (BR-PLT-007, FR-PLT-018)

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

### `sec.UserCompanyScope` — Companies a user can see; ignored when CompanyScopeMode = ALL (FR-PLT-020)

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

### `sec.LoginAttempt` — Login attempts for rate limiting and lockout windows (BR-PLT-005); written by sec.usp_StartSession. A permanent trace in aud.AuditLog is not written yet (O-24)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LoginAttemptId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | نعم |  | sec.AppUser | فارغ لبريد غير موجود (رسالة موحّدة لا تكشف الوجود) |
| LoginName | NVARCHAR(200) | نعم |  |  | البريد المُدخل كما كُتب |
| Outcome | VARCHAR(15) | لا |  |  | enum: LOGIN_SUCCESS, FAILED_PASSWORD, DENIED_LOCKED, DENIED_TENANT, FAILED_MFA, LOCKOUT |
| IpAddress | VARCHAR(45) | نعم |  |  | تقييد المعدل لكل عنوان IP |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LoginAttemptId)

**قيود:** `UserId IS NOT NULL OR LoginName IS NOT NULL`

### `plat.SchemaMigration` — Journal of the schema scripts applied to this database (DOC-B11 section 6)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **SchemaMigrationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Version | VARCHAR(60) | لا |  |  | BASELINE · V0001 … for a versioned script · R for a run of the repeatable scripts |
| Kind | VARCHAR(10) | لا |  |  | enum: BASELINE, VERSIONED, REPEATABLE |
| ScriptName | NVARCHAR(260) | لا |  |  | the file, or the deployment bundle for the baseline |
| Checksum | VARBINARY(32) | لا |  |  | SHA-256 of the file (of the bundle for the baseline and the repeatable run) |
| Fingerprint | VARBINARY(32) | لا |  |  | plat.fn_SchemaFingerprint() after the step |
| AppliedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| AppliedBy | NVARCHAR(128) | لا |  |  |  |
| DurationMs | INT | نعم |  |  |  |
| ChangeRef | VARCHAR(60) | نعم |  |  | BANKFAS_CHANGE_REF of the run (DOC-S11 section 7; internal review v6, D7) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SchemaMigrationId) · UQ(Version) WHERE Kind <> 'REPEATABLE'

**قيود:** `(Kind = 'BASELINE' AND Version = 'BASELINE') OR (Kind = 'VERSIONED' AND Version LIKE 'V[0-9][0-9][0-9][0-9]') OR (Kind = 'REPEATABLE' AND Version = 'R')` · `DurationMs IS NULL OR DurationMs >= 0`

### `sec.SessionBinding` — Connection binding for the row filters (O-16)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| SessionId | INT | لا |  |  | @@SPID of the connection |
| BoundTenantId | INT | لا |  | plat.Tenant | tenant named by the context procedure |
| BoundUserId | BIGINT | لا |  |  | user named by the context procedure; no foreign key (sec.AppUser is tenant-owned) |
| BindingToken | UNIQUEIDENTIFIER | لا |  |  | random per binding; the row filters also require SESSION_CONTEXT(N'BindingToken') to match |
| BoundAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| BindingKind | VARCHAR(10) | لا | USER |  | USER: sec.usp_SetSessionContext; JOB: sec.usp_SetJobContext; SUPPORT: sec.usp_SetSupportContext (DQ-F04-4, DQ-F04-6) enum: USER, JOB, SUPPORT |
| BoundOperatorId | INT | نعم |  | plat.PlatformOperator | the operator of a SUPPORT binding; revoked with the grant or the operator session |

**المفاتيح:** PK(SessionId)

**قيود:** `(BindingKind = 'SUPPORT' AND BoundOperatorId IS NOT NULL) OR (BindingKind <> 'SUPPORT' AND BoundOperatorId IS NULL)`

### `sec.UserSession` — User sessions: 30-minute idle timeout and 12-hour absolute timeout (FR-PLT-014)

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
| EndReason | VARCHAR(19) | نعم |  |  | enum: LOGOUT, IDLE_TIMEOUT, ABSOLUTE_TIMEOUT, TERMINATED_BY_ADMIN, PASSWORD_CHANGED, MFA_RESET, MFA_FAILED, USER_DISABLED, TENANT_SUSPENDED |
| EndedBy | BIGINT | نعم |  | sec.AppUser | المدير الذي أنهى الجلسة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UserSessionId) · UQ(TenantId, TokenHash)

**قيود:** `(EndedAt IS NULL AND EndReason IS NULL) OR (EndedAt IS NOT NULL AND EndReason IS NOT NULL)`

### `sec.MfaRecoveryCode` — Ten single-use recovery codes, stored hashed (FR-PLT-011, BR-PLT-006); replaces the AppUser.RecoveryCodesHash JSON

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

### `sec.UserToken` — Single-use invitation link (48 hours), password-reset token (30 minutes) or MFA re-enrolment link (24 hours) (FR-PLT-013, DQ-F03-8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **UserTokenId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| UserId | BIGINT | لا |  | sec.AppUser |  |
| Purpose | VARCHAR(15) | لا |  |  | enum: INVITATION, PASSWORD_RESET, MFA_REENROLMENT |
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

### `sec.UserPasswordHistory` — Last five passwords, to prevent reuse (BR-PLT-004)

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

**قيود:** `PasswordHash LIKE '$argon2id$v=19$m=%,t=%,p=%$%$%'`

### `sec.ExternalIdentity` — Link between an external OIDC or Entra identity and a user; readiness only (FR-PLT-015, section 11)

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

### `sec.TenantKey` — Tenant key register; each key is wrapped by a master key held outside the database (FR-PLT-037, BR-PLT-015)

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

**قيود:** `KeyVersion >= 1` · `Status NOT IN ('ACTIVE','RETIRING','RETIRED') OR ActivatedAt IS NOT NULL` · `Status <> 'RETIRED' OR RetiredAt IS NOT NULL`

### `sec.KeyEvent` — Key event log: create, rotate and revoke (FR-PLT-037; high severity BR-PLT-009)

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

### `aud.AuditLog` — Append-only audit log; NULL TenantId = platform event, not visible to any tenant; dedicated RLS policy (BR-PLT-001, BR-PLT-009)

*مختلط النطاق*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | نعم | | plat.Tenant | عزل المشترك |
| **AuditLogId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ChainSeq | BIGINT | نعم |  |  | تسلسل السلسلة لكل مشترك أو للمنصة؛ يكتبه aud.TR_AuditLog_Chain عند الإدراج (055، FR-PLT-025) |
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
| RowHash | VARBINARY(32) | نعم |  |  | SHA-256(PrevHash ‖ ChainSeq ‖ تمثيل قانوني للصف)، aud.fn_AuditRowHash (055) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuditLogId) · UQ(TenantId, ChainSeq) WHERE ChainSeq IS NOT NULL

### `aud.SensitiveAccessLog` — Access log for sensitive data: identity reveals, image views, exports and restricted downloads; flags anomalies above 20 per hour (BR-PTY-009)

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
| CompanyId | BIGINT | نعم |  |  | قيمة لا مفتاح أجنبي، كما في aud.AuditLog: يبقى السجل بعد حذف الشركة أو دمجها |
| Result | VARCHAR(10) | لا |  |  | enum: GRANTED, DENIED |
| DenyReason | VARCHAR(40) | نعم |  |  | NO_PERMISSION · SUPPORT_SESSION · OUT_OF_SCOPE · TENANT_STATE |
| Reason | NVARCHAR(300) | نعم |  |  | سبب الكشف إن فعّله المشترك (Q-PTY-05) |
| IpAddress | VARCHAR(45) | نعم |  |  |  |
| UserAgent | NVARCHAR(400) | نعم |  |  |  |
| CorrelationId | UNIQUEIDENTIFIER | نعم |  |  |  |
| AuditLogId | BIGINT | لا |  | aud.AuditLog | الحدث المقابل في AuditLog للمشترك نفسه: كل وصول، مسموحًا أو مرفوضًا، له حدثه (BR-PTY-009، DR-12) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SensitiveAccessLogId)

**قيود:** `ActorType <> 'USER' OR ActorUserId IS NOT NULL` · `ActorType <> 'OPERATOR' OR OperatorId IS NOT NULL` · `Result = 'GRANTED' OR DenyReason IS NOT NULL`

### `aud.AuditChainHead` — Head of each audit hash chain: its last sequence number and hash (FR-PLT-025)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| ChainKey | INT | لا |  |  | TenantId of the chain, or 0 for the platform events; a value, not a foreign key |
| LastSeq | BIGINT | لا |  |  |  |
| LastHash | VARBINARY(32) | لا |  |  |  |

**المفاتيح:** PK(ChainKey)

**قيود:** `ChainKey >= 0` · `LastSeq >= 1`

### `aud.AuditChainAnchor` — Anchor of an audit chain: its head at a moment, also kept outside the database (DOC-S12 section 5.3)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **AuditChainAnchorId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ChainKey | INT | لا |  |  | TenantId, or 0 for the platform events |
| ChainSeq | BIGINT | لا |  |  |  |
| RowHash | VARBINARY(32) | لا |  |  |  |
| TakenAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| StoreRef | NVARCHAR(400) | نعم |  |  | where the copy outside the database is kept (a write-once object or file) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuditChainAnchorId)

**قيود:** `ChainSeq >= 1`

## PLT-DOC

### `doc.Document` — Logical document: document data and status; the file itself is in doc.DocumentVersion (FR-PLT-027/028, BR-PLT-011)

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
| Sensitivity | VARCHAR(12) | لا | CONFIDENTIAL |  | RESTRICTED إن كان النوع IsSensitive (قادح في 043، DR-18)؛ PUBLIC لمستندات المنصة لا المشترك (DQ-S06-5) enum: PUBLIC, INTERNAL, CONFIDENTIAL, RESTRICTED |
| Status | VARCHAR(12) | لا | ACTIVE |  | enum: ACTIVE, SUPERSEDED, SOFT_DELETED |
| CurrentVersionId | BIGINT | نعم |  | doc.DocumentVersion (via DocumentId) | إصدار من المستند نفسه (DR-18) |
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

**قيود:** `IssueDate IS NULL OR ExpiryDate IS NULL OR ExpiryDate > IssueDate` · `Status <> 'SUPERSEDED' OR SupersededByDocumentId IS NOT NULL` · `Status <> 'SOFT_DELETED' OR (DeletedAt IS NOT NULL AND DeleteReason IS NOT NULL)` · `SupersededByDocumentId IS NULL OR SupersededByDocumentId <> DocumentId` · `Sensitivity <> 'PUBLIC'`

### `doc.DocumentVersion` — Immutable file version; a change creates a new version: the application may update only the scan and integrity columns (043, FR-PLT-027, BR-PLT-011, DR-11)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **DocumentVersionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| VersionNo | INT | لا |  |  |  |
| StorageKey | VARCHAR(300) | لا |  |  | مسار في مخزن الملفات المشترك، يبدأ بـ PublicId للمشترك (DOC-S02)؛ فريد على المنصة كلها |
| FileName | NVARCHAR(260) | نعم |  |  |  |
| ContentType | VARCHAR(150) | نعم |  |  | يُفحص بالمحتوى لا بالامتداد (FR-PLT-029) |
| SizeBytes | BIGINT | لا |  |  |  |
| Sha256 | VARBINARY(32) | لا |  |  | يحسبها الخادم من البايتات المستلمة |
| KeyPurpose | VARCHAR(11) | لا | FILE |  | enum: FILE |
| KeyId | BIGINT | لا |  | sec.TenantKey (via KeyPurpose) | مفتاح FILE لتشفير الملف (6.4، DR-02) |
| ScanStatus | VARCHAR(11) | لا | PENDING |  | لا يُنزَّل إلا CLEAN enum: PENDING, CLEAN, QUARANTINED |
| ScannedAt | DATETIME2(3) | نعم |  |  |  |
| ScanDetail | NVARCHAR(300) | نعم |  |  |  |
| IntegrityStatus | VARCHAR(10) | لا | UNVERIFIED |  | فحص السلامة الدوري (FR-PLT-031) enum: UNVERIFIED, OK, MISMATCH, MISSING |
| LastVerifiedAt | DATETIME2(3) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(DocumentVersionId) · UQ(TenantId, DocumentId, VersionNo) · UQ(StorageKey)

**قيود:** `VersionNo >= 1` · `SizeBytes > 0` · `ScanStatus = 'PENDING' OR ScannedAt IS NOT NULL`

### `doc.DocumentLink` — Links a document to any entity with a role and a reference page; unlinking is logical (FR-PLT-028)

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

### `cfg.SettingDefinition` — Setting-key definition with platform minimum and maximum bounds (BR-PLT-018, FR-PLT-043)

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

### `cfg.TenantSetting` — Tenant settings: security policies, timeouts, thresholds, and work start and end times (FR-PLT-043)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TenantSettingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Key | VARCHAR(100) | لا |  |  | مفتاح محجوز في T-SQL: يُقتبس دائمًا؛ مفتاح معرَّف في SettingDefinition فقط، وwork.end−work.start بين 4 و12 ساعة (BR-PLT-018)، يفرضهما القادح في 028 (DR-17) |
| ValueJson | NVARCHAR(MAX) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantSettingId) · UQ(TenantId, Key)

### `cfg.NumberSequenceDefinition` — Numbering-type definition with a tag-based format, for example {seq:000}-{erp}-{yy} (FR-PLT-026)

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

### `cfg.NumberSequence` — Counter per (definition, optional company, period); its row is locked on allocation inside the caller's transaction (BR-PLT-010)

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

### `cfg.NumberIssue` — Issued document numbers; a cancelled number is never reused (FR-PLT-026, BR-PLT-010)

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

### `cfg.ExpiryAlertRule` — Expiry alert rule per item type (FR-PLT-038, BR-PLT-013)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ExpiryAlertRuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ItemType | VARCHAR(60) | لا |  |  | مثل COMPANY_DOCUMENT · IDENTITY_DOCUMENT · BODY_TERM · AUTHORITY_GRANT |
| LeadDays | NVARCHAR(MAX) | لا |  |  | تنازلي مثل [90,60,30,7] |
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

### `cfg.ExpiryAlertRuleRole` — Roles that receive an alert rule's alerts, within the company scope; replaces the RecipientRoles code list, so a renamed or missing role cannot silently receive nothing (FR-PLT-038, DR-16)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| ExpiryAlertRuleId | BIGINT | لا |  | cfg.ExpiryAlertRule |  |
| RoleId | BIGINT | لا |  | sec.Role | دور من المشترك نفسه (مفتاح مركّب) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, ExpiryAlertRuleId, RoleId)

### `cfg.ExpiryAlertLog` — Log of sent expiry alerts: one event per (item, threshold), never repeated on the same day (FR-PLT-038)

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

### `cfg.DataExportJob` — Tenant data export request (FR-PLT-039, BR-PLT-016)

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

**قيود:** `IncludesRestricted = 0 OR Status = 'REQUESTED' OR ApprovedBy IS NOT NULL` · `(ApprovedBy IS NULL AND ApprovedAt IS NULL) OR (ApprovedBy IS NOT NULL AND ApprovedAt IS NOT NULL)` · `Status NOT IN ('READY','EXPIRED') OR ExpiresAt IS NOT NULL` · `Status <> 'READY' OR (PackageDocumentId IS NOT NULL AND PackageSha256 IS NOT NULL)` · `FinishedAt IS NULL OR StartedAt IS NULL OR FinishedAt >= StartedAt`

### `cfg.NonWorkingDay` — Non-working day; NULL TenantId = platform holiday, read-only (FR-PLT-035, BR-PLT-014)

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

### `cfg.OutboxEvent` — Outbound queue with at-least-once delivery; the payload carries identifiers without restricted data; only DELIVERED events may be deleted (043, FR-PLT-042, DR-14)

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

**قيود:** `AttemptCount >= 0` · `EventName LIKE '%.%'` · `Status <> 'PROCESSING' OR (LockedBy IS NOT NULL AND LockedUntil IS NOT NULL)` · `Status <> 'DELIVERED' OR DeliveredAt IS NOT NULL` · `Status <> 'DEAD' OR LastError IS NOT NULL`

### `cfg.JobDefinition` — Background job catalogue: the only JobKey values a job connection may bind with (FR-PLT-044)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **JobDefinitionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| JobKey | VARCHAR(80) | لا |  |  |  |
| Scope | VARCHAR(10) | لا |  |  | PLATFORM: runs without a tenant binding (status transitions, DOC-F05 §6.3) enum: TENANT, PLATFORM |
| RunsInStatuses | VARCHAR(49) | نعم |  |  | CLOSED means within 30 days of ClosedAt; empty for PLATFORM |
| Description | NVARCHAR(500) | نعم |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(JobDefinitionId) · UQ(JobKey)

**قيود:** `Scope = 'PLATFORM' OR RunsInStatuses IS NOT NULL`

### `cfg.JobRun` — Background job run log: last run, duration and result, visible to the account administrator (FR-PLT-044)

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

### `cfg.SeedRun` — Numbered seed-run log per package; re-running a seed adds nothing (FR-PLT-008)

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

### `org.Company` — Company: root of the corporate structure (FR-ORG-001..010, BR-ORG-001..004)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyCode | VARCHAR(20) | لا |  |  | رمز داخلي فريد في المشترك (BR-ORG-001) |
| RefCode | VARCHAR(3) | نعم |  |  | رمز الشركة في مرجع التسهيل: حرفان أو ثلاثة، فريد في المشترك (BR-FAC-021، طلب المالك 2026-10-23) |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| PartyKind | VARCHAR(12) | لا | ORGANIZATION |  | ثابت: المرآة جهة اعتبارية (DR-24) enum: ORGANIZATION |
| PartyId | BIGINT | لا |  | pty.Party (via PartyKind) | Party المرآة تُنشأ آليًا وتبقى للقراءة (FR-PTY-003، BR-PTY-018)؛ الرابط الوحيد بين الشركة ومرآتها (DR-24) |
| LegalEntityTypeId | INT | لا |  | cat.LegalEntityType | الشكل القانوني؛ توافق دولته مع CountryId في التطبيق (BR-ORG-016) |
| IsHolding | BIT | لا | 0 |  | قابضة: علم مستقل عن الشكل القانوني (FR-ORG-003، BR-ORG-003) |
| ParentCompanyId | BIGINT | نعم |  | org.Company | الأم؛ منع الحلقات والعمق الأقصى 10 في التطبيق (FR-ORG-004، BR-ORG-002) |
| CountryId | INT | لا |  | ref.Country | بلد التأسيس |
| IndustryId | INT | نعم |  | ref.Industry | النشاط الرئيسي بالتصنيف السعودي للأنشطة الاقتصادية (ISIC 4)؛ يلزم للتقييم الائتماني (docs/35 §5، طلب المالك 2026-10-19) |
| Status | VARCHAR(10) | لا | ACTIVE |  | الأرشفة ممنوعة مع استخدام نشط (FR-ORG-010) enum: ACTIVE, DORMANT, LIQUIDATED, ARCHIVED |
| EstablishedOn | DATE | نعم |  |  | تاريخ التأسيس |
| CrNumber | VARCHAR(30) | نعم |  |  | رقم السجل التجاري (FR-ORG-005) |
| CrDate | DATE | نعم |  |  |  |
| CrDateHijriText | NVARCHAR(20) | نعم |  |  | التاريخ الهجري كما في الوثيقة (X-DAT-2) |
| ErpCompanyCode | NVARCHAR(20) | نعم |  |  | رمز ERP يدوي بعد التقليم؛ يحمله رقم البروفورما {seq}-{erp}-{yy} (BR-ORG-001) |
| ErpCodeNormalized | NVARCHAR(20) | نعم |  |  | مشتق محسوب مخزَّن: حروف كبيرة بلا فراغات (=صيغة BR-LCE-002، DR-47) محسوب: `CAST(UPPER(REPLACE(ErpCompanyCode, N' ', N'')) AS NVARCHAR(20))` |
| FiscalYearEndMonth | TINYINT | لا |  |  | 1..12 (FR-ORG-006، BR-ORG-004) |
| FiscalYearEndDay | TINYINT | نعم |  |  | فارغ = آخر الشهر |
| BaseCurrencyId | INT | نعم |  | ref.Currency | العملة الأساسية (FR-ORG-008)؛ المواصفة تسميه BaseCurrencyCode |
| OwnershipStatus | VARCHAR(12) | لا | UNDOCUMENTED |  | اكتمال توثيق الملكية (FR-ORG-016) enum: COMPLETE, UNDOCUMENTED |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyId) · UQ(PublicId) · UQ(TenantId, CompanyCode) · UQ(TenantId, RefCode) WHERE RefCode IS NOT NULL · UQ(TenantId, PartyId) · UQ(TenantId, CountryId, CrNumber) WHERE CrNumber IS NOT NULL AND Status <> 'ARCHIVED' · UQ(TenantId, ErpCodeNormalized) WHERE ErpCompanyCode IS NOT NULL AND Status <> 'ARCHIVED'

**قيود:** `FiscalYearEndMonth BETWEEN 1 AND 12` · `RefCode IS NULL OR RefCode COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z0-9]' OR RefCode COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z0-9][A-Z0-9]'` · `FiscalYearEndDay IS NULL OR FiscalYearEndDay BETWEEN 1 AND 31` · `ParentCompanyId IS NULL OR ParentCompanyId <> CompanyId` · `ErpCompanyCode IS NULL OR LEN(ErpCompanyCode) > 0`

### `org.CompanyTaxRate` — Tax rate with an effective date; NULL CompanyId = tenant default (FR-ORG-007, BR-ORG-005)

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

### `org.Department` — Department (FR-ORG-014, BR-ORG-016, Q-ORG-09): at tenant level, optionally per company

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

### `org.Shareholding` — Ownership interest with an effective date; the owner is a Party, an individual or an entity (FR-ORG-015..018, BR-ORG-006..008, G-7)

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
| IntermediatePartyId | BIGINT | نعم |  | pty.Party | الوسيط المسمّى لمسار غير مباشر (Layer >= 2)، فارغ للمالك المباشر؛ صف لكل مسار، ولا يكون الوسيط شركة من شركات المشترك لأن مسارها مشتق من ملكياتها المباشرة (DR-22، BR-ORG-008؛ قادح في 044) |
| IsBeneficialOwner | BIT | لا | 0 |  | مستفيد حقيقي >= 25% أو تحكم (G-7) |
| EffectiveFrom | DATE | لا |  |  |  |
| EffectiveTo | DATE | نعم |  |  | القديم يُغلق بيوم قبل السريان الجديد (BR-ORG-007) |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ShareholdingId) · UQ(TenantId, CompanyId, HolderPartyId, Layer, IntermediatePartyId, EffectiveFrom) · UQ(TenantId, CompanyId, HolderPartyId, Layer, IntermediatePartyId) WHERE EffectiveTo IS NULL

**قيود:** `SharePercent > 0 AND SharePercent <= 100` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `Layer >= 1` · `(Layer = 1 AND IntermediatePartyId IS NULL) OR (Layer >= 2 AND IntermediatePartyId IS NOT NULL)` · `IntermediatePartyId IS NULL OR IntermediatePartyId <> HolderPartyId` · `SharesCount IS NULL OR SharesCount > 0` · `NominalValue IS NULL OR (NominalValue >= 0 AND CurrencyId IS NOT NULL)`

### `org.GoverningBody` — Governing body (FR-ORG-019, BR-ORG-009)

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

### `org.BodyMember` — Membership of a governing body (FR-ORG-020, FR-ORG-021, BR-ORG-010)

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

### `org.AuthorityGrant` — Authority grant to a company (FR-ORG-023..028, BR-ORG-011..014)

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
| SupersedesGrantId | BIGINT | نعم |  | org.AuthorityGrant (via CompanyId) | المنحة الجديدة تحل محل القديمة للشركة نفسها (BR-ORG-014، DR-21) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuthorityGrantId) · UQ(PublicId)

**قيود:** `(GranteeKind = 'BODY' AND BodyId IS NOT NULL AND BodyMemberId IS NULL AND PartyId IS NULL) OR (GranteeKind = 'BODY_MEMBER' AND BodyId IS NULL AND BodyMemberId IS NOT NULL AND PartyId IS NULL) OR (GranteeKind = 'PARTY' AND BodyId IS NULL AND BodyMemberId IS NULL AND PartyId IS NOT NULL)` · `CeilingAmount IS NULL OR CeilingAmount > 0` · `(CeilingAmount IS NULL AND CeilingCurrencyId IS NULL) OR (CeilingAmount IS NOT NULL AND CeilingCurrencyId IS NOT NULL)` · `(RequiresJoint = 1 AND JointMinSignatories IS NOT NULL AND JointMinSignatories >= 2) OR (RequiresJoint = 0 AND JointMinSignatories IS NULL)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `Status IN ('DRAFT','PENDING_APPROVAL') OR SourceDocumentId IS NOT NULL OR ExceptionReason IS NOT NULL` · `Status <> 'REVOKED' OR (RevokedAt IS NOT NULL AND RevokedReason IS NOT NULL)` · `SupersedesGrantId IS NULL OR SupersedesGrantId <> AuthorityGrantId` · `Status IN ('DRAFT','PENDING_APPROVAL') OR (ApprovedBy IS NOT NULL AND ApprovedAt IS NOT NULL)` · `(ApprovedBy IS NULL AND ApprovedAt IS NULL) OR (ApprovedBy IS NOT NULL AND ApprovedAt IS NOT NULL)`

### `org.CompanyProfile` — Company profile, 1:1 (G-1)

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

### `org.CompanyBranch` — Branch, warehouse or subsidiary outside the account, held as text (G-3)

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

### `org.CompanyKycFinancialProfile` — KYC financial profile with an effective date: revenue band and purpose (G-4)

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

### `org.CompanyExpectedFlow` — Monthly expected cash-flow matrix (CTP): direction x five items (G-4)

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

### `org.CompanyWealthSource` — Sources of funds and wealth: multiple-value list (G-4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| FinancialProfileId | BIGINT | لا |  | org.CompanyKycFinancialProfile | no cascade (O-13): a KYC profile is dated history; removing it takes an explicit retention step |
| WealthSourceId | INT | لا |  | cat.LookupItem | قائمة WEALTH_SOURCE (تمويل داخلي، إيرادات تجارية، تسهيلات، بيع أصول...) |
| OtherText | NVARCHAR(200) | نعم |  |  | وصف عند «أخرى» |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, FinancialProfileId, WealthSourceId)

### `org.CompanyDisclosure` — Company disclosures (G-5)

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

### `org.CompanyKeyRelation` — Key relations: auditors, legal counsel, regulators, and major customers and suppliers (G-6)

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

### `pty.Party` — Person or entity; no stored role (FR-PTY-001..003, BR-PTY-001..004, BR-PTY-016..018)

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
| IsActive | BIT | لا | 1 |  |  |
| MergedIntoPartyId | BIGINT | نعم |  | pty.Party | Merged لا تعود (BR-PTY-016) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PartyId) · UQ(PublicId) · UQ(TenantId, PartyCode)

**قيود:** `NameAr IS NOT NULL OR NameEn IS NOT NULL` · `Kind = 'INDIVIDUAL' OR (ResidencyStatus IS NULL AND BirthDate IS NULL AND MaritalStatus IS NULL AND Gender IS NULL AND EducationLevelId IS NULL)` · `MergedIntoPartyId IS NULL OR (IsActive = 0 AND MergedIntoPartyId <> PartyId)`

### `pty.IdentityDocument` — Identity document; the number is encrypted and images are restricted documents (FR-PTY-004..009, FR-PTY-020..022, BR-PTY-002..008)

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
| EncKeyPurpose | VARCHAR(11) | لا | DATA |  | enum: DATA |
| EncKeyId | BIGINT | لا |  | sec.TenantKey (via EncKeyPurpose) | مفتاح DATA لهذا الصف (إصدار صريح؛ 06 §6، DR-02) |
| HashKeyPurpose | VARCHAR(11) | لا | BLIND_INDEX |  | enum: BLIND_INDEX |
| HashKeyId | BIGINT | لا |  | sec.TenantKey (via HashKeyPurpose) | مفتاح BLIND_INDEX لبصمة NumberHash (DR-02) |
| IssueDate | DATE | نعم |  |  |  |
| IssueDateHijriText | NVARCHAR(20) | نعم |  |  | G-11 |
| ExpiryDate | DATE | نعم |  |  |  |
| ExpiryDateHijriText | NVARCHAR(20) | نعم |  |  | G-11 |
| IsPrimary | BIT | لا | 0 |  | أساسية واحدة بين غير المستبدلة (BR-PTY-005) |
| IsSuperseded | BIT | لا | 0 |  | «مستبدلة» مخزَّنة عند التجديد (القسم 8)؛ تُعلَّم أولًا ثم يُنشأ البديل ثم يُربط SupersededById ضمن معاملة التجديد (الرقم نفسه يتكرر في تجديد الهوية) |
| SupersededById | BIGINT | نعم |  | pty.IdentityDocument (via PartyId) | التجديد ينشئ وثيقة جديدة للطرف نفسه تستبدل القديمة (FR-PTY-022، BR-PTY-006، DR-23) |
| VerifiedAt | DATETIME2(3) | نعم |  |  | «تم التحقق من الأصل» (FR-PTY-020) |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IdentityDocumentId) · UQ(PublicId) · UQ(TenantId, DocKind, IssuingCountryId, NumberHash) WHERE IsSuperseded = 0 · UQ(TenantId, PartyId) WHERE IsPrimary = 1

**قيود:** `ExpiryDate IS NULL OR IssueDate IS NULL OR ExpiryDate > IssueDate` · `SupersededById IS NULL OR (SupersededById <> IdentityDocumentId AND IsSuperseded = 1)` · `DATALENGTH(NumberEnc) >= 29` · `IsSuperseded = 0 OR IsPrimary = 0` · `VerifiedBy IS NULL OR VerifiedAt IS NOT NULL`

### `pty.Address` — Postal address with an exclusive owner arc: exactly one of Party, Institution, Unit or Contact (FR-PTY-011, BR-PTY-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AddressId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | نعم |  | pty.Party | قوس المالك: شخص (واحد من أربعة فقط؛ DR-04) |
| InstitutionId | BIGINT | نعم |  | ins.Institution | قوس المالك: منشأة |
| UnitId | BIGINT | نعم |  | ins.InstitutionUnit | قوس المالك: فرع/وحدة |
| ContactId | BIGINT | نعم |  | ins.Contact | قوس المالك: جهة اتصال |
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

**المفاتيح:** PK(AddressId) · UQ(TenantId, PartyId) WHERE IsPrimary = 1 AND IsCurrent = 1 AND PartyId IS NOT NULL · UQ(TenantId, InstitutionId) WHERE IsPrimary = 1 AND IsCurrent = 1 AND InstitutionId IS NOT NULL · UQ(TenantId, UnitId) WHERE IsPrimary = 1 AND IsCurrent = 1 AND UnitId IS NOT NULL · UQ(TenantId, ContactId) WHERE IsPrimary = 1 AND IsCurrent = 1 AND ContactId IS NOT NULL

**قيود:** `(PartyId IS NOT NULL AND InstitutionId IS NULL AND UnitId IS NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NOT NULL AND UnitId IS NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NULL AND UnitId IS NOT NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NULL AND UnitId IS NULL AND ContactId IS NOT NULL)` · `IsPrimary = 0 OR IsCurrent = 1` · `AddressType <> 'PO_BOX' OR PoBoxNumber IS NOT NULL`

### `pty.ContactMethod` — Contact method (phone, e-mail and similar) with an exclusive owner arc, as for addresses (FR-PTY-012, BR-PTY-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ContactMethodId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | نعم |  | pty.Party | قوس المالك (واحد من أربعة؛ DR-04) |
| InstitutionId | BIGINT | نعم |  | ins.Institution |  |
| UnitId | BIGINT | نعم |  | ins.InstitutionUnit |  |
| ContactId | BIGINT | نعم |  | ins.Contact |  |
| Kind | VARCHAR(10) | لا |  |  | enum: MOBILE, PHONE, EMAIL, FAX, WEBSITE, OTHER |
| Value | NVARCHAR(200) | لا |  |  |  |
| NormalizedValue | NVARCHAR(200) | لا |  |  | هاتف E.164 / بريد صغير الأحرف؛ مطلوب لتنفيذ الفرادة |
| Label | NVARCHAR(100) | نعم |  |  |  |
| IsPrimary | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ContactMethodId) · UQ(TenantId, PartyId, Kind, NormalizedValue) WHERE PartyId IS NOT NULL · UQ(TenantId, InstitutionId, Kind, NormalizedValue) WHERE InstitutionId IS NOT NULL · UQ(TenantId, UnitId, Kind, NormalizedValue) WHERE UnitId IS NOT NULL · UQ(TenantId, ContactId, Kind, NormalizedValue) WHERE ContactId IS NOT NULL · UQ(TenantId, PartyId, Kind) WHERE IsPrimary = 1 AND PartyId IS NOT NULL · UQ(TenantId, InstitutionId, Kind) WHERE IsPrimary = 1 AND InstitutionId IS NOT NULL · UQ(TenantId, UnitId, Kind) WHERE IsPrimary = 1 AND UnitId IS NOT NULL · UQ(TenantId, ContactId, Kind) WHERE IsPrimary = 1 AND ContactId IS NOT NULL

**قيود:** `(PartyId IS NOT NULL AND InstitutionId IS NULL AND UnitId IS NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NOT NULL AND UnitId IS NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NULL AND UnitId IS NOT NULL AND ContactId IS NULL) OR (PartyId IS NULL AND InstitutionId IS NULL AND UnitId IS NULL AND ContactId IS NOT NULL)`

### `pty.CustomFieldDefinition` — Custom field definition (FR-PTY-013, BR-PTY-014)

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

### `pty.PartyCustomField` — Custom-field value for a party (FR-PTY-013, FR-PTY-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PartyCustomFieldId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| DefinitionId | BIGINT | لا |  | pty.CustomFieldDefinition |  |
| ValueText | NVARCHAR(1000) | نعم |  |  |  |
| ValueEnc | VARBINARY(512) | نعم |  |  | للحقل المقيَّد بدل ValueText 🔒 restricted |
| EncKeyPurpose | VARCHAR(11) | لا | DATA |  | enum: DATA |
| EncKeyId | BIGINT | نعم |  | sec.TenantKey (via EncKeyPurpose) | مفتاح DATA لقيمة الحقل المقيَّد (DR-02) |
| ValueMask | NVARCHAR(32) | نعم |  |  | قناع يُحسب عند الكتابة (BR-PTY-008) |
| CurrencyId | INT | نعم |  | ref.Currency | لنوع AMOUNT |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PartyCustomFieldId) · UQ(TenantId, PartyId, DefinitionId)

**قيود:** `ValueText IS NULL OR ValueEnc IS NULL` · `ValueEnc IS NULL OR ValueMask IS NOT NULL` · `ValueEnc IS NULL OR (EncKeyId IS NOT NULL AND DATALENGTH(ValueEnc) >= 29)`

### `pty.KycProfile` — KYC completeness checklist per bank and role (FR-PTY-023, BR-PTY-012..013, G-8, G-14)

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
| SeedKey | VARCHAR(80) | نعم |  |  | KYC-CORP-BASE / BANK-A / BANK-B / BANK-C / PERSON-SIGNATORY / PERSON-OWNER / GUARANTOR (05 قسم 3) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(KycProfileId) · UQ(PublicId) · UQ(TenantId, InstitutionId, AppliesToRole, AppliesToKind, Version) · UQ(TenantId, InstitutionId, AppliesToRole, AppliesToKind) WHERE Status = 'ACTIVE' · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `InstitutionId IS NOT NULL OR IsBaseline = 1` · `Version >= 1` · `OwnerThresholdPct IS NULL OR (OwnerThresholdPct > 0 AND OwnerThresholdPct <= 100)`

### `pty.KycProfileItem` — Completeness item (FR-PTY-023, FR-PTY-024, G-14)

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

### `pty.KycProfileItemLegalForm` — Conditions for an item to apply, by legal form; no rows = applies to all (G-15)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| KycProfileItemId | BIGINT | لا |  | pty.KycProfileItem | the condition is part of its item (O-13); items change only in a DRAFT version (041) |
| LegalEntityTypeId | INT | لا |  | cat.LegalEntityType |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, KycProfileItemId, LegalEntityTypeId)

### `pty.PartyCompliance` — Dated compliance declarations per person in their capacity: PEP, sanctions, investigations, immunity (G-9)

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

### `pty.TaxIdentity` — Tax identity and FATCA/CRS tax declaration (G-13)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TaxIdentityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| PartyId | BIGINT | لا |  | pty.Party |  |
| CountryId | INT | لا |  | ref.Country | بلد الإقامة الضريبية |
| TaxNumber | VARCHAR(40) | نعم |  |  | الرقم الضريبي؛ رقم الشركة يُقرأ من صف مرآتها الحالي في دولة تأسيسها عبر org.v_CompanyTaxIdentity (DQ-F02-8، DR-25) 🔒 confidential |
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

### `ref.Country` — Country: global reference, read-only, managed by the platform operator (FR-CAT-026, BR-CAT-018, BR-CAT-015)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CountryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Iso2 | CHAR(2) | لا |  |  | ISO 3166-1 alpha-2 |
| Iso3 | CHAR(3) | لا |  |  | ISO 3166-1 alpha-3 |
| NameAr | NVARCHAR(100) | لا |  |  |  |
| NameEn | NVARCHAR(100) | لا |  |  |  |
| IsGcc | BIT | لا | 0 |  | عضو مجلس التعاون: الدول الست فقط في البذرة (قيمة مقترحة تُراجَع) |
| WeekendDays | VARCHAR(40) | نعم |  |  | رموز أيام العطلة الأسبوعية MON..SUN مفصولة بفاصلة (مثل FRI,SAT)؛ فارغ = غير محدد |
| DialCode | VARCHAR(8) | نعم |  |  | رمز الاتصال الدولي مثل +966 |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CountryId) · UQ(Iso2) · UQ(Iso3)

**قيود:** `Iso2 COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z]%' AND Iso3 COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z]%'` · `DialCode IS NULL OR (DialCode LIKE '+[0-9]%' AND DialCode NOT LIKE '+%[^0-9]%' AND DialCode NOT LIKE '+_____%')` · `WeekendDays IS NULL OR WeekendDays COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z,]%'`

### `ref.Currency` — Currency: global ISO 4217 reference, read-only (FR-CAT-021, Q-CAT-08)

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

**قيود:** `Decimals BETWEEN 0 AND 3` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z]%'` · `NumericCode NOT LIKE '%[^0-9]%'`

## CAT

### `ref.Industry` — An economic activity of the Saudi classification of economic activities (GASTAT, ISIC Rev.4): section and division; a company's main activity (docs/35 section 5)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **IndustryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(10) | لا |  |  | A ... U للقسم، أو C10 وF41 للفرع |
| SectionCode | CHAR(1) | لا |  |  |  |
| ParentId | INT | نعم |  | ref.Industry | الفرع تحت قسمه |
| NameAr | NVARCHAR(300) | لا |  |  |  |
| NameEn | NVARCHAR(300) | لا |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IndustryId) · UQ(Code)

**قيود:** `SectionCode COLLATE Arabic_100_BIN2 LIKE '[A-U]'` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%'`

### `cat.TenantCurrency` — Currencies enabled for the tenant: a subset of the global currency reference (FR-CAT-023, Q-CAT-08) -- جدول بنيوي جديد

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

### `cat.InstitutionType` — Financial institution type: bank, finance company, investment company, financial company, individual (FR-INS-001)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.AccountType` — Account type (FR-ACC-001)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LegalEntityType` — Legal entity type: the entity and its attributes are defined in specification 10 (FR-ORG-002, BR-CAT-017) and seeded by this module; catalogue columns are written by hand because code uniqueness is per country (specification 10, section 6.2), not global

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
| DefaultBodyTypes | VARCHAR(65) | نعم |  |  | هيئات الحوكمة الافتراضية للشكل (قيم GoverningBody.BodyType، DR-32) |
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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.DocumentType` — Document type; applies the flags defined in specification 10 at upload (FR-CAT-018, BR-CAT-016, FR-PLT-028)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)` · `MaxSizeMb IS NULL OR MaxSizeMb > 0` · `RetentionYears IS NULL OR RetentionYears > 0` · `MaxAgeDays IS NULL OR MaxAgeDays > 0`

### `cat.Position` — Job position: its attributes are defined in specification 10 (section 6.2) only, and this module seeds its rows (FR-CAT-019, BR-CAT-017); SortOrder comes from the catalogue base

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
| ApplicableBodyTypes | VARCHAR(65) | نعم |  |  | قيم GoverningBody.BodyType التي يصح فيها المنصب (DR-32) |
| IsSingleHolder | BIT | لا | 0 |  | منصب أحادي الشاغل (CHAIRMAN) -- BR-ORG-010 |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PositionId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.PowerType` — Governance power type: its attributes are defined in specification 10 (section 6.2) only, and this module seeds its rows (FR-CAT-019, FR-ORG-024)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.OperationType` — Bank operation type that a signatory is authorised for (FR-ACC-013, BR-CAT-014)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.OperationTypePowerType` — Links an operation to governance power type(s): any one is sufficient (BR-CAT-014, FR-CAT-019, Q-ACC-05) -- جدول وسيط جديد

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

### `cat.ProductCategory` — Product category: flat list (FR-CAT-007)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.Product` — Bank product with its flags (FR-CAT-007, BR-CAT-004)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.FeeType` — Fee type: a broad category, not a tariff item (FR-CAT-008, BR-CAT-005, Q-CAT-10)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.FinancingType` — Financing type (FR-CAT-009, BR-CAT-006)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.ProductFeeType` — Fee types allowed for a product; disabling a link deletes it and does not affect list pricing rules (FR-CAT-010, BR-CAT-007) -- يبقى بمفتاح بديل لأنه يحمل سمة

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

### `cat.ProductFinancingType` — Financing types allowed for a product (FR-CAT-010, BR-CAT-007); the pair respects the Shariah classification (DR-30)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ProductFinancingTypeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ProductCompliance | VARCHAR(12) | لا |  |  | نسخة من Product.Compliance؛ امتثال منتج مستعمل لا يتغير enum: CONVENTIONAL, ISLAMIC, NEUTRAL |
| ProductId | INT | لا |  | cat.Product (via ProductCompliance) |  |
| FinancingIsIslamic | BIT | لا |  |  | نسخة من FinancingType.IsIslamic؛ علَم نوع مستعمل لا يتغير |
| FinancingTypeId | INT | لا |  | cat.FinancingType (via FinancingIsIslamic) |  |
| IsDefault | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductFinancingTypeId) · UQ(TenantId, ProductId, FinancingTypeId) · UQ(TenantId, ProductId) WHERE IsDefault = 1

**قيود:** `ProductCompliance = 'NEUTRAL' OR (ProductCompliance = 'ISLAMIC' AND FinancingIsIslamic = 1) OR (ProductCompliance = 'CONVENTIONAL' AND FinancingIsIslamic = 0)`

### `cat.FacilityType` — Facility type (FR-CAT-011)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LimitType` — Limit type: master or sub-limit (FR-CAT-012, BR-CAT-008)

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

**قيود:** `(Kind = 'MAIN' AND ParentLimitTypeId IS NULL) OR (Kind = 'SUB' AND ParentLimitTypeId IS NOT NULL)` · `ParentLimitTypeId IS NULL OR ParentLimitTypeId <> LimitTypeId` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LimitTypeProduct` — Products allowed for a limit type; no rows = any product, with a visible flag (BR-CAT-008) -- جدول وسيط جديد

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

### `cat.CollateralType` — Collateral type with its structure type and attribute template (FR-CAT-013)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.CollateralTypeAttribute` — Attribute in a collateral-type template; never deleted, only marked Retired (BR-CAT-009) -- جدول جديد

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

### `cat.ObligationType` — Obligation type with four families (FR-CAT-014, BR-CAT-010)

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

**قيود:** `Family <> 'COVENANT' OR MeasureKind IS NOT NULL` · `MeasureKind IS NULL OR MeasureKind <> 'NONE' OR IsQualitative = 1` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.BaseRate` — Base rate: market-wide (InstitutionId NULL) or internal to a bank (FR-CAT-015, BR-CAT-011); alternative names are in BaseRateAlias

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
| CurrencyId | INT | لا |  | ref.Currency | لكل سعر عملته (DR-29) |
| StaleAfterDays | INT | نعم |  |  | تنبيه التقادم NTF-CAT-01 (الافتراضي 35 مقترح) |
| ScopeKey | BIGINT | نعم |  |  | نطاق الأسماء البديلة: 0 للسوق ورقم البنك للداخلي (DR-29) محسوب: `CASE WHEN InstitutionId IS NULL THEN 0 ELSE InstitutionId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BaseRateId) · UQ(TenantId, FamilyCode, Tenor, InstitutionId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(Kind = 'MARKET' AND InstitutionId IS NULL) OR (Kind = 'BANK_INTERNAL' AND InstitutionId IS NOT NULL)` · `StaleAfterDays IS NULL OR StaleAfterDays > 0` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.BaseRateAlias` — Alternative name for a base rate (for example SIBOR and SAIBOR); case-insensitive search; unique within scope (BR-CAT-011, FR-CAT-015) -- جدول وسيط جديد يحل «Aliases set»

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BaseRateAliasId** | INT IDENTITY | لا | | | مفتاح أساسي |
| BaseRateId | INT | لا |  | cat.BaseRate (via Tenor,ScopeKey) | الربط المركّب يضمن أن الفترة والنطاق المنسوخين يطابقان الأب (DR-29) |
| Tenor | VARCHAR(10) | لا |  |  | نسخة من BaseRate.Tenor: حل الاسم يكون بـ (نطاق + اسم بديل + فترة) في SVC-05 enum: ON, 1M, 3M, 6M, 12M |
| ScopeKey | BIGINT | لا |  |  | نسخة من BaseRate.ScopeKey: 0 للسوق ورقم البنك للداخلي؛ نطاق الفرادة والبحث (DR-29) |
| Alias | NVARCHAR(60) | لا |  |  |  |
| AliasKey | NVARCHAR(60) | نعم |  |  | مفتاح البحث والفرادة بلا حساسية حالة محسوب: `UPPER(Alias)` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BaseRateAliasId)

### `cat.BaseRateValue` — Base-rate value with an effective date; rows are never deleted: a correction inserts a new row and the old one becomes SUPERSEDED (FR-CAT-016, BR-CAT-012/013)

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

### `cat.LookupList` — Tenant-owned lookup list (FR-CAT-020, BR-CAT-015) -- DR-03: نسخة النظام تُهيَّأ لكل مشترك من قالب المنصة

*مملوك للمشترك · كتالوج*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
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
| Scope | VARCHAR(10) | لا |  |  | SYSTEM = نسخة من قالب المنصة لكل مشترك (IsSystem=1)؛ TENANT = قائمة يعرّفها المشترك enum: SYSTEM, TENANT |
| AllowTenantItems | BIT | لا | 0 |  | هل يضيف المشترك بنودًا لقائمة عالمية؟ |
| AttributeSchema | NVARCHAR(MAX) | نعم |  |  | مخطط سمات البنود (JSON Schema مبسّط) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LookupListId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `(Scope = 'SYSTEM' AND IsSystem = 1) OR (Scope = 'TENANT' AND IsSystem = 0)` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

### `cat.LookupItem` — Item in a tenant-owned lookup list (FR-CAT-020) -- DR-03/05/07: نسخ النظام لكل مشترك؛ فرادة الرمز داخل القائمة لا على مستوى المشترك

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)) AND (IsSystem = 0 OR NameEn IS NOT NULL)`

## INS

### `ins.Institution` — Financial institution (FR-INS-001..004, BR-INS-001..003, BR-INS-012); Locality (local or foreign) is derived (BR-INS-002) and therefore not stored

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InstitutionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  | رمز مطبَّع أحرف كبيرة بلا مسافات فريد في المشترك (BR-INS-001) |
| RefCode | VARCHAR(3) | نعم |  |  | رمز البنك الثلاثي في مرجع التسهيل، فريد في المشترك (BR-FAC-021، طلب المالك 2026-10-23) |
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

**المفاتيح:** PK(InstitutionId) · UQ(PublicId) · UQ(TenantId, Code) · UQ(TenantId, RefCode) WHERE RefCode IS NOT NULL · UQ(TenantId, PartyId) WHERE PartyId IS NOT NULL

**قيود:** `Code NOT LIKE '% %'` · `RefCode IS NULL OR RefCode COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z][A-Z]'` · `SwiftBic IS NULL OR SwiftBic COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z0-9][A-Z0-9]' OR SwiftBic COLLATE Arabic_100_BIN2 LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][A-Z][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]'`

### `ins.InstitutionUnit` — Unit in an institution's structure: division, department or branch; self-referencing tree of up to four levels (FR-INS-005/006, BR-INS-004)

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

### `ins.Contact` — Contact at a bank: a lightweight record with no identity; PartyId is optional, for promotion (FR-INS-007/008, BR-INS-005/006/014)

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

### `ins.Relationship` — Company–institution relationship (D-4); unique regardless of status (FR-INS-009, BR-INS-007/011)

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

### `ins.RelationshipContact` — Relationship coverage (first layer): contact with role, rank and period (FR-INS-010, BR-INS-008/009)

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

### `ins.RelationshipProduct` — Product handled within a relationship, with a default contact and channel (FR-INS-011..013, BR-INS-010)

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

### `acc.BankAccount` — Company bank account at a financial institution (FR-ACC-001..009, BR-ACC-001..006, BR-ACC-016); account number and IBAN are encrypted, with blind-index uniqueness

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
| EncKeyPurpose | VARCHAR(11) | لا | DATA |  | enum: DATA |
| EncKeyId | BIGINT | لا |  | sec.TenantKey (via EncKeyPurpose) | مفتاح DATA للرقم والآيبان في هذا الصف (DR-02) |
| HashKeyPurpose | VARCHAR(11) | لا | BLIND_INDEX |  | enum: BLIND_INDEX |
| HashKeyId | BIGINT | لا |  | sec.TenantKey (via HashKeyPurpose) | مفتاح BLIND_INDEX لبصمتي AccountNoHash وIbanHash (DR-02) |
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

**قيود:** `MinSignatures >= 1` · `DATALENGTH(AccountNoEnc) >= 29` · `IbanEnc IS NULL OR DATALENGTH(IbanEnc) >= 29` · `MasterAccountId IS NULL OR MasterAccountId <> BankAccountId` · `(IbanEnc IS NULL AND IbanMask IS NULL AND IbanHash IS NULL) OR (IbanEnc IS NOT NULL AND IbanMask IS NOT NULL AND IbanHash IS NOT NULL)` · `ClosedOn IS NULL OR OpenedOn IS NULL OR ClosedOn >= OpenedOn` · `Status <> 'CLOSED' OR (ClosedOn IS NOT NULL AND ClosureReason IS NOT NULL)` · `(ClosedOn IS NULL AND ClosureReason IS NULL) OR Status = 'CLOSED'`

### `acc.FacilityAccount` — Account linked to a facility for a specific purpose (S2) (FR-ACC-010, BR-ACC-007); populated from the facility screen

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

### `acc.Signatory` — Person authorised to sign for a relationship (S1-B) (FR-ACC-012, FR-ACC-023, BR-ACC-008/009), plus additions from docs/05 G-10

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
| Status | VARCHAR(10) | لا | PENDING |  | EXPIRED آليًا بعد ValidTo؛ REVOKED وEXPIRED نهائيان (043)؛ التجديد صف جديد enum: PENDING, ACTIVE, SUSPENDED, EXPIRED, REVOKED |
| RevokedAt | DATETIME2(3) | نعم |  |  | سحب التفويض: التاريخ والسبب، والفاعل في UpdatedBy والتدقيق (DR-19) |
| RevokedReason | NVARCHAR(500) | نعم |  |  |  |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(SignatoryId) · UQ(PublicId) · UQ(TenantId, RelationshipId, PartyId, SignatureClassId, ValidFrom) · UQ(TenantId, RelationshipId, PartyId, SignatureClassId) WHERE ValidTo IS NULL AND Status <> 'REVOKED'

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `Status NOT IN ('ACTIVE','SUSPENDED','EXPIRED') OR AuthorizationDocumentId IS NOT NULL` · `(CashWithdrawalMode = 'LIMITED' AND CashWithdrawalLimit IS NOT NULL AND CashWithdrawalLimit > 0 AND CashWithdrawalCurrencyId IS NOT NULL) OR (CashWithdrawalMode <> 'LIMITED' AND CashWithdrawalLimit IS NULL)` · `Status <> 'REVOKED' OR (RevokedAt IS NOT NULL AND RevokedReason IS NOT NULL)` · `RevokedAt IS NULL OR Status = 'REVOKED'` · `Status <> 'EXPIRED' OR ValidTo IS NOT NULL`

### `acc.SignatoryAuthority` — Signatory authority for an operation on an account or on the bank (S1-B) (FR-ACC-013/014/017, BR-ACC-010/011); not edited in place: closed and reopened instead; its status is derived and not stored

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

### `acc.SignatoryAuthorityJointClass` — Signature classes required for joint signing (JointClassIds) (BR-ACC-013) -- جدول وسيط جديد؛ لا حذف: التعديل بصف صلاحية جديد

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

### `acc.AuthorityConflict` — Result of checking a signatory's authority against governance rules, and the reviewer's decision (S1-B) (FR-ACC-018, BR-ACC-015)

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
| AuthorityGrantId | BIGINT | نعم |  | org.AuthorityGrant | منحة الحوكمة المقارَنة (أقرب مرشح)؛ فارغة لـ NO_GRANT وNOT_MAPPED (S1B-GAP-13) |
| ResolvedOn | DATETIME2(3) | نعم |  |  | وقت زوال السبب آليًا |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AuthorityConflictId) · UQ(TenantId, SignatoryAuthorityId, ConflictCode, Fingerprint)

**قيود:** `Status <> 'ACKNOWLEDGED' OR (ReviewedBy IS NOT NULL AND ReviewedOn IS NOT NULL AND Reason IS NOT NULL)` · `ReviewedBy IS NULL OR ReviewedOn IS NOT NULL` · `(Status = 'RESOLVED' AND ResolvedOn IS NOT NULL) OR (Status <> 'RESOLVED' AND ResolvedOn IS NULL)`

## FAC

### `fac.Facility` — Facility agreement package: root of the aggregate (FR-FAC-001..008, BR-FAC-001/005/006)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityNo | VARCHAR(40) | لا |  |  | FAC-YY-NNN من NumberSequence (BR-FAC-001) |
| BankReferenceNo | NVARCHAR(80) | نعم |  |  | مرجع البنك: نص حر بلا صيغة (Q-FAC-01) |
| BankStructureNo | NVARCHAR(80) | نعم |  |  | رقم هيكل البنك: نص حر (Q-FAC-01) |
| PlatformRef | VARCHAR(30) | نعم |  |  | مرجع المنصة: الشركة-البنك-الفئة-السنة، مثل IMP-SNB-CAP-26؛ يُخصَّص عند الاعتماد الأول ولا يتغير، والتجديد بسنته (BR-FAC-021) |
| FacilityClassId | INT | نعم |  | cat.LookupItem | فئة التسهيل في المرجع: قائمة FACILITY_CLASS (CAP وSTL وMTL وLTL ...) (BR-FAC-021) |
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

**المفاتيح:** PK(FacilityId) · UQ(PublicId) · UQ(TenantId, FacilityNo) · UQ(TenantId, PlatformRef) WHERE PlatformRef IS NOT NULL · UQ(TenantId, PreviousFacilityId) WHERE PreviousFacilityId IS NOT NULL

**قيود:** `ExpiryDate >= EffectiveFrom` · `AgreementDate IS NULL OR AgreementDate <= EffectiveFrom` · `TotalAmount > 0` · `PlatformRef IS NULL OR PlatformRef COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9-]%'` · `LifecycleStatus = 'DRAFT' OR PlatformRef IS NOT NULL` · `PreviousFacilityId IS NULL OR PreviousFacilityId <> FacilityId` · `NoticeDays IS NULL OR NoticeDays >= 0` · `BankUnilateralRights IS NULL OR BankUnilateralRights NOT LIKE '%CHANGE_PRICING%' OR NoticeDays IS NOT NULL` · `HijriAdjusted = 0 OR HijriAdjustReason IS NOT NULL` · `LifecycleStatus NOT IN ('SUSPENDED','EXPIRED','TERMINATED') OR LifecycleReason IS NOT NULL` · `ApprovedRevisionNo >= 0` · `LifecycleStatus = 'DRAFT' OR ApprovedRevisionNo >= 1` · `AlertLeadDays IS NULL OR AlertLeadDays NOT LIKE '%[^0-9,]%'`

### `fac.FacilityRevision` — Preparer and approver revision of facility terms (FR-FAC-024, BR-FAC-003/004, section 8)

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

### `fac.FacilityDocument` — Document within the package, with precedence (FR-FAC-004, BR-FAC-008, V-FAC-03); its type comes from doc.Document.DocumentTypeId

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
| SupersedesId | BIGINT | نعم |  | fac.FacilityDocument (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN FacilityDocumentId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityDocumentId) · UQ(TenantId, FacilityId, DocumentId) WHERE ToRevision IS NULL · UQ(TenantId, FacilityId, PrecedenceRank) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `PrecedenceRank >= 1` · `PageCount IS NULL OR PageCount > 0` · `AmendsFacilityDocumentId IS NULL OR AmendsFacilityDocumentId <> FacilityDocumentId` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

### `fac.FacilityLender` — Lender and its share (FR-FAC-003, BR-FAC-007, V-FAC-02); shares total 100 and a single agent: checked by the application for every revision, and by trigger fac.TR_FacilityLender_ApprovedShares (db/static/050) for approved revisions

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
| SupersedesId | BIGINT | نعم |  | fac.FacilityLender (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN FacilityLenderId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityLenderId) · UQ(TenantId, FacilityId, InstitutionId) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `SharePct > 0 AND SharePct <= 100` · `Roles <> ''` · `Roles NOT LIKE '%SOLE%' OR SharePct = 100` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

### `fac.OutstandingSnapshot` — Snapshot of the recognised outstanding balance (FR-FAC-009, BR-FAC-017); PctOfLimit is derived and not stored

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
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**قيود:** `AcknowledgedAmount >= 0` · `StatedPct IS NULL OR StatedPct >= 0` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.Limit` — Limit-tree node (FR-FAC-010/011, BR-FAC-009/010, V-FAC-04..07)

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
| SupersedesId | BIGINT | نعم |  | fac.Limit (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN LimitId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitId) · UQ(TenantId, FacilityId, Code) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `(AmountBasis = 'ABSOLUTE' AND Amount IS NOT NULL AND PctOfParent IS NULL) OR (AmountBasis = 'PCT_OF_PARENT' AND PctOfParent IS NOT NULL AND Amount IS NULL)` · `Amount IS NULL OR Amount >= 0` · `PctOfParent IS NULL OR (PctOfParent > 0 AND PctOfParent <= 100)` · `EffectiveAmount IS NULL OR EffectiveAmount >= 0` · `ParentLimitId IS NULL OR ParentLimitId <> LimitId` · `StartDate IS NULL OR EndDate IS NULL OR EndDate >= StartDate` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.LimitProductLine` — Product line within a limit, with an optional SHARED_CAP ceiling (FR-FAC-012, V-FAC-08)

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
| SupersedesId | BIGINT | نعم |  | fac.LimitProductLine (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN LimitProductLineId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitProductLineId) · UQ(TenantId, LimitId, ProductId, BankProductCode) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `(AmountBasis IS NULL AND Amount IS NULL AND PctOfParent IS NULL) OR (AmountBasis IS NOT NULL AND ((AmountBasis = 'ABSOLUTE' AND Amount IS NOT NULL AND PctOfParent IS NULL) OR (AmountBasis = 'PCT_OF_PARENT' AND PctOfParent IS NOT NULL AND Amount IS NULL)))` · `Amount IS NULL OR Amount >= 0` · `PctOfParent IS NULL OR (PctOfParent > 0 AND PctOfParent <= 100)` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.LimitCompanyRule` — Company rule on a limit: allowed, excluded or allocated (FR-FAC-013, BR-FAC-012, V-FAC-09)

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
| SupersedesId | BIGINT | نعم |  | fac.LimitCompanyRule (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN LimitCompanyRuleId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LimitCompanyRuleId) · UQ(TenantId, LimitId, CompanyId, RuleKind, ValidFrom) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `RuleKind <> 'ALLOCATION' OR (AllocationAmount IS NOT NULL AND AllocationPct IS NULL) OR (AllocationAmount IS NULL AND AllocationPct IS NOT NULL)` · `RuleKind = 'ALLOCATION' OR (AllocationAmount IS NULL AND AllocationPct IS NULL)` · `AllocationAmount IS NULL OR AllocationAmount > 0` · `AllocationPct IS NULL OR (AllocationPct > 0 AND AllocationPct <= 100)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.ProductLineTerm` — Operational terms of a product line with effective dates; NULL means 'not specified', not zero (FR-FAC-014, BR-FAC-016)

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
| SupersedesId | BIGINT | نعم |  | fac.ProductLineTerm (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN ProductLineTermId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductLineTermId) · UQ(TenantId, LimitProductLineId, EffectiveFrom) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `MaxTotalTenorDays IS NULL OR MaxTotalTenorDays >= 0` · `MaxDeferralDays IS NULL OR MaxDeferralDays >= 0` · `MaxPostDeferralFinancingDays IS NULL OR MaxPostDeferralFinancingDays >= 0` · `LcValidityDays IS NULL OR LcValidityDays >= 0` · `AdvanceNoticeDays IS NULL OR AdvanceNoticeDays >= 0` · `CashCoverPct IS NULL OR (CashCoverPct >= 0 AND CashCoverPct <= 100)` · `FinancingRatioPct IS NULL OR (FinancingRatioPct >= 0 AND FinancingRatioPct <= 100)` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.Utilization` — Active utilisation item: manual or linked to a letter of credit; never deleted (FR-FAC-016/030, BR-FAC-013/020)

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
| SourceRequestId | BIGINT | نعم |  | wfl.Request (via CompanyId) | OTHER_REQUEST: الطلب العام لشركة البند نفسها. بند LC يربطه lc.LetterOfCredit.UtilizationId وحده (DQ-F12-14، DR-26) |
| Status | VARCHAR(11) | لا | ACTIVE |  | RELEASED وTRANSFERRED نهائيتان (§8)؛ TRANSFERRED: نُقل إلى اللاحق عند التجديد (DQ-F14-5، B6) enum: ACTIVE, RELEASED, TRANSFERRED |
| ReleasedOn | DATE | نعم |  |  |  |
| ReleaseReason | NVARCHAR(500) | نعم |  |  |  |
| TransferredToFacilityId | BIGINT | نعم |  | fac.Facility (via FacilityId) | التسهيل اللاحق لهذا التسهيل نفسه (BR-FAC-006) |
| TransferredToId | BIGINT | نعم |  | fac.Utilization (via TransferredToFacilityId) | البند الجديد في اللاحق، في العقدة بالرمز نفسه (يتحقق التطبيق) |
| TransferredOn | DATE | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(UtilizationId) · UQ(PublicId) · UQ(TenantId, SourceRequestId) WHERE SourceRequestId IS NOT NULL · UQ(TenantId, TransferredToId) WHERE TransferredToId IS NOT NULL

**قيود:** `Amount >= 0` · `Status = 'RELEASED' OR Amount > 0` · `(SourceType = 'OTHER_REQUEST' AND SourceRequestId IS NOT NULL) OR (SourceType <> 'OTHER_REQUEST' AND SourceRequestId IS NULL)` · `RateToFacilityCcy IS NULL OR RateToFacilityCcy > 0` · `MaturityDate IS NULL OR MaturityDate >= StartDate` · `Status <> 'RELEASED' OR (ReleasedOn IS NOT NULL AND ReleaseReason IS NOT NULL)` · `Status = 'RELEASED' OR (ReleasedOn IS NULL AND ReleaseReason IS NULL)` · `(Status = 'TRANSFERRED' AND TransferredToFacilityId IS NOT NULL AND TransferredToId IS NOT NULL AND TransferredOn IS NOT NULL) OR (Status <> 'TRANSFERRED' AND TransferredToFacilityId IS NULL AND TransferredToId IS NULL AND TransferredOn IS NULL)`

### `fac.LimitReservation` — Amount reserved for a request, equal to ExposureAmount (FR-FAC-017/018/020, BR-FAC-015)

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

### `fac.LimitMovement` — Movement record on a reservation or usage; no update or delete; duplicate-prevention key (BR-FAC-015, BR-FAC-020)

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
| OpKind | VARCHAR(10) | لا |  |  | TRANSFER: البند نُقل إلى اللاحق عند التجديد (DQ-F14-5، B6) enum: CREATE, ADJUST, CONVERT, RELEASE, TRANSFER |
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

**قيود:** `(TargetKind = 'RESERVATION' AND LimitReservationId IS NOT NULL AND UtilizationId IS NULL) OR (TargetKind = 'UTILIZATION' AND UtilizationId IS NOT NULL AND LimitReservationId IS NULL)` · `AmountAfter IS NULL OR AmountAfter >= 0` · `AppliedDelta IS NULL OR RequestedDelta IS NULL OR ABS(AppliedDelta) <= ABS(RequestedDelta)` · `OpKind <> 'ADJUST' OR AmountBefore IS NULL OR AmountAfter IS NULL OR AppliedDelta IS NULL OR AmountAfter = AmountBefore + AppliedDelta` · `OpKind <> 'TRANSFER' OR (TargetKind = 'UTILIZATION' AND Reason IS NOT NULL)`

### `fac.FacilityLenderDecision` — The lender's actual decision on a facility in a time of risk: keep it, stop its undrawn limit, reduce it, not renew it, and any change of margin or fees; the latest decision effective on a date is the lender's stance then, and the credit assessment uses it in place of its estimate (docs/35 section 14, ADR 0021)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **FacilityLenderDecisionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LenderInstitutionId | BIGINT | نعم |  | ins.Institution | البنك صاحب القرار (فارغ: كل المقرضين) |
| DecisionDate | DATE | لا |  |  |  |
| EffectiveDate | DATE | لا |  |  |  |
| LimitAction | VARCHAR(15) | لا |  |  | enum: MAINTAINED, UNDRAWN_STOPPED, LIMIT_REDUCED, NOT_RENEWED |
| NewLimitAmount | DECIMAL(19,4) | نعم |  |  | الحد الجديد بعملة التسهيل، للتخفيض وحده |
| MarginChangeBp | INT | لا | 0 |  | تغيّر الهامش بنقاط الأساس على المستعمل |
| FeesChangeBp | INT | لا | 0 |  | تغيّر الرسوم الإدارية بنقاط الأساس سنويًا |
| Note | NVARCHAR(1000) | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(FacilityLenderDecisionId) · UQ(TenantId, FacilityId, EffectiveDate)

**قيود:** `EffectiveDate >= DecisionDate` · `(LimitAction = 'LIMIT_REDUCED' AND NewLimitAmount IS NOT NULL AND NewLimitAmount >= 0) OR (LimitAction <> 'LIMIT_REDUCED' AND NewLimitAmount IS NULL)` · `MarginChangeBp BETWEEN -1000 AND 2000 AND FeesChangeBp BETWEEN -1000 AND 2000` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fac.ValueConflict` — Conflict between two values of one field, and its resolution (FR-FAC-026, BR-FAC-019, BR-FAC-008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ValueConflictId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | نعم |  | fac.Facility | مفتاح النطاق؛ إلزامي إلا لهدف بلا تسهيل: ضمان أو بند تعرفة أو قالب معادلة (قرار المالك 2026-10-13، DR-27) |
| TargetEntity | VARCHAR(60) | لا |  |  | الكيان المستهدف من جداول المصدر وحدها (القيد أدناه)؛ وجوده وتسهيله يتحقق منهما قبل S2 |
| TargetId | BIGINT | لا |  |  |  |
| FieldName | VARCHAR(80) | لا |  |  |  |
| CandidateAValue | NVARCHAR(1000) | لا |  |  | القيمة + ختم المصدر (A) |
| CandidateASourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CandidateASourcePage | VARCHAR(40) | نعم |  |  |  |
| CandidateAReadFromScan | BIT | لا | 0 |  |  |
| CandidateAOriginalText | NVARCHAR(2000) | نعم |  |  | DR-31 🔒 confidential |
| CandidateAConfidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| CandidateBValue | NVARCHAR(1000) | لا |  |  | القيمة + ختم المصدر (B) |
| CandidateBSourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| CandidateBSourcePage | VARCHAR(40) | نعم |  |  |  |
| CandidateBReadFromScan | BIT | لا | 0 |  |  |
| CandidateBOriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**قيود:** `Status <> 'RESOLVED' OR (ChosenSide IS NOT NULL AND ResolutionReason IS NOT NULL AND ResolvedBy IS NOT NULL AND ResolvedOn IS NOT NULL)` · `Status = 'RESOLVED' OR (ChosenSide IS NULL AND ResolvedBy IS NULL AND ResolvedOn IS NULL)` · `TargetEntity IN ('fac.Facility','fac.Limit','fac.LimitProductLine','fac.LimitCompanyRule','fac.ProductLineTerm','fac.OutstandingSnapshot','prc.TariffItem','prc.PricingRule','cmp.TermValue','col.Collateral','obl.Obligation','fin.MeasureFormula')` · `FacilityId IS NOT NULL OR TargetEntity IN ('col.Collateral','prc.TariffItem','fin.MeasureFormula')` · `ChosenSide IS NULL OR ChosenSide <> 'OTHER' OR ResolvedValue IS NOT NULL` · `CandidateASourceDocumentId IS NOT NULL AND CandidateASourcePage IS NOT NULL OR (CandidateASourceDocumentId IS NULL AND CandidateAConfidence = 'ENTERED_NO_DOCUMENT')` · `CandidateBSourceDocumentId IS NOT NULL AND CandidateBSourcePage IS NOT NULL OR (CandidateBSourceDocumentId IS NULL AND CandidateBConfidence = 'ENTERED_NO_DOCUMENT')` · `CandidateAOriginalText IS NULL OR (CandidateAOriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND CandidateAOriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `CandidateBOriginalText IS NULL OR (CandidateBOriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND CandidateBOriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')`

## PRC

### `prc.TariffSchedule` — Bank tariff schedule version; optionally specific to a facility (FR-PRC-001, BR-PRC-001, V-PRC-01)

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

### `prc.TariffItem` — Fee item in a tariff schedule (FR-PRC-002, BR-PRC-002..005)

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
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**قيود:** `ChargeKind <> 'PERCENT' OR (Rate IS NOT NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `ChargeKind <> 'FIXED' OR (FixedAmount IS NOT NULL AND Rate IS NULL AND PerMillionAmount IS NULL)` · `ChargeKind <> 'PER_MILLION' OR (PerMillionAmount IS NOT NULL AND Rate IS NULL AND FixedAmount IS NULL)` · `ChargeKind <> 'TIERED' OR (Rate IS NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `Rate IS NULL OR (Rate >= 0 AND Rate <= 100)` · `PeriodBasis <> 'PER_PERIOD_OR_PART' OR PeriodDays IS NOT NULL` · `PeriodDays IS NULL OR PeriodDays > 0` · `MinAmount IS NULL OR MinAmount >= 0` · `MinAmount IS NULL OR MaxAmount IS NULL OR MinAmount <= MaxAmount` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `prc.TariffTier` — Tier of a tariff item by amount and/or term (FR-PRC-003, BR-PRC-002)

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

### `prc.PricingRule` — Pricing rule with scope, inheritance and methods (FR-PRC-006..017, BR-PRC-006..012, V-PRC-02)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PricingRuleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| ScopeLimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | بلا نطاق = مستوى التسهيل |
| ScopeLimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,ScopeLimitId) | DR-06: الخط من الحد نفسه |
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
| SupersedesId | BIGINT | نعم |  | prc.PricingRule (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN PricingRuleId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PricingRuleId) · UQ(TenantId, FacilityId, FeeTypeId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, EffectiveFrom) WHERE ToRevision IS NULL AND FeeTypeId IS NOT NULL · UQ(TenantId, FacilityId, FinancingTypeId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, EffectiveFrom) WHERE ToRevision IS NULL AND FeeTypeId IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `ScopeLimitProductLineId IS NULL OR ScopeLimitId IS NOT NULL` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `ComponentKind <> 'FINANCING_RETURN' OR FeeTypeId IS NULL` · `ComponentKind = 'FINANCING_RETURN' OR (FeeTypeId IS NOT NULL AND FinancingTypeId IS NULL)` · `ComponentKind <> 'PENALTY_NON_INCOME' OR TriggerEvent IS NOT NULL` · `ComponentKind = 'PENALTY_NON_INCOME' OR TriggerEvent IS NULL` · `RateState <> 'NOT_SPECIFIED_IN_AGREEMENT' OR (AddOnPct IS NULL AND MarginPct IS NULL AND RatePct IS NULL AND RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL AND FixedAmount IS NULL AND PerMillionAmount IS NULL)` · `RateState <> 'SET' OR Method <> 'TARIFF_AS_IS' OR TariffItemId IS NOT NULL` · `RateState <> 'SET' OR Method <> 'TARIFF_PLUS_ADDON' OR (TariffItemId IS NOT NULL AND AddOnPct IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'BASE_PLUS_MARGIN' OR (BaseRateId IS NOT NULL AND MarginPct IS NOT NULL AND RateFixing IS NOT NULL AND DayCount IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'PERCENT_OF_AMOUNT' OR RatePct IS NOT NULL OR (RateRangeLowPct IS NOT NULL AND RateRangeHighPct IS NOT NULL)` · `RateState <> 'SET' OR Method <> 'FIXED_AMOUNT' OR FixedAmount IS NOT NULL` · `RateState <> 'SET' OR Method <> 'PER_MILLION' OR PerMillionAmount IS NOT NULL` · `Method IN ('TARIFF_AS_IS','TARIFF_PLUS_ADDON') OR TariffItemId IS NULL` · `Method = 'TARIFF_PLUS_ADDON' OR AddOnPct IS NULL` · `Method = 'BASE_PLUS_MARGIN' OR (BaseRateId IS NULL AND MarginPct IS NULL AND BaseFloorPct IS NULL AND RateFixing IS NULL AND RepricingMonths IS NULL)` · `Method = 'PERCENT_OF_AMOUNT' OR (RatePct IS NULL AND RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL)` · `Method = 'FIXED_AMOUNT' OR FixedAmount IS NULL` · `Method = 'PER_MILLION' OR PerMillionAmount IS NULL` · `RatePct IS NULL OR (RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL)` · `(RateRangeLowPct IS NULL AND RateRangeHighPct IS NULL) OR (RateRangeLowPct IS NOT NULL AND RateRangeHighPct IS NOT NULL AND RateRangeLowPct <= RateRangeHighPct)` · `RatePct IS NULL OR (RatePct >= 0 AND RatePct <= 100)` · `FixedAmount IS NULL OR FixedAmount >= 0` · `PerMillionAmount IS NULL OR PerMillionAmount >= 0` · `MinFeeAmount IS NULL OR MinFeeAmount >= 0` · `MinFeeAmount IS NULL OR MaxFeeAmount IS NULL OR MinFeeAmount <= MaxFeeAmount` · `PeriodDays IS NULL OR PeriodDays > 0` · `PeriodBasis IS NULL OR PeriodBasis <> 'PER_PERIOD_OR_PART' OR PeriodDays IS NOT NULL OR Method IN ('TARIFF_AS_IS','TARIFF_PLUS_ADDON','TIERED')` · `PeriodBasis IS NULL OR PeriodBasis <> 'PER_ANNUM' OR DayCount IS NOT NULL` · `RepricingMonths IS NULL OR RepricingMonths > 0` · `RateFixing IS NULL OR RateFixing <> 'FLOATING' OR RateState <> 'SET' OR RepricingMonths IS NOT NULL` · `BenchmarkReplacement <> 'NAMED_FALLBACK' OR ReplacementText IS NOT NULL` · `BankMayChange <> 'WITH_NOTICE_OBJECTION' OR (ObjectionDays IS NOT NULL AND ObjectionDaysKind IS NOT NULL)` · `ObjectionDays IS NULL OR ObjectionDays >= 0` · `Retroactive = 0 OR RetroactiveReason IS NOT NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `prc.PricingTier` — Tier of a TIERED rule by amount and/or term (FR-PRC-003, BR-PRC-002)

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
| SupersedesId | BIGINT | نعم |  | prc.PricingTier (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN PricingTierId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PricingTierId) · UQ(TenantId, PricingRuleId, SortOrder) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `AmountFrom IS NULL OR AmountFrom >= 0` · `AmountTo IS NULL OR AmountFrom IS NULL OR AmountTo > AmountFrom` · `PeriodFromDays IS NULL OR PeriodFromDays >= 0` · `PeriodToDays IS NULL OR PeriodFromDays IS NULL OR PeriodToDays >= PeriodFromDays` · `(CASE WHEN RatePct IS NULL THEN 0 ELSE 1 END + CASE WHEN MarginPct IS NULL THEN 0 ELSE 1 END + CASE WHEN FixedAmount IS NULL THEN 0 ELSE 1 END) = 1` · `RatePct IS NULL OR (RatePct >= 0 AND RatePct <= 100)` · `FixedAmount IS NULL OR FixedAmount >= 0` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

## CMP

### `cmp.TermType` — Comparable term key (FR-CMP-001); the code follows the pattern PRC.MARGIN_PCT; system terms cannot be deleted and their unit cannot change (IsSystem)

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

### `cmp.TermValue` — Term value in a facility, with its scope and source (FR-CMP-002..006, BR-CMP-001..006, V-CMP-01)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **TermValueId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| TermTypeId | INT | لا |  | cmp.TermType | مفتاح OTHER + OtherLabel لشرط خارج الكتالوج (FR-CMP-004) |
| OtherLabel | NVARCHAR(200) | نعم |  |  |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) |  |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) | DR-06: الخط من الحد نفسه |
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
| SupersedesId | BIGINT | نعم |  | cmp.TermValue (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN TermValueId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TermValueId) · UQ(TenantId, FacilityId, TermTypeId, OtherLabel, LimitId, LimitProductLineId, ProductId, CompanyId, Bound, EffectiveFrom) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `LimitProductLineId IS NULL OR LimitId IS NOT NULL` · `EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom` · `ValueState = 'SPECIFIED' OR (ValueNumber IS NULL AND ValueText IS NULL AND ValueBool IS NULL AND ValueEnum IS NULL AND NormalizedValue IS NULL)` · `ValueState <> 'SPECIFIED' OR (CASE WHEN ValueNumber IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueText IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueBool IS NULL THEN 0 ELSE 1 END + CASE WHEN ValueEnum IS NULL THEN 0 ELSE 1 END) = 1` · `NormalizedValue IS NULL OR ValueNumber IS NOT NULL` · `Origin <> 'PROJECTED' OR ProjectedFrom IS NOT NULL` · `Origin = 'PROJECTED' OR ProjectedFrom IS NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

## COL

### `col.Collateral` — Collateral record; approved independently of the facility review, and an amendment creates a new revision (FR-COL-001/014, V-COL-01, section 8)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StructureKind | VARCHAR(20) | لا |  |  | نسخة من بنية النوع: يربط بها كل نوع فرعي نوعَه (DR-40) enum: GUARANTEE, PROMISSORY_NOTE, INSURANCE_ASSIGNMENT, CASH_MARGIN, REAL_ESTATE, SET_OFF, NEGATIVE_PLEDGE, GENERIC |
| CollateralTypeId | INT | لا |  | cat.CollateralType (via StructureKind) | بنية النوع وقالب السمات من 11 (FR-CAT-013)؛ بنية نوع مستعمل لا تتغير |
| TitleAr | NVARCHAR(300) | لا |  |  |  |
| Description | NVARCHAR(2000) | نعم |  |  |  |
| OwnerPartyId | BIGINT | نعم |  | pty.Party | مزوّد استخدام Collateral owner؛ شركة المجموعة بـ Party المرآة (FR-COL-015) |
| Attributes | NVARCHAR(MAX) | نعم |  |  | DR-08: سمات القالب (قد تحمل معرّفات) محجوبة عن التقارير؛ الحساب النقدي يُربط بالنوع أدناه 🔒 restricted |
| CashMarginAccountId | BIGINT | نعم |  | acc.BankAccount | الحساب النقدي للهامش: مرجع مُعرَّف لا سمة حرّة (DR-08) |
| Status | VARCHAR(10) | لا | DRAFT |  | SUPERSEDED: نسخة معتمدة حلّت محلها أحدث؛ DISCARDED: مسودة متروكة (DR-36) enum: DRAFT, ACTIVE, RELEASED, EXPIRED, SUPERSEDED, DISCARDED |
| ApprovalState | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser | إضافة: لازم لعقد المُعِدّ/المعتمِد (FR-COL-014، §12) |
| ApprovedOn | DATETIME2(3) | نعم |  |  | إضافة |
| SupersedesId | BIGINT | نعم |  | col.Collateral (via InheritedRootId) | النسخة الجديدة DRAFT تشير إلى المعتمدة (FR-COL-014)، ومن الجذر نفسه (DR-36) |
| InheritedRootId | BIGINT | نعم |  |  | RootId للنسخة السابقة؛ فارغ للنسخة الأولى (DR-36) |
| RootId | BIGINT | نعم |  |  | هوية الضمان الثابتة عبر نسخه: معرّف نسخته الأولى؛ إليها يشير CollateralLink (DR-36) محسوب: `CASE WHEN InheritedRootId IS NULL THEN CollateralId ELSE InheritedRootId END` |
| GrantedOn | DATE | نعم |  |  |  |
| ReleasedOn | DATE | نعم |  |  | الفك بتاريخ وسبب ووثيقة بلا حذف (FR-COL-010) |
| ReleaseReason | NVARCHAR(500) | نعم |  |  |  |
| ReleaseDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**المفاتيح:** PK(CollateralId) · UQ(PublicId) · UQ(TenantId, RootId) WHERE ApprovalState = 'APPROVED' AND Status <> 'SUPERSEDED' · UQ(TenantId, RootId, Status) WHERE Status = 'DRAFT'

**قيود:** `Status IN ('DRAFT','DISCARDED') OR ApprovalState = 'APPROVED'` · `ApprovalState <> 'APPROVED' OR Status NOT IN ('DRAFT','DISCARDED')` · `ApprovalState <> 'APPROVED' OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `Status <> 'RELEASED' OR (ReleasedOn IS NOT NULL AND ReleaseReason IS NOT NULL AND ReleaseDocumentId IS NOT NULL)` · `Status = 'RELEASED' OR (ReleasedOn IS NULL AND ReleaseReason IS NULL AND ReleaseDocumentId IS NULL)` · `GrantedOn IS NULL OR ReleasedOn IS NULL OR ReleasedOn >= GrantedOn` · `SupersedesId IS NULL OR SupersedesId <> CollateralId` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `col.CollateralLink` — Link between collateral and a facility or limit; one collateral can serve several facilities (FR-COL-002, BR-COL-005)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CollateralLinkId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CollateralId | BIGINT | لا |  | col.Collateral | النسخة الأولى للضمان، جذره؛ فلا يُعاد الربط عند نسخة جديدة، والنسخة المعتمدة الحالية تُقرأ بـ RootId (DR-36؛ قادح في 044) |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | حد من التسهيل نفسه؛ فارغ = على مستوى التسهيل |
| CoverageAmount | DECIMAL(19,4) | نعم |  |  | بعملة التسهيل (BR-FAC-002) |
| LienRank | INT | نعم |  |  | رتبة الرهن |
| LinkedOn | DATE | لا |  |  |  |
| UnlinkedOn | DATE | نعم |  |  | فك الربط يضع التاريخ ولا يحذف (FR-COL-002) |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | col.CollateralLink (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN CollateralLinkId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CollateralLinkId) · UQ(TenantId, CollateralId, FacilityId, LimitId) WHERE UnlinkedOn IS NULL AND ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `CoverageAmount IS NULL OR CoverageAmount > 0` · `LienRank IS NULL OR LienRank >= 1` · `UnlinkedOn IS NULL OR UnlinkedOn >= LinkedOn` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

### `col.Guarantee` — Guarantee, 1:1 with Collateral; the guarantor is always a Party, and no identity numbers are stored here (FR-COL-003/004, BR-COL-001)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **GuaranteeId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StructureKind | VARCHAR(20) | لا | GUARANTEE |  | ثابت: الكفالة لضمان بنيته GUARANTEE (DR-40) enum: GUARANTEE |
| CollateralId | BIGINT | لا |  | col.Collateral (via StructureKind) |  |
| GuarantorPartyId | BIGINT | لا |  | pty.Party | فرد أو جهة؛ نوع الكفيل مشتق من Party.Kind ولا يُخزَّن؛ مزوّد Guarantee (FR-COL-015) |
| GuarantorIdentityDocumentId | BIGINT | نعم |  | pty.IdentityDocument (via GuarantorPartyId) | وثيقة الكفيل نفسه وقت التوقيع (BR-PTY-006، DR-33)؛ دمج الأطراف ينقل الوثائق في معاملة واحدة |
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

### `col.PromissoryNote` — Promissory note, 1:1; its own amount may exceed the limit (FR-COL-005, BR-COL-002); NextRenewalDue and PNRatio are derived

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PromissoryNoteId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StructureKind | VARCHAR(20) | لا | PROMISSORY_NOTE |  | ثابت (DR-40) enum: PROMISSORY_NOTE |
| CollateralId | BIGINT | لا |  | col.Collateral (via StructureKind) |  |
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

### `col.PromissoryNoteSigner` — Signers of the promissory note (SignerPartyIds) -- جدول وسيط جديد؛ موقّعو PromissoryNote (FR-COL-015)

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

### `col.InsurancePolicyAssignment` — Insurance policy assignment; the uniqueness key (CollateralId, PolicyNo) allows the policy to be renewed (FR-COL-006, BR-COL-003)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **InsurancePolicyAssignmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StructureKind | VARCHAR(20) | لا | INSURANCE_ASSIGNMENT |  | ثابت: التنازل لنوع INSURANCE_ASSIGNMENT وحده (قرار المالك 2026-10-13، DR-40) enum: INSURANCE_ASSIGNMENT |
| CollateralId | BIGINT | لا |  | col.Collateral (via StructureKind) |  |
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

### `col.ValuationSchedule` — Property valuation schedule (FR-COL-008, BR-COL-004), for example three valuers in the first year, then one valuer per year

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ValuationScheduleId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StructureKind | VARCHAR(20) | لا |  |  | جدول التقييم للعقار والضمان العام (قرار المالك 2026-10-13، DR-40) enum: REAL_ESTATE, GENERIC |
| CollateralId | BIGINT | لا |  | col.Collateral (via StructureKind) |  |
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

### `obl.Obligation` — Obligation on a facility (or on a limit, line or set of companies); the family comes from ObligationType and cannot be edited (FR-OBL-001, BR-OBL-001)

*مملوك للمشترك · مراجَع · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ObligationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| Family | VARCHAR(23) | لا |  |  | نسخة من عائلة النوع (BR-CAT-010): يربط بها التقرير والتعهد نوعَهما (DR-40) enum: REPORTING, COVENANT, TRANSACTION_RESTRICTION, STATIC_CLAUSE |
| ObligationTypeId | INT | لا |  | cat.ObligationType (via Family) | عائلة نوع مستعمل لا تتغير |
| TitleAr | NVARCHAR(300) | لا |  |  |  |
| TitleEn | NVARCHAR(300) | نعم |  |  |  |
| Phase | VARCHAR(10) | لا | ONGOING |  | enum: PRECEDENT, ONGOING, SUBSEQUENT |
| ScopeLimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | حد من التسهيل نفسه |
| ScopeProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,ScopeLimitId) | خط من الحد نفسه في التسهيل نفسه (DR-35) |
| ClauseRef | NVARCHAR(100) | نعم |  |  |  |
| ClauseText | NVARCHAR(MAX) | نعم |  |  | نص البند كما في الاتفاقية (DR-31)؛ بلا IBAN أو رقم حساب صريح (DQ-S06-7) 🔒 confidential |
| ConsequenceText | NVARCHAR(2000) | نعم |  |  |  |
| GraceDays | INT | نعم |  |  | مهلة سماح (FR-OBL-010) |
| CureDays | INT | نعم |  |  | مهلة علاج الخرق (FR-OBL-010، BR-OBL-009) |
| ParamValue | DECIMAL(19,6) | نعم |  |  | بند ثابت برقم (FR-OBL-008) |
| ParamUnit | VARCHAR(13) | نعم |  |  | enum: DAYS, BUSINESS_DAYS, MONTHS, PCT, AMOUNT |
| ParamCurrencyId | INT | نعم |  | ref.Currency | إضافة: عملة ParamValue حين ParamUnit=AMOUNT |
| TriggerField | VARCHAR(100) | نعم |  |  | حقل الاعتماد المستندي المقيَّم (FR-OBL-009) |
| TriggerValues | NVARCHAR(MAX) | نعم |  |  | قيم المشغّل (مصفوفة) |
| CheckMode | VARCHAR(10) | نعم |  |  | فارغ = افتراضي المشترك (FR-OBL-009) enum: OFF, WARN, BLOCK |
| Status | VARCHAR(10) | لا | ACTIVE |  | ENDED مشتقة من ValidTo وحالة التسهيل ولا تُخزَّن (DQ-F15-1، المراجعة الذاتية B7c) enum: ACTIVE, SUSPENDED |
| ValidFrom | DATE | لا |  |  |  |
| ValidTo | DATE | نعم |  |  |  |
| FromRevision | INT | لا | 1 |  |  |
| ToRevision | INT | نعم |  |  |  |
| SupersedesId | BIGINT | نعم |  | obl.Obligation (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN ObligationId ELSE InheritedRootId END` |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**المفاتيح:** PK(ObligationId) · UQ(PublicId) · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `ValidTo IS NULL OR ValidTo >= ValidFrom` · `GraceDays IS NULL OR GraceDays >= 0` · `CureDays IS NULL OR CureDays >= 0` · `(ParamValue IS NULL AND ParamUnit IS NULL) OR (ParamValue IS NOT NULL AND ParamUnit IS NOT NULL)` · `ParamValue IS NULL OR ParamValue >= 0` · `ParamUnit IS NULL OR ParamUnit <> 'AMOUNT' OR ParamCurrencyId IS NOT NULL` · `ParamCurrencyId IS NULL OR ParamUnit = 'AMOUNT'` · `TriggerValues IS NULL OR TriggerField IS NOT NULL` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `ScopeProductLineId IS NULL OR ScopeLimitId IS NOT NULL` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)` · `ClauseText IS NULL OR (ClauseText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND ClauseText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `obl.ObligationCompany` — Companies the obligation applies to (AppliesToCompanyIds) -- جدول وسيط جديد؛ الحذف لصفوف مسودة المراجعة فقط (يفرضه التطبيق)

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

### `obl.ReportingObligation` — Reporting or notice-due rule, 1:1 with Obligation (FR-OBL-002/003, BR-OBL-002, V-OBL-01)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReportingObligationId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Family | VARCHAR(23) | لا | REPORTING |  | ثابت (DR-40) enum: REPORTING |
| ObligationId | BIGINT | لا |  | obl.Obligation (via Family) |  |
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
| SupersedesId | BIGINT | نعم |  | obl.ReportingObligation (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN ReportingObligationId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReportingObligationId) · UQ(TenantId, ObligationId) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `AnchorKind <> 'FIXED_DATE' OR (FixedDueDate IS NOT NULL AND OffsetValue IS NULL)` · `AnchorKind = 'FIXED_DATE' OR (FixedDueDate IS NULL AND OffsetValue IS NOT NULL)` · `OffsetValue IS NULL OR OffsetValue >= 0` · `HorizonMonths IS NULL OR HorizonMonths > 0` · `Frequency <> 'EVENT_BASED' OR AnchorKind IN ('BEFORE_EVENT','AFTER_EVENT')` · `AnchorKind NOT IN ('BEFORE_EVENT','AFTER_EVENT') OR Frequency = 'EVENT_BASED'` · `Frequency <> 'ON_DEMAND' OR AnchorKind = 'ON_DEMAND_REQUEST'` · `AnchorKind <> 'ON_DEMAND_REQUEST' OR Frequency = 'ON_DEMAND'` · `AlertLeadDays IS NULL OR AlertLeadDays NOT LIKE '%[^0-9,]%'` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

### `obl.ReportingInstance` — Agenda item generated or logged for an event (FR-OBL-003..005, BR-OBL-003, section 8); DUE_SOON and OVERDUE are derived; a final status stays (044, DR-39)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReportingInstanceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ReportingObligationRootId | BIGINT | لا |  |  | RootId of the rule: the agenda follows the rule across revisions (DR-28, self-review B1) |
| ReportingObligationId | BIGINT | لا |  | obl.ReportingObligation (via ReportingObligationRootId) |  |
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

**المفاتيح:** PK(ReportingInstanceId) · UQ(PublicId) · UQ(TenantId, ReportingObligationRootId, PeriodEnd) WHERE PeriodEnd IS NOT NULL AND Status <> 'CANCELLED' · UQ(TenantId, ReportingObligationRootId, EventDate) WHERE PeriodEnd IS NULL AND EventDate IS NOT NULL AND Status <> 'CANCELLED' · UQ(TenantId, ReportingObligationRootId, DueDate) WHERE PeriodEnd IS NULL AND EventDate IS NULL AND Status <> 'CANCELLED'

**قيود:** `PeriodStart IS NULL OR (PeriodEnd IS NOT NULL AND PeriodEnd >= PeriodStart)` · `GeneratedBy <> 'MANUAL_EVENT' OR EventDate IS NOT NULL` · `Status <> 'SUBMITTED' OR SubmittedOn IS NOT NULL` · `Status = 'SUBMITTED' OR (SubmittedOn IS NULL AND SubmissionChannelUsedId IS NULL AND SubmissionRef IS NULL)` · `Status NOT IN ('NOT_APPLICABLE','CANCELLED') OR StatusReason IS NOT NULL` · `Status <> 'WAIVED' OR (StatusReason IS NOT NULL AND EvidenceDocumentId IS NOT NULL)` · `ReportedAmount IS NULL OR CurrencyId IS NOT NULL` · `CurrencyId IS NULL OR ReportedAmount IS NOT NULL`

### `obl.Covenant` — Covenant revision with dates; graduated limits are several revisions (FR-OBL-006, BR-OBL-001/005/006, Q-OBL-01)

*مملوك للمشترك · مراجَع*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CovenantId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Family | VARCHAR(23) | لا | COVENANT |  | ثابت (DR-40) enum: COVENANT |
| ObligationId | BIGINT | لا |  | obl.Obligation (via Family) |  |
| MeasureKind | VARCHAR(18) | لا |  |  | NONE = وصفي بلا صيغة ولا حد enum: RATIO, AMOUNT, PERCENT_OF_REVENUE, AVERAGE_BALANCE, FLOW_VOLUME, NONE |
| FormulaId | BIGINT | نعم |  | fin.MeasureFormula (via FormulaResultUnit,FormulaUsesStatements) | إلزامي للثلاثة الأولى؛ انتماؤها للتسهيل أو قالب يتحقق منه التطبيق |
| FormulaResultUnit | VARCHAR(10) | نعم |  |  | نسخة من وحدة ناتج الصيغة بربط مركّب: الحد بوحدتها (DR-38) enum: RATIO, AMOUNT, PERCENT |
| FormulaUsesStatements | BIT | نعم |  |  | نسخة: الصيغة تقرأ القوائم المالية، فيلزم أساس القائمة ومستوى تدقيقها (DR-38) |
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
| SupersedesId | BIGINT | نعم |  | obl.Covenant (via InheritedRootId) |  |
| InheritedRootId | BIGINT | نعم |  |  | RootId of the predecessor; empty for the first row of a node (DR-28) |
| RootId | BIGINT | نعم |  |  | the stable identity of the node across revisions (DQ-F13-4, DR-28) محسوب: `CASE WHEN InheritedRootId IS NULL THEN CovenantId ELSE InheritedRootId END` |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CovenantId) · UQ(TenantId, ObligationId, ValidFrom) WHERE ToRevision IS NULL · UQ(TenantId, RootId) WHERE ToRevision IS NULL

**قيود:** `MeasureKind NOT IN ('RATIO','AMOUNT','PERCENT_OF_REVENUE') OR FormulaId IS NOT NULL` · `MeasureKind <> 'NONE' OR (FormulaId IS NULL AND Operator IS NULL AND ThresholdValue IS NULL AND ThresholdState <> 'SET')` · `ThresholdState <> 'SET' OR (Operator IS NOT NULL AND ThresholdValue IS NOT NULL AND ThresholdUnit IS NOT NULL)` · `ThresholdState = 'SET' OR ThresholdValue IS NULL` · `ThresholdState <> 'SET' OR ThresholdUnit IS NULL OR ThresholdUnit <> 'AMOUNT' OR CurrencyId IS NOT NULL` · `CurrencyId IS NULL OR ThresholdUnit = 'AMOUNT'` · `RevenueBasisRule IS NULL OR MeasureKind = 'PERCENT_OF_REVENUE'` · `(FormulaId IS NULL AND FormulaResultUnit IS NULL AND FormulaUsesStatements IS NULL) OR (FormulaId IS NOT NULL AND FormulaResultUnit IS NOT NULL AND FormulaUsesStatements IS NOT NULL)` · `ThresholdUnit IS NULL OR FormulaResultUnit IS NULL OR ThresholdUnit = FormulaResultUnit` · `ThresholdUnit IS NULL OR (MeasureKind = 'RATIO' AND ThresholdUnit = 'RATIO') OR (MeasureKind IN ('AMOUNT','AVERAGE_BALANCE','FLOW_VOLUME') AND ThresholdUnit = 'AMOUNT') OR (MeasureKind = 'PERCENT_OF_REVENUE' AND ThresholdUnit = 'PERCENT')` · `FormulaUsesStatements IS NULL OR FormulaUsesStatements = 0 OR (StatementBasis IS NOT NULL AND RequiredAssurance IS NOT NULL)` · `SubmissionLagDays IS NULL OR SubmissionLagDays >= 0` · `EarlyWarningPct IS NULL OR (EarlyWarningPct >= 0 AND EarlyWarningPct <= 100)` · `ValidTo IS NULL OR ValidTo >= ValidFrom` · `ToRevision IS NULL OR ToRevision >= FromRevision` · `(SupersedesId IS NULL AND InheritedRootId IS NULL) OR (SupersedesId IS NOT NULL AND InheritedRootId IS NOT NULL)`

### `obl.CovenantAccount` — Accounts covered by a covenant when specific accounts are selected (AccountIds) -- جدول وسيط جديد؛ الحذف لصفوف مسودة المراجعة فقط (يفرضه التطبيق)

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

### `obl.CovenantTest` — Covenant test for a period and test version; an evaluated test changes only by its review (044, DR-39) (FR-OBL-011, FR-FIN-012/013, BR-OBL-006/007, section 8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CovenantTestId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CovenantRootId | BIGINT | لا |  |  | RootId of the covenant: tests follow the covenant across revisions (DR-28, self-review B1) |
| CovenantId | BIGINT | لا |  | obl.Covenant (via CovenantRootId) |  |
| PeriodStart | DATE | لا |  |  |  |
| PeriodEnd | DATE | لا |  |  |  |
| DueDate | DATE | لا |  |  | PeriodEnd + SubmissionLagDays (BR-OBL-005) |
| EvaluationNo | INT | لا | 1 |  | إعادة التقييم تضيف رقمًا ولا تعدّل القديم (BR-OBL-011) |
| State | VARCHAR(12) | لا | SCHEDULED |  | CANCELLED: اختبار مجدول خرج من الجدول، بسبب، ونهائي (DQ-F15-2، B3) enum: SCHEDULED, PENDING_DATA, EVALUATED, REVIEWED, CANCELLED |
| CancelReason | NVARCHAR(500) | نعم |  |  |  |
| Result | VARCHAR(25) | نعم |  |  | enum: COMPLIANT, WARNING, BREACH, MISSING_DATA, NOT_ASSESSED_NO_THRESHOLD, NOT_COMPARABLE, MANUAL_COMPLIANT, MANUAL_NON_COMPLIANT, UNDER_REVIEW |
| Method | VARCHAR(13) | لا |  |  | enum: AUTO, MANUAL_VALUE, MANUAL_STATUS |
| ActualValue | DECIMAL(19,6) | نعم |  |  |  |
| ThresholdApplied | DECIMAL(19,6) | نعم |  |  | العتبة والمشغّل المطبَّقان وقت التقييم (BR-FIN-010) |
| OperatorApplied | VARCHAR(10) | نعم |  |  | enum: GE, LE, GT, LT, EQ |
| Headroom | DECIMAL(19,6) | نعم |  |  | a-t أو t-a (BR-OBL-007) |
| HeadroomPct | DECIMAL(19,6) | نعم |  |  | قد يتجاوز 999.999999 عند عتبة صغيرة جدًا فلا rate |
| InputsSnapshot | NVARCHAR(MAX) | نعم |  |  | لقطة المدخلات؛ إلزامية مع EVALUATED/REVIEWED ثابتة بعد الحفظ، وكاملة للتقييم الآلي (BR-FIN-010، DR-39) |
| FormulaId | BIGINT | نعم |  | fin.MeasureFormula | نسخة الصيغة المستعملة نفسها، لا رقمها (DR-39) |
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

**المفاتيح:** PK(CovenantTestId) · UQ(PublicId) · UQ(TenantId, CovenantRootId, PeriodEnd, EvaluationNo)

**قيود:** `EvaluationNo >= 1` · `PeriodEnd >= PeriodStart` · `DueDate >= PeriodEnd` · `State NOT IN ('SCHEDULED','CANCELLED') OR (Result IS NULL AND EvaluatedAt IS NULL)` · `State <> 'CANCELLED' OR CancelReason IS NOT NULL` · `CancelReason IS NULL OR State = 'CANCELLED'` · `State NOT IN ('EVALUATED','REVIEWED') OR (Result IS NOT NULL AND EvaluatedAt IS NOT NULL AND InputsSnapshot IS NOT NULL)` · `State <> 'REVIEWED' OR (ReviewedBy IS NOT NULL AND ReviewedOn IS NOT NULL)` · `Result NOT IN ('COMPLIANT','WARNING','BREACH') OR (ActualValue IS NOT NULL AND ThresholdApplied IS NOT NULL AND OperatorApplied IS NOT NULL)` · `Result <> 'NOT_ASSESSED_NO_THRESHOLD' OR ThresholdApplied IS NULL` · `ThresholdApplied IS NULL OR OperatorApplied IS NOT NULL` · `Headroom IS NULL OR (ActualValue IS NOT NULL AND ThresholdApplied IS NOT NULL)` · `HeadroomPct IS NULL OR Headroom IS NOT NULL` · `Result NOT IN ('MANUAL_COMPLIANT','MANUAL_NON_COMPLIANT','UNDER_REVIEW') OR Method = 'MANUAL_STATUS'` · `Method <> 'MANUAL_STATUS' OR Result IS NULL OR Result IN ('MANUAL_COMPLIANT','MANUAL_NON_COMPLIANT','UNDER_REVIEW')`

### `obl.CovenantTestStatement` — The statements an automatic evaluation read: written by the database from the test's snapshot, never by the application, so the breach report and a restatement find them by key (FR-FIN-017, BR-FIN-015)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| CovenantTestId | BIGINT | لا |  | obl.CovenantTest |  |
| StatementId | BIGINT | لا |  | fin.FinancialStatement |  |
| StatementVersionNo | INT | لا |  |  | الإصدار كما في اللقطة |
| Basis | VARCHAR(12) | لا |  |  | enum: STANDALONE, CONSOLIDATED |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(TenantId, CovenantTestId, StatementId)

### `obl.ObligationBreach` — Breach record, its remedy and any waiver (FR-OBL-012, BR-OBL-009/011, section 8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ObligationBreachId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ObligationRootId | BIGINT | لا |  |  | RootId of the obligation: the breach register follows it across revisions (DR-28, self-review B1) |
| ObligationId | BIGINT | لا |  | obl.Obligation (via ObligationRootId) |  |
| Kind | VARCHAR(21) | لا |  |  | enum: COVENANT_BREACH, LATE_REPORT, RESTRICTION_VIOLATION, OTHER |
| CovenantRootId | BIGINT | نعم |  |  | نسخة من الاختبار: جذر التعهد (B1) |
| TestPeriodEnd | DATE | نعم |  |  | نسخة من الاختبار: نهاية الفترة (B1) |
| CovenantTestId | BIGINT | نعم |  | obl.CovenantTest (via CovenantRootId,TestPeriodEnd) | اتساق اختبار الخرق مع الالتزام يتحقق منه التطبيق |
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
| WaiverApprovedBy | BIGINT | نعم |  | sec.AppUser | اعتماد TM للتنازل؛ حقول التنازل تُسجَّل في OPEN وIN_CURE قبله (DQ-F15-9، B2) |
| WaiverApprovedOn | DATETIME2(3) | نعم |  |  |  |
| ConsequenceApplied | NVARCHAR(1000) | نعم |  |  |  |
| ResolvedOn | DATE | نعم |  |  |  |
| NeedsReview | BIT | لا | 0 |  | تعليم إعادة العرض لا يغيّر الحالة (BR-OBL-011) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ObligationBreachId) · UQ(PublicId) · UQ(TenantId, CovenantRootId, TestPeriodEnd) WHERE CovenantTestId IS NOT NULL AND Status IN ('OPEN','IN_CURE') · UQ(TenantId, ReportingInstanceId) WHERE ReportingInstanceId IS NOT NULL AND Status IN ('OPEN','IN_CURE')

**قيود:** `CovenantTestId IS NULL OR Kind = 'COVENANT_BREACH'` · `(CovenantTestId IS NULL AND CovenantRootId IS NULL AND TestPeriodEnd IS NULL) OR (CovenantTestId IS NOT NULL AND CovenantRootId IS NOT NULL AND TestPeriodEnd IS NOT NULL)` · `ReportingInstanceId IS NULL OR Kind = 'LATE_REPORT'` · `CureDeadline IS NULL OR CureDeadline >= DetectedOn` · `Status <> 'IN_CURE' OR CureDeadline IS NOT NULL` · `Status NOT IN ('CURED','WAIVED','CLOSED_NO_ACTION') OR ResolvedOn IS NOT NULL` · `Status IN ('CURED','WAIVED','CLOSED_NO_ACTION') OR ResolvedOn IS NULL` · `ResolvedOn IS NULL OR ResolvedOn >= DetectedOn` · `Status <> 'WAIVED' OR (WaiverRef IS NOT NULL AND WaiverDate IS NOT NULL AND WaiverBankContactId IS NOT NULL AND WaiverApprovedBy IS NOT NULL AND WaiverApprovedOn IS NOT NULL)` · `Status IN ('WAIVED','OPEN','IN_CURE') OR (WaiverRef IS NULL AND WaiverDate IS NULL AND WaiverBankContactId IS NULL AND WaiverConditions IS NULL AND WaiverValidUntil IS NULL AND WaiverDocumentId IS NULL)` · `(WaiverApprovedBy IS NULL AND WaiverApprovedOn IS NULL) OR (Status = 'WAIVED' AND WaiverApprovedBy IS NOT NULL AND WaiverApprovedOn IS NOT NULL)` · `WaiverValidUntil IS NULL OR WaiverDate IS NULL OR WaiverValidUntil >= WaiverDate`

## FIN

### `fin.LineCatalogItem` — Standard statement line item; 51 items seeded, twelve of them for the credit assessment; system items used in formulas cannot be deleted (FR-FIN-001, FR-FIN-020, CatalogBase)

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
| Section | VARCHAR(12) | لا |  |  | MEMO: بند إفصاح خارج الميزانية لا يدخل إجمالياتها (الالتزامات المحتملة، FR-FIN-020) enum: BS_ASSET, BS_LIABILITY, BS_EQUITY, IS, CF, MEMO |
| IsTotal | BIT | لا | 0 |  | إجمالي محسوب من رموز مكوّناته (BR-FIN-001) |
| TotalFormula | NVARCHAR(500) | نعم |  |  | مثل GROSS_PROFIT - OPEX؛ نحو الإجماليات البسيط |
| IsRequired | BIT | لا | 0 |  | الفارغ منه يمنع التقديم (BR-FIN-002) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LineCatalogItemId) · UQ(TenantId, Code) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `IsTotal = 0 OR TotalFormula IS NOT NULL` · `IsTotal = 1 OR TotalFormula IS NULL` · `NameEn IS NOT NULL` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `IsLocked = 0 OR (IsSystem = 1 AND IsActive = 1)`

### `fin.LineCatalogItemAlias` — Alternative names (aliases) for a line item, used for paste and matching -- جدول جديد للأسماء البديلة (FR-FIN-003)

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

### `fin.FinancialStatement` — Financial statement header; highly confidential (FR-FIN-002/005/006, BR-FIN-001..004, section 8)

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
| Nature | VARCHAR(10) | لا | ACTUAL |  | BUDGET: قائمة تقديرية (موازنة أو خطة) تُقيَّم تقييمًا تجريبيًا وتبقى مسودة (ADR 0025) enum: ACTUAL, BUDGET |
| CurrencyId | INT | لا |  | ref.Currency |  |
| UnitScale | INT | لا | 1 |  | المدخل بوحدة 1/1000/1000000 والمخزَّن مضروب فيها (BR-FIN-002) |
| AccountingStandard | NVARCHAR(100) | نعم |  |  |  |
| AuditorName | NVARCHAR(200) | نعم |  |  | مراجع الحسابات للقائمة المدققة أو المراجَعة (وحدة الميزانية، 2026-10-18) |
| AuditOpinion | VARCHAR(11) | نعم |  |  | رأي المراجع للقائمة المدققة enum: UNQUALIFIED, QUALIFIED, ADVERSE, DISCLAIMER |
| GoingConcernUncertainty | BIT | لا | 0 |  | فقرة شك جوهري في الاستمرارية في تقرير المراجع (التقييم الائتماني، docs/35 §7) |
| VersionNo | INT | لا | 1 |  |  |
| VersionReason | VARCHAR(12) | لا | ORIGINAL |  | سبب الإصدار إلزامي (BR-FIN-004)؛ RESTRUCTURED: نسخة عرض اختارتها الشركة (ADR 0023) enum: ORIGINAL, RESTATED, CORRECTION, RESTRUCTURED |
| SupersedesId | BIGINT | نعم |  | fin.FinancialStatement (via CompanyId,Basis,Assurance,PeriodType,PeriodEnd,Nature) | الإصدار السابق للشركة والسلسلة نفسها؛ المدققة لا تحل محل الإدارية (قرار المالك 2026-10-13، DR-34) |
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

**المفاتيح:** PK(FinancialStatementId) · UQ(PublicId) · UQ(TenantId, CompanyId, PeriodType, PeriodEnd, Basis, Assurance, Nature, VersionNo) · UQ(TenantId, CompanyId, Basis, Assurance, PeriodType, PeriodEnd) WHERE Status = 'APPROVED' · UQ(TenantId, SupersedesId) WHERE SupersedesId IS NOT NULL AND Status <> 'REJECTED'

**قيود:** `UnitScale IN (1,1000,1000000)` · `PeriodStart IS NULL OR PeriodEnd >= PeriodStart` · `FiscalYear BETWEEN 1900 AND 2200` · `VersionNo >= 1` · `VersionReason <> 'ORIGINAL' OR SupersedesId IS NULL` · `SupersedesId IS NULL OR (VersionNo > 1 AND VersionReason <> 'ORIGINAL' AND SupersedesId <> FinancialStatementId)` · `Status NOT IN ('SUBMITTED','APPROVED','SUPERSEDED') OR (PreparedBy IS NOT NULL AND PreparedOn IS NOT NULL)` · `Status NOT IN ('APPROVED','SUPERSEDED') OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `ApprovedBy IS NULL OR PreparedBy IS NULL OR ApprovedBy <> PreparedBy` · `Status = 'DRAFT' OR Assurance <> 'AUDITED' OR (AuditorName IS NOT NULL AND AuditOpinion IS NOT NULL)` · `AuditOpinion IS NULL OR Assurance = 'AUDITED'` · `GoingConcernUncertainty = 0 OR Assurance IN ('AUDITED','REVIEWED')` · `Nature = 'ACTUAL' OR (Assurance = 'MANAGEMENT' AND Status = 'DRAFT' AND AuditOpinion IS NULL)`

### `fin.StatementLine` — Statement line in the header currency; stored value = input x UnitScale; Variance is derived; highly confidential (BR-FIN-001/002)

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

### `fin.ConsolidationMember` — A unit of a holding's consolidated statement: the parent, each subsidiary, associate and joint venture, with its method and ownership (FR-FIN-015, BR-FIN-013; owner request 2026-10-18)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ConsolidationMemberId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StatementBasis | VARCHAR(12) | لا | CONSOLIDATED |  | ثابت: الوحدات للقائمة الموحدة وحدها enum: CONSOLIDATED |
| StatementId | BIGINT | لا |  | fin.FinancialStatement (via StatementBasis) |  |
| MemberCompanyId | BIGINT | لا |  | org.Company | الوحدة شركة من شركات المشترك؛ القابضة نفسها PARENT |
| Role | VARCHAR(13) | لا |  |  | enum: PARENT, SUBSIDIARY, ASSOCIATE, JOINT_VENTURE |
| Method | VARCHAR(16) | لا |  |  | enum: FULL, EQUITY, PROPORTIONATE, NOT_CONSOLIDATED |
| OwnershipPct | DECIMAL(9,6) | نعم |  |  | نسبة الملكية الفعلية في نهاية الفترة؛ فارغة للقابضة |
| IncludedFrom | DATE | نعم |  |  | دخول الوحدة خلال الفترة (استحواذ) |
| IncludedTo | DATE | نعم |  |  | خروجها خلال الفترة (تخارج) |
| MemberStatementId | BIGINT | نعم |  | fin.FinancialStatement (via MemberCompanyId) | القائمة المنفردة للوحدة للفترة نفسها، إن أُدخلت |
| Note | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ConsolidationMemberId) · UQ(TenantId, StatementId, MemberCompanyId) · UQ(TenantId, StatementId) WHERE Role = 'PARENT'

**قيود:** `OwnershipPct IS NULL OR (OwnershipPct > 0 AND OwnershipPct <= 100)` · `(Role = 'PARENT' AND Method = 'FULL' AND OwnershipPct IS NULL) OR (Role <> 'PARENT' AND OwnershipPct IS NOT NULL)` · `Role <> 'SUBSIDIARY' OR Method IN ('FULL','NOT_CONSOLIDATED')` · `Role <> 'ASSOCIATE' OR Method IN ('EQUITY','NOT_CONSOLIDATED')` · `Role <> 'JOINT_VENTURE' OR Method IN ('EQUITY','PROPORTIONATE','NOT_CONSOLIDATED')` · `IncludedTo IS NULL OR IncludedFrom IS NULL OR IncludedTo >= IncludedFrom` · `MemberStatementId IS NULL OR Role <> 'PARENT'`

### `fin.StatementRatio` — An analysis measure computed on an approved statement, for the study of the balance sheet; written by the engine (FR-FIN-016, BR-FIN-014)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **StatementRatioId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| StatementId | BIGINT | لا |  | fin.FinancialStatement |  |
| FormulaId | BIGINT | لا |  | fin.MeasureFormula |  |
| ResultUnit | VARCHAR(10) | لا |  |  | وحدة الصيغة وقت الحساب enum: RATIO, AMOUNT, PERCENT, DAYS |
| Status | VARCHAR(14) | لا |  |  | enum: COMPUTED, NOT_COMPUTABLE |
| Value | DECIMAL(19,6) | نعم |  |  | فارغ إن لم تُحسب (قسمة على صفر، بند ناقص) |
| Reason | NVARCHAR(300) | نعم |  |  | سبب NOT_COMPUTABLE |
| InputsSnapshot | NVARCHAR(MAX) | لا |  |  | البنود والإصدار المستعمَلان (على غرار BR-FIN-010) |
| ComputedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StatementRatioId) · UQ(TenantId, StatementId, FormulaId)

**قيود:** `(Status = 'COMPUTED' AND Value IS NOT NULL AND Reason IS NULL) OR (Status = 'NOT_COMPUTABLE' AND Value IS NULL AND Reason IS NOT NULL)`

### `fin.RevenueEstimate` — Manual revenue estimate for a fiscal year, used by a revenue-share covenant with RevenueBasisRule MANUAL_ESTIMATE (Q-FIN-05, BR-FIN-008, self-review B4)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RevenueEstimateId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| FiscalYear | INT | لا |  |  |  |
| Basis | VARCHAR(12) | لا |  |  | enum: STANDALONE, CONSOLIDATED |
| Amount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| BasisNote | NVARCHAR(500) | لا |  |  | مصدر التقدير (موازنة معتمدة، توقع الإدارة...) |
| DocumentId | BIGINT | نعم |  | doc.Document |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED, SUPERSEDED |
| PreparedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RevenueEstimateId) · UQ(PublicId) · UQ(TenantId, CompanyId, FiscalYear, Basis) WHERE Status = 'APPROVED'

**قيود:** `Amount > 0` · `FiscalYear BETWEEN 1900 AND 2200` · `Status = 'DRAFT' OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `ApprovedBy IS NULL OR PreparedBy IS NULL OR ApprovedBy <> PreparedBy` · `Status = 'DRAFT' OR PreparedBy IS NOT NULL`

### `fin.AccountMonthlyStat` — Monthly balance of an account in the account currency (FR-FIN-008, BR-FIN-005/006, V-FIN-02)

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
| Status | VARCHAR(10) | لا | DRAFT |  | المؤكَّد لا يتغير ولا يُحذف إلا بإعادة فتح (ADR 0030) enum: DRAFT, CONFIRMED |
| EnteredBy | BIGINT | نعم |  | sec.AppUser |  |
| ConfirmedBy | BIGINT | نعم |  | sec.AppUser |  |
| ConfirmedOn | DATETIME2(3) | نعم |  |  |  |
| ReopenCount | INT | لا | 0 |  | مرات إعادة فتح المؤكَّد: يعيده مسودة بسبب، بيد غير المُدخِل (052، ADR 0030) |
| LastReopenedBy | BIGINT | نعم |  | sec.AppUser |  |
| LastReopenedOn | DATETIME2(3) | نعم |  |  |  |
| LastReopenReason | NVARCHAR(500) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AccountMonthlyStatId) · UQ(PublicId) · UQ(TenantId, BankAccountId, MonthEnd)

**قيود:** `DAY(DATEADD(DAY, 1, MonthEnd)) = 1` · `(Status = 'DRAFT' AND ConfirmedBy IS NULL AND ConfirmedOn IS NULL) OR (Status = 'CONFIRMED' AND ConfirmedBy IS NOT NULL AND ConfirmedOn IS NOT NULL)` · `ConfirmedBy IS NULL OR EnteredBy IS NULL OR ConfirmedBy <> EnteredBy` · `ReopenCount >= 0 AND (ReopenCount = 0 OR (LastReopenedBy IS NOT NULL AND LastReopenedOn IS NOT NULL AND LastReopenReason IS NOT NULL))` · `LastReopenedBy IS NULL OR EnteredBy IS NULL OR LastReopenedBy <> EnteredBy` · `ConfirmedBy IS NULL OR LastReopenedBy IS NULL OR ConfirmedBy <> LastReopenedBy` · `Status <> 'CONFIRMED' OR EnteredBy IS NOT NULL`

### `fin.BankFlowEntry` — Amount transferred to the bank in a month; annual totals are computed automatically (FR-FIN-009/010, BR-FIN-007/008)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **BankFlowEntryId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| InstitutionId | BIGINT | لا |  | ins.Institution |  |
| FacilityId | BIGINT | نعم |  | fac.Facility |  |
| MonthEnd | DATE | لا |  |  |  |
| FlowKindListCode | VARCHAR(80) | لا | FLOW_KIND |  | ثابت: البند من قائمة FLOW_KIND وحدها (المراجعة الذاتية B7f) |
| FlowKindListId | INT | لا |  | cat.LookupList (via FlowKindListCode) |  |
| FlowKindId | INT | لا |  | cat.LookupItem (via FlowKindListId) | الافتراضي التطبيقي TRANSFERRED_TO_BANK |
| Amount | DECIMAL(19,4) | لا |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency |  |
| BasisNote | NVARCHAR(500) | نعم |  |  | أساس الاحتساب بنص حر (03 §3.3) |
| DocumentId | BIGINT | نعم |  | doc.Document |  |
| Status | VARCHAR(10) | لا | DRAFT |  | المؤكَّد وحده يقيس الأداء (FR-FIN-018) enum: DRAFT, CONFIRMED |
| EnteredBy | BIGINT | نعم |  | sec.AppUser |  |
| ConfirmedBy | BIGINT | نعم |  | sec.AppUser |  |
| ConfirmedOn | DATETIME2(3) | نعم |  |  |  |
| ReopenCount | INT | لا | 0 |  | مرات إعادة فتح المؤكَّد: يعيده مسودة بسبب، بيد غير المُدخِل (052، ADR 0030) |
| LastReopenedBy | BIGINT | نعم |  | sec.AppUser |  |
| LastReopenedOn | DATETIME2(3) | نعم |  |  |  |
| LastReopenReason | NVARCHAR(500) | نعم |  |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(BankFlowEntryId) · UQ(PublicId) · UQ(TenantId, CompanyId, InstitutionId, FacilityId, MonthEnd, FlowKindId)

**قيود:** `DAY(DATEADD(DAY, 1, MonthEnd)) = 1` · `Amount >= 0` · `FlowKindListCode = 'FLOW_KIND'` · `(Status = 'DRAFT' AND ConfirmedBy IS NULL AND ConfirmedOn IS NULL) OR (Status = 'CONFIRMED' AND ConfirmedBy IS NOT NULL AND ConfirmedOn IS NOT NULL)` · `ConfirmedBy IS NULL OR EnteredBy IS NULL OR ConfirmedBy <> EnteredBy` · `ReopenCount >= 0 AND (ReopenCount = 0 OR (LastReopenedBy IS NOT NULL AND LastReopenedOn IS NOT NULL AND LastReopenReason IS NOT NULL))` · `LastReopenedBy IS NULL OR EnteredBy IS NULL OR LastReopenedBy <> EnteredBy` · `ConfirmedBy IS NULL OR LastReopenedBy IS NULL OR ConfirmedBy <> LastReopenedBy` · `Status <> 'CONFIRMED' OR EnteredBy IS NOT NULL`

### `fin.MeasureFormula` — Measure formula: a template or a facility-agreement version with revisions; never executed as text (FR-FIN-011, BR-FIN-009, section 12)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **MeasureFormulaId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(60) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | نعم |  |  |  |
| Scope | VARCHAR(13) | لا |  |  | ANALYSIS: مقياس لدراسة الميزانية لا لتعهد (FR-FIN-016) enum: TEMPLATE, FACILITY_COPY, ANALYSIS |
| FacilityId | BIGINT | نعم |  | fac.Facility | لنسخة الاتفاقية فقط؛ فارغ للقالب |
| BaseTemplateId | BIGINT | نعم |  | fin.MeasureFormula | القالب المنسوخ منه؛ كونه TEMPLATE يتحقق منه التطبيق |
| Expression | NVARCHAR(2000) | لا |  |  | نحو مقيَّد يُحلَّل إلى شجرة (BR-FIN-009) |
| InputKinds | VARCHAR(40) | لا |  |  |  |
| ResultUnit | VARCHAR(10) | لا |  |  | على غرار Covenant.ThresholdUnit (المواصفة لا تعدّد القيم)؛ وحدة صيغة مستعملة لا تتغير (DR-38) enum: RATIO, AMOUNT, PERCENT, DAYS |
| UsesStatements | BIT | نعم |  |  | تقرأ القوائم المالية (DR-38) محسوب: `CAST(CASE WHEN InputKinds LIKE '%STATEMENT%' THEN 1 ELSE 0 END AS BIT)` |
| DefinitionNote | NVARCHAR(1000) | نعم |  |  | مثل: هل يشمل الدين التزامات الإيجار |
| VersionNo | INT | لا | 1 |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED, SUPERSEDED |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
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

**قيود:** `Scope = 'FACILITY_COPY' OR FacilityId IS NULL` · `ResultUnit <> 'DAYS' OR Scope = 'ANALYSIS'` · `Scope <> 'FACILITY_COPY' OR FacilityId IS NOT NULL` · `Scope = 'FACILITY_COPY' OR BaseTemplateId IS NULL` · `BaseTemplateId IS NULL OR BaseTemplateId <> MeasureFormulaId` · `InputKinds <> ''` · `VersionNo >= 1` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `Status NOT IN ('APPROVED','SUPERSEDED') OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fin.RatingGrade` — The 21 grades of the Moody's long-term scale, their range on the scorecard continuum and their risk band (docs/35 section 2, BR-FIN-018)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **RatingGradeId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(4) | لا |  |  | Aaa, Aa1 ... Ca, C |
| NotchNo | TINYINT | لا |  |  | 1 = Aaa ... 20 = Ca, 21 = C |
| Category | VARCHAR(3) | لا |  |  | Aaa, Aa, A, Baa, Ba, B, Caa, Ca, C |
| ScoreFrom | DECIMAL(5,2) | نعم |  |  | المجال على الخط المستمر؛ فارغ لـ C التي لا تبلغها البطاقة بالحساب |
| ScoreTo | DECIMAL(5,2) | نعم |  |  |  |
| RiskBand | VARCHAR(11) | لا |  |  | enum: LOW, MODERATE, SUBSTANTIAL, HIGH, VERY_HIGH |
| IsInvestmentGrade | BIT | لا | 0 |  | Baa3 فما فوق |
| FitchEquivalent | VARCHAR(4) | لا |  |  | المقابل في سلّم فيتش طويل الأجل (AAA ... C) |
| DescriptionAr | NVARCHAR(300) | لا |  |  |  |
| DescriptionEn | NVARCHAR(300) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RatingGradeId) · UQ(Code) · UQ(NotchNo)

**قيود:** `NotchNo BETWEEN 1 AND 21` · `(ScoreFrom IS NULL AND ScoreTo IS NULL AND NotchNo = 21) OR (ScoreFrom IS NOT NULL AND ScoreTo IS NOT NULL AND ScoreTo > ScoreFrom AND NotchNo < 21)` · `IsInvestmentGrade = 0 OR NotchNo <= 10`

### `fin.CreditMetric` — The metric dictionary of the credit assessment: how each ratio is computed from the statement lines, its unit and direction, and the texts of its strength and weakness (docs/35 section 4)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CreditMetricId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Kind | VARCHAR(12) | لا |  |  | النوعي يدخله المحلل بدرجة ومبرّر enum: QUANTITATIVE, QUALITATIVE |
| Unit | VARCHAR(10) | لا |  |  | enum: RATIO, PERCENT, DAYS, AMOUNT, MONTHS, YEARS, GRADE |
| Direction | VARCHAR(13) | لا |  |  | enum: HIGHER_BETTER, LOWER_BETTER, NONE |
| DefinitionAr | NVARCHAR(1000) | لا |  |  | الصيغة من رموز البنود والحالات الحدية؛ يحسبها 046 بالكميات المسمّاة، لا نصًا منفَّذًا |
| InputsText | NVARCHAR(500) | نعم |  |  |  |
| Pattern | VARCHAR(10) | نعم |  |  | طريقة الحساب من البسط والمقام (docs/35 §4)؛ VALUE تحسبها خطوة القيم الخاصة؛ فارغ للنوعي enum: RATIO, AMOUNT, DIFF, GROWTH, VALUE |
| NumQty | VARCHAR(40) | نعم |  |  | الكمية المسمّاة في البسط |
| DenQty | VARCHAR(40) | نعم |  |  | وفي المقام |
| Scale | DECIMAL(9,2) | نعم |  |  | 100 للنسبة المئوية، 365 للأيام، 12 للأشهر، 1 للمرات |
| IfNumZero | VARCHAR(15) | نعم |  |  | بسط صفري enum: NONE, VALUE0, BEST, BEST_IF_DEN_POS, WORST |
| IfDenZero | VARCHAR(18) | نعم |  |  | مقام صفري enum: NA, BEST, WORST, BEST_IF_NUM_POS, BEST_IF_NUM_NONNEG |
| IfDenNeg | VARCHAR(10) | نعم |  |  | مقام سالب enum: COMPUTE, WORST, NA |
| IfNumNeg | VARCHAR(15) | نعم |  |  | بسط سالب (وللمبلغ: غير موجب) enum: COMPUTE, WORST, NA, BEST_IF_DEN_POS |
| ThemeCode | VARCHAR(30) | نعم |  |  | محور التقرير: الحجم والسوق، نوع المبيعات، النقد، السيولة، الذمم، المخزون... |
| CashEffectAr | NVARCHAR(500) | نعم |  |  | أثره على النقد |
| CashEffectEn | NVARCHAR(500) | نعم |  |  |  |
| SolvencyEffectAr | NVARCHAR(500) | نعم |  |  | أثره على الملاءة |
| SolvencyEffectEn | NVARCHAR(500) | نعم |  |  |  |
| StrengthTextAr | NVARCHAR(500) | لا |  |  | {v} القيمة و{g} الدرجة |
| StrengthTextEn | NVARCHAR(500) | لا |  |  |  |
| WeaknessTextAr | NVARCHAR(500) | لا |  |  |  |
| WeaknessTextEn | NVARCHAR(500) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditMetricId) · UQ(Code)

**قيود:** `(Kind = 'QUALITATIVE' AND Unit = 'GRADE' AND Direction = 'NONE') OR (Kind = 'QUANTITATIVE' AND Unit <> 'GRADE' AND Direction <> 'NONE')` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `(Kind = 'QUALITATIVE' AND Pattern IS NULL AND NumQty IS NULL) OR (Kind = 'QUANTITATIVE' AND Pattern = 'VALUE' AND NumQty IS NULL AND DenQty IS NULL) OR (Kind = 'QUANTITATIVE' AND Pattern <> 'VALUE' AND NumQty IS NOT NULL AND (Pattern = 'AMOUNT' OR DenQty IS NOT NULL))` · `Pattern IS NULL OR Pattern <> 'RATIO' OR (Scale IS NOT NULL AND IfNumZero IS NOT NULL AND IfDenZero IS NOT NULL AND IfDenNeg IS NOT NULL AND IfNumNeg IS NOT NULL)`

### `fin.Scorecard` — A sector scorecard of the credit assessment and its version; approved, it never changes and a change is a new version (docs/35 section 5, BR-FIN-023)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| VersionNo | INT | لا | 1 |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| SectorNoteAr | NVARCHAR(500) | نعم |  |  |  |
| CurrencyId | INT | لا |  | ref.Currency | عملة حدود الحجم |
| AmountUnit | INT | لا | 1000000 |  | وحدة حدود الحجم (مليون) |
| MinCoveragePct | DECIMAL(5,2) | لا | 85 |  | أدنى وزن محسوب من المقاييس الكمية لإعطاء درجة (BR-FIN-019) |
| QualitativeBoundNotches | TINYINT | لا | 3 |  | بُعد الدرجة النوعية الأقصى عن الدرجة المالية بلا مستند (BR-FIN-021) |
| SupportMaxAgeMonths | TINYINT | لا | 12 |  | أقصى عمر لتقييم الأم في دعم المجموعة (BR-FIN-022) |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED, RETIRED |
| EffectiveFrom | DATE | نعم |  |  |  |
| DisclaimerAr | NVARCHAR(1000) | لا |  |  |  |
| DisclaimerEn | NVARCHAR(1000) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardId) · UQ(Code, VersionNo) · UQ(Code) WHERE Status = 'APPROVED'

**قيود:** `VersionNo >= 1` · `AmountUnit IN (1,1000,1000000)` · `MinCoveragePct > 0 AND MinCoveragePct <= 100` · `QualitativeBoundNotches BETWEEN 1 AND 20` · `SupportMaxAgeMonths BETWEEN 1 AND 36` · `Status = 'DRAFT' OR EffectiveFrom IS NOT NULL` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'`

### `fin.ScorecardMetric` — A metric of a scorecard: its factor, its weight and the nine boundaries of its grid (best cap, Aaa|Aa, Aa|A, A|Baa, Baa|Ba, Ba|B, B|Caa, Caa|Ca, worst cap); a qualitative metric has no grid (docs/35 section 5)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardMetricId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ScorecardId | INT | لا |  | fin.Scorecard |  |
| MetricId | INT | لا |  | fin.CreditMetric |  |
| FactorCode | VARCHAR(24) | لا |  |  | عوامل موديز الثمانية (docs/35 §5) enum: SCALE, BUSINESS_PROFILE, PROFITABILITY_EFFICIENCY, LEVERAGE_COVERAGE, CAPITAL_SOLVENCY, LIQUIDITY_FUNDING, BALANCE_SHEET_QUALITY, FINANCIAL_POLICY |
| Weight | DECIMAL(5,2) | لا |  |  |  |
| B0 | DECIMAL(19,6) | نعم |  |  | القيمة التي تساوي 0.5 أو أفضل منها |
| B1 | DECIMAL(19,6) | نعم |  |  | 1.5: حد Aaa/Aa |
| B2 | DECIMAL(19,6) | نعم |  |  | 4.5: حد Aa/A |
| B3 | DECIMAL(19,6) | نعم |  |  | 7.5: حد A/Baa |
| B4 | DECIMAL(19,6) | نعم |  |  | 10.5: حد Baa/Ba |
| B5 | DECIMAL(19,6) | نعم |  |  | 13.5: حد Ba/B |
| B6 | DECIMAL(19,6) | نعم |  |  | 16.5: حد B/Caa |
| B7 | DECIMAL(19,6) | نعم |  |  | 19.5: حد Caa/Ca |
| B8 | DECIMAL(19,6) | نعم |  |  | القيمة التي تساوي 20.5 أو أسوأ منها |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardMetricId) · UQ(ScorecardId, MetricId)

**قيود:** `Weight > 0 AND Weight <= 100` · `(B0 IS NULL AND B1 IS NULL AND B2 IS NULL AND B3 IS NULL AND B4 IS NULL AND B5 IS NULL AND B6 IS NULL AND B7 IS NULL AND B8 IS NULL) OR (B0 IS NOT NULL AND B1 IS NOT NULL AND B2 IS NOT NULL AND B3 IS NOT NULL AND B4 IS NOT NULL AND B5 IS NOT NULL AND B6 IS NOT NULL AND B7 IS NOT NULL AND B8 IS NOT NULL AND ((B0 < B1 AND B1 < B2 AND B2 < B3 AND B3 < B4 AND B4 < B5 AND B5 < B6 AND B6 < B7 AND B7 < B8) OR (B0 > B1 AND B1 > B2 AND B2 > B3 AND B3 > B4 AND B4 > B5 AND B5 > B6 AND B6 > B7 AND B7 > B8)))`

### `fin.ScorecardItemRule` — A balance-sheet item rule of a scorecard: the item, its metric and the thresholds of LOW, MODERATE, ELEVATED, HIGH and CRITICAL; a value on a threshold belongs to the worse level (docs/35 section 6)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardItemRuleId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ScorecardId | INT | لا |  | fin.Scorecard |  |
| MetricId | INT | لا |  | fin.CreditMetric |  |
| LineCode | VARCHAR(40) | لا |  |  | بند الميزانية الذي يُنسب إليه الخطر |
| T1 | DECIMAL(19,6) | لا |  |  |  |
| T2 | DECIMAL(19,6) | لا |  |  |  |
| T3 | DECIMAL(19,6) | لا |  |  |  |
| T4 | DECIMAL(19,6) | لا |  |  |  |
| ReportStrength | BIT | لا | 0 |  | LOW يُذكر نقطة قوة |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardItemRuleId) · UQ(ScorecardId, MetricId, LineCode)

**قيود:** `(T1 < T2 AND T2 < T3 AND T3 < T4) OR (T1 > T2 AND T2 > T3 AND T3 > T4)`

### `fin.ScorecardAdjustment` — An adjustment of a scorecard: notches down, a standalone cap or an absolute cap on the best grade, applied in that order around group support and the override (docs/35 section 7)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardAdjustmentId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ScorecardId | INT | لا |  | fin.Scorecard |  |
| RuleCode | VARCHAR(40) | لا |  |  | منطق كل قاعدة في 047 برمزها؛ الرمز غير المعروف لا يُطبق (docs/35 §8) |
| Stage | VARCHAR(10) | لا |  |  | تنزيل، ثم سقف منفرد قبل الدعم، ثم سقف مطلق بعد التجاوز enum: NOTCH, STANDALONE, ABSOLUTE |
| Notches | INT | لا | 0 |  | درجات التنزيل، سالبة؛ صفر للسقف |
| CapGradeId | INT | نعم |  | fin.RatingGrade | أفضل درجة مسموحة بعد القاعدة |
| ParamValue | DECIMAL(19,6) | نعم |  |  | المعامل: أشهر القِدم، النسبة، الإيراد بالملايين |
| ShowWhen | VARCHAR(12) | لا | ALWAYS |  | يُذكر السقف دائمًا أو حين يغيّر الدرجة enum: ALWAYS, WHEN_BINDING |
| IsActive | BIT | لا | 1 |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| TextAr | NVARCHAR(500) | لا |  |  | {p} المعامل |
| TextEn | NVARCHAR(500) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardAdjustmentId) · UQ(ScorecardId, RuleCode)

**قيود:** `Notches BETWEEN -3 AND 0` · `(Stage = 'NOTCH' AND CapGradeId IS NULL AND Notches <= 0) OR (Stage <> 'NOTCH' AND CapGradeId IS NOT NULL AND Notches = 0)` · `RuleCode COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `RuleCode NOT IN ('STALE_STATEMENT','RESTATEMENT','HALF_CAPITAL_LOST','HALF_CAPITAL_LOST_CURED','RELATED_PARTY_EXPOSURE','FLOW_SHORTFALL','SIZE_CEILING') OR ParamValue IS NOT NULL`

### `fin.IndustryProfile` — The credit profile of an activity or a division: its sector family scorecard, industry risk, cyclicality, its ceiling, the extra data it must give and the products it usually sells; the expected grade range comes from the country and industry risk anchor (docs/35 section 13, ADR 0019)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **IndustryProfileId** | INT IDENTITY | لا | | | مفتاح أساسي |
| IndustryId | INT | لا |  | ref.Industry |  |
| DefaultScorecardCode | VARCHAR(40) | لا |  |  | بطاقة عائلة القطاع (ADR 0019) |
| IndustryRisk | TINYINT | لا |  |  | 1 منخفضة جدًا ... 6 مرتفعة جدًا |
| Cyclicality | VARCHAR(10) | لا |  |  | enum: LOW, MEDIUM, HIGH |
| CeilingGradeId | INT | نعم |  | fin.RatingGrade | سقف النشاط إن وُجد |
| ExtraDisclosures | VARCHAR(400) | نعم |  |  | رموز الإفصاحات الإضافية للقطاع مفصولة بفواصل |
| ProductCategories | VARCHAR(400) | لا |  |  | فئات المنتجات المعتادة للنشاط مفصولة بفواصل؛ تُقرأ حين لا تُدخل الشركة خطوط منتجاتها |
| NoteAr | NVARCHAR(1000) | نعم |  |  |  |
| NoteEn | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IndustryProfileId) · UQ(IndustryId)

**قيود:** `IndustryRisk BETWEEN 1 AND 6`

### `fin.ShockDriver` — A driver of stress: private demand, government spending, real estate, conflict, oil, credit, imports and currency; its effect at full intensity on revenue, gross margin and collection days (docs/35 section 14, ADR 0019)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ShockDriverId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(20) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| RevenuePct | DECIMAL(9,4) | لا |  |  | فقد الإيرادات عند الشدة الكاملة والحساسية 5 والتعرض 1 |
| GrossMarginPp | DECIMAL(9,4) | لا |  |  | نقاط هامش مجمل الربح |
| DsoDays | DECIMAL(9,2) | لا |  |  | أيام تحصيل إضافية |
| SortOrder | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ShockDriverId) · UQ(Code)

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `RevenuePct >= 0 AND GrossMarginPp >= 0 AND DsoDays >= 0`

### `fin.MacroScenario` — A macro stress scenario: the stagnant market, the financial crisis, a fiscal squeeze, a real estate correction, a regional conflict, an oil price collapse, the Gulf conflict on the shipping routes; the intensity of each driver and the financial conditions (docs/35 section 14, ADR 0019)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **MacroScenarioId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(30) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| DescriptionAr | NVARCHAR(1000) | لا |  |  |  |
| DescriptionEn | NVARCHAR(1000) | لا |  |  |  |
| InventorySeverity | VARCHAR(10) | لا |  |  | أي قيمة بيع للمخزون من فئات المنتجات enum: STAGNANT, CRISIS |
| StLinesWithdrawnPct | DECIMAL(9,4) | لا |  |  | تخفيض الخطوط قصيرة الأجل غير الملتزمة عند تجديدها، قبل عامل البنك |
| RateBp | INT | لا |  |  | ارتفاع سعر الفائدة على الدين المتغير |
| PrivateArLossPct | DECIMAL(9,4) | لا |  |  | خسارة الذمم الخاصة فوق 180 يومًا قبل أثر الطلب |
| BaseDsoDays | DECIMAL(9,2) | لا |  |  |  |
| IsResilienceBase | BIT | لا | 0 |  | السيناريو الذي يقيس الصمود والنظرة (ركود السوق) |
| UndrawnAvailablePct | DECIMAL(9,4) | لا | 100 |  | ما يبقى متاحًا من الحدود الملتزمة غير المسحوبة (0: توقفها البنوك)، قبل الإيقاف بعامل البنك |
| UndrawnCutPct | DECIMAL(9,4) | لا | 0 |  | ما توقفه البنوك من الحدود غير المسحوبة، مضروبًا في عامل البنك (مخاطر القطاع والبلد) |
| LenderMarginBp | INT | لا | 0 |  | زيادة هامش البنك على التسهيلات قصيرة الأجل والقبولات عند تجديدها، مضروبة في عامل البنك |
| LenderFeesBp | INT | لا | 0 |  | الرسوم الإدارية الإضافية على التسهيلات قصيرة الأجل والقبولات، مضروبة في عامل البنك |
| DurationMonths | INT | لا | 12 |  | مدة الأثر بالأشهر (للعرض) |
| OtherCountryMult | DECIMAL(5,3) | لا | 1 |  | مضاعف الضغط لبلد ليس له صف في fin.MacroScenarioCountry |
| SortOrder | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(MacroScenarioId) · UQ(Code) · UQ(IsResilienceBase) WHERE IsResilienceBase = 1

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `StLinesWithdrawnPct BETWEEN 0 AND 100 AND PrivateArLossPct BETWEEN 0 AND 100 AND RateBp >= 0 AND BaseDsoDays >= 0` · `UndrawnAvailablePct BETWEEN 0 AND 100 AND DurationMonths BETWEEN 1 AND 60 AND OtherCountryMult BETWEEN 0 AND 2` · `UndrawnCutPct BETWEEN 0 AND 100 AND LenderMarginBp >= 0 AND LenderFeesBp >= 0`

### `fin.MacroScenarioCountry` — The multiplier of a macro scenario's stress for a country it hits more or less than others; a country without a row takes the scenario's OtherCountryMult (docs/35 section 14, ADR 0020)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **MacroScenarioCountryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| MacroScenarioId | INT | لا |  | fin.MacroScenario |  |
| CountryId | INT | لا |  | ref.Country |  |
| Multiplier | DECIMAL(5,3) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(MacroScenarioCountryId) · UQ(MacroScenarioId, CountryId)

**قيود:** `Multiplier BETWEEN 0 AND 2`

### `fin.MacroScenarioIntensity` — The intensity 0 to 1 of a driver in a macro scenario (docs/35 section 14)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **MacroScenarioIntensityId** | INT IDENTITY | لا | | | مفتاح أساسي |
| MacroScenarioId | INT | لا |  | fin.MacroScenario |  |
| ShockDriverId | INT | لا |  | fin.ShockDriver |  |
| Intensity | DECIMAL(5,3) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(MacroScenarioIntensityId) · UQ(MacroScenarioId, ShockDriverId)

**قيود:** `Intensity BETWEEN 0 AND 1`

### `fin.IndustrySensitivity` — The sensitivity 0 (none) to 5 (extreme) of an activity to a driver of stress (docs/35 section 14)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **IndustrySensitivityId** | INT IDENTITY | لا | | | مفتاح أساسي |
| IndustryId | INT | لا |  | ref.Industry |  |
| ShockDriverId | INT | لا |  | fin.ShockDriver |  |
| Sensitivity | TINYINT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(IndustrySensitivityId) · UQ(IndustryId, ShockDriverId)

**قيود:** `Sensitivity BETWEEN 0 AND 5`

### `fin.CountryRiskProfile` — The credit risk of a country for its companies: country risk 1 to 6, the published sovereign rating and its date, the ceiling of a company's grade, and the country's exposure to each driver of stress; one default row for a country without a profile (docs/35 section 13, ADR 0019)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CountryRiskProfileId** | INT IDENTITY | لا | | | مفتاح أساسي |
| CountryId | INT | نعم |  | ref.Country | فارغ للصف الافتراضي |
| IsDefault | BIT | لا | 0 |  |  |
| CountryRisk | TINYINT | لا |  |  |  |
| SovereignRatingGradeId | INT | نعم |  | fin.RatingGrade | التصنيف السيادي المنشور إن وُجد؛ يتحقق منه مشغّل المنصة |
| RatingAsOf | VARCHAR(7) | نعم |  |  | الشهر YYYY-MM |
| CeilingGradeId | INT | لا |  | fin.RatingGrade | سقف درجة الشركة: التصنيف السيادي، أو سقف مخاطر البلد إن لم يُصنَّف |
| ExpDemand | DECIMAL(5,2) | لا |  |  |  |
| ExpGovSpending | DECIMAL(5,2) | لا |  |  |  |
| ExpRealEstate | DECIMAL(5,2) | لا |  |  |  |
| ExpConflict | DECIMAL(5,2) | لا |  |  |  |
| ExpOil | DECIMAL(5,2) | لا |  |  |  |
| ExpCredit | DECIMAL(5,2) | لا |  |  |  |
| ExpImportFx | DECIMAL(5,2) | لا |  |  |  |
| NoteAr | NVARCHAR(1000) | نعم |  |  |  |
| NoteEn | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CountryRiskProfileId) · UQ(CountryId) WHERE CountryId IS NOT NULL · UQ(IsDefault) WHERE IsDefault = 1

**قيود:** `CountryRisk BETWEEN 1 AND 6` · `(IsDefault = 1 AND CountryId IS NULL) OR (IsDefault = 0 AND CountryId IS NOT NULL)` · `ExpDemand BETWEEN 0.3 AND 2 AND ExpGovSpending BETWEEN 0.3 AND 2 AND ExpRealEstate BETWEEN 0.3 AND 2 AND ExpConflict BETWEEN 0.3 AND 2 AND ExpOil BETWEEN 0.3 AND 2 AND ExpCredit BETWEEN 0.3 AND 2 AND ExpImportFx BETWEEN 0.3 AND 2` · `RatingAsOf IS NULL OR RatingAsOf COLLATE Arabic_100_BIN2 LIKE '[12][0-9][0-9][0-9]-[01][0-9]'`

### `fin.CountryRegion` — A city or region of a country and how much more or less its property falls, and how exposed it is to conflict, than its country (docs/35 section 14)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CountryRegionId** | INT IDENTITY | لا | | | مفتاح أساسي |
| CountryId | INT | لا |  | ref.Country |  |
| Code | VARCHAR(10) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| Tier | VARCHAR(10) | لا |  |  | enum: PRIME, MAJOR, SECONDARY, PERIPHERAL |
| RealEstateMult | DECIMAL(5,2) | لا |  |  |  |
| ConflictMult | DECIMAL(5,2) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CountryRegionId) · UQ(CountryId, Code)

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `RealEstateMult BETWEEN 0.5 AND 2 AND ConflictMult BETWEEN 0.5 AND 2`

### `fin.RiskAnchor` — The anchor of a company's business risk from its country risk and its industry risk, a notch of the 21-grade scale: the computed sector risk sub-factor and the centre of the expected range (docs/35 section 13)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **RiskAnchorId** | INT IDENTITY | لا | | | مفتاح أساسي |
| CountryRisk | TINYINT | لا |  |  |  |
| IndustryRisk | TINYINT | لا |  |  |  |
| AnchorNotch | TINYINT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RiskAnchorId) · UQ(CountryRisk, IndustryRisk)

**قيود:** `CountryRisk BETWEEN 1 AND 6 AND IndustryRisk BETWEEN 1 AND 6 AND AnchorNotch BETWEEN 1 AND 21`

### `fin.ProductCategory` — A category of products or services and its credit behaviour: cash-flow quality, revenue sensitivity, inventory sale value and time to sell in normal, stagnant and crisis markets (docs/35 section 5)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ProductCategoryId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| CashFlowQuality | TINYINT | لا |  |  | 1 الأفضل ... 5 الأضعف |
| DemandSensitivity | TINYINT | لا |  |  | حساسية الطلب على الفئة 0 إلى 5؛ تحل محل حساسية النشاط للطلب حين تُدخل الشركة منتجاتها |
| InvValueNormalPct | DECIMAL(9,4) | لا |  |  | قيمة بيع المخزون من الدفترية |
| InvValueStagnantPct | DECIMAL(9,4) | لا |  |  |  |
| InvValueCrisisPct | DECIMAL(9,4) | لا |  |  |  |
| DaysToSellNormal | INT | لا |  |  |  |
| DaysToSellStagnant | INT | لا |  |  |  |
| DaysToSellCrisis | INT | لا |  |  |  |
| CrisisExtraDso | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ProductCategoryId) · UQ(Code)

**قيود:** `CashFlowQuality BETWEEN 1 AND 5` · `DemandSensitivity BETWEEN 0 AND 5` · `InvValueNormalPct BETWEEN 0 AND 100 AND InvValueStagnantPct BETWEEN 0 AND 100 AND InvValueCrisisPct BETWEEN 0 AND 100`

### `fin.StandardLine` — The standard statement line catalogue of the platform: every point of the statements the credit assessment reads, its kind and the line it breaks down; installed into a tenant's catalogue by fin.usp_InstallStandardLines (docs/35 section 4, FR-FIN-001)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **StandardLineId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| Section | VARCHAR(12) | لا |  |  | enum: BS_ASSET, BS_LIABILITY, BS_EQUITY, IS, CF, MEMO |
| LineKind | VARCHAR(10) | لا |  |  | LINE يدخل الإجماليات؛ OF_WHICH «منه» لا يزيد على أصله؛ DETAIL تفصيل بلا هذا الحد (الإجمالي قبل المخصص)؛ MEMO إفصاح enum: LINE, TOTAL, OF_WHICH, DETAIL, MEMO |
| ParentCode | VARCHAR(40) | نعم |  |  | البند الذي يفصّله OF_WHICH أو DETAIL |
| NameAr | NVARCHAR(300) | لا |  |  |  |
| NameEn | NVARCHAR(300) | لا |  |  |  |
| IsRequired | BIT | لا | 0 |  | من البنود الأساسية؛ غيرها اختياري يُعد صفرًا إن لم يُدخل |
| TotalFormula | NVARCHAR(500) | نعم |  |  | للإجمالي، مثل GROSS_PROFIT = REVENUE - COGS |
| SortOrder | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StandardLineId) · UQ(Code)

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%' AND Code NOT LIKE '[0-9_]%'` · `(LineKind IN ('OF_WHICH','DETAIL') AND ParentCode IS NOT NULL) OR (LineKind NOT IN ('OF_WHICH','DETAIL') AND ParentCode IS NULL)` · `(LineKind = 'TOTAL' AND TotalFormula IS NOT NULL) OR (LineKind <> 'TOTAL' AND TotalFormula IS NULL)` · `ParentCode IS NULL OR ParentCode <> Code`

### `fin.StandardLineTotal` — The components of a standard total and their sign, so a total is recomputed after a pro-forma change (docs/35 section 12)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **StandardLineTotalId** | INT IDENTITY | لا | | | مفتاح أساسي |
| TotalCode | VARCHAR(40) | لا |  |  |  |
| ComponentCode | VARCHAR(40) | لا |  |  |  |
| Sign | SMALLINT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StandardLineTotalId) · UQ(TotalCode, ComponentCode)

**قيود:** `Sign IN (-1,1)` · `TotalCode <> ComponentCode`

### `fin.ScorecardParameter` — A parameter of a scorecard version: a haircut of the break-up test, a collateral haircut, a band of the loss given default, a liquidity threshold, a cost rule; frozen with its scorecard (docs/35 sections 5, 9 and 10)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardParameterId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ScorecardId | INT | لا |  | fin.Scorecard |  |
| GroupCode | VARCHAR(18) | لا |  |  | enum: CARD, REALISABLE_HAIRCUT, COLLATERAL_HAIRCUT, LGD_BAND, SGL, FIXED_COST, SCENARIO |
| ParamKey | VARCHAR(40) | لا |  |  |  |
| Value | DECIMAL(19,6) | لا |  |  |  |
| Value2 | DECIMAL(19,6) | نعم |  |  | لنطاق الخسارة: الدرجات؛ ولغيره فارغ |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardParameterId) · UQ(ScorecardId, GroupCode, ParamKey)

### `fin.ScorecardSubfactor` — A sub-factor of a qualitative factor of a scorecard, with its grading guide; the factor's grade is the average of the graded sub-factors when the analyst grades them (docs/35 section 5)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **ScorecardSubfactorId** | INT IDENTITY | لا | | | مفتاح أساسي |
| ScorecardId | INT | لا |  | fin.Scorecard |  |
| MetricId | INT | لا |  | fin.CreditMetric | العامل النوعي |
| Code | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| GuideAr | NVARCHAR(1500) | لا |  |  |  |
| SortOrder | INT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ScorecardSubfactorId) · UQ(ScorecardId, MetricId, Code)

### `fin.CreditRemedy` — A remedy the report proposes against a finding: a real action, or a presentation that follows the legal substance and needs its evidence, with the change it makes to the statement for the pro-forma grade (docs/35 section 12)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CreditRemedyId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| Kind | VARCHAR(12) | لا |  |  | enum: REAL_ACTION, PRESENTATION |
| MinLevel | VARCHAR(10) | لا |  |  | أدنى مستوى خطر يُقترح عنده enum: MODERATE, ELEVATED, HIGH, CRITICAL |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| TextAr | NVARCHAR(1000) | لا |  |  |  |
| TextEn | NVARCHAR(1000) | لا |  |  |  |
| EvidenceAr | NVARCHAR(500) | نعم |  |  |  |
| EvidenceEn | NVARCHAR(500) | نعم |  |  |  |
| Funding | VARCHAR(15) | لا |  |  | ما يحتاجه الحل: توقيع الشركاء، نقدهم، البنوك، التشغيل... enum: OWNER_CONSENT, OWNER_CASH, RELATED_PARTIES, LENDERS, OPERATIONS, ASSET_SALE, POLICY, DISCLOSURE |
| SetsEvidence | VARCHAR(24) | نعم |  |  | الدليل الذي يفترضه الحل في حسابه التقديري enum: SUBORDINATION, CAPITAL_RESOLUTION, WAIVER_BEFORE_PERIOD_END |
| SortOrder | INT | لا | 0 |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditRemedyId) · UQ(Code)

**قيود:** `Kind = 'REAL_ACTION' OR EvidenceAr IS NOT NULL` · `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'`

### `fin.CreditRemedyTrigger` — A finding a remedy answers: a metric or an adjustment code

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CreditRemedyTriggerId** | INT IDENTITY | لا | | | مفتاح أساسي |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| TriggerCode | VARCHAR(40) | لا |  |  |  |
| SortOrder | INT | لا |  |  | الترتيب الذي يُبحث به عن النتيجة التي تستدعي الحل |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditRemedyTriggerId) · UQ(RemedyId, TriggerCode) · UQ(RemedyId, SortOrder)

### `fin.CreditRemedyStep` — A step of a remedy's pro-forma: an amount, a share of a reference line capped by what the lines decreased hold, taken from up to three lines and added to up to three

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CreditRemedyStepId** | INT IDENTITY | لا | | | مفتاح أساسي |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| StepNo | TINYINT | لا |  |  |  |
| RefLine | VARCHAR(40) | لا |  |  |  |
| Pct | DECIMAL(9,4) | لا |  |  |  |
| Dec1 | VARCHAR(40) | نعم |  |  |  |
| Dec2 | VARCHAR(40) | نعم |  |  |  |
| Dec3 | VARCHAR(40) | نعم |  |  |  |
| Inc1 | VARCHAR(40) | نعم |  |  |  |
| Inc2 | VARCHAR(40) | نعم |  |  |  |
| Inc3 | VARCHAR(40) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditRemedyStepId) · UQ(RemedyId, StepNo)

**قيود:** `Pct > 0 AND Pct <= 100` · `Dec1 IS NOT NULL OR Inc1 IS NOT NULL` · `(Dec2 IS NULL OR Dec1 IS NOT NULL) AND (Dec3 IS NULL OR Dec2 IS NOT NULL)` · `(Inc2 IS NULL OR Inc1 IS NOT NULL) AND (Inc3 IS NULL OR Inc2 IS NOT NULL)`

### `fin.StrengtheningPlan` — A ready-made plan to strengthen the statements: a package of remedies applied one after another, or the best plan the engine builds step by step from the remedies the findings call for (docs/35 section 12)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **StrengtheningPlanId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Code | VARCHAR(40) | لا |  |  |  |
| Kind | VARCHAR(10) | لا |  |  | enum: PACKAGE, OPTIMAL |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| TextAr | NVARCHAR(1000) | لا |  |  |  |
| TextEn | NVARCHAR(1000) | لا |  |  |  |
| ExcludeFunding | VARCHAR(100) | نعم |  |  | للخطة المثلى: أنواع التمويل المستبعدة مفصولة بفواصل |
| SortOrder | INT | لا |  |  |  |
| IsActive | BIT | لا | 1 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StrengtheningPlanId) · UQ(Code)

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `Kind = 'OPTIMAL' OR ExcludeFunding IS NULL`

### `fin.StrengtheningPlanMember` — A remedy of a package plan, in the order the plan applies it

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **StrengtheningPlanMemberId** | INT IDENTITY | لا | | | مفتاح أساسي |
| PlanId | INT | لا |  | fin.StrengtheningPlan |  |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| SortOrder | INT | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(StrengtheningPlanMemberId) · UQ(PlanId, RemedyId) · UQ(PlanId, SortOrder)

### `fin.CreditText` — A text of the credit report: the reconciliation rows, the disclosures and data the report asks for, the outlook rules and views, the liquidity labels, the resilience and the funding kinds (docs/35)

*عالمي*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| **CreditTextId** | INT IDENTITY | لا | | | مفتاح أساسي |
| Domain | VARCHAR(12) | لا |  |  | enum: RECLASS, DISCLOSURE, REQUEST, OUTLOOK, OUTLOOK_VIEW, LIQUIDITY, RESILIENCE, FUNDING |
| Code | VARCHAR(40) | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| NameEn | NVARCHAR(200) | لا |  |  |  |
| TextAr | NVARCHAR(1000) | لا |  |  |  |
| TextEn | NVARCHAR(1000) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditTextId) · UQ(Domain, Code)

### `fin.CreditAssessment` — Credit assessment of an approved statement on a sector scorecard: the study of the balance sheet with a grade on the Moody's scale, its strengths, weaknesses and risks; written as a draft, computed by the database, approved by someone else (FR-FIN-020 to FR-FIN-024, BR-FIN-018 to BR-FIN-024; owner request 2026-10-18)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| StatementId | BIGINT | لا |  | fin.FinancialStatement (via CompanyId) | القائمة المقيَّمة، معتمدة ومن الشركة نفسها |
| PriorStatementId | BIGINT | نعم |  | fin.FinancialStatement (via CompanyId) | قائمة المقارنة؛ فارغة = يختارها الإجراء |
| ScorecardId | INT | لا |  | fin.Scorecard | بطاقة القطاع وإصدارها |
| AssessmentDate | DATE | لا |  |  |  |
| FxRateToScorecard | DECIMAL(19,8) | نعم |  |  | سعر عملة القائمة بعملة البطاقة؛ إلزامي إن اختلفتا (BR-FIN-019) |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, SUBMITTED, APPROVED, REJECTED, SUPERSEDED |
| ComputedAt | DATETIME2(3) | نعم |  |  | من هنا إلى Snapshot: يكتبها fin.usp_ComputeCreditAssessment وحده (DENY على tp_app، 046) |
| InputsHash | VARCHAR(64) | نعم |  |  | بصمة SHA-256 لما قرأه الحساب؛ التقديم يُرفض إن تغيّر بعده (50063) |
| UsedPriorStatementId | BIGINT | نعم |  | fin.FinancialStatement (via CompanyId) |  |
| ResultState | VARCHAR(17) | نعم |  |  | INDICATIVE: درجة مالية فقط لنقص العوامل النوعية، لا تُقدَّم enum: RATED, INDICATIVE, INSUFFICIENT_DATA |
| CoveragePct | DECIMAL(5,2) | نعم |  |  | من أوزان المقاييس الكمية |
| FinancialScore | DECIMAL(9,4) | نعم |  |  | مجموع المقاييس الكمية وحدها |
| FinancialGradeId | INT | نعم |  | fin.RatingGrade |  |
| WeightedScore | DECIMAL(9,4) | نعم |  |  |  |
| IndicatedGradeId | INT | نعم |  | fin.RatingGrade |  |
| AdjustmentNotches | INT | نعم |  |  |  |
| CapGradeId | INT | نعم |  | fin.RatingGrade | أشد سقف طُبّق |
| StandaloneGradeId | INT | نعم |  | fin.RatingGrade | بعد التنزيل والسقوف المنفردة، قبل الدعم |
| SupportNotches | INT | نعم |  |  |  |
| OverrideNotches | INT | نعم |  |  |  |
| FinalGradeId | INT | نعم |  | fin.RatingGrade |  |
| FacilityGradeId | INT | نعم |  | fin.RatingGrade | درجة التسهيلات: درجة الملتزم بعد نطاق الخسارة عند التعثر من الضمانات (docs/35 §10) |
| LgdPct | DECIMAL(5,2) | نعم |  |  | الخسارة المتوقعة عند التعثر من التعرض |
| LgdBand | VARCHAR(4) | نعم |  |  | LGD1..LGD6 |
| LiquidityLabel | VARCHAR(5) | نعم |  |  | SGL-1..SGL-4 من مصادر السنة واستخداماتها (docs/35 §9) |
| CompletenessPct | DECIMAL(5,2) | نعم |  |  | الإفصاحات المطلوبة المعطاة (docs/35 §11) |
| AdjustedDebt | DECIMAL(19,4) | نعم |  |  | الدين المعدَّل تحليليًا بعملة القائمة |
| AdjustedTnw | DECIMAL(19,4) | نعم |  |  | صافي الثروة الملموسة المعدَّلة |
| RealisableNetWorth | DECIMAL(19,4) | نعم |  |  | الأصول بعد خصومات التسييل ناقص الخصوم المعدَّلة |
| SummaryAr | NVARCHAR(1000) | نعم |  |  |  |
| SummaryEn | NVARCHAR(1000) | نعم |  |  |  |
| Snapshot | NVARCHAR(MAX) | نعم |  |  | البنود المقروءة ومعامل التحويل إلى سنة والسعر وإصدار البطاقة |
| PreparedBy | BIGINT | نعم |  | sec.AppUser |  |
| PreparedOn | DATETIME2(3) | نعم |  |  |  |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| RejectionReason | NVARCHAR(500) | نعم |  |  |  |
| EndorsedBy | BIGINT | نعم |  | sec.AppUser | تصديق الاستعمال خارج الشركة: من خارج خط الإعداد والاعتماد (fin.credit.endorse، ADR 0029) |
| EndorsedOn | DATETIME2(3) | نعم |  |  |  |
| EndorsementNote | NVARCHAR(1000) | نعم |  |  | سبب التصديق ونطاقه: لمن يُعرض ولأي غرض |
| EndorsedBias | VARCHAR(12) | نعم |  |  | ميل الشركة مقابل جهاتها يوم التصديق (ADR 0030) enum: INSUFFICIENT, OPTIMISTIC, CONSERVATIVE, ALIGNED |
| EndorsedRatings | INT | نعم |  |  | عدد التصنيفات المقارنة يومها |
| EndorsedLastRatingDate | DATE | نعم |  |  | تاريخ آخر تصنيف لجهة تمويل يومها |
| IndustryId | INT | نعم |  | ref.Industry | النشاط الذي قرأه التقييم (من الشركة عند الحساب) |
| SectorPosition | VARCHAR(10) | نعم |  |  | الدرجة مقابل المدى المتوقع لقطاعها enum: ABOVE, WITHIN, BELOW |
| Resilience | VARCHAR(10) | نعم |  |  | من سيناريو ركود السوق (docs/35 §13) enum: RESILIENT, MODERATE, VULNERABLE |
| Outlook | VARCHAR(10) | نعم |  |  | اتجاه الدرجة خلال 12-18 شهرًا (docs/35 §15) enum: POSITIVE, STABLE, NEGATIVE, DEVELOPING |
| OutlookRules | VARCHAR(200) | نعم |  |  | القواعد التي تحققت مفصولة بفواصل |
| UpHeadroom | DECIMAL(9,4) | نعم |  |  | المسافة من المجموع المرجح إلى الدرجة الأعلى |
| DownHeadroom | DECIMAL(9,4) | نعم |  |  | المسافة إلى الدرجة الأدنى |
| StrengtheningRequested | BIT | لا | 0 |  | طلب العميل خطط تقوية القوائم (docs/35 §12) |
| IsTrial | BIT | لا | 0 |  | تقييم تجريبي: يقرأ قائمة مسودة أو مقدّمة قبل اعتمادها، ويُحسب ويُعاد ولا يُقدَّم (ADR 0022، BR-FIN-036) |
| MarketCountryId | INT | نعم |  | ref.Country | بلد السوق الرئيسي؛ فارغ = بلد تأسيس الشركة (ADR 0019) |
| MarketRegionCode | VARCHAR(10) | نعم |  |  | المدينة أو المنطقة الرئيسية من fin.CountryRegion، للعقار والمقاولات خاصة |
| CountryRisk | TINYINT | نعم |  |  | من هنا: يكتبها الإجراء؛ مخاطر البلد التي قرأها التقييم |
| IndustryRisk | TINYINT | نعم |  |  |  |
| AnchorGradeId | INT | نعم |  | fin.RatingGrade | مرتكز مخاطر البلد والنشاط |
| CountryCeilingGradeId | INT | نعم |  | fin.RatingGrade | سقف البلد الذي طُبّق |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentId) · UQ(PublicId) · UQ(TenantId, StatementId) WHERE Status = 'APPROVED'

**قيود:** `FxRateToScorecard IS NULL OR FxRateToScorecard > 0` · `PriorStatementId IS NULL OR PriorStatementId <> StatementId` · `(ResultState IS NULL AND FinancialScore IS NULL AND WeightedScore IS NULL AND IndicatedGradeId IS NULL AND FinalGradeId IS NULL) OR (ResultState IS NOT NULL AND ComputedAt IS NOT NULL AND InputsHash IS NOT NULL AND CoveragePct IS NOT NULL AND ((ResultState = 'INSUFFICIENT_DATA' AND FinancialScore IS NULL AND WeightedScore IS NULL AND IndicatedGradeId IS NULL AND FinalGradeId IS NULL) OR (ResultState = 'INDICATIVE' AND FinancialScore IS NOT NULL AND FinancialGradeId IS NOT NULL AND WeightedScore IS NULL AND FinalGradeId IS NULL) OR (ResultState = 'RATED' AND FinancialScore IS NOT NULL AND WeightedScore IS NOT NULL AND IndicatedGradeId IS NOT NULL AND StandaloneGradeId IS NOT NULL AND FinalGradeId IS NOT NULL)))` · `WeightedScore IS NULL OR (WeightedScore >= 0.5 AND WeightedScore <= 20.5)` · `FinancialScore IS NULL OR (FinancialScore >= 0.5 AND FinancialScore <= 20.5)` · `CoveragePct IS NULL OR (CoveragePct >= 0 AND CoveragePct <= 100)` · `SupportNotches IS NULL OR SupportNotches BETWEEN 0 AND 2` · `OverrideNotches IS NULL OR OverrideNotches BETWEEN -2 AND 1` · `Status NOT IN ('SUBMITTED','APPROVED','SUPERSEDED') OR (ResultState IS NOT NULL AND ResultState = 'RATED' AND PreparedBy IS NOT NULL AND PreparedOn IS NOT NULL)` · `Status NOT IN ('APPROVED','SUPERSEDED') OR (ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `ApprovedBy IS NULL OR PreparedBy IS NULL OR ApprovedBy <> PreparedBy` · `Status <> 'REJECTED' OR RejectionReason IS NOT NULL` · `(EndorsedBy IS NULL AND EndorsedOn IS NULL AND EndorsementNote IS NULL) OR (EndorsedBy IS NOT NULL AND EndorsedOn IS NOT NULL AND EndorsementNote IS NOT NULL AND Status IN ('APPROVED','SUPERSEDED') AND IsTrial = 0)` · `EndorsedBy IS NULL OR (EndorsedBy <> PreparedBy AND EndorsedBy <> ApprovedBy)` · `(EndorsedBy IS NULL AND EndorsedBias IS NULL AND EndorsedRatings IS NULL AND EndorsedLastRatingDate IS NULL) OR (EndorsedBy IS NOT NULL AND EndorsedBias IS NOT NULL AND EndorsedRatings IS NOT NULL)` · `MarketRegionCode IS NULL OR MarketRegionCode COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `CountryRisk IS NULL OR CountryRisk BETWEEN 1 AND 6` · `IndustryRisk IS NULL OR IndustryRisk BETWEEN 1 AND 6`

### `fin.CreditAssessmentInput` — The analyst's inputs to an assessment: the grade of a qualitative factor, group support or an override, each with its justification; they change only while the assessment is a draft (BR-FIN-021, BR-FIN-022)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentInputId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| Kind | VARCHAR(13) | لا |  |  | enum: QUALITATIVE, SUBFACTOR, GROUP_SUPPORT, OVERRIDE, MARKET_SIZE, FX_RATE, EVIDENCE |
| MetricId | INT | نعم |  | fin.CreditMetric | العامل النوعي |
| SubfactorId | INT | نعم |  | fin.ScorecardSubfactor | العامل الفرعي (SUBFACTOR) |
| Amount | DECIMAL(19,4) | نعم |  |  | حجم السوق بعملة القائمة (MARKET_SIZE) |
| CurrencyId | INT | نعم |  | ref.Currency | عملة السعر (FX_RATE) |
| Rate | DECIMAL(19,8) | نعم |  |  | سعر العملة بعملة القائمة (FX_RATE) |
| EvidenceCode | VARCHAR(29) | نعم |  |  | دليل التبويب (docs/35 §6) enum: SUBORDINATION, CAPITAL_RESOLUTION, WAIVER_BEFORE_PERIOD_END, REFINANCING_BEFORE_PERIOD_END |
| GradeId | INT | نعم |  | fin.RatingGrade | درجته |
| Notches | INT | نعم |  |  | الدعم 1..2، والتجاوز −2..+1 بلا صفر: الرفع درجة واحدة لأن الشركة تقيّم نفسها |
| ParentAssessmentId | BIGINT | نعم |  | fin.CreditAssessment | التقييم المعتمد للأم أو القابضة (GROUP_SUPPORT) |
| Justification | NVARCHAR(1000) | لا |  |  |  |
| DocumentId | BIGINT | نعم |  | doc.Document | المستند المؤيد؛ يلزم لدرجة نوعية تبعد أكثر من الحد عن الدرجة المالية (BR-FIN-021) |
| EnteredBy | BIGINT | نعم |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentInputId) · UQ(TenantId, AssessmentId, Kind, MetricId, SubfactorId, CurrencyId, EvidenceCode)

**قيود:** `(Kind = 'QUALITATIVE' AND MetricId IS NOT NULL AND GradeId IS NOT NULL AND Notches IS NULL AND ParentAssessmentId IS NULL AND SubfactorId IS NULL AND Amount IS NULL AND CurrencyId IS NULL AND Rate IS NULL AND EvidenceCode IS NULL) OR (Kind = 'SUBFACTOR' AND MetricId IS NOT NULL AND SubfactorId IS NOT NULL AND GradeId IS NOT NULL AND Notches IS NULL AND ParentAssessmentId IS NULL AND Amount IS NULL AND CurrencyId IS NULL AND Rate IS NULL AND EvidenceCode IS NULL) OR (Kind = 'GROUP_SUPPORT' AND MetricId IS NULL AND GradeId IS NULL AND Notches IS NOT NULL AND Notches BETWEEN 1 AND 2 AND ParentAssessmentId IS NOT NULL AND SubfactorId IS NULL AND Amount IS NULL AND CurrencyId IS NULL AND Rate IS NULL AND EvidenceCode IS NULL) OR (Kind = 'OVERRIDE' AND MetricId IS NULL AND GradeId IS NULL AND Notches IS NOT NULL AND Notches IN (-2,-1,1) AND ParentAssessmentId IS NULL AND SubfactorId IS NULL AND Amount IS NULL AND CurrencyId IS NULL AND Rate IS NULL AND EvidenceCode IS NULL) OR (Kind = 'MARKET_SIZE' AND Amount IS NOT NULL AND Amount > 0 AND MetricId IS NULL AND GradeId IS NULL AND Notches IS NULL AND ParentAssessmentId IS NULL AND SubfactorId IS NULL AND CurrencyId IS NULL AND Rate IS NULL AND EvidenceCode IS NULL) OR (Kind = 'FX_RATE' AND CurrencyId IS NOT NULL AND Rate IS NOT NULL AND Rate > 0 AND MetricId IS NULL AND GradeId IS NULL AND Notches IS NULL AND ParentAssessmentId IS NULL AND SubfactorId IS NULL AND Amount IS NULL AND EvidenceCode IS NULL) OR (Kind = 'EVIDENCE' AND EvidenceCode IS NOT NULL AND DocumentId IS NOT NULL AND MetricId IS NULL AND GradeId IS NULL AND Notches IS NULL AND ParentAssessmentId IS NULL AND SubfactorId IS NULL AND Amount IS NULL AND CurrencyId IS NULL AND Rate IS NULL)` · `ParentAssessmentId IS NULL OR ParentAssessmentId <> AssessmentId` · `LEN(LTRIM(RTRIM(Justification))) >= 10`

### `fin.CreditAssessmentFactor` — A scorecard metric of an assessment: its value, its score on the linear continuum, its grade, weight and contribution; written by fin.usp_ComputeCreditAssessment only (BR-FIN-018, BR-FIN-019)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentFactorId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| MetricId | INT | لا |  | fin.CreditMetric |  |
| FactorCode | VARCHAR(30) | لا |  |  |  |
| Weight | DECIMAL(5,2) | لا |  |  |  |
| EffectiveWeight | DECIMAL(9,4) | نعم |  |  | الوزن بعد إعادة توزيعه على المقاييس ذات الدرجة |
| Status | VARCHAR(14) | لا |  |  | EXTREME: لا معنى للنسبة فتُعطى طرف الخط (لا دين، EBITDA سالب...) enum: COMPUTED, EXTREME, NOT_COMPUTABLE, ANALYST |
| Value | DECIMAL(19,6) | نعم |  |  |  |
| Score | DECIMAL(9,4) | نعم |  |  |  |
| GradeId | INT | نعم |  | fin.RatingGrade |  |
| Contribution | DECIMAL(9,4) | نعم |  |  |  |
| Reason | NVARCHAR(300) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentFactorId) · UQ(TenantId, AssessmentId, MetricId)

**قيود:** `(Status = 'COMPUTED' AND Value IS NOT NULL AND Score IS NOT NULL AND Reason IS NULL) OR (Status = 'EXTREME' AND Value IS NULL AND Score IS NOT NULL AND Reason IS NOT NULL) OR (Status = 'NOT_COMPUTABLE' AND Value IS NULL AND Score IS NULL AND Reason IS NOT NULL) OR (Status = 'ANALYST' AND Value IS NULL AND Score IS NOT NULL)` · `Score IS NULL OR (Score >= 0.5 AND Score <= 20.5)` · `Weight > 0 AND Weight <= 100`

### `fin.CreditAssessmentFinding` — A finding of an assessment, with its text: a strength, a point to note or watch, a weakness, a critical risk or an adjustment, from the scorecard, an item rule, the covenants or the bank flows; written by fin.usp_ComputeCreditAssessment only (BR-FIN-020)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentFindingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| SeqNo | INT | لا |  |  |  |
| Kind | VARCHAR(13) | لا |  |  | enum: STRENGTH, INFO, WATCH, WEAKNESS, CRITICAL_RISK, ADJUSTMENT |
| Source | VARCHAR(10) | لا |  |  | DATA: إفصاح ناقص أو غير متسق enum: SCORECARD, ITEM_RULE, ADJUSTMENT, COVENANT, BANK_FLOW, ANALYST, DATA, LIQUIDITY, FACILITY |
| RuleCode | VARCHAR(40) | لا |  |  | رمز المقياس أو القاعدة أو التعديل |
| LineCode | VARCHAR(40) | نعم |  |  | بند الميزانية لقاعدة البند |
| RiskLevel | VARCHAR(10) | نعم |  |  | enum: LOW, MODERATE, ELEVATED, HIGH, CRITICAL |
| Value | DECIMAL(19,6) | نعم |  |  |  |
| PriorValue | DECIMAL(19,6) | نعم |  |  |  |
| Notches | INT | نعم |  |  |  |
| RefId | BIGINT | نعم |  |  | اختبار التعهد أو التعهد للنتائج من التعهدات والتحويلات |
| TextAr | NVARCHAR(1000) | لا |  |  |  |
| TextEn | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentFindingId) · UQ(TenantId, AssessmentId, SeqNo)

**قيود:** `SeqNo >= 1` · `Source <> 'ITEM_RULE' OR LineCode IS NOT NULL` · `RiskLevel IS NULL OR Source = 'ITEM_RULE'`

### `fin.CreditAssessmentGuarantor` — A guarantor of the company's facilities with the net worth statement the analyst read: partners' solvency for the facility grade (docs/35 section 10); changes only while the assessment is a draft

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentGuarantorId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| PartyId | BIGINT | لا |  | pty.Party | الشريك أو الكفيل |
| NetWorth | DECIMAL(19,4) | لا |  |  | صافي الثروة المصرَّح به بعملة القائمة |
| LiquidAssets | DECIMAL(19,4) | لا |  |  | منه أصول سائلة (نقد وودائع وأسهم مدرجة) |
| GuaranteesGiven | DECIMAL(19,4) | لا | 0 |  | كفالات قدّمها لالتزامات أخرى |
| GuaranteedAmount | DECIMAL(19,4) | لا |  |  | ما يكفله من تسهيلات الشركة |
| AsOfDate | DATE | لا |  |  |  |
| DocumentId | BIGINT | لا |  | doc.Document | إقرار الذمة المالية أو القوائم الشخصية |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentGuarantorId) · UQ(TenantId, AssessmentId, PartyId)

**قيود:** `NetWorth >= 0 AND LiquidAssets >= 0 AND GuaranteesGiven >= 0 AND GuaranteedAmount > 0` · `LiquidAssets <= NetWorth`

### `fin.LenderRating` — A rating of the company that a lender communicated to it: the lender's own grade and its equivalent on the 21-grade scale (given by the lender or mapped by the treasury), with what the lender said; compared with the company's assessment of that date (docs/36 F6, ADR 0026)

*مملوك للمشترك · بمصدر*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LenderRatingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| LenderInstitutionId | BIGINT | لا |  | ins.Institution |  |
| RatingDate | DATE | لا |  |  |  |
| LenderGradeLabel | NVARCHAR(40) | نعم |  |  | درجة البنك بتسميته الداخلية إن كانت له |
| GradeId | INT | لا |  | fin.RatingGrade | مقابلها على سلّم الإحدى والعشرين درجة |
| MappingKind | VARCHAR(18) | لا |  |  | enum: GIVEN_BY_LENDER, MAPPED_BY_TREASURY |
| LenderReasons | NVARCHAR(2000) | نعم |  |  | ما ذكره البنك من أسباب |
| SourceDocumentId | BIGINT | نعم |  | doc.Document |  |
| SourcePage | VARCHAR(40) | نعم |  |  |  |
| ReadFromScan | BIT | لا | 0 |  |  |
| OriginalText | NVARCHAR(2000) | نعم |  |  | 🔒 confidential |
| NoSourceReason | NVARCHAR(300) | نعم |  |  |  |
| Confidence | VARCHAR(26) | لا | ENTERED_NO_DOCUMENT |  | enum: CONFIRMED_AGAINST_ORIGINAL, READ_FROM_SCAN_UNVERIFIED, ENTERED_NO_DOCUMENT |
| VerifiedBy | BIGINT | نعم |  | sec.AppUser |  |
| VerifiedOn | DATETIME2(3) | نعم |  |  |  |
| ConflictId | BIGINT | نعم |  | fac.ValueConflict |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LenderRatingId) · UQ(TenantId, CompanyId, LenderInstitutionId, RatingDate)

**قيود:** `MappingKind = 'GIVEN_BY_LENDER' OR LenderGradeLabel IS NOT NULL` · `SourceDocumentId IS NOT NULL AND SourcePage IS NOT NULL OR (SourceDocumentId IS NULL AND Confidence = 'ENTERED_NO_DOCUMENT')` · `Confidence <> 'CONFIRMED_AGAINST_ORIGINAL' OR (VerifiedBy IS NOT NULL AND VerifiedOn IS NOT NULL)` · `OriginalText IS NULL OR (OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%' AND OriginalText COLLATE Arabic_100_BIN2 NOT LIKE '%[A-Za-z][A-Za-z][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9] [0-9][0-9][0-9][0-9]%')` · `SourceDocumentId IS NOT NULL OR (NoSourceReason IS NOT NULL AND LEN(LTRIM(RTRIM(NoSourceReason))) > 0)`

### `fin.EarlyWarningAlert` — An early warning the job JOB-FIN-READINESS issued: a lender date of the company within the lead time that is not ready, once per stage of the time left and readiness, so a run after a stop or a second run of the day repeats nothing; written by the database only, with the notification request in the outbox, FIN.READINESS_RED or FIN.READINESS_AMBER (docs/36 F4, ADR 0027, ADR 0028)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **EarlyWarningAlertId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment | التقييم الذي قرأته المهمة: آخر تقييم محسوب لقائمة فعلية |
| EventKind | VARCHAR(13) | لا |  |  | enum: RENEWAL, COVENANT_TEST, REPORTING |
| RefId | BIGINT | لا |  |  | التسهيل أو اختبار التعهد أو موعد التقرير |
| EventDate | DATE | لا |  |  | موعد جهة التمويل وقت الإنذار: تغيّره يعيد الإنذارات من أولها |
| Stage | VARCHAR(10) | لا |  |  | ما بقي من الوقت: داخل مهلة الإعداد، ثم 90 و30 و7 أيام enum: LEAD, D90, D30, D7 |
| Readiness | VARCHAR(10) | لا |  |  | enum: AMBER, RED |
| ReasonCode | VARCHAR(30) | لا |  |  | أول قاعدة حددت الجاهزية (049)، ونصها في رسالة الإنذار (ADR 0028) |
| IssuedOn | DATE | لا |  |  | يوم التشغيل بتوقيت المشترك |
| MessageId | UNIQUEIDENTIFIER | لا |  |  | صف طلب الإشعار في cfg.OutboxEvent |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(EarlyWarningAlertId) · UQ(TenantId, CompanyId, EventKind, RefId, EventDate, Stage, Readiness) · UQ(TenantId, MessageId)

### `fin.AssessmentEvidencePack` — A sealed evidence pack of an endorsed assessment, built for an auditor or a lender: the assessment, its statement versions and lines, findings, reconciliation, calibration and audit rows in one JSON document whose SHA-256 is kept here; the same content gives the same hash (ADR 0030)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **AssessmentEvidencePackId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| Purpose | NVARCHAR(500) | لا |  |  | لمن ولأي غرض: المدقق الخارجي لسنة 2025، أو البنك لتجديد 2026 |
| Sha256 | VARBINARY(32) | لا |  |  | بصمة نص JSON بترميز UTF-16LE كما تعيده القاعدة |
| ContentChars | INT | لا |  |  |  |
| GeneratedBy | BIGINT | لا |  | sec.AppUser |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(AssessmentEvidencePackId)

**قيود:** `ContentChars > 0`

### `fin.ReceivableLossRate` — The loss rate of a receivables ageing bucket for the provision matrix the company compares its recorded allowance with (a provision matrix in the manner of the simplified approach for trade receivables, a check of the allowance and not a measurement under IFRS 9; owner decision 35, ADR 0030); the defaults of the pack FIN.PROVISION are for the treasury to approve or change

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReceivableLossRateId** | INT IDENTITY | لا | | | مفتاح أساسي |
| BucketCode | VARCHAR(19) | لا |  |  | enum: AR_AGE_0_90, AR_AGE_91_180, AR_AGE_181_365, AR_AGE_OVER_365, AR_AGE_OVER_365_GOV |
| LossRatePct | DECIMAL(7,4) | لا |  |  |  |
| EffectiveFrom | DATE | لا |  |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, APPROVED |
| PreparedBy | BIGINT | نعم |  | sec.AppUser | من كتب المسودة أو غيّرها؛ فارغ لافتراضي الحزمة FIN.PROVISION (058، ADR 0037) |
| ApprovedBy | BIGINT | نعم |  | sec.AppUser |  |
| ApprovedOn | DATETIME2(3) | نعم |  |  |  |
| Note | NVARCHAR(500) | نعم |  |  |  |
| SeedKey | VARCHAR(80) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReceivableLossRateId) · UQ(TenantId, BucketCode, EffectiveFrom) · UQ(TenantId, SeedKey) WHERE SeedKey IS NOT NULL

**قيود:** `LossRatePct >= 0 AND LossRatePct <= 100` · `(Status = 'DRAFT' AND ApprovedBy IS NULL AND ApprovedOn IS NULL) OR (Status = 'APPROVED' AND ApprovedBy IS NOT NULL AND ApprovedOn IS NOT NULL)` · `ApprovedBy IS NULL OR PreparedBy IS NULL OR ApprovedBy <> PreparedBy` · `PreparedBy IS NOT NULL OR SeedKey IS NOT NULL`

### `fin.ReportingPeriodLock` — The close of a company's reporting periods: through LockedThrough no actual statement, version, monthly balance or bank flow of the company is added, changed or removed; locked once its figures are approved or confirmed, reopened with a reason by someone other than the one who locked it (optional for each company; docs/38 item 2, ADR 0031)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **ReportingPeriodLockId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| LockedThrough | DATE | لا |  |  | نهاية آخر فترة مقفلة: كل ما تاريخه حتى هذا اليوم مقفل |
| Status | VARCHAR(10) | لا | LOCKED |  | enum: LOCKED, REOPENED |
| LockReason | NVARCHAR(500) | لا |  |  | مثل: إقفال سنة 2025 بعد اعتماد القوائم المدققة |
| LockedBy | BIGINT | لا |  | sec.AppUser |  |
| LockedOn | DATETIME2(3) | لا |  |  |  |
| ReopenedBy | BIGINT | نعم |  | sec.AppUser |  |
| ReopenedOn | DATETIME2(3) | نعم |  |  |  |
| ReopenReason | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(ReportingPeriodLockId) · UQ(TenantId, CompanyId, LockedThrough) WHERE Status = 'LOCKED'

**قيود:** `(Status = 'LOCKED' AND ReopenedBy IS NULL AND ReopenedOn IS NULL AND ReopenReason IS NULL) OR (Status = 'REOPENED' AND ReopenedBy IS NOT NULL AND ReopenedOn IS NOT NULL AND ReopenReason IS NOT NULL)` · `ReopenedBy IS NULL OR ReopenedBy <> LockedBy` · `ReopenedOn IS NULL OR ReopenedOn >= LockedOn`

### `fin.PresentationVersion` — An alternative presentation of a company's statement before its final approval: the remedies the company chose, applied in order to the statement and kept balanced, written as a new draft statement with a trial assessment to compare; chosen by someone other than its preparer, and only when every step rests on a document dated by the period end (docs/36 F2, ADR 0023)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PresentationVersionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| SourceStatementId | BIGINT | لا |  | fin.FinancialStatement |  |
| SourceAssessmentId | BIGINT | نعم |  | fin.CreditAssessment | التقييم الذي يُقارن به ومنه تُنسخ مدخلات التقييم التجريبي |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| Note | NVARCHAR(1000) | نعم |  |  |  |
| Status | VARCHAR(10) | لا | DRAFT |  | enum: DRAFT, BUILT, CHOSEN, DISCARDED |
| ResultStatementId | BIGINT | نعم |  | fin.FinancialStatement | القائمة المسودة التي يكتبها البناء |
| TrialAssessmentId | BIGINT | نعم |  | fin.CreditAssessment | التقييم التجريبي للقائمة الناتجة |
| IsConvertible | BIT | نعم |  |  | كل خطوة بمستند مؤرخ في نهاية الفترة أو قبلها |
| BalanceGap | DECIMAL(19,4) | نعم |  |  | فرق التوازن بعد الخطوات (صفر) |
| BuiltAt | DATETIME2(3) | نعم |  |  |  |
| PreparedBy | BIGINT | لا |  | sec.AppUser |  |
| ChosenBy | BIGINT | نعم |  | sec.AppUser |  |
| ChosenOn | DATETIME2(3) | نعم |  |  |  |
| ChoiceReason | NVARCHAR(1000) | نعم |  |  | لماذا اختيرت هذه النسخة (إلزامي عند الاختيار، ADR 0029) |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PresentationVersionId) · UQ(PublicId) · UQ(TenantId, ResultStatementId) WHERE ResultStatementId IS NOT NULL

**قيود:** `Status IN ('DRAFT','DISCARDED') OR (ResultStatementId IS NOT NULL AND BuiltAt IS NOT NULL AND IsConvertible IS NOT NULL)` · `Status <> 'CHOSEN' OR (ChosenBy IS NOT NULL AND ChosenOn IS NOT NULL AND IsConvertible = 1 AND ChoiceReason IS NOT NULL)` · `ChoiceReason IS NULL OR ChosenBy IS NOT NULL` · `ChosenBy IS NULL OR ChosenBy <> PreparedBy`

### `fin.PresentationVersionStep` — A remedy of the methodology the company chose for a presentation version, in order, with the document that supports it; the amount it moved is written by the build (docs/36 F2, ADR 0023)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **PresentationVersionStepId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| VersionId | BIGINT | لا |  | fin.PresentationVersion |  |
| StepNo | INT | لا |  |  |  |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| ScalePct | DECIMAL(9,4) | لا | 100 |  | نسبة ما يُنفذ من الحل |
| DocumentId | BIGINT | نعم |  | doc.Document | القرار أو العقد أو الاتفاق الذي يسند الخطوة |
| EvidenceDate | DATE | نعم |  |  | تاريخ المستند |
| Justification | NVARCHAR(1000) | لا |  |  |  |
| MovedAmount | DECIMAL(19,4) | نعم |  |  | ما نقلته الخطوة؛ يكتبه البناء |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(PresentationVersionStepId) · UQ(TenantId, VersionId, StepNo) · UQ(TenantId, VersionId, RemedyId)

**قيود:** `ScalePct > 0 AND ScalePct <= 100` · `(DocumentId IS NULL AND EvidenceDate IS NULL) OR (DocumentId IS NOT NULL AND EvidenceDate IS NOT NULL)` · `StepNo >= 1`

### `fin.CreditAssessmentReclass` — A row of the reconciliation of the analytical statement: a standard adjustment that moved an amount of a reported line to an analytical bucket; written by fin.usp_ComputeCreditAssessment only (docs/35 section 6)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentReclassId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| SeqNo | INT | لا |  |  |  |
| AdjCode | VARCHAR(30) | لا |  |  | ADJ_LEASE, ADJ_EOSB, ADJ_SHL_SUB ... |
| LineCode | VARCHAR(40) | لا |  |  |  |
| Bucket | VARCHAR(11) | لا |  |  | enum: DEBT, ST_DEBT, EQUITY, NOT_CASH, NOT_TNW, NON_CURRENT, EBITDA, INTEREST |
| Amount | DECIMAL(19,4) | لا |  |  |  |
| TextAr | NVARCHAR(500) | لا |  |  |  |
| TextEn | NVARCHAR(500) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentReclassId) · UQ(TenantId, AssessmentId, SeqNo)

**قيود:** `SeqNo >= 1`

### `fin.CreditAssessmentFacility` — A facility of the company read from the platform on the assessment date: its limit, outstanding, lender, commitment, expiry and collateral cover, in the statement currency; written by fin.usp_ComputeCreditAssessment only (docs/35 section 10)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentFacilityId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| FacilityId | BIGINT | لا |  | fac.Facility |  |
| LenderInstitutionId | BIGINT | نعم |  | ins.Institution | المقرض صاحب الحصة الأكبر |
| CurrencyId | INT | لا |  | ref.Currency |  |
| RateToStatement | DECIMAL(19,8) | نعم |  |  |  |
| LimitAmount | DECIMAL(19,4) | لا |  |  | بعملة التسهيل |
| OutstandingAmount | DECIMAL(19,4) | لا |  |  |  |
| SecuredCover | DECIMAL(19,4) | لا | 0 |  | تغطية الضمانات المرتبطة بعملة التسهيل |
| RecoverableCover | DECIMAL(19,4) | لا | 0 |  | بعد خصومات أنواع الضمانات |
| IsCommitted | BIT | لا | 0 |  |  |
| ExpiryDate | DATE | لا |  |  |  |
| IsIncluded | BIT | لا |  |  | يُستبعد التسهيل بعملة لا سعر لها |
| ExclusionReason | NVARCHAR(300) | نعم |  |  |  |
| LenderDecisionId | BIGINT | نعم |  | fac.FacilityLenderDecision | قرار البنك الفعلي النافذ في تاريخ التقييم، إن وُجد |
| LimitAction | VARCHAR(15) | نعم |  |  | enum: MAINTAINED, UNDRAWN_STOPPED, LIMIT_REDUCED, NOT_RENEWED |
| DecidedLimitAmount | DECIMAL(19,4) | نعم |  |  | الحد بعد قرار البنك، بعملة التسهيل |
| LenderCostChangeBp | INT | نعم |  |  | تغيّر الهامش والرسوم معًا |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentFacilityId) · UQ(TenantId, AssessmentId, FacilityId)

**قيود:** `IsIncluded = 1 OR ExclusionReason IS NOT NULL`

### `fin.CreditAssessmentRemedy` — A remedy the report proposes, with the finding it answers and the grade the pro-forma statement would get; written by fin.usp_ComputeCreditAssessment only (docs/35 section 12)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentRemedyId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| SeqNo | INT | لا |  |  |  |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| TriggerCode | VARCHAR(40) | لا |  |  |  |
| TriggerLevel | VARCHAR(10) | لا |  |  | enum: MODERATE, ELEVATED, HIGH, CRITICAL, ADJUSTMENT |
| MovedAmount | DECIMAL(19,4) | نعم |  |  | ما نقلته خطوات الحل |
| ProFormaScore | DECIMAL(9,4) | نعم |  |  |  |
| ProFormaGradeId | INT | نعم |  | fin.RatingGrade |  |
| NotchesGained | INT | نعم |  |  | درجات الرتبة التي يكسبها الحل |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentRemedyId) · UQ(TenantId, AssessmentId, SeqNo) · UQ(TenantId, AssessmentId, RemedyId)

**قيود:** `SeqNo >= 1` · `(ProFormaGradeId IS NULL AND NotchesGained IS NULL) OR (ProFormaGradeId IS NOT NULL AND NotchesGained IS NOT NULL)`

### `fin.CompanyProductLine` — A product or service line of a company for a fiscal year: its category, share of revenue and of inventory, and its sales channels; read by the credit assessment for the quality of cash flows and the liquidity of the inventory (docs/35 section 5)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CompanyProductLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company |  |
| FiscalYear | INT | لا |  |  |  |
| NameAr | NVARCHAR(200) | لا |  |  |  |
| ProductCategoryId | INT | لا |  | fin.ProductCategory |  |
| RevenueSharePct | DECIMAL(9,4) | لا |  |  |  |
| InventorySharePct | DECIMAL(9,4) | لا | 0 |  |  |
| CashSalesPct | DECIMAL(9,4) | لا | 0 |  |  |
| GovernmentSalesPct | DECIMAL(9,4) | لا | 0 |  |  |
| ExportSalesPct | DECIMAL(9,4) | لا | 0 |  |  |
| TypicalCreditDays | INT | لا | 0 |  |  |
| PublicId | UNIQUEIDENTIFIER | لا | NEWSEQUENTIALID() |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CompanyProductLineId) · UQ(PublicId)

**قيود:** `RevenueSharePct BETWEEN 0 AND 100 AND InventorySharePct BETWEEN 0 AND 100` · `CashSalesPct + GovernmentSalesPct + ExportSalesPct <= 100 AND CashSalesPct >= 0 AND GovernmentSalesPct >= 0 AND ExportSalesPct >= 0` · `TypicalCreditDays BETWEEN 0 AND 720` · `FiscalYear BETWEEN 1900 AND 2200`

### `fin.CreditAssessmentBureau` — The company's SIMAH commercial credit report the analyst read: exposure at all lenders, payment behaviour, defaults, bounced cheques, judgments (docs/35 section 10); changes only while the assessment is a draft

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentBureauId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| ReportDate | DATE | لا |  |  |  |
| DocumentId | BIGINT | لا |  | doc.Document |  |
| TotalLimits | DECIMAL(19,4) | لا |  |  | بعملة القائمة |
| TotalOutstanding | DECIMAL(19,4) | لا |  |  |  |
| LenderCount | INT | لا |  |  |  |
| WorstDpd12m | INT | لا | 0 |  | أسوأ أيام تأخر في 12 شهرًا |
| WorstDpd24m | INT | لا | 0 |  |  |
| CurrentDefault | BIT | لا | 0 |  | تعثر قائم أو حساب مشطوب غير مسوّى |
| Defaults24mCount | INT | لا | 0 |  |  |
| Defaults24mAmount | DECIMAL(19,4) | لا | 0 |  |  |
| BouncedCheques12mCount | INT | لا | 0 |  |  |
| BouncedCheques12mAmount | DECIMAL(19,4) | لا | 0 |  |  |
| JudgmentsCount | INT | لا | 0 |  |  |
| JudgmentsAmount | DECIMAL(19,4) | لا | 0 |  |  |
| Inquiries6m | INT | لا | 0 |  |  |
| Restructured | BIT | لا | 0 |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentBureauId) · UQ(TenantId, AssessmentId)

**قيود:** `TotalLimits >= 0 AND TotalOutstanding >= 0 AND LenderCount >= 0` · `WorstDpd12m >= 0 AND WorstDpd24m >= WorstDpd12m` · `Defaults24mCount >= 0 AND Defaults24mAmount >= 0 AND BouncedCheques12mCount >= 0 AND BouncedCheques12mAmount >= 0 AND JudgmentsCount >= 0 AND JudgmentsAmount >= 0 AND Inquiries6m >= 0`

### `fin.CreditAssessmentScenario` — The assessment recomputed on the statement under each macro scenario, with the stress applied: the grade, the liquidity label and the notches lost; written by fin.usp_ComputeCreditAssessment only (docs/35 section 13)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentScenarioId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| MacroScenarioId | INT | لا |  | fin.MacroScenario |  |
| RevenuePct | DECIMAL(9,4) | نعم |  |  | الضغط الذي طُبّق: من شدة المحركات وحساسية النشاط وتعرض البلد والمنطقة |
| GrossMarginPp | DECIMAL(9,4) | نعم |  |  |  |
| DsoDays | DECIMAL(9,2) | نعم |  |  |  |
| StLinesWithdrawnPct | DECIMAL(9,4) | نعم |  |  |  |
| RateBp | INT | نعم |  |  |  |
| PrivateArLossPct | DECIMAL(9,4) | نعم |  |  |  |
| InventoryWritedownPct | DECIMAL(9,4) | نعم |  |  |  |
| UndrawnAvailablePct | DECIMAL(9,4) | نعم |  |  |  |
| LenderCostBp | DECIMAL(9,2) | نعم |  |  | هامش البنك ورسومه على التسهيلات قصيرة الأجل بعد عامل البنك |
| CountryMult | DECIMAL(5,3) | نعم |  |  |  |
| RevenueAfter | DECIMAL(19,4) | نعم |  |  |  |
| EbitdaAfter | DECIMAL(19,4) | نعم |  |  |  |
| InventoryValueAfter | DECIMAL(19,4) | نعم |  |  |  |
| Score | DECIMAL(9,4) | نعم |  |  |  |
| GradeId | INT | نعم |  | fin.RatingGrade |  |
| LiquidityLabel | VARCHAR(5) | نعم |  |  |  |
| NotchesLost | INT | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentScenarioId) · UQ(TenantId, AssessmentId, MacroScenarioId)

### `fin.CreditAssessmentPlan` — A strengthening plan computed for the assessment when the customer asked for one: the grade at its end and whether the balance sheet stayed balanced; written by fin.usp_ComputeCreditAssessment only (docs/35 section 12)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentPlanId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| PlanId | INT | لا |  | fin.StrengtheningPlan |  |
| StepCount | INT | لا |  |  |  |
| FinalScore | DECIMAL(9,4) | لا |  |  |  |
| FinalGradeId | INT | لا |  | fin.RatingGrade |  |
| NotchesGained | INT | لا |  |  |  |
| IsBalanced | BIT | لا |  |  | الأصول = الخصوم + حقوق الملكية بعد كل خطوة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentPlanId) · UQ(TenantId, AssessmentId, PlanId)

**قيود:** `StepCount >= 1`

### `fin.CreditAssessmentPlanStep` — A step of a strengthening plan: the remedy applied, the amount it moved and the grade after it

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentPlanStepId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| PlanId | INT | لا |  | fin.StrengtheningPlan |  |
| StepNo | INT | لا |  |  |  |
| RemedyId | INT | لا |  | fin.CreditRemedy |  |
| MovedAmount | DECIMAL(19,4) | لا |  |  |  |
| Score | DECIMAL(9,4) | لا |  |  |  |
| GradeId | INT | لا |  | fin.RatingGrade |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentPlanStepId) · UQ(TenantId, AssessmentId, PlanId, StepNo)

**قيود:** `StepNo >= 1`

### `fin.CreditAssessmentTrigger` — What would move the scorecard grade one notch: the value of a metric at which the weighted score crosses to the grade above or below, the other metrics unchanged (docs/35 section 15)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **CreditAssessmentTriggerId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| AssessmentId | BIGINT | لا |  | fin.CreditAssessment |  |
| MetricId | INT | لا |  | fin.CreditMetric |  |
| Direction | VARCHAR(10) | لا |  |  | enum: UP, DOWN |
| CurrentValue | DECIMAL(19,6) | لا |  |  |  |
| TriggerValue | DECIMAL(19,6) | لا |  |  |  |
| Score | DECIMAL(9,4) | لا |  |  |  |
| TargetScore | DECIMAL(9,4) | لا |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(CreditAssessmentTriggerId) · UQ(TenantId, AssessmentId, MetricId, Direction)

## REQ

### `wfl.RequestType` — Request type definition (FR-REQ-001, BR-REQ-001, V-REQ-01); new types need no code (FR-REQ-021); its template is the current WorkflowTemplate of the type and its index fields the IndexRole fields of that template (DR-49)

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
| NumberSequenceKey | VARCHAR(50) | لا |  |  | = req:<Code> (قيد أدناه) يقابل cfg.NumberSequenceDefinition.SequenceKey، فيخضع لقاعدة الترقيم بلا فجوات (BR-WFL-013، X-DAT-8، DR-49) |
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

**قيود:** `Category <> 'CHILD' OR ParentEntityType IS NOT NULL` · `ConsumesCreditLimit = 1 OR LimitCheckMode = 'NONE'` · `NumberSequenceKey = CONCAT('req:', Code)`

### `wfl.RequestTypeAudience` — Audience of a request type: who may raise it; no rows = nobody (fail closed) (FR-REQ-007)

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

### `wfl.TemplateField` — Changes only while its template version is a draft (044, DR-41). Field in a template version; the form UI is generated without code (FR-REQ-002..005, BR-REQ-003/004)

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

### `wfl.TemplateAttachmentRule` — Changes only while its template version is a draft (044, DR-41). Attachment rule on a template version (FR-REQ-006, BR-REQ-005, FR-WFL-024/025)

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

### `wfl.Request` — Request: the most heavily used table; the internal status is kept separate from the visible phase (FR-WFL-001, FR-REQ-009, D-6, BR-REQ-002/003)

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
| Status | VARCHAR(14) | لا | DRAFT |  | §8؛ AWAITING_CLOSE: انتهت المراحل بنجاح وتنتظر إقفال إدارة الخزينة؛ COMPLETED لا يُبلَغ إلا بإقفالها (BR-WFL-027) enum: DRAFT, ACTIVE, AWAITING_CLOSE, COMPLETED, REJECTED, CANCELLED |
| CurrentStageId | INT | نعم |  | wfl.WorkflowStage (via TemplateId) | نسخة تكتبها القاعدة من مثيل المرحلة الحالي (044، DR-44)؛ إضافة: المرحلة الحالية مخبأة للفهارس ولوحات الطابور؛ تتبع القالب الملتقَط نفسه |
| CurrentStageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance (via RequestId) | مثيل المرحلة الحالي، من الطلب نفسه بمفتاح مركّب (DR-44)؛ كتابته تنسخ المرحلة والإسناد والمهلة |
| ExternalPhaseId | INT | لا |  | wfl.ExternalPhase | المرحلة الظاهرة للطالب (BR-WFL-011) |
| SubStatusKey | VARCHAR(40) | نعم |  |  | الحالة الفرعية الداخلية؛ لا يراها الطالب (FR-WFL-015) |
| AssigneeUserId | BIGINT | نعم |  | sec.AppUser | المُسنَد؛ فارغ في الطابور (BR-WFL-005/007)؛ هذه الخمسة نسخ من مثيل المرحلة الحالي تكتبها القاعدة وحدها (044، DR-44) |
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
| ReadyToCloseAt | DATETIME2(3) | نعم |  |  | وقت انتهاء المرحلة الأخيرة الناجحة (دخول AWAITING_CLOSE؛ BR-WFL-027) |
| ClosedByUserId | BIGINT | نعم |  | sec.AppUser | مدير الخزينة الذي أقفل الدورة؛ إلزامي عند COMPLETED (BR-WFL-027، صلاحية req.treasury.close) |
| ClosedAt | DATETIME2(3) | نعم |  |  | وقت الإقفال؛ يساوي CompletedAt عند COMPLETED |
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
| LcId | BIGINT | نعم |  | lc.LetterOfCredit (via CompanyId) | DR-10: الاعتماد من شركة الطلب نفسها |
| FacilityId | BIGINT | نعم |  | fac.Facility | التخصيص (AllocFacilityId في المواصفة): اختيار الخزينة في FACILITY_SELECTION |
| LimitId | BIGINT | نعم |  | fac.Limit (via FacilityId) | AllocLimitId؛ الحد من التسهيل نفسه |
| LimitProductLineId | BIGINT | نعم |  | fac.LimitProductLine (via FacilityId,LimitId) | AllocProductLineId (LineId في fac.reserve_limit) |
| InstitutionId | BIGINT | نعم |  | ins.Institution | AllocInstitutionId |
| ExecutionChannel | VARCHAR(18) | نعم |  |  | تقترحه 11 SVC-02 ويعدّله المنفّذ (FR-WFL-027) enum: BANK_PORTAL, MANUAL_FORM, DIRECT_INTEGRATION |
| ReservationId | BIGINT | نعم |  | fac.LimitReservation (via RequestId) | آخر حجز لهذا الطلب نفسه (DR-44)؛ والثلاثة نسخ من fac.LimitReservation تكتبها القاعدة وحدها (044) |
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

**قيود:** `(RequestNo IS NULL AND NumberYear IS NULL AND NumberSeq IS NULL) OR (RequestNo IS NOT NULL AND NumberYear IS NOT NULL AND NumberSeq IS NOT NULL)` · `DraftRef LIKE 'D-%'` · `Status NOT IN ('ACTIVE','AWAITING_CLOSE','COMPLETED','REJECTED') OR SubmittedAt IS NOT NULL` · `(Status IN ('DRAFT','ACTIVE','AWAITING_CLOSE') AND CompletedAt IS NULL) OR (Status IN ('COMPLETED','REJECTED','CANCELLED') AND CompletedAt IS NOT NULL)` · `CompletedAt IS NULL OR SubmittedAt IS NULL OR CompletedAt >= SubmittedAt` · `Status <> 'ACTIVE' OR CurrentStageInstanceId IS NOT NULL` · `Status <> 'COMPLETED' OR RequestNo IS NOT NULL` · `ArchivedAt IS NULL OR Status = 'DRAFT'` · `Status <> 'AWAITING_CLOSE' OR (ReadyToCloseAt IS NOT NULL AND CurrentStageInstanceId IS NOT NULL)` · `ReadyToCloseAt IS NULL OR Status IN ('AWAITING_CLOSE','COMPLETED')` · `Status <> 'COMPLETED' OR (ClosedByUserId IS NOT NULL AND ClosedAt IS NOT NULL AND ClosedAt = CompletedAt)` · `ClosedByUserId IS NULL OR Status = 'COMPLETED'` · `Priority <> 'URGENT' OR UrgentReason IS NOT NULL` · `CycleNo >= 1` · `Amount IS NULL OR CurrencyId IS NOT NULL` · `SlaState NOT IN ('ON_TRACK','AT_RISK','OVERDUE') OR DueAt IS NOT NULL` · `(ReservationState = 'NONE' AND ReservationId IS NULL AND ReservedAmount IS NULL) OR (ReservationState <> 'NONE' AND ReservationId IS NOT NULL AND ReservedAmount IS NOT NULL)` · `ReservedAmount IS NULL OR (ReservedAmount > 0 AND CurrencyId IS NOT NULL)` · `LimitId IS NULL OR FacilityId IS NOT NULL` · `LimitProductLineId IS NULL OR LimitId IS NOT NULL` · `(ParentEntityType IS NULL AND ParentEntityId IS NULL) OR (ParentEntityType IS NOT NULL AND ParentEntityId IS NOT NULL)` · `ParentRequestId IS NULL OR ParentRequestId <> RequestId` · `CopiedFromRequestId IS NULL OR CopiedFromRequestId <> RequestId` · `Status <> 'REJECTED' OR OutcomeReason IS NOT NULL`

### `wfl.RequestComment` — Comment visible to the requester or internal; the application prevents editing it, and withdrawal keeps the original (FR-REQ-017, BR-REQ-014)

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

### `wfl.RequestAttachment` — Links a document to a request and creates a DocumentLink (EntityType = Request) (FR-REQ-006, BR-REQ-005)

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

### `wfl.RequestExternalRef` — External reference as free text; edits replace the value and keep the history; no external validation (FR-REQ-010, X-DAT-7, BR-REQ-006)

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

### `wfl.ExternalPhase` — Phase shown to the requester: DRAFT, IN_APPROVAL, RETURNED, AWAITING_REQUESTER, IN_PROGRESS, COMPLETED, REJECTED, CANCELLED (BR-WFL-011, D-6)

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

### `wfl.WorkflowTemplate` — Workflow template version; a published version is immutable and its parts change only while it is a draft (044, DR-41) (FR-WFL-001/028, BR-WFL-019, AC-WFL-6)

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

**المفاتيح:** PK(WorkflowTemplateId) · UQ(PublicId) · UQ(TenantId, TemplateKey, VersionNo) · UQ(TenantId, TemplateKey) WHERE IsCurrent = 1 · UQ(TenantId, RequestTypeId) WHERE IsCurrent = 1 · UQ(TenantId, RequestTypeId, SeedKey, SourceSeedVersion) WHERE SeedKey IS NOT NULL

**قيود:** `VersionNo >= 1` · `IsCurrent = 0 OR Status = 'PUBLISHED'` · `Status <> 'PUBLISHED' OR PublishedAt IS NOT NULL` · `Status <> 'DRAFT' OR PublishedAt IS NULL` · `(PublishedAt IS NULL AND PublishedBy IS NULL) OR (PublishedAt IS NOT NULL AND PublishedBy IS NOT NULL)` · `(Status = 'RETIRED' AND RetiredAt IS NOT NULL) OR (Status <> 'RETIRED' AND RetiredAt IS NULL)` · `IsTenantModified = 0 OR SeedKey IS NULL` · `SeedKey IS NULL OR SourceSeedVersion IS NOT NULL` · `NameAr IS NOT NULL OR NameEn IS NOT NULL`

### `wfl.WorkflowStage` — Changes only while its template version is a draft (044, DR-41). Stage in a template version (FR-WFL-003/004/005, BR-WFL-002/010/012); physical delete only for a draft version

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

### `wfl.StageApprover` — Changes only while its template version is a draft (044, DR-41). Approval slot in an APPROVAL stage; ALL = every slot, and a role requiring two people together = two slots (FR-WFL-007/041, BR-WFL-003/004)

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

### `wfl.WorkflowTransition` — Changes only while its template version is a draft (044, DR-41). Transition between two stages with a condition and a priority; a linear flow with simple conditional branching (FR-WFL-006, BR-WFL-001, D-8)

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
| ConditionJson | NVARCHAR(MAX) | نعم |  |  | تعبير مقيَّد بلا كود؛ الفارغ = دائمًا (FR-REQ-004) |
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

### `wfl.WorkflowStageHook` — Changes only while its template version is a draft (044, DR-41). Hook registered on a stage: a key and parameters, no code (FR-WFL-021, BR-WFL-015, section 5.4)

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

### `wfl.RequestStageInstance` — Entry of a request into a stage; source of the cycle-time, withdrawal and SLA metrics (BR-WFL-002/007/012, section 8)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestStageInstanceId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| TemplateId | INT | لا |  | wfl.WorkflowTemplate | قالب الطلب المُثبَّت عند الدخول (DR-09) |
| StageId | INT | لا |  | wfl.WorkflowStage (via TemplateId) | مرحلة من القالب نفسه (DR-09) |
| CycleNo | INT | لا | 1 |  |  |
| Status | VARCHAR(17) | لا |  |  | §8: مثيل المرحلة (المهمة المسندة مباشرة تُعدّ CLAIMED) enum: QUEUED, CLAIMED, AWAITING_APPROVAL, DONE, RETURNED, REJECTED, CANCELLED |
| EnteredAt | DATETIME2(3) | لا |  |  |  |
| QueuedAt | DATETIME2(3) | نعم |  |  |  |
| ClaimedAt | DATETIME2(3) | نعم |  |  |  |
| ExitedAt | DATETIME2(3) | نعم |  |  |  |
| ExitAction | VARCHAR(10) | نعم |  |  | الإجراء الذي أنهى المرحلة؛ CLOSE يُغلق المثيل النهائي عند إقفال الخزينة (BR-WFL-027، DQ-F08-6) enum: SUBMIT, APPROVE, COMPLETE, RETURN, REJECT, CANCEL, RESUBMIT, CLOSE |
| AssigneeUserId | BIGINT | نعم |  | sec.AppUser |  |
| DueAt | DATETIME2(3) | نعم |  |  |  |
| ClaimDueAt | DATETIME2(3) | نعم |  |  | مهلة السحب (ClaimSlaHours) من QueuedAt (BR-WFL-012) |
| SlaPausedSeconds | INT | لا | 0 |  | مجموع الإيقاف في حالات PausesSla (BR-WFL-010) |
| SlaState | VARCHAR(10) | لا | NONE |  | enum: ON_TRACK, AT_RISK, OVERDUE, PAUSED, NONE |
| SlaMet | BIT | نعم |  |  | نتيجة SLA عند الخروج: 1 قبل DueAt · 0 بعده · فارغ بلا SLA (§8، R-WFL-01) |
| ReleaseCount | INT | لا | 0 |  | التحرير لا يصفّر قِدَم الطابور (BR-WFL-007) |
| ReassignCount | INT | لا | 0 |  |  |
| ResumeStageId | INT | نعم |  | wfl.WorkflowStage (via TemplateId) |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(RequestStageInstanceId) · UQ(TenantId, RequestId) WHERE ExitedAt IS NULL

**قيود:** `(ExitedAt IS NULL AND ExitAction IS NULL AND Status IN ('QUEUED','CLAIMED','AWAITING_APPROVAL')) OR (ExitedAt IS NOT NULL AND ExitAction IS NOT NULL AND Status IN ('DONE','RETURNED','REJECTED','CANCELLED'))` · `Status <> 'RETURNED' OR ExitAction = 'RETURN'` · `Status <> 'REJECTED' OR ExitAction = 'REJECT'` · `Status <> 'CANCELLED' OR ExitAction = 'CANCEL'` · `ExitAction IS NULL OR ExitAction <> 'CLOSE' OR Status = 'DONE'` · `Status <> 'QUEUED' OR AssigneeUserId IS NULL` · `Status <> 'CLAIMED' OR AssigneeUserId IS NOT NULL` · `ClaimedAt IS NULL OR QueuedAt IS NOT NULL` · `ExitedAt IS NULL OR ExitedAt >= EnteredAt` · `QueuedAt IS NULL OR QueuedAt >= EnteredAt` · `ClaimedAt IS NULL OR QueuedAt IS NULL OR ClaimedAt >= QueuedAt` · `SlaPausedSeconds >= 0 AND ReleaseCount >= 0 AND ReassignCount >= 0` · `CycleNo >= 1`

### `wfl.RequestApproval` — Approval slot created per entry and cycle; a new cycle creates new slots (BR-WFL-003, FR-WFL-007/008/011)

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

**قيود:** `(Decision = 'PENDING' AND ActedAt IS NULL) OR (Decision <> 'PENDING' AND ActedAt IS NOT NULL)` · `AssignedUserId IS NOT NULL OR AssignedRoleId IS NOT NULL` · `Decision NOT IN ('APPROVED','RETURNED','REJECTED') OR ActedByUserId IS NOT NULL` · `Decision <> 'APPROVED' OR SnapshotHash IS NOT NULL` · `Source <> 'DELEGATE' OR (DelegationId IS NOT NULL AND OnBehalfOfUserId IS NOT NULL)` · `(OnBehalfOfUserId IS NULL AND DelegationId IS NULL) OR (Source IS NOT NULL AND Source = 'DELEGATE')` · `OverrideRequested = 0 OR OverrideReason IS NOT NULL` · `CycleNo >= 1`

### `wfl.RequestAction` — Append-only action log covering every event; separate from the security audit log (FR-WFL-033/034, section 6.2)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **RequestActionId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| RequestId | BIGINT | لا |  | wfl.Request |  |
| StageInstanceId | BIGINT | نعم |  | wfl.RequestStageInstance (via RequestId) |  |
| CycleNo | INT | نعم |  |  |  |
| ActionType | VARCHAR(18) | لا |  |  | enum: CREATED, SUBMITTED, RESUBMITTED, NUMBER_ASSIGNED, FIELD_EDITED, APPROVED, RETURNED, REJECTED, CANCELLED, STAGE_CHANGED, SUBSTATUS_CHANGED, CLAIMED, RELEASED, REASSIGNED, COMMENT_ADDED, ATTACHMENT_ADDED, ATTACHMENT_REMOVED, EXTREF_ADDED, EXTREF_CHANGED, HOOK_EXECUTED, HOOK_FAILED, SLA_AT_RISK, SLA_BREACHED, ESCALATED, DELEGATED_ACTION, CHILD_CREATED, PRIORITY_CHANGED, TEMPLATE_MIGRATED, RESERVATION_LOST, DRAFT_ARCHIVED, DRAFT_RESTORED, CHANNEL_CHANGED, SOD_EXCEPTION_USED, DELEGATION_CREATED, DELEGATION_REVOKED, READY_TO_CLOSE, CLOSED |
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

### `wfl.HookExecution` — Execution of a hook with an idempotency key; a repeat returns the stored result (FR-WFL-021, BR-WFL-015) -- جدول جديد

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

**المفاتيح:** PK(HookExecutionId) · UQ(TenantId, RequestId, StageInstanceId, HookKey, TriggerKind, ActionFilter)

**قيود:** `AttemptCount >= 0` · `(TriggerKind = 'ON_ACTION' AND ActionFilter IS NOT NULL) OR (TriggerKind <> 'ON_ACTION' AND ActionFilter IS NULL)` · `Status <> 'SUCCEEDED' OR ExecutedAt IS NOT NULL` · `Status <> 'GAVE_UP' OR (ExecMode = 'AFTER_COMMIT' AND AttemptCount >= 5)`

### `wfl.UserDelegation` — Task delegation with a period and scope; no chained delegation (FR-WFL-020, BR-WFL-021, V-WFL-06)

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

### `ntf.NotificationEventType` — Event catalogue: specification 13 owns it for all modules, and modules seed their events into it (FR-NTF-001, section 9.2)

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

### `ntf.NotificationRule` — Recipient rule for an event; changes apply to subsequent events only (FR-NTF-003, BR-NTF-001, V-NTF-02)

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

### `ntf.NotificationTemplate` — Message template per (event, channel, language); deleting it reverts to the seed template (FR-NTF-012, FR-NTF-025)

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

### `ntf.NotificationPreference` — User preference per event group and channel (FR-NTF-010, BR-NTF-003/014); mandatory notifications cannot be switched off in the application

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

### `ntf.DigestBatch` — Digest batch for a user, channel and period; never sent empty (FR-NTF-014, BR-NTF-004, JOB-NTF-DIGEST) -- جدول جديد

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

### `ntf.Notification` — Notification for a user; the content carries no restricted values (FR-NTF-005/006/007/021, BR-NTF-001/002/007/008/011)

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
| DedupKey | VARCHAR(200) | لا |  |  | {EventCode}:{TargetType}:{TargetId}:{Threshold/Cycle}:{ItemVersion} (BR-NTF-002)؛ إلزامي، والافتراضي من MessageId للحدث (DQ-F17-7، DR-50) |
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

**المفاتيح:** PK(NotificationId) · UQ(PublicId) · UQ(TenantId, UserId, DedupKey)

**قيود:** `(ActionRequired = 0 AND ActionState = 'NONE') OR (ActionRequired = 1 AND ActionState IN ('OPEN','RESOLVED'))` · `(ActionState = 'RESOLVED' AND ResolvedAt IS NOT NULL) OR (ActionState <> 'RESOLVED' AND ResolvedAt IS NULL)` · `CoalescedCount >= 1` · `ReminderCount >= 0 AND ReminderCount <= 3` · `NextReminderAt IS NULL OR ActionState = 'OPEN'`

### `ntf.NotificationDelivery` — Delivery of a notification per channel, with status and retries (FR-NTF-019, BR-NTF-009, section 8)

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

### `ref.Incoterm` — Incoterms delivery term: global reference, read-only, managed by the operator; legacy terms are displayed, not selectable (FR-LCT-013, FR-CAT-021, BR-CAT-015)

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z]%'`

### `ref.UcpArticle` — UCP 600 reference article: NULL TenantId = global read-only row, published only by the platform operator (FR-LCT-006, BR-LCT-018, BR-PLT-001)

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

### `lc.LcFieldDefinition` — Definition of a field in letter-of-credit terms: data seeded per tenant (FR-LCT-004, BR-LCT-002); UCP references are in lc.LcFieldUcpRef

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
| Sensitivity | VARCHAR(12) | لا | NORMAL |  | المقيّد لا تُنسخ قيمته في المقارنة ولا في فروق التعديل (044، DR-46، DQ-F12-11) enum: NORMAL, CONFIDENTIAL, RESTRICTED |
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

**قيود:** `FieldKey NOT LIKE '% %'` · `IsLocked = 0 OR IsActive = 1` · `ListCode IS NULL OR DataType IN ('LIST','ENUM')` · `FieldKey <> 'beneficiaryAccountIban' OR Sensitivity = 'RESTRICTED'`

### `lc.LcFieldUcpRef` — UCP reference for a field: article and paragraph (UcpRefs in specification); feeds the badge, R-LCT-01 and BR-LCT-018 -- وسيط جديد

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

### `lc.Counterparty` — Counterparty: lightweight supplier or customer without identity; promoted to Party when needed (FR-LCT-036/037, BR-LCT-022, Q-PTY-03)

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
| ErpCodeNormalized | NVARCHAR(40) | نعم |  |  | مطبَّع محسوب مخزَّن: أرقام عربية-هندية → لاتينية + حروف كبيرة + بلا فراغات (BR-REQ-006، DR-47) محسوب: `CAST(UPPER(REPLACE(TRANSLATE(ErpCode, N'٠١٢٣٤٥٦٧٨٩', N'0123456789'), N' ', N'')) AS NVARCHAR(40))` |
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

**قيود:** `ErpCode IS NULL OR LEN(ErpCode) > 0` · `MergedIntoId IS NULL OR (MergedIntoId <> CounterpartyId AND IsActive = 0)`

### `lc.LcDocumentClause` — Document-clause library with versions: template text with parameters (FR-LCT-017..019, BR-LCT-012); UCP references are in lc.LcDocumentClauseUcpRef

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

**قيود:** `Code COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9_]%'` · `VersionNo >= 1` · `DefaultOriginals IS NULL OR DefaultOriginals >= 0` · `DefaultCopies IS NULL OR DefaultCopies >= 0` · `LegalReviewStatus <> 'REVIEWED' OR (ReviewedByText IS NOT NULL AND ReviewedOn IS NOT NULL)`

### `lc.LcDocumentClauseUcpRef` — UCP 600 reference for a document clause: article and paragraph (UcpRefs in specification) -- وسيط جديد

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

### `lc.LcTerms` — Letter-of-credit terms version: one row per version, with the section 6.2 dictionary columns; shared by proforma, request, credit and amendment (FR-LCT-001..035); a locked version changes only in its treasury fields until TreasuryHash (044, DR-41)

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
| EncKeyPurpose | VARCHAR(11) | لا | DATA |  | enum: DATA |
| EncKeyId | BIGINT | نعم |  | sec.TenantKey (via EncKeyPurpose) | مفتاح DATA لـIBAN المستفيد (إصدار صريح؛ DR-02) |
| HashKeyPurpose | VARCHAR(11) | لا | BLIND_INDEX |  | enum: BLIND_INDEX |
| HashKeyId | BIGINT | نعم |  | sec.TenantKey (via HashKeyPurpose) | مفتاح BLIND_INDEX لبصمة IBAN المستفيد (DR-02) |
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
| IsTransferable | BIT | نعم |  |  | H1 (أولوية: ممكن) |
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

**قيود:** `VersionNo >= 1` · `VersionNo = 1 OR SupersedesTermsId IS NOT NULL` · `SupersedesTermsId IS NULL OR SupersedesTermsId <> LcTermsId` · `CopiedFromTermsId IS NULL OR CopiedFromTermsId <> LcTermsId` · `(Purpose = 'PROFORMA' AND OwnerType IN ('REQUEST','PROFORMA')) OR (Purpose = 'APPLICATION' AND OwnerType = 'REQUEST') OR (Purpose IN ('ISSUED','RECEIVED') AND OwnerType = 'LETTER_OF_CREDIT') OR (Purpose = 'AMENDMENT' AND OwnerType IN ('REQUEST','AMENDMENT'))` · `(Purpose NOT IN ('APPLICATION','ISSUED') OR LcClass = 'PURCHASE') AND (Purpose NOT IN ('PROFORMA','RECEIVED') OR LcClass = 'SALES')` · `OwnerType <> 'REQUEST' OR OwnerId IS NOT NULL` · `Status = 'DRAFT' OR (SnapshotHash IS NOT NULL AND LockedAt IS NOT NULL AND LockedBy IS NOT NULL)` · `TreasuryHash IS NULL OR SnapshotHash IS NOT NULL` · `Status = 'DRAFT' OR (LcType IS NOT NULL AND CurrencyId IS NOT NULL AND Amount IS NOT NULL AND ExpiryRule IS NOT NULL AND AmountInWordsAr IS NOT NULL AND AmountInWordsEn IS NOT NULL)` · `Amount IS NULL OR Amount > 0` · `TolerancePlusPct BETWEEN 0 AND 100 AND ToleranceMinusPct BETWEEN 0 AND 100` · `Status = 'DRAFT' OR ToleranceMode <> 'NONE' OR (TolerancePlusPct = 0 AND ToleranceMinusPct = 0)` · `Status = 'DRAFT' OR ToleranceMode <> 'ABOUT' OR (TolerancePlusPct = 10 AND ToleranceMinusPct = 10)` · `DeferralDays IS NULL OR DeferralDays BETWEEN 1 AND 720` · `Status = 'DRAFT' OR LcType <> 'SIGHT' OR (DeferralDays IS NULL AND MaturityBasis IS NULL)` · `Status = 'DRAFT' OR LcType NOT IN ('DEFERRED_PAYMENT','ACCEPTANCE') OR (DeferralDays IS NOT NULL AND MaturityBasis IS NOT NULL)` · `Status = 'DRAFT' OR LcType <> 'MIXED' OR MixedPaymentText IS NOT NULL` · `Status = 'DRAFT' OR DraftDrawee IS NULL OR (DraftRequired IS NOT NULL AND DraftRequired = 1)` · `Status = 'DRAFT' OR LcType NOT IN ('ACCEPTANCE','NEGOTIATION') OR (DraftRequired IS NOT NULL AND DraftRequired = 1)` · `Status = 'DRAFT' OR ConfirmingBankBic IS NULL OR ((ConfirmingBankBic LIKE '________' OR ConfirmingBankBic LIKE '___________') AND ConfirmingBankBic COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%')` · `Status = 'DRAFT' OR AdvisingBankBic IS NULL OR ((AdvisingBankBic LIKE '________' OR AdvisingBankBic LIKE '___________') AND AdvisingBankBic COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%')` · `(BeneficiaryAccountIbanEnc IS NULL AND BeneficiaryAccountIbanMask IS NULL AND BeneficiaryAccountIbanHash IS NULL) OR (BeneficiaryAccountIbanEnc IS NOT NULL AND BeneficiaryAccountIbanMask IS NOT NULL AND BeneficiaryAccountIbanHash IS NOT NULL)` · `BeneficiaryAccountIbanEnc IS NULL OR (EncKeyId IS NOT NULL AND HashKeyId IS NOT NULL AND DATALENGTH(BeneficiaryAccountIbanEnc) >= 29)` · `LcClass = 'SALES' OR (ApplicantCounterpartyId IS NULL AND BeneficiaryCompanyId IS NULL)` · `LcClass = 'PURCHASE' OR (ApplicantCompanyId IS NULL AND BeneficiaryCounterpartyId IS NULL)` · `Status = 'DRAFT' OR (LcClass = 'PURCHASE' AND ApplicantCompanyId IS NOT NULL AND BeneficiaryCounterpartyId IS NOT NULL) OR (LcClass = 'SALES' AND ApplicantCounterpartyId IS NOT NULL AND BeneficiaryCompanyId IS NOT NULL)` · `ExpiryDaysAfterIssue IS NULL OR ExpiryDaysAfterIssue > 0` · `LatestShipmentDaysAfterIssue IS NULL OR LatestShipmentDaysAfterIssue > 0` · `Status = 'DRAFT' OR ExpiryRule IS NULL OR (ExpiryRule = 'ABSOLUTE' AND ExpiryDate IS NOT NULL AND ExpiryDaysAfterIssue IS NULL) OR (ExpiryRule = 'DAYS_AFTER_ISSUE' AND ExpiryDaysAfterIssue IS NOT NULL)` · `Status = 'DRAFT' OR (LatestShipmentRule IS NULL AND LatestShipmentDate IS NULL AND LatestShipmentDaysAfterIssue IS NULL) OR (LatestShipmentRule = 'ABSOLUTE' AND LatestShipmentDate IS NOT NULL AND LatestShipmentDaysAfterIssue IS NULL) OR (LatestShipmentRule = 'DAYS_AFTER_ISSUE' AND LatestShipmentDaysAfterIssue IS NOT NULL)` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR EarliestShipmentDate IS NULL OR LatestShipmentDate IS NULL OR EarliestShipmentDate <= LatestShipmentDate` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR ExpiryDate IS NULL OR LatestShipmentDate IS NULL OR ExpiryDate >= LatestShipmentDate` · `PresentationDays IS NULL OR PresentationDays BETWEEN 1 AND 90` · `Status = 'DRAFT' OR Purpose IN ('ISSUED','RECEIVED') OR IncotermId IS NULL OR IncotermPlace IS NOT NULL` · `InsurancePctStated = 0 OR InsuranceMinPct IS NOT NULL` · `InsuranceMinPct IS NULL OR InsuranceMinPct > 0` · `MarginPct IS NULL OR MarginPct BETWEEN 0 AND 100` · `Status = 'DRAFT' OR DebitAuthorization IS NULL OR DebitAuthorization <> 'FULL_LC_VALUE' OR (MarginPct IS NOT NULL AND MarginPct = 100)` · `PostDeferralFinancingDays IS NULL OR PostDeferralFinancingDays >= 0` · `PrevLcAmount IS NULL OR PrevLcAmount >= 0` · `PrevLcUtilizedAmount IS NULL OR PrevLcUtilizedAmount >= 0` · `PrevLcAmount IS NULL OR PrevLcUtilizedAmount IS NULL OR PrevLcUtilizedAmount <= PrevLcAmount` · `(PrevLcAmount IS NULL AND PrevLcUtilizedAmount IS NULL) OR PrevLcCurrencyId IS NOT NULL`

### `lc.LcTermsDocument` — Document clause selected in the terms, with its parameters; written only while the terms are a draft (044, DR-41) (FR-LCT-018, BR-LCT-012) -- جديد

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

### `lc.LcChargesMatrix` — Charges per term: one row per category; six complete rows, checked by the application (V-LCT-12); written only while the terms are a draft (044, DR-41) (FR-LCT-020, BR-LCT-014)

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

### `lc.LcFormTemplate` — Form template per bank, product and form type, with version, effective period and contract annex (FR-LCT-026, BR-LCT-017, specification 02 F-14)

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

### `lc.LcFormFieldMap` — Mapping of a system field to a PDF field or a portal-form item (FR-LCT-027, BR-LCT-020) -- جديد

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcFormFieldMapId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| TemplateId | BIGINT | لا |  | lc.LcFormTemplate |  |
| TargetName | NVARCHAR(120) | لا |  |  | اسم حقل PDF أو بند ورقة البوابة |
| SourceExpr | NVARCHAR(200) | لا |  |  | مسار من جذور مسموحة فقط؛ لا تنفيذ كود (BR-LCT-020) |
| Transform | VARCHAR(15) | لا | NONE |  | enum: NONE, UPPER, DATE_DMY, DATE_HIJRI, AMOUNT_WORDS_AR, AMOUNT_WORDS_EN, CHECKBOX_EQ, CONCAT_DOCS, CHARGES_SUMMARY |
| TransformArg | NVARCHAR(100) | نعم |  |  |  |
| IsRequired | BIT | لا | 0 |  | هدف إلزامي بلا مصدر يمنع الطباعة الرسمية (BR-LCT-020) |
| SeqNo | INT | نعم |  |  | ترتيب ورقة البوابة |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcFormFieldMapId) · UQ(TenantId, TemplateId, TargetName)

**قيود:** `SourceExpr LIKE 'terms.%' OR SourceExpr LIKE 'company.%' OR SourceExpr LIKE 'counterparty.%' OR SourceExpr LIKE 'facility.%' OR SourceExpr LIKE 'relationship.%' OR SourceExpr LIKE 'request.%' OR SourceExpr LIKE 'lc.%'` · `SourceExpr COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Za-z0-9._]%'` · `Transform <> 'CHECKBOX_EQ' OR TransformArg IS NOT NULL` · `SeqNo IS NULL OR SeqNo >= 1`

### `lc.LetterOfCredit` — Letter-of-credit record for both sides: purchases (we are the applicant) and sales (we are the beneficiary) (FR-LCI-011..016, FR-LCE-009, BR-LCI-004/008/016, BR-LCE-007/009)

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
| UtilizationId | BIGINT | نعم |  | fac.Utilization (via FacilityId,CompanyId) | ناتج fac.convert_reservation للشركة نفسها؛ الرابط الوحيد بين الاعتماد واستغلاله (FR-LCI-012، DQ-F12-14، DR-26) |
| RequestId | BIGINT | نعم |  | wfl.Request (via CompanyId) | طلب الإصدار (مشتريات)؛ فارغ للمسجَّل مباشرة والقائم السابق |
| ProformaId | BIGINT | نعم |  | lc.ProformaInvoice (via CompanyId) | بروفورما مبيعات واحدة قد تُربط باعتمادات عدة (BR-LCE-018) |
| CurrentTermsId | BIGINT | لا |  | lc.LcTerms (via LcClass,CurrencyId,TolerancePlusPct,ToleranceMinusPct) | الشروط الحالية: ISSUED/RECEIVED أو لقطة آخر تعديل مطبَّق؛ الفئة والعملة والتفاوت المنسوخة تطابقها (DR-42) |
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

**قيود:** `Amount > 0 AND OriginalAmount > 0` · `TolerancePlusPct BETWEEN 0 AND 100 AND ToleranceMinusPct BETWEEN 0 AND 100` · `DrawnAmount >= 0 AND SettledAmount >= 0 AND SettledAmount <= DrawnAmount` · `EarmarkedRemaining >= 0` · `ExposureAmount IS NULL OR ExposureAmount >= Amount` · `(LcClass = 'PURCHASE' AND IssueDate IS NOT NULL AND ReceivedDate IS NULL) OR (LcClass = 'SALES' AND ReceivedDate IS NOT NULL AND IssueDate IS NULL)` · `IssueDate IS NULL OR ExpiryDate >= IssueDate` · `LimitId IS NULL OR FacilityId IS NOT NULL` · `LimitProductLineId IS NULL OR LimitId IS NOT NULL` · `UtilizationId IS NULL OR FacilityId IS NOT NULL` · `RelationshipId IS NULL OR InstitutionId IS NOT NULL` · `LcClass = 'SALES' OR InstitutionId IS NOT NULL` · `LcClass = 'PURCHASE' OR (FacilityId IS NULL AND UtilizationId IS NULL AND ExposureAmount IS NULL AND MarginPct IS NULL AND MarginAmount IS NULL)` · `LcClass = 'SALES' OR ExposureAmount IS NOT NULL` · `LcClass = 'SALES' OR (ProformaId IS NULL AND OtherBankText IS NULL AND OtherBankBic IS NULL AND EarmarkedRemaining = 0)` · `MarginPct IS NULL OR MarginPct BETWEEN 0 AND 100` · `MarginAmount IS NULL OR MarginAmount >= 0` · `Status NOT IN ('CLOSED','CANCELLED') OR (ClosedOn IS NOT NULL AND ClosedReason IS NOT NULL)` · `Status IN ('CLOSED','CANCELLED') OR (ClosedOn IS NULL AND ClosedReason IS NULL)` · `UndrawnReleasedOn IS NULL OR Status IN ('EXPIRED','CLOSED','CANCELLED')` · `LegacyEntry = 0 OR RequestId IS NULL` · `OtherBankBic IS NULL OR ((OtherBankBic LIKE '________' OR OtherBankBic LIKE '___________') AND OtherBankBic COLLATE Arabic_100_BIN2 NOT LIKE '%[^A-Z0-9]%')` · `AmendmentNo >= 0` · `LcNumberNormalized NOT LIKE '% %'`

### `lc.LcExternalRef` — External reference for a credit (ERP and similar); no uniqueness; search on the normalised value (FR-LCI-013, BR-REQ-006) -- جديد

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

### `lc.LcAmendment` — Amendment to an issued or received letter of credit (FR-LCI-018/019, FR-LCE-020, BR-LCI-011/012, BR-LCE-014); statuses in section 8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcAmendmentId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company | شركة الطلب الفرعي: تُقيَّد بها الصلة بالطلب (DR-10) |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) | عملة التعديل = عملة الاعتماد |
| AmendmentNo | INT | نعم |  |  | رقم البنك أو تسلسل المنصة؛ يُسجَّل عند BANK_ISSUED |
| Origin | VARCHAR(22) | لا |  |  | enum: OUR_REQUEST, RECEIVED_FROM_CUSTOMER |
| ChangeKinds | VARCHAR(87) | لا |  |  | قائمة قيم ثابتة (المواصفة json) |
| RequestId | BIGINT | نعم |  | wfl.Request (via CompanyId) | الطلب الفرعي LC_AMENDMENT |
| TermsPurpose | VARCHAR(11) | لا | AMENDMENT |  | ثابت (DR-42) enum: AMENDMENT |
| TermsId | BIGINT | لا |  | lc.LcTerms (via TermsPurpose,CurrencyId) | شروط غرض AMENDMENT بعملة التعديل (لقطة ما بعد التعديل) |
| ChangedFieldsJson | NVARCHAR(MAX) | نعم |  |  | مفاتيح الحقول المتغيرة؛ لا قيمة لحقل مقيّد (DR-46) 🔒 confidential |
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
| WithdrawalDocumentId | BIGINT | نعم |  | doc.Document | تأكيد البنك المكتوب لسحب تعديل بعد إصداره (DQ-F12-7، B7e) |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcAmendmentId) · UQ(TenantId, LcId, AmendmentNo) WHERE AmendmentNo IS NOT NULL · UQ(TenantId, RequestId) WHERE RequestId IS NOT NULL · UQ(TenantId, TermsId)

**قيود:** `AmendmentNo IS NULL OR AmendmentNo >= 1` · `ChangeKinds <> ''` · `ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' OR ChangeKinds NOT LIKE '%DECREASE_AMOUNT%'` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' OR AmountDelta > 0` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%DECREASE_AMOUNT%' OR AmountDelta < 0` · `Status = 'DRAFT' OR (ChangeKinds NOT LIKE '%INCREASE_AMOUNT%' AND ChangeKinds NOT LIKE '%DECREASE_AMOUNT%') OR NewAmount IS NOT NULL` · `Status = 'DRAFT' OR ChangeKinds NOT LIKE '%EXTEND_EXPIRY%' OR NewExpiryDate IS NOT NULL` · `NewAmount IS NULL OR NewAmount > 0` · `Status <> 'WITHDRAWN' OR BankIssuedOn IS NULL OR (WithdrawalDocumentId IS NOT NULL AND Reason IS NOT NULL)` · `Status NOT IN ('BANK_ISSUED','APPLIED') OR (AmendmentNo IS NOT NULL AND BankIssuedOn IS NOT NULL)` · `Status <> 'APPLIED' OR (BeneficiaryResponse = 'ACCEPTED' AND AppliedOn IS NOT NULL AND AppliedBy IS NOT NULL)` · `BeneficiaryResponse IS NULL OR BeneficiaryResponse = 'PENDING' OR RespondedOn IS NOT NULL` · `Status <> 'REJECTED' OR BeneficiaryResponse = 'REJECTED'` · `Status <> 'WITHDRAWN' OR BeneficiaryResponse IS NULL OR BeneficiaryResponse = 'PENDING'`

### `lc.LcDrawing` — Drawing or presentation of documents under a credit; for exports includes transfer of allocation (FR-LCI-023, BR-LCI-013, BR-LCE-011); statuses in section 8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcDrawingId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company | شركة الطلب الفرعي: تُقيَّد بها الصلة بالطلب (DR-10) |
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
| RequestId | BIGINT | نعم |  | wfl.Request (via CompanyId) | طلب مستندات التحصيل في التصدير (lc.convert_earmark) |
| OverrideReason | NVARCHAR(500) | نعم |  |  | تجاوز TM لتقديم بعد الانتهاء (V-LCI-06) |
| Notes | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcDrawingId) · UQ(TenantId, LcId, DrawingNo) · UQ(TenantId, RequestId) WHERE RequestId IS NOT NULL

**قيود:** `Amount > 0` · `SettledAmount >= 0 AND SettledAmount <= Amount` · `Status <> 'SETTLED' OR SettledAmount = Amount` · `Status NOT IN ('REFUSED','CANCELLED') OR SettledAmount = 0` · `SettledAmount = 0 OR LastSettledOn IS NOT NULL` · `MaturityDate IS NULL OR MaturityBasisDate IS NULL OR MaturityDate >= MaturityBasisDate` · `ExaminationDeadline IS NULL OR ExaminationDeadline >= PresentationDate`

### `lc.LcSalesOrder` — Allocation of a sales order against a received credit; no credit limit corresponds to it (FR-LCE-013..015, BR-LCE-009..013); statuses in section 8

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcSalesOrderId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| CompanyId | BIGINT | لا |  | org.Company | شركة الطلب الفرعي: تُقيَّد بها الصلة بالطلب (DR-10) |
| LcId | BIGINT | لا |  | lc.LetterOfCredit (via CurrencyId) | عملة الأمر = عملة الاعتماد (V-LCE-06) |
| RequestId | BIGINT | لا |  | wfl.Request (via CompanyId) | طلب SALES_ORDER_APPROVAL؛ خطاف lc.earmark_sales_order متكرر الأمان |
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

### `lc.LcDrawingAllocation` — Allocation of an export drawing across sales orders (FR-LCE-016/017, BR-LCE-011/013) -- جديد؛ Σ التوزيع ≤ مبلغ السحب وكل جزء ≤ متبقي أمره يتحقق منهما التطبيق

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

### `lc.LcDiscrepancy` — Discrepancy on presented or issued documents; the decision requires the lc.discrepancy.decide permission (FR-LCI-024, FR-LCE-021, section 8) -- جديد

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

### `lc.ProformaInvoice` — Issued proforma invoice; after issue only its status, void reason and successor change (043, DR-41); number format {seq:000}-{erp}-{yy} (FR-LCE-005..008, BR-LCE-001..006)

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
| TermsPurpose | VARCHAR(11) | لا | PROFORMA |  | ثابت (DR-42) enum: PROFORMA |
| TermsId | BIGINT | لا |  | lc.LcTerms (via TermsPurpose,CurrencyId) | شروط غرض PROFORMA مقفلة بعملة البروفورما (نسخة عند الإصدار، BR-LCT-019) |
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

### `lc.ProformaLine` — Line item in the proforma (FR-LCE-003, BR-LCE-001); fixed after issue: written once, in one statement, never updated; the totals match the lines (044, DR-41)

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

**المفاتيح:** PK(ProformaLineId) · UQ(TenantId, ProformaId, LineNo)

**قيود:** `LineNo >= 1` · `Qty > 0` · `UnitPrice >= 0 AND LineTotal >= 0`

### `lc.LcTermsComparison` — Result of comparing received credit terms with the proforma (FR-LCT-031, FR-LCE-023, BR-LCT-021) -- جديد (أولوية: ممكن)

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

### `lc.LcTermsComparisonLine` — One field difference, its verdict and the treasury decision (FR-LCT-031, BR-LCT-021) -- جديد (أولوية: ممكن)

*مملوك للمشترك*

| العمود | النوع | NULL | الافتراضي | المرجع | ملاحظة |
|---|---|---|---|---|---|
| TenantId | INT | لا | | plat.Tenant | عزل المشترك |
| **LcTermsComparisonLineId** | BIGINT IDENTITY | لا | | | مفتاح أساسي |
| ComparisonId | BIGINT | لا |  | lc.LcTermsComparison |  |
| FieldKey | VARCHAR(60) | لا |  |  |  |
| BaselineValue | NVARCHAR(MAX) | نعم |  |  | لا قيمة لحقل مقيّد: IBAN يُحكم ببصمته ولا يُنسخ (DR-46) 🔒 confidential |
| ReceivedValue | NVARCHAR(MAX) | نعم |  |  | 🔒 confidential |
| Verdict | VARCHAR(15) | لا |  |  | enum: MATCH, MORE_FAVOURABLE, LESS_FAVOURABLE, ADDED, MISSING, REVIEW |
| Decision | VARCHAR(17) | نعم |  |  | enum: ACCEPT, REQUEST_AMENDMENT, IGNORE |
| DecisionNote | NVARCHAR(1000) | نعم |  |  |  |
| CreatedAt | DATETIME2(3) | لا | SYSUTCDATETIME() |  |  |
| CreatedBy | BIGINT | نعم |  |  |  |
| UpdatedAt | DATETIME2(3) | نعم |  |  |  |
| UpdatedBy | BIGINT | نعم |  |  |  |

**المفاتيح:** PK(LcTermsComparisonLineId) · UQ(TenantId, ComparisonId, FieldKey)

**قيود:** `Decision IS NULL OR Verdict <> 'MATCH'` · `FieldKey <> 'beneficiaryAccountIban' OR (BaselineValue IS NULL AND ReceivedValue IS NULL)`
