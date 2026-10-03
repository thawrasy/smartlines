# قاموس البيانات — قاعدة بيانات مسلك (المرحلة الأولى)

> مولَّد آلياً من القاعدة المبنية (`db/tools/gen_docs.py`)؛ لا يُعدَّل يدوياً.

**181 جدولاً، 1885 عموداً، في 14 مخططاً.**

الرموز: 🔑 مفتاح أساسي · 🔗 مفتاح أجنبي · ✱ إلزامي · 🛡️ عزل المستأجر (RLS) · 🧩 مقسّم شهرياً · 🔒 إلحاق فقط/محمي من التعديل

## الفهرس

- [`iam` — الهوية والأطراف والمستخدمون والصلاحيات وواجهات API](#iam) (23 جدولاً)
- [`ref` — البيانات المرجعية والملفات](#ref) (5 جدولاً)
- [`sys` — الإعدادات وصندوق الأحداث وWebhooks](#sys) (6 جدولاً)
- [`net` — الشبكة: المحطات والخطوط ورموز الناقلين](#net) (8 جدولاً)
- [`fleet` — الأسطول: المركبات والمقاعد والطاقم والتراخيص والتأمين](#fleet) (12 جدولاً)
- [`pricing` — التسعير والضرائب والعمولات والحملات والولاء](#pricing) (19 جدولاً)
- [`ops` — الرحلات والمخزون والتشغيل والتتبع والحوادث](#ops) (17 جدولاً)
- [`sales` — القنوات والحجوزات والمسافرون والتذاكر](#sales) (8 جدولاً)
- [`fin` — المحافظ والدفتر والمدفوعات والتوزيع والتسوية](#fin) (16 جدولاً)
- [`acct` — المحاسبة المبسطة والفوترة الإلكترونية والملف الضريبي](#acct) (24 جدولاً)
- [`crm` — الشكاوى والتقييم والإشعارات والمساعد الذكي](#crm) (9 جدولاً)
- [`gov` — الحوكمة والالتزامات وحماية البيانات](#gov) (10 جدولاً)
- [`sec` — الأمن: قواعد IP والمخاطر والتوقيع ووحدة الأمن](#sec) (19 جدولاً)
- [`audit` — سجلات الدخول والإجراءات (إلحاق فقط)](#audit) (5 جدولاً)

<a id="iam"></a>
## `iam` — الهوية والأطراف والمستخدمون والصلاحيات وواجهات API

### `iam.api_client` 🛡️

عملاء API (ناقل، قناة، شريك، جهة): نطاقات وحد معدل وقائمة IP مسموحة وmTLS اختياري

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `name` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `owner_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `environment` | `text` | ✱ | `'SANDBOX'::text` |
| `scopes` | `text[]` | ✱ | `'{}'::text[]` |
| `rate_limit_per_min` | `integer` | ✱ | `600` |
| `ip_allowlist` | `cidr[]` |  |  |
| `require_mtls` | `boolean` | ✱ | `false` |
| `mtls_cert_sha256` | `bytea` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.api_key` 

مفاتيح API مجزأة؛ مفتاحان فعالان كحد أقصى أثناء التدوير

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `api_client_id` | `bigint` | 🔗 `iam.api_client` ✱ |  |
| `key_prefix` | `text` | ✱ |  |
| `key_hash` | `bytea` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `last_used_at` | `timestamp with time zone` |  |  |
| `last_used_ip` | `inet` |  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |
| `revoked_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `revoke_reason` | `text` |  |  |

### `iam.app_user` 

حساب الدخول؛ نوع الحساب يحدد البوابة: المنصة، الشركة، الوكالة، العميل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `account_kind` | `text` | ✱ |  |
| `mobile` | `text` |  |  |
| `email` | `citext` |  |  |
| `password_hash` | `text` |  |  |
| `password_changed_at` | `timestamp with time zone` |  |  |
| `mfa_required` | `boolean` | ✱ | `false` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `failed_attempts` | `integer` | ✱ | `0` |
| `locked_until` | `timestamp with time zone` |  |  |
| `last_login_at` | `timestamp with time zone` |  |  |
| `last_login_ip` | `inet` |  |  |
| `preferred_lang` | `text` | ✱ | `'ar'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.auth_token` 

رموز الدعوة والاسترجاع وOTP (لمرة واحدة، مخزنة مجزأة)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `kind` | `text` | ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `target` | `text` |  |  |
| `attempts` | `smallint` | ✱ | `0` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `used_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.bank_account` 

الحسابات البنكية للسحب والتسوية (IBAN مشفر)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `bank_name` | `text` | ✱ |  |
| `holder_name` | `text` | ✱ |  |
| `iban_enc` | `bytea` | ✱ |  |
| `iban_bidx` | `bytea` | ✱ |  |
| `iban_last4` | `text` | ✱ |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry` ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `verified` | `boolean` | ✱ | `false` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.beneficial_owner` 

المالكون المستفيدون للشركة (امتثال وأمن)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `ownership_pct` | `numeric(5,2)` | ✱ |  |

### `iam.biometric_template` 

القالب الحيوي للوجه مشفراً بمفتاح منفصل ومعزولاً (3.8 ج)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `template_enc` | `bytea` | ✱ |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry` ✱ |  |
| `algorithm` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `retain_until` | `timestamp with time zone` | ✱ |  |

### `iam.company` 🛡️

الشركة الناقلة (Tenant): ملف 1:1 مع party؛ كل بيانات الشركة معزولة بـ company_id

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `company_type` | `text` | ✱ | `'CARRIER'::text` |
| `cr_no` | `text` |  |  |
| `cr_expiry` | `date` |  |  |
| `transport_license_no` | `text` |  |  |
| `regulator_code` | `text` |  |  |
| `settlement_cycle` | `text` | ✱ | `'WEEKLY'::text` |
| `approval_status` | `text` | ✱ | `'PENDING'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.company_member` 🛡️

مستخدمو الشركة (المقاعد) ودورهم؛ مالك واحد لكل شركة لا يُعدَّل من داخلها

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `role_id` | `bigint` | 🔗 `iam.role`  |  |
| `is_owner` | `boolean` | ✱ | `false` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.device` 

الأجهزة المسجلة لكل مستخدم (3.5 و16.8)؛ جهاز المشغّل الجديد يحتاج اعتماداً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `fingerprint_hash` | `bytea` | ✱ |  |
| `platform` | `text` | ✱ |  |
| `app_version` | `text` |  |  |
| `attestation_state` | `text` | ✱ | `'UNKNOWN'::text` |
| `trust_status` | `text` | ✱ | `'PENDING_APPROVAL'::text` |
| `first_seen_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_seen_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |

### `iam.document` 

المستندات لأي كيان (مرجع متعدد الأشكال) مع الملف والمراجعة وتاريخ الانتهاء

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `owner_type` | `text` | ✱ |  |
| `owner_id` | `bigint` | ✱ |  |
| `doc_type` | `text` | ✱ |  |
| `doc_no_enc` | `bytea` |  |  |
| `doc_no_bidx` | `bytea` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `issuer` | `text` |  |  |
| `issue_date` | `date` |  |  |
| `expiry_date` | `date` |  |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `reviewed_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.gov_identity_link` 

ربط الحساب بالهوية الرقمية الوطنية (جاهزية على نمط نفاذ)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `provider_id` | `bigint` | 🔑 🔗 `iam.identity_provider` ✱ |  |
| `subject_ref_bidx` | `bytea` | ✱ |  |
| `assurance_level` | `text` |  |  |
| `linked_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_verified_at` | `timestamp with time zone` |  |  |

### `iam.identity_provider` 

محوّلات التحقق: مزود KYC، السجل الوطني، الاتصالات، الهوية الرقمية (تُفعَّل في المرحلة 5)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country`  |  |
| `kind` | `text` | ✱ |  |
| `protocol` | `text` | ✱ |  |
| `config` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'INACTIVE'::text` |

### `iam.mfa_factor` 

عوامل التحقق المتعدد (TOTP بسر مشفر، مفاتيح المرور، رموز احتياطية)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `factor_type` | `text` | ✱ |  |
| `secret_enc` | `bytea` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `public_key` | `bytea` |  |  |
| `verified_at` | `timestamp with time zone` |  |  |
| `disabled_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.party` 

الطرف الموحد: شخص أو شركة أو كيان؛ يُسجَّل مرة واحدة ويحمل أدواراً متعددة (مسافر، سائق، مالك مركبة...)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `party_type` | `text` | ✱ |  |
| `legal_name` | `text` | ✱ |  |
| `name_en` | `text` |  |  |
| `id_type` | `text` |  |  |
| `id_no_enc` | `bytea` |  |  |
| `id_no_bidx` | `bytea` |  |  |
| `id_no_last4` | `text` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `nationality` | `character(2)` | 🔗 `ref.country`  |  |
| `birth_date` | `date` |  |  |
| `gender` | `text` |  |  |
| `mobile` | `text` |  |  |
| `email` | `citext` |  |  |
| `address` | `jsonb` |  |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ | `'SY'::bpchar` |
| `is_foreign` | `boolean` | ✱ | `false` |
| `national_entity_no` | `text` |  |  |
| `tax_no` | `text` |  |  |
| `tax_country` | `character(2)` | 🔗 `ref.country`  |  |
| `kyc_level` | `smallint` | ✱ | `0` |
| `verification_status` | `text` | ✱ | `'UNVERIFIED'::text` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `external_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.party_role` 

أدوار الطرف (عدة أدوار لطرف واحد)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `role_code` | `text` | 🔑 ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `valid_from` | `date` | ✱ | `CURRENT_DATE` |
| `valid_to` | `date` |  |  |

### `iam.permission` 

كتالوج الصلاحيات (القسم 33)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `module` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `description_ar` | `text` | ✱ |  |
| `is_sensitive` | `boolean` | ✱ | `false` |

### `iam.push_token` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `device_id` | `bigint` | 🔑 🔗 `iam.device` ✱ |  |
| `token` | `text` | ✱ |  |
| `consent` | `boolean` | ✱ | `true` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.role` 

الأدوار: أدوار المنصة، وقوالب أدوار الشركة، وأدوار تحددها كل شركة لنفسها (3.4 ج)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `is_system` | `boolean` | ✱ | `false` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.role_permission` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `permission_code` | `text` | 🔑 🔗 `iam.permission` ✱ |  |

### `iam.user_role` 

أدوار موظفي المنصة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `granted_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `granted_at` | `timestamp with time zone` | ✱ | `now()` |
| `valid_to` | `timestamp with time zone` |  |  |

### `iam.user_session` 

الجلسات الفعالة؛ إلغاؤها ينهي الدخول فوراً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |
| `portal` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `token_hash` | `bytea` | ✱ |  |
| `refresh_hash` | `bytea` |  |  |
| `ip` | `inet` | ✱ |  |
| `user_agent` | `text` |  |  |
| `mfa_passed` | `boolean` | ✱ | `false` |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_seen_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `revoked_at` | `timestamp with time zone` |  |  |
| `revoke_reason` | `text` |  |  |

### `iam.verification` 

سجل كل تحقق (هوية بمستويات L0..L3، شركة، مركبة، مستند)؛ يدوي الآن وآلي بعد الربط

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `level` | `smallint` |  |  |
| `method` | `text` | ✱ |  |
| `provider_id` | `bigint` | 🔗 `iam.identity_provider`  |  |
| `doc_type` | `text` |  |  |
| `doc_no_bidx` | `bytea` |  |  |
| `doc_expiry` | `date` |  |  |
| `liveness_score` | `numeric(5,4)` |  |  |
| `match_score` | `numeric(5,4)` |  |  |
| `decision` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `evidence_file_ids` | `bigint[]` |  |  |
| `reviewer_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `gov_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="ref"></a>
## `ref` — البيانات المرجعية والملفات

### `ref.city` 

المدن (محلية ودولية)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `region` | `text` |  |  |
| `name_ar` | `text` | ✱ |  |
| `name_en` | `text` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `timezone` | `text` | ✱ | `'Asia/Damascus'::text` |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.country` 

الدول (حزمة الدولة 12.4): سوريا أساساً ثم التوسع

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `character(2)` | 🔑 ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `name_en` | `text` | ✱ |  |
| `phone_prefix` | `text` |  |  |
| `default_currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.currency` 

العملات؛ كل المبالغ في النظام BIGINT بالوحدة الصغرى لهذه العملة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `character(3)` | 🔑 ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `name_en` | `text` | ✱ |  |
| `minor_unit` | `smallint` | ✱ | `2` |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.exchange_rate` 

أسعار الصرف بتاريخ سريان؛ يُثبَّت السعر المستخدم في كل عملية (القسم 12)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `base_currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `quote_currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `rate` | `numeric(20,10)` | ✱ |  |
| `source` | `text` | ✱ | `'MANUAL'::text` |
| `valid_from` | `timestamp with time zone` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.file_object` 

بيانات وصفية لكل ملف مرفوع (مستندات، صور، PDF موقّع)؛ المحتوى في تخزين الكائنات المشفر

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `storage_key` | `text` | ✱ |  |
| `file_name` | `text` |  |  |
| `mime_type` | `text` | ✱ |  |
| `size_bytes` | `bigint` | ✱ |  |
| `sha256` | `bytea` | ✱ |  |
| `data_class` | `text` | ✱ | `'CONFIDENTIAL'::text` |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `uploaded_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `retain_until` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sys"></a>
## `sys` — الإعدادات وصندوق الأحداث وWebhooks

### `sys.company_setting` 🛡️

إعدادات خاصة بكل ناقل (سياسة البيع بعد الانطلاق، مهل الإقفال، أوضاع المقاعد...)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` |  |  |

### `sys.outbox_event` 

صندوق الأحداث الصادرة (Outbox): يُكتب في معاملة التغيير نفسها، ثم يُنشر للخدمات والشركاء

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `event_uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `event_type` | `text` | ✱ |  |
| `aggregate_type` | `text` | ✱ |  |
| `aggregate_id` | `bigint` | ✱ |  |
| `company_id` | `bigint` |  |  |
| `payload` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `attempts` | `integer` | ✱ | `0` |
| `next_attempt_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_error` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `published_at` | `timestamp with time zone` |  |  |

### `sys.schema_migration` 

إصدارات المخطط المطبقة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `version` | `text` | 🔑 ✱ |  |
| `description` | `text` |  |  |
| `checksum` | `text` |  |  |
| `applied_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.setting` 

الإعدادات العامة ومفاتيح التفعيل (مبدأ البناء الكامل والتفعيل بالإعدادات 2.8)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `scope` | `text` | ✱ | `'PLATFORM'::text` |
| `description` | `text` |  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sys.webhook_delivery` 

محاولات التسليم وإعادة المحاولة والرسائل المتعثرة (DEAD)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `endpoint_id` | `bigint` | 🔗 `sys.webhook_endpoint` ✱ |  |
| `outbox_event_id` | `bigint` | 🔗 `sys.outbox_event` ✱ |  |
| `delivery_uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `attempts` | `integer` | ✱ | `0` |
| `http_status` | `integer` |  |  |
| `next_attempt_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_error` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `delivered_at` | `timestamp with time zone` |  |  |

### `sys.webhook_endpoint` 

اشتراكات Webhooks للشركاء والتكاملات (14 و13.10)، موقّعة HMAC-SHA256

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `owner_kind` | `text` | ✱ |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `kind` | `text` | ✱ | `'PARTNER'::text` |
| `url` | `text` | ✱ |  |
| `events` | `text[]` | ✱ |  |
| `secret_enc` | `bytea` | ✱ |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry` ✱ |  |
| `include_pii` | `boolean` | ✱ | `false` |
| `api_version` | `text` | ✱ | `'v1'::text` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_success_at` | `timestamp with time zone` |  |  |

<a id="net"></a>
## `net` — الشبكة: المحطات والخطوط ورموز الناقلين

### `net.carrier_code` 

رمز الناقل الثلاثي (والثنائي الاختياري)، فريد على مستوى المنصة ولا يُعاد قبل 24 شهراً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `code3` | `character(3)` | ✱ |  |
| `code2` | `character(2)` |  |  |
| `code_type` | `text` | ✱ | `'CARRIER'::text` |
| `status` | `text` | ✱ | `'PROPOSED'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `valid_from` | `date` |  |  |
| `retired_at` | `date` |  |  |

### `net.code_reservation` 

رموز محجوزة أو ممنوعة أو مسحوبة مؤقتاً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `reason` | `text` | ✱ |  |
| `until` | `date` |  |  |

### `net.compliance_profile` 

ملف الامتثال بإصدارات لكل (دولة، فئة): الحقول المطلوبة ومهلة الاستكمال (4.11 ب)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `subject` | `text` | ✱ | `'STATION'::text` |
| `country_code` | `text` | ✱ |  |
| `station_class` | `text` | ✱ |  |
| `version` | `integer` | ✱ |  |
| `spec` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.route` 🛡️

قالب خط الناقل بين محطتين؛ تُنسخ محطاته إلى الرحلة عند توليدها (كتالوج الخطوط المعتمد 4.15 يضاف في المرحلة 2)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `code` | `text` | ✱ |  |
| `origin_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `dest_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `service_type` | `text` | ✱ | `'DIRECT'::text` |
| `route_scope` | `text` | ✱ | `'DOMESTIC'::text` |
| `distance_km` | `integer` |  |  |
| `std_duration_min` | `integer` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.route_stop` 

محطات الخط بالترتيب، وأزمنة الإزاحة، وسلّم السعر من الأصل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `route_id` | `bigint` | 🔑 🔗 `net.route` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `kind` | `text` | ✱ |  |
| `arr_offset_min` | `integer` | ✱ | `0` |
| `dep_offset_min` | `integer` | ✱ | `0` |
| `rest_min` | `smallint` | ✱ | `0` |
| `dist_from_origin_km` | `integer` |  |  |
| `fare_from_origin` | `bigint` |  |  |
| `sellable` | `boolean` | ✱ | `true` |

### `net.service_number` 🛡️

رقم الخدمة المتكررة من كتلة النوع؛ لا يتكرر للناقل في فترة متداخلة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `number` | `integer` | ✱ |  |
| `block` | `text` | ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `direction` | `text` | ✱ |  |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.station` 🛡️

سجل المحطات ونقاط الانطلاق والوصول (مركزية، نقطة شركة، خارجية) بكود فريد (4.11)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `station_class` | `text` | ✱ |  |
| `subtype` | `text` | ✱ | `'TERMINAL'::text` |
| `owner_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name_ar` | `text` | ✱ |  |
| `name_en` | `text` |  |  |
| `address` | `text` |  |  |
| `lat` | `numeric(9,6)` | ✱ |  |
| `lng` | `numeric(9,6)` | ✱ |  |
| `phone` | `text` |  |  |
| `email` | `citext` |  |  |
| `hours` | `jsonb` |  |  |
| `facilities` | `text[]` |  |  |
| `operator_name` | `text` |  |  |
| `license_no` | `text` |  |  |
| `license_authority` | `text` |  |  |
| `license_expiry` | `date` |  |  |
| `lead_min` | `integer` | ✱ | `30` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `compliance_state` | `text` | ✱ | `'OK'::text` |
| `compliance_profile_id` | `bigint` | 🔗 `net.compliance_profile`  |  |
| `extra` | `jsonb` | ✱ | `'{}'::jsonb` |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `verified_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.station_contact` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `role` | `text` |  |  |
| `name` | `text` | ✱ |  |
| `phone` | `text` |  |  |
| `email` | `citext` |  |  |

<a id="fleet"></a>
## `fleet` — الأسطول: المركبات والمقاعد والطاقم والتراخيص والتأمين

### `fleet.crew_profile` 🛡️

السائقون والمضيفون؛ رخصهم وتواريخها في fleet.license_record

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `crew_type` | `text` | ✱ |  |
| `license_class` | `text` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.field_check_log` 

كل استعلام ميداني من رجال الأمن والجهات المخوّلة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `inspector_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `method` | `text` | ✱ |  |
| `result` | `text` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.insurance_policy` 🛡️

عقد التأمين شرط لتفعيل المركبة؛ يُتحقق منه لاحقاً من المرور أو شركات التأمين (7.12 أ)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `insurer_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `insurer_name` | `text` | ✱ |  |
| `policy_no` | `text` | ✱ |  |
| `coverage_type` | `text` | ✱ |  |
| `passenger_cover` | `boolean` | ✱ | `false` |
| `cargo_cover` | `boolean` | ✱ | `false` |
| `limits` | `jsonb` |  |  |
| `period` | `daterange` | ✱ |  |
| `license_record_id` | `bigint` | 🔗 `fleet.license_record`  |  |
| `document_id` | `bigint` | 🔗 `iam.document`  |  |
| `source` | `text` | ✱ | `'MANUAL'::text` |
| `verified_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.license_change_request` 

طلب تعديل ترخيص مقفل: مراجعة ثم اعتماد من مسؤول مختلف

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `license_record_id` | `bigint` | 🔗 `fleet.license_record` ✱ |  |
| `requested_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `new_values` | `jsonb` | ✱ |  |
| `document_id` | `bigint` | 🔗 `iam.document`  |  |
| `status` | `text` | ✱ | `'SUBMITTED'::text` |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decision_reason` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `decided_at` | `timestamp with time zone` |  |  |

### `fleet.license_record` 🛡️ 🔒

كل تاريخ انتهاء يحكم أهلية التشغيل (ترخيص، فحص، تأمين، رخصة قيادة)؛ مقفل بعد الحفظ

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `license_type` | `text` | ✱ |  |
| `license_no` | `text` | ✱ |  |
| `issuer` | `text` | ✱ |  |
| `issue_date` | `date` | ✱ |  |
| `expiry_date` | `date` | ✱ |  |
| `source` | `text` | ✱ | `'MANUAL'::text` |
| `locked` | `boolean` | ✱ | `true` |
| `document_id` | `bigint` | 🔗 `iam.document`  |  |
| `status` | `text` | ✱ | `'PENDING_REVIEW'::text` |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `last_change_request_id` | `bigint` | 🔗 `fleet.license_change_request`  |  |
| `last_gov_sync_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.seat_layout` 

مخططات المقاعد القابلة لإعادة الاستخدام

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name` | `text` | ✱ |  |
| `total_seats` | `smallint` | ✱ |  |
| `decks` | `smallint` | ✱ | `1` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.seat_layout_seat` 

مقاعد الركاب في المخطط (مقاعد الطاقم لا تدخل المخزون 4.14)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `layout_id` | `bigint` | 🔑 🔗 `fleet.seat_layout` ✱ |  |
| `seat_no` | `smallint` | 🔑 ✱ |  |
| `label` | `text` |  |  |
| `row_no` | `smallint` | ✱ |  |
| `col_no` | `smallint` | ✱ |  |
| `deck` | `smallint` | ✱ | `1` |
| `cabin` | `text` | ✱ | `'ECONOMY'::text` |

### `fleet.seat_price_rule` 🛡️

أسعار المقاعد المميزة أو المخفضة يحددها الناقل (4.14 أ)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `seat_layout_id` | `bigint` | 🔗 `fleet.seat_layout`  |  |
| `seat_nos` | `smallint[]` | ✱ |  |
| `price_delta` | `bigint` | ✱ |  |
| `label` | `text` | ✱ |  |
| `active` | `boolean` | ✱ | `true` |

### `fleet.vehicle` 🛡️

المركبة: النوع والسعة الجالسة والواقفة، الملكية والمالك، والحالة التي تحجبها عن الإسناد (4.3، 4.13، 4.17، 4.18)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_class` | `text` | ✱ | `'BUS'::text` |
| `vehicle_type` | `text` | ✱ |  |
| `make` | `text` |  |  |
| `model` | `text` |  |  |
| `manufacture_year` | `smallint` |  |  |
| `plate_no` | `text` | ✱ |  |
| `plate_country` | `character(2)` | 🔗 `ref.country` ✱ | `'SY'::bpchar` |
| `chassis_no` | `text` | ✱ |  |
| `serial_no` | `text` |  |  |
| `machine_no` | `text` |  |  |
| `seat_layout_id` | `bigint` | 🔗 `fleet.seat_layout`  |  |
| `passenger_seats` | `smallint` | ✱ |  |
| `standing_capacity` | `smallint` | ✱ | `0` |
| `standing_factor` | `numeric(4,3)` | ✱ | `0.600` |
| `crew_seats` | `jsonb` | ✱ | `'{"driver": 1}'::jsonb` |
| `cargo_capacity_kg` | `integer` | ✱ | `0` |
| `fuel_tank_l` | `integer` |  |  |
| `ownership_type` | `text` | ✱ | `'OWNED'::text` |
| `owner_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `block_reason` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.vehicle_lease` 🛡️

عقد إيجار المركبة؛ مستأجر فعّال واحد لكل مركبة في الفترة (قيد استبعاد)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `owner_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `lessee_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `contract_no` | `text` | ✱ |  |
| `period` | `daterange` | ✱ |  |
| `document_id` | `bigint` | 🔗 `iam.document`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.vehicle_qr_tag` 

ملصق QR الموقّع على المركبة للتحقق الميداني (4.18 هـ)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |

### `fleet.vehicle_status_history` 

تاريخ حالة المركبة (إيقاف بعد حادث، حجز، إفراج) بالسبب والدليل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `status` | `text` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `incident_id` | `bigint` | 🔗 `ops.incident`  |  |
| `changed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `release_document_id` | `bigint` | 🔗 `iam.document`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="pricing"></a>
## `pricing` — التسعير والضرائب والعمولات والحملات والولاء

### `pricing.allocation_template` 

قالب شجرة توزيع السعر على المستفيدين (ناقل، منصة، ضريبة، وسيط)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `anchor_line_code` | `text` | ✱ |  |
| `rounding_line_code` | `text` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.allocation_template_line` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `template_id` | `bigint` | 🔑 🔗 `pricing.allocation_template` ✱ |  |
| `code` | `text` | 🔑 ✱ |  |
| `level` | `smallint` | ✱ |  |
| `parent_code` | `text` |  |  |
| `component_type` | `text` | ✱ |  |
| `beneficiary_ref` | `text` | ✱ |  |
| `basis` | `text` | ✱ |  |
| `value` | `numeric(18,6)` |  |  |
| `rule_ref` | `text` |  |  |
| `wallet_type` | `text` | ✱ |  |
| `release_event` | `text` | ✱ | `'TRIP_COMPLETED'::text` |
| `refundable` | `boolean` | ✱ | `true` |

### `pricing.campaign` 

الحملة: الجمهور والنطاق والميزة والتمويل والميزانية والحدود (شرط ← إجراء)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `audience_rule` | `jsonb` | ✱ | `'{}'::jsonb` |
| `scope_rule` | `jsonb` | ✱ | `'{}'::jsonb` |
| `trigger` | `text` | ✱ | `'AUTO'::text` |
| `benefit` | `jsonb` | ✱ |  |
| `funding` | `jsonb` | ✱ |  |
| `budget_total` | `bigint` |  |  |
| `budget_spent` | `bigint` | ✱ | `0` |
| `per_user_limit` | `integer` |  |  |
| `per_day_limit` | `integer` |  |  |
| `stackable` | `boolean` | ✱ | `false` |
| `priority` | `smallint` | ✱ | `100` |
| `valid` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.commission_rule` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `scheme_id` | `bigint` | 🔗 `pricing.commission_scheme` ✱ |  |
| `seq` | `smallint` | ✱ |  |
| `calc_method` | `text` | ✱ |  |
| `rate` | `numeric(9,6)` |  |  |
| `amount` | `bigint` |  |  |
| `min_amount` | `bigint` |  |  |
| `max_amount` | `bigint` |  |  |
| `cap_period` | `text` |  |  |

### `pricing.commission_scheme` 

مخطط عمولة (منصة، وسيط، دفع، إحالة) بممول ومستفيد وإصدارات

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `type` | `text` | ✱ |  |
| `funded_by` | `text` | ✱ |  |
| `beneficiary_role` | `text` | ✱ |  |
| `scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `base_type` | `text` | ✱ | `'FARE'::text` |
| `valid` | `tstzrange` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.fare_brand` 

علامات الأسعار وشروط التذكرة والأمتعة والاسترداد؛ تُنسخ لقطتها إلى التذكرة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name_ar` | `text` | ✱ |  |
| `name_en` | `text` |  |  |
| `factor` | `numeric(6,4)` | ✱ | `1` |
| `rules` | `jsonb` | ✱ |  |
| `sort` | `smallint` | ✱ | `0` |
| `active` | `boolean` | ✱ | `true` |

### `pricing.fare_table` 

جدول أجرة مركزي (مقفل) أو للناقل ضمن حدود (5.2)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `scope` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `locked` | `boolean` | ✱ | `false` |
| `min_price` | `bigint` |  |  |
| `max_price` | `bigint` |  |  |
| `valid` | `tstzrange` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.fare_table_item` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `fare_table_id` | `bigint` | 🔑 🔗 `pricing.fare_table` ✱ |  |
| `from_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `to_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `cabin` | `text` | 🔑 ✱ | `'ECONOMY'::text` |
| `passenger_category` | `text` | 🔑 ✱ | `'ADULT'::text` |
| `base_price` | `bigint` | ✱ |  |

### `pricing.jurisdiction` 

الاختصاص الضريبي (دولة، منطقة، منفذ، محلي)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `level` | `text` | ✱ |  |
| `parent_id` | `bigint` | 🔗 `pricing.jurisdiction`  |  |
| `name` | `text` | ✱ |  |

### `pricing.loyalty_program` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `point_value` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `expiry_months` | `smallint` | ✱ | `24` |
| `tax_treatment` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.loyalty_rule` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `kind` | `text` | ✱ |  |
| `condition` | `jsonb` | ✱ | `'{}'::jsonb` |
| `formula` | `jsonb` | ✱ |  |
| `funded_by` | `text` | ✱ | `'PLATFORM'::text` |
| `valid` | `tstzrange` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `active` | `boolean` | ✱ | `true` |

### `pricing.loyalty_tier` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `code` | `text` | ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `min_points` | `bigint` | ✱ | `0` |
| `benefits` | `jsonb` | ✱ | `'{}'::jsonb` |

### `pricing.points_account` 

حساب النقاط؛ الرصيد مخزَّن ويُطابَق مع دفتر النقاط

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `tier_id` | `bigint` | 🔗 `pricing.loyalty_tier`  |  |
| `balance` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.points_ledger` 🔒

دفتر النقاط: إلحاق فقط، والتصحيح بقيد عكسي

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `account_id` | `bigint` | 🔗 `pricing.points_account` ✱ |  |
| `txn_type` | `text` | ✱ |  |
| `points` | `bigint` | ✱ |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `rule_id` | `bigint` | 🔗 `pricing.loyalty_rule`  |  |
| `funded_by` | `text` |  |  |
| `idempotency_key` | `text` | ✱ |  |
| `expires_at` | `timestamp with time zone` |  |  |
| `reverses_id` | `bigint` | 🔗 `pricing.points_ledger`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.pricing_modifier` 

المعدّلات الديناميكية بالترتيب (5.3)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `type` | `text` | ✱ |  |
| `condition` | `jsonb` | ✱ |  |
| `action_type` | `text` | ✱ |  |
| `action_value` | `numeric(12,4)` | ✱ |  |
| `priority` | `smallint` | ✱ | `100` |
| `valid` | `tstzrange` | ✱ |  |
| `active` | `boolean` | ✱ | `true` |

### `pricing.promo_code` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `campaign_id` | `bigint` | 🔗 `pricing.campaign` ✱ |  |
| `code` | `citext` | ✱ |  |
| `max_uses` | `integer` |  |  |
| `uses` | `integer` | ✱ | `0` |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |

### `pricing.rate_band` 

شرائح الاحتساب لقاعدة ضريبة أو عمولة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `tax_rule_id` | `bigint` | 🔗 `pricing.tax_rule`  |  |
| `commission_rule_id` | `bigint` | 🔗 `pricing.commission_rule`  |  |
| `dimension` | `text` | ✱ |  |
| `from_value` | `numeric(18,4)` | ✱ |  |
| `to_value` | `numeric(18,4)` |  |  |
| `rate` | `numeric(9,6)` |  |  |
| `amount` | `bigint` |  |  |
| `mode` | `text` | ✱ | `'WHOLE'::text` |

### `pricing.tax_rule` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `seq` | `smallint` | ✱ |  |
| `calc_method` | `text` | ✱ |  |
| `rate` | `numeric(9,6)` |  |  |
| `amount` | `bigint` |  |  |
| `base_type` | `text` | ✱ | `'FARE'::text` |
| `base_include` | `jsonb` | ✱ | `'[]'::jsonb` |
| `compound_mode` | `text` | ✱ | `'ADD'::text` |
| `min_amount` | `bigint` |  |  |
| `max_amount` | `bigint` |  |  |
| `rounding_rule` | `text` | ✱ | `'HALF_UP'::text` |
| `applies_per` | `text` | ✱ | `'TICKET'::text` |
| `priority` | `smallint` | ✱ | `100` |

### `pricing.tax_scheme` 

مخطط ضريبة أو رسم بمعالجته واختصاصه وجهة تحصيله، بإصدارات واعتماد مزدوج

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `jurisdiction_id` | `bigint` | 🔗 `pricing.jurisdiction` ✱ |  |
| `tax_type` | `text` | ✱ |  |
| `treatment` | `text` | ✱ | `'STANDARD'::text` |
| `scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `collected_by` | `text` | ✱ |  |
| `payable_to_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `valid` | `tstzrange` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="ops"></a>
## `ops` — الرحلات والمخزون والتشغيل والتتبع والحوادث

### `ops.crew_assignment` 

إسناد الطاقم للرحلة؛ قيد استبعاد يمنع إسناد الفرد لرحلتين متداخلتين

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `party_id` | `bigint` | 🔗 `fleet.crew_profile` ✱ |  |
| `crew_role` | `text` | ✱ |  |
| `busy` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'ASSIGNED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.family_zone` 

مناطق العائلات في الرحلة (4.14 أ)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seat_nos` | `smallint[]` | ✱ |  |
| `label` | `text` | 🔑 ✱ | `'FAMILY'::text` |

### `ops.geo_event` 🧩

مواقع التتبع؛ مقسّم شهرياً، ومدة احتفاظ قصيرة (16.13: 7 أيام افتراضياً للأفراد)؛ بلا FK لأداء الإدخال

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ts` | `timestamp with time zone` | 🔑 ✱ |  |
| `trip_id` | `bigint` |  |  |
| `vehicle_id` | `bigint` |  |  |
| `driver_user_id` | `bigint` |  |  |
| `lat` | `numeric(9,6)` | ✱ |  |
| `lng` | `numeric(9,6)` | ✱ |  |
| `accuracy_m` | `real` |  |  |
| `speed_kmh` | `real` |  |  |
| `heading` | `smallint` |  |  |
| `source` | `text` | ✱ | `'DRIVER_APP'::text` |

### `ops.incident` 🛡️

الحادث أو العطل؛ الجسيم منه يوقف المركبة فوراً ويطلب قرار استمرارية

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `driver_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `type` | `text` | ✱ |  |
| `severity` | `text` | ✱ |  |
| `injuries` | `boolean` | ✱ | `false` |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `occurred_at` | `timestamp with time zone` | ✱ |  |
| `police_report_no` | `text` |  |  |
| `reported_via` | `text` | ✱ | `'DRIVER_APP'::text` |
| `reported_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.incident_evidence` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object` ✱ |  |
| `kind` | `text` | ✱ |  |
| `uploaded_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.incident_external_link` 

الربط مع المرور والشرطة وشركات التأمين (يُفعَّل بعد الربط الحكومي)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `authority` | `text` | ✱ |  |
| `external_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `last_sync_at` | `timestamp with time zone` |  |  |

### `ops.seat_segment` 

مخزون المقعد لكل مقطع (4.12 ج): المقعد يُباع للزوج إن كان شاغراً في كل مقاطعه

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seat_no` | `smallint` | 🔑 ✱ |  |
| `seg` | `smallint` | 🔑 ✱ |  |
| `status` | `text` | ✱ | `'AVAILABLE'::text` |
| `lock_token` | `uuid` |  |  |
| `lock_user_id` | `bigint` |  |  |
| `lock_expires_at` | `timestamp with time zone` |  |  |
| `ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |

### `ops.standing_segment` 

عدّاد أماكن الوقوف لكل مقطع، لا يتجاوز السعة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seg` | `smallint` | 🔑 ✱ |  |
| `capacity` | `smallint` | ✱ |  |
| `used` | `smallint` | ✱ | `0` |

### `ops.tracking_alert` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `kind` | `text` | ✱ |  |
| `severity` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `escalated` | `boolean` | ✱ | `false` |
| `detail` | `jsonb` |  |  |
| `opened_at` | `timestamp with time zone` | ✱ | `now()` |
| `resolved_at` | `timestamp with time zone` |  |  |

### `ops.trip` 🛡️

الرحلة الفعلية (الكيان المحوري) برقمها والمركبة والسعة واللقطات والسياسات؛ قيد استبعاد يمنع تعارض المركبة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `trip_no` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `service_number_id` | `bigint` | 🔗 `net.service_number`  |  |
| `section_suffix` | `character(1)` |  |  |
| `template_id` | `bigint` | 🔗 `ops.trip_template`  |  |
| `route_id` | `bigint` | 🔗 `net.route` ✱ |  |
| `trip_type` | `text` | ✱ | `'SCHEDULED'::text` |
| `transport_mode` | `text` | ✱ | `'BUS'::text` |
| `service_type` | `text` | ✱ | `'DIRECT'::text` |
| `has_rest` | `boolean` | ✱ | `false` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `departure_at` | `timestamp with time zone` | ✱ |  |
| `arrival_at` | `timestamp with time zone` | ✱ |  |
| `turnaround_min` | `smallint` | ✱ | `30` |
| `vehicle_busy` | `tstzrange` |  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `capacity_mode` | `text` | ✱ | `'SEATED'::text` |
| `seat_selection_mode` | `text` | ✱ | `'OPEN_PAID'::text` |
| `seats_total` | `smallint` | ✱ |  |
| `standing_capacity` | `smallint` | ✱ | `0` |
| `standing_factor` | `numeric(4,3)` | ✱ | `0.600` |
| `cargo_capacity_kg` | `integer` | ✱ | `0` |
| `segments_count` | `smallint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `base_price` | `bigint` | ✱ |  |
| `fare_brand_codes` | `text[]` | ✱ | `'{}'::text[]` |
| `baggage_policy` | `jsonb` | ✱ | `'{}'::jsonb` |
| `crew_snapshot` | `jsonb` | ✱ | `'{}'::jsonb` |
| `seat_prices_snapshot` | `jsonb` | ✱ | `'[]'::jsonb` |
| `post_departure_policy` | `text` | ✱ | `'PHYSICAL_FREE'::text` |
| `sales_cutoff_min` | `smallint` | ✱ | `15` |
| `hold_min` | `smallint` | ✱ | `10` |
| `shift_min` | `integer` | ✱ | `0` |
| `clearance_status` | `text` | ✱ | `'NOT_REQUIRED'::text` |
| `tracking_level` | `text` | ✱ | `'NORMAL'::text` |
| `published_at` | `timestamp with time zone` |  |  |
| `external_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.trip_change` 

سجل تغييرات الرحلة وأسبابها (7.9)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `kind` | `text` | ✱ |  |
| `old_departure` | `timestamp with time zone` |  |  |
| `new_departure` | `timestamp with time zone` |  |  |
| `shift_min` | `integer` |  |  |
| `reason` | `text` | ✱ |  |
| `by_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.trip_disruption` 

قرار استمرارية الرحلة: بديلة، استئجار، تعاون، إنقاذ، إيقاف (7.12 ج)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `incident_id` | `bigint` | 🔗 `ops.incident`  |  |
| `decision` | `text` |  |  |
| `replacement_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `partner_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `decision_deadline` | `timestamp with time zone` | ✱ |  |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decided_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'AWAITING_DECISION'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.trip_pair_fare` 

سعر استثنائي لزوج محطات يتجاوز فرق السلّم

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `from_seq` | `smallint` | 🔑 ✱ |  |
| `to_seq` | `smallint` | 🔑 ✱ |  |
| `price` | `bigint` | ✱ |  |

### `ops.trip_stop` 

محطات الرحلة (لقطة من الخط) بالأوقات الموعودة والفعلية وسلّم السعر

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `kind` | `text` | ✱ | `'STATION'::text` |
| `sellable` | `boolean` | ✱ | `true` |
| `sched_arr` | `timestamp with time zone` |  |  |
| `sched_dep` | `timestamp with time zone` |  |  |
| `actual_arr` | `timestamp with time zone` |  |  |
| `actual_dep` | `timestamp with time zone` |  |  |
| `rest_min` | `smallint` | ✱ | `0` |
| `fare_from_origin` | `bigint` | ✱ | `0` |
| `sales_closed_at` | `timestamp with time zone` |  |  |

### `ops.trip_stop_event` 

الوصول والمغادرة الفعليان لكل محطة (أساس الالتزام بالموعد 4.12 ح)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `seq` | `smallint` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `ts` | `timestamp with time zone` | ✱ |  |
| `delay_min` | `integer` |  |  |
| `source` | `text` | ✱ | `'DRIVER_APP'::text` |
| `by_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.trip_template` 🛡️

نمط الرحلة المتكررة الذي يولّد الرحلات الفعلية

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route` ✱ |  |
| `service_number_id` | `bigint` | 🔗 `net.service_number`  |  |
| `default_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `departure_time` | `time without time zone` | ✱ |  |
| `days_of_week` | `smallint[]` | ✱ | `'{1,2,3,4,5,6,7}'::smallint[]` |
| `recurrence_rule` | `text` |  |  |
| `fare_brand_codes` | `text[]` | ✱ | `'{}'::text[]` |
| `base_price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `active` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.vehicle_swap` 

تبديل مركبة الرحلة دون تغيير رقمها (4.16 د)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `from_vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `to_vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `reason` | `text` | ✱ |  |
| `seats_reassigned` | `boolean` | ✱ | `false` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sales"></a>
## `sales` — القنوات والحجوزات والمسافرون والتذاكر

### `sales.boarding_event` 🔒

أحداث الصعود والنزول بالمسح (أساس التفويج والتسوية والمنافست)؛ إلحاق فقط

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ticket_id` | `bigint` | 🔗 `sales.ticket` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `stop_seq` | `smallint` | ✱ |  |
| `event_type` | `text` | ✱ |  |
| `method` | `text` | ✱ | `'AGENT_SCAN'::text` |
| `result` | `text` | ✱ | `'OK'::text` |
| `scanned_by_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `sales.booking` 🛡️

الحجز: لقطة السعر، والقناة، وشجرة التوزيع، ومفتاح عدم التكرار؛ حالاته وفق القسم 28

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `booking_ref` | `text` | ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `booker_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `booker_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `status` | `text` | ✱ | `'PENDING_PAYMENT'::text` |
| `pay_method` | `text` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `total_amount` | `bigint` | ✱ |  |
| `price_breakdown` | `jsonb` | ✱ |  |
| `rules_version` | `text` | ✱ |  |
| `price_allocation_id` | `bigint` | 🔗 `fin.price_allocation`  |  |
| `idempotency_key` | `text` | ✱ |  |
| `hold_expires_at` | `timestamp with time zone` |  |  |
| `confirmed_at` | `timestamp with time zone` |  |  |
| `cancelled_at` | `timestamp with time zone` |  |  |
| `cancel_reason` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.campaign_redemption` 

استخدام الحملة في حجز ومن يموّل الخصم

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `campaign_id` | `bigint` | 🔗 `pricing.campaign` ✱ |  |
| `promo_code_id` | `bigint` | 🔗 `pricing.promo_code`  |  |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `discount_amount` | `bigint` | ✱ |  |
| `sponsor_amount` | `bigint` | ✱ | `0` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.channel` 

قناة البيع (مباشر، شباك، وكالة، شريك API)؛ الاتفاقيات والحصص في المرحلة 9

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `channel_type` | `text` | ✱ |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.passenger` 

بيانات المسافر في الحجز؛ أرقام الوثائق مشفرة بفهرس أعمى للفحص الأمني والمنافست

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `full_name` | `text` | ✱ |  |
| `passenger_category` | `text` | ✱ | `'ADULT'::text` |
| `id_type` | `text` |  |  |
| `id_no_enc` | `bytea` |  |  |
| `id_no_bidx` | `bytea` |  |  |
| `id_no_last4` | `text` |  |  |
| `passport_no_enc` | `bytea` |  |  |
| `passport_no_bidx` | `bytea` |  |  |
| `passport_country` | `character(2)` | 🔗 `ref.country`  |  |
| `passport_expiry` | `date` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `nationality` | `character(2)` | 🔗 `ref.country`  |  |
| `birth_date` | `date` |  |  |
| `gender` | `text` |  |  |
| `mobile` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.passenger_compensation` 

تعويض المسافرين عن الإلغاء أو التعطل، ويُحمَّل على الناقل المتسبب

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `trip_disruption_id` | `bigint` | 🔗 `ops.trip_disruption`  |  |
| `type` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `charged_to_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `credit_note_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.refund_request` 

طلب الاسترداد بلقطة السياسة؛ لا يُحرَّر المبلغ قبل إقفال الإشعار الدائن (BR-EIN-03)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `reason` | `text` | ✱ |  |
| `amount_requested` | `bigint` | ✱ |  |
| `amount_approved` | `bigint` |  |  |
| `policy_snapshot` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `requested_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `credit_note_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `decided_at` | `timestamp with time zone` |  |  |

### `sales.ticket` 

التذكرة لكل مسافر وزوج محطات، بمقعد مرقَّم أو مضمون أو وقوف، ولقطة الشروط وQR موقّع

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `ticket_no` | `text` | ✱ |  |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `passenger_id` | `bigint` | 🔗 `sales.passenger` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `from_seq` | `smallint` | ✱ |  |
| `to_seq` | `smallint` | ✱ |  |
| `seat_no` | `smallint` |  |  |
| `is_standing` | `boolean` | ✱ | `false` |
| `assigned_seat_at_boarding` | `smallint` |  |  |
| `cabin` | `text` | ✱ | `'ECONOMY'::text` |
| `fare_brand_code` | `text` | 🔗 `pricing.fare_brand`  |  |
| `fare_amount` | `bigint` | ✱ |  |
| `seat_surcharge` | `bigint` | ✱ | `0` |
| `baggage_pieces` | `smallint` | ✱ | `0` |
| `baggage_fee` | `bigint` | ✱ | `0` |
| `total_amount` | `bigint` | ✱ |  |
| `rules_snapshot` | `jsonb` | ✱ |  |
| `qr_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `qr_serial` | `integer` | ✱ | `0` |
| `status` | `text` | ✱ | `'ISSUED'::text` |
| `boarded_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="fin"></a>
## `fin` — المحافظ والدفتر والمدفوعات والتوزيع والتسوية

### `fin.bank_reconciliation` 

المطابقة اليومية: رصيد البنك = إجمالي المحافظ + المستحقات

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `recon_date` | `date` | ✱ |  |
| `account_label` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `bank_balance` | `bigint` | ✱ |  |
| `wallets_total` | `bigint` | ✱ |  |
| `receivables` | `bigint` | ✱ | `0` |
| `diff` | `bigint` |  | `((bank_balance - wallets_total) - rec...` |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.bank_transfer_topup` 

شحن المحفظة بتحويل بنكي بمرجع فريد ومطابقة تلقائية

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `wallet_id` | `bigint` | 🔗 `fin.wallet` ✱ |  |
| `virtual_ref` | `text` | ✱ |  |
| `bank_ref` | `text` |  |  |
| `amount` | `bigint` |  |  |
| `status` | `text` | ✱ | `'AWAITING'::text` |
| `matched_at` | `timestamp with time zone` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.ledger_entry` 🔒

سطر القيد (مدين/دائن)؛ إلحاق فقط، ويحدّث رصيد المحفظة ذرياً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `txn_id` | `bigint` | 🔗 `fin.ledger_txn` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet` ✱ |  |
| `direction` | `character(2)` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `balance_after` | `bigint` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.ledger_txn` 🔒

رأس القيد المالي؛ غير قابل للتعديل، ومفتاح عدم التكرار يمنع القيد المزدوج

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `txn_type` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `ref_type` | `text` |  |  |
| `ref_id` | `bigint` |  |  |
| `idempotency_key` | `text` | ✱ |  |
| `memo` | `text` |  |  |
| `reverses_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.payment` 

الدفعة؛ لا تصبح SUCCESS إلا بإشعار موقّع من البوابة وقيد في الدفتر (16.25)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `provider_id` | `bigint` | 🔗 `fin.payment_provider` ✱ |  |
| `purpose` | `text` | ✱ |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `payer_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `method` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `fee` | `bigint` | ✱ | `0` |
| `platform_fee` | `bigint` | ✱ | `0` |
| `provider_ref` | `text` |  |  |
| `idempotency_key` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `card_last4` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `settled_at` | `timestamp with time zone` |  |  |

### `fin.payment_notification` 🔒

إشعارات البوابة الموقّعة كما وردت (مرجع حالة الدفع، ومنع التكرار)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `provider_id` | `bigint` | 🔗 `fin.payment_provider` ✱ |  |
| `event_id` | `text` | ✱ |  |
| `payment_id` | `bigint` | 🔗 `fin.payment`  |  |
| `signature_valid` | `boolean` | ✱ |  |
| `source_ip` | `inet` |  |  |
| `payload` | `jsonb` | ✱ |  |
| `received_at` | `timestamp with time zone` | ✱ | `now()` |
| `processed_at` | `timestamp with time zone` |  |  |

### `fin.payment_provider` 

مزود الدفع بمحوّل موحد قابل للاستبدال

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `config` | `jsonb` | ✱ | `'{}'::jsonb` |
| `fee_policy` | `jsonb` | ✱ | `'{}'::jsonb` |
| `clearing_wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `status` | `text` | ✱ | `'INACTIVE'::text` |

### `fin.payout` 🛡️

التحويل البنكي للناقل بحسب جدوله

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `settlement_batch_id` | `bigint` | 🔗 `fin.settlement_batch`  |  |
| `bank_account_id` | `bigint` | 🔗 `iam.bank_account`  |  |
| `period` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `gross` | `bigint` | ✱ |  |
| `holdback` | `bigint` | ✱ | `0` |
| `net` | `bigint` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `bank_ref` | `text` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.payout_schedule` 🛡️



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `frequency` | `text` | ✱ | `'WEEKLY'::text` |
| `weekday` | `smallint` |  |  |
| `month_day` | `smallint` |  |  |
| `holdback_pct` | `numeric(5,2)` | ✱ | `0` |
| `min_amount` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.price_allocation` 

رأس شجرة توزيع السعر لكل حجز أو تذكرة أو شحنة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `total` | `bigint` | ✱ |  |
| `template_id` | `bigint` | 🔗 `pricing.allocation_template`  |  |
| `rules_version` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.price_allocation_line` 

أسطر الشجرة: أجرة، ضريبة، عمولة، رسم، خصم؛ كل ورقة تُحرَّر لمحفظة مستفيدها عند حدثها

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `allocation_id` | `bigint` | 🔗 `fin.price_allocation` ✱ |  |
| `code` | `text` | ✱ |  |
| `level` | `smallint` | ✱ |  |
| `parent_line_id` | `bigint` | 🔗 `fin.price_allocation_line`  |  |
| `is_leaf` | `boolean` | ✱ |  |
| `component_type` | `text` | ✱ |  |
| `beneficiary_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme`  |  |
| `commission_scheme_id` | `bigint` | 🔗 `pricing.commission_scheme`  |  |
| `basis` | `text` | ✱ |  |
| `rate` | `numeric(18,6)` |  |  |
| `amount` | `bigint` | ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `release_event` | `text` | ✱ |  |
| `released_at` | `timestamp with time zone` |  |  |
| `refunded_amount` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'HELD'::text` |

### `fin.settlement_batch` 🛡️

كشف تسوية الناقل لفترة؛ لا تتداخل الفترات

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `period` | `daterange` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `gross` | `bigint` | ✱ | `0` |
| `commission` | `bigint` | ✱ | `0` |
| `tax` | `bigint` | ✱ | `0` |
| `refunds` | `bigint` | ✱ | `0` |
| `net` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.settlement_line` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `batch_id` | `bigint` | 🔗 `fin.settlement_batch` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `gross` | `bigint` | ✱ |  |
| `commission` | `bigint` | ✱ |  |
| `tax` | `bigint` | ✱ |  |
| `refunds` | `bigint` | ✱ | `0` |
| `net` | `bigint` | ✱ |  |

### `fin.tax_ledger` 🛡️ 🔒

دفتر الضرائب المحصلة والمستردة لكل مخطط واختصاص وفترة (أساس الإقرار)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `jurisdiction_id` | `bigint` | 🔗 `pricing.jurisdiction` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `period` | `date` | ✱ |  |
| `direction` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `base` | `bigint` | ✱ |  |
| `tax` | `bigint` | ✱ |  |
| `allocation_line_id` | `bigint` | 🔗 `fin.price_allocation_line`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.wallet` 🛡️

المحفظة: مستخدم، شركة، منصة، ضمان Escrow، عمولة، ضريبة، مقاصة؛ الرصيد يُطابَق مع القيود

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `wallet_type` | `text` | ✱ |  |
| `label` | `text` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `balance` | `bigint` | ✱ | `0` |
| `hold_balance` | `bigint` | ✱ | `0` |
| `allow_negative` | `boolean` | ✱ | `false` |
| `kyc_level` | `smallint` | ✱ | `0` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.withdrawal_request` 

طلب السحب بحدود ومراجعة وموافقتين للمبالغ الكبيرة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `wallet_id` | `bigint` | 🔗 `fin.wallet` ✱ |  |
| `bank_account_id` | `bigint` | 🔗 `iam.bank_account` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `requested_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `second_approver` | `bigint` | 🔗 `iam.app_user`  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `decided_at` | `timestamp with time zone` |  |  |

<a id="acct"></a>
## `acct` — المحاسبة المبسطة والفوترة الإلكترونية والملف الضريبي

### `acct.account_mapping` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `connection_id` | `bigint` | 🔑 🔗 `acct.accounting_connection` ✱ |  |
| `local_type` | `text` | 🔑 ✱ |  |
| `local_id` | `bigint` | 🔑 ✱ |  |
| `external_id` | `text` | ✱ |  |
| `external_name` | `text` |  |  |

### `acct.accounting_connection` 🛡️

ربط المنصة أو الشركة بنظام محاسبي خارجي (Odoo، Zoho، الأمين، ملف، API)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `system_type` | `text` | ✱ |  |
| `credentials_ref` | `text` |  |  |
| `settings` | `jsonb` | ✱ | `'{}'::jsonb` |
| `mode` | `text` | ✱ | `'DAILY'::text` |
| `status` | `text` | ✱ | `'INACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.cost_center` 🛡️



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |

### `acct.einvoice_activation` 

تفعيل الإلزام بالموجات لكل فئة ونوع مستند وتاريخ

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `doc_type` | `text` | ✱ |  |
| `taxpayer_category` | `text` | ✱ | `'*'::text` |
| `mandatory_from` | `timestamp with time zone` | ✱ |  |
| `mode` | `text` | ✱ |  |
| `active` | `boolean` | ✱ | `false` |

### `acct.einvoice_document` 🛡️ 🔒

الفاتورة والإشعار الدائن والمدين؛ بعد الإقفال لا يتغير إلا الحالة ورد الجهة، ولا حذف إطلاقاً

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uuid` | `uuid` | ✱ | `gen_random_uuid()` |
| `doc_type` | `text` | ✱ |  |
| `subtype` | `text` | ✱ |  |
| `seller_profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `unit_id` | `bigint` | 🔗 `acct.einvoice_unit` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `buyer_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `buyer_tax_no` | `text` |  |  |
| `source_type` | `text` | ✱ |  |
| `source_id` | `bigint` | ✱ |  |
| `original_doc_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `reason_code` | `text` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `subtotal` | `bigint` | ✱ | `0` |
| `tax_total` | `bigint` | ✱ | `0` |
| `total` | `bigint` | ✱ | `0` |
| `number` | `text` |  |  |
| `counter_value` | `bigint` |  |  |
| `previous_hash` | `text` |  |  |
| `hash` | `text` |  |  |
| `signature` | `text` |  |  |
| `qr_payload` | `text` |  |  |
| `xml_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `pdf_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `authority_ref` | `text` |  |  |
| `finalized_at` | `timestamp with time zone` |  |  |
| `confirmed_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.einvoice_line` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `document_id` | `bigint` | 🔗 `acct.einvoice_document` ✱ |  |
| `line_no` | `smallint` | ✱ |  |
| `description` | `text` | ✱ |  |
| `qty` | `numeric(12,3)` | ✱ | `1` |
| `unit_price` | `bigint` | ✱ |  |
| `discount` | `bigint` | ✱ | `0` |
| `net_amount` | `bigint` | ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme`  |  |
| `treatment` | `text` | ✱ | `'STANDARD'::text` |
| `tax_rate` | `numeric(9,6)` | ✱ | `0` |
| `tax_amount` | `bigint` | ✱ | `0` |
| `allocation_line_id` | `bigint` | 🔗 `fin.price_allocation_line`  |  |

### `acct.einvoice_submission` 🔒

كل محاولة دفع للجهة الحكومية وردها كما ورد (إلحاق فقط)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `document_id` | `bigint` | 🔗 `acct.einvoice_document` ✱ |  |
| `attempt` | `smallint` | ✱ |  |
| `mode` | `text` | ✱ |  |
| `sent_at` | `timestamp with time zone` | ✱ | `now()` |
| `response_status` | `text` |  |  |
| `authority_ref` | `text` |  |  |
| `stamped_xml_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `authority_qr` | `text` |  |  |
| `warnings` | `jsonb` |  |  |
| `errors` | `jsonb` |  |  |

### `acct.einvoice_template` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `version` | `integer` | ✱ |  |
| `fields` | `jsonb` | ✱ |  |
| `qr_encoding` | `text` | ✱ | `'TLV_BASE64'::text` |
| `xml_schema_ref` | `text` |  |  |
| `valid_from` | `timestamp with time zone` | ✱ |  |

### `acct.einvoice_unit` 

وحدة الإصدار لكل بائع: العداد وتجزئة آخر فاتورة والشهادة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `unit_code` | `text` | ✱ |  |
| `number_prefix` | `text` | ✱ |  |
| `certificate_ref` | `text` |  |  |
| `cert_expiry` | `timestamp with time zone` |  |  |
| `signing_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `counter_value` | `bigint` | ✱ | `0` |
| `last_hash` | `text` | ✱ | `'0'::text` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `acct.gl_account` 🛡️

دليل الحسابات المبسط لكل دفتر (المنصة أو الشركة) بقالب جاهز قابل للتعديل (13.3)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `account_type` | `text` | ✱ |  |
| `parent_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `is_postable` | `boolean` | ✱ | `true` |
| `external_code` | `text` |  |  |
| `active` | `boolean` | ✱ | `true` |

### `acct.gl_period` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `period` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `closed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `closed_at` | `timestamp with time zone` |  |  |

### `acct.journal_entry` 🛡️ 🔒

القيد المحاسبي؛ بعد الترحيل لا يُعدَّل والتصحيح بقيد عكسي

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `entry_no` | `text` | ✱ |  |
| `entry_date` | `date` | ✱ |  |
| `source_type` | `text` | ✱ |  |
| `source_id` | `bigint` |  |  |
| `posting_rule_id` | `bigint` | 🔗 `acct.posting_rule`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `fx_rate` | `numeric(20,10)` | ✱ | `1` |
| `memo` | `text` |  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `reversed_by_id` | `bigint` | 🔗 `acct.journal_entry`  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `posted_at` | `timestamp with time zone` |  |  |

### `acct.journal_line` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `entry_id` | `bigint` | 🔗 `acct.journal_entry` ✱ |  |
| `account_id` | `bigint` | 🔗 `acct.gl_account` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `cost_center_id` | `bigint` | 🔗 `acct.cost_center`  |  |
| `debit` | `bigint` | ✱ | `0` |
| `credit` | `bigint` | ✱ | `0` |
| `amount_fc` | `bigint` |  |  |
| `memo` | `text` |  |  |

### `acct.posting_rule` 

قواعد الترحيل: الأحداث تُحوَّل إلى قيود، ولا تكتب أي وحدة في الأستاذ مباشرة (13.4)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `event_type` | `text` | ✱ |  |
| `condition` | `jsonb` | ✱ | `'{}'::jsonb` |
| `lines_template` | `jsonb` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `active` | `boolean` | ✱ | `true` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `acct.sync_item` 

سجل دفع القيود والفواتير إلى النظام الخارجي عبر API، بإعادة محاولة ومنع تكرار (13.12)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `connection_id` | `bigint` | 🔗 `acct.accounting_connection` ✱ |  |
| `batch_ref` | `text` | ✱ |  |
| `item_type` | `text` | ✱ |  |
| `local_id` | `bigint` | ✱ |  |
| `external_id` | `text` |  |  |
| `idempotency_key` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `attempts` | `integer` | ✱ | `0` |
| `error` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `sent_at` | `timestamp with time zone` |  |  |

### `acct.tax_authority` 

الجهة الضريبية ومحوّلها: وضع الإصدار قبل الربط، ثم الإبلاغ أو الاعتماد المسبق

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `name` | `text` | ✱ |  |
| `regime` | `text` | ✱ | `'GENERATION'::text` |
| `report_deadline_hours` | `integer` |  |  |
| `api_base` | `text` |  |  |
| `status` | `text` | ✱ | `'INACTIVE'::text` |

### `acct.tax_collection_no_file` 

ضرائب ورسوم تُحصَّل من طرف بلا ملف ضريبي (ترانزيت، مقطوع) بإيصال تحصيل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `payer_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `base` | `bigint` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `source_type` | `text` | ✱ |  |
| `source_id` | `bigint` | ✱ |  |
| `receipt_no` | `text` | ✱ |  |
| `remitted_payment_id` | `bigint` | 🔗 `acct.tax_payment`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.tax_payment` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile`  |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `tax_return_id` | `bigint` | 🔗 `acct.tax_return`  |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `paid_at` | `timestamp with time zone` | ✱ |  |
| `ref` | `text` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |

### `acct.tax_profile` 

الملف الضريبي لكل شركة أو مالك أو شريك بإصدارات زمنية غير متداخلة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority`  |  |
| `tax_status` | `text` | ✱ |  |
| `tax_no` | `text` |  |  |
| `cr_no` | `text` |  |  |
| `branch_code` | `text` |  |  |
| `legal_name_ar` | `text` | ✱ |  |
| `einvoice_mandatory` | `boolean` | ✱ | `false` |
| `issuer_mode` | `text` | ✱ | `'PLATFORM'::text` |
| `verified_source` | `text` | ✱ | `'MANUAL'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `valid` | `tstzrange` | ✱ | `tstzrange(now(), NULL::timestamp with...` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.tax_profile_field` 

حقول ضريبية ديناميكية يضيفها المسؤول لكل دولة أو جهة دون برمجة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority`  |  |
| `code` | `text` | ✱ |  |
| `label_ar` | `text` | ✱ |  |
| `data_type` | `text` | ✱ |  |
| `required` | `boolean` | ✱ | `false` |
| `validation` | `jsonb` |  |  |

### `acct.tax_profile_value` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `profile_id` | `bigint` | 🔑 🔗 `acct.tax_profile` ✱ |  |
| `field_id` | `bigint` | 🔑 🔗 `acct.tax_profile_field` ✱ |  |
| `value` | `jsonb` | ✱ |  |

### `acct.tax_registration` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `filing_frequency` | `text` | ✱ |  |
| `registered` | `daterange` | ✱ |  |

### `acct.tax_return` 

مسودة الإقرار الضريبي لكل مكلف وفترة بخانات نموذج الجهة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `period` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `submitted_at` | `timestamp with time zone` |  |  |
| `authority_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.tax_return_line` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `return_id` | `bigint` | 🔑 🔗 `acct.tax_return` ✱ |  |
| `box_code` | `text` | 🔑 ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `source_note` | `text` |  |  |

<a id="crm"></a>
## `crm` — الشكاوى والتقييم والإشعارات والمساعد الذكي

### `crm.ai_conversation` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `channel` | `text` | ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `ended_at` | `timestamp with time zone` |  |  |
| `resolved` | `boolean` |  |  |
| `escalated_case_id` | `bigint` | 🔗 `crm.case`  |  |
| `csat` | `smallint` |  |  |

### `crm.ai_message` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `conversation_id` | `bigint` | 🔗 `crm.ai_conversation` ✱ |  |
| `role` | `text` | ✱ |  |
| `redacted_text` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.ai_policy` 

أدوات المساعد ومستوى إجراء كل أداة وحدودها وشرط تأكيد المستخدم

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `tool` | `text` | 🔑 ✱ |  |
| `action_level` | `smallint` | ✱ |  |
| `limits` | `jsonb` | ✱ | `'{}'::jsonb` |
| `requires_confirmation` | `boolean` | ✱ | `true` |
| `enabled` | `boolean` | ✱ | `false` |

### `crm.ai_tool_call` 🔒

كل أداة نفذها المساعد بصلاحية العميل وتأكيده (إلحاق فقط)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `conversation_id` | `bigint` | 🔗 `crm.ai_conversation` ✱ |  |
| `tool` | `text` | 🔗 `crm.ai_policy` ✱ |  |
| `args_redacted` | `jsonb` | ✱ |  |
| `action_level` | `smallint` | ✱ |  |
| `confirmed_by_user` | `boolean` | ✱ | `false` |
| `result_status` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.case` 🛡️

الشكوى أو المطالبة أو الاستفسار بمهل الخدمة والتعويض وفصل المهام (7.6)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `ref` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `category` | `text` | ✱ |  |
| `priority` | `text` | ✱ | `'NORMAL'::text` |
| `status` | `text` | ✱ | `'NEW'::text` |
| `channel` | `text` | ✱ | `'APP'::text` |
| `subject` | `text` | ✱ |  |
| `description` | `text` |  |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `assigned_to` | `bigint` | 🔗 `iam.app_user`  |  |
| `first_due_at` | `timestamp with time zone` |  |  |
| `resolve_due_at` | `timestamp with time zone` |  |  |
| `first_response_at` | `timestamp with time zone` |  |  |
| `resolved_at` | `timestamp with time zone` |  |  |
| `sla_breached` | `boolean` | ✱ | `false` |
| `resolution` | `text` |  |  |
| `claim_amount` | `bigint` |  |  |
| `approved_amount` | `bigint` |  |  |
| `liable` | `text` |  |  |
| `payout_status` | `text` | ✱ | `'NONE'::text` |
| `payout_ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `csat` | `smallint` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.case_event` 🔒



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `case_id` | `bigint` | 🔗 `crm.case` ✱ |  |
| `actor_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `actor_role` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `visibility` | `text` | ✱ | `'PUBLIC'::text` |
| `body` | `text` |  |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.notification` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `template_code` | `text` | ✱ |  |
| `channel` | `text` | ✱ |  |
| `to_address` | `text` |  |  |
| `payload` | `jsonb` | ✱ | `'{}'::jsonb` |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `status` | `text` | ✱ | `'QUEUED'::text` |
| `cost_minor` | `bigint` | ✱ | `0` |
| `charged_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `attempts` | `smallint` | ✱ | `0` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `sent_at` | `timestamp with time zone` |  |  |
| `read_at` | `timestamp with time zone` |  |  |

### `crm.notification_template` 

قوالب الإشعارات المعتمدة (كتالوج الإشعارات 34)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `channel` | `text` | 🔑 ✱ |  |
| `lang` | `text` | 🔑 ✱ | `'ar'::text` |
| `subject` | `text` |  |  |
| `body` | `text` | ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `active` | `boolean` | ✱ | `true` |

### `crm.trip_rating` 

تقييم الرحلة (تذكرة واحدة = تقييم واحد) ويغذي ترتيب الناقل (7.7)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ticket_id` | `bigint` | 🔗 `sales.ticket` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `stars` | `smallint` | ✱ |  |
| `punctuality` | `smallint` |  |  |
| `comfort` | `smallint` |  |  |
| `staff` | `smallint` |  |  |
| `comment` | `text` |  |  |
| `moderation` | `text` | ✱ | `'VISIBLE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="gov"></a>
## `gov` — الحوكمة والالتزامات وحماية البيانات

### `gov.consent` 

الموافقات بإصدار السياسة وتاريخ السحب

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `purpose` | `text` | ✱ |  |
| `granted` | `boolean` | ✱ |  |
| `source` | `text` | ✱ |  |
| `policy_version` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `withdrawn_at` | `timestamp with time zone` |  |  |

### `gov.data_inventory` 

جرد البيانات وتصنيفها وغرضها ومدة احتفاظها (يقود الحذف الآلي)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `dataset` | `text` | 🔑 ✱ |  |
| `data_class` | `text` | ✱ |  |
| `owner` | `text` | ✱ |  |
| `purpose` | `text` | ✱ |  |
| `legal_basis` | `text` | ✱ |  |
| `retention_days` | `integer` |  |  |
| `location` | `text` | ✱ | `'PRIMARY_DC'::text` |
| `processors` | `text[]` | ✱ | `'{}'::text[]` |

### `gov.feature_compliance_review` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `feature` | `text` | ✱ |  |
| `dpia_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `obligations` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `decision` | `text` | ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.obligation_register` 

سجل الالتزامات التشريعية وربطها بالضوابط والأدلة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `source` | `text` | ✱ |  |
| `ref_no` | `text` | ✱ |  |
| `title_ar` | `text` | ✱ |  |
| `effective_date` | `date` |  |  |
| `control_ref` | `text` |  |  |
| `evidence_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `owner_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `next_review` | `date` |  |  |

### `gov.partner_dpa` 

اتفاقيات معالجة البيانات مع الشركاء والمزودين

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `purpose` | `text` | ✱ |  |
| `data_fields` | `text[]` | ✱ |  |
| `retention_days` | `integer` | ✱ |  |
| `processing_location` | `text` |  |  |
| `signed_at` | `date` | ✱ |  |
| `review_at` | `date` | ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |

### `gov.policy_authority` 

من يقرر في كل مجال سياسة (المنصة، الناقل ضمن حدود، الجهة الناظمة، مزدوج)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `domain_code` | `text` | 🔗 `gov.policy_domain` ✱ |  |
| `scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `mode` | `text` | ✱ |  |
| `version` | `integer` | ✱ |  |
| `effective_from` | `timestamp with time zone` | ✱ |  |
| `decision_doc_sha256` | `bytea` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `approved_by` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.policy_change` 

تغيير سياسة بإصدار واعتماد بحسب المصفوفة؛ المقترح لا يعتمد نفسه

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `domain_code` | `text` | 🔗 `gov.policy_domain` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `version` | `integer` | ✱ |  |
| `proposed_value` | `jsonb` | ✱ |  |
| `proposer_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approvers` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `authority_snapshot` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `effective_from` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.policy_domain` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name_ar` | `text` | ✱ |  |
| `class` | `text` | ✱ |  |
| `regulated_bounds` | `jsonb` |  |  |

### `gov.privacy_incident` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `detected_at` | `timestamp with time zone` | ✱ |  |
| `data_class` | `text` | ✱ |  |
| `affected_count` | `integer` |  |  |
| `description` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `notified_authority_at` | `timestamp with time zone` |  |  |
| `notified_subjects_at` | `timestamp with time zone` |  |  |
| `security_event_id` | `bigint` | 🔗 `sec.security_event`  |  |

### `gov.subject_request` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `kind` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'RECEIVED'::text` |
| `due_at` | `timestamp with time zone` | ✱ |  |
| `result` | `text` |  |  |
| `handled_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sec"></a>
## `sec` — الأمن: قواعد IP والمخاطر والتوقيع ووحدة الأمن

### `sec.access_review` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔗 `iam.role`  |  |
| `reviewer_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `decision` | `text` | ✱ |  |
| `reviewed_on` | `date` | ✱ | `CURRENT_DATE` |

### `sec.authority_data_request` 

طلب بيانات رسمي بتفويض ثنائي؛ لا تسليم لأي جهة خارج هذا المسار

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `official_ref` | `text` | ✱ |  |
| `legal_basis` | `text` | ✱ |  |
| `scope` | `jsonb` | ✱ |  |
| `requested_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `delivered_at` | `timestamp with time zone` |  |  |
| `delivery_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.authority_order` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `order_ref` | `text` | ✱ |  |
| `order_type` | `text` | ✱ |  |
| `target_type` | `text` | ✱ |  |
| `target_id` | `bigint` | ✱ |  |
| `status` | `text` | ✱ | `'RECEIVED'::text` |
| `received_at` | `timestamp with time zone` | ✱ | `now()` |
| `executed_at` | `timestamp with time zone` |  |  |
| `executed_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sec.authority_policy` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `applies_to` | `jsonb` | ✱ |  |
| `checkpoint` | `text` | ✱ |  |
| `mandatory` | `boolean` | ✱ | `true` |
| `decision_map` | `jsonb` | ✱ | `'{}'::jsonb` |

### `sec.authority_profile` 

تعريف الجهة الأمنية ومحوّلها (تعريف بلا ربط في المرحلة 1 — القرار 88)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `authority_type` | `text` | ✱ |  |
| `protocol` | `text` | ✱ |  |
| `endpoint` | `text` |  |  |
| `cert_ref` | `text` |  |  |
| `data_scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `fail_policy` | `text` | ✱ | `'ALLOW_QUEUE'::text` |
| `sla_ms` | `integer` |  |  |
| `active` | `boolean` | ✱ | `false` |

### `sec.blocklist_entry` 

قائمة حظر بالقيم المجزأة (جهاز، هاتف، IBAN، وثيقة)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `entry_type` | `text` | ✱ |  |
| `value_hash` | `bytea` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `added_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` |  |  |

### `sec.break_glass_log` 

وصول الطوارئ بصلاحيات مرتفعة: بسبب وموافقة ومدة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `actor_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `reason` | `text` | ✱ |  |
| `approver_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `ended_at` | `timestamp with time zone` |  |  |

### `sec.document_signature` 

كل مستند رسمي يصدره الخادم موقّعاً؛ صفحة التحقق تقارن به فيُكشف أي مستند معدَّل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `doc_type` | `text` | ✱ |  |
| `doc_ref_id` | `bigint` | ✱ |  |
| `serial_no` | `text` | ✱ |  |
| `sha256` | `bytea` | ✱ |  |
| `signature` | `bytea` | ✱ |  |
| `key_id` | `integer` | 🔗 `sec.key_registry` ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |

### `sec.fraud_case` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `rule_code` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `assigned_to` | `bigint` | 🔗 `iam.app_user`  |  |
| `outcome` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `closed_at` | `timestamp with time zone` |  |  |

### `sec.ip_rule` 🛡️ 🔒

حجب/سماح/إبطاء عنوان أو نطاق أو دولة أو ASN لكل بوابة أو عميل API؛ يدوي أو آلي بمهلة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `rule_type` | `text` | ✱ |  |
| `cidr` | `cidr` |  |  |
| `country_code` | `character(2)` |  |  |
| `asn` | `integer` |  |  |
| `action` | `text` | ✱ |  |
| `scope` | `text` | ✱ | `'ALL'::text` |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `priority` | `smallint` | ✱ | `100` |
| `reason` | `text` | ✱ |  |
| `source` | `text` | ✱ | `'MANUAL'::text` |
| `evidence` | `jsonb` |  |  |
| `hit_count` | `bigint` | ✱ | `0` |
| `last_hit_at` | `timestamp with time zone` |  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` |  |  |
| `revoked_at` | `timestamp with time zone` |  |  |
| `revoked_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `revoke_reason` | `text` |  |  |

### `sec.key_registry` 

سجل مفاتيح التشفير والتوقيع (16.8 و16.18): المرجع فقط، والمفتاح في KMS؛ كل حقل مشفر يحمل key_id

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `integer` | 🔑 ✱ | `identity` |
| `key_ref` | `text` | ✱ |  |
| `purpose` | `text` | ✱ |  |
| `data_class` | `text` | ✱ | `'RESTRICTED'::text` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `algorithm` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `rotated_at` | `timestamp with time zone` |  |  |
| `expires_at` | `timestamp with time zone` |  |  |

### `sec.manifest_submission` 

المنافست (يدوي في المرحلة 1) بإصدارات وتوقيع

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile`  |  |
| `manifest_type` | `text` | ✱ |  |
| `version` | `integer` | ✱ |  |
| `payload_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `sha256` | `bytea` | ✱ |  |
| `signature` | `bytea` |  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `ack_ref` | `text` |  |  |
| `retry_count` | `smallint` | ✱ | `0` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `sent_at` | `timestamp with time zone` |  |  |

### `sec.risk_assessment` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` |  |  |
| `event_type` | `text` | ✱ |  |
| `score` | `smallint` | ✱ |  |
| `signals` | `jsonb` | ✱ |  |
| `decision` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.screening_request` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `context_type` | `text` | ✱ |  |
| `context_id` | `bigint` | ✱ |  |
| `identifier_hash` | `bytea` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `requested_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.screening_result` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `request_id` | `bigint` | 🔑 🔗 `sec.screening_request` ✱ |  |
| `decision` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `silent_flag` | `boolean` | ✱ | `false` |
| `response_ref` | `text` |  |  |
| `valid_until` | `timestamp with time zone` |  |  |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.security_event` 🛡️ 🔒

الأحداث الأمنية لمركز العمليات (SOC) وقواعد الكشف (16.20)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `source` | `text` | ✱ |  |
| `severity` | `text` | ✱ |  |
| `category` | `text` | ✱ |  |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `ip` | `inet` |  |  |
| `details` | `jsonb` | ✱ |  |
| `correlation_id` | `uuid` |  |  |
| `ip_rule_id` | `bigint` | 🔗 `sec.ip_rule`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.sos_event` 



| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `triggered_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `notified` | `jsonb` | ✱ | `'[]'::jsonb` |
| `incident_id` | `bigint` | 🔗 `ops.incident`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.tamper_event` 🔒

محاولات إرسال قيم تخالف المحسوب في الخادم (سعر، تاريخ، حالة دفع)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `ip` | `inet` |  |  |
| `endpoint` | `text` | ✱ |  |
| `field` | `text` | ✱ |  |
| `client_value` | `text` |  |  |
| `server_value` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.watchlist_entry` 

قائمة المراقبة والمنع بالمطابقة المجزأة دون نسخ البيانات الكاملة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile`  |  |
| `identifier_type` | `text` | ✱ |  |
| `identifier_hash` | `bytea` | ✱ |  |
| `action` | `text` | ✱ |  |
| `valid` | `tstzrange` | ✱ |  |
| `source_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |

<a id="audit"></a>
## `audit` — سجلات الدخول والإجراءات (إلحاق فقط)

### `audit.activity_log` 🧩 🔒

كل طلب أو إجراء في المنصة أو عبر API: من، متى، من أين، ماذا، على أي كيان، والنتيجة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ts` | `timestamp with time zone` | 🔑 ✱ | `now()` |
| `request_id` | `uuid` |  |  |
| `actor_type` | `text` | ✱ |  |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `company_id` | `bigint` |  |  |
| `session_id` | `bigint` |  |  |
| `portal` | `text` |  |  |
| `ip` | `inet` |  |  |
| `user_agent` | `text` |  |  |
| `http_method` | `text` |  |  |
| `endpoint` | `text` |  |  |
| `action` | `text` | ✱ |  |
| `object_type` | `text` |  |  |
| `object_id` | `bigint` |  |  |
| `object_uid` | `uuid` |  |  |
| `result` | `text` | ✱ |  |
| `http_status` | `smallint` |  |  |
| `latency_ms` | `integer` |  |  |
| `reason` | `text` |  |  |
| `changes` | `jsonb` |  |  |
| `row_hash` | `bytea` |  |  |

### `audit.auth_event` 🧩 🔒

كل محاولة دخول أو خروج أو تحقق أو استخدام مفتاح API، ناجحة أو فاشلة، بالعنوان والجهاز والبوابة

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ts` | `timestamp with time zone` | 🔑 ✱ | `now()` |
| `event` | `text` | ✱ |  |
| `actor_type` | `text` | ✱ |  |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `api_key_id` | `bigint` |  |  |
| `identifier_hash` | `bytea` |  |  |
| `portal` | `text` |  |  |
| `company_id` | `bigint` |  |  |
| `session_id` | `bigint` |  |  |
| `device_id` | `bigint` |  |  |
| `ip` | `inet` | ✱ |  |
| `country_code` | `character(2)` |  |  |
| `asn` | `integer` |  |  |
| `user_agent` | `text` |  |  |
| `result` | `text` | ✱ |  |
| `reason` | `text` |  |  |
| `request_id` | `uuid` |  |  |
| `row_hash` | `bytea` |  |  |

### `audit.data_access_log` 🧩 🔒

كل كشف لحقل سري (جواز، هوية، IBAN) بالسبب

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ts` | `timestamp with time zone` | 🔑 ✱ | `now()` |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `company_id` | `bigint` |  |  |
| `ip` | `inet` |  |  |
| `object_type` | `text` | ✱ |  |
| `object_id` | `bigint` | ✱ |  |
| `fields` | `text[]` | ✱ |  |
| `purpose` | `text` | ✱ |  |
| `request_id` | `uuid` |  |  |
| `row_hash` | `bytea` |  |  |

### `audit.log_seal` 🔒

ختم دوري لكتل السجلات بسلسلة تجزئة (وتوقيع KMS) يكشف أي حذف أو تعديل

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `log_name` | `text` | ✱ |  |
| `from_id` | `bigint` | ✱ |  |
| `to_id` | `bigint` | ✱ |  |
| `row_count` | `bigint` | ✱ |  |
| `block_hash` | `bytea` | ✱ |  |
| `prev_seal_hash` | `bytea` |  |  |
| `seal_hash` | `bytea` | ✱ |  |
| `key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `signature` | `bytea` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `audit.row_change` 🧩 🔒

التقاط آلي لأي تغيير على الجداول الحساسة حتى لو تم خارج التطبيق (مع هوية المستخدم من سياق الطلب)

| العمود | النوع | قيود | افتراضي |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ts` | `timestamp with time zone` | 🔑 ✱ | `now()` |
| `schema_name` | `text` | ✱ |  |
| `table_name` | `text` | ✱ |  |
| `op` | `character(1)` | ✱ |  |
| `row_pk` | `text` |  |  |
| `old_values` | `jsonb` |  |  |
| `new_values` | `jsonb` |  |  |
| `db_user` | `text` | ✱ | `CURRENT_USER` |
| `user_id` | `bigint` |  |  |
| `api_client_id` | `bigint` |  |  |
| `company_id` | `bigint` |  |  |
| `request_id` | `uuid` |  |  |
| `ip` | `inet` |  |  |
| `txid` | `bigint` | ✱ | `txid_current()` |
| `row_hash` | `bytea` |  |  |
