# Entity-Relationship Diagrams — Masslak Database (Phase 1)

> Generated from the actual foreign keys of the built database. Each diagram shows the module's tables with their key columns,
> plus the tables they reference in other modules (without columns). Solid line = required relationship, dashed = optional.
> For clarity, "who did it" links (created_by, approved_by...) to `iam.app_user` and links to currency, country,
> encryption keys and files are not drawn; they are all listed in the [data dictionary](DATA_DICTIONARY.md).

## Overview: modules and their relationships

```mermaid
flowchart LR
  iam["iam<br/>Identity, parties, users, permissions and API clients"]
  ref["ref<br/>Reference data, locales and files"]
  sys["sys<br/>Settings, outbox and webhooks"]
  net["net<br/>Network: stations, routes and carrier codes"]
  fleet["fleet<br/>Fleet: vehicles, seats, crew, licenses and insurance"]
  pricing["pricing<br/>Pricing, taxes, commissions, campaigns and loyalty"]
  ops["ops<br/>Trips, inventory, operations, tracking and incidents"]
  sales["sales<br/>Channels, bookings, passengers and tickets"]
  fin["fin<br/>Wallets, ledger, payments, allocation and settlement"]
  acct["acct<br/>Simplified accounting, e-invoicing and tax profiles"]
  crm["crm<br/>Complaints, ratings, notifications and the AI assistant"]
  gov["gov<br/>Governance, obligations and data protection"]
  sec["sec<br/>Security: IP rules, risk, signing and the security hub"]
  audit["audit<br/>Login and activity logs (append-only)"]
  acct -->|2| fin
  acct -->|10| iam
  acct -->|2| net
  acct -->|5| pricing
  crm -->|1| fin
  crm -->|9| iam
  crm -->|3| ops
  crm -->|1| ref
  crm -->|3| sales
  fin -->|10| iam
  fin -->|1| ops
  fin -->|5| pricing
  fin -->|2| sales
  fleet -->|15| iam
  fleet -->|1| ops
  gov -->|5| iam
  gov -->|1| sec
  iam -->|1| ref
  net -->|4| iam
  net -->|1| ref
  ops -->|7| fleet
  ops -->|5| iam
  ops -->|5| net
  ops -->|1| sales
  pricing -->|7| iam
  pricing -->|3| net
  pricing -->|1| sales
  sales -->|2| acct
  sales -->|1| fin
  sales -->|9| iam
  sales -->|6| ops
  sales -->|3| pricing
  sec -->|5| iam
  sec -->|3| ops
  sys -->|2| iam
```

## `iam` — Identity, parties, users, permissions and API clients

```mermaid
erDiagram
  iam_api_client {
    bigint id PK
    uuid uid
    bigint owner_party_id FK
    bigint company_id FK
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  iam_api_key {
    bigint id PK
    bigint api_client_id FK
    text status
    bigint created_by FK
    bigint revoked_by FK
  }
  iam_app_user {
    bigint id PK
    uuid uid
    bigint party_id FK
    text status
    text preferred_locale FK
  }
  iam_auth_token {
    bigint id PK
    bigint user_id FK
  }
  iam_bank_account {
    bigint id PK
    bigint party_id FK
    integer enc_key_id FK
    character currency FK
    text status
  }
  iam_beneficial_owner {
    bigint company_id PK
    bigint party_id PK
  }
  iam_biometric_template {
    bigint party_id PK
    integer enc_key_id FK
  }
  iam_company {
    bigint id PK
    bigint approved_by FK
  }
  iam_company_member {
    bigint user_id PK
    bigint company_id PK
    bigint role_id FK
    text status
  }
  iam_device {
    bigint id PK
    bigint user_id FK
  }
  iam_document {
    bigint id PK
    uuid uid
    integer enc_key_id FK
    bigint file_id FK
    text status
    bigint reviewed_by FK
  }
  iam_gov_identity_link {
    bigint party_id PK
    bigint provider_id PK
  }
  iam_identity_provider {
    bigint id PK
    text code
    character country_code FK
    text status
  }
  iam_mfa_factor {
    bigint id PK
    bigint user_id FK
    integer enc_key_id FK
  }
  iam_party {
    bigint id PK
    uuid uid
    integer enc_key_id FK
    character nationality FK
    character country_code FK
    character tax_country FK
    text status
  }
  iam_party_role {
    bigint party_id PK
    text role_code PK
    text status
  }
  iam_permission {
    text code PK
  }
  iam_push_token {
    bigint device_id PK
  }
  iam_role {
    bigint id PK
    text code
    bigint company_id FK
  }
  iam_role_permission {
    bigint role_id PK
    text permission_code PK
  }
  iam_user_role {
    bigint user_id PK
    bigint role_id PK
    bigint granted_by FK
  }
  iam_user_session {
    bigint id PK
    bigint user_id FK
    bigint device_id FK
    bigint company_id FK
  }
  iam_verification {
    bigint id PK
    bigint provider_id FK
    bigint reviewer_id FK
  }
  ref_locale {
    ref external
  }
  iam_api_key }o--|| iam_api_client : "api_client_id"
  iam_user_role }o--|| iam_app_user : "user_id"
  iam_company_member }o--|| iam_app_user : "user_id"
  iam_device }o--|| iam_app_user : "user_id"
  iam_mfa_factor }o--|| iam_app_user : "user_id"
  iam_user_session }o--|| iam_app_user : "user_id"
  iam_auth_token }o..o| iam_app_user : "user_id"
  iam_beneficial_owner }o--|| iam_company : "company_id"
  iam_company_member }o--|| iam_company : "company_id"
  iam_role }o..o| iam_company : "company_id"
  iam_user_session }o..o| iam_company : "company_id"
  iam_api_client }o..o| iam_company : "company_id"
  iam_push_token }o--|| iam_device : "device_id"
  iam_user_session }o..o| iam_device : "device_id"
  iam_gov_identity_link }o--|| iam_identity_provider : "provider_id"
  iam_verification }o..o| iam_identity_provider : "provider_id"
  iam_party_role }o--|| iam_party : "party_id"
  iam_company }o--|| iam_party : "id"
  iam_biometric_template }o--|| iam_party : "party_id"
  iam_gov_identity_link }o--|| iam_party : "party_id"
  iam_beneficial_owner }o--|| iam_party : "party_id"
  iam_bank_account }o--|| iam_party : "party_id"
  iam_app_user }o--|| iam_party : "party_id"
  iam_api_client }o--|| iam_party : "owner_party_id"
  iam_role_permission }o--|| iam_permission : "permission_code"
  iam_role_permission }o--|| iam_role : "role_id"
  iam_user_role }o--|| iam_role : "role_id"
  iam_company_member }o..o| iam_role : "role_id"
  iam_app_user }o--|| ref_locale : "preferred_locale"
```

## `ref` — Reference data, locales and files

```mermaid
erDiagram
  ref_city {
    bigint id PK
    text code
    character country_code FK
  }
  ref_country {
    character code PK
    character default_currency FK
  }
  ref_currency {
    character code PK
  }
  ref_exchange_rate {
    bigint id PK
    character base_currency FK
    character quote_currency FK
  }
  ref_file_object {
    bigint id PK
    uuid uid
    integer enc_key_id FK
    bigint uploaded_by FK
  }
  ref_locale {
    text code PK
  }
  ref_translation {
    bigint id PK
    text locale FK
  }
  ref_translation }o--|| ref_locale : "locale"
```

## `sys` — Settings, outbox and webhooks

```mermaid
erDiagram
  sys_company_setting {
    bigint company_id PK
    text key PK
  }
  sys_outbox_event {
    bigint id PK
    text status
  }
  sys_schema_migration {
    text version PK
  }
  sys_setting {
    text key PK
    bigint updated_by FK
  }
  sys_webhook_delivery {
    bigint id PK
    bigint endpoint_id FK
    bigint outbox_event_id FK
    text status
  }
  sys_webhook_endpoint {
    bigint id PK
    uuid uid
    bigint api_client_id FK
    integer enc_key_id FK
    text status
  }
  iam_api_client {
    ref external
  }
  iam_company {
    ref external
  }
  sys_webhook_endpoint }o..o| iam_api_client : "api_client_id"
  sys_company_setting }o--|| iam_company : "company_id"
  sys_webhook_delivery }o--|| sys_outbox_event : "outbox_event_id"
  sys_webhook_delivery }o--|| sys_webhook_endpoint : "endpoint_id"
```

## `net` — Network: stations, routes and carrier codes

```mermaid
erDiagram
  net_carrier_code {
    bigint id PK
    bigint company_id FK
    text status
    bigint approved_by FK
  }
  net_code_reservation {
    text code PK
  }
  net_compliance_profile {
    bigint id PK
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  net_route {
    bigint id PK
    uuid uid
    bigint company_id FK
    text code
    bigint origin_station_id FK
    bigint dest_station_id FK
    text status
  }
  net_route_stop {
    bigint route_id PK
    smallint seq PK
    bigint station_id FK
  }
  net_service_number {
    bigint id PK
    bigint company_id FK
    integer number
    bigint route_id FK
  }
  net_station {
    bigint id PK
    uuid uid
    text code
    bigint city_id FK
    character country_code FK
    bigint owner_company_id FK
    text status
    bigint compliance_profile_id FK
    bigint verified_by FK
  }
  net_station_contact {
    bigint id PK
    bigint station_id FK
  }
  iam_company {
    ref external
  }
  ref_city {
    ref external
  }
  net_carrier_code }o--|| iam_company : "company_id"
  net_service_number }o--|| iam_company : "company_id"
  net_route }o--|| iam_company : "company_id"
  net_station }o..o| iam_company : "owner_company_id"
  net_station }o..o| net_compliance_profile : "compliance_profile_id"
  net_route_stop }o--|| net_route : "route_id"
  net_service_number }o..o| net_route : "route_id"
  net_station_contact }o--|| net_station : "station_id"
  net_route_stop }o--|| net_station : "station_id"
  net_route }o--|| net_station : "origin_station_id"
  net_route }o--|| net_station : "dest_station_id"
  net_station }o--|| ref_city : "city_id"
```

## `fleet` — Fleet: vehicles, seats, crew, licenses and insurance

```mermaid
erDiagram
  fleet_crew_profile {
    bigint party_id PK
    bigint company_id FK
    text status
  }
  fleet_field_check_log {
    bigint id PK
    bigint inspector_user_id FK
    bigint vehicle_id FK
  }
  fleet_insurance_policy {
    bigint id PK
    bigint vehicle_id FK
    bigint insurer_party_id FK
    bigint license_record_id FK
    bigint document_id FK
    text status
  }
  fleet_license_change_request {
    bigint id PK
    bigint license_record_id FK
    bigint requested_by FK
    bigint document_id FK
    text status
    bigint reviewed_by FK
    bigint approved_by FK
  }
  fleet_license_record {
    bigint id PK
    bigint company_id FK
    bigint document_id FK
    text status
    bigint verified_by FK
    bigint last_change_request_id FK
  }
  fleet_seat_layout {
    bigint id PK
    bigint company_id FK
  }
  fleet_seat_layout_seat {
    bigint layout_id PK
    smallint seat_no PK
  }
  fleet_seat_price_rule {
    bigint id PK
    bigint company_id FK
    bigint vehicle_id FK
    bigint seat_layout_id FK
  }
  fleet_vehicle {
    bigint id PK
    uuid uid
    bigint company_id FK
    character plate_country FK
    bigint seat_layout_id FK
    bigint owner_party_id FK
    text status
  }
  fleet_vehicle_lease {
    bigint id PK
    bigint vehicle_id FK
    bigint owner_party_id FK
    bigint lessee_company_id FK
    bigint document_id FK
    text status
  }
  fleet_vehicle_qr_tag {
    bigint id PK
    bigint vehicle_id FK
  }
  fleet_vehicle_status_history {
    bigint id PK
    bigint vehicle_id FK
    text status
    bigint incident_id FK
    bigint changed_by FK
    bigint release_document_id FK
  }
  iam_company {
    ref external
  }
  iam_document {
    ref external
  }
  iam_party {
    ref external
  }
  ops_incident {
    ref external
  }
  fleet_license_record }o..o| fleet_license_change_request : "last_change_request_id"
  fleet_license_change_request }o--|| fleet_license_record : "license_record_id"
  fleet_insurance_policy }o..o| fleet_license_record : "license_record_id"
  fleet_seat_layout_seat }o--|| fleet_seat_layout : "layout_id"
  fleet_seat_price_rule }o..o| fleet_seat_layout : "seat_layout_id"
  fleet_vehicle }o..o| fleet_seat_layout : "seat_layout_id"
  fleet_vehicle_lease }o--|| fleet_vehicle : "vehicle_id"
  fleet_insurance_policy }o--|| fleet_vehicle : "vehicle_id"
  fleet_vehicle_qr_tag }o--|| fleet_vehicle : "vehicle_id"
  fleet_vehicle_status_history }o--|| fleet_vehicle : "vehicle_id"
  fleet_seat_price_rule }o..o| fleet_vehicle : "vehicle_id"
  fleet_field_check_log }o..o| fleet_vehicle : "vehicle_id"
  fleet_seat_layout }o..o| iam_company : "company_id"
  fleet_seat_price_rule }o--|| iam_company : "company_id"
  fleet_crew_profile }o--|| iam_company : "company_id"
  fleet_license_record }o..o| iam_company : "company_id"
  fleet_vehicle }o--|| iam_company : "company_id"
  fleet_vehicle_lease }o--|| iam_company : "lessee_company_id"
  fleet_license_change_request }o..o| iam_document : "document_id"
  fleet_vehicle_lease }o..o| iam_document : "document_id"
  fleet_vehicle_status_history }o..o| iam_document : "release_document_id"
  fleet_license_record }o..o| iam_document : "document_id"
  fleet_insurance_policy }o..o| iam_document : "document_id"
  fleet_crew_profile }o--|| iam_party : "party_id"
  fleet_vehicle_lease }o--|| iam_party : "owner_party_id"
  fleet_insurance_policy }o..o| iam_party : "insurer_party_id"
  fleet_vehicle }o--|| iam_party : "owner_party_id"
  fleet_vehicle_status_history }o..o| ops_incident : "incident_id"
```

## `pricing` — Pricing, taxes, commissions, campaigns and loyalty

```mermaid
erDiagram
  pricing_allocation_template {
    bigint id PK
    text code
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  pricing_allocation_template_line {
    bigint template_id PK
    text code PK
  }
  pricing_campaign {
    bigint id PK
    uuid uid
    text code
    bigint company_id FK
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  pricing_commission_rule {
    bigint id PK
    bigint scheme_id FK
  }
  pricing_commission_scheme {
    bigint id PK
    text code
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  pricing_fare_brand {
    text code PK
    bigint company_id FK
  }
  pricing_fare_table {
    bigint id PK
    bigint company_id FK
    bigint route_id FK
    character currency FK
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  pricing_fare_table_item {
    bigint fare_table_id PK
    bigint from_station_id PK
    bigint to_station_id PK
    text cabin PK
    text passenger_category PK
  }
  pricing_jurisdiction {
    bigint id PK
    character country_code FK
    bigint parent_id FK
  }
  pricing_loyalty_program {
    bigint id PK
    text code
    character currency FK
    text status
  }
  pricing_loyalty_rule {
    bigint id PK
    bigint program_id FK
  }
  pricing_loyalty_tier {
    bigint id PK
    bigint program_id FK
    text code
  }
  pricing_points_account {
    bigint id PK
    bigint program_id FK
    bigint party_id FK
    bigint tier_id FK
    text status
  }
  pricing_points_ledger {
    bigint id PK
    bigint account_id FK
    bigint booking_id FK
    bigint rule_id FK
    bigint reverses_id FK
  }
  pricing_pricing_modifier {
    bigint id PK
    bigint company_id FK
  }
  pricing_promo_code {
    bigint id PK
    bigint campaign_id FK
    citext code
    bigint owner_party_id FK
  }
  pricing_rate_band {
    bigint id PK
    bigint tax_rule_id FK
    bigint commission_rule_id FK
  }
  pricing_tax_rule {
    bigint id PK
    bigint scheme_id FK
  }
  pricing_tax_scheme {
    bigint id PK
    text code
    bigint jurisdiction_id FK
    bigint payable_to_party_id FK
    text status
    bigint created_by FK
    bigint approved_by FK
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  net_route {
    ref external
  }
  net_station {
    ref external
  }
  sales_booking {
    ref external
  }
  pricing_fare_brand }o..o| iam_company : "company_id"
  pricing_pricing_modifier }o..o| iam_company : "company_id"
  pricing_fare_table }o..o| iam_company : "company_id"
  pricing_campaign }o..o| iam_company : "company_id"
  pricing_points_account }o--|| iam_party : "party_id"
  pricing_promo_code }o..o| iam_party : "owner_party_id"
  pricing_tax_scheme }o..o| iam_party : "payable_to_party_id"
  pricing_fare_table }o..o| net_route : "route_id"
  pricing_fare_table_item }o--|| net_station : "from_station_id"
  pricing_fare_table_item }o--|| net_station : "to_station_id"
  pricing_allocation_template_line }o--|| pricing_allocation_template : "template_id"
  pricing_promo_code }o--|| pricing_campaign : "campaign_id"
  pricing_rate_band }o..o| pricing_commission_rule : "commission_rule_id"
  pricing_commission_rule }o--|| pricing_commission_scheme : "scheme_id"
  pricing_fare_table_item }o--|| pricing_fare_table : "fare_table_id"
  pricing_jurisdiction }o..o| pricing_jurisdiction : "parent_id"
  pricing_tax_scheme }o--|| pricing_jurisdiction : "jurisdiction_id"
  pricing_loyalty_tier }o--|| pricing_loyalty_program : "program_id"
  pricing_loyalty_rule }o--|| pricing_loyalty_program : "program_id"
  pricing_points_account }o--|| pricing_loyalty_program : "program_id"
  pricing_points_ledger }o..o| pricing_loyalty_rule : "rule_id"
  pricing_points_account }o..o| pricing_loyalty_tier : "tier_id"
  pricing_points_ledger }o--|| pricing_points_account : "account_id"
  pricing_points_ledger }o..o| pricing_points_ledger : "reverses_id"
  pricing_rate_band }o..o| pricing_tax_rule : "tax_rule_id"
  pricing_tax_rule }o--|| pricing_tax_scheme : "scheme_id"
  pricing_points_ledger }o..o| sales_booking : "booking_id"
```

## `ops` — Trips, inventory, operations, tracking and incidents

```mermaid
erDiagram
  ops_crew_assignment {
    bigint id PK
    bigint trip_id FK
    bigint party_id FK
    text status
  }
  ops_family_zone {
    bigint trip_id PK
    text label PK
  }
  ops_geo_event {
    bigint id PK
    timestamp_with_time_zone ts PK
  }
  ops_incident {
    bigint id PK
    uuid uid
    bigint company_id FK
    bigint vehicle_id FK
    bigint trip_id FK
    bigint driver_party_id FK
    bigint reported_by FK
    text status
  }
  ops_incident_evidence {
    bigint id PK
    bigint incident_id FK
    bigint file_id FK
    bigint uploaded_by FK
  }
  ops_incident_external_link {
    bigint id PK
    bigint incident_id FK
    text status
  }
  ops_seat_segment {
    bigint trip_id PK
    smallint seat_no PK
    smallint seg PK
    text status
    bigint ticket_id FK
  }
  ops_standing_segment {
    bigint trip_id PK
    smallint seg PK
  }
  ops_tracking_alert {
    bigint id PK
    bigint trip_id FK
    text status
  }
  ops_trip {
    bigint id PK
    uuid uid
    text trip_no
    bigint company_id FK
    bigint service_number_id FK
    bigint template_id FK
    bigint route_id FK
    bigint vehicle_id FK
    text status
    character currency FK
  }
  ops_trip_change {
    bigint id PK
    bigint trip_id FK
    bigint by_user_id FK
  }
  ops_trip_disruption {
    bigint id PK
    bigint trip_id FK
    bigint incident_id FK
    bigint replacement_vehicle_id FK
    bigint partner_company_id FK
    bigint decided_by FK
    text status
  }
  ops_trip_pair_fare {
    bigint trip_id PK
    smallint from_seq PK
    smallint to_seq PK
  }
  ops_trip_stop {
    bigint trip_id PK
    smallint seq PK
    bigint station_id FK
  }
  ops_trip_stop_event {
    bigint id PK
    bigint trip_id FK
    bigint by_user_id FK
  }
  ops_trip_template {
    bigint id PK
    bigint company_id FK
    bigint route_id FK
    bigint service_number_id FK
    bigint default_vehicle_id FK
    character currency FK
    text status
  }
  ops_vehicle_swap {
    bigint id PK
    bigint trip_id FK
    bigint from_vehicle_id FK
    bigint to_vehicle_id FK
    bigint approved_by FK
  }
  fleet_crew_profile {
    ref external
  }
  fleet_vehicle {
    ref external
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  net_route {
    ref external
  }
  net_service_number {
    ref external
  }
  net_station {
    ref external
  }
  sales_ticket {
    ref external
  }
  ops_crew_assignment }o--|| fleet_crew_profile : "party_id"
  ops_vehicle_swap }o--|| fleet_vehicle : "from_vehicle_id"
  ops_vehicle_swap }o--|| fleet_vehicle : "to_vehicle_id"
  ops_incident }o..o| fleet_vehicle : "vehicle_id"
  ops_trip_template }o..o| fleet_vehicle : "default_vehicle_id"
  ops_trip_disruption }o..o| fleet_vehicle : "replacement_vehicle_id"
  ops_trip }o..o| fleet_vehicle : "vehicle_id"
  ops_trip_template }o--|| iam_company : "company_id"
  ops_incident }o--|| iam_company : "company_id"
  ops_trip }o--|| iam_company : "company_id"
  ops_trip_disruption }o..o| iam_company : "partner_company_id"
  ops_incident }o..o| iam_party : "driver_party_id"
  ops_trip_template }o--|| net_route : "route_id"
  ops_trip }o--|| net_route : "route_id"
  ops_trip_template }o..o| net_service_number : "service_number_id"
  ops_trip }o..o| net_service_number : "service_number_id"
  ops_trip_stop }o--|| net_station : "station_id"
  ops_incident_evidence }o--|| ops_incident : "incident_id"
  ops_incident_external_link }o--|| ops_incident : "incident_id"
  ops_trip_disruption }o..o| ops_incident : "incident_id"
  ops_trip_stop }o--|| ops_trip : "trip_id"
  ops_trip_pair_fare }o--|| ops_trip : "trip_id"
  ops_seat_segment }o--|| ops_trip : "trip_id"
  ops_standing_segment }o--|| ops_trip : "trip_id"
  ops_family_zone }o--|| ops_trip : "trip_id"
  ops_crew_assignment }o--|| ops_trip : "trip_id"
  ops_trip_stop_event }o--|| ops_trip : "trip_id"
  ops_trip_change }o--|| ops_trip : "trip_id"
  ops_vehicle_swap }o--|| ops_trip : "trip_id"
  ops_tracking_alert }o--|| ops_trip : "trip_id"
  ops_trip_disruption }o--|| ops_trip : "trip_id"
  ops_incident }o..o| ops_trip : "trip_id"
  ops_trip_stop_event }o--|| ops_trip_stop : "trip_id,seq"
  ops_trip }o..o| ops_trip_template : "template_id"
  ops_seat_segment }o..o| sales_ticket : "ticket_id"
```

## `sales` — Channels, bookings, passengers and tickets

```mermaid
erDiagram
  sales_boarding_event {
    bigint id PK
    bigint ticket_id FK
    bigint trip_id FK
    bigint scanned_by_user_id FK
    bigint device_id FK
  }
  sales_booking {
    bigint id PK
    uuid uid
    text booking_ref
    bigint trip_id FK
    bigint company_id FK
    bigint booker_party_id FK
    bigint booker_user_id FK
    bigint channel_id FK
    text status
    character currency FK
    bigint price_allocation_id FK
  }
  sales_campaign_redemption {
    bigint id PK
    bigint campaign_id FK
    bigint promo_code_id FK
    bigint booking_id FK
    bigint party_id FK
  }
  sales_channel {
    bigint id PK
    uuid uid
    text code
    bigint party_id FK
    bigint api_client_id FK
    text status
  }
  sales_passenger {
    bigint id PK
    bigint booking_id FK
    bigint party_id FK
    character passport_country FK
    integer enc_key_id FK
    character nationality FK
  }
  sales_passenger_compensation {
    bigint id PK
    bigint booking_id FK
    bigint trip_disruption_id FK
    bigint charged_to_company_id FK
    bigint credit_note_id FK
    text status
  }
  sales_refund_request {
    bigint id PK
    bigint booking_id FK
    bigint ticket_id FK
    text status
    bigint requested_by FK
    bigint decided_by FK
    bigint credit_note_id FK
  }
  sales_ticket {
    bigint id PK
    uuid uid
    bigint booking_id FK
    bigint passenger_id FK
    bigint trip_id FK
    text fare_brand_code FK
    integer qr_key_id FK
    text status
  }
  acct_einvoice_document {
    ref external
  }
  fin_price_allocation {
    ref external
  }
  iam_api_client {
    ref external
  }
  iam_app_user {
    ref external
  }
  iam_company {
    ref external
  }
  iam_device {
    ref external
  }
  iam_party {
    ref external
  }
  ops_trip {
    ref external
  }
  ops_trip_disruption {
    ref external
  }
  ops_trip_stop {
    ref external
  }
  pricing_campaign {
    ref external
  }
  pricing_fare_brand {
    ref external
  }
  pricing_promo_code {
    ref external
  }
  sales_passenger_compensation }o..o| acct_einvoice_document : "credit_note_id"
  sales_refund_request }o..o| acct_einvoice_document : "credit_note_id"
  sales_booking }o..o| fin_price_allocation : "price_allocation_id"
  sales_channel }o..o| iam_api_client : "api_client_id"
  sales_booking }o..o| iam_app_user : "booker_user_id"
  sales_booking }o--|| iam_company : "company_id"
  sales_passenger_compensation }o..o| iam_company : "charged_to_company_id"
  sales_boarding_event }o..o| iam_device : "device_id"
  sales_passenger }o..o| iam_party : "party_id"
  sales_channel }o..o| iam_party : "party_id"
  sales_campaign_redemption }o--|| iam_party : "party_id"
  sales_booking }o--|| iam_party : "booker_party_id"
  sales_boarding_event }o--|| ops_trip : "trip_id"
  sales_booking }o--|| ops_trip : "trip_id"
  sales_ticket }o--|| ops_trip : "trip_id"
  sales_passenger_compensation }o..o| ops_trip_disruption : "trip_disruption_id"
  sales_ticket }o--|| ops_trip_stop : "trip_id,from_seq"
  sales_ticket }o--|| ops_trip_stop : "trip_id,to_seq"
  sales_campaign_redemption }o--|| pricing_campaign : "campaign_id"
  sales_ticket }o..o| pricing_fare_brand : "fare_brand_code"
  sales_campaign_redemption }o..o| pricing_promo_code : "promo_code_id"
  sales_passenger }o--|| sales_booking : "booking_id"
  sales_refund_request }o--|| sales_booking : "booking_id"
  sales_passenger_compensation }o--|| sales_booking : "booking_id"
  sales_ticket }o--|| sales_booking : "booking_id"
  sales_campaign_redemption }o--|| sales_booking : "booking_id"
  sales_booking }o--|| sales_channel : "channel_id"
  sales_ticket }o--|| sales_passenger : "passenger_id"
  sales_boarding_event }o--|| sales_ticket : "ticket_id"
  sales_refund_request }o..o| sales_ticket : "ticket_id"
```

## `fin` — Wallets, ledger, payments, allocation and settlement

```mermaid
erDiagram
  fin_bank_reconciliation {
    bigint id PK
    character currency FK
    text status
    bigint reviewed_by FK
  }
  fin_bank_transfer_topup {
    bigint id PK
    bigint wallet_id FK
    text status
    bigint ledger_txn_id FK
  }
  fin_ledger_entry {
    bigint id PK
    bigint txn_id FK
    bigint wallet_id FK
  }
  fin_ledger_txn {
    bigint id PK
    uuid uid
    character currency FK
    bigint reverses_txn_id FK
    bigint created_by FK
  }
  fin_payment {
    bigint id PK
    uuid uid
    bigint provider_id FK
    bigint booking_id FK
    bigint payer_party_id FK
    bigint wallet_id FK
    character currency FK
    text status
    bigint ledger_txn_id FK
  }
  fin_payment_notification {
    bigint id PK
    bigint provider_id FK
    bigint payment_id FK
  }
  fin_payment_provider {
    bigint id PK
    text code
    bigint clearing_wallet_id FK
    text status
  }
  fin_payout {
    bigint id PK
    uuid uid
    bigint company_id FK
    bigint settlement_batch_id FK
    bigint bank_account_id FK
    character currency FK
    text status
    bigint ledger_txn_id FK
  }
  fin_payout_schedule {
    bigint company_id PK
    text status
  }
  fin_price_allocation {
    bigint id PK
    uuid uid
    bigint booking_id FK
    character currency FK
    bigint template_id FK
  }
  fin_price_allocation_line {
    bigint id PK
    bigint allocation_id FK
    text code
    bigint parent_line_id FK
    bigint beneficiary_party_id FK
    bigint tax_scheme_id FK
    bigint commission_scheme_id FK
    bigint wallet_id FK
    text status
  }
  fin_settlement_batch {
    bigint id PK
    uuid uid
    bigint company_id FK
    character currency FK
    text status
    bigint approved_by FK
  }
  fin_settlement_line {
    bigint id PK
    bigint batch_id FK
    bigint trip_id FK
  }
  fin_tax_ledger {
    bigint id PK
    bigint jurisdiction_id FK
    bigint tax_scheme_id FK
    bigint company_id FK
    character currency FK
    bigint allocation_line_id FK
  }
  fin_wallet {
    bigint id PK
    uuid uid
    bigint owner_party_id FK
    bigint company_id FK
    character currency FK
    text status
  }
  fin_withdrawal_request {
    bigint id PK
    bigint wallet_id FK
    bigint bank_account_id FK
    text status
    bigint requested_by FK
    bigint approved_by FK
    bigint second_approver FK
    bigint ledger_txn_id FK
  }
  iam_bank_account {
    ref external
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  ops_trip {
    ref external
  }
  pricing_allocation_template {
    ref external
  }
  pricing_commission_scheme {
    ref external
  }
  pricing_jurisdiction {
    ref external
  }
  pricing_tax_scheme {
    ref external
  }
  sales_booking {
    ref external
  }
  fin_ledger_entry }o--|| fin_ledger_txn : "txn_id"
  fin_bank_transfer_topup }o..o| fin_ledger_txn : "ledger_txn_id"
  fin_ledger_txn }o..o| fin_ledger_txn : "reverses_txn_id"
  fin_withdrawal_request }o..o| fin_ledger_txn : "ledger_txn_id"
  fin_payout }o..o| fin_ledger_txn : "ledger_txn_id"
  fin_payment }o..o| fin_ledger_txn : "ledger_txn_id"
  fin_payment_notification }o..o| fin_payment : "payment_id"
  fin_payment_notification }o--|| fin_payment_provider : "provider_id"
  fin_payment }o--|| fin_payment_provider : "provider_id"
  fin_price_allocation_line }o--|| fin_price_allocation : "allocation_id"
  fin_price_allocation_line }o..o| fin_price_allocation_line : "parent_line_id"
  fin_tax_ledger }o..o| fin_price_allocation_line : "allocation_line_id"
  fin_settlement_line }o--|| fin_settlement_batch : "batch_id"
  fin_payout }o..o| fin_settlement_batch : "settlement_batch_id"
  fin_bank_transfer_topup }o--|| fin_wallet : "wallet_id"
  fin_withdrawal_request }o--|| fin_wallet : "wallet_id"
  fin_ledger_entry }o--|| fin_wallet : "wallet_id"
  fin_payment_provider }o..o| fin_wallet : "clearing_wallet_id"
  fin_payment }o..o| fin_wallet : "wallet_id"
  fin_price_allocation_line }o..o| fin_wallet : "wallet_id"
  fin_withdrawal_request }o--|| iam_bank_account : "bank_account_id"
  fin_payout }o..o| iam_bank_account : "bank_account_id"
  fin_payout_schedule }o--|| iam_company : "company_id"
  fin_settlement_batch }o--|| iam_company : "company_id"
  fin_payout }o--|| iam_company : "company_id"
  fin_wallet }o..o| iam_company : "company_id"
  fin_tax_ledger }o..o| iam_company : "company_id"
  fin_wallet }o..o| iam_party : "owner_party_id"
  fin_payment }o--|| iam_party : "payer_party_id"
  fin_price_allocation_line }o..o| iam_party : "beneficiary_party_id"
  fin_settlement_line }o..o| ops_trip : "trip_id"
  fin_price_allocation }o..o| pricing_allocation_template : "template_id"
  fin_price_allocation_line }o..o| pricing_commission_scheme : "commission_scheme_id"
  fin_tax_ledger }o--|| pricing_jurisdiction : "jurisdiction_id"
  fin_tax_ledger }o--|| pricing_tax_scheme : "tax_scheme_id"
  fin_price_allocation_line }o..o| pricing_tax_scheme : "tax_scheme_id"
  fin_payment }o..o| sales_booking : "booking_id"
  fin_price_allocation }o..o| sales_booking : "booking_id"
```

## `acct` — Simplified accounting, e-invoicing and tax profiles

```mermaid
erDiagram
  acct_account_mapping {
    bigint connection_id PK
    text local_type PK
    bigint local_id PK
  }
  acct_accounting_connection {
    bigint id PK
    bigint company_id FK
    text status
  }
  acct_cost_center {
    bigint id PK
    bigint company_id FK
    text code
    bigint route_id FK
    bigint station_id FK
  }
  acct_einvoice_activation {
    bigint id PK
    bigint authority_id FK
  }
  acct_einvoice_document {
    bigint id PK
    bigint seller_profile_id FK
    bigint unit_id FK
    bigint company_id FK
    bigint buyer_party_id FK
    bigint original_doc_id FK
    character currency FK
    text number
    bigint xml_file_id FK
    bigint pdf_file_id FK
    text status
  }
  acct_einvoice_line {
    bigint id PK
    bigint document_id FK
    bigint tax_scheme_id FK
    bigint allocation_line_id FK
  }
  acct_einvoice_submission {
    bigint id PK
    bigint document_id FK
    bigint stamped_xml_file_id FK
  }
  acct_einvoice_template {
    bigint id PK
    bigint authority_id FK
  }
  acct_einvoice_unit {
    bigint id PK
    bigint profile_id FK
    bigint authority_id FK
    integer signing_key_id FK
    text status
  }
  acct_gl_account {
    bigint id PK
    bigint company_id FK
    text code
    bigint parent_id FK
    character currency FK
  }
  acct_gl_period {
    bigint company_id FK
    text status
    bigint closed_by FK
  }
  acct_journal_entry {
    bigint id PK
    uuid uid
    bigint company_id FK
    bigint posting_rule_id FK
    character currency FK
    text status
    bigint reversed_by_id FK
    bigint created_by FK
  }
  acct_journal_line {
    bigint id PK
    bigint entry_id FK
    bigint account_id FK
    bigint party_id FK
    bigint cost_center_id FK
  }
  acct_posting_rule {
    bigint id PK
    bigint created_by FK
    bigint approved_by FK
  }
  acct_sync_item {
    bigint id PK
    bigint connection_id FK
    text status
  }
  acct_tax_authority {
    bigint id PK
    text code
    character country_code FK
    text status
  }
  acct_tax_collection_no_file {
    bigint id PK
    bigint payer_party_id FK
    bigint tax_scheme_id FK
    character currency FK
    bigint remitted_payment_id FK
  }
  acct_tax_payment {
    bigint id PK
    bigint profile_id FK
    bigint authority_id FK
    bigint tax_return_id FK
    bigint tax_scheme_id FK
    character currency FK
    bigint ledger_txn_id FK
  }
  acct_tax_profile {
    bigint id PK
    bigint party_id FK
    bigint authority_id FK
    bigint approved_by FK
  }
  acct_tax_profile_field {
    bigint id PK
    character country_code FK
    bigint authority_id FK
    text code
  }
  acct_tax_profile_value {
    bigint profile_id PK
    bigint field_id PK
  }
  acct_tax_registration {
    bigint id PK
    bigint profile_id FK
    bigint tax_scheme_id FK
  }
  acct_tax_return {
    bigint id PK
    bigint profile_id FK
    bigint authority_id FK
    bigint tax_scheme_id FK
    text status
  }
  acct_tax_return_line {
    bigint return_id PK
    text box_code PK
  }
  fin_ledger_txn {
    ref external
  }
  fin_price_allocation_line {
    ref external
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  net_route {
    ref external
  }
  net_station {
    ref external
  }
  pricing_tax_scheme {
    ref external
  }
  acct_account_mapping }o--|| acct_accounting_connection : "connection_id"
  acct_sync_item }o--|| acct_accounting_connection : "connection_id"
  acct_journal_line }o..o| acct_cost_center : "cost_center_id"
  acct_einvoice_line }o--|| acct_einvoice_document : "document_id"
  acct_einvoice_submission }o--|| acct_einvoice_document : "document_id"
  acct_einvoice_document }o..o| acct_einvoice_document : "original_doc_id"
  acct_einvoice_document }o--|| acct_einvoice_unit : "unit_id"
  acct_journal_line }o--|| acct_gl_account : "account_id"
  acct_gl_account }o..o| acct_gl_account : "parent_id"
  acct_journal_line }o--|| acct_journal_entry : "entry_id"
  acct_journal_entry }o..o| acct_journal_entry : "reversed_by_id"
  acct_journal_entry }o..o| acct_posting_rule : "posting_rule_id"
  acct_einvoice_template }o--|| acct_tax_authority : "authority_id"
  acct_einvoice_activation }o--|| acct_tax_authority : "authority_id"
  acct_tax_profile }o..o| acct_tax_authority : "authority_id"
  acct_tax_profile_field }o..o| acct_tax_authority : "authority_id"
  acct_einvoice_unit }o--|| acct_tax_authority : "authority_id"
  acct_tax_return }o--|| acct_tax_authority : "authority_id"
  acct_tax_payment }o--|| acct_tax_authority : "authority_id"
  acct_tax_collection_no_file }o..o| acct_tax_payment : "remitted_payment_id"
  acct_tax_profile_value }o--|| acct_tax_profile : "profile_id"
  acct_tax_registration }o--|| acct_tax_profile : "profile_id"
  acct_einvoice_unit }o--|| acct_tax_profile : "profile_id"
  acct_tax_return }o--|| acct_tax_profile : "profile_id"
  acct_tax_payment }o..o| acct_tax_profile : "profile_id"
  acct_einvoice_document }o--|| acct_tax_profile : "seller_profile_id"
  acct_tax_profile_value }o--|| acct_tax_profile_field : "field_id"
  acct_tax_return_line }o--|| acct_tax_return : "return_id"
  acct_tax_payment }o..o| acct_tax_return : "tax_return_id"
  acct_tax_payment }o..o| fin_ledger_txn : "ledger_txn_id"
  acct_einvoice_line }o..o| fin_price_allocation_line : "allocation_line_id"
  acct_gl_period }o..o| iam_company : "company_id"
  acct_gl_account }o..o| iam_company : "company_id"
  acct_cost_center }o..o| iam_company : "company_id"
  acct_accounting_connection }o..o| iam_company : "company_id"
  acct_journal_entry }o..o| iam_company : "company_id"
  acct_einvoice_document }o..o| iam_company : "company_id"
  acct_tax_profile }o--|| iam_party : "party_id"
  acct_tax_collection_no_file }o--|| iam_party : "payer_party_id"
  acct_journal_line }o..o| iam_party : "party_id"
  acct_einvoice_document }o..o| iam_party : "buyer_party_id"
  acct_cost_center }o..o| net_route : "route_id"
  acct_cost_center }o..o| net_station : "station_id"
  acct_tax_registration }o--|| pricing_tax_scheme : "tax_scheme_id"
  acct_tax_collection_no_file }o--|| pricing_tax_scheme : "tax_scheme_id"
  acct_tax_return }o--|| pricing_tax_scheme : "tax_scheme_id"
  acct_tax_payment }o--|| pricing_tax_scheme : "tax_scheme_id"
  acct_einvoice_line }o..o| pricing_tax_scheme : "tax_scheme_id"
```

## `crm` — Complaints, ratings, notifications and the AI assistant

```mermaid
erDiagram
  crm_ai_conversation {
    bigint id PK
    uuid uid
    bigint party_id FK
    bigint company_id FK
    bigint escalated_case_id FK
  }
  crm_ai_message {
    bigint id PK
    bigint conversation_id FK
  }
  crm_ai_policy {
    text tool PK
  }
  crm_ai_tool_call {
    bigint id PK
    bigint conversation_id FK
    text tool FK
  }
  crm_case {
    bigint id PK
    uuid uid
    text status
    bigint party_id FK
    bigint booking_id FK
    bigint trip_id FK
    bigint company_id FK
    bigint assigned_to FK
    bigint payout_ledger_txn_id FK
  }
  crm_case_event {
    bigint id PK
    bigint case_id FK
    bigint actor_id FK
    bigint file_id FK
  }
  crm_notification {
    bigint id PK
    bigint user_id FK
    bigint party_id FK
    bigint trip_id FK
    bigint booking_id FK
    text status
    bigint charged_company_id FK
  }
  crm_notification_template {
    text code PK
    text channel PK
    text locale PK
    bigint approved_by FK
  }
  crm_trip_rating {
    bigint id PK
    bigint ticket_id FK
    bigint trip_id FK
    bigint company_id FK
    bigint party_id FK
  }
  fin_ledger_txn {
    ref external
  }
  iam_app_user {
    ref external
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  ops_trip {
    ref external
  }
  ref_locale {
    ref external
  }
  sales_booking {
    ref external
  }
  sales_ticket {
    ref external
  }
  crm_ai_message }o--|| crm_ai_conversation : "conversation_id"
  crm_ai_tool_call }o--|| crm_ai_conversation : "conversation_id"
  crm_ai_tool_call }o--|| crm_ai_policy : "tool"
  crm_case_event }o--|| crm_case : "case_id"
  crm_ai_conversation }o..o| crm_case : "escalated_case_id"
  crm_case }o..o| fin_ledger_txn : "payout_ledger_txn_id"
  crm_notification }o..o| iam_app_user : "user_id"
  crm_trip_rating }o--|| iam_company : "company_id"
  crm_ai_conversation }o..o| iam_company : "company_id"
  crm_notification }o..o| iam_company : "charged_company_id"
  crm_case }o..o| iam_company : "company_id"
  crm_notification }o..o| iam_party : "party_id"
  crm_ai_conversation }o..o| iam_party : "party_id"
  crm_trip_rating }o--|| iam_party : "party_id"
  crm_case }o..o| iam_party : "party_id"
  crm_trip_rating }o--|| ops_trip : "trip_id"
  crm_notification }o..o| ops_trip : "trip_id"
  crm_case }o..o| ops_trip : "trip_id"
  crm_notification_template }o--|| ref_locale : "locale"
  crm_notification }o..o| sales_booking : "booking_id"
  crm_case }o..o| sales_booking : "booking_id"
  crm_trip_rating }o--|| sales_ticket : "ticket_id"
```

## `gov` — Governance, obligations and data protection

```mermaid
erDiagram
  gov_consent {
    bigint id PK
    bigint party_id FK
  }
  gov_data_inventory {
    text dataset PK
  }
  gov_feature_compliance_review {
    bigint id PK
    bigint dpia_file_id FK
    bigint approved_by FK
  }
  gov_obligation_register {
    bigint id PK
    bigint evidence_file_id FK
    bigint owner_user_id FK
    text status
  }
  gov_partner_dpa {
    bigint id PK
    bigint partner_party_id FK
    bigint file_id FK
  }
  gov_policy_authority {
    bigint id PK
    text domain_code FK
    text status
  }
  gov_policy_change {
    bigint id PK
    text domain_code FK
    bigint company_id FK
    bigint proposer_id FK
    text status
  }
  gov_policy_domain {
    text code PK
  }
  gov_privacy_incident {
    bigint id PK
    text status
    bigint security_event_id FK
  }
  gov_subject_request {
    bigint id PK
    bigint party_id FK
    text status
    bigint handled_by FK
  }
  iam_app_user {
    ref external
  }
  iam_company {
    ref external
  }
  iam_party {
    ref external
  }
  sec_security_event {
    ref external
  }
  gov_policy_authority }o--|| gov_policy_domain : "domain_code"
  gov_policy_change }o--|| gov_policy_domain : "domain_code"
  gov_policy_change }o--|| iam_app_user : "proposer_id"
  gov_policy_change }o..o| iam_company : "company_id"
  gov_partner_dpa }o--|| iam_party : "partner_party_id"
  gov_consent }o--|| iam_party : "party_id"
  gov_subject_request }o--|| iam_party : "party_id"
  gov_privacy_incident }o..o| sec_security_event : "security_event_id"
```

## `sec` — Security: IP rules, risk, signing and the security hub

```mermaid
erDiagram
  sec_access_review {
    bigint id PK
    bigint user_id FK
    bigint role_id FK
    bigint reviewer_id FK
  }
  sec_authority_data_request {
    bigint id PK
    bigint authority_id FK
    bigint requested_by FK
    bigint approved_by FK
    text status
  }
  sec_authority_order {
    bigint id PK
    bigint authority_id FK
    text status
    bigint executed_by FK
  }
  sec_authority_policy {
    bigint id PK
    bigint authority_id FK
  }
  sec_authority_profile {
    bigint id PK
    text code
  }
  sec_blocklist_entry {
    bigint id PK
    bigint added_by FK
  }
  sec_break_glass_log {
    bigint id PK
    bigint actor_id FK
    bigint approver_id FK
  }
  sec_document_signature {
    bigint id PK
    integer key_id FK
    bigint file_id FK
  }
  sec_fraud_case {
    bigint id PK
    text status
    bigint assigned_to FK
  }
  sec_ip_rule {
    bigint id PK
    bigint api_client_id FK
    bigint created_by FK
    bigint approved_by FK
    bigint revoked_by FK
  }
  sec_key_registry {
    integer id PK
    bigint company_id FK
    text status
  }
  sec_manifest_submission {
    bigint id PK
    bigint trip_id FK
    bigint authority_id FK
    bigint payload_file_id FK
    text status
    bigint created_by FK
  }
  sec_risk_assessment {
    bigint id PK
  }
  sec_screening_request {
    bigint id PK
    bigint authority_id FK
    text status
  }
  sec_screening_result {
    bigint request_id PK
    bigint reviewed_by FK
  }
  sec_security_event {
    bigint id PK
    bigint ip_rule_id FK
  }
  sec_sos_event {
    bigint id PK
    bigint trip_id FK
    bigint triggered_by FK
    text status
    bigint incident_id FK
  }
  sec_tamper_event {
    bigint id PK
  }
  sec_watchlist_entry {
    bigint id PK
    bigint authority_id FK
    text status
    bigint created_by FK
  }
  iam_api_client {
    ref external
  }
  iam_app_user {
    ref external
  }
  iam_company {
    ref external
  }
  iam_role {
    ref external
  }
  ops_incident {
    ref external
  }
  ops_trip {
    ref external
  }
  sec_ip_rule }o..o| iam_api_client : "api_client_id"
  sec_access_review }o--|| iam_app_user : "user_id"
  sec_sos_event }o..o| iam_app_user : "triggered_by"
  sec_key_registry }o..o| iam_company : "company_id"
  sec_access_review }o..o| iam_role : "role_id"
  sec_sos_event }o..o| ops_incident : "incident_id"
  sec_manifest_submission }o--|| ops_trip : "trip_id"
  sec_sos_event }o..o| ops_trip : "trip_id"
  sec_authority_policy }o--|| sec_authority_profile : "authority_id"
  sec_screening_request }o--|| sec_authority_profile : "authority_id"
  sec_watchlist_entry }o..o| sec_authority_profile : "authority_id"
  sec_authority_order }o--|| sec_authority_profile : "authority_id"
  sec_authority_data_request }o--|| sec_authority_profile : "authority_id"
  sec_manifest_submission }o..o| sec_authority_profile : "authority_id"
  sec_security_event }o..o| sec_ip_rule : "ip_rule_id"
  sec_screening_result }o--|| sec_screening_request : "request_id"
```

## `audit` — Login and activity logs (append-only)

```mermaid
erDiagram
  audit_activity_log {
    bigint id PK
    timestamp_with_time_zone ts PK
  }
  audit_auth_event {
    bigint id PK
    timestamp_with_time_zone ts PK
  }
  audit_data_access_log {
    bigint id PK
    timestamp_with_time_zone ts PK
  }
  audit_log_seal {
    bigint id PK
    integer key_id FK
  }
  audit_row_change {
    bigint id PK
    timestamp_with_time_zone ts PK
  }
```
