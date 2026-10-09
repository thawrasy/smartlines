"""Reviewed exceptions to the code rules of test_code_rules.py (expert review of October 2026, stage C).

Each entry is a decision a reviewer took: where the code steps outside the caller's own row-level security, or reads a
stored wallet balance directly, and why that is right there. A new use, or a use moved to another function, fails CI
until it is added here with its reason, so it is reviewed rather than slipped in. Keep reasons short and specific:
what the caller cannot see or write by itself, and why the step needs it.
"""

# ------------------------------------------------------------------ db.system_scope
# (file, function): (number of uses, reason). The system scope acts as the platform inside the caller's transaction;
# the acting user stays in the context and the audit logs.
SYSTEM_SCOPE = {
    ("app/modular/workflows.py", "_charge"): (1, "service payment: posts from the passenger's wallet to the carrier's shared wallet"),
    ("app/modular/workflows.py", "accept_bid"): (1, "freight: the shipper accepts a carrier's bid and creates the contract both parties see"),
    ("app/modular/workflows.py", "book_rental"): (1, "rental booking written for the renting company's fleet"),
    ("app/modular/workflows.py", "buy_plan"): (1, "shuttle pass and subscription rows issued by the operator's plan"),
    ("app/modular/workflows.py", "cancel_rental"): (1, "the renter cancels a booking held in the rental company's rows"),
    ("app/modular/workflows.py", "cancel_taxi"): (1, "the rider cancels a ride request already offered to drivers"),
    ("app/modular/workflows.py", "post_freight"): (1, "freight request published to carriers"),
    ("app/modular/workflows.py", "send_parcel"): (1, "shipment and its first tracking event written for the carrier"),
    ("app/modular/workflows.py", "taxi_request"): (1, "ride request offered to drivers of other companies"),
    ("app/modular/workflows.py", "track"): (1, "public parcel tracking by number: carrier rows, nothing personal returned"),
    ("app/modules/account/service.py", "export"): (1, "data export of the person's own bookings, including those an agency made for them"),
    ("app/modules/cash/api.py", "decide"): (1, "finance confirms a carrier's remittance: posts to the carrier's cash wallet"),
    ("app/modules/cash/service.py", "booking_detail"): (1, "counter staff open a booking on their own carrier's trip made by any buyer"),
    ("app/modules/cash/service.py", "bookings"): (1, "counter list of the carrier's cash and pay-later bookings, with the seller's name"),
    ("app/modules/cash/service.py", "cancel"): (2, "counter cancellation: the booking of any buyer and the carrier's cash wallet"),
    ("app/modules/cash/service.py", "collect"): (1, "counter collects a pay-later reservation and posts to the carrier's cash wallet"),
    ("app/modules/cash/service.py", "dashboard"): (1, "counter totals over every booking sold at the carrier's counters"),
    ("app/modules/cash/service.py", "day_report"): (1, "the drawer count per seller over the carrier's counter sales"),
    ("app/modules/cash/service.py", "sell"): (1, "opens the carrier's cash wallet before a counter sale"),
    ("app/modules/cash/service.py", "ticket_status"): (1, "printing a counter ticket of the carrier's own trip"),
    ("app/modules/documents/scanner.py", "scan_file"): (1, "the scanner job marks any uploaded file and raises its event"),
    ("app/modules/documents/service.py", "read_file"): (1, "reading a document writes the data access log the reader cannot write"),
    ("app/modules/documents/service.py", "upload"): (1, "encryption key lookup for a new document"),
    ("app/modules/family/api.py", "_summary"): (1, "the family account (head's wallet) shown to members"),
    ("app/modules/family/api.py", "add_member"): (1, "a member's person record created and sealed for the head"),
    ("app/modules/family/api.py", "approve"): (1, "the head approves a link and the member is notified"),
    ("app/modules/family/api.py", "create_family"): (1, "the head's person record is read to start the family"),
    ("app/modules/family/api.py", "family_passes"): (1, "passes bought for members from the family account, posted to the operator"),
    ("app/modules/family/api.py", "join"): (1, "joining by code: the family and its link requests belong to the head"),
    ("app/modules/family/api.py", "leave"): (1, "a member leaves a family whose rows belong to the head"),
    ("app/modules/family/api.py", "update_member"): (1, "a member's sealed identity and mobile updated for the head"),
    ("app/modules/family/service.py", "link_account"): (1, "linking a member account moves passenger and pass rows between the two people"),
    ("app/modules/family/service.py", "transfer"): (1, "money between the head's wallet and the family account"),
    ("app/modules/integration/service.py", "ping"): (1, "test event written to the outbox and its delivery queue"),
    ("app/modules/integration/service.py", "redeliver"): (1, "a resend request of a money or authority event, decided by the platform"),
    ("app/modules/integration/v1.py", "border_decide"): (1, "a border authority records its decision on a manifest of another company"),
    ("app/modules/integration/v1.py", "border_manifest"): (1, "a border authority reads a manifest addressed to it"),
    ("app/modules/integration/v1.py", "border_manifests"): (1, "a border authority lists the manifests addressed to it"),
    ("app/modules/integration/v1.py", "manifest_ack"): (1, "an authority acknowledges a manifest delivery"),
    ("app/modules/integration/v1.py", "manifest_deliveries"): (1, "deliveries addressed to the calling authority"),
    ("app/modules/integration/v1.py", "manifest_delivery"): (1, "one manifest delivery addressed to the calling authority"),
    ("app/modules/integration/v1.py", "wallet_credit_status"): (1, "a partner reads the status of its own credit"),
    ("app/modules/integration/v1.py", "wallet_credits"): (1, "a partner lists its own credits to passengers"),
    ("app/modules/integration/v1.py", "wallet_lookup"): (1, "a partner checks that a mobile number has a passenger wallet"),
    ("app/modules/manifests/service.py", "issue"): (1, "a manifest built from crew, vehicle and passengers of the trip, sealed"),
    ("app/modules/payments/api.py", "_test_payment"): (1, "sandbox payment page reads the payment it completes"),
    ("app/modules/payments/api.py", "agency_topups"): (1, "an agency lists the top-ups it took in cash for passengers"),
    ("app/modules/payments/api.py", "mine"): (1, "the passenger's own payments with their provider and transfer details"),
    ("app/modules/payments/service.py", "agency_topup"): (1, "an agency credits a passenger's wallet from its prepaid balance"),
    ("app/modules/payments/service.py", "apply_notice"): (1, "a provider's signed notice settles a payment"),
    ("app/modules/payments/service.py", "cancel"): (1, "the payer cancels a pending payment or transfer"),
    ("app/modules/payments/service.py", "cancel_approval"): (1, "a cancelled approval undoes the statement match or the held refund"),
    ("app/modules/payments/service.py", "confirm_code"): (2, "an e-wallet payment confirmed by the payer's code: the attempt, then the provider's answer (R-16)"),
    ("app/modules/payments/service.py", "decide_approval"): (1, "the last approval credits the statement line or releases the refund; a rejection undoes it"),
    ("app/modules/payments/service.py", "ignore_line"): (1, "finance sets aside a bank statement line"),
    ("app/modules/payments/service.py", "import_statement"): (1, "finance imports a bank statement and matches transfers"),
    ("app/modules/payments/service.py", "match_line"): (1, "finance matches a statement line to a transfer and credits the payer"),
    ("app/modules/payments/service.py", "partner_credit"): (1, "a partner credits a passenger's wallet through the API"),
    ("app/modules/payments/service.py", "record_rejected"): (1, "a rejected provider notice is kept for investigation"),
    ("app/modules/payments/service.py", "request_refund"): (1, "finance asks for a refund to the source: the amount is held in the payer's wallet"),
    ("app/modules/payments/service.py", "send_refund"): (2, "a refund sent to its provider: claimed, then posted or released by the answer (R-17)"),
    ("app/modules/payments/service.py", "start_bank_transfer"): (1, "a transfer reference opened for the passenger"),
    ("app/modules/payments/service.py", "start_booking_payment"): (2, "the passenger pays a reservation through a provider: recorded, then the provider's answer (R-16)"),
    ("app/modules/payments/service.py", "start_topup"): (2, "a top-up payment opened with a provider: recorded, then the provider's answer (R-16)"),
    ("app/modules/payments/service.py", "status_of"): (1, "the payer reads the status of their own payment"),
    ("app/modules/payouts/service.py", "add_bank_account"): (1, "encryption key lookup for a new bank account"),
    ("app/modules/payouts/service.py", "mark_paid"): (1, "finance records a paid withdrawal and posts it from the company's wallet"),
    ("app/modules/payouts/service.py", "request_withdrawal"): (1, "cash owed is set off against earnings before a withdrawal"),
    ("app/modules/payouts/service.py", "reveal_iban"): (1, "revealing an IBAN writes the data access log"),
    ("app/modules/reports/api.py", "create_schedule"): (1, "recipients of a schedule are checked against the company's accounts"),
    ("app/modules/reports/api.py", "download_delivery"): (1, "a sensitive report link checks its recipient and logs the download"),
    ("app/modules/reports/scheduler.py", "_deliveries"): (1, "sensitive report files stored encrypted with a link per recipient"),
    ("app/modules/sales/service.py", "booking_view"): (1, "tickets of a booking on another company's trip, for its buyer"),
    ("app/modules/sales/service.py", "cancel_booking"): (1, "refund from escrow and allocation lines the buyer cannot see"),
    ("app/modules/sales/service.py", "cancel_reserved"): (1, "an unpaid reservation frees seats and closes its payment"),
    ("app/modules/sales/service.py", "confirm_reserved"): (1, "a paid reservation is settled into escrow and its tickets issued"),
    ("app/modules/sales/service.py", "create_booking"): (2, "seats, tickets and passengers on the carrier's trip, and the payment into escrow"),
    ("app/modules/sales/service.py", "offline_credential"): (1, "the passenger's signed ticket credential for offline boarding"),
    ("app/modules/sales/service.py", "travellers"): (1, "a family member's stored identity used for a booking by the head"),
    ("app/modules/support/api.py", "pay_claim"): (1, "an approved claim paid from the carrier's or the platform's wallet"),
    ("app/routers/carrier.py", "complete_trip"): (1, "trip completion releases escrow to the allocation lines and sets off cash owed"),
    ("app/routers/driver.py", "offline_pack"): (1, "the driver's offline list of the trip's tickets and passengers"),
    ("app/routers/wallet.py", "topup"): (1, "sandbox top-up: the simulated provider notice and the posting from clearing"),
}

# ------------------------------------------------------------------ stored wallet balances
# Shared (DEFERRED) wallets store a balance that lags their newest entries; the balance that counts is
# fin.wallet_balance(id), which ledger.counted() applies. A raw read of the stored balance, or of a raw wallet row, is
# right only for wallets with an exact balance (IMMEDIATE: passenger, family and counter cash wallets).
# file: (number of raw reads, reason)
BALANCE_READS = {
    "app/modules/family/service.py": (1, "the family account (FAMILY wallet, IMMEDIATE) after a transfer"),
    "app/modules/family/api.py": (1, "the family account (FAMILY wallet, IMMEDIATE) on the family page"),
    "app/routers/wallet.py": (1, "the passenger's wallet (USER, IMMEDIATE) after a top-up"),
    "app/routers/regulator.py": (1, "the sum of passenger wallets (USER, IMMEDIATE); escrow uses fin.wallet_balance"),
}
WALLET_ROWS = {
    "app/ledger.py": (2, "the wallet helpers: owned_wallet finds or opens a wallet (ON CONFLICT, then read again); shared wallets go through counted()"),
    "app/modules/family/service.py": (1, "FAMILY wallets, IMMEDIATE"),
    "app/modules/payments/service.py": (4, "clearing wallet (only its id is used), the payer's wallet of a paid reservation "
                                           "(USER, exact), the refund check (wrapped in counted()) and a bank transfer's wallet "
                                           "(its currency only, 1061)"),
}
