# dbgen — لغة نموذج قاعدة البيانات

يحوّل نماذج نصية مضغوطة (`db/model/*.model`) إلى: **SQL Server** (الناتج المعتمد، `db/generated/tsql`) + **PostgreSQL** (للتحقق البنيوي فقط، `db/generated/pg`) + قاموس بيانات + مخططات ERD.
**المرجع الهندسي الواحد هو النموذج؛ لا تُعدَّل ملفات `generated/` يدويًا.**

```
python3 tools/dbgen/dbgen.py check  db/model/12-facilities.model --allow-missing-refs   # فحص ملف واحد (مراجع الوحدات الأخرى تُتجاهل)
python3 tools/dbgen/dbgen.py check  db/model/*.model                                    # فحص الكل (المراجع المعلّقة أخطاء)
python3 tools/dbgen/dbgen.py build  db/model/*.model --out db/generated --docs docs/    # توليد
tools/dbgen/pg_validate.sh db/generated/pg/000_all.sql                                  # تنفيذ فعلي على PostgreSQL
```

## 1. الصيغة

```
module FAC                                  # علامة وحدة لتجميع القاموس (اختيارية)
table fac.Facility public  # تسهيل: حزمة اتفاقية (FR-FAC-001)
  FacilityNo     ascii(40)   req   # الرقم الداخلي
  CurrencyId     ->ref.Currency req
  Status         enum{DRAFT,ACTIVE} req =DRAFT
  TotalAmount    money       req
  ParentLimitId  ->fac.Limit via=FacilityId     # ربط مركّب يضمن أن الأب من التسهيل نفسه
  check EndDate > StartDate
  unique FacilityNo
  unique FacilityId where ParentLimitId IS NULL
  index  BorrowerCompanyId,Status include EndDate
  sens   NationalNo,NumberHash
  calc   Total money =Amount * 2            # عمود محسوب مخزَّن (PERSISTED)؛ تعبيرات بسيطة فقط
```
- الأسطر المنزاحة تتبع آخر `table`. `#` تعليق (يظهر في القاموس).
- **لا تعرّف** `TenantId` ولا مفتاح الجدول `<Table>Id` ولا أعمدة التدقيق ولا `RowVersion` ولا `PublicId`: تُضاف آليًا.

### علامات الجدول (بعد الاسم)
| العلامة | الأثر |
|---|---|
| `int` | مفتاح INT بدل BIGINT (للكتالوجات والجداول الصغيرة) |
| `global` | جدول عالمي بلا `TenantId` (مثل `plat.Tenant`، `ref.Currency`) |
| `mixed` | نطاق مختلط: `TenantId` يقبل NULL (صفوف عالمية للقراءة فقط + صفوف المشترك) — مثل LookupItem |
| `public` | يضيف `PublicId UNIQUEIDENTIFIER` للتعريض عبر API (جذور التجميعات) |
| `catalog` | أعمدة الكتالوج المعتمدة: Code, NameAr, NameEn, Description, IsActive, IsSystem, IsLocked, SortOrder, SeedKey, ExternalCode + فرادة (Tenant,Code) و(Tenant,SeedKey) |
| `rev` | صف مراجَع [R]: FromRevision, ToRevision, SupersedesId (ذاتي) |
| `src` | ختم المصدر [S]: SourceDocumentId→doc.Document, SourcePage, ReadFromScan, OriginalText, Confidence, VerifiedBy/On, ConflictId→fac.ValueConflict |
| `pk=A,B` | مفتاح أساسي طبيعي مركّب (بلا مفتاح جديد؛ يسبقه TenantId) — للجداول الوسيطة |
| `append` | للإضافة فقط: بلا UpdatedAt/By وبلا RowVersion (سجلات التدقيق والأحداث) |
| `norv` | بلا RowVersion |
| `noaudit` | بلا أعمدة التدقيق |
| `deletable` | يُمنح التطبيق حذفًا فعليًا عليه؛ كل الجداول الأخرى `DENY DELETE` |

### الأنواع
| النوع | يصير |
|---|---|
| `int` `bigint` `smallint` `tinyint` `date` `time` `guid` | كما هي (`ts` ← `DATETIME2(3)` UTC) |
| `bool` | `BIT` (استعمل `=0`/`=1`، وفي `check` اكتب `Col = 1`) |
| `str(n)` · `ascii(n)` · `char(n)` | `NVARCHAR(n)` · `VARCHAR(n)` · `CHAR(n)` (رموز وأكواد: `ascii`) |
| `text` · `json` | `NVARCHAR(MAX)` (والـ`json` مع `ISJSON`) |
| `money` · `rate` · `dec(p,s)` | `DECIMAL(19,4)` · `DECIMAL(9,6)` (نقاط مئوية) · عشري |
| `bin(n)` · `blob` | `VARBINARY(n)` · `VARBINARY(MAX)` |
| `enum{A,B}` | `VARCHAR` + `CHECK ... IN (...)`؛ الافتراضي `=A` |
| `set{A,B}` | `VARCHAR` مفصول بفواصل (لقوائم صغيرة جدًا فقط؛ **قائمة مفاتيح = جدول وسيط**) |
| `->schema.Table` | مفتاح أجنبي؛ النوع يؤخذ من الهدف |

### الرموز على السطر
`req` إلزامي (الافتراضي اختياري) · `=VALUE` افتراضي · `via=ColA,ColB` أعمدة نطاق للربط المركّب · `cascade` · `noidx` (بلا فهرس تلقائي) · `sens=restricted|confidential`.

## 2. ما يولّده المولّد تلقائيًا
- **المشترك:** `TenantId INT NOT NULL` وFK إلى `plat.Tenant` لكل جدول مملوك للمشترك.
- **المفتاح:** `<Table>Id BIGINT IDENTITY` (أو INT)، و`UNIQUE (TenantId, <Table>Id)` هدفًا للمفاتيح المركّبة.
- **FK بين جدولين للمشترك = مركّب** `(TenantId, [via…], Col) → (TenantId, [via…], Id)` فيستحيل الربط عبر المشتركين أو عبر تسهيلين.
- FK نحو جدول `global` أو `mixed` = مفتاح بسيط.
- **فهرس تلقائي لكل FK** ما لم يغطّه مفتاح/فهرس أو وُضعت `noidx`.
- **التدقيق:** CreatedAt/By, UpdatedAt/By, RowVersion.
- أسماء الكيانات القيدية: `PK_/UQ_/IX_/FK_/CK_/DF_<Table>_…` فريدة داخل المخطط، ≤ 128.

## 3. قواعد التصميم (إلزامية لكاتب النموذج)
1. **جدول لكل كيان** وارد في القسم 6 بما فيه الموسوم (جديد)؛ والخاصية المتعددة القيم (set →كيان) تصير **جدولًا وسيطًا**.
2. اسم العمود المرجعي: `<الكيان>Id` أو دور واضح (`ParentLimitId`, `OwnerPartyId`, `CurrencyId`).
3. **المبلغ = `money` + `CurrencyId ->ref.Currency`**؛ النسبة `rate`؛ التاريخ ميلادي `date` (والنص الهجري `str(20)` حيث يلزم).
4. **القيود البسيطة** في `check` (ترتيب التواريخ، الحصرية XOR، النطاقات، ربط النوع بالحقول)؛ والمعقّد يبقى في التطبيق مع ذكر `BR-…` في التعليق.
5. **الفرادة** من عمود «الفرادة» في المواصفة → `unique` (والمصفّاة `where`).
6. **الفهارس** لما تنص عليه المواصفة من بحث وتقارير واستحقاقات (حالة، تاريخ استحقاق، رقم مرجعي، مفتاح بحث…).
7. **الحساسية:** أرقام الهوية/الإقامة/الجواز لا تُخزَّن صريحة: `NumberEnc bin(512)` + `NumberMask str(32)` + `NumberHash bin(32)` (HMAC فهرسة أعمى) وعلّمها `sens=restricted`.
8. **التعارض مع المواصفة** يُدوَّن في تقرير الكاتب ولا يُحلّ بالتخمين.
9. لا تخترع كيانات خارج المواصفات إلا لضرورة بنيوية (وسيط، سجل) وسمِّها في التقرير.

## 4. خريطة المخططات (Schema map)
| المخطط | محتواه |
|---|---|
| `plat` | Tenant، Plan، PlanModule، TenantModule، PlatformOperator، SupportAccessGrant (عالمي) |
| `ref` | Country، Currency، Incoterm، UcpArticle… (عالمي؛ مراجع) |
| `sec` | AppUser، Role، Permission، RolePermission، UserRole، UserCompanyScope، الجلسات/محاولات الدخول |
| `aud` | AuditLog، SensitiveAccessLog |
| `doc` | Document، DocumentVersion، DocumentLink |
| `cfg` | NumberSequenceDefinition، NumberIssue، TenantSetting، ExpiryAlertRule، DataExportJob، NonWorkingDay |
| `cat` | الكتالوجات (LegalEntityType، Position، PowerType، DocumentType، Product…، LookupList/Item مختلط) |
| `org` | Company، Department، Shareholding، GoverningBody، BodyMember، AuthorityGrant، CompanyProfile… |
| `pty` | Party، IdentityDocument، Address، ContactMethod، PartyCustomField، KycProfile… |
| `ins` · `acc` | المنشآت والجهات/العلاقات · الحسابات والمفوّضون |
| `fac` · `prc` · `col` · `obl` · `fin` · `cmp` | التسهيلات · التسعير والتعرفة · الضمانات · الالتزامات والتعهدات · البيانات المالية · الشروط القابلة للمقارنة |
| `wfl` · `ntf` | الطلبات ودورات العمل · الإشعارات |
| `lc` | الاعتمادات المستندية والبروفورما (LCT/LCI/LCE) |
