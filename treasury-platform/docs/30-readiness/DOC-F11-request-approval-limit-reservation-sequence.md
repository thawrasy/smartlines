# DOC-F11 — تسلسل معاملة موافقة الطلب وحجز الحد (M6 مع M5)

| البند | القيمة |
|---|---|
| المعرّف | DOC-F11 (docs/30-readiness-documents.md) |
| الإصدار | 0.1 — مسودة للمراجعة — 2026-10-12 |
| المالك المقترح | معماري الحلول مع مالكي M5 وM6 |
| الأولوية | P1 قبل S2 (العقد مع M5 يُنفَّذ في S2، ويعطّل S3) |
| يغطي | FR-WFL-022، FR-WFL-023، FR-WFL-035، BR-WFL-003، BR-WFL-015، BR-WFL-016، BR-WFL-017، BR-WFL-023، FR-FAC-017، FR-FAC-018، FR-FAC-020، BR-FAC-014، BR-FAC-015، AC-WFL-3، NFR-PERF-03، D-9 |
| يعتمد على | DOC-F10 (نقطة الحجز في القالب)، DOC-F04 (ربط الاتصال)، DOC-F17 (Outbox والإشعار بعد الالتزام)، DOC-B03 (NFR-PERF-03)، DOC-B04 (رموز الأخطاء ومفتاح التكرار)، DOC-F12 (التحويل عند الإصدار)، DOC-F14 (حالات الحجز) |
| المصادر | docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md، docs/10-detailed-analysis/12-m5-facilities-pricing-collateral-obligations.md، db/model/15-workflow-notifications.model، db/model/13-facilities-pricing-terms.model، db/model/10-platform.model، docs/20-database-design.md، docs/21-data-dictionary.md، docs/review/design-review-2026-10-11.json |

## 1. الغرض والنطاق

تصف هذه الوثيقة ما يجري حين يوافق مدير الخزينة على طلب في نقطة الحجز. الموافقة والحجز يتمّان معًا في معاملة واحدة أو لا يتمّ أيٌّ منهما (FR-WFL-022، 13-m6:143). وتفصل الوثيقة ما يقع داخل المعاملة عمّا يقع بعدها.

تغطي: ترتيب الخطوات، والأقفال وترتيبها، وإعادة المحاولة عند الجمود، وفروع الفشل ورموزها، والتجاوز، وعدم التكرار، والتحرير عند الرفض والإلغاء، والأحداث بعد الالتزام، واختبار NFR-PERF-03.

خارج النطاق: مراحل القالب (DOC-F10)، والتحويل عند الإصدار وتعديل الاعتماد (DOC-F12)، وحالات الحجز والاستغلال (DOC-F14)، وتسليم Outbox والإشعار (DOC-F17)، وربط الاتصال بالمشترك (DOC-F04).

اختصار المسار: «13-m6» و«12-m5» لملفي docs/10-detailed-analysis، و«15.model» = db/model/15-workflow-notifications.model، و«13.model» = db/model/13-facilities-pricing-terms.model.

الرموز: 🟢 قائم في المستودع أو مقرَّر في الوثائق، 🟡 مقترح ينتظر القرار.

## 2. ما يوجد في النموذج وما هو مواصفة فقط

الخدمة `fac.reserve_limit` عقد في طبقة التطبيق، لا إجراء في القاعدة (docs/20-database-design.md:41). لا يوجد إجراء حجز في db/static، ولا كود تطبيق في المستودع.

| البند | الحالة | المصدر |
|---|---|---|
| علم نقطة الحجز IsReservationPoint، ومقيّد بمرحلة APPROVAL | 🟢 في النموذج | 15.model:122، :134 |
| تعريف الخطاف على المرحلة: HookKey وExecMode = SYNC_TX وOnFailure = BLOCK | 🟢 الجدول wfl.WorkflowStageHook؛ 🟡 الصف المبذور غير موجود بعد | 15.model:183-195 |
| سجل تنفيذ الخطاف بمفتاح ونتيجة مخزّنة ورمز خطأ | 🟢 wfl.HookExecution، فريد (RequestId, StageInstanceId, HookKey, TriggerKind) | 15.model:480-502 |
| الموافقة ببصمة SnapshotHash، وإقرار التحذيرات، ولقطة التوفر، وطلب التجاوز وسببه | 🟢 قيود: البصمة إلزامية عند APPROVED، والسبب إلزامي مع التجاوز | 15.model:435-452 |
| مفتاح تكرار الإجراء | 🟢 wfl.RequestAction.IdempotencyKey فريد لكل طلب | 15.model:471-473 |
| حقول الحجز على الطلب | 🟢 ReservationId وReservedAmount وReservationState وقيد اقترانها | 15.model:294-296، :331-332 |
| الحجز | 🟢 fac.LimitReservation: مفتاح فريد، وحجز ACTIVE واحد لكل طلب، وOverLimit يلزمه سبب | 13.model:272-301 |
| حركة الحد | 🟢 fac.LimitMovement للإضافة فقط، بمفتاح فريد، والرصيد لا يهبط تحت الصفر | 13.model:303-324؛ db/generated/tsql/005_delete_grants.sql:49 |
| صف الحد الجاري | 🟢 fac.Limit بمراجعات، والجاري ToRevision IS NULL | 13.model:139-171 |
| صندوق Outbox | 🟢 cfg.OutboxEvent | db/model/10-platform.model:532-552 |
| قفل التسهيل ثم الحدود، وحساب المتاح، ورموز الرفض | 🟡 مواصفة فقط | 12-m5:252-253؛ 13-m6:306 |
| إعادة المحاولة عند الجمود حتى 3 مرات بتراجع 50 مللي ثانية | 🟡 مواصفة فقط | 13-m6:315 |
| اختبار 100 حجز متزامن | 🟡 غير مكتوب | docs/20-database-design.md:241، :493؛ NFR-PERF-03 |

## 3. المشاركون

| المشارك | ما يمثله | يعمل داخل المعاملة؟ |
|---|---|---|
| مدير الخزينة | المستخدم في المتصفح، يحمل `req.treasury.approve` | لا |
| الواجهة البرمجية | ASP.NET Core: المصادقة والربط ومفتاح التكرار | تفتح الاتصال وتربطه |
| محرك M6 | قواعد الدورة والخانات والانتقال | نعم |
| خدمة M7 | تحسب ExposureAmount (BR-WFL-016، 13-m6:247) | قراءة فقط |
| خدمة M5 | `fac.reserve_limit` وإخوتها (SVC-FAC-04، 12-m5:555) | نعم، على الاتصال نفسه |
| القاعدة | SQL Server 2025، جداول wfl وfac وaud وcfg تحت RLS | — |

قاعدة 🟡: الخطافات SYNC_TX استدعاءات داخل العملية نفسها، على الاتصال والمعاملة نفسيهما. لا خدمة شبكية بين M6 وM5 داخل المعاملة.

## 4. التسلسل الناجح

```mermaid
sequenceDiagram
  autonumber
  participant TM as مدير الخزينة
  participant API as الواجهة البرمجية
  participant WFL as محرك M6
  participant LC as خدمة M7
  participant FAC as خدمة M5
  participant DB as القاعدة
  TM->>API: POST approve مع Idempotency-Key و If-Match
  API->>DB: ربط السياق sec.usp_SetSessionContext
  API->>WFL: Approve مع الإقرارات وطلب التجاوز
  WFL->>DB: بحث RequestAction بالمفتاح
  rect rgb(235, 240, 255)
    WFL->>DB: BEGIN TRAN وقفل صف الطلب وفحص RowVersion
    WFL->>LC: ExposureAmount من الشروط المقفلة
    WFL->>DB: فحص المرحلة والخانة وفصل المهام و CheckMode
    WFL->>DB: RequestApproval بحالة APPROVED مع SnapshotHash
    WFL->>FAC: fac.reserve_limit على الاتصال نفسه
    FAC->>DB: قفل التسهيل ثم الحدود من الجذر إلى الورقة
    FAC->>DB: حساب Avail ثم LimitReservation و LimitMovement
    FAC-->>WFL: ReservationId و ReservedAmount و OverLimit
    WFL->>DB: HookExecution ناجح وحقول الحجز في الطلب
    WFL->>DB: إغلاق المثيل ودخول ERP_ENTRY
    WFL->>DB: RequestAction و AuditLog وصفوف Outbox
    WFL->>DB: COMMIT
  end
  API-->>TM: 200 مع الحالة الجديدة و ETag
  Note over DB: عامل Outbox يسلّم الأحداث والإشعارات بعد الالتزام في DOC-F17
```

## 5. خطوات المعاملة

| # | الخطوة | القفل أو الكتابة | عند الفشل |
|---|---|---|---|
| 0 | قبل المعاملة: الصلاحية `req.treasury.approve`، ونطاق الشركة، ومفتاح التكرار (DOC-B04 §7) | قراءة | 403 أو 404؛ إعادة الاستجابة المخزّنة عند التكرار |
| 1 | BEGIN TRAN بعزل READ_COMMITTED (docs/20-database-design.md:239) | — | — |
| 2 | قفل wfl.Request بـ UPDLOCK وROWLOCK، ومقارنة RowVersion (BR-WFL-023) | قفل | 409 VERSION_CONFLICT |
| 3 | ExposureAmount من M7، والتخصيص FacilityId وLimitId وLimitProductLineId | قراءة | 422 إن نقص التخصيص (BR-WFL-016) |
| 4 | المرحلة الحالية IsReservationPoint، والخانة PENDING للفاعل أو مجموعته، وفصل المهام (BR-WFL-006)، وشروط المغادرة (BR-WFL-014)، وCheckMode (BR-REQ-010) | قراءة | 409 إن سبقه مؤهل؛ 403 SOD_VIOLATION؛ 422 VALIDATION_FAILED أو WARNINGS_REQUIRE_ACK |
| 5 | تسجيل الموافقة: Decision = APPROVED، وActedByUserId، وOnBehalfOfUserId، وSnapshotHash، وClientIp، وAckWarningsJson، وAvailabilitySnapshotJson، وOverrideRequested وOverrideReason؛ والخانات الأخرى SUPERSEDED في ANY | كتابة wfl.RequestApproval | يُلغى بالتراجع |
| 6 | HookExecution بحالة PENDING ومفتاحه (§8) | كتابة | يُلغى بالتراجع |
| 7 | `fac.reserve_limit` (§6) | أقفال M5 وكتابة fac وOutbox | رمز رفض: تراجع كامل (§7) |
| 8 | HookExecution بحالة SUCCEEDED وResultJson؛ وReservationId وReservedAmount وReservationState = RESERVED على الطلب | كتابة | — |
| 9 | إغلاق المثيل DONE بـ ExitAction = APPROVE، واختيار الانتقال (BR-WFL-001)، ودخول ERP_ENTRY (BR-WFL-002) | كتابة | خطاف ON_ENTER فاشل بسياسة BLOCK يلغي الكل |
| 10 | RequestAction بالأنواع APPROVED وHOOK_EXECUTED وSTAGE_CHANGED، وaud.AuditLog بشدة عالية، وصفوف Outbox (§10) | كتابة | — |
| 11 | COMMIT | تحرير الأقفال | — |

بصمة SnapshotHash 🟡 (DQ-F11-5): SHA-256 على JSON مُطبَّع لما عُرض على الموافق: RequestId وCycleNo وRowVersion الطلب، والحقول الظاهرة له من FormDataJson، وAmount والعملة وExposureAmount، والتخصيص الثلاثي، وقيم لوحة التوفر المعروضة. والحقول المقيّدة تدخل البصمة مشفّرة كما خُزّنت، لا نصها.

## 6. داخل `fac.reserve_limit`: الأقفال والحساب

### 6.1 ترتيب الأقفال 🟡

ترتيب واحد لكل من يكتب الاستغلال أو الحجز، فلا يقع جمود بين الحجوزات:

| الترتيب | الصف | التلميح | السبب |
|---|---|---|---|
| 1 | wfl.Request للطلب | UPDLOCK وROWLOCK | جذر الإجراء؛ يمنع موافقتين على طلب واحد |
| 2 | fac.Facility للتسهيل | UPDLOCK وHOLDLOCK | نقطة التسلسل الواحدة لكل تسهيل (BR-FAC-015، 12-m5:253) |
| 3 | fac.Limit على المسار من الجذر إلى الورقة، الجاري فقط | UPDLOCK وHOLDLOCK بترتيب العمق | المتاح يأخذ أصغر قيمة على المسار (BR-FAC-014) |
| 4 | fac.LimitProductLine للخط | UPDLOCK وHOLDLOCK | سقف الخط |

بعد القفل 2 تُقرأ مجاميع fac.Utilization وfac.LimitReservation في جمل لاحقة. كل كاتب يأخذ قفل التسهيل أولًا، فالمجاميع ثابتة حتى الالتزام. ومع READ_COMMITTED_SNAPSHOT، إن فُعّل (DOC-B03 §2)، تبدأ هذه الجمل بعد حصول القفل، فترى ما التزم به الكاتب السابق.

القاعدة تشمل `fac.adjust_reservation` و`fac.convert_reservation` و`fac.release_reservation` و`fac.adjust_utilization` و`fac.create_utilization` و`lc.sync_exposure` ومهمة JOB-FAC-RESERVATION. المهمة لا تقفل wfl.Request بعد التسهيل؛ تُصدر `fac.reservation.expired`، ويعلّم المحرك الطلب LOST في معاملة أخرى (13-m6:311).

### 6.2 الفحوص والكتابة

1. التسهيل ACTIVE والحد غير منتهٍ، وإلا LIMIT_NOT_ACTIVE.
2. السريان: NOT_CONFIRMED بحسب سياسة التسهيل، وإلا VALIDITY_UNCONFIRMED.
3. المنتج مسموح للخط، والشركة غير مستبعدة، وسعر العملة متاح، وسياسة إيقاف التعهدات: PRODUCT_NOT_ALLOWED وCOMPANY_EXCLUDED وCURRENCY_NO_RATE وCOVENANT_STOP_POLICY.
4. Avail بالتعريف الوحيد BR-FAC-014، **باستثناء حجز الطلب نفسه** (12-m5:252-253).
5. ExposureAmount ≤ Avail: upsert حجز ACTIVE بـ RequestId (13.model:291)، وصف LimitMovement ‏CREATE أو ADJUST، وصف Outbox ‏`reservation.created` أو `reservation.adjusted` (12-m5:582).
6. ExposureAmount > Avail بلا تجاوز صالح: INSUFFICIENT_AVAILABLE مع المطلوب والمتاح.

M6 لا يعيد حساب المتاح ولا يعرض إلا ما تعيده M5 (BR-REQ-009، 13-m6:271).

### 6.3 إعادة المحاولة عند الجمود 🟡

- الخطأ 1205 (ضحية الجمود) يلغي المعاملة كلها في SQL Server. يعيد المحرك المعاملة من الخطوة 1، لا الجملة وحدها.
- حتى 3 إعادات بتراجع 50 مللي ثانية (13-m6:315)، ونقترح إضافة تفاوت عشوائي حتى 50 مللي ثانية كي لا تتصادم الإعادات ثانية.
- انتهاء مهلة القفل (1222) يُعامل كالجمود. نقترح `SET LOCK_TIMEOUT 5000` لهذه المعاملة (DQ-F11-2).
- بعد استنفاد الإعادات: CONCURRENT_RETRY ← 503 مع Retry-After (DOC-B04 §9.3).
- لا إعادة لرموز الأعمال ولا لـ VERSION_CONFLICT.

مع ترتيب §6.1 لا يقع جمود بين حجزين. الإعادة تبقى لحماية التقاطع مع مسارات أخرى لم تُبنَ بعد.

## 7. فروع الفشل

```mermaid
sequenceDiagram
  autonumber
  participant TM as مدير الخزينة
  participant API as الواجهة البرمجية
  participant WFL as محرك M6
  participant FAC as خدمة M5
  participant DB as القاعدة
  TM->>API: POST approve
  API->>WFL: Approve
  loop حتى 3 إعادات عند 1205 أو 1222
    WFL->>DB: BEGIN TRAN وقفل الطلب وتسجيل الموافقة
    WFL->>FAC: fac.reserve_limit
    FAC->>DB: الأقفال وحساب Avail
    FAC-->>WFL: INSUFFICIENT_AVAILABLE مع المطلوب والمتاح
    WFL->>DB: ROLLBACK
  end
  WFL->>DB: معاملة منفصلة HookExecution FAILED و HOOK_FAILED و AuditLog
  WFL-->>API: رمز الرفض
  API-->>TM: 409 problem+json مع المطلوب والمتاح
  Note over TM: الخيارات إرجاع أو انتظار أو تجاوز بسبب
```

الحلقة تتكرر للجمود فقط. رمز الأعمال يخرج منها من أول مرة.

| الحالة | أين | ما يُلغى | ما يُكتب بعد التراجع | HTTP والرمز |
|---|---|---|---|---|
| تعارض RowVersion | الخطوة 2 | لا شيء كُتب | — | 409 VERSION_CONFLICT |
| سبقه مؤهل في ANY | الخطوة 4 | — | — | 409 (FR-WFL-008) |
| فصل المهام | الخطوة 4 | — | AuditLog بحدث مرفوض (FR-WFL-009) | 403 SOD_VIOLATION |
| CheckMode = BLOCK أو إقرار ناقص | الخطوة 4 | — | — | 422 VALIDATION_FAILED أو WARNINGS_REQUIRE_ACK |
| INSUFFICIENT_AVAILABLE | الخطوة 7 | الموافقة والخانات والطلب كلها | HookExecution FAILED بالرمز، وRequestAction ‏HOOK_FAILED داخلي (BR-WFL-015) | 409 مع المطلوب والمتاح |
| LIMIT_NOT_ACTIVE | الخطوة 7 | كلها | كما سبق | 409 |
| VALIDITY_UNCONFIRMED، PRODUCT_NOT_ALLOWED، COMPANY_EXCLUDED، CURRENCY_NO_RATE، COVENANT_STOP_POLICY | الخطوة 7 | كلها | كما سبق | 422 |
| OVERRIDE_NOT_ALLOWED | الخطوة 7 | كلها | كما سبق | 403 |
| OVERRIDE_REASON_REQUIRED | الخطوة 4 أو 7 | كلها | — | 422 |
| جمود مستمر | الخطوة 7 | كلها | HookExecution FAILED برمز CONCURRENT_RETRY | 503 CONCURRENT_RETRY |

النتيجة كما في AC-WFL-3: الموافقة على B تُرفض INSUFFICIENT_AVAILABLE «دون أي موافقة مسجَّلة» (13-m6:759). الخانة تبقى PENDING، والطلب في TM_APPROVAL.

الرموز وحالاتها من DOC-B04 §9.3. النص للمستخدم يُصاغ من إسقاط الموظف، ولا يصل الطالب شيء منه (BR-WFL-024).
