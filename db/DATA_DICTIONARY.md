# Data Dictionary — Masslak Database (Phase 1)

> Generated from the built database (`db/tools/gen_docs.py`); do not edit by hand.

**183 tables, 1893 columns, in 14 schemas.**

Legend: 🔑 primary key · 🔗 foreign key · ✱ required · 🛡️ tenant isolation (RLS) · 🧩 partitioned monthly · 🔒 append-only / change-protected

## Index

- [`iam` — Identity, parties, users, permissions and API clients](#iam) (23 tables)
- [`ref` — Reference data, locales and files](#ref) (7 tables)
- [`sys` — Settings, outbox and webhooks](#sys) (6 tables)
- [`net` — Network: stations, routes and carrier codes](#net) (8 tables)
- [`fleet` — Fleet: vehicles, seats, crew, licenses and insurance](#fleet) (12 tables)
- [`pricing` — Pricing, taxes, commissions, campaigns and loyalty](#pricing) (19 tables)
- [`ops` — Trips, inventory, operations, tracking and incidents](#ops) (17 tables)
- [`sales` — Channels, bookings, passengers and tickets](#sales) (8 tables)
- [`fin` — Wallets, ledger, payments, allocation and settlement](#fin) (16 tables)
- [`acct` — Simplified accounting, e-invoicing and tax profiles](#acct) (24 tables)
- [`crm` — Complaints, ratings, notifications and the AI assistant](#crm) (9 tables)
- [`gov` — Governance, obligations and data protection](#gov) (10 tables)
- [`sec` — Security: IP rules, risk, signing and the security hub](#sec) (19 tables)
- [`audit` — Login and activity logs (append-only)](#audit) (5 tables)

<a id="iam"></a>
## `iam` — Identity, parties, users, permissions and API clients

### `iam.api_client` 🛡️

API clients (carrier, channel, partner, authority): scopes, rate limit, IP allowlist and optional mTLS

| Column | Type | Constraints | Default |
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

Hashed API keys; at most two active keys during rotation

| Column | Type | Constraints | Default |
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

Login account; the account kind determines the portal: platform, company, agency, customer

| Column | Type | Constraints | Default |
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
| `preferred_locale` | `text` | 🔗 `ref.locale` ✱ | `'en'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.auth_token` 

Invitation, reset and OTP tokens (single use, stored hashed)

| Column | Type | Constraints | Default |
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

Bank accounts for withdrawals and settlement (encrypted IBAN)

| Column | Type | Constraints | Default |
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

Beneficial owners of the company (compliance and security)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `ownership_pct` | `numeric(5,2)` | ✱ |  |

### `iam.biometric_template` 

Facial biometric template, encrypted with a separate key and stored in isolation (3.8 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `template_enc` | `bytea` | ✱ |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry` ✱ |  |
| `algorithm` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `retain_until` | `timestamp with time zone` | ✱ |  |

### `iam.company` 🛡️

Carrier company (tenant): 1:1 profile with party; all company data is isolated by company_id

| Column | Type | Constraints | Default |
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

Company users (seats) and their role; one owner per company, not editable from inside the company

| Column | Type | Constraints | Default |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `role_id` | `bigint` | 🔗 `iam.role`  |  |
| `is_owner` | `boolean` | ✱ | `false` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.device` 

Registered devices per user (3.5, 16.8); a new operator device requires approval

| Column | Type | Constraints | Default |
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

Documents for any entity (polymorphic reference) with file, review and expiry date

| Column | Type | Constraints | Default |
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

Link between the account and the national digital identity (readiness for a Nafath-style system)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `provider_id` | `bigint` | 🔑 🔗 `iam.identity_provider` ✱ |  |
| `subject_ref_bidx` | `bytea` | ✱ |  |
| `assurance_level` | `text` |  |  |
| `linked_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_verified_at` | `timestamp with time zone` |  |  |

### `iam.identity_provider` 

Verification adapters: KYC vendor, national registry, telecom, digital identity (activated in Phase 5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country`  |  |
| `kind` | `text` | ✱ |  |
| `protocol` | `text` | ✱ |  |
| `config` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'INACTIVE'::text` |

### `iam.mfa_factor` 

MFA factors (TOTP with encrypted secret, passkeys, recovery codes)

| Column | Type | Constraints | Default |
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

Unified party: person, company or entity; registered once and holds multiple roles (passenger, driver, vehicle owner...)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `party_type` | `text` | ✱ |  |
| `legal_name` | `text` | ✱ |  |
| `name_latin` | `text` |  |  |
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

Party roles (several roles per party)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `role_code` | `text` | 🔑 ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `valid_from` | `date` | ✱ | `CURRENT_DATE` |
| `valid_to` | `date` |  |  |

### `iam.permission` 

Permission catalog (section 33)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `module` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `description` | `text` | ✱ |  |
| `is_sensitive` | `boolean` | ✱ | `false` |

### `iam.push_token` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `device_id` | `bigint` | 🔑 🔗 `iam.device` ✱ |  |
| `token` | `text` | ✱ |  |
| `consent` | `boolean` | ✱ | `true` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.role` 

Roles: platform roles, company role templates, and roles each company defines for itself (3.4 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `is_system` | `boolean` | ✱ | `false` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.role_permission` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `permission_code` | `text` | 🔑 🔗 `iam.permission` ✱ |  |

### `iam.user_role` 

Platform staff roles

| Column | Type | Constraints | Default |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `granted_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `granted_at` | `timestamp with time zone` | ✱ | `now()` |
| `valid_to` | `timestamp with time zone` |  |  |

### `iam.user_session` 

Active sessions; revoking one ends the login immediately

| Column | Type | Constraints | Default |
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

Record of every verification (identity levels L0..L3, company, vehicle, document); manual now, automatic after integration

| Column | Type | Constraints | Default |
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
## `ref` — Reference data, locales and files

### `ref.city` 

Cities (domestic and international)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `region` | `text` |  |  |
| `name` | `text` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `timezone` | `text` | ✱ | `'Asia/Damascus'::text` |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.country` 

Countries (Country Pack 12.4): Syria first, then expansion

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `character(2)` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `phone_prefix` | `text` |  |  |
| `default_currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.currency` 

Currencies; every amount in the system is a BIGINT in the minor unit of its currency

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `character(3)` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `minor_unit` | `smallint` | ✱ | `2` |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.exchange_rate` 

Exchange rates with an effective date; the rate used is fixed on every transaction (section 12)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `base_currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `quote_currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `rate` | `numeric(20,10)` | ✱ |  |
| `source` | `text` | ✱ | `'MANUAL'::text` |
| `valid_from` | `timestamp with time zone` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.file_object` 

Metadata for every uploaded file (documents, images, signed PDFs); content is in encrypted object storage

| Column | Type | Constraints | Default |
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

### `ref.locale` 

Supported UI locales with text direction; English is the system default, other locales are UI-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `native_name` | `text` |  |  |
| `direction` | `text` | ✱ | `'LTR'::text` |
| `is_enabled` | `boolean` | ✱ | `false` |
| `is_default` | `boolean` | ✱ | `false` |

### `ref.translation` 

Localized display values for reference data; the English value in the source row is the fallback

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `entity` | `text` | ✱ |  |
| `entity_key` | `text` | ✱ |  |
| `field` | `text` | ✱ |  |
| `locale` | `text` | 🔗 `ref.locale` ✱ |  |
| `value` | `text` | ✱ |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sys"></a>
## `sys` — Settings, outbox and webhooks

### `sys.company_setting` 🛡️

Per-carrier settings (post-departure sales policy, cutoffs, seat selection modes...)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` |  |  |

### `sys.outbox_event` 

Transactional outbox: written in the same transaction as the change, then published to services and partners

| Column | Type | Constraints | Default |
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

Applied schema versions

| Column | Type | Constraints | Default |
|---|---|---|---|
| `version` | `text` | 🔑 ✱ |  |
| `description` | `text` |  |  |
| `checksum` | `text` |  |  |
| `applied_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.setting` 

Global settings and feature flags (full-build, activate-by-configuration principle 2.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `scope` | `text` | ✱ | `'PLATFORM'::text` |
| `description` | `text` |  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sys.webhook_delivery` 

Delivery attempts, retries and dead letters (DEAD)

| Column | Type | Constraints | Default |
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

Webhook subscriptions for partners and integrations (14, 13.10), signed with HMAC-SHA256

| Column | Type | Constraints | Default |
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
## `net` — Network: stations, routes and carrier codes

### `net.carrier_code` 

Three-letter carrier code (optional two-character code), unique platform-wide and not reissued for 24 months

| Column | Type | Constraints | Default |
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

Reserved, prohibited or temporarily withdrawn codes

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `reason` | `text` | ✱ |  |
| `until` | `date` |  |  |

### `net.compliance_profile` 

Versioned compliance profile per (country, class): required fields and completion grace period (4.11 b)

| Column | Type | Constraints | Default |
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

Carrier route template between two stations; its stops are copied to the trip when generated (the approved line catalog 4.15 is added in Phase 2)

| Column | Type | Constraints | Default |
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

Ordered route stops, time offsets and the fare ladder from the origin

| Column | Type | Constraints | Default |
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

Recurring service number from its type block; never repeated for a carrier in an overlapping period

| Column | Type | Constraints | Default |
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

Register of stations and departure/arrival points (central, company point, external) with a unique code (4.11)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `station_class` | `text` | ✱ |  |
| `subtype` | `text` | ✱ | `'TERMINAL'::text` |
| `owner_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name` | `text` | ✱ |  |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `role` | `text` |  |  |
| `name` | `text` | ✱ |  |
| `phone` | `text` |  |  |
| `email` | `citext` |  |  |

<a id="fleet"></a>
## `fleet` — Fleet: vehicles, seats, crew, licenses and insurance

### `fleet.crew_profile` 🛡️

Drivers and hosts; their licenses and dates live in fleet.license_record

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `crew_type` | `text` | ✱ |  |
| `license_class` | `text` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.field_check_log` 

Every field query by security officers and authorized bodies

| Column | Type | Constraints | Default |
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

Insurance contract, required to activate the vehicle; later verified with the traffic authority or insurers (7.12 a)

| Column | Type | Constraints | Default |
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

Change request for a locked license: review, then approval by a different officer

| Column | Type | Constraints | Default |
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

Every expiry date that governs operating eligibility (license, inspection, insurance, driving license); locked after saving

| Column | Type | Constraints | Default |
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

Reusable seat layouts

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name` | `text` | ✱ |  |
| `total_seats` | `smallint` | ✱ |  |
| `decks` | `smallint` | ✱ | `1` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.seat_layout_seat` 

Passenger seats in the layout (crew seats are not part of the inventory, 4.14)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `layout_id` | `bigint` | 🔑 🔗 `fleet.seat_layout` ✱ |  |
| `seat_no` | `smallint` | 🔑 ✱ |  |
| `label` | `text` |  |  |
| `row_no` | `smallint` | ✱ |  |
| `col_no` | `smallint` | ✱ |  |
| `deck` | `smallint` | ✱ | `1` |
| `cabin` | `text` | ✱ | `'ECONOMY'::text` |

### `fleet.seat_price_rule` 🛡️

Premium or discounted seat prices set by the carrier (4.14 a)

| Column | Type | Constraints | Default |
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

Vehicle: type, seated and standing capacity, ownership and owner, and the status that blocks assignment (4.3, 4.13, 4.17, 4.18)

| Column | Type | Constraints | Default |
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

Vehicle lease contract; one active lessee per vehicle per period (exclusion constraint)

| Column | Type | Constraints | Default |
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

Signed QR sticker on the vehicle for field verification (4.18 e)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |

### `fleet.vehicle_status_history` 

Vehicle status history (suspension after an incident, impoundment, release) with reason and evidence

| Column | Type | Constraints | Default |
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
## `pricing` — Pricing, taxes, commissions, campaigns and loyalty

### `pricing.allocation_template` 

Template of the price allocation tree across beneficiaries (carrier, platform, tax, intermediary)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Campaign: audience, scope, benefit, funding, budget and limits (condition -> action)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Commission scheme (platform, intermediary, payment, referral) with funder, beneficiary and versions

| Column | Type | Constraints | Default |
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

Fare brands with ticket, baggage and refund conditions; a snapshot is copied to the ticket

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name` | `text` | ✱ |  |
| `factor` | `numeric(6,4)` | ✱ | `1` |
| `rules` | `jsonb` | ✱ |  |
| `sort` | `smallint` | ✱ | `0` |
| `active` | `boolean` | ✱ | `true` |

### `pricing.fare_table` 

Central (locked) fare table or carrier fare table within limits (5.2)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `fare_table_id` | `bigint` | 🔑 🔗 `pricing.fare_table` ✱ |  |
| `from_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `to_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `cabin` | `text` | 🔑 ✱ | `'ECONOMY'::text` |
| `passenger_category` | `text` | 🔑 ✱ | `'ADULT'::text` |
| `base_price` | `bigint` | ✱ |  |

### `pricing.jurisdiction` 

Tax jurisdiction (country, region, border crossing, local)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `level` | `text` | ✱ |  |
| `parent_id` | `bigint` | 🔗 `pricing.jurisdiction`  |  |
| `name` | `text` | ✱ |  |

### `pricing.loyalty_program` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `point_value` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `expiry_months` | `smallint` | ✱ | `24` |
| `tax_treatment` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.loyalty_rule` 



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `min_points` | `bigint` | ✱ | `0` |
| `benefits` | `jsonb` | ✱ | `'{}'::jsonb` |

### `pricing.points_account` 

Points account; the balance is stored and reconciled with the points ledger

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `tier_id` | `bigint` | 🔗 `pricing.loyalty_tier`  |  |
| `balance` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.points_ledger` 🔒

Points ledger: append-only, corrections by reversing entry

| Column | Type | Constraints | Default |
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

Dynamic pricing modifiers applied in order (5.3)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `campaign_id` | `bigint` | 🔗 `pricing.campaign` ✱ |  |
| `code` | `citext` | ✱ |  |
| `max_uses` | `integer` |  |  |
| `uses` | `integer` | ✱ | `0` |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |

### `pricing.rate_band` 

Calculation bands for a tax or commission rule

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Tax or fee scheme with its treatment, jurisdiction and collecting party, versioned with dual approval

| Column | Type | Constraints | Default |
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
## `ops` — Trips, inventory, operations, tracking and incidents

### `ops.crew_assignment` 

Crew assignment to the trip; an exclusion constraint prevents assigning a person to two overlapping trips

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `party_id` | `bigint` | 🔗 `fleet.crew_profile` ✱ |  |
| `crew_role` | `text` | ✱ |  |
| `busy` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'ASSIGNED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.family_zone` 

Family zones on the trip (4.14 a)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seat_nos` | `smallint[]` | ✱ |  |
| `label` | `text` | 🔑 ✱ | `'FAMILY'::text` |

### `ops.geo_event` 🧩

Tracking positions; partitioned monthly, short retention (16.13: 7 days by default for individuals); no FKs for insert performance

| Column | Type | Constraints | Default |
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

Incident or breakdown; a serious one takes the vehicle out of service immediately and requires a continuity decision

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object` ✱ |  |
| `kind` | `text` | ✱ |  |
| `uploaded_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.incident_external_link` 

Integration with traffic police, police and insurers (activated after government integration)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `authority` | `text` | ✱ |  |
| `external_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `last_sync_at` | `timestamp with time zone` |  |  |

### `ops.seat_segment` 

Seat inventory per segment (4.12 c): a seat is sellable for a pair if it is vacant in all of the pair's segments

| Column | Type | Constraints | Default |
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

Standing places counter per segment, never above capacity

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seg` | `smallint` | 🔑 ✱ |  |
| `capacity` | `smallint` | ✱ |  |
| `used` | `smallint` | ✱ | `0` |

### `ops.tracking_alert` 



| Column | Type | Constraints | Default |
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

Actual trip (the pivotal entity) with its number, vehicle, capacity, snapshots and policies; an exclusion constraint prevents vehicle conflicts

| Column | Type | Constraints | Default |
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

Trip change log with reasons (7.9)

| Column | Type | Constraints | Default |
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

Trip continuity decision: replacement, lease, interline, rescue, cancellation (7.12 c)

| Column | Type | Constraints | Default |
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

Exceptional price for a station pair exceeding the ladder difference

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `from_seq` | `smallint` | 🔑 ✱ |  |
| `to_seq` | `smallint` | 🔑 ✱ |  |
| `price` | `bigint` | ✱ |  |

### `ops.trip_stop` 

Trip stops (snapshot of the route) with promised and actual times and the fare ladder

| Column | Type | Constraints | Default |
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

Actual arrival and departure at each stop (basis of on-time performance 4.12 h)

| Column | Type | Constraints | Default |
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

Recurring trip pattern that generates the actual trips

| Column | Type | Constraints | Default |
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

Swapping the trip vehicle without changing the trip number (4.16 d)

| Column | Type | Constraints | Default |
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
## `sales` — Channels, bookings, passengers and tickets

### `sales.boarding_event` 🔒

Boarding and alighting scan events (basis for dispatch, settlement and the manifest); append-only

| Column | Type | Constraints | Default |
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

Booking: price snapshot, channel, allocation tree and idempotency key; statuses per section 28

| Column | Type | Constraints | Default |
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

Campaign use on a booking and who funds the discount

| Column | Type | Constraints | Default |
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

Sales channel (direct, counter, agency, API partner); agreements and quotas come in Phase 9

| Column | Type | Constraints | Default |
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

Name rule (constraint `passenger_name_parts`, migration 1.2.0): every new passenger has a nationality, first name and family name; Syrian citizens (`nationality = 'SY'`) also need the father's and grandfather's names. Other nationalities enter the names exactly as on the passport or ID, with the father's and grandfather's names only when the document carries them. `full_name` is the composed display name in document order.

Passenger data on the booking; document numbers encrypted with a blind index for security screening and the manifest

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `booking_id` | `bigint` | 🔗 `sales.booking` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `full_name` | `text` | ✱ |  |
| `first_name` | `text` |  |  |
| `father_name` | `text` |  |  |
| `grandfather_name` | `text` |  |  |
| `last_name` | `text` |  |  |
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

Passenger compensation for cancellation or disruption, charged to the carrier at fault

| Column | Type | Constraints | Default |
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

Refund request with a policy snapshot; funds are not released before the credit note is finalized (BR-EIN-03)

| Column | Type | Constraints | Default |
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

Ticket per passenger and station pair, with a numbered, guaranteed or standing place, a conditions snapshot and a signed QR

| Column | Type | Constraints | Default |
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
## `fin` — Wallets, ledger, payments, allocation and settlement

### `fin.bank_reconciliation` 

Daily reconciliation: bank balance = total wallets + receivables

| Column | Type | Constraints | Default |
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

Wallet top-up by bank transfer with a unique reference and automatic matching

| Column | Type | Constraints | Default |
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

Ledger entry (debit/credit); append-only, updates the wallet balance atomically

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `txn_id` | `bigint` | 🔗 `fin.ledger_txn` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet` ✱ |  |
| `direction` | `character(2)` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `balance_after` | `bigint` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.ledger_txn` 🔒

Ledger transaction header; immutable, and the idempotency key prevents double posting

| Column | Type | Constraints | Default |
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

Payment; becomes SUCCESS only with a signed gateway notification and a ledger entry (16.25)

| Column | Type | Constraints | Default |
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

Signed gateway notifications as received (source of payment status, deduplication)

| Column | Type | Constraints | Default |
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

Payment provider behind a unified, replaceable adapter

| Column | Type | Constraints | Default |
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

Bank payout to the carrier according to its schedule

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Price allocation tree header for each booking, ticket or shipment

| Column | Type | Constraints | Default |
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

Tree lines: fare, tax, commission, fee, discount; each leaf is released to its beneficiary's wallet on its event

| Column | Type | Constraints | Default |
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

Carrier settlement statement for a period; periods never overlap

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Ledger of taxes collected and refunded per scheme, jurisdiction and period (basis of the tax return)

| Column | Type | Constraints | Default |
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

Wallet: user, company, platform, escrow, commission, tax, clearing; the balance is reconciled with the entries

| Column | Type | Constraints | Default |
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

Withdrawal request with limits, review and two approvals for large amounts

| Column | Type | Constraints | Default |
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
## `acct` — Simplified accounting, e-invoicing and tax profiles

### `acct.account_mapping` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `connection_id` | `bigint` | 🔑 🔗 `acct.accounting_connection` ✱ |  |
| `local_type` | `text` | 🔑 ✱ |  |
| `local_id` | `bigint` | 🔑 ✱ |  |
| `external_id` | `text` | ✱ |  |
| `external_name` | `text` |  |  |

### `acct.accounting_connection` 🛡️

Link between the platform or a company and an external accounting system (Odoo, Zoho, Al-Ameen, file, API)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |

### `acct.einvoice_activation` 

Phased mandate activation per taxpayer category, document type and date

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `doc_type` | `text` | ✱ |  |
| `taxpayer_category` | `text` | ✱ | `'*'::text` |
| `mandatory_from` | `timestamp with time zone` | ✱ |  |
| `mode` | `text` | ✱ |  |
| `active` | `boolean` | ✱ | `false` |

### `acct.einvoice_document` 🛡️ 🔒

Invoice, credit note and debit note; after finalization only the status and the authority's response may change, and deletion is never allowed

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Every submission attempt to the government authority and its response as received (append-only)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `version` | `integer` | ✱ |  |
| `fields` | `jsonb` | ✱ |  |
| `qr_encoding` | `text` | ✱ | `'TLV_BASE64'::text` |
| `xml_schema_ref` | `text` |  |  |
| `valid_from` | `timestamp with time zone` | ✱ |  |

### `acct.einvoice_unit` 

Issuing unit per seller: counter, last invoice hash and certificate

| Column | Type | Constraints | Default |
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

Simplified chart of accounts per book (platform or company) from an editable template (13.3)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `account_type` | `text` | ✱ |  |
| `parent_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `is_postable` | `boolean` | ✱ | `true` |
| `external_code` | `text` |  |  |
| `active` | `boolean` | ✱ | `true` |

### `acct.gl_period` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `period` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `closed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `closed_at` | `timestamp with time zone` |  |  |

### `acct.journal_entry` 🛡️ 🔒

Journal entry; after posting it is never modified, corrections by reversing entry

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Posting rules: events become journal entries; no module writes to the ledger directly (13.4)

| Column | Type | Constraints | Default |
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

Log of journal entries and invoices pushed to the external system via API, with retries and deduplication (13.12)

| Column | Type | Constraints | Default |
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

Tax authority and its adapter: generation mode before integration, then reporting or clearance

| Column | Type | Constraints | Default |
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

Taxes and fees collected from a party without a tax file (transit, flat-rate) with a collection receipt

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Tax profile of each company, owner or partner, with non-overlapping time versions

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority`  |  |
| `tax_status` | `text` | ✱ |  |
| `tax_no` | `text` |  |  |
| `cr_no` | `text` |  |  |
| `branch_code` | `text` |  |  |
| `legal_name` | `text` | ✱ |  |
| `einvoice_mandatory` | `boolean` | ✱ | `false` |
| `issuer_mode` | `text` | ✱ | `'PLATFORM'::text` |
| `verified_source` | `text` | ✱ | `'MANUAL'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `valid` | `tstzrange` | ✱ | `tstzrange(now(), NULL::timestamp with...` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.tax_profile_field` 

Dynamic tax fields added by the administrator per country or authority without code changes

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority`  |  |
| `code` | `text` | ✱ |  |
| `label` | `text` | ✱ |  |
| `data_type` | `text` | ✱ |  |
| `required` | `boolean` | ✱ | `false` |
| `validation` | `jsonb` |  |  |

### `acct.tax_profile_value` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `profile_id` | `bigint` | 🔑 🔗 `acct.tax_profile` ✱ |  |
| `field_id` | `bigint` | 🔑 🔗 `acct.tax_profile_field` ✱ |  |
| `value` | `jsonb` | ✱ |  |

### `acct.tax_registration` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `filing_frequency` | `text` | ✱ |  |
| `registered` | `daterange` | ✱ |  |

### `acct.tax_return` 

Draft tax return per taxpayer and period using the authority's form boxes

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `return_id` | `bigint` | 🔑 🔗 `acct.tax_return` ✱ |  |
| `box_code` | `text` | 🔑 ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `source_note` | `text` |  |  |

<a id="crm"></a>
## `crm` — Complaints, ratings, notifications and the AI assistant

### `crm.ai_conversation` 



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `conversation_id` | `bigint` | 🔗 `crm.ai_conversation` ✱ |  |
| `role` | `text` | ✱ |  |
| `redacted_text` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.ai_policy` 

Assistant tools, each tool's action level, limits and user confirmation requirement

| Column | Type | Constraints | Default |
|---|---|---|---|
| `tool` | `text` | 🔑 ✱ |  |
| `action_level` | `smallint` | ✱ |  |
| `limits` | `jsonb` | ✱ | `'{}'::jsonb` |
| `requires_confirmation` | `boolean` | ✱ | `true` |
| `enabled` | `boolean` | ✱ | `false` |

### `crm.ai_tool_call` 🔒

Every tool executed by the assistant with the customer's permissions and confirmation (append-only)

| Column | Type | Constraints | Default |
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

Complaint, claim or inquiry with service levels, compensation and segregation of duties (7.6)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Approved notification templates (notification catalog 34)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `channel` | `text` | 🔑 ✱ |  |
| `locale` | `text` | 🔑 🔗 `ref.locale` ✱ | `'en'::text` |
| `subject` | `text` |  |  |
| `body` | `text` | ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `active` | `boolean` | ✱ | `true` |

### `crm.trip_rating` 

Trip rating (one ticket = one rating), feeds carrier ranking (7.7)

| Column | Type | Constraints | Default |
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
## `gov` — Governance, obligations and data protection

### `gov.consent` 

Consents with policy version and withdrawal date

| Column | Type | Constraints | Default |
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

Data inventory with classification, purpose and retention (drives automatic deletion)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `feature` | `text` | ✱ |  |
| `dpia_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `obligations` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `decision` | `text` | ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.obligation_register` 

Register of legal obligations mapped to controls and evidence

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `source` | `text` | ✱ |  |
| `ref_no` | `text` | ✱ |  |
| `title` | `text` | ✱ |  |
| `effective_date` | `date` |  |  |
| `control_ref` | `text` |  |  |
| `evidence_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `owner_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `next_review` | `date` |  |  |

### `gov.partner_dpa` 

Data processing agreements with partners and providers

| Column | Type | Constraints | Default |
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

Who decides each policy domain (platform, carrier within limits, regulator, dual)

| Column | Type | Constraints | Default |
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

Versioned policy change approved according to the matrix; the proposer cannot approve

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `class` | `text` | ✱ |  |
| `regulated_bounds` | `jsonb` |  |  |

### `gov.privacy_incident` 



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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
## `sec` — Security: IP rules, risk, signing and the security hub

### `sec.access_review` 



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔗 `iam.role`  |  |
| `reviewer_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `decision` | `text` | ✱ |  |
| `reviewed_on` | `date` | ✱ | `CURRENT_DATE` |

### `sec.authority_data_request` 

Official data request with dual authorization; nothing is delivered to any authority outside this path

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `applies_to` | `jsonb` | ✱ |  |
| `checkpoint` | `text` | ✱ |  |
| `mandatory` | `boolean` | ✱ | `true` |
| `decision_map` | `jsonb` | ✱ | `'{}'::jsonb` |

### `sec.authority_profile` 

Security authority definition and its adapter (definition without integration in Phase 1 — Decision 88)

| Column | Type | Constraints | Default |
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

Blocklist of hashed values (device, phone, IBAN, document)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `entry_type` | `text` | ✱ |  |
| `value_hash` | `bytea` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `added_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` |  |  |

### `sec.break_glass_log` 

Break-glass access with elevated privileges: reason, approval and duration

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `actor_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `reason` | `text` | ✱ |  |
| `approver_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `ended_at` | `timestamp with time zone` |  |  |

### `sec.document_signature` 

Every official document issued by the server is signed; the verification page compares against it so any altered document is detected

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Block/allow/throttle an address, range, country or ASN per portal or API client; manual or automatic with expiry

| Column | Type | Constraints | Default |
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

Registry of encryption and signing keys (16.8, 16.18): references only, keys live in KMS; every encrypted field carries its key_id

| Column | Type | Constraints | Default |
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

Manifest (manual in Phase 1), versioned and signed

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Security events for the SOC and detection rules (16.20)

| Column | Type | Constraints | Default |
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



| Column | Type | Constraints | Default |
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

Attempts to submit values that contradict the server-side computation (price, date, payment status)

| Column | Type | Constraints | Default |
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

Watch and ban list with hashed matching, without copying full data

| Column | Type | Constraints | Default |
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
## `audit` — Login and activity logs (append-only)

### `audit.activity_log` 🧩 🔒

Every request or action on the platform or via API: who, when, from where, what, on which entity, and the result

| Column | Type | Constraints | Default |
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

Every login, logout, verification or API key use, successful or failed, with address, device and portal

| Column | Type | Constraints | Default |
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

Every reveal of a sensitive field (passport, ID, IBAN) with its reason

| Column | Type | Constraints | Default |
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

Periodic sealing of log blocks with a hash chain (and KMS signature) that reveals any deletion or modification

| Column | Type | Constraints | Default |
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

Automatic capture of any change to sensitive tables, even outside the application (with the user identity from the request context)

| Column | Type | Constraints | Default |
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
