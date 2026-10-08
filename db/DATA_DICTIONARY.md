# Data Dictionary — Masslak Database (study v2.6)

> Generated from the built database (`db/tools/gen_docs.py`); do not edit by hand.

**476 tables, 4920 columns, in 26 schemas.**

Legend: 🔑 primary key · 🔗 foreign key · ✱ required · 🛡️ tenant isolation (RLS) · 🧩 partitioned monthly · 🔒 append-only / change-protected

## Index

- [`iam` — Identity, parties, users, permissions and API clients](#iam) (32 tables)
- [`ref` — Reference data, locales and files](#ref) (13 tables)
- [`sys` — Settings, outbox and webhooks](#sys) (20 tables)
- [`net` — Network: stations, routes, lines, corridors and geofences](#net) (22 tables)
- [`fleet` — Fleet: vehicles, trucks, trailers, seats, crew, licenses and insurance](#fleet) (22 tables)
- [`pricing` — Pricing, taxes, commissions, campaigns and loyalty](#pricing) (35 tables)
- [`ops` — Trips, inventory, operations, shuttle rides, tracking and incidents](#ops) (32 tables)
- [`sales` — Channels, bookings, passengers, tickets, subscriptions and travel documents](#sales) (27 tables)
- [`fin` — Wallets, ledger, payments, allocation, settlement and float](#fin) (25 tables)
- [`acct` — Simplified accounting, e-invoicing and tax profiles](#acct) (35 tables)
- [`bill` — Carrier subscriptions, metering and platform invoices](#bill) (7 tables)
- [`crm` — Complaints, ratings, notifications, the AI assistant and the contact center](#crm) (19 tables)
- [`gov` — Governance, obligations and data protection](#gov) (14 tables)
- [`sec` — Security: IP rules, risk, signing, the security hub and government adapters](#sec) (25 tables)
- [`ptn` — Service partners: fuel stations, rest stops and maintenance](#ptn) (14 tables)
- [`ship` — Shipments and the integrated shipping network](#ship) (55 tables)
- [`frt` — Trucking, heavy transport and transit freight](#frt) (14 tables)
- [`brd` — Border manifest gateway](#brd) (10 tables)
- [`ctr` — Contracted transport: universities and employees](#ctr) (6 tables)
- [`sch` — School transport: schools, operators, pupils and guardians, contracts, routes, runs and attendance](#sch) (11 tables)
- [`gis` — PostGIS reference data](#gis) (1 tables)
- [`rail` — Rail extension](#rail) (5 tables)
- [`taxi` — Taxis](#taxi) (7 tables)
- [`rent` — Car rental](#rent) (15 tables)
- [`rpt` — Report definitions, runs and schedules](#rpt) (4 tables)
- [`audit` — Login and activity logs (append-only)](#audit) (6 tables)

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
| `description` | `text` |  |  |
| `contact_email` | `text` |  |  |
| `acting_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `payment_provider_id` | `bigint` | 🔗 `fin.payment_provider`  |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile`  |  |
| `status_reason` | `text` |  |  |

### `iam.api_key` 🛡️

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

### `iam.api_usage_daily` 🛡️

Calls per API client and day, for the client console and capacity planning

| Column | Type | Constraints | Default |
|---|---|---|---|
| `api_client_id` | `bigint` | 🔑 🔗 `iam.api_client` ✱ |  |
| `day` | `date` | 🔑 ✱ |  |
| `requests` | `integer` | ✱ | `0` |
| `errors` | `integer` | ✱ | `0` |
| `last_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.app_user` 🛡️

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

### `iam.auth_token` 🛡️

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

### `iam.bank_account` 🛡️

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
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `verified_at` | `timestamp with time zone` |  |  |

### `iam.beneficial_owner` 🛡️

Beneficial owners of the company (compliance and security)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `ownership_pct` | `numeric(5,2)` | ✱ |  |

### `iam.biometric_template` 🛡️

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
| `payout_bank_account_id` | `bigint` | 🔗 `iam.bank_account`  |  |

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

### `iam.device` 🛡️

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
| `attested_at` | `timestamp with time zone` |  |  |
| `attestation_provider` | `text` |  |  |

### `iam.device_permission_state` 🛡️

Current location and Nearby permissions per device; a change writes ops.permission_event

| Column | Type | Constraints | Default |
|---|---|---|---|
| `device_id` | `bigint` | 🔑 🔗 `iam.device` ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `location_permission` | `text` | ✱ |  |
| `location_services_on` | `boolean` | ✱ |  |
| `bluetooth_on` | `boolean` | ✱ |  |
| `nearby_permission` | `boolean` | ✱ |  |
| `app_version` | `text` |  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.document` 🛡️

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
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `uploaded_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `review_note` | `text` |  |  |
| `owner_lease_id` | `bigint` | 🔗 `fleet.vehicle_lease`  |  |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `owner_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `owner_license_id` | `bigint` | 🔗 `fleet.license_record`  |  |
| `owner_station_id` | `bigint` | 🔗 `net.station`  |  |
| `owner_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `owner_incident_id` | `bigint` | 🔗 `ops.incident`  |  |
| `owner_insurance_id` | `bigint` | 🔗 `fleet.insurance_policy`  |  |
| `retention_policy_id` | `bigint` | 🔗 `gov.retention_policy`  |  |
| `legal_hold` | `boolean` | ✱ | `false` |
| `anonymized_at` | `timestamp with time zone` |  |  |
| `erasure_request_id` | `bigint` | 🔗 `gov.subject_request`  |  |

### `iam.family` 🛡️

A passenger's family: the head pays for, books for and controls its members (4.20)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `head_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `name` | `text` | ✱ |  |
| `trips_wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.family_link_request` 🛡️

Linking a member's own account opened on another device: the member enters the head's code, the head approves the account and its funding (4.20 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `family_id` | `bigint` | 🔗 `iam.family` ✱ |  |
| `member_id` | `bigint` | 🔗 `iam.family_member` ✱ |  |
| `invite_code_hash` | `bytea` | ✱ |  |
| `requester_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `requester_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `device_label` | `text` |  |  |
| `device_hash` | `bytea` |  |  |
| `ip` | `inet` |  |  |
| `funding` | `text` |  |  |
| `attempts` | `smallint` | ✱ | `0` |
| `status` | `text` | ✱ | `'INVITED'::text` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `submitted_at` | `timestamp with time zone` |  |  |
| `decided_at` | `timestamp with time zone` |  |  |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.family_member` 🛡️

A member of a family with full identity details (document number encrypted); funding and limits apply to purchases the member makes on their own device (4.20)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `family_id` | `bigint` | 🔗 `iam.family` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `relation` | `text` | ✱ |  |
| `first_name` | `text` | ✱ |  |
| `father_name` | `text` |  |  |
| `grandfather_name` | `text` |  |  |
| `last_name` | `text` | ✱ |  |
| `nationality` | `character(2)` | 🔗 `ref.country` ✱ | `'SY'::bpchar` |
| `birth_date` | `date` | ✱ |  |
| `gender` | `text` |  |  |
| `id_type` | `text` |  |  |
| `id_no_enc` | `bytea` |  |  |
| `id_no_bidx` | `bytea` |  |  |
| `id_no_last4` | `text` |  |  |
| `passport_expiry` | `date` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `mobile` | `text` |  |  |
| `account_status` | `text` | ✱ | `'NONE'::text` |
| `linked_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `funding` | `text` | ✱ | `'HEAD_WALLET'::text` |
| `per_trip_limit` | `bigint` |  |  |
| `daily_limit` | `bigint` |  |  |
| `monthly_limit` | `bigint` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `retention_policy_id` | `bigint` | 🔗 `gov.retention_policy`  |  |
| `legal_hold` | `boolean` | ✱ | `false` |
| `anonymized_at` | `timestamp with time zone` |  |  |
| `erasure_request_id` | `bigint` | 🔗 `gov.subject_request`  |  |
| `mobile_enc` | `bytea` |  |  |
| `mobile_last4` | `text` |  |  |

### `iam.family_spend` 🛡️ 🔒

Every charge to the head's wallet or the family trips account on behalf of a member; limits are checked against it; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `family_id` | `bigint` | 🔗 `iam.family` ✱ |  |
| `member_id` | `bigint` | 🔗 `iam.family_member` ✱ |  |
| `source` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ref_type` | `text` | ✱ |  |
| `ref_id` | `bigint` | ✱ |  |
| `initiated_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.family_travel_rule` 🛡️

When and where a member may travel on the family's money: time windows by weekday, city-to-city routes, shuttle lines; no rule of a type means no limit of that type (4.20 d)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `member_id` | `bigint` | 🔗 `iam.family_member` ✱ |  |
| `rule_type` | `text` | ✱ |  |
| `days` | `smallint[]` |  |  |
| `start_time` | `time without time zone` |  |  |
| `end_time` | `time without time zone` |  |  |
| `from_city_id` | `bigint` | 🔗 `ref.city`  |  |
| `to_city_id` | `bigint` | 🔗 `ref.city`  |  |
| `both_ways` | `boolean` | ✱ | `true` |
| `line_id` | `bigint` | 🔗 `net.line`  |  |
| `active` | `boolean` | ✱ | `true` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.gov_identity_link` 🛡️

Link between the account and the national digital identity (readiness for a Nafath-style system)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `provider_id` | `bigint` | 🔑 🔗 `iam.identity_provider` ✱ |  |
| `subject_ref_bidx` | `bytea` | ✱ |  |
| `assurance_level` | `text` |  |  |
| `linked_at` | `timestamp with time zone` | ✱ | `now()` |
| `last_verified_at` | `timestamp with time zone` |  |  |

### `iam.identity_provider` 🛡️

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

### `iam.mfa_factor` 🛡️

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
| `last_used_step` | `bigint` |  |  |
| `label` | `text` |  |  |

### `iam.party` 🛡️

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
| `retention_policy_id` | `bigint` | 🔗 `gov.retention_policy`  |  |
| `legal_hold` | `boolean` | ✱ | `false` |
| `anonymized_at` | `timestamp with time zone` |  |  |
| `erasure_request_id` | `bigint` | 🔗 `gov.subject_request`  |  |

### `iam.party_role` 🛡️

Party roles (several roles per party)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `role_code` | `text` | 🔑 🔗 `ref.party_role_type` ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `valid_from` | `date` | ✱ | `CURRENT_DATE` |
| `valid_to` | `date` |  |  |

### `iam.permission` 🛡️

Permission catalog (section 33)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `module` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `description` | `text` | ✱ |  |
| `is_sensitive` | `boolean` | ✱ | `false` |

### `iam.push_token` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `device_id` | `bigint` | 🔑 🔗 `iam.device` ✱ |  |
| `token` | `text` | ✱ |  |
| `consent` | `boolean` | ✱ | `true` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `iam.role` 🛡️

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

### `iam.role_permission` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `permission_code` | `text` | 🔑 🔗 `iam.permission` ✱ |  |

### `iam.role_scope` 🛡️

Limits a role to some stations, routes, lines, cities, countries or trip types

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `role_id` | `bigint` | 🔗 `iam.role` ✱ |  |
| `scope_type` | `text` | ✱ |  |
| `scope_value` | `text` | ✱ |  |

### `iam.user_role` 🛡️

Platform staff roles

| Column | Type | Constraints | Default |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔑 🔗 `iam.role` ✱ |  |
| `granted_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `granted_at` | `timestamp with time zone` | ✱ | `now()` |
| `valid_to` | `timestamp with time zone` |  |  |

### `iam.user_session` 🛡️

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
| `mfa_failures` | `smallint` | ✱ | `0` |
| `access_expires_at` | `timestamp with time zone` |  |  |
| `prev_refresh_hash` | `bytea` |  |  |
| `client` | `text` | ✱ | `'web'::text` |

### `iam.user_station_scope` 🛡️

Station staff act only at their stations

| Column | Type | Constraints | Default |
|---|---|---|---|
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |

### `iam.verification` 🛡️

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
| `subject_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `subject_document_id` | `bigint` | 🔗 `iam.document`  |  |

<a id="ref"></a>
## `ref` — Reference data, locales and files

### `ref.cargo_category` 🛡️

Cargo categories as additional information for transit and freight (annex D.3)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `module` | `text` | ✱ | `'core'::text` |
| `is_system` | `boolean` | ✱ | `false` |
| `is_active` | `boolean` | ✱ | `true` |
| `sort` | `integer` | ✱ | `100` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `dangerous` | `boolean` | ✱ | `false` |
| `needs_temperature` | `boolean` | ✱ | `false` |

### `ref.city` 🛡️

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
| `timezone` | `text` | ✱ |  |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.country` 🛡️

Countries (Country Pack 12.4): Syria first, then expansion

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `character(2)` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `phone_prefix` | `text` |  |  |
| `default_currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.currency` 🛡️

Currencies; every amount in the system is a BIGINT in the minor unit of its currency

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `character(3)` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `minor_unit` | `smallint` | ✱ | `2` |
| `is_active` | `boolean` | ✱ | `true` |

### `ref.exchange_rate` 🛡️

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

### `ref.file_object` 🛡️

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
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `scan_status` | `text` | ✱ | `'PENDING'::text` |
| `scanned_at` | `timestamp with time zone` |  |  |
| `scan_engine` | `text` |  |  |
| `scan_detail` | `text` |  |  |
| `scan_attempts` | `integer` | ✱ | `0` |

### `ref.locale` 🛡️

Supported UI locales with text direction; English is the system default, other locales are UI-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `native_name` | `text` |  |  |
| `direction` | `text` | ✱ | `'LTR'::text` |
| `is_enabled` | `boolean` | ✱ | `false` |
| `is_default` | `boolean` | ✱ | `false` |

### `ref.party_role_type` 🛡️

Party roles (2.1); rows replace the former fixed list

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `module` | `text` | ✱ | `'core'::text` |
| `is_system` | `boolean` | ✱ | `false` |
| `is_active` | `boolean` | ✱ | `true` |
| `sort` | `integer` | ✱ | `100` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.seed_version` 🛡️

Version, hash and approval of each reference data set (review 3.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `dataset` | `text` | ✱ |  |
| `version` | `text` | ✱ |  |
| `sha256` | `bytea` | ✱ |  |
| `source` | `text` | ✱ |  |
| `signed_by` | `text` |  |  |
| `signature` | `bytea` |  |  |
| `effective` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `applied_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.station_subtype` 🛡️

Station subtypes (BORDER marks a border crossing point)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `module` | `text` | ✱ | `'core'::text` |
| `is_system` | `boolean` | ✱ | `false` |
| `is_active` | `boolean` | ✱ | `true` |
| `sort` | `integer` | ✱ | `100` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.translation` 🛡️

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

### `ref.trip_type` 🛡️

Trip types: one trip entity with many types (2.1)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `module` | `text` | ✱ | `'core'::text` |
| `is_system` | `boolean` | ✱ | `false` |
| `is_active` | `boolean` | ✱ | `true` |
| `sort` | `integer` | ✱ | `100` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ref.vehicle_class` 🛡️

Vehicle classes

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `module` | `text` | ✱ | `'core'::text` |
| `is_system` | `boolean` | ✱ | `false` |
| `is_active` | `boolean` | ✱ | `true` |
| `sort` | `integer` | ✱ | `100` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sys"></a>
## `sys` — Settings, outbox and webhooks

### `sys.city_rollout` 🛡️

Which city is opened for which service, and in which stage (shuttle city by city, owner decision 1042)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `feature_key` | `text` | 🔑 ✱ |  |
| `city_id` | `bigint` | 🔑 🔗 `ref.city` ✱ |  |
| `stage` | `smallint` | ✱ |  |
| `status` | `text` | ✱ | `'PLANNED'::text` |
| `opens_on` | `date` |  |  |
| `note` | `text` |  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.company_setting` 🛡️

Per-carrier settings (post-departure sales policy, cutoffs, seat selection modes...)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` |  |  |

### `sys.compliance_requirement` 🛡️

Licences, tracking and reporting duties a regulator may impose, each switched OFF, OPTIONAL or REQUIRED by configuration

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `domain` | `text` | ✱ |  |
| `applies_to` | `text` | ✱ | `'ALL'::text` |
| `subject_type` | `text` |  |  |
| `license_type` | `text` |  |  |
| `level` | `text` | ✱ | `'OPTIONAL'::text` |
| `required_from` | `date` |  |  |
| `authority` | `text` |  |  |
| `legal_ref` | `text` |  |  |
| `description` | `text` | ✱ |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sys.delivery_retry_request` 🛡️

A request to resend a money or authority event to a partner: applied only after a platform approval (audit T3-12)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `delivery_id` | `bigint` | 🔗 `sys.webhook_delivery` ✱ |  |
| `event_type` | `text` | ✱ |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `requested_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `reason` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decided_at` | `timestamp with time zone` |  |  |
| `decision_note` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.job_run` 🛡️

Every run of a scheduled job (daily upkeep), so monitoring can alert when one stops or fails (audit T3-16)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `job` | `text` | ✱ |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `finished_at` | `timestamp with time zone` |  |  |
| `ok` | `boolean` |  |  |
| `detail` | `jsonb` | ✱ | `'{}'::jsonb` |

### `sys.json_contract` 🛡️

Every JSONB column with its kind and contract version; RULES and SHAPE columns are validated on write, SNAPSHOT columns are frozen once written (third-party audit R-08)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `table_name` | `text` | 🔑 ✱ |  |
| `column_name` | `text` | 🔑 ✱ |  |
| `kind` | `text` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `spec` | `jsonb` |  |  |
| `note` | `text` |  |  |

### `sys.module_gate` 🛡️

Which feature switch opens the tables of each phase schema (review 3.10)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `schema_name` | `text` | 🔑 ✱ |  |
| `feature_keys` | `text[]` | ✱ |  |
| `phase` | `text` | ✱ |  |

### `sys.orphan_check` 🛡️

Result of each orphan sweep over the registered references; any orphan raises an integrity.orphans_found event

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `checked_at` | `timestamp with time zone` | ✱ | `now()` |
| `orphans` | `bigint` | ✱ |  |
| `findings` | `jsonb` | ✱ |  |

### `sys.outbox_event` 🛡️

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
| `schema_version` | `smallint` | ✱ | `1` |
| `correlation_id` | `uuid` |  | `sys.ctx_request_id()` |
| `aggregate_seq` | `bigint` |  |  |

### `sys.outbox_sequence` 🛡️

Last event number per aggregate; survives the purge of delivered events so numbers never repeat

| Column | Type | Constraints | Default |
|---|---|---|---|
| `aggregate_type` | `text` | 🔑 ✱ |  |
| `aggregate_id` | `bigint` | 🔑 ✱ |  |
| `last_seq` | `bigint` | ✱ |  |

### `sys.polymorphic_reference` 🛡️

Every (type, id) reference: TYPED ones are backed by real foreign keys, BUSINESS ones are swept for orphans weekly, METADATA ones outlive their rows on purpose (third-party audit R-03)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `table_name` | `text` | 🔑 ✱ |  |
| `type_col` | `text` | 🔑 ✱ |  |
| `id_col` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `targets` | `jsonb` | ✱ | `'{}'::jsonb` |
| `owner` | `text` | ✱ |  |
| `reason` | `text` | ✱ |  |

### `sys.project_phase` 🛡️

Project phases of the study roadmap (22); Phase 1 split into releases 1A and 1B (review decision 3)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `ordinal` | `numeric(4,1)` | ✱ |  |
| `name` | `text` | ✱ |  |
| `study_ref` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `feature_keys` | `text[]` | ✱ | `'{}'::text[]` |

### `sys.requirement_change` 🛡️

Every change of a regulatory requirement: proposed with its measured impact, decided by a second person (audit T3-14)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | 🔗 `sys.compliance_requirement` ✱ |  |
| `from_level` | `text` | ✱ |  |
| `to_level` | `text` | ✱ |  |
| `required_from` | `date` |  |  |
| `reason` | `text` | ✱ |  |
| `impact` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'PROPOSED'::text` |
| `proposed_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `proposed_at` | `timestamp with time zone` | ✱ | `now()` |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decided_at` | `timestamp with time zone` |  |  |
| `decision_note` | `text` |  |  |

### `sys.schema_file` 🛡️

Schema files applied to this database, with their SHA-256 at the time

| Column | Type | Constraints | Default |
|---|---|---|---|
| `file` | `text` | 🔑 ✱ |  |
| `sha256` | `text` | ✱ |  |
| `applied_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.schema_migration` 🛡️

Applied schema versions

| Column | Type | Constraints | Default |
|---|---|---|---|
| `version` | `text` | 🔑 ✱ |  |
| `description` | `text` |  |  |
| `checksum` | `text` |  |  |
| `applied_at` | `timestamp with time zone` | ✱ | `now()` |

### `sys.setting` 🛡️

Global settings and feature flags (full-build, activate-by-configuration principle 2.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `key` | `text` | 🔑 ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `scope` | `text` | ✱ | `'PLATFORM'::text` |
| `description` | `text` |  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sys.table_class` 🛡️

Data class of every table (review 3.2). A test fails when a table has no class or its RLS does not match its class

| Column | Type | Constraints | Default |
|---|---|---|---|
| `table_name` | `text` | 🔑 ✱ |  |
| `data_class` | `text` | ✱ |  |
| `tenant_path` | `text` |  |  |
| `note` | `text` |  |  |

### `sys.table_phase` 🛡️

The phase that brings each table into use, and its module (ERD group of the design document)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `table_name` | `text` | 🔑 ✱ |  |
| `phase_code` | `text` | 🔗 `sys.project_phase` ✱ |  |
| `module` | `text` | ✱ |  |

### `sys.webhook_delivery` 🛡️

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
| `response_ms` | `integer` |  |  |
| `event_type` | `text` |  |  |

### `sys.webhook_endpoint` 🛡️

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
## `net` — Network: stations, routes, lines, corridors and geofences

### `net.approved_rest_stop` 🛡️

The only places where a transit trip may stop on its corridor

| Column | Type | Constraints | Default |
|---|---|---|---|
| `corridor_id` | `bigint` | 🔑 🔗 `net.corridor` ✱ |  |
| `station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `max_minutes` | `integer` | ✱ | `30` |

### `net.carrier_code` 🛡️

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

### `net.code_reservation` 🛡️

Reserved, prohibited or temporarily withdrawn codes

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `reason` | `text` | ✱ |  |
| `until` | `date` |  |  |

### `net.compliance_profile` 🛡️

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

### `net.corridor` 🛡️

Approved transit corridor: route and tolerance; leaving it raises a tracking alert (annex D.1.3)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `path` | `jsonb` | ✱ |  |
| `buffer_m` | `integer` | ✱ | `500` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `path_geo` | `gis.geography` |  | `sys.geo_line(path)` |

### `net.geofence` 🛡️

Geofenced areas (ports, borders, depots, restricted zones) that raise arrival, departure and violation events

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `polygon` | `jsonb` |  |  |
| `center_lat` | `numeric(9,6)` |  |  |
| `center_lng` | `numeric(9,6)` |  |  |
| `radius_m` | `integer` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `net.line` 🛡️

The official line approved by the regulator (4.15); carriers operate it under a permit

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `fare_regime` | `text` | ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.line_diversion` 🛡️

A temporary detour of an approved line; trips keeping to it raise no violation

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `active` | `tstzrange` | ✱ |  |
| `geometry` | `jsonb` | ✱ |  |
| `corridor_m` | `integer` | ✱ | `150` |
| `reason` | `text` | ✱ |  |
| `issued_by` | `text` | ✱ |  |
| `reference_no` | `text` |  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `path` | `gis.geography` |  | `sys.geo_line(geometry)` |

### `net.line_fare` 🛡️

Fare rows of a tariff (line_fare and line_fare_table in the study): pair, band, flat or per kilometre

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `tariff_id` | `bigint` | 🔗 `net.line_tariff` ✱ |  |
| `from_station_id` | `bigint` | 🔗 `net.station`  |  |
| `to_station_id` | `bigint` | 🔗 `net.station`  |  |
| `passenger_category` | `text` | ✱ | `'ADULT'::text` |
| `fare` | `bigint` | ✱ |  |
| `band_to_seq` | `smallint` |  |  |
| `per_km` | `bigint` |  |  |

### `net.line_permit` 🛡️

A carrier's permit to operate a line, with its vehicle and daily-trip limits

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `valid` | `daterange` | ✱ |  |
| `max_vehicles` | `integer` |  |  |
| `max_trips_day` | `integer` |  |  |
| `permit_no` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `net.line_stop` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `line_version_id` | `bigint` | 🔑 🔗 `net.line_version` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `mandatory` | `boolean` | ✱ | `true` |
| `geofence_m` | `integer` | ✱ | `60` |
| `arr_offset_min` | `integer` |  |  |
| `dep_offset_min` | `integer` |  |  |

### `net.line_tariff` 🛡️

Versioned tariff of a line (4.15); the mode decides how ops.shuttle_ride is charged (7.13)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `version` | `integer` | ✱ |  |
| `regime` | `text` | ✱ |  |
| `mode` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid_from` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_at` | `timestamp with time zone` |  |  |

### `net.line_version` 🛡️

A version of the line with its route; trips keep the version they were generated from

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `version` | `integer` | ✱ |  |
| `geometry` | `jsonb` | ✱ |  |
| `corridor_m` | `integer` | ✱ | `150` |
| `distance_km` | `numeric(7,2)` | ✱ |  |
| `typical_min` | `integer` | ✱ |  |
| `effective_from` | `date` |  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `path` | `gis.geography` |  | `sys.geo_line(geometry)` |

### `net.line_version_approval` 🛡️

Four-eyes approval of a line version (approved_by[] in 4.15), one row per approver

| Column | Type | Constraints | Default |
|---|---|---|---|
| `line_version_id` | `bigint` | 🔑 🔗 `net.line_version` ✱ |  |
| `user_id` | `bigint` | 🔑 🔗 `iam.app_user` ✱ |  |
| `role` | `text` | ✱ |  |
| `approved_at` | `timestamp with time zone` | ✱ | `now()` |

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
| `line_id` | `bigint` | 🔗 `net.line`  |  |

### `net.route_stop` 🛡️

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
| `subtype` | `text` | 🔗 `ref.station_subtype` ✱ | `'TERMINAL'::text` |
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
| `geo` | `gis.geography` |  | `
CASE
    WHEN ((lat IS NOT NULL) AND...` |

### `net.station_contact` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `role` | `text` |  |  |
| `name` | `text` | ✱ |  |
| `phone` | `text` |  |  |
| `email` | `citext` |  |  |

### `net.station_display` 🛡️

Departure and arrival boards in stations (phase 7)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `gate_id` | `bigint` | 🔗 `net.station_gate`  |  |
| `device_serial` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `last_seen_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `net.station_gate` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `code` | `text` | ✱ |  |
| `gate_type` | `text` | ✱ | `'PLATFORM'::text` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `net.timetable_template` 🛡️

Shuttle timetable: fixed times or a headway within a window

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `kind` | `text` | ✱ |  |
| `days` | `smallint[]` | ✱ | `'{1,2,3,4,5,6,7}'::smallint[]` |
| `times` | `time without time zone[]` |  |  |
| `headway_min` | `integer` |  |  |
| `window_from` | `time without time zone` |  |  |
| `window_to` | `time without time zone` |  |  |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

<a id="fleet"></a>
## `fleet` — Fleet: vehicles, trucks, trailers, seats, crew, licenses and insurance

### `fleet.boarding_validator` 🛡️

Gate device on the vehicle that validates QR codes and NFC cards offline

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `device_serial` | `text` | ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `validator_type` | `text` | ✱ |  |
| `firmware` | `text` |  |  |
| `deny_list_version` | `integer` | ✱ | `0` |
| `last_sync_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

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
| `job_title` | `text` |  |  |
| `certificate_no` | `text` |  |  |
| `heavy_class` | `boolean` | ✱ | `false` |
| `cross_border` | `boolean` | ✱ | `false` |
| `hazmat_certified` | `boolean` | ✱ | `false` |

### `fleet.driving_hours_log` 🛡️

Driving and rest periods per driver (10.4); feeds the rest-time rules

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `party_id` | `bigint` | 🔗 `fleet.crew_profile` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `kind` | `text` | ✱ |  |
| `started_at` | `timestamp with time zone` | ✱ |  |
| `ended_at` | `timestamp with time zone` |  |  |
| `source` | `text` | ✱ | `'APP'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.field_check_log` 🛡️

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

### `fleet.insurance_claim` 🛡️

Claim notified to the insurer for an incident (7.10 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `policy_id` | `bigint` | 🔗 `fleet.insurance_policy` ✱ |  |
| `insurer_ref` | `text` |  |  |
| `amount` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'NOTIFIED'::text` |
| `last_sync_at` | `timestamp with time zone` |  |  |
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

### `fleet.license_change_request` 🛡️

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
| `subject_driver_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_partner_id` | `bigint` | 🔗 `ptn.partner`  |  |
| `subject_station_id` | `bigint` | 🔗 `net.station`  |  |
| `subject_trailer_id` | `bigint` | 🔗 `fleet.trailer`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `subject_person_id` | `bigint` | 🔗 `iam.party`  |  |

### `fleet.line_permit_vehicle` 🛡️

The vehicles a permit binds to its approved line; a vehicle serves one line at a time, and may still run scheduled trips

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `permit_id` | `bigint` | 🔗 `net.line_permit` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.seat_layout` 🛡️

Reusable seat layouts

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `name` | `text` | ✱ |  |
| `total_seats` | `smallint` | ✱ |  |
| `decks` | `smallint` | ✱ | `1` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `grid` | `jsonb` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `fleet.seat_layout_seat` 🛡️

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

### `fleet.tracking_device` 🛡️

A contracted tracking device installed in a vehicle; one active device per vehicle at a time

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `provider` | `text` | ✱ |  |
| `serial_no` | `text` | ✱ |  |
| `protocol` | `text` | ✱ | `'API'::text` |
| `certificate_no` | `text` |  |  |
| `installed` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.trailer` 🛡️

Trailers with their own plate and licence documents (10.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `ownership_type` | `text` | ✱ | `'OWNED'::text` |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `plate_no` | `text` | ✱ |  |
| `plate_country` | `character(2)` | 🔗 `ref.country` ✱ | `'SY'::bpchar` |
| `chassis_no` | `text` |  |  |
| `trailer_type` | `text` | ✱ |  |
| `payload_kg` | `integer` | ✱ |  |
| `volume_m3` | `numeric(8,2)` |  |  |
| `length_m` | `numeric(5,2)` |  |  |
| `axles` | `smallint` |  |  |
| `container_capacity` | `smallint` |  |  |
| `temp_min_c` | `numeric(4,1)` |  |  |
| `temp_max_c` | `numeric(4,1)` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.truck_combination` 🛡️

Truck, trailer and driver coupled for a period; trailers can be swapped without overlap (10.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `truck_vehicle_id` | `bigint` | 🔗 `fleet.truck_unit` ✱ |  |
| `trailer_id` | `bigint` | 🔗 `fleet.trailer`  |  |
| `driver_party_id` | `bigint` | 🔗 `fleet.crew_profile`  |  |
| `period` | `tstzrange` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.truck_unit` 🛡️

Truck extension of fleet.vehicle (vehicle_class TRUCK); plate, chassis, ownership and licences stay on the vehicle (10.4, 4.17)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `vehicle_id` | `bigint` | 🔑 🔗 `fleet.vehicle` ✱ |  |
| `axle_config` | `text` | ✱ |  |
| `gvw_kg` | `integer` | ✱ |  |
| `tare_kg` | `integer` | ✱ |  |
| `fuel_type` | `text` | ✱ | `'DIESEL'::text` |
| `gps_device_ref` | `text` |  |  |
| `hazmat_certified` | `boolean` | ✱ | `false` |
| `cross_border_permit_no` | `text` |  |  |
| `cross_border_permit_expiry` | `date` |  |  |

### `fleet.vehicle` 🛡️

Vehicle: type, seated and standing capacity, ownership and owner, and the status that blocks assignment (4.3, 4.13, 4.17, 4.18)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_class` | `text` | 🔗 `ref.vehicle_class` ✱ | `'BUS'::text` |
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
| `tracking_source` | `text` | ✱ | `'DRIVER_APP'::text` |

### `fleet.vehicle_fuel_profile` 🛡️

Expected consumption and tolerance, per vehicle or per class, for fuel anomaly checks (14.11 f)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `vehicle_class` | `text` | 🔗 `ref.vehicle_class`  |  |
| `tank_capacity_l` | `numeric(7,1)` | ✱ |  |
| `expected_l_per_100km` | `numeric(5,1)` | ✱ |  |
| `tolerance_pct` | `numeric(4,1)` | ✱ | `15` |

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

### `fleet.vehicle_qr_tag` 🛡️

Signed QR sticker on the vehicle for field verification (4.18 e)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |
| `revoked_at` | `timestamp with time zone` |  |  |

### `fleet.vehicle_service_status` 🛡️

Out-of-service and impound periods; a vehicle in such a period cannot be assigned (7.10 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `status` | `text` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `incident_id` | `bigint` | 🔗 `ops.incident`  |  |
| `period` | `tstzrange` | ✱ | `tstzrange(now(), NULL::timestamp with...` |
| `released_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `release_evidence_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fleet.vehicle_status_history` 🛡️

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

### `pricing.allocation_template` 🛡️

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

### `pricing.allocation_template_line` 🛡️



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

### `pricing.award_seat_rule` 🛡️

Seats a carrier releases for points on a line or route, with blackout dates

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `line_id` | `bigint` | 🔗 `net.line`  |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `cabin` | `text` |  |  |
| `points_cost` | `bigint` | ✱ |  |
| `quota` | `integer` | ✱ |  |
| `blackout_dates` | `date[]` | ✱ | `'{}'::date[]` |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.bin_range` 🛡️

Card number ranges of a bank, used to target bank-funded campaigns

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `bank_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `from_bin` | `character(8)` | ✱ |  |
| `to_bin` | `character(8)` | ✱ |  |
| `card_type` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.campaign` 🛡️

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
| `budget_alert_pct` | `smallint` |  |  |
| `sponsor_account_id` | `bigint` | 🔗 `pricing.sponsor_account`  |  |

### `pricing.cancellation_policy` 🛡️

Refund percentages by time before departure; refund requests keep a snapshot of it

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `rules` | `jsonb` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `pricing.category_fare_rule` 🛡️

Fare of children and infants: a share of the adult fare, a fixed fare or free; route rows win over carrier rows, carrier rows over the platform default (4.19)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `category` | `text` | ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `method` | `text` | ✱ |  |
| `value` | `numeric(12,2)` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency`  |  |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.commission_rule` 🛡️



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

### `pricing.commission_scheme` 🛡️

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

### `pricing.family_offer` 🛡️

Carrier offer for a family travelling or subscribing together; applies when enough registered members of one family are on the booking (4.19 d)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `applies_to` | `text` | ✱ | `'TICKETS'::text` |
| `min_members` | `smallint` | ✱ | `3` |
| `min_adults` | `smallint` | ✱ | `1` |
| `min_minors` | `smallint` | ✱ | `1` |
| `discount_type` | `text` | ✱ |  |
| `discount_value` | `numeric(12,2)` | ✱ |  |
| `max_discount` | `bigint` |  |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.fare_brand` 🛡️

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

### `pricing.fare_table` 🛡️

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

### `pricing.fare_table_item` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `fare_table_id` | `bigint` | 🔑 🔗 `pricing.fare_table` ✱ |  |
| `from_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `to_station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `cabin` | `text` | 🔑 ✱ | `'ECONOMY'::text` |
| `passenger_category` | `text` | 🔑 ✱ | `'ADULT'::text` |
| `base_price` | `bigint` | ✱ |  |

### `pricing.jurisdiction` 🛡️

Tax jurisdiction (country, region, border crossing, local)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `level` | `text` | ✱ |  |
| `parent_id` | `bigint` | 🔗 `pricing.jurisdiction`  |  |
| `name` | `text` | ✱ |  |

### `pricing.loyalty_partner` 🛡️

Earn and burn partner of the loyalty program (5.13 f); extends the partner register

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `service_partner_id` | `bigint` | 🔗 `ptn.partner`  |  |
| `partner_type` | `text` | ✱ |  |
| `earn_rate` | `numeric(8,4)` | ✱ | `0` |
| `burn_rate` | `numeric(8,4)` | ✱ | `0` |
| `conversion_ratio` | `numeric(10,4)` |  |  |
| `settlement_cycle` | `text` | ✱ | `'MONTHLY'::text` |
| `contract_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

### `pricing.loyalty_program` 🛡️



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

### `pricing.loyalty_rule` 🛡️



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

### `pricing.loyalty_tier` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `min_points` | `bigint` | ✱ | `0` |
| `benefits` | `jsonb` | ✱ | `'{}'::jsonb` |

### `pricing.override_policy` 🛡️

An approved individual exception to a fee or discount rule, with its reason and period

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `target_type` | `text` | ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `policy_key` | `text` | ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `valid` | `tstzrange` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `created_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.partner_redemption` 🛡️ 🔒

Points spent at a partner; the basis of partner settlement and of the liability release

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `loyalty_partner_id` | `bigint` | 🔗 `pricing.loyalty_partner` ✱ |  |
| `voucher_id` | `bigint` | 🔗 `pricing.reward_voucher`  |  |
| `token_id` | `bigint` | 🔗 `pricing.redemption_token`  |  |
| `partner_sale_id` | `bigint` | 🔗 `ptn.partner_sale`  |  |
| `points` | `bigint` | ✱ |  |
| `value` | `bigint` | ✱ |  |
| `commission` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `redeemed_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.passenger_age_band` 🛡️

Age bands of adults, children and infants set by each carrier; the platform row applies until a carrier sets its own (4.19)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `category` | `text` | ✱ |  |
| `min_age` | `smallint` | ✱ |  |
| `max_age` | `smallint` |  |  |
| `seat_required` | `boolean` | ✱ | `true` |
| `needs_adult` | `boolean` | ✱ | `false` |
| `max_per_adult` | `smallint` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `document_required` | `boolean` | ✱ | `false` |

### `pricing.points_account` 🛡️

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

### `pricing.points_ledger` 🛡️ 🔒

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

### `pricing.points_liability` 🛡️

Accounting liability of outstanding points per issuer and period, with estimated breakage

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `issuer_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `period` | `daterange` | ✱ |  |
| `issued` | `bigint` | ✱ | `0` |
| `redeemed` | `bigint` | ✱ | `0` |
| `expired` | `bigint` | ✱ | `0` |
| `breakage_est` | `bigint` | ✱ | `0` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.points_transfer` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `account_id` | `bigint` | 🔗 `pricing.points_account` ✱ |  |
| `loyalty_partner_id` | `bigint` | 🔗 `pricing.loyalty_partner` ✱ |  |
| `direction` | `text` | ✱ |  |
| `points` | `bigint` | ✱ |  |
| `external_units` | `numeric(14,2)` | ✱ |  |
| `ratio` | `numeric(10,4)` | ✱ |  |
| `external_ref` | `text` |  |  |
| `points_ledger_id` | `bigint` | 🔗 `pricing.points_ledger`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.pricing_modifier` 🛡️

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

### `pricing.promo_code` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `campaign_id` | `bigint` | 🔗 `pricing.campaign` ✱ |  |
| `code` | `citext` | ✱ |  |
| `max_uses` | `integer` |  |  |
| `uses` | `integer` | ✱ | `0` |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |

### `pricing.rate_band` 🛡️

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

### `pricing.redemption_channel` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `rules` | `jsonb` | ✱ | `'{}'::jsonb` |
| `min_points` | `bigint` | ✱ | `0` |
| `max_points` | `bigint` |  |  |
| `active` | `boolean` | ✱ | `true` |

### `pricing.redemption_token` 🛡️

Single-use temporary token presented at a partner to redeem points

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `channel_code` | `text` | 🔗 `pricing.redemption_channel` ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `method` | `text` | ✱ |  |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `used_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.reward_catalog` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `program_id` | `bigint` | 🔗 `pricing.loyalty_program` ✱ |  |
| `loyalty_partner_id` | `bigint` | 🔗 `pricing.loyalty_partner`  |  |
| `reward_type` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `points_cost` | `bigint` | ✱ |  |
| `conversion_value` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `commission_bp` | `integer` | ✱ | `0` |
| `external_code` | `text` |  |  |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.reward_voucher` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `catalog_id` | `bigint` | 🔗 `pricing.reward_catalog`  |  |
| `loyalty_partner_id` | `bigint` | 🔗 `pricing.loyalty_partner`  |  |
| `points_ledger_id` | `bigint` | 🔗 `pricing.points_ledger`  |  |
| `code_hash` | `bytea` | ✱ |  |
| `points` | `bigint` | ✱ |  |
| `value` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `used_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'ISSUED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `pricing.sponsor_account` 🛡️

Who funds a discount, and what they owe the platform for it

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `kind` | `text` | ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `receivable_balance` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `pricing.tax_rule` 🛡️



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

### `pricing.tax_scheme` 🛡️

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
## `ops` — Trips, inventory, operations, shuttle rides, tracking and incidents

### `ops.crew_assignment` 🛡️

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

### `ops.crossing_event` 🛡️

Border entry and exit of a trip (11.3 CROSSING_EVENT); append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `direction` | `text` | ✱ |  |
| `source` | `text` | ✱ |  |
| `occurred_at` | `timestamp with time zone` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `recorded_by_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.driver_notice` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `body` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `ack_at` | `timestamp with time zone` |  |  |

### `ops.family_zone` 🛡️

Family zones on the trip (4.14 a)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seat_nos` | `smallint[]` | ✱ |  |
| `label` | `text` | 🔑 ✱ | `'FAMILY'::text` |

### `ops.geo_event` 🛡️ 🧩

Tracking positions; daily partitions created ahead by sys.ensure_daily_partitions and dropped whole after the retention of the lifecycle matrix (7 days, T3-10); no foreign keys on the hot insert path

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
| `event_id` | `uuid` |  |  |
| `seq` | `bigint` |  |  |
| `device_ts` | `timestamp with time zone` |  |  |
| `received_at` | `timestamp with time zone` | ✱ | `now()` |
| `provider` | `text` |  |  |
| `is_mock` | `boolean` | ✱ | `false` |
| `trust` | `text` | ✱ | `'HIGH'::text` |
| `trust_flags` | `text[]` | ✱ | `'{}'::text[]` |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |

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

### `ops.incident_evidence` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object` ✱ |  |
| `kind` | `text` | ✱ |  |
| `uploaded_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.incident_external_link` 🛡️

Integration with traffic police, police and insurers (activated after government integration)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `incident_id` | `bigint` | 🔗 `ops.incident` ✱ |  |
| `authority` | `text` | ✱ |  |
| `external_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `last_sync_at` | `timestamp with time zone` |  |  |

### `ops.permission_event` 🛡️ 🔒

Lock and restore log of app permissions; feeds ops.tracking_alert for drivers; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `kind` | `text` | ✱ |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ops.presence_beacon` 🛡️

Rotating signed presence tokens per trip that passengers' phones detect over Nearby

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `source` | `text` | ✱ |  |
| `key_id` | `text` | 🔗 `sec.key_registry` ✱ |  |
| `rotation_sec` | `integer` | ✱ | `30` |
| `active` | `tstzrange` | ✱ |  |

### `ops.proximity_sample` 🛡️

Proximity samples between passenger and vehicle; deleted after the retention period (16.13)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `ride_id` | `bigint` | 🔑 🔗 `ops.shuttle_ride` ✱ |  |
| `ts` | `timestamp with time zone` | 🔑 ✱ |  |
| `rssi` | `smallint` |  |  |
| `est_distance_m` | `numeric(6,1)` |  |  |
| `co_moving` | `boolean` |  |  |
| `source` | `text` | ✱ |  |

### `ops.ride_segment_charge` 🛡️ 🔒

One row per deduction: the receipt lines of a shuttle ride; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ride_id` | `bigint` | 🔗 `ops.shuttle_ride` ✱ |  |
| `seq_from` | `smallint` | ✱ |  |
| `seq_to` | `smallint` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ops.route_adherence_event` 🛡️ 🔒

Deviations from the line version measured by tracking; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `kind` | `text` | ✱ |  |
| `ts` | `timestamp with time zone` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `detail` | `jsonb` | ✱ | `'{}'::jsonb` |

### `ops.route_violation` 🛡️

A deviation from the route the trip must keep to: warning, continuous alarm, correction, review and reporting

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `driver_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `compliance_source` | `text` | ✱ |  |
| `line_version_id` | `bigint` | 🔗 `net.line_version`  |  |
| `kind` | `text` | ✱ |  |
| `tracking_source` | `text` | ✱ |  |
| `started_at` | `timestamp with time zone` | ✱ |  |
| `ended_at` | `timestamp with time zone` |  |  |
| `max_distance_m` | `integer` |  |  |
| `in_service` | `boolean` | ✱ |  |
| `carrying_passengers` | `boolean` | ✱ | `false` |
| `driver_warned_at` | `timestamp with time zone` |  |  |
| `alarm_started_at` | `timestamp with time zone` |  |  |
| `corrected_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `justification` | `text` |  |  |
| `diversion_id` | `bigint` | 🔗 `net.line_diversion`  |  |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `evidence` | `jsonb` | ✱ | `'{}'::jsonb` |
| `retain_until` | `date` | ✱ | `(CURRENT_DATE + 730)` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `evidence_trust` | `text` | ✱ | `'HIGH'::text` |

### `ops.seat_lock` 🛡️

Audit trail of seat holds. Never read to decide availability: the hold itself is the LOCKED row of ops.seat_segment (study 16.28)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `seat_no` | `text` | ✱ |  |
| `from_seq` | `smallint` | ✱ |  |
| `to_seq` | `smallint` | ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `session_ref` | `text` | ✱ |  |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `released_at` | `timestamp with time zone` |  |  |
| `outcome` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.seat_segment` 🛡️

Seat inventory per segment (4.12 c): a seat is sellable for a pair if it is vacant in all of the pair's segments

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seat_no` | `smallint` | 🔑 ✱ |  |
| `seg` | `smallint` | 🔑 ✱ |  |
| `status` | `text` | ✱ | `'AVAILABLE'::text` |
| `lock_token` | `uuid` |  |  |
| `lock_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `lock_expires_at` | `timestamp with time zone` |  |  |
| `ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `version` | `integer` | ✱ | `0` |

### `ops.shuttle_ride` 🛡️

One open ride per user, charged stop by stop until alighting (7.13)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `line_id` | `bigint` | 🔗 `net.line` ✱ |  |
| `tariff_id` | `bigint` | 🔗 `net.line_tariff`  |  |
| `boarding_event_id` | `bigint` | 🔗 `sales.boarding_event`  |  |
| `board_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `board_ts` | `timestamp with time zone` | ✱ |  |
| `alight_station_id` | `bigint` | 🔗 `net.station`  |  |
| `alight_ts` | `timestamp with time zone` |  |  |
| `alight_method` | `text` |  |  |
| `companions` | `smallint` | ✱ | `0` |
| `charged_amount` | `bigint` | ✱ | `0` |
| `outstanding_amount` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `last_charged_seq` | `smallint` |  |  |
| `counts_in_capacity` | `boolean` | ✱ | `true` |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.standing_segment` 🛡️

Standing places counter per segment, never above capacity

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `seg` | `smallint` | 🔑 ✱ |  |
| `capacity` | `smallint` | ✱ |  |
| `used` | `smallint` | ✱ | `0` |

### `ops.tracking_alert` 🛡️



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

### `ops.tracking_state` 🛡️

Current tracking status of a trip; positions themselves are in ops.geo_event (trip_position in 7.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `driver_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `last_ping_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'OFF'::text` |
| `off_reason` | `text` |  |  |
| `level` | `text` | ✱ | `'NORMAL'::text` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.transit_reconciliation` 🛡️

Transit passengers leaving Syria must match those who entered (annex D.1.5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `entry_count` | `integer` | ✱ | `0` |
| `exit_count` | `integer` | ✱ | `0` |
| `missing_ticket_ids` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `resolved_by_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `resolved_at` | `timestamp with time zone` |  |  |
| `note` | `text` |  |  |

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
| `trip_type` | `text` | 🔗 `ref.trip_type` ✱ | `'SCHEDULED'::text` |
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
| `seat_map` | `jsonb` |  |  |
| `corridor_id` | `bigint` | 🔗 `net.corridor`  |  |
| `transit_max_minutes` | `integer` |  |  |
| `line_version_id` | `bigint` | 🔗 `net.line_version`  |  |
| `timetable_slot` | `time without time zone` |  |  |
| `fare_regime` | `text` |  |  |
| `compliance_source` | `text` | ✱ | `'NONE'::text` |

### `ops.trip_change` 🛡️

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

### `ops.trip_crossing_plan` 🛡️

The trip's border crossings in order (11.6); a transit trip has two: into Syria, then out of it

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `seq` | `smallint` | ✱ |  |
| `exit_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `entry_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `planned_at` | `timestamp with time zone` |  |  |

### `ops.trip_delay` 🛡️ 🔒

Delay estimates per stop that feed station displays and passenger notifications (phase 7)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `stop_seq` | `smallint` |  |  |
| `delay_min` | `integer` | ✱ |  |
| `cause` | `text` | ✱ |  |
| `source` | `text` | ✱ |  |
| `reported_at` | `timestamp with time zone` | ✱ | `now()` |

### `ops.trip_disruption` 🛡️

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

### `ops.trip_pair_fare` 🛡️

Exceptional price for a station pair exceeding the ladder difference

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `from_seq` | `smallint` | 🔑 ✱ |  |
| `to_seq` | `smallint` | 🔑 ✱ |  |
| `price` | `bigint` | ✱ |  |

### `ops.trip_stop` 🛡️

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
| `gate_id` | `bigint` | 🔗 `net.station_gate`  |  |

### `ops.trip_stop_event` 🛡️

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

### `ops.vehicle_swap` 🛡️

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

### `ops.violation_report` 🛡️

A violation sent to an authority over the channel it imposed; delivered through the outbox

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `violation_id` | `bigint` | 🔗 `ops.route_violation` ✱ |  |
| `authority` | `text` | ✱ |  |
| `channel` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `external_ref` | `text` |  |  |
| `sent_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sales"></a>
## `sales` — Channels, bookings, passengers, tickets, subscriptions and travel documents

### `sales.agency_agreement` 🛡️

Agency terms: commission in basis points of the fares and a daily sales limit

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `agency_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `commission_bp` | `integer` | ✱ |  |
| `daily_limit` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `valid_from` | `date` | ✱ | `CURRENT_DATE` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.boarding_event` 🛡️ 🔒

Boarding and alighting scan events (basis for dispatch, settlement and the manifest); append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
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
| `device_scan_id` | `text` |  |  |
| `scanned_at` | `timestamp with time zone` |  |  |
| `companions` | `smallint` | ✱ | `0` |
| `offline_token` | `text` |  |  |
| `geo_match` | `boolean` |  |  |
| `vehicle_tag_id` | `bigint` | 🔗 `fleet.vehicle_qr_tag`  |  |
| `validator_id` | `bigint` | 🔗 `fleet.boarding_validator`  |  |
| `nfc_card_id` | `bigint` | 🔗 `sales.nfc_card`  |  |

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
| `agency_id` | `bigint` | 🔗 `iam.company`  |  |
| `contact_mobile` | `text` |  |  |
| `family_id` | `bigint` | 🔗 `iam.family`  |  |
| `funded_by_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `funding_source` | `text` |  |  |

### `sales.campaign_redemption` 🛡️

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

### `sales.channel` 🛡️

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
| `relationship` | `text` |  |  |

### `sales.channel_agreement` 🛡️

Terms between a channel and the platform or a carrier; links to the commission scheme (5.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `model` | `text` | ✱ |  |
| `rate_bp` | `integer` |  |  |
| `commission_scheme_id` | `bigint` | 🔗 `pricing.commission_scheme`  |  |
| `scope` | `jsonb` | ✱ | `'{}'::jsonb` |
| `fare_visibility` | `jsonb` | ✱ | `'{}'::jsonb` |
| `markup_policy` | `jsonb` | ✱ | `'{}'::jsonb` |
| `settlement_cycle` | `text` | ✱ | `'WEEKLY'::text` |
| `label` | `text` | ✱ |  |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sales.channel_api_profile` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `channel_id` | `bigint` | 🔑 🔗 `sales.channel` ✱ |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client` ✱ |  |
| `api_schema` | `text` | ✱ | `'NATIVE'::text` |
| `rate_limit_per_min` | `integer` | ✱ | `600` |
| `look_to_book_limit` | `integer` |  |  |
| `cache_ttl_sec` | `integer` | ✱ | `60` |
| `ip_allow` | `cidr[]` | ✱ | `'{}'::cidr[]` |
| `mtls_cert_ref` | `text` |  |  |

### `sales.channel_booking_ref` 🛡️

The booking reference in the channel's own system

| Column | Type | Constraints | Default |
|---|---|---|---|
| `booking_id` | `bigint` | 🔑 🔗 `sales.booking` ✱ |  |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `external_locator` | `text` | ✱ |  |
| `agent_ref` | `text` |  |  |
| `sub_agent_ref` | `text` |  |  |

### `sales.channel_inventory_rule` 🛡️

Seats allotted to a channel per route or trip type, and when unsold seats return

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `trip_type` | `text` | 🔗 `ref.trip_type`  |  |
| `allotment_seats` | `integer` |  |  |
| `cutoff_min` | `integer` | ✱ | `60` |
| `release_rule` | `text` | ✱ | `'AT_CUTOFF'::text` |
| `visibility` | `text` | ✱ | `'VISIBLE'::text` |

### `sales.channel_memo` 🛡️

Debit and credit memos that correct a channel statement (ADM/ACM pattern)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `statement_id` | `bigint` | 🔗 `sales.channel_statement`  |  |
| `memo_type` | `text` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ref` | `text` |  |  |
| `status` | `text` | ✱ | `'ISSUED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.channel_statement` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `channel_id` | `bigint` | 🔗 `sales.channel` ✱ |  |
| `period` | `daterange` | ✱ |  |
| `gross_sales` | `bigint` | ✱ | `0` |
| `refunds` | `bigint` | ✱ | `0` |
| `commission` | `bigint` | ✱ | `0` |
| `taxes` | `bigint` | ✱ | `0` |
| `net_due` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `sales.channel_statement_line` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `statement_id` | `bigint` | 🔑 🔗 `sales.channel_statement` ✱ |  |
| `line_no` | `integer` | 🔑 ✱ |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `kind` | `text` | ✱ |  |
| `gross` | `bigint` | ✱ |  |
| `commission` | `bigint` | ✱ | `0` |
| `tax` | `bigint` | ✱ | `0` |
| `net` | `bigint` | ✱ |  |

### `sales.entry_rule` 🛡️

Data-driven document rules per destination or transit country and nationality, four-eyes approved (11.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `country_role` | `text` | ✱ | `'DESTINATION'::text` |
| `nationality` | `character(2)` | 🔗 `ref.country`  |  |
| `doc_required` | `text[]` | ✱ | `'{PASSPORT}'::text[]` |
| `security_approval` | `boolean` | ✱ | `false` |
| `passport_min_days` | `integer` | ✱ | `180` |
| `enforcement` | `text` | ✱ | `'BLOCK'::text` |
| `label` | `text` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `valid` | `daterange` |  |  |
| `legal_basis` | `text` |  |  |
| `note` | `text` |  |  |

### `sales.external_mapping` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `source_id` | `bigint` | 🔑 🔗 `sales.supplier_source` ✱ |  |
| `local_type` | `text` | 🔑 ✱ |  |
| `local_id` | `bigint` | ✱ |  |
| `external_id` | `text` | 🔑 ✱ |  |

### `sales.inspection_check` 🛡️ 🔒

Random fare inspection on board; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `inspector_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `boarding_event_id` | `bigint` | 🔗 `sales.boarding_event`  |  |
| `result` | `text` | ✱ |  |
| `fee_charged` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `sales.nfc_card` 🛡️

Prepaid card linked to a wallet; validators keep a deny list of blocked cards (7.6 e)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `card_uid_hash` | `bytea` | ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `issued_at` | `timestamp with time zone` | ✱ | `now()` |

### `sales.passenger` 🛡️

Passenger data on the booking; document numbers encrypted with a blind index for security screening and the manifest

| Column | Type | Constraints | Default |
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
| `first_name` | `text` |  |  |
| `father_name` | `text` |  |  |
| `grandfather_name` | `text` |  |  |
| `last_name` | `text` |  |  |
| `family_member_id` | `bigint` | 🔗 `iam.family_member`  |  |
| `accompanied_by_passenger_id` | `bigint` | 🔗 `sales.passenger`  |  |
| `retention_policy_id` | `bigint` | 🔗 `gov.retention_policy`  |  |
| `legal_hold` | `boolean` | ✱ | `false` |
| `anonymized_at` | `timestamp with time zone` |  |  |
| `erasure_request_id` | `bigint` | 🔗 `gov.subject_request`  |  |
| `mobile_enc` | `bytea` |  |  |
| `mobile_last4` | `text` |  |  |

### `sales.passenger_compensation` 🛡️

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

### `sales.refund_request` 🛡️

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

### `sales.shuttle_pass` 🛡️

The pass carried by the subscriber: a signed QR or an NFC card

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `subscription_id` | `bigint` | 🔗 `sales.subscription` ✱ |  |
| `pass_no` | `text` | ✱ |  |
| `medium` | `text` | ✱ |  |
| `nfc_card_id` | `bigint` | 🔗 `sales.nfc_card`  |  |
| `qr_key_id` | `text` | 🔗 `sec.key_registry`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `sales.shuttle_zone` 🛡️

Fare zone for zone-based shuttle subscriptions

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `polygon` | `jsonb` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `sales.subscription` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `plan_id` | `bigint` | 🔗 `sales.subscription_plan` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `starts_on` | `date` | ✱ |  |
| `ends_on` | `date` | ✱ |  |
| `rides_used` | `integer` | ✱ | `0` |
| `price_paid` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `family_id` | `bigint` | 🔗 `iam.family`  |  |
| `purchased_by_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `family_offer_id` | `bigint` | 🔗 `pricing.family_offer`  |  |

### `sales.subscription_plan` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `line_id` | `bigint` | 🔗 `net.line`  |  |
| `zone_id` | `bigint` | 🔗 `sales.shuttle_zone`  |  |
| `period_days` | `smallint` | ✱ |  |
| `rides_limit` | `integer` |  |  |
| `passenger_category` | `text` | ✱ | `'ADULT'::text` |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `sales.supplier_source` 🛡️

Inbound content source: an external rail or bus system whose inventory is sold on the platform (14.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `name` | `text` | ✱ |  |
| `source_type` | `text` | ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `protocol` | `text` | ✱ |  |
| `credentials_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'TESTING'::text` |

### `sales.ticket` 🛡️

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
| `travel_category` | `text` |  |  |

### `sales.ticket_doc` 🛡️

Travel documents of one international ticket; numbers are encrypted (11.9, D.1.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `ticket_id` | `bigint` | 🔑 🔗 `sales.ticket` ✱ |  |
| `entry_rule_id` | `bigint` | 🔗 `sales.entry_rule`  |  |
| `dest_country` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `passport_expiry` | `date` |  |  |
| `visa_type` | `text` |  |  |
| `visa_no_enc` | `bytea` |  |  |
| `visa_country` | `character(2)` | 🔗 `ref.country`  |  |
| `visa_valid` | `daterange` |  |  |
| `visa_entries` | `text` |  |  |
| `residence_no_enc` | `bytea` |  |  |
| `residence_country` | `character(2)` | 🔗 `ref.country`  |  |
| `residence_expiry` | `date` |  |  |
| `security_no_enc` | `bytea` |  |  |
| `security_authority` | `text` |  |  |
| `security_expiry` | `date` |  |  |
| `transit_visa_no_enc` | `bytea` |  |  |
| `transit_permit_no` | `text` |  |  |
| `transit_permit_valid` | `daterange` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `issues` | `jsonb` | ✱ | `'[]'::jsonb` |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `verified_at` | `timestamp with time zone` |  |  |
| `source` | `text` | ✱ | `'PASSENGER'::text` |
| `doc_type` | `text` |  |  |
| `exception` | `boolean` | ✱ | `false` |

### `sales.waitlist_entry` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `from_seq` | `smallint` | ✱ |  |
| `to_seq` | `smallint` | ✱ |  |
| `seats` | `smallint` | ✱ | `1` |
| `status` | `text` | ✱ | `'WAITING'::text` |
| `offered_at` | `timestamp with time zone` |  |  |
| `offer_expires_at` | `timestamp with time zone` |  |  |
| `booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="fin"></a>
## `fin` — Wallets, ledger, payments, allocation, settlement and float

### `fin.bank_reconciliation` 🛡️

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

### `fin.bank_statement_import` 🛡️

A bank statement file imported by finance; the same file cannot be imported twice

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `account_label` | `text` | ✱ |  |
| `file_sha256` | `bytea` | ✱ |  |
| `line_count` | `integer` | ✱ |  |
| `matched_count` | `integer` | ✱ | `0` |
| `imported_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.bank_statement_line` 🛡️

One credit line of an imported statement: matched to a top-up by reference and amount, or decided by finance

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `import_id` | `bigint` | 🔗 `fin.bank_statement_import` ✱ |  |
| `value_date` | `date` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `reference` | `text` |  |  |
| `payer` | `text` |  |  |
| `bank_ref` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'UNMATCHED'::text` |
| `topup_id` | `bigint` | 🔗 `fin.bank_transfer_topup`  |  |
| `note` | `text` |  |  |
| `decided_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `decided_at` | `timestamp with time zone` |  |  |

### `fin.bank_transfer_topup` 🛡️

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
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `payment_id` | `bigint` | 🔗 `fin.payment`  |  |
| `expires_at` | `timestamp with time zone` |  |  |
| `matched_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `statement_line_id` | `bigint` | 🔗 `fin.bank_statement_line`  |  |

### `fin.cash_remittance` 🛡️

Cash collected by a carrier from cash sales and remitted to the platform (6.5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `method` | `text` | ✱ |  |
| `ref` | `text` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `recorded_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `reconciled_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.deposit_placement` 🛡️

Maturity ladder of placements; client funds stay withdrawable at any time

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `account_id` | `bigint` | 🔗 `fin.float_account` ✱ |  |
| `product` | `text` | ✱ |  |
| `principal` | `bigint` | ✱ |  |
| `rate_bp` | `integer` | ✱ |  |
| `starts_on` | `date` | ✱ |  |
| `matures_on` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `fin.float_account` 🛡️

Bank accounts holding wallet funds, each matched by a ledger wallet (6.8 c)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `bank_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `kind` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `account_ref` | `text` | ✱ |  |
| `ledger_wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `fin.float_report` 🛡️

Daily coverage of wallet liabilities by bank assets

| Column | Type | Constraints | Default |
|---|---|---|---|
| `report_date` | `date` | 🔑 ✱ |  |
| `currency` | `character(3)` | 🔑 🔗 `ref.currency` ✱ |  |
| `liabilities` | `bigint` | ✱ |  |
| `assets` | `bigint` | ✱ |  |
| `coverage_ratio` | `numeric(6,4)` | ✱ |  |
| `liquid_ratio` | `numeric(6,4)` | ✱ |  |
| `yield_accrued` | `bigint` | ✱ | `0` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.ledger_entry` 🛡️ 🔒

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

### `fin.ledger_txn` 🛡️ 🔒

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
| `posting_batch_id` | `bigint` | 🔗 `fin.posting_batch`  |  |
| `source_event_id` | `uuid` |  |  |
| `reversal_reason` | `text` |  |  |

### `fin.payment` 🛡️

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
| `stage` | `text` | ✱ | `'CREATED'::text` |
| `checkout_url` | `text` |  |  |
| `expires_at` | `timestamp with time zone` |  |  |
| `failure_code` | `text` |  |  |
| `payer_mobile_mask` | `text` |  |  |
| `otp_attempts` | `smallint` | ✱ | `0` |
| `refunded_amount` | `bigint` | ✱ | `0` |
| `agency_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |

### `fin.payment_notification` 🛡️ 🔒

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

### `fin.payment_provider` 🛡️

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
| `adapter` | `text` | ✱ | `'SANDBOX'::text` |
| `min_amount` | `bigint` | ✱ | `100000` |
| `max_amount` | `bigint` | ✱ | `100000000` |
| `purposes` | `text[]` | ✱ | `ARRAY['TOPUP'::text]` |
| `sort_order` | `smallint` | ✱ | `100` |
| `updated_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.payment_refund` 🛡️

Money returned to the card or e-wallet it came from; the wallet is debited in the same transaction

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `payment_id` | `bigint` | 🔗 `fin.payment` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `provider_ref` | `text` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `requested_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `idempotency_key` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `completed_at` | `timestamp with time zone` |  |  |

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

### `fin.posting_batch` 🛡️

A group of ledger transactions posted together; closing it checks the control total (review 3.5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `source` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ |  |
| `control_total` | `bigint` | ✱ |  |
| `entry_count` | `integer` | ✱ |  |
| `closed_at` | `timestamp with time zone` |  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `fin.price_allocation` 🛡️

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
| `subject_ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `subject_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `subject_shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `subject_freight_leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `subject_subscription_id` | `bigint` | 🔗 `sales.subscription`  |  |

### `fin.price_allocation_line` 🛡️

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
| `sponsor_account_id` | `bigint` | 🔗 `pricing.sponsor_account`  |  |
| `funded_by` | `text` |  |  |

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
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_at` | `timestamp with time zone` |  |  |

### `fin.settlement_line` 🛡️



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
| `trip_no` | `text` |  |  |

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

### `fin.wallet_reconciliation` 🛡️

Result of each balance-versus-entries reconciliation (review 3.5); a mismatch raises an alert

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `run_at` | `timestamp with time zone` | ✱ | `now()` |
| `wallets` | `integer` | ✱ |  |
| `mismatches` | `integer` | ✱ |  |
| `detail` | `jsonb` | ✱ | `'[]'::jsonb` |

### `fin.withdrawal_request` 🛡️

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
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `needs_second` | `boolean` | ✱ | `false` |
| `idempotency_key` | `text` |  |  |
| `bank_ref` | `text` |  |  |
| `reject_reason` | `text` |  |  |
| `paid_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `paid_at` | `timestamp with time zone` |  |  |

<a id="acct"></a>
## `acct` — Simplified accounting, e-invoicing and tax profiles

### `acct.account_mapping` 🛡️



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

### `acct.cash_box` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `owner_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `account_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `acct.cash_payment` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `voucher_no` | `text` | ✱ |  |
| `method` | `text` | ✱ |  |
| `cash_session_id` | `bigint` | 🔗 `acct.cash_session`  |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `bank_account_id` | `bigint` | 🔗 `iam.bank_account`  |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `purpose` | `text` | ✱ |  |
| `account_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `payment_date` | `date` | ✱ | `CURRENT_DATE` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `journal_entry_id` | `bigint` | 🔗 `acct.journal_entry`  |  |

### `acct.cash_receipt` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `receipt_no` | `text` | ✱ |  |
| `method` | `text` | ✱ |  |
| `cash_session_id` | `bigint` | 🔗 `acct.cash_session`  |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `bank_account_id` | `bigint` | 🔗 `iam.bank_account`  |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `invoice_id` | `bigint` | 🔗 `acct.sales_invoice`  |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ref` | `text` |  |  |
| `receipt_date` | `date` | ✱ | `CURRENT_DATE` |
| `journal_entry_id` | `bigint` | 🔗 `acct.journal_entry`  |  |

### `acct.cash_session` 🛡️

A shift of a cash box: opening, closing, variance and hand-over

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `cash_box_id` | `bigint` | 🔗 `acct.cash_box` ✱ |  |
| `opened_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `opened_at` | `timestamp with time zone` | ✱ | `now()` |
| `opening_amount` | `bigint` | ✱ | `0` |
| `closed_at` | `timestamp with time zone` |  |  |
| `closing_amount` | `bigint` |  |  |
| `expected_amount` | `bigint` |  |  |
| `variance` | `bigint` |  | `(closing_amount - expected_amount)` |
| `handed_over_at` | `timestamp with time zone` |  |  |
| `handed_over_to` | `bigint` | 🔗 `iam.app_user`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `acct.cost_center` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |

### `acct.credit_note` 🛡️

The only way to reduce an issued invoice (refunds); goes through e-invoicing like the invoice

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `credit_no` | `text` | ✱ |  |
| `invoice_id` | `bigint` | 🔗 `acct.sales_invoice` ✱ |  |
| `reason` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `tax` | `bigint` | ✱ | `0` |
| `einvoice_document_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `acct.einvoice_activation` 🛡️

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
| `source_refund_id` | `bigint` | 🔗 `sales.refund_request`  |  |
| `source_ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `source_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `source_shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `source_subscription_id` | `bigint` | 🔗 `sales.subscription`  |  |

### `acct.einvoice_line` 🛡️



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

### `acct.einvoice_submission` 🛡️ 🔒

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

### `acct.einvoice_template` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `acct.tax_authority` ✱ |  |
| `version` | `integer` | ✱ |  |
| `fields` | `jsonb` | ✱ |  |
| `qr_encoding` | `text` | ✱ | `'TLV_BASE64'::text` |
| `xml_schema_ref` | `text` |  |  |
| `valid_from` | `timestamp with time zone` | ✱ |  |

### `acct.einvoice_unit` 🛡️

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

### `acct.export_batch` 🛡️

File export of the books for systems without an API, with its checksum

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `format` | `text` | ✱ |  |
| `period` | `daterange` | ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `checksum` | `text` |  |  |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

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

### `acct.gl_period` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `period` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `closed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `closed_at` | `timestamp with time zone` |  |  |
| `id` | `bigint` | 🔑 ✱ | `identity` |

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

### `acct.journal_line` 🛡️



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

### `acct.posting_rule` 🛡️

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

### `acct.sales_invoice` 🛡️

Sales invoice of the books with gapless numbering per company; linked to its e-invoice when one is required

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `invoice_no` | `text` | ✱ |  |
| `customer_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `issue_date` | `date` | ✱ |  |
| `due_date` | `date` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `subtotal` | `bigint` | ✱ | `0` |
| `tax` | `bigint` | ✱ | `0` |
| `total` | `bigint` | ✱ | `0` |
| `source_type` | `text` |  |  |
| `source_id` | `bigint` |  |  |
| `einvoice_document_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `journal_entry_id` | `bigint` | 🔗 `acct.journal_entry`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `source_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `source_shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `source_subscription_id` | `bigint` | 🔗 `sales.subscription`  |  |

### `acct.sales_invoice_line` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `invoice_id` | `bigint` | 🔑 🔗 `acct.sales_invoice` ✱ |  |
| `line_no` | `smallint` | 🔑 ✱ |  |
| `description` | `text` | ✱ |  |
| `qty` | `numeric(12,3)` | ✱ | `1` |
| `unit_price` | `bigint` | ✱ |  |
| `tax_code_id` | `bigint` | 🔗 `acct.tax_code`  |  |
| `tax_amount` | `bigint` | ✱ | `0` |
| `amount` | `bigint` | ✱ |  |
| `account_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `cost_center_id` | `bigint` | 🔗 `acct.cost_center`  |  |

### `acct.sync_conflict` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `item_id` | `bigint` | 🔗 `acct.sync_item` ✱ |  |
| `conflict_type` | `text` | ✱ |  |
| `detail` | `jsonb` | ✱ | `'{}'::jsonb` |
| `resolution` | `text` |  |  |
| `resolved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `resolved_at` | `timestamp with time zone` |  |  |

### `acct.sync_item` 🛡️

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
| `job_id` | `bigint` | 🔗 `acct.sync_job`  |  |

### `acct.sync_job` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `connection_id` | `bigint` | 🔗 `acct.accounting_connection` ✱ |  |
| `batch_ref` | `text` | ✱ |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `finished_at` | `timestamp with time zone` |  |  |
| `items_total` | `integer` | ✱ | `0` |
| `items_failed` | `integer` | ✱ | `0` |
| `status` | `text` | ✱ | `'RUNNING'::text` |

### `acct.tax_authority` 🛡️

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

### `acct.tax_code` 🛡️

Tax code of the books, mapped to a GL account and to the pricing engine's tax rule

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `rate` | `numeric(6,3)` | ✱ |  |
| `account_id` | `bigint` | 🔗 `acct.gl_account`  |  |
| `tax_rule_id` | `bigint` | 🔗 `pricing.tax_rule`  |  |
| `active` | `boolean` | ✱ | `true` |

### `acct.tax_collection_no_file` 🛡️

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

### `acct.tax_payment` 🛡️



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

### `acct.tax_profile` 🛡️

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

### `acct.tax_profile_field` 🛡️

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

### `acct.tax_profile_value` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `profile_id` | `bigint` | 🔑 🔗 `acct.tax_profile` ✱ |  |
| `field_id` | `bigint` | 🔑 🔗 `acct.tax_profile_field` ✱ |  |
| `value` | `jsonb` | ✱ |  |

### `acct.tax_registration` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `profile_id` | `bigint` | 🔗 `acct.tax_profile` ✱ |  |
| `tax_scheme_id` | `bigint` | 🔗 `pricing.tax_scheme` ✱ |  |
| `filing_frequency` | `text` | ✱ |  |
| `registered` | `daterange` | ✱ |  |

### `acct.tax_return` 🛡️

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

### `acct.tax_return_line` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `return_id` | `bigint` | 🔑 🔗 `acct.tax_return` ✱ |  |
| `box_code` | `text` | 🔑 ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `source_note` | `text` |  |  |

<a id="bill"></a>
## `bill` — Carrier subscriptions, metering and platform invoices

### `bill.billed_usage` 🛡️

What has already been billed of the overage, so usage is never billed twice

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `subscription_id` | `bigint` | 🔗 `bill.company_subscription` ✱ |  |
| `invoice_id` | `bigint` | 🔗 `bill.carrier_invoice` ✱ |  |
| `kind` | `text` | ✱ |  |
| `qty` | `integer` | ✱ |  |
| `period_start` | `date` | ✱ |  |

### `bill.carrier_agreement` 🛡️

A negotiated agreement with one carrier, four-eyes approved

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `label` | `text` | ✱ |  |
| `terms` | `jsonb` | ✱ |  |
| `valid_days` | `integer` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `bill.carrier_invoice` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `subscription_id` | `bigint` | 🔗 `bill.company_subscription`  |  |
| `kind` | `text` | ✱ |  |
| `period_start` | `date` | ✱ |  |
| `period_end` | `date` | ✱ |  |
| `subtotal` | `bigint` | ✱ | `0` |
| `discount` | `bigint` | ✱ | `0` |
| `tax` | `bigint` | ✱ | `0` |
| `total` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'DUE'::text` |
| `einvoice_document_id` | `bigint` | 🔗 `acct.einvoice_document`  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `bill.carrier_invoice_line` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `invoice_id` | `bigint` | 🔑 🔗 `bill.carrier_invoice` ✱ |  |
| `line_no` | `smallint` | 🔑 ✱ |  |
| `kind` | `text` | ✱ |  |
| `description` | `text` | ✱ |  |
| `qty` | `numeric(12,2)` | ✱ | `1` |
| `unit_price` | `bigint` | ✱ |  |
| `amount` | `bigint` | ✱ |  |

### `bill.company_subscription` 🛡️

One active subscription per company; terms are copied at start

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `source` | `text` | ✱ |  |
| `plan_id` | `bigint` | 🔗 `bill.plan`  |  |
| `agreement_id` | `bigint` | 🔗 `bill.carrier_agreement`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `starts_at` | `timestamp with time zone` | ✱ |  |
| `ends_at` | `timestamp with time zone` | ✱ |  |
| `terms` | `jsonb` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `bill.plan` 🛡️

Package catalog: three carrier plans and two shuttle plans with included quantities and overage (5.11 d)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `annual_fee` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `included_users` | `integer` | ✱ | `1` |
| `extra_user_fee` | `bigint` | ✱ | `0` |
| `max_extra_users` | `integer` |  |  |
| `included_invoices` | `integer` | ✱ | `0` |
| `included_api_calls` | `integer` | ✱ | `0` |
| `included_whatsapp` | `integer` | ✱ | `0` |
| `commission_bp` | `integer` | ✱ | `0` |
| `overage_invoice_fee` | `bigint` | ✱ | `0` |
| `overage_api_per_1000` | `bigint` | ✱ | `0` |
| `overage_whatsapp_fee` | `bigint` | ✱ | `0` |
| `self_service` | `boolean` | ✱ | `true` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `bill.usage_event` 🛡️ 🔒

Metering log; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `kind` | `text` | ✱ |  |
| `qty` | `integer` | ✱ | `1` |
| `ref_type` | `text` |  |  |
| `ref_id` | `bigint` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

<a id="crm"></a>
## `crm` — Complaints, ratings, notifications, the AI assistant and the contact center

### `crm.ai_conversation` 🛡️



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

### `crm.ai_eval_case` 🛡️

Test set of the assistant per dialect, run before each model or policy change

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `lang_dialect` | `text` | ✱ |  |
| `input` | `text` | ✱ |  |
| `expected` | `text` | ✱ |  |
| `last_result` | `text` |  |  |
| `last_run_at` | `timestamp with time zone` |  |  |
| `active` | `boolean` | ✱ | `true` |

### `crm.ai_message` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `conversation_id` | `bigint` | 🔗 `crm.ai_conversation` ✱ |  |
| `role` | `text` | ✱ |  |
| `redacted_text` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.ai_policy` 🛡️

Assistant tools, each tool's action level, limits and user confirmation requirement

| Column | Type | Constraints | Default |
|---|---|---|---|
| `tool` | `text` | 🔑 ✱ |  |
| `action_level` | `smallint` | ✱ |  |
| `limits` | `jsonb` | ✱ | `'{}'::jsonb` |
| `requires_confirmation` | `boolean` | ✱ | `true` |
| `enabled` | `boolean` | ✱ | `false` |

### `crm.ai_tool_call` 🛡️ 🔒

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

### `crm.call` 🛡️

Every call: AI first, warm transfer to an agent when needed (7.11)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `direction` | `text` | ✱ |  |
| `caller_hash` | `bytea` | ✱ |  |
| `line_ref` | `text` |  |  |
| `queue_id` | `bigint` | 🔗 `crm.call_queue`  |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `case_id` | `bigint` | 🔗 `crm.case`  |  |
| `ai_conversation_id` | `bigint` | 🔗 `crm.ai_conversation`  |  |
| `agent_id` | `bigint` | 🔗 `crm.call_agent`  |  |
| `handled_by` | `text` |  |  |
| `state` | `text` | ✱ | `'RINGING'::text` |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `answered_at` | `timestamp with time zone` |  |  |
| `ended_at` | `timestamp with time zone` |  |  |
| `outcome` | `text` |  |  |
| `recording_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `transcript_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `csat` | `smallint` |  |  |

### `crm.call_agent` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `shift` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'OFFLINE'::text` |

### `crm.call_agent_skill` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `agent_id` | `bigint` | 🔑 🔗 `crm.call_agent` ✱ |  |
| `skill_code` | `text` | 🔑 🔗 `crm.call_skill` ✱ |  |
| `level` | `smallint` | ✱ | `1` |

### `crm.call_event` 🛡️ 🔒



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `call_id` | `bigint` | 🔗 `crm.call` ✱ |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |
| `kind` | `text` | ✱ |  |
| `detail_redacted` | `jsonb` | ✱ | `'{}'::jsonb` |

### `crm.call_qa` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `call_id` | `bigint` | 🔗 `crm.call` ✱ |  |
| `scorer` | `text` | ✱ |  |
| `scorer_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `score` | `numeric(5,2)` | ✱ |  |
| `flags` | `text[]` | ✱ | `'{}'::text[]` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `crm.call_queue` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `channel` | `text` | ✱ | `'VOICE'::text` |
| `sla_target_sec` | `integer` | ✱ | `60` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `crm.call_queue_skill` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `queue_id` | `bigint` | 🔑 🔗 `crm.call_queue` ✱ |  |
| `skill_code` | `text` | 🔑 🔗 `crm.call_skill` ✱ |  |

### `crm.call_skill` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |

### `crm.callback_request` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `call_id` | `bigint` | 🔗 `crm.call`  |  |
| `phone_hash` | `bytea` | ✱ |  |
| `reason` | `text` | ✱ |  |
| `due_at` | `timestamp with time zone` | ✱ |  |
| `assigned_agent_id` | `bigint` | 🔗 `crm.call_agent`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

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

### `crm.case_event` 🛡️ 🔒



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

### `crm.notification` 🛡️



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
| `event_uid` | `uuid` |  |  |
| `last_error` | `text` |  |  |

### `crm.notification_template` 🛡️

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

### `crm.trip_rating` 🛡️

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

### `gov.consent` 🛡️

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

### `gov.data_inventory` 🛡️

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
| `erasure_method` | `text` |  |  |
| `copies` | `text[]` | ✱ | `'{}'::text[]` |
| `backup_retention_days` | `integer` |  |  |

### `gov.data_purpose` 🛡️

Why restricted data is read; some purposes need a written reason or a second officer

| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `description` | `text` | ✱ |  |
| `requires_reason` | `boolean` | ✱ | `true` |
| `requires_second_approval` | `boolean` | ✱ | `false` |

### `gov.erasure_log` 🛡️

Each erasure: what was pseudonymised, what was kept and why

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `request_id` | `bigint` | 🔗 `gov.subject_request`  |  |
| `outcome` | `text` | ✱ |  |
| `detail` | `jsonb` | ✱ |  |
| `done_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `done_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.feature_compliance_review` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `feature` | `text` | ✱ |  |
| `dpia_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `obligations` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `decision` | `text` | ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.legal_hold` 🛡️

Records that must not be deleted or anonymised while a case is open; release needs a second officer

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `scope_type` | `text` | ✱ |  |
| `scope_id` | `bigint` |  |  |
| `dataset` | `text` |  |  |
| `reason` | `text` | ✱ |  |
| `case_ref` | `text` | ✱ |  |
| `placed_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `placed_at` | `timestamp with time zone` | ✱ | `now()` |
| `released_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `released_at` | `timestamp with time zone` |  |  |

### `gov.obligation_register` 🛡️

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

### `gov.partner_dpa` 🛡️

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

### `gov.policy_authority` 🛡️

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

### `gov.policy_change` 🛡️

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

### `gov.policy_domain` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `class` | `text` | ✱ |  |
| `regulated_bounds` | `jsonb` |  |  |

### `gov.privacy_incident` 🛡️



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

### `gov.retention_policy` 🛡️

How long each kind of record is kept and what happens after (review 3.15)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `dataset` | `text` | ✱ |  |
| `retention_days` | `integer` | ✱ |  |
| `action` | `text` | ✱ |  |
| `legal_basis` | `text` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `gov.subject_request` 🛡️



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
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `reason` | `text` |  |  |
| `handled_at` | `timestamp with time zone` |  |  |

<a id="sec"></a>
## `sec` — Security: IP rules, risk, signing, the security hub and government adapters

### `sec.access_review` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `role_id` | `bigint` | 🔗 `iam.role`  |  |
| `reviewer_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `decision` | `text` | ✱ |  |
| `reviewed_on` | `date` | ✱ | `CURRENT_DATE` |
| `due_on` | `date` |  |  |
| `scope` | `text` |  |  |

### `sec.authority_alert` 🛡️

Notifications to the regulator: a vehicle operating with an expired licence or an unregistered trip (4.16 g)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile`  |  |
| `alert_type` | `text` | ✱ |  |
| `evidence_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `sent_to_authority` | `boolean` | ✱ | `false` |
| `sent_at` | `timestamp with time zone` |  |  |
| `response_ref` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.authority_data_request` 🛡️

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

### `sec.authority_order` 🛡️



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
| `target_trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `target_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `target_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `target_ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `target_wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `target_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `target_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `target_payment_id` | `bigint` | 🔗 `fin.payment`  |  |
| `target_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `target_document_id` | `bigint` | 🔗 `iam.document`  |  |

### `sec.authority_policy` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `applies_to` | `jsonb` | ✱ |  |
| `checkpoint` | `text` | ✱ |  |
| `mandatory` | `boolean` | ✱ | `true` |
| `decision_map` | `jsonb` | ✱ | `'{}'::jsonb` |

### `sec.authority_profile` 🛡️

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

### `sec.authority_scope` 🛡️

What each authority may receive, where, on which legal basis, approved by a second officer

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `data_category` | `text` | ✱ |  |
| `scope_type` | `text` | ✱ |  |
| `scope_value` | `text` |  |  |
| `legal_basis` | `text` | ✱ |  |
| `valid` | `daterange` | ✱ |  |
| `created_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sec.blocklist_entry` 🛡️

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

### `sec.break_glass_log` 🛡️

Break-glass access with elevated privileges: reason, approval and duration

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `actor_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `reason` | `text` | ✱ |  |
| `approver_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `started_at` | `timestamp with time zone` | ✱ | `now()` |
| `ended_at` | `timestamp with time zone` |  |  |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `incident_ref` | `text` | ✱ |  |
| `scope` | `text` | ✱ |  |
| `emergency` | `boolean` | ✱ | `false` |
| `closed_reason` | `text` |  |  |
| `reviewed_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `reviewed_at` | `timestamp with time zone` |  |  |
| `review_note` | `text` |  |  |
| `review_alerted_at` | `timestamp with time zone` |  |  |

### `sec.document_signature` 🛡️

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

### `sec.external_access_grant` 🛡️

Every access given to an external auditor or tester: who, for which engagement, granted by whom, until when (owner decision, 8 October 2026)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `granted_by` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `organisation` | `text` | ✱ |  |
| `purpose` | `text` | ✱ |  |
| `engagement_ref` | `text` | ✱ |  |
| `starts_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `revoked_at` | `timestamp with time zone` |  |  |
| `revoked_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sec.fraud_case` 🛡️



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
| `subject_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `subject_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_device_id` | `bigint` | 🔗 `iam.device`  |  |
| `subject_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `subject_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_payment_id` | `bigint` | 🔗 `fin.payment`  |  |
| `subject_api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `subject_withdrawal_id` | `bigint` | 🔗 `fin.withdrawal_request`  |  |

### `sec.gov_adapter_config` 🛡️

Adapter to a government registry; field mapping changes by configuration (phase 5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `adapter_type` | `text` | ✱ |  |
| `endpoint` | `text` | ✱ |  |
| `protocol` | `text` | ✱ |  |
| `cert_ref` | `text` |  |  |
| `mapping` | `jsonb` | ✱ | `'{}'::jsonb` |
| `timeout_ms` | `integer` | ✱ | `5000` |
| `status` | `text` | ✱ | `'TESTING'::text` |

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

### `sec.key_registry` 🛡️

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
| `key_version` | `integer` | ✱ | `1` |
| `kms_key_id` | `text` |  |  |
| `wrapped_dek` | `bytea` |  |  |

### `sec.manifest_submission` 🛡️

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

### `sec.policy_decision` 🛡️ 🔒

Every decision to read restricted data, with its purpose, reason and policy version (review 3.11)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `decided_at` | `timestamp with time zone` | ✱ | `now()` |
| `request_id` | `uuid` |  |  |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `scope` | `text` |  |  |
| `resource` | `text` | ✱ |  |
| `action` | `text` | ✱ |  |
| `purpose_code` | `text` | 🔗 `gov.data_purpose`  |  |
| `reason` | `text` |  |  |
| `decision` | `text` | ✱ |  |
| `rule` | `text` | ✱ |  |
| `policy_version` | `text` | ✱ |  |

### `sec.risk_assessment` 🛡️



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
| `subject_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `subject_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_booking_id` | `bigint` | 🔗 `sales.booking`  |  |
| `subject_payment_id` | `bigint` | 🔗 `fin.payment`  |  |
| `subject_api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `subject_withdrawal_id` | `bigint` | 🔗 `fin.withdrawal_request`  |  |

### `sec.screening_request` 🛡️



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
| `subject_host_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_driver_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `subject_passenger_id` | `bigint` | 🔗 `iam.party`  |  |
| `context_trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `context_booking_id` | `bigint` | 🔗 `sales.booking`  |  |

### `sec.screening_result` 🛡️



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

### `sec.sos_event` 🛡️



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

### `sec.tamper_event` 🛡️ 🔒

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

### `sec.verification_job` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `adapter_id` | `bigint` | 🔗 `sec.gov_adapter_config` ✱ |  |
| `verification_id` | `bigint` | 🔗 `iam.verification`  |  |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` | ✱ |  |
| `request_ref` | `text` |  |  |
| `status` | `text` | ✱ | `'QUEUED'::text` |
| `attempts` | `integer` | ✱ | `0` |
| `result` | `jsonb` |  |  |
| `requested_at` | `timestamp with time zone` | ✱ | `now()` |
| `completed_at` | `timestamp with time zone` |  |  |
| `subject_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `subject_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `subject_license_id` | `bigint` | 🔗 `fleet.license_record`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `subject_document_id` | `bigint` | 🔗 `iam.document`  |  |

### `sec.watchlist_entry` 🛡️

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

<a id="ptn"></a>
## `ptn` — Service partners: fuel stations, rest stops and maintenance

### `ptn.fuel_anomaly` 🛡️

Fuel quantity that does not match tank size, distance or expected consumption (14.11 f)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `session_id` | `bigint` | 🔗 `ptn.fuel_session` ✱ |  |
| `anomaly_type` | `text` | ✱ |  |
| `severity` | `text` | ✱ |  |
| `distance_odometer_km` | `numeric(9,1)` |  |  |
| `distance_gps_km` | `numeric(9,1)` |  |  |
| `distance_trips_km` | `numeric(9,1)` |  |  |
| `liters` | `numeric(8,2)` |  |  |
| `evidence` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `resolved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `resolved_at` | `timestamp with time zone` |  |  |

### `ptn.fuel_card` 🛡️

Virtual fuel card of a carrier, bound to a vehicle or a driver, with limits

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `driver_party_id` | `bigint` | 🔗 `fleet.crew_profile`  |  |
| `daily_limit` | `bigint` |  |  |
| `monthly_limit` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `fuel_types` | `text[]` | ✱ | `'{DIESEL}'::text[]` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.fuel_price` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `fuel_type` | `text` | ✱ |  |
| `unit_price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid_from` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.fuel_session` 🛡️

Refuelling session that precedes the sale and carries the odometer evidence (14.11 f)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `pump_ref` | `text` |  |  |
| `station_employee_id` | `bigint` | 🔗 `ptn.station_employee` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `driver_party_id` | `bigint` | 🔗 `fleet.crew_profile`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `fuel_card_id` | `bigint` | 🔗 `ptn.fuel_card`  |  |
| `opened_at` | `timestamp with time zone` | ✱ | `now()` |
| `closed_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `ptn.odometer_reading` 🛡️ 🔒

Series of odometer readings per vehicle; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `session_id` | `bigint` | 🔗 `ptn.fuel_session`  |  |
| `value_km` | `integer` | ✱ |  |
| `photo_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `ocr_value` | `integer` |  |  |
| `driver_confirmed` | `boolean` | ✱ | `false` |
| `employee_confirmed` | `boolean` | ✱ | `false` |
| `source` | `text` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.partner` 🛡️

A contracted service partner, registered on the station pattern (14.11, 4.11)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `partner_type` | `text` | ✱ |  |
| `code` | `text` | ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `geofence_m` | `integer` | ✱ | `150` |
| `license_no` | `text` |  |  |
| `license_expiry` | `date` |  |  |
| `hours` | `jsonb` | ✱ | `'{}'::jsonb` |
| `menu_enabled` | `boolean` | ✱ | `false` |
| `preorder_enabled` | `boolean` | ✱ | `false` |
| `avg_service_min` | `smallint` |  |  |
| `compliance_state` | `text` | ✱ | `'PENDING'::text` |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.partner_contract` 🛡️

Versioned commission contract with dual approval; one active contract per period

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `commission_model` | `text` | ✱ |  |
| `rate_bp` | `integer` |  |  |
| `fixed_fee` | `bigint` |  |  |
| `tiers` | `jsonb` |  |  |
| `carrier_fee` | `bigint` | ✱ | `0` |
| `carrier_share_pct` | `numeric(5,2)` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `settlement_cycle` | `text` | ✱ | `'WEEKLY'::text` |
| `credit_terms` | `jsonb` | ✱ | `'{}'::jsonb` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `ptn.partner_menu_item` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `name` | `text` | ✱ |  |
| `category` | `text` | ✱ | `'FOOD'::text` |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `available` | `boolean` | ✱ | `true` |

### `ptn.partner_order` 🛡️

Pre-order at a rest stop on the trip (14.11 e); its lines are ptn.partner_order_item

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `pickup_eta` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'PLACED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.partner_order_item` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `order_id` | `bigint` | 🔑 🔗 `ptn.partner_order` ✱ |  |
| `menu_item_id` | `bigint` | 🔑 🔗 `ptn.partner_menu_item` ✱ |  |
| `qty` | `smallint` | ✱ |  |
| `unit_price` | `bigint` | ✱ |  |

### `ptn.partner_sale` 🛡️

The shared sale transaction for fuel and rest stops, posted through the ledger

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `session_id` | `bigint` | 🔗 `ptn.fuel_session`  |  |
| `order_id` | `bigint` | 🔗 `ptn.partner_order`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `driver_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `fuel_type` | `text` |  |  |
| `qty` | `numeric(10,2)` |  |  |
| `unit_price` | `bigint` |  |  |
| `amount` | `bigint` | ✱ |  |
| `points_used` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `method` | `text` | ✱ |  |
| `odometer_km` | `integer` |  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `status` | `text` | ✱ | `'COMPLETED'::text` |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.partner_settlement` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `period` | `daterange` | ✱ |  |
| `gross` | `bigint` | ✱ | `0` |
| `commission` | `bigint` | ✱ | `0` |
| `carrier_share` | `bigint` | ✱ | `0` |
| `redemptions` | `bigint` | ✱ | `0` |
| `net` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `ptn.rest_stop_rating` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `overall` | `smallint` | ✱ |  |
| `cleanliness` | `smallint` |  |  |
| `service` | `smallint` |  |  |
| `value` | `smallint` |  |  |
| `comment` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ptn.station_employee` 🛡️

A personal account per attendant, so every fuel session has a named employee

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ptn.partner` ✱ |  |
| `user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `role` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

<a id="ship"></a>
## `ship` — Shipments and the integrated shipping network

### `ship.access_point` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `partner_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `point_type` | `text` | ✱ |  |
| `capacity` | `integer` |  |  |
| `hours` | `jsonb` | ✱ | `'{}'::jsonb` |
| `services` | `text[]` | ✱ | `'{DROP_OFF,PICK_UP}'::text[]` |
| `hold_days` | `smallint` | ✱ | `5` |
| `commission_bp` | `integer` | ✱ | `0` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `ship.address` 🛡️

Structured address with a short code, for areas without formal addresses (9.21)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `geo_zone_id` | `bigint` | 🔗 `ship.geo_zone`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `address_text` | `text` | ✱ |  |
| `landmark` | `text` |  |  |
| `short_code` | `text` |  |  |
| `verified` | `boolean` | ✱ | `false` |
| `last_delivered_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.capacity_booking` 🛡️

B2B capacity bought on a load, trip or route by a courier company; generalizes cargo_booking

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `load_id` | `bigint` | 🔗 `ship.load`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `seller_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `buyer_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `reserved_weight_kg` | `numeric(10,2)` | ✱ |  |
| `reserved_volume_m3` | `numeric(8,2)` |  |  |
| `positions` | `smallint` |  |  |
| `rate` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.cargo_claim` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `claim_type` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `liable_leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `case_id` | `bigint` | 🔗 `crm.case`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.cargo_rate_card` 🛡️

A bus carrier's rates for parcels in the luggage hold (9.4); feeds the pricing engine

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `service_id` | `bigint` | 🔗 `ship.service_product`  |  |
| `weight_from_kg` | `numeric(9,2)` | ✱ | `0` |
| `weight_to_kg` | `numeric(9,2)` | ✱ |  |
| `volume_to_m3` | `numeric(8,3)` |  |  |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid` | `daterange` | ✱ |  |

### `ship.carrier_scorecard` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `carrier_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `access_point_id` | `bigint` | 🔗 `ship.access_point`  |  |
| `period` | `daterange` | ✱ |  |
| `otd_pct` | `numeric(5,2)` |  |  |
| `fadr_pct` | `numeric(5,2)` |  |  |
| `scan_pct` | `numeric(5,2)` |  |  |
| `damage_pct` | `numeric(5,2)` |  |  |
| `loss_pct` | `numeric(5,2)` |  |  |
| `score` | `numeric(5,2)` |  |  |

### `ship.cod_collection` 🛡️

Cash on delivery, passed through the ledger to the merchant

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `collected_at` | `timestamp with time zone` |  |  |
| `collected_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

### `ship.courier_assignment` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `courier_route_id` | `bigint` | 🔗 `ship.courier_route` ✱ |  |
| `stop_seq` | `smallint` | ✱ |  |
| `kind` | `text` | ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `pickup_request_id` | `bigint` | 🔗 `ship.pickup_request`  |  |
| `eta` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

### `ship.courier_route` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `hub_id` | `bigint` | 🔗 `ship.hub`  |  |
| `courier_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `route_date` | `date` | ✱ |  |
| `status` | `text` | ✱ | `'PLANNED'::text` |

### `ship.custody_transfer` 🛡️ 🔒

Chain of custody between carriers, couriers and points; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `unit_id` | `bigint` | 🔗 `ship.handling_unit`  |  |
| `from_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `to_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `method` | `text` | ✱ |  |
| `signature_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ship.delivery_attempt` 🛡️ 🔒



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `attempt_no` | `smallint` | ✱ |  |
| `courier_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `result` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `responsible` | `text` |  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ship.delivery_preference` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `pref_type` | `text` | ✱ |  |
| `value` | `jsonb` | ✱ |  |
| `requested_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `fee` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.delivery_proof` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `shipment_id` | `bigint` | 🔑 🔗 `ship.shipment` ✱ |  |
| `attempt_id` | `bigint` | 🔗 `ship.delivery_attempt`  |  |
| `method` | `text` | ✱ |  |
| `evidence_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `delivered_to` | `text` | ✱ |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ship.fuel_surcharge_index` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `period` | `daterange` | ✱ |  |
| `diesel_price_ref` | `bigint` | ✱ |  |
| `pct` | `numeric(5,2)` | ✱ |  |
| `published_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.geo_zone` 🛡️

Delivery zone served by a hub, with its class (remote areas carry a surcharge)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `governorate` | `text` |  |  |
| `city_id` | `bigint` | 🔗 `ref.city`  |  |
| `district` | `text` |  |  |
| `polygon` | `jsonb` |  |  |
| `zone_class` | `text` | ✱ | `'NORMAL'::text` |
| `servicing_hub_id` | `bigint` | 🔗 `ship.hub`  |  |
| `delivery_days` | `smallint[]` | ✱ | `'{1,2,3,4,5,6}'::smallint[]` |

### `ship.guarantee_claim` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `committed_at` | `timestamp with time zone` | ✱ |  |
| `delivered_at` | `timestamp with time zone` |  |  |
| `eligible` | `boolean` |  |  |
| `exclusion_reason` | `text` |  |  |
| `refund_amount` | `bigint` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `chargeback_leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `ship.handling_unit` 🛡️

Bag, cage, pallet or container; units nest, and a unit's scan is inherited by its contents

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `unit_type` | `text` | ✱ |  |
| `parent_unit_id` | `bigint` | 🔗 `ship.handling_unit`  |  |
| `label_no` | `text` | ✱ |  |
| `seal_no` | `text` |  |  |
| `current_station_id` | `bigint` | 🔗 `net.station`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.handling_unit_item` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `unit_id` | `bigint` | 🔗 `ship.handling_unit` ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `parcel_id` | `bigint` | 🔗 `ship.parcel`  |  |
| `added_at` | `timestamp with time zone` | ✱ | `now()` |
| `removed_at` | `timestamp with time zone` |  |  |

### `ship.hub` 🛡️

Sorting hub on a depot station (9.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `sort_capacity` | `integer` |  |  |
| `hours` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `ship.integration_message` 🛡️

Outbox, inbox and dead-letter queue of partner messages

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `direction` | `text` | ✱ |  |
| `message_type` | `text` | ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `sequence_no` | `bigint` |  |  |
| `idempotency_key` | `text` | ✱ |  |
| `payload_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `attempts` | `integer` | ✱ | `0` |
| `next_retry_at` | `timestamp with time zone` |  |  |
| `error_code` | `text` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.integration_partner` 🛡️

Global and local partners connected by configuration, not custom development (9.25)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `partner_type` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `protocol` | `text` | ✱ | `'REST'::text` |
| `status` | `text` | ✱ | `'SANDBOX'::text` |

### `ship.linehaul_schedule` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `origin_hub_id` | `bigint` | 🔗 `ship.hub` ✱ |  |
| `dest_hub_id` | `bigint` | 🔗 `ship.hub` ✱ |  |
| `departure_time` | `time without time zone` | ✱ |  |
| `arrival_time` | `time without time zone` | ✱ |  |
| `days` | `smallint[]` | ✱ | `'{1,2,3,4,5,6}'::smallint[]` |
| `mode` | `text` | ✱ |  |
| `carrier_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `capacity_kg` | `numeric(10,2)` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `ship.load` 🛡️

Truck or hold load with capacity by weight, volume and pallet positions; no booking once full (9.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `truck_combination_id` | `bigint` | 🔗 `fleet.truck_combination`  |  |
| `load_type` | `text` | ✱ |  |
| `origin_hub_id` | `bigint` | 🔗 `ship.hub`  |  |
| `dest_hub_id` | `bigint` | 🔗 `ship.hub`  |  |
| `max_weight_kg` | `numeric(10,2)` | ✱ |  |
| `max_volume_m3` | `numeric(8,2)` |  |  |
| `pallet_positions` | `smallint` |  |  |
| `used_weight_kg` | `numeric(10,2)` | ✱ | `0` |
| `used_volume_m3` | `numeric(8,2)` | ✱ | `0` |
| `seal_no` | `text` |  |  |
| `status` | `text` | ✱ | `'PLANNED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.load_plan` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `load_id` | `bigint` | 🔑 🔗 `ship.load` ✱ |  |
| `handling_unit_id` | `bigint` | 🔑 🔗 `ship.handling_unit` ✱ |  |
| `stop_seq` | `smallint` | ✱ |  |
| `position` | `text` |  |  |

### `ship.load_stop` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `load_id` | `bigint` | 🔑 🔗 `ship.load` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `planned_at` | `timestamp with time zone` |  |  |
| `actual_at` | `timestamp with time zone` |  |  |

### `ship.locker_compartment` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `access_point_id` | `bigint` | 🔗 `ship.access_point` ✱ |  |
| `code` | `text` | ✱ |  |
| `size` | `text` | ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `pin_hash` | `bytea` |  |  |
| `expires_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'FREE'::text` |

### `ship.parcel` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `piece_no` | `smallint` | ✱ |  |
| `label_no` | `text` | ✱ |  |
| `weight_kg` | `numeric(9,2)` | ✱ |  |
| `length_cm` | `numeric(7,1)` |  |  |
| `width_cm` | `numeric(7,1)` |  |  |
| `height_cm` | `numeric(7,1)` |  |  |
| `content_desc` | `text` | ✱ |  |
| `hs_code` | `text` |  |  |
| `fragile` | `boolean` | ✱ | `false` |

### `ship.partner_command` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `command_type` | `text` | ✱ |  |
| `payload_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `idempotency_key` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'RECEIVED'::text` |
| `applied_at` | `timestamp with time zone` |  |  |

### `ship.partner_contract` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `roles` | `text[]` | ✱ |  |
| `services` | `text[]` | ✱ | `'{}'::text[]` |
| `territory` | `text[]` | ✱ | `'{SY}'::text[]` |
| `exclusive` | `boolean` | ✱ | `false` |
| `sla` | `jsonb` | ✱ | `'{}'::jsonb` |
| `fees` | `jsonb` | ✱ | `'{}'::jsonb` |
| `liability_cap` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'USD'::bpchar` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `ship.partner_pre_alert` 🛡️

Incoming manifest that creates shipments with status EXPECTED

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `manifest_no` | `text` | ✱ |  |
| `flight_or_trip_ref` | `text` |  |  |
| `expected_at` | `timestamp with time zone` |  |  |
| `item_count` | `integer` | ✱ |  |
| `status` | `text` | ✱ | `'RECEIVED'::text` |

### `ship.partner_reconciliation` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `recon_date` | `date` | ✱ |  |
| `matched` | `integer` | ✱ | `0` |
| `missing_in_platform` | `integer` | ✱ | `0` |
| `missing_in_partner` | `integer` | ✱ | `0` |
| `amount_diff` | `bigint` | ✱ | `0` |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `ship.partner_settlement` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `partner_id` | `bigint` | 🔗 `ship.integration_partner` ✱ |  |
| `period` | `daterange` | ✱ |  |
| `service_fees` | `bigint` | ✱ | `0` |
| `collected_on_behalf` | `bigint` | ✱ | `0` |
| `claims` | `bigint` | ✱ | `0` |
| `net_amount` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'USD'::bpchar` |
| `fx_rate` | `numeric(18,8)` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `ship.partner_status_map` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `partner_id` | `bigint` | 🔑 🔗 `ship.integration_partner` ✱ |  |
| `direction` | `text` | 🔑 ✱ |  |
| `external_code` | `text` | 🔑 ✱ |  |
| `external_reason` | `text` | 🔑 ✱ | `''::text` |
| `milestone` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `version` | `integer` | 🔑 ✱ | `1` |

### `ship.pickup_request` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `shipper_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `address_id` | `bigint` | 🔗 `ship.address` ✱ |  |
| `pickup_window` | `tstzrange` | ✱ |  |
| `pieces` | `integer` | ✱ | `1` |
| `courier_route_id` | `bigint` | 🔗 `ship.courier_route`  |  |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.pricing_agreement` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `discounts` | `jsonb` | ✱ | `'{}'::jsonb` |
| `earned_tiers` | `jsonb` | ✱ | `'[]'::jsonb` |
| `min_charge_override` | `bigint` |  |  |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `account_id` | `bigint` | 🔗 `ship.shipper_account`  |  |

### `ship.pricing_zone_chart` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `origin_zone_id` | `bigint` | 🔑 🔗 `ship.geo_zone` ✱ |  |
| `dest_zone_id` | `bigint` | 🔑 🔗 `ship.geo_zone` ✱ |  |
| `price_zone` | `text` | ✱ |  |
| `valid` | `daterange` | 🔑 ✱ | `daterange(CURRENT_DATE, NULL::date)` |

### `ship.prohibited_item` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `hs_prefix` | `text` |  |  |
| `rule` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country`  |  |

### `ship.rate_table` 🛡️

Published rate table per service: price by zone and weight break (9.21)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `service_id` | `bigint` | 🔗 `ship.service_product` ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `ship.rate_table_entry` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `rate_table_id` | `bigint` | 🔑 🔗 `ship.rate_table` ✱ |  |
| `price_zone` | `text` | 🔑 ✱ |  |
| `weight_break` | `numeric(9,2)` | 🔑 ✱ |  |
| `price` | `bigint` | ✱ |  |
| `per_kg_over` | `bigint` | ✱ | `0` |
| `min_charge` | `bigint` | ✱ | `0` |

### `ship.return_authorization` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `original_shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `merchant_account_id` | `bigint` | 🔗 `ship.shipper_account`  |  |
| `reason` | `text` | ✱ |  |
| `return_shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `status` | `text` | ✱ | `'REQUESTED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.routing_rule` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `service_id` | `bigint` | 🔗 `ship.service_product` ✱ |  |
| `origin_zone_id` | `bigint` | 🔗 `ship.geo_zone`  |  |
| `dest_zone_id` | `bigint` | 🔗 `ship.geo_zone`  |  |
| `preferred_modes` | `text[]` | ✱ |  |
| `cutoff_time` | `time without time zone` |  |  |
| `transit_days` | `smallint` |  |  |
| `priority` | `integer` | ✱ | `100` |

### `ship.service_option` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `applicable_services` | `text[]` | ✱ | `'{}'::text[]` |
| `surcharge_id` | `bigint` | 🔗 `ship.surcharge_definition`  |  |

### `ship.service_product` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `cutoff_time` | `time without time zone` |  |  |
| `guaranteed` | `boolean` | ✱ | `false` |
| `max_weight_kg` | `numeric(9,2)` |  |  |
| `max_dims_cm` | `integer[]` |  |  |
| `network_model` | `text` | ✱ | `'NETWORK'::text` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `ship.shipment` 🛡️

A consignment from sender to receiver, independent of the vehicles that carry it (9.4, 9.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `tracking_no` | `text` | ✱ |  |
| `master_tracking_no` | `text` |  |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `shipper_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `shipper_account_id` | `bigint` | 🔗 `ship.shipper_account`  |  |
| `merchant_ref` | `text` |  |  |
| `service_id` | `bigint` | 🔗 `ship.service_product` ✱ |  |
| `shipper_type` | `text` | ✱ | `'INDIVIDUAL'::text` |
| `origin_station_id` | `bigint` | 🔗 `net.station`  |  |
| `dest_station_id` | `bigint` | 🔗 `net.station`  |  |
| `origin_address_id` | `bigint` | 🔗 `ship.address`  |  |
| `dest_address_id` | `bigint` | 🔗 `ship.address`  |  |
| `payer_type` | `text` | ✱ | `'SENDER'::text` |
| `payer_account_id` | `bigint` | 🔗 `ship.shipper_account`  |  |
| `declared_value` | `bigint` | ✱ | `0` |
| `cod_amount` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `billable_weight_kg` | `numeric(9,2)` |  |  |
| `dim_weight_kg` | `numeric(9,2)` |  |  |
| `cargo_category` | `text` | 🔗 `ref.cargo_category`  |  |
| `routing_code` | `text` |  |  |
| `committed_delivery_at` | `timestamp with time zone` |  |  |
| `signature_level` | `text` | ✱ | `'NONE'::text` |
| `price_breakdown` | `jsonb` |  |  |
| `current_leg_seq` | `smallint` |  |  |
| `eta` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'CREATED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |
| `recipient_name` | `text` |  |  |
| `recipient_mobile` | `text` |  |  |
| `contents` | `text` |  |  |

### `ship.shipment_leg` 🛡️

One leg per mode and carrier; generalizes cargo_assignment (9.4) and the freight leg (10.9)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `seq` | `smallint` | ✱ |  |
| `mode` | `text` | ✱ |  |
| `carrier_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `load_id` | `bigint` | 🔗 `ship.load`  |  |
| `courier_route_id` | `bigint` | 🔗 `ship.courier_route`  |  |
| `from_station_id` | `bigint` | 🔗 `net.station`  |  |
| `to_station_id` | `bigint` | 🔗 `net.station`  |  |
| `from_seq` | `smallint` |  |  |
| `to_seq` | `smallint` |  |  |
| `price` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'PLANNED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `contract_id` | `bigint` | 🔗 `frt.freight_contract`  |  |

### `ship.shipment_option` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `shipment_id` | `bigint` | 🔑 🔗 `ship.shipment` ✱ |  |
| `option_id` | `bigint` | 🔑 🔗 `ship.service_option` ✱ |  |
| `value` | `jsonb` |  |  |

### `ship.shipment_party` 🛡️

Sender and receiver data required for security screening; identity numbers are encrypted

| Column | Type | Constraints | Default |
|---|---|---|---|
| `shipment_id` | `bigint` | 🔑 🔗 `ship.shipment` ✱ |  |
| `role` | `text` | 🔑 ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party`  |  |
| `name` | `text` | ✱ |  |
| `id_type` | `text` |  |  |
| `id_no_enc` | `bytea` |  |  |
| `id_no_bidx` | `bytea` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `mobile` | `text` | ✱ |  |
| `address_id` | `bigint` | 🔗 `ship.address`  |  |

### `ship.shipment_reference` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment` ✱ |  |
| `parcel_id` | `bigint` | 🔗 `ship.parcel`  |  |
| `ref_type` | `text` | ✱ |  |
| `issuer_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `value` | `text` | ✱ |  |
| `normalized_value` | `text` | ✱ |  |
| `pushed_to_issuer_at` | `timestamp with time zone` |  |  |

### `ship.shipper_account` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `account_no` | `text` | ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `account_type` | `text` | ✱ |  |
| `credit_limit` | `bigint` |  |  |
| `billing_cycle` | `text` |  |  |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `pricing_agreement_id` | `bigint` | 🔗 `ship.pricing_agreement`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `ship.sort_window` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `hub_id` | `bigint` | 🔗 `ship.hub` ✱ |  |
| `direction` | `text` | ✱ |  |
| `starts_at` | `time without time zone` | ✱ |  |
| `ends_at` | `time without time zone` | ✱ |  |
| `cutoff` | `time without time zone` | ✱ |  |

### `ship.surcharge_definition` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `trigger_rule` | `jsonb` | ✱ | `'{}'::jsonb` |
| `calc_method` | `text` | ✱ |  |
| `value` | `numeric(12,4)` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |

### `ship.tracking_event` 🛡️ 🔒

Scans and milestones of a shipment, unit or load; append-only (generalizes shipment_event)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `unit_id` | `bigint` | 🔗 `ship.handling_unit`  |  |
| `load_id` | `bigint` | 🔗 `ship.load`  |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `milestone` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `actor_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `ship.transit_time_matrix` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `origin_zone_id` | `bigint` | 🔑 🔗 `ship.geo_zone` ✱ |  |
| `dest_zone_id` | `bigint` | 🔑 🔗 `ship.geo_zone` ✱ |  |
| `service_id` | `bigint` | 🔑 🔗 `ship.service_product` ✱ |  |
| `transit_days` | `smallint` | ✱ |  |
| `delivery_by_time` | `time without time zone` |  |  |

### `ship.trip_cargo_capacity` 🛡️

Hold capacity of a passenger trip offered to parcels (9.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `max_weight_kg` | `numeric(9,2)` | ✱ |  |
| `max_volume_m3` | `numeric(7,2)` |  |  |
| `max_items` | `integer` |  |  |
| `used_weight_kg` | `numeric(9,2)` | ✱ | `0` |
| `used_volume_m3` | `numeric(7,2)` | ✱ | `0` |
| `used_items` | `integer` | ✱ | `0` |

### `ship.weight_audit` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `parcel_id` | `bigint` | 🔗 `ship.parcel` ✱ |  |
| `measured_weight_kg` | `numeric(9,2)` | ✱ |  |
| `measured_dims_cm` | `integer[]` |  |  |
| `photo_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `device_id` | `bigint` | 🔗 `iam.device`  |  |
| `delta_kg` | `numeric(9,2)` | ✱ |  |
| `adjustment_amount` | `bigint` |  |  |
| `dispute_status` | `text` | ✱ | `'NONE'::text` |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

<a id="frt"></a>
## `frt` — Trucking, heavy transport and transit freight

### `frt.container` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `container_no` | `text` | ✱ |  |
| `size_type` | `text` | ✱ |  |
| `owner_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `tare_kg` | `integer` |  |  |
| `status` | `text` | ✱ | `'EMPTY'::text` |

### `frt.detention_claim` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `frt.freight_contract` ✱ |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `waiting` | `tstzrange` | ✱ |  |
| `free_minutes` | `integer` | ✱ | `120` |
| `rate_per_hour` | `bigint` | ✱ |  |
| `amount` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `frt.escort_assignment` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg` ✱ |  |
| `escort_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `period` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'ASSIGNED'::text` |

### `frt.freight_bid` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `request_id` | `bigint` | 🔗 `frt.freight_request` ✱ |  |
| `carrier_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `truck_vehicle_id` | `bigint` | 🔗 `fleet.truck_unit`  |  |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid_until` | `timestamp with time zone` | ✱ |  |
| `status` | `text` | ✱ | `'SUBMITTED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `frt.freight_claim` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `frt.freight_contract` ✱ |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `claim_type` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `case_id` | `bigint` | 🔗 `crm.case`  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `frt.freight_contract` 🛡️

Contract from an awarded request; it produces one or more legs

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `request_id` | `bigint` | 🔗 `frt.freight_request` ✱ |  |
| `carrier_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `accepted_bid_id` | `bigint` | 🔗 `frt.freight_bid`  |  |
| `terms` | `jsonb` | ✱ |  |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `price_breakdown` | `jsonb` |  |  |
| `advance_pct` | `numeric(5,2)` | ✱ | `0` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `signed_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `frt.freight_document` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `frt.freight_contract`  |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `doc_type` | `text` | ✱ |  |
| `doc_no` | `text` | ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `status` | `text` | ✱ | `'UPLOADED'::text` |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `frt.freight_request` 🛡️

The shipper's request with the cargo data of D.3 (category, description, weight, UN number and hazard class)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `shipper_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `shipper_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `origin_station_id` | `bigint` | 🔗 `net.station`  |  |
| `origin_address_id` | `bigint` | 🔗 `ship.address`  |  |
| `dest_station_id` | `bigint` | 🔗 `net.station`  |  |
| `dest_address_id` | `bigint` | 🔗 `ship.address`  |  |
| `cargo_category` | `text` | 🔗 `ref.cargo_category` ✱ |  |
| `cargo_description` | `text` | ✱ |  |
| `hs_code` | `text` |  |  |
| `declared_weight_kg` | `numeric(10,1)` | ✱ |  |
| `volume_m3` | `numeric(8,2)` |  |  |
| `packages` | `integer` |  |  |
| `container_count` | `smallint` | ✱ | `0` |
| `un_number` | `text` |  |  |
| `adr_class` | `text` |  |  |
| `temp_min_c` | `numeric(4,1)` |  |  |
| `temp_max_c` | `numeric(4,1)` |  |  |
| `required_trailer_type` | `text` |  |  |
| `pickup_window` | `tstzrange` | ✱ |  |
| `delivery_window` | `tstzrange` |  |  |
| `mode` | `text` | ✱ |  |
| `target_price` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `frt.gate_event` 🛡️ 🔒



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `appointment_id` | `bigint` | 🔗 `frt.port_appointment`  |  |
| `port_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `truck_vehicle_id` | `bigint` | 🔗 `fleet.truck_unit` ✱ |  |
| `direction` | `text` | ✱ |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `frt.handover_event` 🛡️ 🔒

Handover between carriers in the yard: seal, weight, documents and both signatures; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg` ✱ |  |
| `next_leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `from_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `to_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `seal_no` | `text` |  |  |
| `weight_kg` | `numeric(10,1)` |  |  |
| `docs_checked` | `boolean` | ✱ | `false` |
| `from_signature_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `to_signature_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `frt.leg_container` 🛡️

Containers carried on a leg, with the seal and gross weight of that leg

| Column | Type | Constraints | Default |
|---|---|---|---|
| `leg_id` | `bigint` | 🔑 🔗 `ship.shipment_leg` ✱ |  |
| `container_id` | `bigint` | 🔑 🔗 `frt.container` ✱ |  |
| `seal_no` | `text` |  |  |
| `gross_weight_kg` | `integer` |  |  |

### `frt.port_appointment` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `port_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `truck_vehicle_id` | `bigint` | 🔗 `fleet.truck_unit` ✱ |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `slot` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'BOOKED'::text` |

### `frt.transit_declaration` 🛡️

Transit across the country on a corridor with a deadline; carries the D.3 cargo data for the authorities

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg` ✱ |  |
| `declaration_no` | `text` | ✱ |  |
| `entry_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `exit_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `corridor_id` | `bigint` | 🔗 `net.corridor`  |  |
| `deadline` | `timestamp with time zone` | ✱ |  |
| `cargo_category` | `text` | 🔗 `ref.cargo_category` ✱ |  |
| `cargo_description` | `text` | ✱ |  |
| `hs_code` | `text` |  |  |
| `declared_weight_kg` | `numeric(10,1)` | ✱ |  |
| `packages` | `integer` |  |  |
| `un_number` | `text` |  |  |
| `adr_class` | `text` |  |  |
| `temp_min_c` | `numeric(4,1)` |  |  |
| `temp_max_c` | `numeric(4,1)` |  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `frt.weighbridge_reading` 🛡️ 🔒

Weighbridge weight compared with the declared weight; a difference raises an alert (10.7, D.3)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `gross_kg` | `integer` | ✱ |  |
| `declared_kg` | `integer` |  |  |
| `alert` | `boolean` | ✱ | `false` |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

<a id="brd"></a>
## `brd` — Border manifest gateway

### `brd.border_point` 🛡️

Border crossing point; extends a station of subtype BORDER (11.6)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `station_id` | `bigint` | 🔑 🔗 `net.station` ✱ |  |
| `point_type` | `text` | ✱ |  |
| `country_code` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `counterpart_station_id` | `bigint` | 🔗 `brd.border_point`  |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile`  |  |
| `hours` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `brd.crossing_profile` 🛡️

What each authority requires at a crossing; changed by configuration, not code

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `border_point_id` | `bigint` | 🔗 `brd.border_point` ✱ |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `required_fields` | `jsonb` | ✱ |  |
| `lead_time_min` | `integer` | ✱ | `60` |
| `schema_version` | `text` | ✱ |  |
| `formats` | `text[]` | ✱ | `'{JSON}'::text[]` |
| `fail_policy` | `text` | ✱ | `'BLOCK'::text` |
| `valid` | `daterange` | ✱ | `daterange(CURRENT_DATE, NULL::date)` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `brd.manifest` 🛡️

Manifest header: a versioned snapshot per trip and border point (11.6)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `crossing_plan_id` | `bigint` | 🔗 `ops.trip_crossing_plan`  |  |
| `border_point_id` | `bigint` | 🔗 `brd.border_point`  |  |
| `profile_id` | `bigint` | 🔗 `brd.crossing_profile`  |  |
| `version` | `integer` | ✱ | `1` |
| `manifest_type` | `text` | ✱ |  |
| `content_type` | `text` | ✱ | `'PASSENGER'::text` |
| `submission_id` | `bigint` | 🔗 `sec.manifest_submission`  |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `closed_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `scope` | `text` | ✱ | `'INTERNATIONAL'::text` |
| `issued_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `issued_at` | `timestamp with time zone` |  |  |
| `payload_sha256` | `bytea` |  |  |
| `persons_count` | `integer` |  |  |
| `supersedes_id` | `bigint` | 🔗 `brd.manifest`  |  |

### `brd.manifest_cargo` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `manifest_id` | `bigint` | 🔗 `brd.manifest` ✱ |  |
| `shipment_id` | `bigint` | 🔗 `ship.shipment`  |  |
| `leg_id` | `bigint` | 🔗 `ship.shipment_leg`  |  |
| `cargo_category` | `text` | 🔗 `ref.cargo_category` ✱ |  |
| `cargo_description` | `text` | ✱ |  |
| `hs_code` | `text` |  |  |
| `declared_weight_kg` | `numeric(10,1)` | ✱ |  |
| `packages` | `integer` |  |  |
| `container_no` | `text` |  |  |
| `seal_no` | `text` |  |  |
| `un_number` | `text` |  |  |
| `adr_class` | `text` |  |  |
| `temp_min_c` | `numeric(4,1)` |  |  |
| `temp_max_c` | `numeric(4,1)` |  |  |

### `brd.manifest_delivery` 🛡️

One delivery of a manifest version to one authority: pushed, offered for pull, or handled by hand; the carrier sees its status (11.10)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `manifest_id` | `bigint` | 🔗 `brd.manifest` ✱ |  |
| `route_id` | `bigint` | 🔗 `brd.manifest_route` ✱ |  |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `channel` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `attempts` | `smallint` | ✱ | `0` |
| `next_attempt_at` | `timestamp with time zone` | ✱ | `now()` |
| `ack_ref` | `text` |  |  |
| `reject_reason` | `text` |  |  |
| `last_error` | `text` |  |  |
| `sent_at` | `timestamp with time zone` |  |  |
| `acknowledged_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `brd.manifest_discrepancy` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `manifest_id` | `bigint` | 🔗 `brd.manifest` ✱ |  |
| `discrepancy_type` | `text` | ✱ |  |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` |  |  |
| `detail` | `jsonb` | ✱ | `'{}'::jsonb` |
| `resolved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `resolved_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `subject_cargo_id` | `bigint` | 🔗 `brd.manifest_cargo`  |  |
| `subject_person_id` | `bigint` | 🔗 `brd.manifest_person`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |

### `brd.manifest_person` 🛡️

Snapshot of a passenger or crew member; transit passengers carry their Syrian entry and exit points (D.1.8)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `manifest_id` | `bigint` | 🔗 `brd.manifest` ✱ |  |
| `person_role` | `text` | ✱ |  |
| `ticket_id` | `bigint` | 🔗 `sales.ticket`  |  |
| `crew_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `doc_type` | `text` |  |  |
| `doc_no_enc` | `bytea` |  |  |
| `doc_no_bidx` | `bytea` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `issuing_country` | `character(2)` | 🔗 `ref.country`  |  |
| `doc_expiry` | `date` |  |  |
| `nationality` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `birth_date` | `date` |  |  |
| `sex` | `character(1)` |  |  |
| `embark_station_id` | `bigint` | 🔗 `net.station`  |  |
| `disembark_station_id` | `bigint` | 🔗 `net.station`  |  |
| `visa_ref` | `text` |  |  |
| `passenger_category` | `text` |  |  |
| `syria_entry_point_id` | `bigint` | 🔗 `brd.border_point`  |  |
| `syria_exit_point_id` | `bigint` | 🔗 `brd.border_point`  |  |
| `full_name` | `text` |  |  |
| `age_category` | `text` |  |  |
| `doc_last4` | `text` |  |  |
| `seat_label` | `text` |  |  |

### `brd.manifest_response` 🛡️ 🔒

Authority decisions per manifest or subject; silent flags are visible to the platform only; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `manifest_id` | `bigint` | 🔗 `brd.manifest` ✱ |  |
| `subject_type` | `text` | ✱ |  |
| `subject_id` | `bigint` |  |  |
| `decision` | `text` | ✱ |  |
| `reason_code` | `text` |  |  |
| `silent_flag` | `boolean` | ✱ | `false` |
| `received_at` | `timestamp with time zone` | ✱ | `now()` |
| `subject_cargo_id` | `bigint` | 🔗 `brd.manifest_cargo`  |  |
| `subject_person_id` | `bigint` | 🔗 `brd.manifest_person`  |  |
| `subject_vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |

### `brd.manifest_route` 🛡️

Which authority receives which manifests and how; activated only by a second platform officer; empty filters match every trip (11.10)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `authority_id` | `bigint` | 🔗 `sec.authority_profile` ✱ |  |
| `scope` | `text` | ✱ |  |
| `content_type` | `text` | ✱ | `'ALL'::text` |
| `manifest_types` | `text[]` | ✱ | `'{PRE_DEPARTURE,FINAL,AMENDMENT,CANCE...` |
| `country_code` | `character(2)` | 🔗 `ref.country`  |  |
| `border_point_id` | `bigint` | 🔗 `brd.border_point`  |  |
| `city_id` | `bigint` | 🔗 `ref.city`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `channel` | `text` | ✱ |  |
| `format` | `text` | ✱ | `'JSON'::text` |
| `include_documents` | `boolean` | ✱ | `false` |
| `legal_basis` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `brd.manifest_vehicle` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `manifest_id` | `bigint` | 🔑 🔗 `brd.manifest` ✱ |  |
| `vehicle_id` | `bigint` | 🔑 🔗 `fleet.vehicle` ✱ |  |
| `trailer_id` | `bigint` | 🔗 `fleet.trailer`  |  |
| `plate_no` | `text` | ✱ |  |
| `plate_country` | `character(2)` | 🔗 `ref.country` ✱ |  |
| `chassis_no` | `text` |  |  |

<a id="ctr"></a>
## `ctr` — Contracted transport: universities and employees

### `ctr.attendance_event` 🛡️

Boarding, alighting, absence and hand-over; append-only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `rider_id` | `bigint` | 🔗 `ctr.contract_rider` ✱ |  |
| `event` | `text` | ✱ |  |
| `received_by_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `occurred_at` | `timestamp with time zone` | ✱ |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `source` | `text` | ✱ |  |

### `ctr.authorized_receiver` 🛡️

People allowed to receive a child at drop-off (D.2.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `rider_id` | `bigint` | 🔑 🔗 `ctr.contract_rider` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `relation` | `text` | ✱ |  |
| `verified_at` | `timestamp with time zone` |  |  |

### `ctr.contract_invoice` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `ctr.service_contract` ✱ |  |
| `period_start` | `date` | ✱ |  |
| `period_end` | `date` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'DRAFT'::text` |

### `ctr.contract_rider` 🛡️

Riders on the contract; minors need guardian consent (D.2.4)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `ctr.service_contract` ✱ |  |
| `passenger_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `guardian_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `pickup_station_id` | `bigint` | 🔗 `net.station`  |  |
| `dropoff_station_id` | `bigint` | 🔗 `net.station`  |  |
| `guardian_consent_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `ctr.contract_route` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `ctr.service_contract` ✱ |  |
| `route_id` | `bigint` | 🔗 `net.route`  |  |
| `direction` | `text` | ✱ |  |
| `operating_days` | `smallint[]` | ✱ | `'{1,2,3,4,5}'::smallint[]` |
| `depart_time` | `time without time zone` | ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `driver_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `attendant_party_id` | `bigint` | 🔗 `iam.party`  |  |

### `ctr.service_contract` 🛡️

Contract between an institution or employer and a carrier (annex D.2.2)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `kind` | `text` | ✱ |  |
| `client_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `client_company_id` | `bigint` | 🔗 `iam.company`  |  |
| `carrier_company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `starts_on` | `date` | ✱ |  |
| `ends_on` | `date` | ✱ |  |
| `pricing_mode` | `text` | ✱ |  |
| `price` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `terms` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

<a id="sch"></a>
## `sch` — School transport: schools, operators, pupils and guardians, contracts, routes, runs and attendance

### `sch.absence_notice` 🛡️

The guardian tells the bus in advance that the pupil will not ride

| Column | Type | Constraints | Default |
|---|---|---|---|
| `enrollment_id` | `bigint` | 🔑 🔗 `sch.enrollment` ✱ |  |
| `absent_on` | `date` | 🔑 ✱ |  |
| `direction` | `text` | 🔑 ✱ |  |
| `reported_by_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `reported_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.attendance` 🛡️ 🔒

Boarding, leaving and hand-over of each pupil on a run; append-only, guardians are notified from it

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `run_id` | `bigint` | 🔗 `sch.run` ✱ |  |
| `enrollment_id` | `bigint` | 🔗 `sch.enrollment` ✱ |  |
| `event` | `text` | ✱ |  |
| `received_by_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `occurred_at` | `timestamp with time zone` | ✱ | `now()` |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `source` | `text` | ✱ |  |
| `recorded_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `sch.contract` 🛡️

A school transport contract: the school assigning its own buses, a guardian with a company or an individual, or a government scheme; always under a school transport licence

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `operator_id` | `bigint` | 🔗 `sch.operator` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `contract_kind` | `text` | ✱ |  |
| `school_id` | `bigint` | 🔗 `sch.school` ✱ |  |
| `guardian_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `school_year` | `text` | ✱ |  |
| `valid` | `daterange` | ✱ |  |
| `pricing_mode` | `text` | ✱ |  |
| `price` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `school_transport_license_no` | `text` | ✱ |  |
| `license_authority` | `text` | ✱ |  |
| `terms` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `signed_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.enrollment` 🛡️

A pupil on a contract, with the morning and afternoon routes and stops, and the guardian's consent

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `sch.contract` ✱ |  |
| `student_id` | `bigint` | 🔗 `sch.student` ✱ |  |
| `to_route_id` | `bigint` | 🔗 `sch.route`  |  |
| `to_stop_seq` | `smallint` |  |  |
| `from_route_id` | `bigint` | 🔗 `sch.route`  |  |
| `from_stop_seq` | `smallint` |  |  |
| `guardian_consent` | `text` | ✱ | `'PENDING'::text` |
| `consent_at` | `timestamp with time zone` |  |  |
| `consent_by_party_id` | `bigint` | 🔗 `iam.party`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.operator` 🛡️

Who carries pupils: the school's own buses, a company, an individual owner-driver, or a government or government-contracted carrier

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `operator_kind` | `text` | ✱ |  |
| `school_id` | `bigint` | 🔗 `sch.school`  |  |
| `government_contract_no` | `text` |  |  |
| `supervising_authority` | `text` |  |  |
| `school_transport_license_no` | `text` | ✱ |  |
| `license_issuer` | `text` | ✱ |  |
| `license_expiry` | `date` |  |  |
| `license_record_id` | `bigint` | 🔗 `fleet.license_record`  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `approved_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.route` 🛡️

A school route with its bus, driver and attendant; activation checks the licences the configuration requires

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `operator_id` | `bigint` | 🔗 `sch.operator` ✱ |  |
| `school_id` | `bigint` | 🔗 `sch.school` ✱ |  |
| `code` | `text` | ✱ |  |
| `direction` | `text` | ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `driver_party_id` | `bigint` | 🔗 `fleet.crew_profile`  |  |
| `attendant_party_id` | `bigint` | 🔗 `fleet.crew_profile`  |  |
| `path` | `jsonb` |  |  |
| `corridor_m` | `integer` | ✱ | `150` |
| `max_ride_min` | `integer` |  |  |
| `depart_time` | `time without time zone` | ✱ |  |
| `operating_days` | `smallint[]` | ✱ | `'{1,2,3,4,7}'::smallint[]` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `path_geo` | `gis.geography` |  | `sys.geo_line(path)` |

### `sch.route_stop` 🛡️

Pick-up and drop-off points of a school route, door to door or at gathering points

| Column | Type | Constraints | Default |
|---|---|---|---|
| `route_id` | `bigint` | 🔑 🔗 `sch.route` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `label` | `text` | ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `lat` | `numeric(9,6)` | ✱ |  |
| `lng` | `numeric(9,6)` | ✱ |  |
| `planned_offset_min` | `integer` | ✱ | `0` |

### `sch.run` 🛡️

One run of a school route on a day; it closes only after the check that no child is left on the bus

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `route_id` | `bigint` | 🔗 `sch.route` ✱ |  |
| `run_date` | `date` | ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `status` | `text` | ✱ | `'PLANNED'::text` |
| `started_at` | `timestamp with time zone` |  |  |
| `completed_at` | `timestamp with time zone` |  |  |
| `sweep_checked_at` | `timestamp with time zone` |  |  |
| `sweep_checked_by` | `bigint` | 🔗 `iam.party`  |  |

### `sch.school` 🛡️

A school on the platform: guardians find it, its staff manage its pupils and, when it owns buses, its transport

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `ministry_code` | `text` |  |  |
| `sector` | `text` | ✱ |  |
| `education_license_no` | `text` |  |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station`  |  |
| `lat` | `numeric(9,6)` |  |  |
| `lng` | `numeric(9,6)` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.student` 🛡️

A pupil of a school; a minor is linked to the guardian's account through the family member the guardian defined

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `school_id` | `bigint` | 🔗 `sch.school` ✱ |  |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `family_member_id` | `bigint` | 🔗 `iam.family_member`  |  |
| `student_no` | `text` |  |  |
| `grade` | `text` |  |  |
| `class_name` | `text` |  |  |
| `medical_note_enc` | `bytea` |  |  |
| `enc_key_id` | `integer` | 🔗 `sec.key_registry`  |  |
| `photo_document_id` | `bigint` | 🔗 `iam.document`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `sch.student_guardian` 🛡️

Guardians and authorised receivers of a pupil, with custody restrictions

| Column | Type | Constraints | Default |
|---|---|---|---|
| `student_id` | `bigint` | 🔑 🔗 `sch.student` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `role` | `text` | ✱ |  |
| `relation` | `text` | ✱ |  |
| `is_primary` | `boolean` | ✱ | `false` |
| `can_receive` | `boolean` | ✱ | `true` |
| `receive_blocked` | `boolean` | ✱ | `false` |
| `verified_at` | `timestamp with time zone` |  |  |
| `verified_by` | `bigint` | 🔗 `iam.app_user`  |  |

<a id="gis"></a>
## `gis` — PostGIS reference data

### `gis.spatial_ref_sys` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `srid` | `integer` | 🔑 ✱ |  |
| `auth_name` | `character varying(256)` |  |  |
| `auth_srid` | `integer` |  |  |
| `srtext` | `character varying(2048)` |  |  |
| `proj4text` | `character varying(2048)` |  |  |

<a id="rail"></a>
## `rail` — Rail extension

### `rail.coach_layout` 🛡️

A coach type built on the seat layout model (4.13)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `code` | `text` | ✱ |  |
| `coach_type` | `text` | ✱ |  |
| `seat_layout_id` | `bigint` | 🔗 `fleet.seat_layout`  |  |
| `berths` | `smallint` |  |  |
| `fare_class_id` | `bigint` | 🔗 `rail.fare_class`  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `rail.fare_class` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `code` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `cabin_rank` | `smallint` | ✱ | `2` |
| `refundable` | `boolean` | ✱ | `true` |
| `changeable` | `boolean` | ✱ | `true` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `rail.journey` 🛡️

Connected journey: several tickets on connecting trips sold and protected as one (phase 10)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `origin_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `dest_station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `status` | `text` | ✱ | `'BOOKED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `rail.journey_leg` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `journey_id` | `bigint` | 🔑 🔗 `rail.journey` ✱ |  |
| `seq` | `smallint` | 🔑 ✱ |  |
| `ticket_id` | `bigint` | 🔗 `sales.ticket` ✱ |  |
| `trip_id` | `bigint` | 🔗 `ops.trip` ✱ |  |
| `min_connection_min` | `smallint` | ✱ | `15` |

### `rail.train_composition` 🛡️

Coaches of a train trip in order; seats are addressed as coach number plus seat

| Column | Type | Constraints | Default |
|---|---|---|---|
| `trip_id` | `bigint` | 🔑 🔗 `ops.trip` ✱ |  |
| `position` | `smallint` | 🔑 ✱ |  |
| `coach_no` | `text` | ✱ |  |
| `coach_layout_id` | `bigint` | 🔗 `rail.coach_layout` ✱ |  |

<a id="taxi"></a>
## `taxi` — Taxis

### `taxi.dispatch_offer` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `request_id` | `bigint` | 🔗 `taxi.ride_request` ✱ |  |
| `shift_id` | `bigint` | 🔗 `taxi.taxi_shift` ✱ |  |
| `distance_m` | `integer` |  |  |
| `offered_at` | `timestamp with time zone` | ✱ | `now()` |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `response` | `text` |  |  |
| `responded_at` | `timestamp with time zone` |  |  |

### `taxi.meter_tariff` 🛡️

Regulated meter tariff per city (4.15, 2.5)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `version` | `integer` | ✱ |  |
| `flag_fall` | `bigint` | ✱ |  |
| `per_km` | `bigint` | ✱ |  |
| `per_wait_min` | `bigint` | ✱ | `0` |
| `night_factor` | `numeric(4,2)` | ✱ | `1.0` |
| `min_fare` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `taxi.ride` 🛡️

A taxi ride from a request or a street hail, metered or at a fixed price

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `request_id` | `bigint` | 🔗 `taxi.ride_request`  |  |
| `shift_id` | `bigint` | 🔗 `taxi.taxi_shift` ✱ |  |
| `rider_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `trip_id` | `bigint` | 🔗 `ops.trip`  |  |
| `tariff_id` | `bigint` | 🔗 `taxi.meter_tariff`  |  |
| `fare_mode` | `text` | ✱ |  |
| `started_at` | `timestamp with time zone` |  |  |
| `ended_at` | `timestamp with time zone` |  |  |
| `distance_km` | `numeric(7,2)` |  |  |
| `wait_min` | `integer` |  |  |
| `fare` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `payment_method` | `text` |  |  |
| `ledger_txn_id` | `bigint` | 🔗 `fin.ledger_txn`  |  |
| `share_token` | `text` |  |  |
| `status` | `text` | ✱ | `'ARRIVING'::text` |

### `taxi.ride_request` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `rider_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `kind` | `text` | ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `pickup_lat` | `numeric(9,6)` | ✱ |  |
| `pickup_lng` | `numeric(9,6)` | ✱ |  |
| `pickup_text` | `text` |  |  |
| `dropoff_lat` | `numeric(9,6)` |  |  |
| `dropoff_lng` | `numeric(9,6)` |  |  |
| `dropoff_text` | `text` |  |  |
| `requested_for` | `timestamp with time zone` | ✱ | `now()` |
| `seats` | `smallint` | ✱ | `1` |
| `fare_estimate` | `bigint` |  |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'SEARCHING'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `taxi.taxi_office` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `license_no` | `text` |  |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

### `taxi.taxi_permit` 🛡️

Taxi licence of a car; ownership and the owner stay on fleet.vehicle (4.17)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `permit_no` | `text` | ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company` ✱ |  |
| `office_id` | `bigint` | 🔗 `taxi.taxi_office`  |  |
| `city_id` | `bigint` | 🔗 `ref.city` ✱ |  |
| `scope` | `text` | ✱ | `'INTRACITY'::text` |
| `gps_required` | `boolean` | ✱ | `false` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `taxi.taxi_shift` 🛡️

A driver on a car for a shift; tracking runs only inside a shift (privacy, 21.1)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `permit_id` | `bigint` | 🔗 `taxi.taxi_permit` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `driver_party_id` | `bigint` | 🔗 `fleet.crew_profile` ✱ |  |
| `period` | `tstzrange` | ✱ |  |
| `status` | `text` | ✱ | `'ON'::text` |

<a id="rent"></a>
## `rent` — Car rental

### `rent.contract_driver` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `contract_id` | `bigint` | 🔑 🔗 `rent.rental_contract` ✱ |  |
| `party_id` | `bigint` | 🔑 🔗 `iam.party` ✱ |  |
| `is_primary` | `boolean` | ✱ | `false` |
| `license_verified` | `boolean` | ✱ | `false` |

### `rent.deposit_hold` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `rent.rental_contract` ✱ |  |
| `method` | `text` | ✱ |  |
| `amount` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `wallet_id` | `bigint` | 🔗 `fin.wallet`  |  |
| `provider_ref` | `text` |  |  |
| `captured_amount` | `bigint` | ✱ | `0` |
| `case_id` | `bigint` | 🔗 `crm.case`  |  |
| `status` | `text` | ✱ | `'HELD'::text` |

### `rent.rental_addon` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `code` | `text` | ✱ |  |
| `price` | `bigint` | ✱ |  |
| `unit` | `text` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `active` | `boolean` | ✱ | `true` |

### `rent.rental_booking` 🛡️

A rental across any company from unified search; a car cannot be double-booked

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `renter_party_id` | `bigint` | 🔗 `iam.party` ✱ |  |
| `rental_class` | `text` | 🔗 `rent.rental_vehicle_class` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `rent.rental_fleet`  |  |
| `rate_id` | `bigint` | 🔗 `rent.rental_rate`  |  |
| `pickup_branch_id` | `bigint` | 🔗 `rent.rental_branch` ✱ |  |
| `return_branch_id` | `bigint` | 🔗 `rent.rental_branch` ✱ |  |
| `period` | `tstzrange` | ✱ |  |
| `quoted_total` | `bigint` | ✱ |  |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `status` | `text` | ✱ | `'CONFIRMED'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `rent.rental_booking_addon` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `booking_id` | `bigint` | 🔑 🔗 `rent.rental_booking` ✱ |  |
| `addon_id` | `bigint` | 🔑 🔗 `rent.rental_addon` ✱ |  |
| `qty` | `smallint` | ✱ | `1` |
| `amount` | `bigint` | ✱ |  |

### `rent.rental_branch` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `station_id` | `bigint` | 🔗 `net.station` ✱ |  |
| `branch_type` | `text` | ✱ |  |
| `hours` | `jsonb` | ✱ | `'{}'::jsonb` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `rent.rental_company` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `company_id` | `bigint` | 🔑 🔗 `iam.company` ✱ |  |
| `brand` | `text` | ✱ |  |
| `status` | `text` | ✱ | `'PENDING'::text` |

### `rent.rental_contract` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_no` | `text` | ✱ |  |
| `booking_id` | `bigint` | 🔗 `rent.rental_booking` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `rent.rental_fleet` ✱ |  |
| `terms` | `jsonb` | ✱ |  |
| `signed_at` | `timestamp with time zone` |  |  |
| `signature_file_id` | `bigint` | 🔗 `ref.file_object`  |  |
| `closed_at` | `timestamp with time zone` |  |  |
| `final_amount` | `bigint` |  |  |
| `status` | `text` | ✱ | `'OPEN'::text` |

### `rent.rental_fleet` 🛡️

Rental extension of fleet.vehicle: its class and home branch

| Column | Type | Constraints | Default |
|---|---|---|---|
| `vehicle_id` | `bigint` | 🔑 🔗 `fleet.vehicle` ✱ |  |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `rental_class` | `text` | 🔗 `rent.rental_vehicle_class` ✱ |  |
| `home_branch_id` | `bigint` | 🔗 `rent.rental_branch`  |  |
| `status` | `text` | ✱ | `'AVAILABLE'::text` |

### `rent.rental_inspection` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `contract_id` | `bigint` | 🔗 `rent.rental_contract` ✱ |  |
| `stage` | `text` | ✱ |  |
| `odometer_km` | `integer` | ✱ |  |
| `fuel_level_pct` | `smallint` | ✱ |  |
| `damage` | `jsonb` | ✱ | `'[]'::jsonb` |
| `photo_file_ids` | `bigint[]` | ✱ | `'{}'::bigint[]` |
| `inspector_user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `renter_confirmed` | `boolean` | ✱ | `false` |
| `ts` | `timestamp with time zone` | ✱ | `now()` |

### `rent.rental_rate` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `rental_class` | `text` | 🔗 `rent.rental_vehicle_class` ✱ |  |
| `branch_id` | `bigint` | 🔗 `rent.rental_branch`  |  |
| `unit` | `text` | ✱ |  |
| `price` | `bigint` | ✱ |  |
| `km_included_per_day` | `integer` |  |  |
| `extra_km_price` | `bigint` | ✱ | `0` |
| `deposit_amount` | `bigint` | ✱ | `0` |
| `currency` | `character(3)` | 🔗 `ref.currency` ✱ | `'SYP'::bpchar` |
| `valid` | `daterange` | ✱ |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `rent.rental_vehicle_class` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `code` | `text` | 🔑 ✱ |  |
| `name` | `text` | ✱ |  |
| `sort` | `integer` | ✱ | `100` |

### `rent.renter_rule` 🛡️

Renter eligibility as data-driven rules: age, licence years and documents (11.9 pattern)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `renter_kind` | `text` | ✱ |  |
| `rental_class` | `text` | 🔗 `rent.rental_vehicle_class`  |  |
| `min_age` | `smallint` | ✱ | `21` |
| `min_license_years` | `smallint` | ✱ | `1` |
| `docs_required` | `text[]` | ✱ |  |
| `version` | `integer` | ✱ | `1` |
| `status` | `text` | ✱ | `'DRAFT'::text` |
| `approved_by` | `bigint` | 🔗 `iam.app_user`  |  |

### `rent.telematics_device` 🛡️



| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `company_id` | `bigint` | 🔗 `rent.rental_company` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle`  |  |
| `imei_hash` | `bytea` | ✱ |  |
| `provider` | `text` | ✱ |  |
| `installed_at` | `timestamp with time zone` |  |  |
| `status` | `text` | ✱ | `'ACTIVE'::text` |

### `rent.vehicle_trip_log` 🛡️

Trips recorded by the telematics device; access limited to the company for safety and recovery (21.2)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `device_id` | `bigint` | 🔗 `rent.telematics_device` ✱ |  |
| `vehicle_id` | `bigint` | 🔗 `fleet.vehicle` ✱ |  |
| `contract_id` | `bigint` | 🔗 `rent.rental_contract`  |  |
| `started_at` | `timestamp with time zone` | ✱ |  |
| `ended_at` | `timestamp with time zone` |  |  |
| `distance_km` | `numeric(8,2)` |  |  |
| `max_speed_kmh` | `smallint` |  |  |
| `geofence_violations` | `integer` | ✱ | `0` |

<a id="rpt"></a>
## `rpt` — Report definitions, runs and schedules

### `rpt.report_definition` 🛡️

Custom report built from a whitelisted dataset; spec holds columns, filters, group_by, totals and sort by column key only

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `owner_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `audience` | `text` | ✱ |  |
| `name` | `text` | ✱ |  |
| `description` | `text` |  |  |
| `dataset` | `text` | ✱ |  |
| `spec` | `jsonb` | ✱ |  |
| `shared` | `boolean` | ✱ | `false` |
| `status` | `text` | ✱ | `'ACTIVE'::text` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `updated_at` | `timestamp with time zone` | ✱ | `now()` |

### `rpt.report_delivery` 🛡️

One link per recipient of a sensitive scheduled report: only a hash of the token is kept; every download is counted and logged (audit T3-05)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `schedule_id` | `bigint` | 🔗 `rpt.report_schedule` ✱ |  |
| `report_run_id` | `bigint` | 🔗 `rpt.report_run` ✱ |  |
| `recipient` | `text` | ✱ |  |
| `recipient_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `file_id` | `bigint` | 🔗 `ref.file_object` ✱ |  |
| `file_name` | `text` | ✱ |  |
| `token_hash` | `bytea` | ✱ |  |
| `expires_at` | `timestamp with time zone` | ✱ |  |
| `first_downloaded_at` | `timestamp with time zone` |  |  |
| `last_downloaded_at` | `timestamp with time zone` |  |  |
| `download_count` | `integer` | ✱ | `0` |
| `revoked_at` | `timestamp with time zone` |  |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `rpt.report_run` 🛡️ 🔒

Every report preview and export: who, which report, parameters, rows and file digest (append-only)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `report_code` | `text` |  |  |
| `definition_id` | `bigint` | 🔗 `rpt.report_definition`  |  |
| `user_id` | `bigint` | 🔗 `iam.app_user`  |  |
| `api_client_id` | `bigint` | 🔗 `iam.api_client`  |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `portal` | `text` | ✱ |  |
| `params` | `jsonb` | ✱ | `'{}'::jsonb` |
| `format` | `text` | ✱ |  |
| `row_count` | `integer` | ✱ |  |
| `sha256` | `bytea` |  |  |
| `duration_ms` | `integer` | ✱ |  |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |

### `rpt.report_schedule` 🛡️

Report delivered by e-mail on a cycle; the outbox worker runs it with the owner's rights

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `uid` | `uuid` | ✱ | `gen_random_uuid()` |
| `report_code` | `text` |  |  |
| `definition_id` | `bigint` | 🔗 `rpt.report_definition`  |  |
| `owner_user_id` | `bigint` | 🔗 `iam.app_user` ✱ |  |
| `company_id` | `bigint` | 🔗 `iam.company`  |  |
| `portal` | `text` | ✱ |  |
| `frequency` | `text` | ✱ |  |
| `format` | `text` | ✱ |  |
| `locale` | `text` | 🔗 `ref.locale` ✱ | `'ar'::text` |
| `recipients` | `text[]` | ✱ |  |
| `params` | `jsonb` | ✱ | `'{}'::jsonb` |
| `next_run_at` | `timestamp with time zone` | ✱ |  |
| `last_run_at` | `timestamp with time zone` |  |  |
| `active` | `boolean` | ✱ | `true` |
| `created_at` | `timestamp with time zone` | ✱ | `now()` |
| `sensitive` | `boolean` | ✱ | `false` |
| `consent_by` | `bigint` | 🔗 `iam.app_user`  |  |
| `consent_at` | `timestamp with time zone` |  |  |

<a id="audit"></a>
## `audit` — Login and activity logs (append-only)

### `audit.activity_log` 🛡️ 🧩 🔒

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

### `audit.auth_event` 🛡️ 🧩 🔒

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

### `audit.data_access_log` 🛡️ 🧩 🔒

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
| `service_name` | `text` |  |  |

### `audit.ddl_event` 🛡️ 🔒

Every schema change (DDL, grants, policies); security-relevant changes outside a migration raise an alert (third-party audit R-09)

| Column | Type | Constraints | Default |
|---|---|---|---|
| `id` | `bigint` | 🔑 ✱ | `identity` |
| `occurred_at` | `timestamp with time zone` | ✱ | `now()` |
| `command_tag` | `text` | ✱ |  |
| `object_type` | `text` |  |  |
| `object_identity` | `text` |  |  |
| `in_migration` | `boolean` | ✱ |  |
| `security_relevant` | `boolean` | ✱ |  |
| `session_user_name` | `text` | ✱ |  |
| `current_user_name` | `text` | ✱ |  |
| `client_addr` | `inet` |  |  |
| `application_name` | `text` |  |  |
| `statement` | `text` |  |  |

### `audit.log_seal` 🛡️ 🔒

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

### `audit.row_change` 🛡️ 🧩 🔒

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
