// Arabic messages (right-to-left interface). Keys mirror en.ts.
import type { Messages } from "./en";

const ar: Messages = {
  app: { passenger: "مسلك", driver: "مسلك للسائقين" },
  city: {
    ALP: "حلب", AMM: "عمّان", BEY: "بيروت", DAM: "دمشق", DRA: "درعا", DRZ: "دير الزور", HMA: "حماة",
    HMS: "حمص", HSK: "الحسكة", IDL: "إدلب", LTK: "اللاذقية", QNT: "القنيطرة", RDM: "ريف دمشق", RQA: "الرقة",
    SWD: "السويداء", TRT: "طرطوس",
  },
  extra: { booked: "تم الحجز · {ref}", seatsChosen: "اخترت {n} من {max} مقاعد", stops: "{n} محطات", direct: "مباشر",
           ticketStatus: { ISSUED: "صالحة", BOARDED: "تم الصعود", CANCELLED: "ملغاة", REFUNDED: "مستردة" },
           noTickets: "لا رحلات اليوم.", trip: "الرحلة {no}", openTicket: "عرض التذكرة" },
  txn: { SHIPMENT_PAY: "إرسال طرد", SUBSCRIPTION_PAY: "اشتراك نقل ترددي", BOOKING_PAY: "حجز رحلة", REFUND: "استرداد", TOPUP: "شحن المحفظة", RELEASE: "تسوية", PAYOUT: "صرف مصرفي" },
  common: {
    signIn: "تسجيل الدخول", signOut: "تسجيل الخروج", email: "البريد أو الجوال", password: "كلمة المرور", continue: "متابعة",
    cancel: "إلغاء", retry: "أعد المحاولة", loading: "جارٍ التحميل…", seat: "المقعد", seats: "المقاعد", total: "الإجمالي",
    from: "من", to: "إلى", date: "التاريخ", passengers: "الركاب", back: "رجوع", save: "حفظ", offline: "دون اتصال",
    online: "متصل", sync: "مزامنة الآن", language: "اللغة", currency: "ل.س",
  },
  security: {
    locked: "مسلك مقفل", unlock: "فتح", unlockPrompt: "افتح تذاكرك ومحفظتك",
    rooted: "يبدو أن هذا الجهاز مكسور الحماية (روت أو جيلبريك)، وحماية تذاكرك ومحفظتك عليه أضعف.",
    driverRooted: "لا يتوفر صعود الركاب على جهاز مكسور الحماية.",
    insecure: "لا يمكن لهذا الإصدار الاتصال بأمان. ثبّت التطبيق الرسمي.",
    noPasscode: "فعّل قفل الشاشة على هذا الجهاز لحماية تذاكرك ومحفظتك.",
  },
  auth: { title: "الدخول إلى مسلك", code: "الرمز من تطبيق المصادقة", verify: "تحقق",
          enrollOnWeb: "فعّل الدخول بخطوتين على الموقع أولاً، ثم سجّل الدخول هنا." },
  tabs: { search: "احجز", trips: "رحلاتي", wallet: "المحفظة", account: "الحساب", today: "اليوم" },
  search: { title: "إلى أين؟", origin: "من", destination: "إلى", date: "تاريخ السفر", find: "ابحث عن رحلة",
            none: "لا توجد رحلات في هذا التاريخ.", seatsLeft: "متبقٍ {n} مقعداً", choose: "اختر" },
  trip: { docNumber: "رقم الوثيقة", passportExpiry: "انتهاء الجواز (صالح حتى {date} على الأقل)", passportNeeded: "رحلة دولية: يلزم جواز سفر صالح لمدة {days} يوماً على الأقل بعد الانطلاق.", docException: "رحلة دولية: يوجد استثناء معتمد يقبل {docs}.", docTypes: { PASSPORT: "جواز سفر", NATIONAL_ID: "هوية وطنية", RESIDENCE: "إقامة", LAISSEZ_PASSER: "وثيقة مرور", TRAVEL_DOCUMENT: "وثيقة سفر", OTHER: "أخرى" }, seats: "اختر مقاعدك", hold: "احجز المقاعد مؤقتاً", held: "المقاعد محجوزة لمدة {t}", front: "الأمام", driver: "السائق",
          passenger: "الراكب {n}", first: "الاسم الأول", father: "اسم الأب", grandfather: "اسم الجد",
          last: "الكنية", nationality: "الجنسية", syrian: "مواطن سوري", otherNationality: "جنسية أخرى",
          namesHint: "كما في وثيقة الهوية. للسوريين: الأسماء الأربعة.", pay: "ادفع {amount} من المحفظة",
          balance: "رصيد المحفظة: {amount}" },
  ticket: { title: "تذكرتك", show: "أظهر هذا الرمز للسائق", offlineReady: "محفوظة على هذا الهاتف: تعمل دون اتصال",
            notSaved: "افتح التذكرة مرة واحدة أثناء الاتصال لحفظها للاستخدام دون اتصال.", valid: "صالحة", boarded: "صعد" },
  trips: { none: "لا توجد رحلات بعد.", upcoming: "القادمة", past: "السابقة" },
  wallet: { balance: "الرصيد", history: "السجل", topup: "إضافة رصيد تجريبي" },
  account: { devices: "الأجهزة المسجلة", thisDevice: "هذا الجهاز", language: "اللغة", english: "الإنكليزية",
             arabic: "العربية", restart: "أعد تشغيل التطبيق لتغيير اتجاه الواجهة." },
  driver: {
    today: "رحلاتك", board: "صعود الركاب", download: "تنزيل للعمل دون اتصال", downloaded: "جاهز دون اتصال · {n} تذكرة",
    scan: "وجّه الكاميرا إلى رمز التذكرة", pending: "{n} عمليات مسح بانتظار المزامنة", synced: "تمت مزامنة كل عمليات المسح",
    boardedCount: "صعد {n} من {total}", camera: "اسمح للكاميرا بمسح التذاكر", allow: "السماح بالكاميرا",
    results: { OK: "صالحة — تفضل بالصعود", DUPLICATE: "صعد مسبقاً", INVALID_QR: "تذكرة غير صالحة",
               WRONG_TRIP: "تذكرة لرحلة أخرى", CANCELLED: "تذكرة ملغاة", NOT_IN_PACK: "غير موجودة في القائمة المحفوظة — تحقق عند الاتصال" },
  },
  errors: {
    NETWORK: "لا يوجد اتصال، وما زالت ميزات العمل دون اتصال متاحة.", INVALID_CREDENTIALS: "البريد أو كلمة المرور غير صحيحة.",
    ACCOUNT_LOCKED: "محاولات كثيرة، الحساب مقفل لمدة 15 دقيقة.", MFA_CODE_INVALID: "الرمز غير صحيح.",
    SEAT_TAKEN: "حُجز أحد المقاعد للتو، اختر من جديد.", HOLD_EXPIRED: "انتهت مدة الحجز المؤقت، اختر مقاعدك من جديد.",
    INSUFFICIENT_BALANCE: "رصيد المحفظة غير كافٍ.", NAME_PARTS_REQUIRED: "يحتاج المواطن السوري إلى الأسماء الأربعة.",
    DEVICE_REVOKED: "سُجّل خروج هذا الجهاز من حسابك.", SESSION_EXPIRED: "سجّل الدخول من جديد.",
    RATE_LIMITED: "محاولات كثيرة، انتظر قليلاً.", generic: "حدث خطأ، أعد المحاولة.",
  },
};

export default ar;
