"""Diagram groups of the database design document: every table of the model belongs to exactly one ERD.

Each group lists its tables; the colour family follows the study's diagrams (section 4.1): core in blue, assets and
network in green, trips in yellow, pricing and money in lavender, booking in peach, security and borders in orange.
"""

# Colour families taken from the study's own diagrams and tables
NAVY = "#1F3A5F"        # table header fill in the study
BLUE = "#2E74B5"        # heading colour in the study
GRID = "#B7C3D0"        # table border colour in the study
ROW_ALT = "#F2F6FA"     # alternate row fill in the study
INK = "#404040"         # box outline in the study diagrams
EDGE = "#595959"
FAMILY = {
    "core":     {"fill": "#DCE6F2", "band": "#2E74B5"},   # identity and parties
    "asset":    {"fill": "#E2EFDA", "band": "#548235"},   # fleet and network
    "trip":     {"fill": "#FFF2CC", "band": "#BF8F00"},   # trips and inventory
    "money":    {"fill": "#E4DFEC", "band": "#7030A0"},   # pricing, wallet, accounting
    "booking":  {"fill": "#FCE4D6", "band": "#C55A11"},   # booking and channels
    "security": {"fill": "#F8CBAD", "band": "#B03A2E"},   # security, borders, audit
    "service":  {"fill": "#DDEBF7", "band": "#0E7C86"},   # partners, contact center, later phases
}
SCHEMA_FAMILY = {
    "iam": "core", "ref": "core", "sys": "core",
    "net": "asset", "fleet": "asset",
    "ops": "trip", "ctr": "trip", "rail": "trip", "taxi": "trip", "rent": "trip",
    "pricing": "money", "fin": "money", "acct": "money", "bill": "money",
    "sales": "booking", "crm": "service", "ptn": "service",
    "ship": "asset", "frt": "trip",
    "sec": "security", "brd": "security", "gov": "security", "audit": "security",
}

# (id, title, study sections, family, description, tables)
GROUPS = [
    ("E01", "Identity, parties and companies", "4.2, 3.6", "core",
     "A party is a person, company or entity; a company is a party acting as a tenant. Roles, memberships, beneficial owners, "
     "bank accounts, documents and verifications all hang off the party.",
     ["iam.party", "iam.party_role", "iam.company", "iam.company_member", "iam.app_user", "iam.role", "iam.role_permission",
      "iam.permission", "iam.user_role", "iam.beneficial_owner", "iam.bank_account", "iam.document", "iam.verification",
      "ref.party_role_type"]),
    ("E02", "Sessions, devices and API access", "16.8, 16.9, 14.2", "core",
     "Sign-in sessions and tokens, second factors, bound devices with their permission state, push tokens, API clients and keys, "
     "identity providers and government identity links.",
     ["iam.user_session", "iam.auth_token", "iam.mfa_factor", "iam.device", "iam.device_permission_state", "iam.push_token",
      "iam.api_client", "iam.api_key", "iam.identity_provider", "iam.gov_identity_link", "iam.biometric_template"]),
    ("E03", "Reference data and system", "2.8, 4.10, D.4", "core",
     "Countries, currencies, cities, locales and translations, files, the extensible reference lists of appendix D, settings, "
     "the outbox and webhooks.",
     ["ref.country", "ref.currency", "ref.exchange_rate", "ref.city", "ref.locale", "ref.translation", "ref.file_object",
      "ref.trip_type", "ref.vehicle_class", "ref.station_subtype", "ref.cargo_category", "sys.setting", "sys.company_setting",
      "sys.outbox_event", "sys.webhook_endpoint", "sys.webhook_delivery", "sys.schema_migration", "sys.schema_file"]),
    ("E04", "Stations, routes, carrier codes and corridors", "4.4, 4.11, 4.16, D.1", "asset",
     "The station register with compliance profiles, gates and displays; carrier routes and their stops; carrier codes and "
     "service numbers; transit corridors, approved rest stops and geofences.",
     ["net.station", "net.station_contact", "net.compliance_profile", "net.station_gate", "net.station_display", "net.route",
      "net.route_stop", "net.carrier_code", "net.code_reservation", "net.service_number", "net.corridor",
      "net.approved_rest_stop", "net.geofence"]),
    ("E05", "Approved lines and tariffs", "4.15", "asset",
     "The regulator's line catalog: versions with their route and four-eyes approvals, ordered stops, carrier permits, "
     "versioned tariffs with fare rows, and timetables.",
     ["net.line", "net.line_version", "net.line_version_approval", "net.line_stop", "net.line_permit", "net.line_tariff",
      "net.line_fare", "net.timetable_template"]),
    ("E06", "Vehicles, seats, leases and insurance", "4.3, 4.13, 4.14, 4.17, 7.10", "asset",
     "Vehicles with their seat layouts and seat prices, leases, QR tags, status history and service status, insurance policies "
     "and claims, boarding validators and fuel profiles.",
     ["fleet.vehicle", "fleet.seat_layout", "fleet.seat_layout_seat", "fleet.seat_price_rule", "fleet.vehicle_lease",
      "fleet.vehicle_qr_tag", "fleet.vehicle_status_history", "fleet.vehicle_service_status", "fleet.insurance_policy",
      "fleet.insurance_claim", "fleet.boarding_validator", "fleet.vehicle_fuel_profile"]),
    ("E07", "Crews, licences, trucks and trailers", "4.3, 4.18, 10.4", "asset",
     "Drivers and hosts with their driving hours, locked licence records and amendment requests, field checks, and the truck "
     "extension of a vehicle with trailers and their combinations.",
     ["fleet.crew_profile", "fleet.driving_hours_log", "fleet.license_record", "fleet.license_change_request",
      "fleet.field_check_log", "fleet.truck_unit", "fleet.trailer", "fleet.truck_combination"]),
    ("E08", "Trips and seat inventory", "4.5, 4.12, 7.9", "trip",
     "A trip is generated from a template on a route; its stops define segments, and each seat is sold per segment. Seat locks, "
     "crew, changes, vehicle swaps, family zones, stop events and delays belong to the trip.",
     ["ops.trip_template", "ops.trip", "ops.trip_stop", "ops.trip_pair_fare", "ops.seat_segment", "ops.standing_segment",
      "ops.seat_lock", "ops.crew_assignment", "ops.trip_change", "ops.vehicle_swap", "ops.family_zone", "ops.trip_stop_event",
      "ops.trip_delay"]),
    ("E09", "Tracking, incidents and border crossings", "7.8, 7.10, 11.3, D.1", "trip",
     "Positions, tracking state and alerts, driver notices, route adherence and permission events; incidents with evidence and "
     "external links; the crossing plan, crossing events and the transit reconciliation.",
     ["ops.geo_event", "ops.tracking_state", "ops.tracking_alert", "ops.driver_notice", "ops.route_adherence_event",
      "ops.permission_event", "ops.incident", "ops.incident_evidence", "ops.incident_external_link", "ops.trip_disruption",
      "ops.trip_crossing_plan", "ops.crossing_event", "ops.transit_reconciliation"]),
    ("E10", "Shuttle rides and subscriptions", "7.13, 4.10", "trip",
     "One open ride per user, charged stop by stop from proximity to the vehicle's presence beacon; subscription plans, "
     "subscriptions, passes, zones and NFC cards.",
     ["ops.shuttle_ride", "ops.ride_segment_charge", "ops.proximity_sample", "ops.presence_beacon", "sales.subscription_plan",
      "sales.subscription", "sales.shuttle_pass", "sales.shuttle_zone", "sales.nfc_card"]),
    ("E11", "Bookings, tickets and travel documents", "4.5, 7, 11.9", "booking",
     "A booking holds passengers and tickets; tickets are boarded, refunded or compensated. Waiting lists, inspections, entry "
     "rules and the travel documents of international tickets complete the cycle.",
     ["sales.booking", "sales.passenger", "sales.ticket", "sales.boarding_event", "sales.refund_request",
      "sales.passenger_compensation", "sales.waitlist_entry", "sales.campaign_redemption", "sales.inspection_check",
      "sales.ticket_doc", "sales.entry_rule"]),
    ("E12", "Channels, agencies and content sources", "14.7, 14.8, 14.9", "booking",
     "Sales channels with agency and channel agreements, allotments, API profiles, the channel's booking reference, statements "
     "and memos, and inbound content sources with their mappings.",
     ["sales.channel", "sales.agency_agreement", "sales.channel_agreement", "sales.channel_inventory_rule",
      "sales.channel_api_profile", "sales.channel_booking_ref", "sales.channel_statement", "sales.channel_statement_line",
      "sales.channel_memo", "sales.supplier_source", "sales.external_mapping"]),
    ("E13", "Fares, taxes, commissions and allocation templates", "5.1-5.8", "money",
     "Fare brands and tables with modifiers and cancellation policies; jurisdictions, tax schemes and rules with rate bands; "
     "commission schemes and rules; allocation templates that split every price.",
     ["pricing.fare_brand", "pricing.fare_table", "pricing.fare_table_item", "pricing.pricing_modifier",
      "pricing.cancellation_policy", "pricing.jurisdiction", "pricing.tax_scheme", "pricing.tax_rule", "pricing.rate_band",
      "pricing.commission_scheme", "pricing.commission_rule", "pricing.allocation_template", "pricing.allocation_template_line"]),
    ("E14", "Campaigns and sponsors", "5.12", "money",
     "Campaigns with promo codes and their sponsor, bank BIN ranges for card campaigns, and individual override policies.",
     ["pricing.campaign", "pricing.promo_code", "pricing.sponsor_account", "pricing.bin_range", "pricing.override_policy"]),
    ("E15", "Loyalty, rewards and partners", "5.13", "money",
     "The loyalty program with tiers and rules, points accounts and their ledger, transfers and liability, loyalty partners, "
     "the reward catalog, redemption channels, tokens, vouchers, partner redemptions and award seats.",
     ["pricing.loyalty_program", "pricing.loyalty_tier", "pricing.loyalty_rule", "pricing.points_account",
      "pricing.points_ledger", "pricing.points_transfer", "pricing.points_liability", "pricing.loyalty_partner",
      "pricing.reward_catalog", "pricing.redemption_channel", "pricing.redemption_token", "pricing.reward_voucher",
      "pricing.partner_redemption", "pricing.award_seat_rule"]),
    ("E16", "Wallets, ledger and payments", "6.1-6.5", "money",
     "Wallets and the double-entry ledger, payment providers, payments and their signed notifications, bank top-ups, "
     "withdrawals and cash remittances.",
     ["fin.wallet", "fin.ledger_txn", "fin.ledger_entry", "fin.payment_provider", "fin.payment", "fin.payment_notification",
      "fin.bank_transfer_topup", "fin.withdrawal_request", "fin.cash_remittance"]),
    ("E17", "Price allocation, settlement, payouts and float", "5.7, 6.6-6.8", "money",
     "The allocation tree of each price, the tax ledger, settlement batches and lines, payout schedules and payouts, bank "
     "reconciliation, float accounts, deposit placements and the daily float report.",
     ["fin.price_allocation", "fin.price_allocation_line", "fin.tax_ledger", "fin.settlement_batch", "fin.settlement_line",
      "fin.payout_schedule", "fin.payout", "fin.bank_reconciliation", "fin.float_account", "fin.deposit_placement",
      "fin.float_report"]),
    ("E18", "Carrier subscriptions and billing", "5.11", "money",
     "Plans and negotiated agreements produce one active subscription per company; usage is metered, billed once, and invoiced.",
     ["bill.plan", "bill.carrier_agreement", "bill.company_subscription", "bill.usage_event", "bill.carrier_invoice",
      "bill.carrier_invoice_line", "bill.billed_usage"]),
    ("E19", "Books: journals, invoices and cash", "13.1-13.7", "money",
     "Chart of accounts, periods, journal entries and lines from posting rules; cost centers and tax codes; sales invoices and "
     "credit notes; cash boxes, sessions, receipts and payments.",
     ["acct.gl_account", "acct.gl_period", "acct.journal_entry", "acct.journal_line", "acct.posting_rule", "acct.cost_center",
      "acct.tax_code", "acct.sales_invoice", "acct.sales_invoice_line", "acct.credit_note", "acct.cash_box",
      "acct.cash_session", "acct.cash_receipt", "acct.cash_payment"]),
    ("E20", "E-invoicing and tax profiles", "13.11-13.13", "money",
     "Tax authorities and activation, invoice templates and units, e-invoice documents with lines and submissions, tax profiles "
     "with dynamic fields, registrations, returns, collections without a tax file and tax payments.",
     ["acct.tax_authority", "acct.einvoice_activation", "acct.einvoice_template", "acct.einvoice_unit",
      "acct.einvoice_document", "acct.einvoice_line", "acct.einvoice_submission", "acct.tax_profile", "acct.tax_profile_field",
      "acct.tax_profile_value", "acct.tax_registration", "acct.tax_return", "acct.tax_return_line",
      "acct.tax_collection_no_file", "acct.tax_payment"]),
    ("E21", "Accounting system integration", "13.10", "money",
     "Connections to external accounting systems, account mappings, sync jobs and items, conflicts and file exports.",
     ["acct.accounting_connection", "acct.account_mapping", "acct.sync_job", "acct.sync_item", "acct.sync_conflict",
      "acct.export_batch"]),
    ("E22", "Cases, notifications and the AI assistant", "7.6, 14.10, 7.11", "service",
     "Support and claim cases with their events, notifications and templates, trip ratings, assistant conversations with "
     "messages and tool calls, policies and the evaluation set.",
     ["crm.case", "crm.case_event", "crm.notification", "crm.notification_template", "crm.trip_rating", "crm.ai_conversation",
      "crm.ai_message", "crm.ai_tool_call", "crm.ai_policy", "crm.ai_eval_case"]),
    ("E23", "Contact center", "7.11", "service",
     "Calls answered by the assistant first, with warm transfer to queues and agents by skill, call events, callbacks and "
     "quality scores.",
     ["crm.call", "crm.call_event", "crm.call_queue", "crm.call_skill", "crm.call_agent", "crm.call_agent_skill",
      "crm.call_queue_skill", "crm.callback_request", "crm.call_qa"]),
    ("E24", "Security and compliance hub", "4.9, 8, 4.10", "security",
     "Authority profiles and policies, screening requests and results, watchlists, manifest submissions, authority orders and "
     "data requests, SOS events, authority alerts, and the government adapters with their verification jobs.",
     ["sec.authority_profile", "sec.authority_policy", "sec.screening_request", "sec.screening_result", "sec.watchlist_entry",
      "sec.manifest_submission", "sec.authority_order", "sec.authority_data_request", "sec.sos_event", "sec.authority_alert",
      "sec.gov_adapter_config", "sec.verification_job"]),
    ("E25", "Platform protection and audit logs", "16", "security",
     "IP rules, risk assessments, fraud cases, blocklists, security events, encryption key registry, access reviews, "
     "break-glass log, document signatures and tamper events; and the append-only audit logs with their seals.",
     ["sec.ip_rule", "sec.risk_assessment", "sec.fraud_case", "sec.blocklist_entry", "sec.security_event", "sec.key_registry",
      "sec.access_review", "sec.break_glass_log", "sec.document_signature", "sec.tamper_event", "audit.auth_event",
      "audit.activity_log", "audit.data_access_log", "audit.row_change", "audit.log_seal"]),
    ("E26", "Governance and data protection", "2.5, 16.13-16.15", "security",
     "The policy authority matrix with its changes, the obligation register, the data inventory, consents, subject requests, "
     "privacy incidents, partner data processing agreements and feature compliance reviews.",
     ["gov.policy_domain", "gov.policy_authority", "gov.policy_change", "gov.obligation_register", "gov.data_inventory",
      "gov.consent", "gov.subject_request", "gov.privacy_incident", "gov.partner_dpa", "gov.feature_compliance_review"]),
    ("E27", "Service partners: fuel and rest stops", "14.11", "service",
     "Partners on the station pattern with versioned contracts and attendants; fuel prices, fuel cards and sessions with odometer "
     "readings and anomalies; menus and pre-orders; the shared sale, settlement and ratings.",
     ["ptn.partner", "ptn.partner_contract", "ptn.station_employee", "ptn.fuel_price", "ptn.fuel_card", "ptn.fuel_session",
      "ptn.odometer_reading", "ptn.fuel_anomaly", "ptn.partner_menu_item", "ptn.partner_order", "ptn.partner_order_item",
      "ptn.partner_sale", "ptn.partner_settlement", "ptn.rest_stop_rating"]),
    ("E28", "Shipping catalog, zones and rates", "9.21", "asset",
     "Service products and options, surcharges, delivery zones with price zones and transit times, published rate tables, "
     "the fuel surcharge index, bus hold rate cards, prohibited items and routing rules.",
     ["ship.service_product", "ship.service_option", "ship.surcharge_definition", "ship.geo_zone", "ship.pricing_zone_chart",
      "ship.transit_time_matrix", "ship.rate_table", "ship.rate_table_entry", "ship.fuel_surcharge_index",
      "ship.cargo_rate_card", "ship.prohibited_item", "ship.routing_rule"]),
    ("E29", "Shipments, legs and tracking", "9.4, 9.9", "asset",
     "A shipment with its parties, options and parcels, accepted on a shipper account; it travels on legs across modes, is "
     "tracked by events and handed over in a chain of custody; capacity is bought on trips and loads.",
     ["ship.shipment", "ship.shipment_party", "ship.shipment_option", "ship.parcel", "ship.address", "ship.shipper_account",
      "ship.pricing_agreement", "ship.shipment_leg", "ship.tracking_event", "ship.custody_transfer", "ship.capacity_booking",
      "ship.trip_cargo_capacity"]),
    ("E30", "Shipping network operations", "9.9, 9.21", "asset",
     "Hubs with sort windows and linehaul schedules, loads with stops and loading plans, nested handling units, courier routes "
     "with pickups and assignments, access points and lockers.",
     ["ship.hub", "ship.sort_window", "ship.linehaul_schedule", "ship.load", "ship.load_stop", "ship.load_plan",
      "ship.handling_unit", "ship.handling_unit_item", "ship.courier_route", "ship.courier_assignment", "ship.pickup_request",
      "ship.access_point", "ship.locker_compartment"]),
    ("E31", "Delivery, claims and scorecards", "9.4, 9.21", "asset",
     "Delivery attempts and proof, recipient preferences, cash on delivery, weight audits, delivery guarantees, returns, cargo "
     "claims and carrier scorecards.",
     ["ship.delivery_attempt", "ship.delivery_proof", "ship.delivery_preference", "ship.cod_collection", "ship.weight_audit",
      "ship.guarantee_claim", "ship.return_authorization", "ship.cargo_claim", "ship.carrier_scorecard"]),
    ("E32", "Shipping partner integration", "9.25", "asset",
     "Integration partners with contracts, external references, status mappings, pre-alerts, commands, the message queue, "
     "daily reconciliation and settlement.",
     ["ship.integration_partner", "ship.partner_contract", "ship.shipment_reference", "ship.partner_status_map",
      "ship.partner_pre_alert", "ship.partner_command", "ship.integration_message", "ship.partner_reconciliation",
      "ship.partner_settlement"]),
    ("E33", "Freight and transit trucking", "10, D.3", "trip",
     "Freight requests with the D.3 cargo data, bids and contracts that produce legs; containers, yard handovers, port "
     "appointments and gates, transit declarations, escorts, documents, weighbridge readings and claims.",
     ["frt.freight_request", "frt.freight_bid", "frt.freight_contract", "frt.container", "frt.leg_container",
      "frt.handover_event", "frt.port_appointment", "frt.gate_event", "frt.transit_declaration", "frt.escort_assignment",
      "frt.freight_document", "frt.weighbridge_reading", "frt.detention_claim", "frt.freight_claim"]),
    ("E34", "Border manifest gateway", "11, D.1.8", "security",
     "Border points extend border stations; crossing profiles hold each authority's requirements; a manifest is a versioned "
     "snapshot of persons, vehicles and cargo, answered by responses and checked by discrepancies.",
     ["brd.border_point", "brd.crossing_profile", "brd.manifest", "brd.manifest_person", "brd.manifest_vehicle",
      "brd.manifest_cargo", "brd.manifest_response", "brd.manifest_discrepancy"]),
    ("E35", "Contracted transport", "D.2", "trip",
     "Contracts between an institution or employer and a carrier, with routes, riders, authorised receivers, attendance and "
     "invoices.",
     ["ctr.service_contract", "ctr.contract_route", "ctr.contract_rider", "ctr.authorized_receiver", "ctr.attendance_event",
      "ctr.contract_invoice"]),
    ("E36", "Rail and taxi", "4.10, 14.8, 21.1", "trip",
     "Rail fare classes, coach layouts, train compositions and connected journeys; taxi offices, permits, meter tariffs, shifts, "
     "ride requests, dispatch offers and rides.",
     ["rail.fare_class", "rail.coach_layout", "rail.train_composition", "rail.journey", "rail.journey_leg", "taxi.taxi_office",
      "taxi.taxi_permit", "taxi.meter_tariff", "taxi.taxi_shift", "taxi.ride_request", "taxi.dispatch_offer", "taxi.ride"]),
    ("E37", "Car rental", "21.2", "trip",
     "Rental companies with branches, fleet, rates and add-ons; renter rules; bookings with add-ons, contracts with drivers, "
     "inspections and deposits; telematics devices and trip logs.",
     ["rent.rental_company", "rent.rental_branch", "rent.rental_vehicle_class", "rent.rental_fleet", "rent.rental_rate",
      "rent.rental_addon", "rent.renter_rule", "rent.rental_booking", "rent.rental_booking_addon", "rent.rental_contract",
      "rent.contract_driver", "rent.rental_inspection", "rent.deposit_hold", "rent.telematics_device", "rent.vehicle_trip_log"]),
]

# Focus diagrams: one business rule across modules; tables keep their own module colour (family None)
FOCUS = [
    ("F01", "Travel documents on international trips", "11.9, 11.9.1 (v2.7)", None,
     "Passport by default, approved exceptions per destination or transit country and nationality. The segment's countries come from "
     "the trip's stops; the entry rule is looked up most specific first; the passenger's document and the rule applied are recorded "
     "on the ticket.",
     ["sales.entry_rule", "ops.trip", "ops.trip_stop", "net.station", "ref.country", "sales.booking", "sales.passenger",
      "sales.ticket", "sales.ticket_doc", "iam.app_user"]),
    ("F02", "Booking spine: from trip to ledger", "4.5, 4.6, 4.12, 5.8", None,
     "The core relationships every sale goes through: a trip's stops and seat segments, the booking with its passengers and tickets, "
     "the payment and the ledger transaction, and the price allocation of the ticket.",
     ["ops.trip", "ops.trip_stop", "ops.seat_segment", "sales.booking", "sales.passenger", "sales.ticket", "fin.payment",
      "fin.ledger_txn", "fin.price_allocation", "fin.price_allocation_line", "iam.company", "iam.party"]),
]

# Data stores of the use case and data flow diagrams v1.0 (section 6) mapped to the groups that implement them
DATA_STORES = [
    ("D1", "Identity and access", ["E02"], ["iam.app_user", "iam.role", "iam.permission"]),
    ("D2", "Parties and documents", ["E01"], []),
    ("D3", "Fleet and crews", ["E06", "E07"], []),
    ("D4", "Network and tariffs", ["E04", "E05"], ["ref.city"]),
    ("D5", "Trips and inventory", ["E08"], []),
    ("D6", "Bookings and tickets", ["E11"], []),
    ("D7", "Pricing and allocation", ["E13", "E14"], ["fin.price_allocation", "fin.price_allocation_line"]),
    ("D8", "Wallets and ledger", ["E16"], ["fin.payout", "fin.payout_schedule"]),
    ("D9", "Tracking and operations", ["E09"], ["ops.trip_stop_event"]),
    ("D10", "Shuttle rides", ["E10"], []),
    ("D11", "Shipments", ["E28", "E29", "E30", "E31", "E32"], []),
    ("D12", "Security and compliance", ["E24", "E34"], []),
    ("D13", "Partners and loyalty", ["E27", "E15"], []),
    ("D14", "Invoices and journal", ["E19", "E20", "E21"], []),
    ("D15", "Cases and notifications", ["E22", "E23"], []),
    ("D16", "Audit logs", [], ["audit.auth_event", "audit.activity_log", "audit.data_access_log", "audit.row_change", "audit.log_seal"]),
    ("D17", "Channels and agencies", ["E12"], []),
]

SCHEMA_TITLE = {
    "iam": "Parties, users, roles", "ref": "Reference lists", "sys": "Settings, outbox",
    "net": "Stations, routes, lines", "fleet": "Vehicles, crews, trucks", "ship": "Shipments, network",
    "ops": "Trips, tracking, shuttle", "frt": "Freight, transit", "ctr": "Contracted transport",
    "rail": "Rail", "taxi": "Taxis", "rent": "Car rental",
    "sales": "Bookings, tickets, channels", "pricing": "Fares, tax, loyalty", "fin": "Wallets, ledger",
    "acct": "Books, e-invoicing", "bill": "Carrier billing", "crm": "Cases, AI, calls", "ptn": "Fuel, rest stops",
    "sec": "Security hub", "brd": "Border manifest", "gov": "Data protection", "audit": "Audit logs",
}
