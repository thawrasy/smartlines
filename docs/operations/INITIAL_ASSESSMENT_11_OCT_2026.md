# Initial assessment, 11 October 2026: boarding photo, ticket binding and the money model

This is the record of the sixth round of owner decisions and the first assessment made from them. It is the input to the
next development steps. It states what the code does today, what changes, in which order, and what the owner must still
decide. Dates and amounts are examples from the owner's brief; the rules themselves are configuration, not code (below).

## 1. Decisions recorded

### Boarding photo

| Topic | Decision | Status in code |
|---|---|---|
| Phase 1 | The photo is optional for a person and for family members; a file may stay empty | Done: no photo is a normal state; the driver sees "no photo" |
| When it is mandatory | When it is a condition of travel, or once the person is linked to the National Information Centre or the competent authority, which supplies the data and shows the photo as the verification | Built (1087): the rules decide it, proposed and approved by two platform people, and enforced at booking and at the gate. Until a rule is approved the photo is optional. The rule values are the owner's decision (question 4) |
| Who sees it | Driver, carrier agent, carrier manager or operator, escalation office, and any authority with a duty of escalation to the vehicle; **domestic trips and Syrian citizens only** | Partly: driver and carrier office read it; domestic-and-citizen rule and escalation role not built (WP2) |
| Foreign travellers | No photo; identity checked from the passport; may book on the platform, through an agent, or directly with the carrier with passport data | Passport booking exists; no photo rule (WP7) |
| Transit passengers | No photo; their data is required | Not built (WP7) |
| Ticket binding | A ticket booked from the account (for the person or a family member) is bound to that account | Not built: see section 3 (WP3) |
| Replacement | Not by the person or the family. A change is made by the platform with proof of identity, or a civil registry extract that carries the photo; audited | Corrected in this round: the database and the API refuse a second photo (409 PHOTO_EXISTS). Built (1087): a platform request with the evidence and the new photo, applied by a second platform person, and audited |
| Phase 2 | The app keeps a copy of the photo, mandatory once linked. Face matching is an option, off by default, only if the state requires it later | Not built |
| Ride-hailing drivers | The platform may require a recent photo, licence, identity and vehicle papers | Not built (WP8); the taxi module has permits and shifts |

### Boarding in practice

- Scheduled trips: the driver shows a passenger's photo when checking who is boarded.
- Shuttle and public transit: the boarding is recorded by scanning the passenger's QR code at a permitted stop; the photo is shown on that scan.
- Stations and gates are boarding points run by the carrier (its agents, managers or operators). They record the boarding. They do not verify data, and the platform has no station portal.

### Money

Three stages, shown on a 100-unit fare (examples from the brief):

1. **All-in:** the passenger pays 100; the carrier receives all of it, taxes included.
2. **Split:** 100 = carrier fare 98 + platform commission 2. The commission is collected from the passenger or deducted at settlement.
3. **Taxes:** 100 = carrier 95 + tax 3 + platform 2. If the platform remits the tax to the state, it deducts the tax and its commission, and transfers 95 to the carrier's wallet. Remittances to the state and to carriers run on a regular schedule (weekly or monthly). If the carrier remits the tax itself, the tax is recorded as the carrier's liability.

Further rules:
- Cash collected by a carrier produces a commission receivable from that carrier, which is offset (netting, "al-muqassa") through the platform.
- Every movement is a balanced double entry in the platform's books and in each carrier's books, and wallet movements between holders are posted explicitly.
- Wallet money is held in bank accounts, one virtual account per holder if the bank supports it. The platform records ledger claims against those accounts. No licence is assumed before the pilot; the licence follows the pilot.
- Every rule is configuration; a law may impose one.

## 2. What the code has today (evidence)

- **Double entry:** `fin.ledger_txn` and `fin.ledger_entry`; a database trigger (`fin.tg_ledger_txn_balanced`, db/schema/070_fin.sql) rejects an unbalanced transaction. `ledger.post_txn` accepts several lines, so compound entries are possible.
- **Wallet types:** `USER`, `COMPANY`, `PLATFORM`, `ESCROW`, `COMMISSION`, `TAX`, `SPONSOR`, `GATEWAY_CLEARING`, `BANK_CLEARING`, `CASH_COLLECT`, `DEPOSIT`, `EXPENSE`. The accounts the money model needs already exist.
- **Fees:** `platform_fee` is a flat amount per booking (`config.py`, 100,000 minor units). The agency commission is in basis points. There is no per-ticket split of the fare into carrier, commission and tax legs at sale time; the breakdown is stored in the rules snapshot.
- **Tax:** `acct.tax_code` has a `WITHHOLDING` type, and sales invoices and exports exist. There is no posting for withholding or for remittance to the state.
- **Bank side:** `fin.float_account` (bank accounts holding wallet funds, matched to wallets), `fin.deposit_placement`, `fin.bank_statement_import` and `fin.wallet_reconciliation` exist. No per-holder virtual accounts and no bank interface.
- **Cash:** `acct.cash_session`, `acct.cash_receipt`, `fin.cash_remittance` and `acct.cash_box` exist. Netting a cash commission against a payout is not confirmed in the code and must be checked.
- **Photo:** `iam.party_photo` (migration 1086): one photo per person, scanned and encrypted, first photo only, erased with the person. Every read is audited.
- **Visibility of parties:** migration 1039 lets a party row be seen through a passenger row that refers to it. Linking a self-booking to the account would widen what a carrier can see, so this policy must be narrowed first (see risk 1).
- **Roles:** carrier staff have permissions such as `manifest.view`; drivers have their own portal. There is no gate role and no escalation role.

## 3. Gaps and risks

1. **Party visibility (high).** Binding self-bookings to the account through `sales.passenger.party_id` exposes the account holder's party row to anyone who can read the passenger row, which includes carrier staff. Before binding: give carriers the passenger name fields only (a view), keep contact and identity fields to the person, the platform and audited endpoints.
2. **Photo rules are not configurable (high).** Mandatory-or-optional by market, trip type, nationality and passenger category needs a policy table with effective dates, the legal basis, and four-eyes changes. Without it, every rule is code.
3. **Domestic-and-citizen visibility (high).** The photo endpoints do not yet check the trip type or the nationality. This must be enforced in the database or in the endpoint, not only in the app.
4. **Ticket binding (high).** Until WP3, most self-bookings have no photo. This is the owner's option (a) and is the only route that works for a self-booking.
5. **Taxes and remittances (high).** No withholding posting, no remittance run, no tax report per stage. This is the largest money gap.
6. **Commission model (medium).** The flat booking fee and the percentage agency commission must become one rate card per carrier, with the split frozen on the ticket.
7. **Offline boarding (medium).** The driver's offline pack carries no photos. Shuttle stops need them offline if the signal is poor. Decide what goes on the device and for how long (WP6).
8. **Device copy (medium).** The photo reaches the phone for display; whether the phone keeps a copy must be checked on a device before release.
9. **Virtual accounts (medium).** The model can be built on `fin.float_account` with a bank adapter; no bank contract exists. Until then the pilot uses pooled float accounts matched to the ledger.
10. **Legal basis (to confirm).** Whether a photo is mandatory, who may see it, and the retention period come from law. Nothing in this assessment is legal advice; counsel must review the rules before they are switched on.

## 4. Work packages, in order

| WP | Content | Size | Depends on |
|---|---|---|---|
| WP1 | Photo policy table and engine: market, trip scope, nationality class, passenger category, requirement, effective date, legal basis; four-eyes changes; enforced at booking and at boarding | M | — |
| WP2 | Visibility rules: domestic trips and Syrian citizens only; escalation office role; carrier gate and agent roles | M | WP1, WP3 |
| WP3 | Ticket binding: self and family bookings link the traveller to the account; carrier sees names only (a view) | M | risk 1 decided |
| WP4 | Platform replacement: request, proof of identity or civil registry extract, four-eyes, audit | S | — |
| WP5 | Carrier gate roles and QR boarding at permitted stops; no platform station portal | M | WP2 |
| WP6 | Driver app: photo on scheduled-trip checks and at stops; the offline pack decision | M | WP5, owner decision |
| WP7 | Transit and foreign passengers: no photo, required data, passport-based booking | S | WP1 |
| WP8 | Ride-hailing driver verification (photo, licence, identity, vehicle) in the taxi module | L | WP1 |
| WP9 | Money stages 1–3: rate card per carrier; the split frozen on each ticket; postings for sale, settlement, tax and remittance; cash commission receivable and netting; a test that the legs always add up to the price | L | owner decisions 2 and 3 |
| WP10 | Virtual accounts: bank adapter for `fin.float_account`; daily reconciliation against statements | L | bank partner |
| WP11 | Statements per carrier and per platform; tax reports per stage | M | WP9 |

WP4, WP9 (design and tests) and WP1 can start now. WP3 must wait for the decision on risk 1, which is taken here: option
(a), binding from the account, with the narrowed visibility.

## 5. Questions for the owner

1. The word in the brief that reads "almunafst" (for the transit passengers' data): is it "border crossings" (almanafidh)? (Assumed: border crossings.)
2. Tax at launch: the platform remits the tax (stage 3, first form), or the carrier remits it itself (second form)? Under which agreement with the Ministry of Finance?
3. Commission at launch: the current flat fee per booking, or a percentage per carrier (for example 2%)?
4. The legal text that makes the photo mandatory, the date, and the authority that supplies the data (National Information Centre or another).
5. Evidence for a platform replacement: a civil registry extract that carries the photo, or an identity document; who approves.
6. Remittance schedule: weekly or monthly, for each tax and for carrier payouts.
7. Offline pack: may the driver's phone hold photos for shuttle stops, for how long, and under which encryption.
8. Bank partner for virtual accounts, and whether the pilot may run on pooled float accounts first.

## 6. What changed in the repository with this assessment

- Migration 1086 and the photo service: a photo on file is never replaced by the person or the family head; the database
  refuses it and the API answers 409 PHOTO_EXISTS. The test for a second photo now expects the refusal. The platform
  replacement (WP4) and the photo rules (WP1) are built in 1087; see the response record.
- The response record gains a sixth-round section, and its fifth-round replacement row is corrected.
- Seventh round (section 7): the owner's answers are recorded. Migration 1088 makes the documents accepted for a photo
  change a platform setting (passport added), and a request with a switched-off kind is refused.

## 7. Seventh round: the owner's answers (11 October 2026)

The owner answered the eight questions of section 5 and added one (wallet management). The decisions are the owner's. The
status column states what the code does today; nothing below is switched on by default unless the status says so.

| # | Topic | Decision | Status in code and next step |
|---|---|---|---|
| 1 | Meaning of "the competitor" in the transit scenario | Border crossings. Confirmed | Recorded. The border manifest module (1019) uses the same terms |
| 2 | Border flows | (a) A trip into Syria from abroad is sent to the border crossings system, naming the crossing point where it arrives, so the authority can see it, with a passenger group identifier and the arriving passengers. (b) A trip out of Syria is sent to the border crossings platform, after the company is linked with it, naming the crossing point where the trip leaves Syria. (c) A transit trip names its entry crossing point and its exit crossing point, and is sent as a transit trip with both; the route (line) is defined too and sent if the authority asks for it | The manifest categories DEPARTING, ARRIVING, TRANSIT and DOMESTIC exist, and a transit manifest needs both points (CHECK in 1019). The end-to-end link to the authority's systems is not built: WP7 |
| 3 | Tax at launch | Not charged at launch. When it is enacted, it is switched on by a platform setting or by a carrier-gateway setting, for all carriers or for a segment: by revenue above or below a threshold, by carrier type, for individuals, or any other segment. The carrier type is known in advance. Later, by agreement with the Ministry of Finance (approvals and legislation), the tax may be withheld from the carrier and remitted by the platform. Until then the switch decides | `pricing.tax_scheme` exists with status PENDING, so nothing is applied until it is activated; its scope field can hold a segment. The carrier-gateway switch and the withholding are not built: WP9 |
| 4 | Commission at launch | A fixed amount per booking, or a percentage per carrier. Both are configurable, by platform setting, per carrier type or segment, or not charged. The amount may be a percentage of the fare or a flat sum regardless of the fare, and is set per carrier by agreement | `pricing.commission_scheme` and `pricing.commission_rule` (rate or amount, minimum, maximum, cap period) and `fin.fee_rule` (percent, fixed, or both; borne by payer, platform or carrier) exist, and are PENDING or INACTIVE by default. The current flat 1,000 SYP per booking is data to be set per carrier agreement. No default changed |
| 5 | Legal text for the photo | None is needed at launch. The photo is optional by default; the platform may make it required by setting; a government system may later impose it or permit it. The rules stay flexible | Built (1087). The rule's legal basis accepts the platform's own decision reference (3 to 500 characters) until a legal text exists |
| 6 | Remittance frequency | Set per carrier agreement: daily, weekly or monthly. A daily schedule may carry a charge because of its cost. The routine release from the reserved cash account to the customer's wallet is electronic. From the wallet the carrier may transfer to its bank account, pay a partner (a station, a rest stop), or use the funds in any other way the platform allows | Not built in this round. `fin.cash_remittance` exists. The per-carrier schedule and the routine release are configuration for WP5 and WP9 |
| 7 | Document for a photo replacement | The national identity card is the main document. Until every citizen holds one, and while children receive none before a certain age, a civil registry extract that carries the photo, or a passport, is accepted. The list is a platform setting, not code | Built (1088). `iam.photo_evidence_kind` holds the three kinds, each on or off; a request with a kind that is off is refused with `EVIDENCE_KIND_NOT_ACCEPTED`. A second platform person applies the change (WP4, as built) |
| 8 | Photos on the driver's phone when offline | No photo is kept on the driver's phone, in any case. Identity checks at the security gates use a security portal, reached once the route and the vehicle number are known, to find the person they need. This also relieves the driver app and the driver portal | The offline pack carries no photos (design). A photo is fetched online for each scan. Open: the app's image component may keep a device cache; this must be verified on a device and removed if it exists. The security-gate lookup is not built: item S4 |
| 9 | Bank partner for virtual accounts | Not at launch. Bank links for independent e-wallets are still being developed in Syria. The platform will contract banks; funds are held in separate bank accounts under each bank's own compliance; the platform's wallet is ready to be linked with a bank | WP10 moves to after the bank contracts. `fin.float_account` and `fin.deposit_placement` exist; there is no bank adapter |
| 10 | Wallet management | Built later, with the owner's guidance; or bought ready from a vendor that already runs one and adapted to the company's visual identity | Open. Planning with the owner; not built |

New work items from this round:

- **S1** Border flows: map each trip type to its crossing points and link the manifests to the authority (extends WP7).
- **S2** Tax activation by segment, with the carrier-gateway switch and, later, withholding (WP9).
- **S3** Commission per carrier agreement: configuration screens and the fixed-or-percentage choice (WP9).
- **S4** Security-gate lookup: route and vehicle first, then the person; no photo on a driver's device (new WP12).
- **S5** On a device, verify that the photo view writes nothing to the image cache; if it does, change the view (mobile).
- **S6** Remittance schedules per carrier and the routine release from the reserved cash account (WP5, WP9).
- **S7** Ride-hailing driver and children's identity rules, kept configurable (WP8).

Legal and operating review is still needed before go-live for items 2, 3 and 9, because they depend on agreements with the
authorities and banks named above.

