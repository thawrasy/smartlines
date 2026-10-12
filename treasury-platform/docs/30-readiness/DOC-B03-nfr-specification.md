# DOC-B03 — مواصفة المتطلبات غير الوظيفية

| البند | القيمة |
|---|---|
| المعرّف | DOC-B03 (docs/30-readiness-documents.md)، ويشمل DOC-S14 المدمج فيه |
| الإصدار | 0.1 — مسودة للمراجعة — 2026-10-12 |
| المالك المقترح | معماري الحلول مع مدير التشغيل؛ والقسم الأمني مع مهندس الأمن |
| الأولوية | P0 قبل S0 |
| يغطي | 00 §6.1 و§6.2 و§6.4، X-SEC-1 إلى X-SEC-7، FR-PLT-010 إلى 014، FR-PLT-032 إلى 034، FR-PLT-044، FR-PLT-045، O-14 (20-database-design)، O-08 (erd_open_items) |
| يعتمد على | DOC-B01، DOC-B02، DOC-B11، DOC-S02، DOC-S03، DOC-S04، DOC-S05، DOC-S06، DOC-S09، DOC-S12، DOC-S13 |
| المصادر | docs/10-detailed-analysis/00-overview-and-cross-cutting.md، docs/10-detailed-analysis/10-m0-m1-platform-organization.md، docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md، docs/20-database-design.md، docs/adr/0001-schema-work-on-linux.md، docs/adr/0002-login-and-session-bound-context.md، db/static/030_session_context.sql، tools/ci/db_ci.sh |

## 1. الغرض والنطاق

تحوّل هذه الوثيقة الأهداف غير الوظيفية المتفرقة إلى سجل بمعرّفات، لكل بند هدف وطريقة قياس وإجراء اختبار ومالك ومصدر.

- مصدرها الرئيسي جدول §6.4 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:164-173)، وكل قيمه بوسم 🟡 أي مقترحة.
- تضم متطلبات الأمن والتدقيق (X-SEC وX-AUD في السطور 134-150) بمعايير قبول، فتحل محل DOC-S14 (docs/30-readiness-documents.md:314-316).
- لا تكرر ما تملكه وثائق أخرى: قيم كلمات المرور في DOC-S04، وإعدادات TLS في DOC-S05، وإجراءات النسخ والاستعادة في DOC-S09، والسجلات والتنبيهات في DOC-S12، وخطة الاختبار الأمني في DOC-S13.
- كل رقم لم يرد في مصدر معتمد مقترح 🟡 ومدرج في §11.

البادئات: PERF الأداء والتزامن · AVL التوفر · REC التعافي · SEC الأمن · SCL قابلية التوسع · ACC إمكانية الوصول · OPS التشغيل · I18N اللغة والتوطين.

## 2. الأداء والتزامن (NFR-PERF)

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-PERF-01 | الشاشات الرئيسية: زمن الطلب على الخادم p95 ≤ 2 ثانية، وتحميل الصفحة ≤ 2 ثانية، ببيانات NFR-SCL-02 | p95 من سجلات التطبيق، وزمن التحميل من المتصفح | اختبار حمل في بيئة الاختبار بعشرين مستخدمًا متزامنًا 🟡 قبل خروج S2 | قائد التطبيق | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:167 |
| NFR-PERF-02 | البحث الموحّد في المنشآت وجهات الاتصال < 2 ثانية على 5,000 جهة | p95 لنقطة البحث | AC-INS-8 قبل خروج S1 | قائد التطبيق | docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md:128 |
| NFR-PERF-03 | 100 طلب حجز متزامن على الحد نفسه: لا تجاوز للمتاح، ولكل طلب نتيجة محددة | مجموع المحجوز مقابل المتاح بعد التشغيل، وعدد النتائج لكل نوع | اختبار تكامل تزامني على SQL Server 2025 قبل خروج S2 | قائد قاعدة البيانات | docs/20-database-design.md:241 |
| NFR-PERF-04 | الترقيم: 50 طلبًا متزامنًا 🟡 بلا رقم مكرر ولا فجوة | فحص التسلسل الناتج | اختبار تكامل ضمن AC-PLT-3 | قائد قاعدة البيانات | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:128 |
| NFR-PERF-05 | الدخول: p95 ≤ 1 ثانية 🟡 بعشرين دخولًا متزامنًا، مع سقف للتجزئات المتزامنة لأن كل تجزئة Argon2id تحجز 64 ميغابايت | الزمن، وذروة ذاكرة عملية التطبيق | اختبار حمل لنقطة الدخول | قائد التطبيق | docs/adr/0002-login-and-session-bound-context.md:14 |
| NFR-PERF-06 | ربط السياق لكل طلب بـ sec.usp_SetSessionContext: p95 ≤ 20 مللي ثانية 🟡 | زمن الاستدعاء من قياس التطبيق | ضمن اختبار NFR-PERF-01 | قائد قاعدة البيانات | docs/adr/0002-login-and-session-bound-context.md:22 |
| NFR-PERF-07 | تعديلان متزامنان لسجل واحد: يُقبل الأول ويُرفض الثاني برمز تعارض ثابت | نتيجة الطلبين | اختبار API | قائد التطبيق | docs/20-database-design.md:232 |

ملاحظات:
- مستوى العزل READ_COMMITTED مع قفل صريح للحد (docs/20-database-design.md:239)، وREAD_COMMITTED_SNAPSHOT توصية تشغيل غير مضمَّنة في السكربتات (السطر 462). يُقاس NFR-PERF-01 بالإعداد الذي يُعتمد للإنتاج.
- يُقاس الأداء على بيئة اختبار بحجم الإنتاج نفسه (DQ-B03-9)، لا على CI.

## 3. التوفر (NFR-AVL)

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-AVL-01 | 99.5% شهريًا للإنتاج في المرحلة الأولى، أي نحو 3.6 ساعات توقف في شهر من 30 يومًا | مراقب خارجي يطلب نقطة الصحة كل دقيقة 🟡، خارج نوافذ الصيانة المعلنة | تقرير شهري | مدير التشغيل | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:168 |
| NFR-AVL-02 | نافذة صيانة معلنة 🟡: ساعتان أسبوعيًا خارج ساعات العمل بإشعار 48 ساعة | جدول الصيانة المنشور | مراجعة شهرية | مدير التشغيل | DQ-B03-5 |
| NFR-AVL-03 | نقطة صحة للتطبيق والقاعدة والمهام والمخزن، لا تكشف بيانات مشترك | استجابة النقطة | فحص آلي بعد كل نشر (DOC-B11) | مهندس DevOps | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:173 |

الإنتاج خادم VPS واحد لقاعدة البيانات (docs/adr/0001-schema-work-on-linux.md:16)، فلا تكرار تلقائي. استعادة كاملة بزمن RTO المقترح (4 ساعات) تستهلك أكثر من ميزانية الشهر (3.6 ساعات). القرار في DQ-B03-3.

## 4. التعافي (NFR-REC)

كل قيم هذا القسم مقترحة وغير معتمدة: §6.4 يذكرها بوسم 🟡 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:169)، و10-m0-m1 يقول إنها «تُثبَّت مع الاستضافة» (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:590)، ووثيقة القاعدة تقول إنها «لم تُحدَّد بعد» (docs/20-database-design.md:463) وتسجلها O-14 (20-database-design، السطر 542). إجراءات النسخ والاستعادة في DOC-S09.

```mermaid
flowchart LR
  A["آخر نسخة سجل معاملات خارج الخادم"] -->|"RPO ≤ 15 دقيقة"| B["وقوع الحادث"]
  B --> C["إعلان الحادث"]
  C --> D["تجهيز الخادم والمفاتيح"]
  D --> E["استعادة كامل ثم تفاضلي ثم السجل"]
  E --> F["فحص فك تشفير عيّنة"]
  F --> G["عودة الخدمة"]
  B -.->|"RTO ≤ 4 ساعات"| G
```

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-REC-01 | RPO ≤ 15 دقيقة 🟡 غير معتمد | الفارق بين آخر نسخة سجل ناجحة منسوخة خارج الخادم ووقت الحادث | تمرين استعادة | مدير التشغيل مع DBA | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:169 |
| NFR-REC-02 | RTO ≤ 4 ساعات 🟡 غير معتمد | من إعلان الحادث إلى نجاح فحص الدخان | تمرين استعادة كامل ربع سنوي 🟡 | مدير التشغيل | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:169 |
| NFR-REC-03 | نسخ كامل ليلي وتفاضلي وسجل معاملات كل 15 دقيقة بنموذج FULL، ونسخة في موقع منفصل | سجل مهام النسخ | فحص آلي يومي لنجاح المهام | DBA | docs/20-database-design.md:458 |
| NFR-REC-04 | اختبار استعادة دوري مع فك تشفير عيّنة | نجاح الاستعادة وقراءة عمود مشفّر | شهري 🟡 في بيئة معزولة | DBA | docs/20-database-design.md:460 |
| NFR-REC-05 | المفاتيح الرئيسية في نسخ منفصل عن القاعدة ونسخها | جرد مواقع النسخ | تمرين استعادة المفتاح (DOC-S02) | مسؤول حفظ المفاتيح | docs/20-database-design.md:459 |
| NFR-REC-06 | استرجاع مشترك واحد دون المساس بغيره خلال 8 ساعات 🟡 | زمن الإجراء | تمرين نصف سنوي 🟡 | DBA | docs/20-database-design.md:461 |

شرط NFR-REC-01: نسخة السجل كل 15 دقيقة لا تحقق RPO 15 دقيقة إن بقيت على الخادم نفسه وفُقد الخادم. فالقياس من آخر نسخة وصلت الموقع المنفصل.

## 5. الأمن (NFR-SEC، ويحل محل DOC-S14)

معيار القبول لكل بند هو الهدف نفسه، ويُثبت بالاختبار المذكور. الحالات T-n في db/tests/tenant_isolation_tests.sql، والسيناريوهات AC في DOC-B02.

| المعرّف | الهدف ومعيار القبول | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-SEC-01 | عزل المشتركين: صفر صفوف عابرة؛ 41 حالة قاعدة تمر في كل بناء؛ كل نقطة API تعيد 404 لمعرّف مشترك آخر | PASS لكل حالة | خطوة CI 7 (tools/ci/db_ci.sh:75-92)، واختبار العبور المولَّد من OpenAPI | QA lead | X-SEC-4 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:139)؛ O-09 (erd_open_items) |
| NFR-SEC-02 | فشل مغلق: بلا ربط صحيح صفر صفوف، حتى الصفوف العامة | PASS | T1 وT16c وT28 | قائد قاعدة البيانات | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:138 |
| NFR-SEC-03 | كلمات المرور: Argon2id بصيغة PHC بمعاملات لا تقل عن m=65536 وt=3 وp=4؛ tp_app لا يقرأ التجزئة | CHECK في القاعدة، ونتيجة الحالات | T33 وT35، ومراجعة كود | مهندس الأمن | docs/adr/0002-login-and-session-bound-context.md:14-15 |
| NFR-SEC-04 | سياسة كلمة المرور: 12 خانة افتراضيًا وحد المنصة 10، ومنع المسرَّب وآخر 5 (القيم في DOC-S04) | نتيجة السيناريو | AC-PLT-10 | مهندس الأمن | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:230 |
| NFR-SEC-05 | القفل: 5 إخفاقات خلال 15 دقيقة تقفل 15 دقيقة؛ القفل الثالث خلال 24 ساعة يحتاج المدير | PASS | T34 وAC-PLT-2 | مهندس الأمن | db/static/030_session_context.sql:90-98 |
| NFR-SEC-06 | MFA: TOTP إلزامي؛ لا ربط قبل تسجيل نتيجته؛ 10 رموز استرداد لمرة واحدة | PASS | T36 وAC-PLT-2؛ مستخدم MfaEnabled = 0 يربط اليوم بلا MFA (O-24) | مهندس الأمن | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:113؛ db/static/030_session_context.sql:143 |
| NFR-SEC-07 | الجلسات: خمول 30 دقيقة ومطلقة 12 ساعة؛ الإنهاء والتعطيل يسحبان الربط فورًا | PASS | T25 وT32 وT35 وT37 وAC-PLT-12؛ T35 يمنع tp_app من تمديد المهلة المطلقة، ولا حالة لانقضائها بعد | مهندس الأمن | db/static/030_session_context.sql:116-118 |
| NFR-SEC-08 | لا كشف لوجود الحسابات: خطأ واحد 50005 لكل فشل دخول، ورسالة واجهة واحدة | PASS | T33 وAC-PLT-2 | مهندس الأمن | db/static/030_session_context.sql:140 |
| NFR-SEC-09 | TLS 1.2 حدًا أدنى و1.3 مفضّلًا مع HSTS؛ لا SSLv3 ولا TLS 1.0 أو 1.1 | نتيجة فحص الخادم | فحص TLS آلي بعد كل نشر (DOC-S05) | مهندس البنية التحتية | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:582؛ O-08 (erd_open_items) |
| NFR-SEC-10 | البيانات المقيّدة مشفّرة على مستوى العمود، تُعرض مقنَّعة، وكل كشف مدقَّق؛ tp_readonly لا يقرؤها | PASS | T21 وT23، والقاعدتان R7 وR8 في check_grants.py، وAC-PTY-1 | معماري البيانات | X-SEC-2 وX-SEC-3 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:137-138) |
| NFR-SEC-11 | التدقيق للإدراج فقط: tp_app لا يعدّل ولا يحذف؛ سلسلة بصمات في S2 بمرساة خارجية | PASS | T13 إلى T15، والقاعدة R9، وFR-PLT-025 في S2 | مهندس الأمن | X-AUD-1 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:147)؛ O-13 (20-database-design) |
| NFR-SEC-12 | أقل صلاحية في القاعدة: القواعد R1 إلى R10 تمر في كل بناء | خروج الأداة 0 | خطوة CI 3 (tools/ci/db_ci.sh:49) | قائد قاعدة البيانات | docs/20-database-design.md:488 |
| NFR-SEC-13 | حماية التطبيق: OWASP ASVS المستوى 2 هدفًا؛ ملفات ارتباط آمنة بـ SameSite، وCSRF، وCSP، وتقييد المعدل | نتائج قائمة ASVS | DOC-S13، وتفاصيل الضوابط في DOC-S03 | مهندس الأمن | X-SEC-5 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:140)؛ docs/10-detailed-analysis/10-m0-m1-platform-organization.md:585 |
| NFR-SEC-14 | السجلات خالية من أرقام الهويات وكلمات المرور ورموز الجلسات | عدد التطابقات = 0 | مسح آلي لسجلات اختبار القبول بأنماط محظورة 🟡 | مهندس الأمن | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:586 |
| NFR-SEC-15 | الرفع: فحص المحتوى لا الامتداد، حد 25 ميغابايت، فحص البرمجيات الخبيثة قبل الإتاحة | PASS | AC-PLT-15 | قائد التطبيق | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:131 |
| NFR-SEC-16 | الحزم: لا Preview ولا RC، ولا ثغرة معروفة عالية أو حرجة بلا معالجة عند الإصدار 🟡 | نتيجة البوابة وفحص الحزم | بوابة FR-PLT-045 وAC-PLT-4 (DOC-B11) | مهندس DevOps | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:147 |
| NFR-SEC-17 | فصل المهام: المُعِدّ غير المعتمِد، والصلاحيات الحساسة مقفلة على TM وFO | PASS | AC-PTY-1 وسيناريوهات S1-ب | محلل الأعمال | X-SEC-7 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:142)؛ BR-PLT-019 |
| NFR-SEC-18 | اختبار اختراق قبل التجربة، بلا نتيجة حرجة أو عالية مفتوحة | تقرير الاختبار | DOC-S13 وDOC-B12 | مهندس الأمن | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:591 |

المخاطر المتبقية داخل المشترك الواحد مسجلة في O-24 (erd_open_items، tools/dbgen/erd_open_items.py:151-156)، ومنها تعديل tp_app لتجزئة كلمة المرور وعدّادات القفل، وحذف سجلات محاولات الدخول، وربط مستخدم بلا MFA. البند نفسه يطلب إغلاقها بإجراءات قبل كتابة كود الدخول في S0، فتصير معايير قبول لـ NFR-SEC-03 و05 و06 بعد القرار؛ وتحليلها في DOC-S01.

## 6. قابلية التوسع (NFR-SCL)

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-SCL-01 | 300 مشترك 🟡 في قاعدة واحدة دون تقسيم، تفسيرًا لـ«مئات المشتركين» | NFR-PERF-01 عند 300 مشترك اصطناعي | اختبار حجم قبل S5 🟡 | معماري الحلول | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:170 |
| NFR-SCL-02 | 50,000 سجل 🟡 لكل جدول رئيسي لكل مشترك، تفسيرًا لـ«عشرات الآلاف» | حجم مجموعة بيانات الاختبار | مولّد بيانات اصطناعية (DOC-B06) | QA lead | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:167 |
| NFR-SCL-03 | مراقبة نمو aud.AuditLog وwfl.RequestAction وntf.NotificationDelivery، وقرار أرشفة عند 10 ملايين صف 🟡 | عدّ الصفوف شهريًا | تقرير تشغيل | DBA | docs/20-database-design.md:466 |
| NFR-SCL-04 | حدود الباقة الناعمة تنبّه عند 90% ولا تمنع | عدّادات الاستخدام | AC-PLT-7 | مالك المنتج | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:106 |

## 7. إمكانية الوصول (NFR-ACC)

§6.4 يطلب «واجهة تدعم لوحة المفاتيح وقارئات الشاشة بحدود معقولة، وعربية RTL كاملة» (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172). الشق الأول يُفسَّر هنا بمعيار قابل للقياس، والشق الثاني يحسمه قرار اللغة في DQ-B03-1.

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-ACC-01 | WCAG 2.1 المستوى AA 🟡 لشاشات S0 وS1 | صفر مخالفات حرجة أو جسيمة في الفحص الآلي | axe-core ضمن اختبارات Playwright 🟡، ومراجعة يدوية لكل شريحة | مصمم UX | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172 |
| NFR-ACC-02 | كل إجراء في الشاشات ممكن بلوحة المفاتيح، والتركيز ظاهر | قائمة فحص لكل شاشة | يدوي لكل شاشة في DOC-B07 | QA lead | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172 |
| NFR-ACC-03 | لكل حقل تسمية مقروءة، والأخطاء تُعلن لقارئ الشاشة | الفحص الآلي واليدوي | كما في NFR-ACC-01 | مصمم UX | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172 |
| NFR-ACC-04 | الإنجليزية LTR الآن، والتخطيط جاهز لـ RTL دون إعادة بناء | المحليّة التجريبية RTL بلا كسر | AC-PLT-16 | قائد الواجهة الأمامية | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134 |

## 8. التشغيل (NFR-OPS)

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-OPS-01 | سجلات تشغيل مركزية بمعرّف ارتباط واحد للطلب يمر إلى sec.usp_SetSessionContext عبر @CorrelationId | المعرّف نفسه في سجل التطبيق وسجل التدقيق | اختبار تكامل (المواصفة في DOC-S12) | مهندس DevOps | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:173؛ db/static/030_session_context.sql:169 |
| NFR-OPS-02 | تتبّع الأخطاء ولوحة صحة للمشغّل | وجود اللوحة وتغطيتها للمكونات | مراجعة قبل الإطلاق | مدير التشغيل | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:173 |
| NFR-OPS-03 | المهام الخلفية: آخر تشغيل ومدته ونتيجته ظاهرة، وإعادة المحاولة خلال ساعة | شاشة المهام | AC-PLT-20 | قائد التطبيق | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:146 |
| NFR-OPS-04 | الحدث الأمني الفوري يصل مستلمه خلال دقيقة | الفارق بين الحدث والتسليم | AC-NTF-3 | قائد التطبيق | docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:217 |
| NFR-OPS-05 | آخر إصدار GA دائمًا، ومراجعة كل GA جديد خلال 30 يومًا، وتنبيه أسبوعي | سجل الإصدارات وتاريخ المراجعة | AC-PLT-4 | مهندس DevOps | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:147 |
| NFR-OPS-06 | نشر قابل للتكرار من خط واحد: القاعدة بـ deploy.sh والترحيلات المرقّمة | نجاح النشر على قاعدة جديدة وعلى نسخة الإصدار السابق | DOC-B11 | مهندس DevOps | docs/adr/0001-schema-work-on-linux.md:19 |
| NFR-OPS-07 | مزامنة ساعات الخوادم بفارق ≤ 1 ثانية 🟡، لأن القفل والجلسات تُحسب بـ SYSUTCDATETIME وTOTP يُحسب في التطبيق | فارق الساعة عن مصدر الوقت | فحص مراقبة دوري | مهندس DevOps | db/static/030_session_context.sql:56 |

## 9. اللغة والتوطين (NFR-I18N)

| المعرّف | الهدف | طريقة القياس | إجراء الاختبار | المالك | المصدر |
|---|---|---|---|---|---|
| NFR-I18N-01 | الإنجليزية لغة الواجهة الأساس، وكل نص مرئي من ملفات الموارد | صفر نصوص ثابتة | فحص آلي ضمن AC-PLT-16 | قائد الواجهة الأمامية | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134 |
| NFR-I18N-02 | جاهزية RTL بخصائص CSS منطقية، والمحليّة التجريبية RTL لا تكسر أي صفحة | صفر تداخل أو قص | اختبار تخطيط آلي ضمن AC-PLT-16 | قائد الواجهة الأمامية | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134 |
| NFR-I18N-03 | ميلادي مخزَّن، وهجري أم القرى معروض ومدخل في حقول معلَّمة | نتيجة السيناريو | AC-PLT-16 | قائد التطبيق | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:135 |
| NFR-I18N-04 | الوقت مخزَّن UTC ومعروض بتوقيت المشترك، والأرقام 0-9 افتراضيًا | نتيجة السيناريو | AC-PLT-16 | قائد التطبيق | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:136 |
| NFR-I18N-05 | أسماء الكتالوجات بلغتين | كل كتالوج يحمل الاسمين | فحص النموذج 🟡 | قائد قاعدة البيانات | X-DAT-6 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:160) |
| NFR-I18N-06 | البحث العربي بالتطبيع، وترتيب القاعدة Arabic_100_CI_AS_SC، ومقارنة ثنائية حيث تلزم حساسية الحالة | نتيجة البحث والمقارنة | AC-PTY-4 | قائد قاعدة البيانات | db/deploy.sql:18؛ docs/adr/0002-login-and-session-bound-context.md:20 |
| NFR-I18N-07 | لغة الإشعار: مفضّلة المستخدم ثم لغة المشترك ثم الإنجليزية 🟡 | نتيجة السيناريو | AC-NTF-4 | قائد التطبيق | docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:223 |

## 10. التحقق بحسب الشريحة

| الشريحة | البنود التي تُثبت قبل الخروج |
|---|---|
| S0 | NFR-SEC-01 إلى 12 و14 و16، NFR-PERF-05 و06، NFR-AVL-03 في بيئة الاختبار، NFR-ACC-01 إلى 04 لشاشات S0، NFR-OPS-01 و03 و05 و06 و07، NFR-I18N-01 إلى 04 |
| S1 | NFR-PERF-02، NFR-SEC-15 و17، NFR-I18N-05 إلى 07، NFR-ACC لشاشات S1 |
| S2 | NFR-PERF-01 و03 و04 و07، NFR-SCL-02، NFR-SEC-11 للسلسلة |
| قبل الإطلاق | NFR-AVL-01 و02، NFR-REC-01 إلى 06 بعد اعتماد الأرقام، NFR-SCL-01 و03، NFR-SEC-13 و18، NFR-OPS-02 و04 |

## 11. القرارات المطلوبة

| المعرّف | السؤال | الافتراض المقترح | من يقرر | ما يعطّله |
|---|---|---|---|---|
| DQ-B03-1 | §6.4 يطلب «عربية RTL كاملة» (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172)، وقرار 2026-10-10 يجعل الإنجليزية الأساس والعربية لاحقًا | قرار مسجَّل ومحسوم: الإنجليزية LTR الآن مع تخطيط جاهز لـ RTL (NFR-ACC-04 وNFR-I18N-01 و02)، والعربية الكاملة إصدار لاحق؛ ويُصحَّح نص السطر 172 | المالك، وقد قرر في 2026-10-10 (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:320) | واجهة S0 |
| DQ-B03-2 | اعتماد RPO ≤ 15 دقيقة وRTO ≤ 4 ساعات | اعتمادهما مع شرط النسخ خارج الخادم، وتثبيتهما بعد أول تمرين استعادة مقاس | المالك مع مدير التشغيل | DOC-S09، الإطلاق، O-14 (20-database-design) |
| DQ-B03-3 | 99.5% مع خادم واحد وRTO 4 ساعات: استعادة كاملة واحدة تتجاوز ميزانية الشهر | الإبقاء على الرقمين، وتسجيل الشهر الذي تقع فيه استعادة كاملة خرقًا معلنًا، ومراجعتهما بعد التمرين | المالك مع مدير التشغيل | NFR-AVL-01 |
| DQ-B03-4 | تفسير «عشرات الآلاف» و«مئات المشتركين» | 50,000 سجل لكل جدول رئيسي لكل مشترك، و300 مشترك | معماري الحلول مع مالك المنتج | NFR-PERF-01، NFR-SCL |
| DQ-B03-5 | نافذة الصيانة | ساعتان أسبوعيًا خارج ساعات العمل بإشعار 48 ساعة | مدير التشغيل | NFR-AVL-02 |
| DQ-B03-6 | معيار إمكانية الوصول | WCAG 2.1 المستوى AA | مالك المنتج | NFR-ACC-01 |
| DQ-B03-7 | سقف التجزئات المتزامنة للدخول | طابور بحد 8 تجزئات متزامنة لكل عقدة تطبيق، يُضبط بعد NFR-PERF-05 | قائد التطبيق مع مهندس الأمن | حجم خادم التطبيق |
| DQ-B03-8 | لغة الرجوع في الإشعار | الإنجليزية (DQ-B02-2) | مالك المنتج | NFR-I18N-07 |
| DQ-B03-9 | بيئة قياس الأداء | بيئة اختبار بموارد خادم الإنتاج نفسها | مدير التشغيل | NFR-PERF |
| DQ-B03-10 | المهل الزمنية الأخرى غير الموثقة (زمن فتح الصفحة الأولى، زمن التصدير) | لا أهداف إضافية الآن، ويُكتفى بـ NFR-PERF-01 | معماري الحلول | لا شيء |

## 12. تعارضات وفجوات في المصادر

1. اللغة: «عربية RTL كاملة» في docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172، و«واجهة ويب RTL عربي/إنجليزي» في السطر 107، والافتراضي القديم «عربية كاملة» في السطر 303، كلها تخالف القرار في السطر 320 وFR-PLT-032 (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134). وكذلك docs/01-preliminary-analysis.md:333 («اللغة: عربية RTL») وFR-NTF-024 الذي يرجع إلى العربية (docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:223).
2. RPO/RTO: تظهر قيمًا في docs/10-detailed-analysis/00-overview-and-cross-cutting.md:169 وdocs/10-detailed-analysis/10-m0-m1-platform-organization.md:590، بينما تقول docs/20-database-design.md:463 إنها لم تُحدَّد، وتسجلها O-14 في السطر 540.
3. تصادم المعرّف O-14: في docs/20-database-design.md:542 هو أرقام RPO/RTO، وفي tools/dbgen/erd_open_items.py:98-101 هو خطة الشرائح. هذه الوثيقة تقصد الأول.
4. docs/10-detailed-analysis/00-overview-and-cross-cutting.md:170 يفترض «مئات المشتركين»، وdocs/20-database-design.md:466 يفترض حملًا منخفضًا دون رقم؛ لا تعارض، لكن لا رقم معتمدًا في أي منهما.
5. لا يوجد هدف رقمي للتزامن غير اختبار الحجز (docs/20-database-design.md:241)، ولا هدف لحجم البيانات، قبل هذه الوثيقة.
6. docs/30-readiness-documents.md:355 يذكر أن 00-overview يقول «ويندوز» في السطرين 126 و226؛ النص الحالي فيهما يطابق ADR 0001، كما تقول ملاحظة التحقق في السطر 357.

## 13. التتبع

| البند في هذه الوثيقة | المتطلب أو القاعدة أو القرار | المصدر |
|---|---|---|
| §2 | §6.4 الأداء، اختبار التزامن، FR-INS-019 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:167؛ docs/20-database-design.md:241؛ docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md:128 |
| §3 | §6.4 التوفر، ADR 0001 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:168؛ docs/adr/0001-schema-work-on-linux.md:16 |
| §4 | §6.4 التعافي، O-14 (20-database-design) | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:169؛ docs/20-database-design.md:457-463، 542 |
| §5 | X-SEC-1 إلى 7، X-AUD-1، ADR 0002، DOC-S14 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:134-150؛ docs/adr/0002-login-and-session-bound-context.md؛ docs/30-readiness-documents.md:314-320 |
| §6 | §6.4 قابلية التوسع، FR-PLT-004 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:170؛ docs/10-detailed-analysis/10-m0-m1-platform-organization.md:106 |
| §7، §9 | §6.4 إمكانية الوصول، FR-PLT-032 إلى 034، Q-PLT-05 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:172، 320؛ docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134-136 |
| §8 | §6.4 قابلية الدعم، FR-PLT-044، FR-PLT-045، FR-NTF-018 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:173؛ docs/10-detailed-analysis/10-m0-m1-platform-organization.md:146-147؛ docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:217 |
| DQ-B03-1 | قرار اللغة 2026-10-10 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:320؛ docs/10-detailed-analysis/90-consolidated-open-questions.md:15 |
