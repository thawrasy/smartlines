# Experience

How Masslak should feel and flow for each person who uses it. Build every screen from these principles, the portal map and the journeys below, using the components in this system.

## Experience principles

1. **Certainty before commitment.** Show price breakdown, seat, time, cancellation terms and the balance after payment before the passenger taps pay. No surprise fees after the summary.
2. **One clear next step.** Each screen has one filled `primary` action. Secondary paths are tonal, outlined or text.
3. **Works on a weak network.** Tickets, QR codes, the driver manifest and the inspector check work offline and sync later. Every write shows its sync state.
4. **Same pattern, every portal.** A carrier clerk, a passenger and an authority officer meet the same buttons, tables, chips and dialogs. Learning one portal teaches the others.
5. **Arabic first, never translated-looking.** Layouts are designed in RTL first and mirrored to LTR, not the other way round. Copy is written in Arabic, then English.
6. **Respect for money and identity.** Wallet amounts, deductions and personal data are shown with care: masked by default where sensitive, always with a reason when collected.
7. **Calm for operators.** Dense portals stay quiet: one accent colour, status by chips, alerts only when action is needed.

## People

| Person | Where | Main goal | What matters |
| --- | --- | --- | --- |
| Passenger | Mobile app, website | Find a trip, book a seat, travel with a QR ticket | Price clarity, speed, offline ticket, Arabic first |
| Shuttle rider | Mobile app | Ride a city or intercity shuttle line and pay per segment | One-tap boarding by scanning the vehicle sticker, balance warnings before each station |
| Shipper and recipient | Mobile app, website | Send a parcel and track it to delivery | Price before drop-off, live status, proof of delivery |
| Carrier owner and clerks | Web portal | Run fleet, crews, trips, sales and settlements | Fast data entry, clear revenue, approvals |
| Driver and host | Driver app (Android first) | Run the assigned trip, board passengers, report incidents | Large targets, works offline, night mode, SOS |
| Travel agency | Web portal | Sell tickets for many carriers under a quota | Quick search, commissions, statements |
| Fuel station and rest stop | Partner app and portal | Accept platform payments for fuel and services | Scan, confirm, settle |
| Courier and hub staff | Mobile app | Collect, sort and deliver parcels | Scan-driven flow, proof of delivery |
| Inspector and security officer | Inspector app, Security hub | Verify tickets, vehicles and passengers on legal basis | Instant verdict, audit trail |
| Regulator | Web dashboard (read only) | Oversee lines, licences, tariffs, complaints | Aggregated, trustworthy figures |
| Platform admin and finance | Back office | Approve companies, manage reference data, reconcile money | Four-eyes approvals, audit, reports |

## Portal map

Each portal uses the same shell for its platform (Platforms): a navigation drawer on web, a bottom navigation bar on mobile.

### Passenger app and website

- **Home:** search card (from, to, date, passengers), upcoming trip card, wallet balance, shuttle quick-scan.
- **Search results:** trip cards sorted by departure, filters as chips (time of day, carrier, fare brand, amenities).
- **Trip:** stops timeline, vehicle, fare brands, baggage, cancellation terms.
- **Seat selection:** seat map with a 10-minute hold countdown.
- **Passenger details:** structured names by identity document (four parts for Syrian citizens), nationality, document number.
- **Checkout:** price breakdown, payment method (wallet, cash at agency, card later), terms.
- **Ticket:** QR code, booking reference in `data-large`, boarding window, offline badge.
- **Trips, Wallet, Account:** bottom navigation tabs on mobile, top navigation on web.
- **Shuttle:** scan vehicle sticker, live ride with current and next station, fare per segment, warning before each station, end ride.

### Carrier portal (web)

Dashboard, Trips and schedule, Fleet (vehicles, seat layouts, licences), Crews, Lines and stations, Sales and bookings, Manifests, Settlements and payouts, Users and roles, Company profile and documents, Subscription.

### Driver app

Today (assigned trip), Boarding (scan QR, manifest count), Route (stops timeline, delays), Incidents and SOS, Profile. The app locks when location permission is off; SOS stays available.

### Agency portal (web)

Search and sell, Bookings, Quotas, Commissions and statements, Sub-agents.

### Partner portals

Fuel station: scan vehicle QR, enter litres and amount, confirm. Rest stop: menu, orders, scan to pay. Both: daily settlement.

### Shipping

Create shipment, drop-off points, tracking timeline, courier tasks, hub sorting, proof of delivery.

### Security hub and inspector

Screening queue with ALLOW, REVIEW and DENY verdicts, official requests, ticket and vehicle verification by scan.

### Regulator dashboard

Approved carriers, active lines and licences, tariff compliance, complaints and SLA, taxes and fees by authority. Read only, aggregated by default.

### Admin back office

Company approvals, reference data (cities, stations, countries), tariffs and policies, finance reconciliation, support cases, audit log.

## Key journeys

### Book an intercity trip (passenger, target under 90 seconds)

1. Home: enter from, to, date. One field per step on mobile, one row on web.
2. Results: pick a trip card. Price shown is the final price for the chosen fare brand.
3. Seat map: pick seats. Hold countdown starts; leaving keeps the hold until it expires.
4. Passenger details: saved travellers fill in one tap; new names follow the identity document rules.
5. Checkout: review the breakdown, pay from wallet. The button reads the exact amount.
6. Ticket: issued instantly, saved offline, added to Trips.

### Ride a shuttle line (rider)

1. Tap Scan on Home or the shuttle tab, scan the sticker inside the vehicle.
2. The app checks location and nearby proximity to the driver's phone, confirms the line and charges the first segment.
3. Live ride screen shows current station, next station and the fare to continue.
4. Before each station: if the balance will not cover the next segment, a banner warns and offers top-up. Continuing creates an interest-free outstanding fare.
5. Ride ends when the rider moves away from the vehicle or scans the station code; the receipt lists every segment.

### Board passengers (driver)

1. Today shows the assigned trip with a single "Start boarding" action.
2. Scan each ticket: a full-width result card answers in under one second (valid, wrong trip, already used), with sound and haptic feedback.
3. Manifest count updates; offline scans queue and sync.
4. "Depart" closes boarding and sends the final manifest.

### Publish a trip (carrier clerk)

1. Trips, New trip from a pattern: line, date, vehicle, crew.
2. System checks licences, vehicle documents and crew assignments; problems appear as inline banners with a fix link.
3. Review fares (from the approved tariff) and publish.

## Patterns

- **Forms:** labels above fields, helper text below, errors replace helper text. Validate on blur, never on each keystroke. Group long forms into steps with a progress indicator.
- **Tables (portals):** sticky header in `surface-container-low`, row actions in an overflow menu, status chips in their own column, numbers aligned to the end and tabular.
- **Search:** results update on submit on mobile, live on web; filters as chips with a count.
- **Confirmation:** destructive or financial actions open a dialog that restates the object and amount: "Cancel booking 7Q4K2P and refund SYP 85,000 to your wallet?"
- **Feedback:** snackbars for completed actions, banners for conditions that persist, dialogs only when a decision is needed.
- **Offline:** a quiet `tertiary` banner at the top: "You're offline. Tickets and scans still work."
- **Permissions:** explain before asking. Location: "Masslak uses your location to charge the right fare and protect your wallet if you forget to scan at your stop."
