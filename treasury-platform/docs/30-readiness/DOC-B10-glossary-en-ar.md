# DOC-B10 — المسرد ثنائي اللغة (English / العربية)

| البند | القيمة |
|---|---|
| المعرّف | DOC-B10 (docs/30-readiness-documents.md) |
| الإصدار | 0.1 — مسودة للمراجعة — 2026-10-12 |
| المالك المقترح | محلل الأعمال (BA) مع مراجع المصطلحات |
| الأولوية | P0 قبل S0 لمصطلحات شاشات S0 وملفات الموارد |
| يغطي | FR-PLT-032، X-DAT-6، D-13 |
| يعتمد على | DOC-B07 (الشاشات)، DOC-F07 (حالات الاستخدام)، DOC-F08 (حالات الطلب) |
| المصادر | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:71-99، المسارد §3 في docs/10-detailed-analysis/10…14، docs/21-data-dictionary.md، db/model/10-platform.model |

## 1. الغرض والنطاق

يثبّت المسرد الاسم الإنجليزي لكل مصطلح تعرضه شاشات S0 ورسائلها، ومقابله العربي، والصيغ التي تُتجنَّب، قبل كتابة ملفات الموارد.

- 🟢 الإنجليزية لغة الواجهة الأساس، والعربية تُضاف لاحقًا بملفات الموارد (FR-PLT-032، قرار 2026-10-10).
- 🟢 «موافقة» للإجراء الإداري، و«اعتماد مستندي (LC)» للخطاب؛ ولا يُستعمل «اعتماد» وحده إلا حيث لا لبس (D-13، docs/10-detailed-analysis/00-overview-and-cross-cutting.md:96).
- الأسماء البرمجية (الجداول والأعمدة والرموز) تبقى كما في المستودع ولا تُترجم.
- المصطلح الإنجليزي هو الأساس في الكود ومفاتيح الموارد؛ والعربي للعرض فقط.
- 🟡 تعني اقتراحًا يحتاج اعتمادًا (§10).
- اختصارات المسارات: «00» = docs/10-detailed-analysis/00-overview-and-cross-cutting.md، و«10-m0-m1» و«12-m5» و«13-m6» و«14-m7-m8» = الملفات المقابلة في docs/10-detailed-analysis/، و«20-database-design» = docs/20-database-design.md.

## 2. المنصة والمشترك

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| Tenant | المشترك | شركة أو مجموعة مشتركة في المنصة ببيانات معزولة | plat.Tenant؛ SCR-PLT-52…54 | 🟡 لا يُستعمل Subscriber ولا Customer ولا Client في الواجهة؛ وفي بوابة المشترك يُعرض اسم المشترك لا كلمة Tenant |
| Subscription | الاشتراك | علاقة المشترك بالمنصة بباقة ووحدات | plat.Plan | لا يُستعمل بمعنى الفوترة؛ لا فوترة الآن |
| Plan | الباقة | حزمة وحدات وحدود ناعمة | plat.Plan؛ SCR-PLT-52 | يُتجنَّب «الخطة» |
| Module | الوحدة | حزمة وظائف تُفعَّل لكل مشترك برمز ModuleCode | plat.TenantModule؛ SCR-PLT-54 | يُتجنَّب «التطبيق» و«النظام الفرعي» |
| Soft limit | الحد الناعم | حد للباقة ينبّه ولا يمنع | SCR-PLT-52 | لا يُخلط بحد التسهيل (Limit) |
| Platform operator | مشغّل المنصة | موظف المنصة بهوية منفصلة عن مستخدمي المشترك | plat.PlatformOperator | يُتجنَّب «مسؤول المشغّل» (10-m0-m1:79) و«مدير النظام» |
| Operator console | لوحة المشغّل | واجهة المشغّل المنفصلة عن بوابة المشترك | SCR-PLT-51…56 | كما في FR-PLT-005 وDOC-F01؛ يُتجنَّب «لوحة الإدارة» و«وحدة التحكم» |
| Tenant portal | بوابة المشترك | واجهة مستخدمي المشترك على عنوانه الفرعي | SCR-PLT-01…16 | — |
| Sub-domain | العنوان الفرعي | `{tenant}.bankfas.com` لكل مشترك | plat.Tenant.Code؛ SCR-PLT-53 | يُتجنَّب «النطاق الفرعي» لأن «النطاق» يُستعمل لنطاق الشركات |
| Trial · Active · Suspended · Closed · Archived (read-only) | تجريبي · فعّال · معلّق · مغلق · مؤرشف (قراءة فقط) | حالات المشترك | plat.Tenant.Status | «مغلق» للمشترك؛ و«إقفال» محجوز لإقفال الطلب (§7) |
| Extend trial | تمديد التجربة | تأجيل TrialEndsOn بيد المشغّل | SCR-PLT-52 | — |
| Tenant onboarding | تهيئة المشترك | إنشاء المشترك وبذره ودعوة مديره الأول في معاملة واحدة | UC-PLT-02 | يُتجنَّب «تأهيل» (00:194) |
| Seed | البذرة | بيانات افتراضية تُزرع عند التهيئة وتُعلَّم بـ SeedKey | cfg.SeedRun؛ SCR-PLT-54 | — |
| Onboarding checklist | قائمة البدء | خطوات مدير الحساب الأولى بنسبة إنجاز | SCR-PLT-06 | — |
| Support access | وصول الدعم | دخول مؤقت للمشغّل بإذن مدير الحساب وتحت التدقيق | plat.SupportAccessGrant؛ SCR-PLT-11 | Break-glass في الوثائق فقط لا في الواجهة |
| Global references | المراجع العالمية | قوائم يملكها المشغّل ويقرؤها كل المشتركين | ref.Country، ref.Currency؛ SCR-PLT-55 | — |

## 3. الهوية والدخول والجلسات

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| Sign in · Sign out | تسجيل الدخول · تسجيل الخروج | بدء الجلسة وإنهاؤها | SCR-PLT-01؛ القشرة | يُتجنَّب Log in وLogon في الواجهة |
| Email | البريد الإلكتروني | معرّف الدخول الفريد في المشترك | sec.AppUser.Email | — |
| Password | كلمة المرور | سر المستخدم، يُخزَّن تجزئة Argon2id | sec.AppUser.PasswordHash | يُتجنَّب «الرقم السري» |
| Two-step verification | التحقق بخطوتين | تسمية المستخدم للمصادقة متعددة العوامل | SCR-PLT-02، SCR-PLT-04 | 🟡 في شاشات المستخدم؛ وفي شاشات الإدارة MFA |
| Multi-factor authentication (MFA) | المصادقة متعددة العوامل | كلمة مرور ثم رمز TOTP | sec.AppUser.MfaEnabled؛ SCR-PLT-07 | — |
| Authenticator app | تطبيق المصادقة | تطبيق يولّد رموز TOTP | SCR-PLT-04 | لا يُذكر اسم منتج بعينه |
| Verification code | رمز التحقق | الرمز المكوّن من 6 أرقام من تطبيق المصادقة | SCR-PLT-02 | يُتجنَّب OTP في الواجهة |
| Recovery code | رمز الاسترداد | واحد من 10 رموز تُستعمل مرة واحدة بدل TOTP | sec.MfaRecoveryCode؛ SCR-PLT-02، 04، 15 | يُتجنَّب Backup code |
| Reset MFA | إعادة تعيين MFA | إلغاء تسجيل MFA وإجبار المستخدم على التسجيل من جديد | SCR-PLT-07 | — |
| Invitation | الدعوة | رابط لمرة واحدة صالح 48 ساعة لتفعيل حساب | sec.UserToken (INVITATION)؛ SCR-PLT-04 | — |
| Reset password | إعادة تعيين كلمة المرور | رابط لمرة واحدة صالح 30 دقيقة | sec.UserToken (PASSWORD_RESET)؛ SCR-PLT-03 | يُتجنَّب «استعادة كلمة المرور» لأن الكلمة لا تُستعاد |
| Lockout · Locked · Unlock | قفل الحساب · مقفل · فك القفل | منع الدخول بعد 5 محاولات فاشلة خلال 15 دقيقة | sec.AppUser.Status؛ SCR-PLT-07 | يُتجنَّب Blocked و«محظور»؛ ولا تُعرض «مقفل» في شاشة الدخول |
| Session | الجلسة | فترة دخول برمز يحمله المتصفح | sec.UserSession؛ SCR-PLT-08، 15 | — |
| Idle timeout · Absolute timeout | مهلة الخمول · المهلة المطلقة | 30 دقيقة بلا نشاط · 12 ساعة من الدخول | sec.UserSession | — |
| End sessions | إنهاء الجلسات | إنهاء كل جلسات مستخدم بيد المدير | SCR-PLT-07 | يُتجنَّب Kill وTerminate في الواجهة |
| Re-authenticate | إعادة المصادقة | إدخال كلمة المرور وMFA قبل فعل حساس | SCR-PLT-13 | — |
| Single sign-on (SSO) | الدخول الموحّد | ربط هوية خارجية (لاحقًا) | sec.ExternalIdentity | S5 |

## 4. المستخدمون والأدوار والصلاحيات

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| User | المستخدم | حساب في بوابة المشترك | sec.AppUser؛ SCR-PLT-07 | — |
| Invited · Active · Locked · Disabled · Archived | مدعو · فعّال · مقفل · معطّل · مؤرشف | حالات المستخدم | sec.AppUser.Status | — |
| Service account | حساب الخدمة | حساب للمهام الخلفية بلا دخول تفاعلي | sec.AppUser.IsSystemUser | لا يظهر في قائمة المستخدمين 🟡 |
| Tenant administrator (TA) | مدير حساب المشترك | يدير المستخدمين والأدوار والإعدادات | دور نظام؛ SCR-PLT-08 | 🟡 يُتجنَّب Account administrator (db/model/10-platform.model:98) في الواجهة لأن Account تعني الحساب البنكي؛ و«مدير الحساب» وحده (DOC-F01 يستعمله) قد يُفهم مدير حساب لدى البنك |
| Treasury manager (TM) | مدير الخزينة | رئيس الخزينة؛ يحمل الصلاحيات المقفلة | دور نظام | — |
| Facilities officer (FO) | مسؤول التسهيلات | موظف الخزينة المسؤول عن التسهيلات؛ يحمل الصلاحيات المقفلة | دور نظام | — |
| Treasury employee (TE) | موظف الخزينة | منفّذ الطلبات | دور نظام | — |
| Auditor (AU) | المدقق | عرض فقط | دور نظام | لا يُخلط بدور «مدقّق» في دورة العمل (§7) |
| Role · System role · Custom role | الدور · دور نظام · دور مخصص | مجموعة صلاحيات؛ المبذور نظام والمنشأ مخصص | sec.Role.IsSystem؛ SCR-PLT-09 | — |
| Permission | الصلاحية | إذن دقيق برمز مثل `party.identity.reveal` | sec.Permission؛ SCR-PLT-09 | 🟡 تُحصر «صلاحية» في هذا المعنى؛ انظر Authority grant |
| Sensitive permission | صلاحية حساسة | إسنادها يُدقَّق بشدة عالية ويُشعر المديرين | sec.Permission.IsSensitive | — |
| Locked permission | صلاحية مقفلة | لا تُسند منصةً إلا لدوري TM وFO | sec.Permission.LockedToRoleCodes؛ SCR-PLT-09 | الرمز PERMISSION_LOCKED |
| Effective permissions | الصلاحيات الفعلية | اتحاد صلاحيات أدوار المستخدم | SCR-PLT-08 | لا صلاحية «منع» |
| Company scope · All · Selected | نطاق الشركات · الكل · مختارة | الشركات التي يرى المستخدم بياناتها | sec.UserCompanyScope؛ SCR-PLT-10 | يُتجنَّب «الصلاحية على الشركات» |
| Include subsidiaries | تضمين التابعات | يمتد النطاق إلى الشركات التابعة | sec.UserCompanyScope.IncludeDescendants | — |
| Company switcher | مبدّل الشركة | يضيّق العرض إلى شركة من النطاق ولا يوسّعه | القشرة (DOC-B07 §4.4) | — |
| Department | الإدارة | وحدة تنظيمية في المشترك | org.Department | يُتجنَّب «القسم» للتمييز عن أقسام البنك |
| Line manager | المدير المباشر | يُستعمل لتحديد «المدير» في الموافقات | sec.AppUser.LineManagerUserId | — |

## 5. الإعدادات والترقيم والتدقيق والمستندات

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| Settings · Security settings | الإعدادات · إعدادات الأمان | قيم المشترك ضمن حدود المنصة | cfg.TenantSetting؛ SCR-PLT-11 | — |
| Work hours (start · end) | ساعات العمل (البداية · النهاية) | نافذة حساب SLA والتذكير | `work.start`، `work.end` | — |
| Re-mask delay | مدة إعادة الإخفاء | ثوانٍ قبل عودة القناع بعد الكشف | cfg.TenantSetting | — |
| Number series · Numbering | سلسلة الترقيم · الترقيم | تعريف صيغة ترقيم لنوع مستند | cfg.NumberSequenceDefinition؛ SCR-PLT-12 | يُتجنَّب «العدّاد» في الواجهة |
| Pattern · Preview | الصيغة · المعاينة | قالب بوسوم مثل `{seq:000}-{erp}-{yy}` | SCR-PLT-12 | — |
| Issued number · Void | رقم صادر · إلغاء (ملغى) | الرقم الملغى بسبب لا يُعاد | cfg.NumberIssue.Status | يُتجنَّب Delete number و«حذف» |
| Gap-free | بلا فجوات | لا رقم متروك إلا بإلغاء موثَّق | GapPolicy | معناه قرار مفتوح O-12 (erd_open_items) |
| Audit log · Audit event | سجل التدقيق · حدث تدقيق | سجل للإدراج فقط لكل فعل مهم | aud.AuditLog؛ SCR-PLT-13 | يُتجنَّب «سجل المراجعة» و«اللوغ» |
| Severity: Info · High | الشدة: عادية · عالية | تصنيف الحدث | aud.AuditLog.Severity | — |
| Actor | الفاعل | من نفّذ الفعل: مستخدم أو مشغّل أو نظام أو مهمة | aud.AuditLog.ActorType | — |
| Reveal · Mask · Masked | الكشف · القناع · مقنَّع | إظهار القيمة الكاملة بصلاحية / عرض آخر 4 خانات | BR-PTY-008، BR-PTY-009 | زر الواجهة Show؛ والحدث IDENTITY_REVEAL |
| Background job | مهمة خلفية | عمل مجدول بإعادة محاولة وسجل تشغيل | cfg.JobRun؛ SCR-PLT-14 | — |
| Document · Document type · Version | المستند · نوع المستند · الإصدار | مستند منطقي بإصدارات ثابتة | doc.Document، doc.DocumentVersion؛ SCR-PLT-16 | يُتجنَّب «المرفق» للمستند المنطقي |
| Upload · Download · Preview | رفع · تنزيل · معاينة | عبر نقطة مصرَّحة فقط | SCR-PLT-16 | — |
| Quarantined | محجور | ملف مشبوه لا يُنزَّل | doc.DocumentVersion.ScanStatus | — |
| Data export | تصدير البيانات | حزمة مختومة بطلب مدير الحساب | cfg.DataExportJob | S5 |
| Retention · Disposal | الاحتفاظ · الإتلاف | مدة الحفظ ثم الإتلاف بموافقة | FR-PLT-040 | لا حذف تلقائي |
| Hijri · Gregorian | هجري (أم القرى) · ميلادي | التخزين ميلادي والعرض هجري عند الطلب | plat.Tenant.CalendarDisplay | — |

## 6. الهيكل المؤسسي والأشخاص (M1)

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| Company | الشركة | منشأة قانونية داخل المشترك | org.Company | يُتجنَّب «المنشأة» لأنها للمنشأة المالية |
| Legal form | الشكل القانوني | كتالوج LegalEntityType | cat.LegalEntityType | — |
| Holding · Parent company · Subsidiary | قابضة · الشركة الأم · تابعة | علم مستقل عن الشكل؛ وشجرة الهرم | org.Company.IsHolding | — |
| Shareholding · Ownership change | حصة الملكية · تغيير الملكية | حصة بفترة سريان؛ معالج يغلق ويفتح | org.Shareholding | — |
| Governing body · Position | هيئة الحوكمة · المنصب | مجلس أو إدارة أو جمعية؛ ومنصب العضو | org.GoverningBody، org.BodyMember | — |
| Authority grant | منحة تفويض 🟡 | من يخوَّل نظاميًا بنوع صلاحية وسقف وتوقيع مشترك وفترة | org.AuthorityGrant | الوثائق تقول «منح الصلاحية» (10-m0-m1:88)؛ يُقترح «تفويض» لفصلها عن Permission |
| Power type | نوع التفويض 🟡 | توقيع عقود، اقتراض، ضمانات… | cat.PowerType | الوثائق تقول «نوع الصلاحية» (10-m0-m1:178) |
| Party | الشخص أو الجهة | فرد أو جهة اعتبارية يُعاد استخدامه | pty.Party | يُتجنَّب «العميل» و«الطرف» وحده |
| Identity document · Primary document | وثيقة الهوية · الوثيقة الأساسية | وثيقة برقم مشفَّر؛ والأساسية بحسب الجنسية والإقامة | pty.IdentityDocument | — |
| Mirror party | الجهة المرآة | Party تُنشأ آليًا لكل شركة وتبقى للقراءة | org.Company.PartyId (الرابط الوحيد، DR-24) | — |
| Usage provider | مزوّد الاستخدام | واجهة تكشف أدوار الشخص المشتقة | BR-PTY-001 | «الاستخدام» محجوز لهذا المعنى؛ انظر Utilisation |
| Merge | الدمج | توحيد شخصين مكرَّرين | UC-PTY-06 | — |
| KYC profile · Completeness | ملف الاكتمال (KYC) · الاكتمال | ما يطلبه بنك عن شخص بدور معيّن | pty.KycProfile | — |
| Guarantor pack | حزمة بيانات الكفيل | PDF كامل أو مسودة مقنَّعة | UC-PTY-12 | — |

## 7. المجال الأساسي (التسهيلات والاعتمادات والطلبات)

| English term | المصطلح العربي | التعريف | أين يُستعمل | ملاحظة وما يُتجنَّب |
|---|---|---|---|---|
| Financial institution | المنشأة المالية | بنك أو شركة تمويل أو ممول | ins.Institution | — |
| Relationship · Relationship manager (RM) | العلاقة · مدير العلاقة | ارتباط شركة بمنشأة؛ ومسؤول البنك عنها | ins.Relationship | لا يُخلط بـ RQM (مدير مقدّم الطلب) |
| Bank account | الحساب البنكي | حساب الشركة لدى المنشأة | acc.BankAccount | «Account» في الواجهة يعني هذا وحده |
| Signatory | المفوَّض | شخص مخوَّل لدى بنك عن شركة | acc.Signatory | تُوحَّد الكتابة «المفوَّض» بدل «المفوّض» |
| Facility | التسهيل | حزمة اتفاقية ائتمانية | fac.Facility | — |
| Limit · Product line | الحد · خط المنتج | جزء من التسهيل؛ وسطر منتج داخل الحد | fac.Limit، fac.LimitProductLine | — |
| Reservation | الحجز | تخصيص جزء من الحد لطلب | fac.LimitReservation | — |
| Utilisation | الاستغلال 🟡 | ما يستهلك الحد فعليًا (يدوي أو من اعتماد صادر) | fac.Utilization | يُتجنَّب «الاستخدام» (12-m5:86) لتعارضه مع مزوّد الاستخدام |
| Exposure amount | مبلغ التعرّض | المبلغ الوحيد الممرَّر لخدمات الحدود | ExposureAmount | — |
| Available | المتاح | السقف ناقص المستغَل والمحجوز | لوحة توفر الحدود | — |
| Pricing · Tariff | التسعير · التعرفة | شروط السعر؛ وجدول رسوم البنك | fac، prc | — |
| Collateral · Guarantee · Guarantor | الضمان · الكفالة · الكفيل | ضمان للتسهيل؛ والكفالة نوع منه؛ والكفيل Party | col.Collateral، col.Guarantee | — |
| Promissory note | السند لأمر | ضمان بسند وموقّعيه | col.PromissoryNote | — |
| Covenant · Obligation | التعهد · الالتزام | التزام قابل للقياس؛ والالتزام أعم | obl.Covenant، obl.Obligation | — |
| Letter of credit (LC) | الاعتماد المستندي (LC) | الخطاب نفسه | lc.LetterOfCredit | لا يُكتب «اعتماد» وحده إلا حيث لا لبس (D-13) |
| Approval · Approver | الموافقة · الموافِق | الإجراء الإداري ومن يقوم به | wfl.RequestApproval | 🟡 يُفضَّل «الموافِق» على «المعتمِد» في شاشات الاعتمادات |
| Drawing | السحب على الاعتماد 🟡 | تقديم مستندات بمبلغ تحت اعتماد | lc.LcDrawing | «السحب» وحده يتعارض مع Claim (14-m7-m8:95 و13-m6:93) |
| Request · Requester | الطلب · مقدّم الطلب | سجل عمل للخزينة؛ وصاحبه | wfl.Request | «الجهة الطالبة» للإدارة لا للشخص |
| Workflow template · Stage | قالب دورة العمل · المرحلة | مراحل الطلب وانتقالاتها | wfl.WorkflowTemplate، wfl.WorkflowStage | — |
| External phase | المرحلة الظاهرة | ما يراه مقدّم الطلب | wfl.ExternalPhase | يُتجنَّب «الحالة الظاهرة» (00:92) |
| Sub-status | الحالة الفرعية | حالة الخزينة داخل المرحلة | wfl.Request.SubStatusKey | — |
| Claim (from queue) | الاستلام من الطابور 🟡 | أخذ طلب من طابور الخزينة | `req.claim` | «السحب» محجوز لـ Drawing |
| Reviewer (workflow) | المراجِع 🟡 | دور «مدقّق» في دورة العمل بين المنشئ والمعتمِد | WorkflowRole = AUDITOR | لا يُخلط بدور Auditor (AU) |
| Request status: Draft · Active · Awaiting close · Completed · Rejected · Cancelled | مسودة · قيد المعالجة · بانتظار الإقفال · مكتمل · مرفوض · ملغى | حالة دورة الطلب الداخلية | wfl.Request.Status | DOC-F08 |
| Close (request) | إقفال الطلب | إكمال الطلب بيد إدارة الخزينة | `req.treasury.close` | «إقفال» للطلب وحده؛ و«إغلاق» للمشترك والاعتماد |
| In progress | تحت الإجراء | المرحلة الظاهرة IN_PROGRESS | wfl.ExternalPhase | يُتجنَّب «قيد التنفيذ» (20-database-design:406) |

## 8. رسائل S0

المفاتيح مقترحة 🟡 بنمط `<area>.<item>`. النص الإنجليزي هو المرجع. رموز الأخطاء (V-PLT-nn وPERMISSION_LOCKED وغيرها) يملكها DOC-B04 وتبقى أسماؤها البرمجية كما هي، ومنها LAST_ACCOUNT_ADMIN مع أن الواجهة تقول tenant administrator.

| المفتاح | English | العربية | المصدر |
|---|---|---|---|
| `auth.invalid_credentials` | Invalid email or password. | البريد الإلكتروني أو كلمة المرور غير صحيحة. | FR-PLT-012؛ الخطأ 50005 |
| `auth.code_invalid` | The verification code is not valid. Try again. | رمز التحقق غير صالح. حاول مرة أخرى. | FR-PLT-011 |
| `auth.recovery_used` | Recovery code accepted. You have {n} codes left. | قُبل رمز الاسترداد. بقي لديك {n} رموز. | BR-PLT-006 |
| `auth.link_invalid` | This link is no longer valid. Ask for a new one. | هذا الرابط لم يعد صالحًا. اطلب رابطًا جديدًا. | FR-PLT-013؛ V-PLT-06 |
| `auth.reset_sent` | If this email is registered, we have sent a reset link. | إن كان البريد مسجّلًا فقد أرسلنا رابط إعادة التعيين. | FR-PLT-013 |
| `auth.session_expired` | Your session has ended. Please sign in again. | انتهت جلستك. سجّل الدخول من جديد. | FR-PLT-014 |
| `auth.password_weak` | This password is too short or too common. | كلمة المرور قصيرة أو شائعة. | BR-PLT-004؛ V-PLT-04 |
| `auth.password_reused` | You cannot reuse one of your last 5 passwords. | لا يمكن استعمال إحدى كلمات المرور الخمس الأخيرة. | BR-PLT-004؛ V-PLT-05 |
| `users.last_admin` | You cannot disable the last active tenant administrator. | لا يمكن تعطيل آخر مدير حساب مشترك فعّال. | FR-PLT-016؛ LAST_ACCOUNT_ADMIN |
| `roles.permission_locked` | This permission is locked to the Treasury manager and Facilities officer roles. | هذه الصلاحية مقفلة على دوري مدير الخزينة ومسؤول التسهيلات. | BR-PLT-019؛ PERMISSION_LOCKED |
| `settings.below_minimum` | The value is weaker than the platform minimum ({min}). | القيمة أضعف من الحد الأدنى للمنصة ({min}). | BR-PLT-018؛ V-PLT-08 |
| `common.forbidden` | You do not have permission for this action. | لا تملك صلاحية هذا الإجراء. | FR-PLT-021 (403) |
| `common.not_found` | The item was not found. | لم يُعثر على العنصر. | FR-PLT-021 (404) |
| `common.read_only` | Your organisation is in read-only mode. | بيانات جهتك متاحة للقراءة فقط. | BR-PLT-002؛ TENANT_READ_ONLY |
| `common.module_disabled` | This module is not enabled for your organisation. | هذه الوحدة غير مفعّلة لجهتك. | FR-PLT-003؛ MODULE_DISABLED |

## 9. قواعد ملفات الموارد

- مفتاح واحد لكل مصطلح، ولا يُكرَّر النص نفسه بمفاتيح مختلفة 🟡.
- تهجئة إنجليزية واحدة في الواجهة: البريطانية 🟡 (organisation، utilisation)، والمعرّفات البرمجية تبقى كما هي (Utilization) (DQ-B10-9).
- قيم الحالات تُعرض من جدول تحويل للتعداد (enum) لا من النص الخام في القاعدة.
- كل اسم في الكتالوجات بلغتين (X-DAT-6)، والإنجليزي هو المعروض الآن.
- لا رسالة تكشف وجود بريد أو مشترك أو سبب رفض الدخول (FR-PLT-012، FR-PLT-046).
- لا رقم هوية ولا قيمة مقيّدة في أي نص رسالة أو إشعار (BR-PLT-009).
- المصطلحات المقترحة 🟡 لا تدخل ملف الموارد قبل اعتمادها (§10).

## 10. القرارات المطلوبة

| المعرّف | السؤال | الافتراض المقترح | من يقرر | ما يعطّله |
|---|---|---|---|---|
| DQ-B10-1 | الاسم الإنجليزي لدور TA | ✅ معتمد من المالك (2026-10-12): Tenant administrator، والعربي «مدير حساب المشترك» | مالك المنتج | بذور الأدوار، SCR-PLT-08 |
| DQ-B10-2 | المقابل العربي لـ Utilisation | «الاستغلال»، و«الاستخدام» لمزوّد الاستخدام وحده | مراجع المصطلحات مع مالك M5 | واجهات S2 |
| DQ-B10-3 | المقابل العربي لـ Authority grant وPower type | «منحة تفويض» و«نوع التفويض»، و«صلاحية» لـ Permission وحده | مراجع المصطلحات مع مالك M1 | واجهات S1-ب |
| DQ-B10-4 | المقابل العربي لـ Claim وDrawing | «الاستلام من الطابور» و«السحب على الاعتماد» | مراجع المصطلحات مع مالكي M6 وM7 | واجهات S3 |
| DQ-B10-5 | الاسم الإنجليزي لدور «مدقّق» في دورة العمل | Reviewer في الواجهة، والقيمة البرمجية AUDITOR كما هي | مالك M6 | محرر القوالب |
| DQ-B10-6 | إلزام NameEn حيث يُعرض الاسم | NameEn إلزامي لكل كتالوج يُعرض في الواجهة الإنجليزية | معماري البيانات | البذور (DOC-B05) |
| DQ-B10-7 | مصطلحات الواجهة للمصادقة | Two-step verification للمستخدم، وMFA في شاشات الإدارة | UX lead | SCR-PLT-02، 07 |
| DQ-B10-8 | من يراجع النص العربي قبل إضافته | مراجع مصطلحات يسمّيه العميل، ويُوثَّق في DOC-B09 | مدير المشروع | ملفات الموارد العربية |
| DQ-B10-9 | تهجئة الإنجليزية في الواجهة | ✅ معتمد من المالك (2026-10-12): البريطانية، مع إبقاء المعرّفات البرمجية | مالك المنتج | ملفات الموارد |

## 11. تعارضات وفجوات في المصادر

1. Utilization مترجمة «الاستخدام» في 12-m5 (docs/10-detailed-analysis/12-m5-facilities-pricing-collateral-obligations.md:86، :123) و«الاستغلال» في 14-m7-m8 (docs/10-detailed-analysis/14-m7-m8-letters-of-credit.md:32) و13-m6 (:344)؛ و«الاستخدام» نفسه يعني مزوّد الاستخدام في PTY (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:91).
2. «صلاحية» تعني Permission (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:119) وتعني أيضًا التفويض النظامي في «منح الصلاحية» (:88) و«نوع الصلاحية» (:178) و«صلاحية المفوّض» (docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md:87).
3. «السحب» تعني Claim (docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:93) وتعني Drawing (docs/10-detailed-analysis/14-m7-m8-letters-of-credit.md:95).
4. «مدقق» دور قراءة AU (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:41) ودور في دورة العمل بقيمة AUDITOR (docs/21-data-dictionary.md:4588، docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:162).
5. TA «مدير الحساب» (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:41) و«مدير حساب المشترك» (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:58)، وبالإنجليزية account administrator (db/model/10-platform.model:98، tools/dbgen/erd_open_items.py:117)، وكلمة Account تعني الحساب البنكي في ACC.
6. ExternalPhase «الحالة الظاهرة» (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:92) و«المرحلة الظاهرة» (docs/10-detailed-analysis/13-m6-workflow-engine-notifications.md:89).
7. ✅ وُحّدت: IN_PROGRESS «تحت الإجراء» في المواصفة 13 ووثيقة التصميم، ومنها حالة AWAITING_CLOSE (DQ-F08-5، DQ-F08-9). التفصيل في DOC-F08.
8. «تأهيل مشترك جديد» (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:194) و«تهيئة المشترك» (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:405، docs/20-database-design.md:475).
9. «مسؤول المشغّل» (docs/10-detailed-analysis/10-m0-m1-platform-organization.md:79) مقابل «مشغّل المنصة» في بقية الوثائق.
10. «اعتماد» وحده بمعنى الموافقة، مثل «باعتماد السجل» (docs/10-detailed-analysis/12-m5-facilities-pricing-collateral-obligations.md:457)، خلافًا لـ D-13.
11. T-10 يجعل NameEn اختياريًا في الكتالوجات (docs/20-database-design.md:70)، والواجهة إنجليزية أولًا؛ مثال: cfg.NonWorkingDay بلا اسم إلزامي (db/model/10-platform.model:526-527).
12. نص 00 ما زال يصف الواجهة عربية RTL أولًا (docs/10-detailed-analysis/00-overview-and-cross-cutting.md:107، :172، :303). التفصيل في DOC-B07 §8.

## 12. التتبع

| البند في هذه الوثيقة | المتطلب أو القاعدة أو القرار | المصدر |
|---|---|---|
| §1 اللغة | FR-PLT-032، Q-PLT-05 | docs/10-detailed-analysis/10-m0-m1-platform-organization.md:134، :617 |
| §1 موافقة واعتماد | D-13 | docs/01-preliminary-analysis.md:404؛ docs/10-detailed-analysis/00-overview-and-cross-cutting.md:96 |
| §2 إلى §6 | مسرد 00 ومسرد 10-m0-m1 §3 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:73-99؛ docs/10-detailed-analysis/10-m0-m1-platform-organization.md:71-93 |
| §7 | مسارد 11 إلى 14 §3 | docs/10-detailed-analysis/11-m2-m4-institutions-accounts-catalogs.md:73؛ 12-m5:77؛ 13-m6:81؛ 14-m7-m8:79 |
| §8 الرسائل | FR-PLT-011…014، FR-PLT-016، FR-PLT-021، BR-PLT-004، BR-PLT-018، BR-PLT-019 | db/static/030_session_context.sql:140 |
| §9 | X-DAT-6، BR-PLT-009 | docs/10-detailed-analysis/00-overview-and-cross-cutting.md:160 |
