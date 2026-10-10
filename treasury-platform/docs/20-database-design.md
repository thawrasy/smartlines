# وثيقة تصميم قاعدة البيانات — BankFas

| البند | القيمة |
|---|---|
| الحالة | **مسودة للتقييم (الإصدار 0.1)** — التصميم مكتمل لكل وحدات `10…14`؛ **لم يُنفَّذ على SQL Server** بعد (انظر §14) |
| التاريخ | 2026-10-10 |
| المنتج | منصة إدارة الخزينة متعددة المشتركين (TMP) — قاعدة البيانات `BankFas` |
| المحرك المعتمد | **SQL Server 2025** (آخر إصدار؛ قاعدة سياسة الإصدارات في `01` §13) |
| المرجع الهندسي | `db/model/*.model` (194 جدولًا) — **الملفات المولَّدة لا تُعدَّل يدويًا** |
| المخرجات | `db/generated/tsql/*` (SQL Server) · `db/static/*` (RLS والأدوار والجلسة) · `db/deploy.sql` · `21-data-dictionary.md` · `22-erd-by-schema.md` |
| المتطلبات | 470 متطلبًا وظيفيًا في `10-detailed-analysis/10…14` (فهرس: `91-requirements-index.md`) |

---

## 1. النطاق والحالة

**داخل هذه الوثيقة:** التصميم المنطقي والفيزيائي الكامل لقاعدة البيانات لكل الوحدات: المنصة والأمن والتدقيق (م0)، الهيكل المؤسسي والأشخاص (م1)، الجهات المالية والحسابات والمفوّضون والكتالوجات (م2–م4)، التسهيلات والتسعير والضمانات والالتزامات والبيانات المالية ومكتبة الشروط (م5)، محرك الطلبات ودورات العمل والإشعارات (م6)، الاعتمادات المستندية والبروفورما (م7/م8).

**ليس فيها (لم يُطلب بعد):** إجراءات تخزين الأعمال (حدود/حجوزات…) — خدمات الحدود (`fac.reserve_limit` وإخوتها) **عقود في طبقة التطبيق** تقرأ وتكتب هذه الجداول؛ بيانات البذور الفعلية (§13)؛ سكربتات الترحيل بين الإصدارات؛ شيفرة التطبيق والواجهات.

| المؤشر | القيمة |
|---|---|
| جداول | **194** في 20 مخططًا |
| أعمدة | 3,248 مُعرَّفة في النماذج + الأعمدة الآلية = **3,774** في DDL |
| مفاتيح أجنبية | **741** = 184 لملكية المشترك (`TenantId → plat.Tenant`) + **476 مركّبة** `(TenantId, …)` بين جداول المشترك + 81 بسيطة نحو جداول عالمية/مختلطة |
| فهارس | 675 غير مجمّعة (196 مصفّاة · 47 بأعمدة `INCLUDE`) |
| قيود | 1,131 `CHECK` (قوائم قيم وتناسق حقول وتواريخ) · 387 قيد `UNIQUE` + فهارس فريدة مصفّاة |
| جداول بمعرّف عام `PublicId` | 38 (جذور التجميعات المعرَّضة عبر API) |
| جداول خاضعة لعزل الصفوف RLS | 184 (183 بسياسة عامة + `aud.AuditLog` بسياسة خاصة؛ الـ10 العالمية خارجها) |
| أعمدة محجوبة عن دور التقارير | 28 |

---

## 2. القرارات التقنية الأساسية

| # | القرار | السبب |
|---|---|---|
| T-1 | **SQL Server 2025** قاعدة واحدة `BankFas` لكل المشتركين | D-1، حمل منخفض على VPS خاص (`01` §0) |
| T-2 | **Collation القاعدة `Arabic_100_CI_AS_SC`** (غير حساس لحالة الأحرف، حساس للنبرات، يدعم المحارف التكميلية) | بيانات عربية وإنجليزية؛ البحث والفرادة غير حساسة لحالة الأحرف؛ تعدد اللغات داخل `NVARCHAR` |
| T-3 | **كل النصوص البشرية `NVARCHAR`**، والرموز والأكواد `VARCHAR` ASCII (`ascii(n)`) | توفير مساحة وسرعة فهرسة للأكواد |
| T-4 | **JSON كنص** `NVARCHAR(MAX)` + `CHECK (ISJSON(...) = 1)` | نموذج واحد يُتحقَّق منه على PostgreSQL؛ نوع JSON الأصلي في SQL Server 2025 **مرشَّح للاعتماد لاحقًا** عند حاجة فعلية (فهرسة داخل JSON) — لم يُعتمد الآن |
| T-5 | **لا Temporal Tables**؛ التاريخ بصفوف مراجَعة (`rev`) + `aud.AuditLog` | تاريخ ذو معنى أعمال (من أي مستند ومتى سرى) لا تاريخ تقني فقط؛ لا تضخّم تخزين لكل جدول |
| T-6 | **عزل المشتركين: `TenantId` في كل جدول + مفاتيح أجنبية مركّبة + RLS** (ثلاث طبقات) | §3 |
| T-7 | التشفير على مستوى **الأعمدة في طبقة التطبيق** (AES-256-GCM)، المفتاح ملفوف بمفتاح رئيسي **خارج القاعدة** | §6؛ لا `Always Encrypted` الآن لأن البحث بالتطابق يتم بفهرس أعمى HMAC خاص بنا |
| T-8 | **التوليد من نموذج واحد** (`dbgen`) لا كتابة DDL يدوية | اتساق 194 جدولًا وتتبّع التغيير في ملف مضغوط واحد لكل وحدة |
| T-9 | **PostgreSQL 16 للتحقق البنيوي فقط**؛ المعتمد للتسليم هو T-SQL | تنفيذ فعلي لما تيسّر في بيئة العمل (§14) دون ادعاء أنه اختبار على SQL Server |
| T-10 | اللغة: **الإنجليزية الأساس** في واجهات المشتركين، والعربية لاحقًا؛ أعمدة الأسماء ثنائية (`NameAr` إلزامي، `NameEn` اختياري في الكتالوجات) | FR-PLT-032 |

---

## 3. العزل بين المشتركين

### 3.1 الطبقات الثلاث
1. **بنية:** كل جدول مملوك للمشترك فيه `TenantId INT NOT NULL` مع `FK` إلى `plat.Tenant`.
2. **مفاتيح مركّبة:** كل جدول يملك `UNIQUE (TenantId, <Id>)` هدفًا، وكل مرجع بين جدولين للمشترك **مركّب** `(TenantId, [أعمدة النطاق…], Col) → (TenantId, [أعمدة النطاق…], Id)`.
   - يستحيل ربط سجل بسجل مشترك آخر **حتى لو أخطأ التطبيق**.
   - **أعمدة النطاق `via=`** تمنع الربط عبر تجميعتين داخل المشترك نفسه: حد أب من تسهيل آخر، حجز على خط منتج من حد آخر، مرحلة من قالب آخر… (73 مفتاحًا من الـ476 تحمل أعمدة نطاق).
3. **عزل الصفوف RLS** (`db/static/010_rls.sql`): سياسة أمنية لكل جدول؛ ترشيح وحجب إدراج/تعديل بالمعيار `TenantId = SESSION_CONTEXT('TenantId')`.

### 3.2 سياق الجلسة
- `sec.usp_SetSessionContext(@TenantId, @UserId, @ClientIp, @CorrelationId)` يُستدعى **عند فتح كل اتصال من المجمّع**؛ يضبط المفاتيح بـ `@read_only = 1` فلا يستطيع استعلام لاحق تغيير المشترك.
- يرفض مشتركًا غير موجود أو حالته خارج `TRIAL/ACTIVE/SUSPENDED/ARCHIVED_READ_ONLY`.
- لا يملك التطبيق مسارًا آخر لتحديد المشترك. الاتصال الذي لا يضبط السياق **لا يرى صفوف أي مشترك** (الجداول العالمية وصفوف المنصة المختلطة تبقى للقراءة).
- ⚠ المجمّع: إعادة الاستخدام تستلزم `sp_reset_connection` (سلوك `SqlClient` الافتراضي) حتى يُمسَح السياق قبل الضبط التالي.

### 3.3 أنواع النطاق
| النوع | علامة النموذج | الجداول | القراءة | الكتابة |
|---|---|---|---|---|
| مملوك للمشترك | (افتراضي) | 179 | صفوف مشتركه | صفوف مشتركه |
| عالمي | `global` | 10: `plat.Plan/PlanModule/Tenant/ReservedSubdomain/PlatformOperator` · `sec.Permission` · `cfg.SettingDefinition` · `ref.Country/Currency/Incoterm` | الكل | `tp_platform` فقط |
| مختلط | `mixed` | 5: `cat.LookupList` · `cat.LookupItem` · `cfg.NonWorkingDay` · `ref.UcpArticle` · `aud.AuditLog` (له سياسة خاصة §3.4) | صفوف المنصة (`TenantId IS NULL`) + صفوف مشتركه | صفوف مشتركه فقط؛ صفوف المنصة لـ `tp_platform` |

قيدان بنيويان يفرضهما المولّد: لا جدول عالمي أو مختلط يشير إلى جدول مملوك (يُرفض عند التوليد)، والمراجع نحو العالمي/المختلط مفاتيح بسيطة.

### 3.4 سياسة خاصة لـ `aud.AuditLog`
جدول مختلط ولكن دلالته مختلفة عن الكتالوجات (BR-PLT-001/009):
- **القراءة:** المشترك يرى صفوفه فقط. صفوف `TenantId IS NULL` (أحداث المنصة) **لأعضاء `tp_platform` فقط** (لا تُرى كصفوف عامة كما في الكتالوجات).
- **الكتابة (إدراج فقط):** `TenantId` الخاص بالمشترك أو `NULL` لحدث منصة؛ لا تعديل ولا حذف.
- الدوال: `rls.fn_AuditRead` و`rls.fn_AuditWrite`، والسياسة `rls.TP_aud_AuditLog`.

### 3.5 مشغّلو المنصة والدعم
- أعضاء `tp_platform` يتجاوزون RLS (إدارة المشتركين والاشتراكات). هذا الدور **لا يُمنح لحساب التطبيق العادي**.
- وصول الدعم إلى بيانات مشترك يمر عبر `plat.SupportAccessGrant`: يفعّله مستخدم من المشترك (`GrantedBy`) لمشغّل محدد، بنافذة زمنية `StartsAt…EndsAt` (من ساعة إلى 72 ساعة، الافتراضي 4 — تُتحقق في التطبيق) وسبب إلزامي، ويمكن إلغاؤه (`RevokedAt/By`)؛ ويُسجَّل في `aud.AuditLog` بشدة عالية (BR-PLT-009).

---

## 4. الاتفاقيات (Conventions)

| الموضوع | الاتفاق |
|---|---|
| **المفاتيح** | `<Table>Id BIGINT IDENTITY` (و`INT` للكتالوجات الصغيرة بعلامة `int`، 48 جدولًا)؛ المفتاح الأساسي مجمّع على المعرّف وحده؛ الفرادة المركّبة `(TenantId, Id)` هدفًا للمراجع |
| **المعرّف العام** | `PublicId UNIQUEIDENTIFIER DEFAULT NEWSEQUENTIALID()` على جذور التجميعات المعرَّضة (علامة `public`)، فريد على مستوى القاعدة؛ **لا يُعرَّض `BIGINT` عبر API** |
| **التدقيق** | `CreatedAt/CreatedBy/UpdatedAt/UpdatedBy` (UTC `DATETIME2(3)`) + `RowVersion ROWVERSION` للتزامن المتفائل (161 جدولًا) |
| **للإضافة فقط** | علامة `append`: بلا `UpdatedAt/By` وبلا `RowVersion`؛ **تُفرض بالصلاحيات** (`DENY UPDATE`) — §9 |
| **الحذف** | **لا حذف فعلي** إلا على الجداول المعلَّمة `deletable` (36 جدولًا: وسطاء وجلسات ورموز مؤقتة…)؛ الباقي بالحالة (أرشفة/إلغاء/استبدال) |
| **المبالغ** | `DECIMAL(19,4)` + عمود `CurrencyId` مجاور؛ لا مبلغ بلا عملة. أسعار الصرف `DECIMAL(19,8)` |
| **النسب** | `DECIMAL(9,6)` بنقاط مئوية (1.5 = 1.5%) |
| **القوائم المغلقة** | `VARCHAR` + `CHECK ... IN (...)` (لا جداول بحث لقيم منطق ثابتة)؛ القوائم القابلة للتخصيص لكل مشترك في `cat.LookupList/LookupItem` أو كتالوجات مسمّاة |
| **القوائم المتعددة القيم** | جدول وسيط؛ `set{}` (نص مفصول بفواصل) لقوائم صغيرة جدًا ثابتة فقط |
| **التواريخ** | ميلادي `DATE`؛ الهجري نص `NVARCHAR(20)` حيث تفرضه المستندات |
| **الأسماء** | مخططات بحروف صغيرة (`fac`)، جداول `PascalCase` مفرد، قيود `PK_/UQ_/IX_/FK_/CK_/DF_<Table>_…` ≤ 128 حرفًا |
| **الكتالوجات** | علامة `catalog`: `Code, NameAr, NameEn, Description, IsActive, IsSystem, IsLocked, SortOrder, SeedKey, ExternalCode` + فرادة `(Tenant,Code)` و`(Tenant,SeedKey)`؛ `SeedKey` يربط صف البذرة عبر الإصدارات دون الاعتماد على `Code` القابل للتعديل |
| **حقول الربط الخارجي** | `ExternalCode`/`ExternalRef` نصية عامة لربط ERP والبنوك لاحقًا دون تغيير بنيوي |

---

## 5. التاريخ والمراجعات ومصدر القيمة

### 5.1 الصفوف المراجَعة `rev` (13 جدولًا)
الأعمدة: `FromRevision`, `ToRevision` (NULL = الجاري), `SupersedesId`. التعديل **يُنشئ صفًا جديدًا** ويغلق السابق. الفرادة تُصفّى على الجاري (`WHERE ToRevision IS NULL`). التسهيل يملك رأسًا واحدًا + `fac.FacilityRevision` (مسودة/تقديم/رفض/اعتماد؛ مراجعة مفتوحة واحدة لكل تسهيل عبر فهرس فريد مصفّى).

### 5.2 ختم المصدر `src` (11 جدولًا)
كل قيمة ائتمانية مقروءة من اتفاقية تحمل: `SourceDocumentId`, `SourcePage`, `ReadFromScan`, `OriginalText`, `NoSourceReason`, `Confidence` (`ENTERED_NO_DOCUMENT` / … / `CONFIRMED_AGAINST_ORIGINAL`), `VerifiedBy/On`, `ConflictId → fac.ValueConflict`.
- قيد `CHECK`: إما مستند وصفحة، وإما `ENTERED_NO_DOCUMENT` — فلا قيمة بلا أصل أو إقرار بغيابه.
- «مؤكَّد مقابل الأصل» يستلزم مدققًا وتاريخًا.
- التعارض بين مستندين (أو مراجعتين) يُسجَّل في `fac.ValueConflict` ولا يُحلّ بالتخمين.

### 5.3 التدقيق
- `aud.AuditLog`: من/متى/ماذا (`BeforeJson/AfterJson` مع إخفاء الحقول المقيَّدة)/من أي عنوان وارتباط (`IpAddress`, `CorrelationId`)؛ إدراج فقط، بتصنيف (`Category`) وشدة (`Severity`) ونتيجة (`Result`). **سلسلة بصمات** اختيارية لكل مشترك (`ChainSeq`, `PrevHash`, `RowHash` = SHA-256 للسابق مع تمثيل قانوني للصف) لكشف العبث بعد التفعيل (FR-PLT-025).
- `aud.SensitiveAccessLog`: كل كشف أو تصدير أو عرض صورة هوية (`party.identity.reveal` · `party.identity.image.view` · `party.pack.export` · `party.export.sensitive`) بسبب إلزامي.
- `wfl.RequestAction`: سجل إجراءات الطلب (خطّ زمني للمستخدم) — **غير** سجل التدقيق الأمني.
- `sec.KeyEvent`: دورة حياة المفاتيح.

---

## 6. حماية البيانات الحساسة

| العنصر | التصميم |
|---|---|
| **أرقام الهوية/الإقامة/الجواز/هوية الخليج** | `NumberEnc VARBINARY(512)` (AES-256-GCM) + `NumberMask NVARCHAR(32)` (للعرض: آخر 4) + `NumberHash VARBINARY(32)` (HMAC-SHA256 فهرسة عمياء للبحث بالتطابق وكشف التكرار) في `pty.IdentityDocument` |
| **أرقام الحسابات والآيبان** | `…Enc / …Mask / …Hash` في `acc.BankAccount` و`lc.LcTerms` (آيبان المستفيد) |
| **قيم الحقول المخصصة الحساسة** | `pty.PartyCustomField.ValueEnc` |
| **علامات الامتثال (PEP/عقوبات/تحقيق/حصانة)** | `pty.PartyCompliance` — محجوبة عن التقارير |
| **المفاتيح** | `sec.TenantKey`: لكل مشترك مفاتيح بأغراض `DATA` / `BLIND_INDEX` / `FILE` وإصدارات؛ `WrappedKey` **ملفوف بمفتاح رئيسي خارج القاعدة** (`MasterKeyRef` يشير إليه)؛ مفتاح `ACTIVE` واحد لكل غرض (فرادة مصفّاة)؛ التدوير بحالة `RETIRING` أثناء إعادة التشفير |
| **كلمات المرور والرموز** | تُخزَّن **بصمات** فقط (`PasswordHash`, `TokenHash`, `CodeHash`) وأسرار MFA مشفّرة (`MfaSecretEnc`)؛ `sec.UserPasswordHistory` لمنع إعادة الاستخدام |
| **حجب عن التقارير** | `DENY SELECT` على 28 عمودًا موسومة `sens=restricted` للدور `tp_readonly` (`006_sensitive_columns.sql`) |
| **صور الهوية** | ملفات في مخزن الملفات خارج القاعدة (`doc.DocumentVersion`: `StorageKey` معزول لكل مشترك، `Sha256` يحسبه الخادم، `KeyId → sec.TenantKey` بمفتاح `FILE`، وفحص `ScanStatus` — لا يُنزَّل إلا `CLEAN`)؛ عرضها بصلاحية `party.identity.image.view` وسبب |
| **من يرى الأرقام كاملة** | مدير الخزينة وموظف التسهيلات فقط (قرار §9.4 في `04`)؛ غيرهما يرى `NumberMask`. تطبيق ذلك في **طبقة التطبيق بالصلاحيات**، والقاعدة تضمن أن لا شيء يُقرأ نصًّا صريحًا |

⚠ لا أسرار في النماذج: لا مفاتيح، ولا قيم افتراضية لكلمات مرور. البيانات الشخصية المقروءة من الاتفاقيات المرفوعة **لا تدخل الوثائق ولا البذور**.

---

## 7. استراتيجية سلامة البيانات

| المستوى | ما يضمنه | أين |
|---|---|---|
| **مرجعي** | كل مرجع مفتاح أجنبي (741)، والمركّب يمنع العبور بين المشتركين والتجميعات | `002_foreign_keys.sql` |
| **حالة** | قيم الحالات والأنواع `CHECK IN` (385) | `001_tables.sql` |
| **تناسق الحقول** | قيود تجمع الحقول المتلازمة: مبلغ مطلق أو نسبة من الأب (XOR)، ترتيب التواريخ، `ExposureAmount >= Amount`، اعتماد مبيعات بلا تسهيل/استخدام، `LcClass` يقيّد الحقول… | `CHECK` على الجداول |
| **فرادة** | رموز الكتالوج، الرقم الداخلي، **فريد بين الجاري فقط** (`WHERE ToRevision IS NULL`)، **حجز فعّال واحد لكل طلب**، **تحويل حجز واحد لكل استخدام**، وإعادة إرسال أمر الحجز لا تكرّره (`IdempotencyKey` فريد) | `UNIQUE` وفهارس فريدة مصفّاة (196 مصفّاة) |
| **تزامن** | `RowVersion` + مقارنة في التحديث | طبقة التطبيق |
| **منطق معقّد يبقى في التطبيق** (مذكور برمز `BR-…` في تعليق العمود) | عمق شجرة الحدود ≤ 6 وبلا حلقات · سقف الابن ≤ الأب · حساب المتاح `Available` · إعادة حساب `EffectiveAmount` · التحقق من صلاحيات التفويض · فحص التعارض بين المفوّضين | خدمات `fac.*` وخدمات التطبيق |

**قاعدة الحدود (ملخص):** المبلغ الوحيد الممرَّر لخدمات الحدود هو `ExposureAmount = Amount × (1 + PlusTol)`. أوضاع التوزيع `SHARED_CAP / PARTITION / OUTSIDE_TOTAL`. شدة الفحص `CheckMode` ∈ {`OFF`, `WARN`, `BLOCK`} بافتراضي **`WARN`** — إقرار مسجَّل (`AcknowledgedWarnings`) لا منع. الحجز يمر بحالات `ACTIVE → CONVERTED | RELEASED`، ولكل تحرك أثر في `fac.LimitMovement` (للإضافة فقط).

---

## 8. الفهرسة

| النوع | الاستخدام |
|---|---|
| **تلقائي لكل مفتاح أجنبي** | يُنشأ ما لم يغطّه مفتاح/فهرس أو وُسم `noidx` — يمنع الأقفال الطويلة عند الحذف/التحديث ويُسرّع الربط |
| **`TenantId` أولًا** في كل فهرس لجداول المشترك | توافق مع مرشّح RLS |
| **مصفّاة (196)** | استحقاقات وتنبيهات على الحالات الحية فقط (`Status = 'ACTIVE'`، `ExpiresOn IS NOT NULL`…) فتبقى صغيرة |
| **`INCLUDE` (47)** | لوحات التوفر وتقارير الاستحقاق دون رجوع للجدول |
| **بحث نصي كامل** | `wfl.Request.SearchText` — اختياري `db/static/040_fulltext_optional.sql` (يتطلب ميزة Full-Text Search) |

قيود SQL Server التي فُحصت آليًا في المخرجات: لا مفتاح فهرس يتجاوز **1,700 بايت** ولا 16 عمودًا؛ المسندات المصفّاة تستعمل `=` و`<>` و`IN` و`IS [NOT] NULL` و`AND` فقط (**لا `OR`**، وهو غير مدعوم في الفهارس المصفّاة)؛ مفتاحان فقط بـ `ON DELETE CASCADE` (`org.CompanyWealthSource` و`pty.KycProfileItemLegalForm`) فلا مسارات تعاقب متعددة.

> ملاحظة التنفيذ: الفهارس المصفّاة والأعمدة المحسوبة المخزَّنة تتطلب `QUOTED_IDENTIFIER ON` وخيارات ANSI. أدوات `sqlcmd` تفترضها `OFF`؛ لذلك يبدأ كل ملف مولَّد بضبطها ويُشغَّل النشر بالخيار `-I`.

---

## 9. الأدوار والصلاحيات (على مستوى القاعدة)

| الدور | الغرض | الصلاحيات |
|---|---|---|
| `tp_app` | حساب تشغيل التطبيق | `SELECT, INSERT, UPDATE, REFERENCES` على مخططات الأعمال؛ `plat`: قراءة فقط؛ `aud`: `SELECT, INSERT`؛ `DELETE` على الجداول المعلَّمة `deletable` فقط (`005`)؛ `DENY UPDATE` على جداول `append` خارج `aud` (7 جداول)؛ `EXECUTE` على `sec` و`cfg` |
| `tp_platform` | مشغّلو المنصة | يتجاوز RLS؛ كتابة على `plat`؛ إدراج في `aud`؛ **لا حذف**؛ `DENY UPDATE` على جداول `append` |
| `tp_readonly` | تقارير/تحليل | `SELECT` على كل المخططات **دون الأعمدة الحساسة** (`006`) |
| `tp_migrator` | النشر والترحيل | يُنشأ الدور فقط في `020`؛ **لم تُمنح له صلاحيات بعد** (تُحدَّد مع أداة الترحيل O-2)، ويُستعمل حساب بصلاحيات مالك القاعدة أثناء النشر |

- **لا يملك `tp_app` حذفًا** على أي جدول غير مصرَّح به (لا `DENY` على مستوى المخطط لأنه يُبطل منح الجداول).
- `DENY` يقيّد الأعضاء بالدور؛ مالكو القاعدة (`db_owner`/`sysadmin`) خارج هذا النموذج ويجب حصرهم تشغيليًا.
- حساب خدمة واحد للتطبيق (`tp_app`)؛ وحساب منفصل لمهام المنصة (`tp_platform`) لا يُشارك بيانات الاعتماد.

---

## 10. خريطة المخططات والجداول

| المخطط | الجداول | الوحدة |
|---|---:|---|
| `plat` | 7 — Plan, PlanModule, Tenant, ReservedSubdomain, PlatformOperator, TenantModule, SupportAccessGrant | م0 |
| `sec` | 14 — AppUser, Role, Permission, RolePermission, UserRole, UserCompanyScope, LoginAttempt, UserSession, MfaRecoveryCode, UserToken, UserPasswordHistory, ExternalIdentity, TenantKey, KeyEvent | م0 |
| `aud` | 2 — AuditLog, SensitiveAccessLog | م0 |
| `doc` | 3 — Document, DocumentVersion, DocumentLink | م0 |
| `cfg` | 12 — SettingDefinition, TenantSetting, NumberSequenceDefinition, NumberSequence, NumberIssue, ExpiryAlertRule, ExpiryAlertLog, DataExportJob, NonWorkingDay, OutboxEvent, JobRun, SeedRun | م0 |
| `org` | 14 — Company, CompanyTaxRate, Department, Shareholding, GoverningBody, BodyMember, AuthorityGrant, CompanyProfile, CompanyBranch, CompanyKycFinancialProfile, CompanyExpectedFlow, CompanyWealthSource, CompanyDisclosure, CompanyKeyRelation | م1 |
| `pty` | 11 — Party, IdentityDocument, Address, ContactMethod, CustomFieldDefinition, PartyCustomField, KycProfile, KycProfileItem, KycProfileItemLegalForm, PartyCompliance, TaxIdentity | م1 |
| `ref` | 4 — Country, Currency, Incoterm, UcpArticle | مرجعي |
| `cat` | 26 — TenantCurrency, InstitutionType, AccountType, LegalEntityType, DocumentType, Position, PowerType, OperationType, OperationTypePowerType, ProductCategory, Product, FeeType, FinancingType, ProductFeeType, ProductFinancingType, FacilityType, LimitType, LimitTypeProduct, CollateralType, CollateralTypeAttribute, ObligationType, BaseRate, BaseRateAlias, BaseRateValue, LookupList, LookupItem | م4 |
| `ins` | 6 — Institution, InstitutionUnit, Contact, Relationship, RelationshipContact, RelationshipProduct | م2 |
| `acc` | 6 — BankAccount, FacilityAccount, Signatory, SignatoryAuthority, SignatoryAuthorityJointClass, AuthorityConflict | م3 |
| `fac` | 13 — Facility, FacilityRevision, FacilityDocument, FacilityLender, OutstandingSnapshot, Limit, LimitProductLine, LimitCompanyRule, ProductLineTerm, Utilization, LimitReservation, LimitMovement, ValueConflict | م5 |
| `prc` | 5 — TariffSchedule, TariffItem, TariffTier, PricingRule, PricingTier | م5 |
| `cmp` | 2 — TermType, TermValue | م5 |
| `col` | 7 — Collateral, CollateralLink, Guarantee, PromissoryNote, PromissoryNoteSigner, InsurancePolicyAssignment, ValuationSchedule | م5 |
| `obl` | 8 — Obligation, ObligationCompany, ReportingObligation, ReportingInstance, Covenant, CovenantAccount, CovenantTest, ObligationBreach | م5 |
| `fin` | 7 — LineCatalogItem, LineCatalogItemAlias, FinancialStatement, StatementLine, AccountMonthlyStat, BankFlowEntry, MeasureFormula | م5 |
| `wfl` | 19 — RequestType, RequestTypeAudience, ExternalPhase, WorkflowTemplate, WorkflowStage, StageApprover, WorkflowTransition, WorkflowStageHook, TemplateField, TemplateAttachmentRule, Request, RequestComment, RequestAttachment, RequestExternalRef, RequestStageInstance, RequestApproval, RequestAction, HookExecution, UserDelegation | م6 |
| `ntf` | 7 — NotificationEventType, NotificationRule, NotificationTemplate, NotificationPreference, DigestBatch, Notification, NotificationDelivery | م6 |
| `lc` | 21 — LcFieldDefinition, LcFieldUcpRef, Counterparty, LcDocumentClause, LcDocumentClauseUcpRef, LcTerms, LcTermsDocument, LcChargesMatrix, LcFormTemplate, LcFormFieldMap, LetterOfCredit, LcExternalRef, LcAmendment, LcDrawing, LcSalesOrder, LcDrawingAllocation, LcDiscrepancy, ProformaInvoice, ProformaLine, LcTermsComparison, LcTermsComparisonLine | م7/م8 |

القاموس الكامل (عمود بعمود: النوع، الإلزام، الافتراضي، المرجع، الحساسية، الوصف): [`21-data-dictionary.md`](21-data-dictionary.md). مخططات العلاقات لكل مخطط (Mermaid) وجدول العلاقات العابرة للمخططات: [`22-erd-by-schema.md`](22-erd-by-schema.md).

### 10.1 تغطية المتطلبات
فُحص آليًا أن كل كيان مسمّى في القسم 6 من المواصفات (`10…14`) له جدول في النموذج؛ لم يظهر كيان ناقص (التطابقات الثلاثة المعروضة `A10/A11/SortOrder` ليست كيانات). تعيين المتطلبات إلى الجداول مرجعه تعليقات النماذج (`FR-…`/`BR-…`/`V-…` في كل جدول وعمود).

---

## 11. أنماط التصميم للمجالات الرئيسية

| المجال | النمط |
|---|---|
| **الأشخاص والجهات** | `pty.Party` موحّد (فرد/منشأة) يُعاد استخدامه: شريك، مدير، مفوّض، كفيل، جهة اتصال، مستفيد؛ الهويات والعناوين ووسائل الاتصال جداول تابعة؛ اكتمال KYC لكل بنك عبر `KycProfile/Item` (بنود بحد مالك `OwnerThresholdPct` وعمر أقصى `MaxAgeDays`) |
| **الهيكل المؤسسي** | `org.Company` (شكل قانوني منفصل عن علم «قابضة»)، `Shareholding` (ملكية متعددة الطبقات)، `GoverningBody`/`BodyMember`/`AuthorityGrant` (حوكمة وصلاحيات بسقف وتوقيع مشترك وفترة)، وجداول KYC للشركة (ملف، فروع، تدفقات متوقعة، مصادر ثروة، إفصاحات، علاقات رئيسية) |
| **الجهات المالية والحسابات** | `ins.Institution` ← `InstitutionUnit` ← `Contact` (طبقتان)، `Relationship` (شركة–بنك) تحمل مديري العلاقة والمنتجات؛ `acc.BankAccount` بأرقام مشفّرة؛ المفوّضون `Signatory` بحدود السلطة `SignatoryAuthority` وأسس التفويض ونوع التوقيع وسقف السحب النقدي، وتعارض السلطات `AuthorityConflict` |
| **التسهيلات** | `fac.Facility` (حزمة اتفاقية) + `FacilityRevision`؛ `Limit` شجرة بأوضاع توزيع؛ `LimitProductLine` خطوط منتج؛ `ProductLineTerm` شروط؛ `FacilityLender` للتجمعات؛ `Utilization`/`LimitReservation`/`LimitMovement`؛ `OutstandingSnapshot` رصيد إدخالي من البنك؛ `ValueConflict` |
| **التسعير** | `prc.TariffSchedule/Item/Tier` جداول رسوم؛ `PricingRule/Tier` قواعد تسعير (هامش فوق مرجع، عمولات)؛ `cat.BaseRate/Alias/Value` أسعار مرجعية (SIBOR/TARIF…) بقيم مؤرخة |
| **الضمانات** | `col.Collateral` + `CollateralLink` (ربط بحد/تسهيل بتغطية) + تخصصات: `Guarantee`, `PromissoryNote`+`Signer`, `InsurancePolicyAssignment`, `ValuationSchedule` |
| **الالتزامات** | `obl.Obligation` + `ReportingObligation/Instance` (تقويم تقارير) + `Covenant/CovenantTest/CovenantAccount` + `ObligationBreach`؛ `CheckMode` اختياري يرث افتراضي المشترك |
| **البيانات المالية** | `fin.FinancialStatement/StatementLine` ببنود كتالوج (`LineCatalogItem` + مرادفات)، `AccountMonthlyStat` متوسطات الأرصدة، `BankFlowEntry` المبالغ المحوَّلة (يدخلها قسم الخزينة)، `MeasureFormula` لحساب المؤشرات |
| **الشروط القابلة للمقارنة** | `cmp.TermType/TermValue` — مكتبة شروط للمقارنة المستقبلية بين البنوك بترتيب: التسعير ثم المدد ثم الضمانات |
| **محرك الطلبات** | `wfl.RequestType` ← `WorkflowTemplate` (قالب افتراضي قابل للتعديل) ← `WorkflowStage/StageApprover/Transition/Hook`؛ الطلب `Request` + نسخ المراحل + الموافقات + الإجراءات + المرفقات + المراجع الخارجية؛ `UserDelegation` للتفويض؛ أدوار المنشئ والمدقق والمعتمد بالصلاحيات، والفصل بينها `wf.sod.allow_same_person` |
| **الإشعارات** | `NotificationEventType` + `Rule` + `Template` + `Preference` (فوري/ملخص يومي/أسبوعي/إيقاف) + `Notification` + `Delivery` + `DigestBatch`؛ إلزامية بعض الأحداث تُفرض في التطبيق |
| **الاعتمادات** | `lc.LcTerms` (شروط مشتركة بين الطلب والاعتماد والبروفورما) + `LcFieldDefinition` وربط كل حقل بمواد UCP (`LcFieldUcpRef`) + `LetterOfCredit` (شراء/مبيعات) + تعديل/سحب/مخالفات + حجز طلبات المبيعات `LcSalesOrder` + `LcChargesMatrix` + `LcFormTemplate/FieldMap` لنماذج البنوك + `LcTermsComparison` |
| **الوظائف الخلفية** | `cfg.OutboxEvent` (بريد صادر لأحداث متسقة مع المعاملة)، `JobRun`، `ExpiryAlertRule/Log`، `DataExportJob`، `SeedRun` |

---

## 12. النشر والتشغيل

### 12.1 ترتيب النشر (`db/deploy.sql`، وضع SQLCMD)
```
sqlcmd -S <server> -E -I -f 65001 -i db\deploy.sql -v DbName=BankFas
```
1. إنشاء القاعدة بـ `Arabic_100_CI_AS_SC` إن لم تكن موجودة
2. `000_schemas` → `001_tables` → `002_foreign_keys` → `003_indexes` (مولَّدة)
3. `004_rls_tables` (جدول مؤقت بالجداول الخاضعة لـ RLS، في **الجلسة نفسها** حتى 010)
4. `020_roles_and_grants` → `005_delete_grants` → `006_sensitive_columns`
5. `010_rls` (الدوال والسياسات)
6. `030_session_context`
7. اختياري: `040_fulltext_optional`

الملفات تحوي `GO` وتُنفَّذ بالترتيب نفسه عند كل نشر؛ **لا يوجد بعدُ مسار ترحيل بين الإصدارات** (§16).

### 12.2 تغيير النموذج
عدِّل `db/model/*.model` ← `python3 tools/dbgen/dbgen.py check db/model/*.model` ← `build … --out db/generated --docs docs/` ← `tools/dbgen/pg_validate.sh db/generated/pg/000_all.sql`. لا تُعدَّل الملفات المولَّدة يدويًا. صيغة النموذج مشروحة في `tools/dbgen/README.md`.

### 12.3 النسخ الاحتياطي والاستعادة (توصيات للتشغيل 🟡)
- نسخ كامل ليلي + تفاضلي + سجل المعاملات كل 15 دقيقة (نموذج الاسترداد `FULL`)، ونسخ إلى موقع منفصل.
- **المفاتيح الرئيسية (خارج القاعدة) في نسخ احتياطي منفصل**؛ فقدانها يعني فقدان البيانات المشفّرة.
- اختبار استعادة دوري، مع اختبار فك تشفير عيّنة بعد كل استعادة.
- استرجاع مشترك واحد (حذف بالخطأ) يتم بتصدير/استيراد صفوفه بترتيب التبعيات من استعادة بنسخة مؤقتة، لأن القاعدة واحدة لكل المشتركين.
- ضبط `READ_COMMITTED_SNAPSHOT ON` للقاعدة لتقليل الحجب بين القراءة والكتابة (توصية تشغيل؛ لم يُضمَّن في السكربتات).

### 12.4 الأداء والحمل
الحمل المتوقع منخفض (مشتركون قليلون، VPS خاص)؛ التصميم لا يعتمد على Partitioning. إن نمت `aud.AuditLog` و`wfl.RequestAction` و`ntf.NotificationDelivery` فهي أول مرشحة للتقسيم/الأرشفة بالتاريخ.

---

## 13. البذور وتهيئة المشترك (خطة — لم تُنفَّذ بعد)

| المرحلة | المحتوى | الآلية |
|---|---|---|
| **عالمي** | `ref.Country/Currency/Incoterm/UcpArticle`، `plat.Plan/PlanModule`، `sec.Permission`، `cfg.SettingDefinition`، أنواع الأحداث `ntf.NotificationEventType`، تعريفات حقول الاعتماد `lc.LcFieldDefinition` + `LcFieldUcpRef` | سكربت بذور عالمي عند النشر؛ كل بذرة بـ `SeedKey` ثابت و`cfg.SeedRun` يسجل التنفيذ |
| **عند إنشاء مشترك** | كتالوجات المشترك الافتراضية (أنواع قانونية، مناصب، صلاحيات حوكمة، أنواع منتجات، أنواع حدود، أنواع ضمانات…)، الأدوار القياسية وربطها بالصلاحيات، قوالب دورات العمل الافتراضية القابلة للتعديل (شراء/مبيعات/عامة)، ملفات KYC المسبقة (KYC-CORP-BASE وبنوك التصدير والاستيراد/ساب/الرياض، KYC-PERSON-SIGNATORY…)، قواعد الإشعارات وقوالبها | إجراء تهيئة المشترك في التطبيق (idempotent) يبذر بـ `SeedKey`؛ لا يلمس ما عدّله المشترك (`IsSystem`/`IsLocked`) |
| **مفتاح مفقود** | قائمة `AUTHORISATION_BASIS` في `cat.LookupList` لأسس التفويض (طلبها مؤلفو النماذج) | تُضاف لبذور المشترك |

⚠ UCP: أرقام المواد في `lc.LcFieldUcpRef` **مراجع هندسية غير موثَّقة قانونيًا** إلى أن يتحقق منها مختص (عمود `VerifiedBy/On` في `ref.UcpArticle`).

---

## 14. أدلة التحقق وحدودها (بصراحة)

| الفحص | النتيجة | ملاحظة |
|---|---|---|
| فحص النموذج (`dbgen check`) | **OK** — 194 جدولًا / 3,248 عمودًا؛ لا مراجع معلّقة؛ لا مخالفة لقواعد النطاق | التحقق من التسمية والمراجع والمفاتيح المركّبة والأعمدة المطلوبة |
| تنفيذ PostgreSQL 16 | **OK** — 194 جدولًا / 741 مفتاحًا أجنبيًا / 691 قيد فريد أو أساسي، تنفيذ كامل بلا أخطاء | يثبت سلامة **البنية المنطقية** (الأسماء، المراجع، القيود، الفرادة المصفّاة). **لا** يثبت صحة T-SQL |
| تحليل T-SQL بـ `sqlglot` | `000…005` و`010/020/030/040`: **بلا أخطاء**؛ `006`: 28 تحذير لأن المحلّل لا يدعم صيغة `DENY SELECT ON [s].[T]([Col])` على مستوى العمود — وهي صيغة صحيحة في T-SQL | التحليل نحوي جزئي (المؤشرات `CURSOR` وسياسات الأمان تُعامَل كأوامر عامة) |
| فحوص آلية لمحاذير SQL Server | لا `OR` في الفهارس المصفّاة · مفاتيح الفهارس ≤ 1,700 بايت و≤ 16 عمودًا · لا مسارات `CASCADE` متعددة · خيارات `SET` ضُمّنت للفهارس المصفّاة | فحوص نصّية على المخرجات |
| **التنفيذ على SQL Server 2025** | **لم يحدث** | لا توفر المحرك في بيئة العمل. **أول خطوة قبل أي اعتماد:** تشغيل `deploy.sql` على نسخة SQL Server 2025 نظيفة وتصحيح ما يظهر (متوقع: تفاصيل صيغة قليلة، خصوصًا `CREATE SECURITY POLICY` الديناميكي وترتيب النشر) |
| اختبارات سلوكية (RLS/تعدد المشتركين/القيود) | **لم تُكتب** | مقترح: حزمة tSQLt أو اختبارات تكامل تنشئ مشتركَين وتحاول القراءة/الكتابة العابرة وتتحقق من الرفض |

---

## 15. القرارات المتخذة أثناء الصياغة (تُعتمد ما لم تعترض)

مؤلفو النماذج رصدوا ثغرات أو تعارضات بين المواصفات؛ هذه ما اتُّخذ فيها:

| # | الموضوع | القرار |
|---|---|---|
| DB-1 | `ErpCompanyCode` | فريد بين الشركات غير المؤرشفة (أشدّ من تحذير BR-ORG-001 وتحققه القاعدة) |
| DB-2 | `pty.KycProfile.InstitutionId` | اختياري؛ علم «أساسي» للملفات غير المرتبطة ببنك |
| DB-3 | قوالب دورات العمل | عائلة قوالب لكل نوع طلب؛ البذور المشتركة تُكرَّر لكل نوع (لا مشاركة قالب بين نوعين) |
| DB-4 | رأس التسهيل | صف واحد + `FacilityRevision.HeaderChanges`؛ لا نسخ رأس لكل مراجعة |
| DB-5 | `fac.Limit` عقد النسخ | نسخ الشجرة الفرعية عند المراجعة عقدٌ في التطبيق (`[R]`) |
| DB-6 | `ref.UcpArticle` | نطاق مختلط؛ `VerifiedBy → plat.PlatformOperator` |
| DB-7 | `ref.Incoterm` | عالمي (Incoterms 2020) |
| DB-8 | `fac.ValueConflict` | المرشّحون مسطَّحون (أعمدة) لا جدول فرعي |
| DB-9 | `fac.LimitMovement` | مفاتيح أجنبية مكتوبة (حجز/استخدام/…) لا مرجع عام متعدد الأشكال |
| DB-10 | الملخص الأسبوعي | أُضيفت `DIGEST_WEEKLY` إلى `ntf.NotificationPreference.Mode` |
| DB-11 | `wfl.RequestAction.ActionType` | أُضيفت: `RESERVATION_LOST`, `DRAFT_ARCHIVED`, `DRAFT_RESTORED`, `CHANNEL_CHANGED`, `SOD_EXCEPTION_USED`, `DELEGATION_CREATED`, `DELEGATION_REVOKED` |
| DB-12 | جهات اتصال المدير العام/المالي | عبر `org.BodyMember` + `pty.ContactMethod` (لا جدول مستقل) |
| DB-13 | الإضافة فقط | تُفرض بـ `DENY UPDATE` لـ `tp_app` و`tp_platform` على جداول `append` خارج `aud` (الجداول: LoginAttempt, UserPasswordHistory, KeyEvent, ExpiryAlertLog, SeedRun, LimitMovement, RequestAction) |

---

## 16. حدود معروفة ونقاط مفتوحة

| # | البند | الأثر | المقترح |
|---|---|---|---|
| O-1 | **لم تُنفَّذ السكربتات على SQL Server** (§14) | قد تظهر أخطاء صيغة | أول مهمة: نشر على SQL Server 2025 نظيف + حزمة اختبار RLS |
| O-2 | لا سكربتات ترحيل بين الإصدارات | تغيير النموذج يعيد توليد DDL كاملًا | اعتماد أداة ترحيل (مثل DbUp/Flyway) عند أول نشر فعلي على بيانات حقيقية؛ المولِّد يولّد «الحالة المستهدفة» فقط |
| O-3 | البذور غير مكتوبة (§13) | القاعدة فارغة بعد النشر | كتابتها مع شريحة S0 |
| O-4 | أسئلة مفتوحة بقيم افتراضية في `90-consolidated-open-questions.md` | أثرها على الشرائح اللاحقة؛ المتعلق منها بـ S3: Q-WFL-02, Q-WFL-09, Q-WFL-11, Q-LCT-01/02, Q-LCI-01/02 | تُراجع عند بدء S3 |
| O-5 | الأعمدة المحسوبة محدودة (3) | بقية المشتقات (المتاح، الرصيد) تُحسب في التطبيق/العروض | عروض/دوال لاحقًا عند الحاجة لتقارير |
| O-6 | سياسات الاحتفاظ والأرشفة (جداول التدقيق والإشعارات) غير محدَّدة | نمو الجداول الكبيرة | قرار احتفاظ لكل جدول مع بدء التشغيل |
| O-7 | نموذج استرداد القاعدة والنسخ المتعدد المشتركين | استعادة مشترك واحد معقّدة (§12.3) | إن طلب مشترك كبير قاعدة مستقلة، يمكن لاحقًا نقل صفوفه إلى قاعدة خاصة لأن البنية تحمل `TenantId` والمفاتيح المركّبة |
| O-8 | نوع JSON الأصلي في SQL Server 2025 | غير مستعمل (T-4) | تقييمه عند الحاجة إلى استعلام داخل JSON |

---

## 17. الخطوة التالية

1. **تقييمك** لهذه الوثيقة، خاصة القرارات §2 و§15 والحدود §16.
2. نشر على **SQL Server 2025** فعلي وتصحيح ما يظهر + اختبارات RLS والمفاتيح المركّبة (O-1).
3. ثم تصميم الواجهات (RTL لاحقًا؛ الإنجليزية أولًا) والشريحة الرأسية الرقيقة S0، أو التوجّه الذي تحدده.
