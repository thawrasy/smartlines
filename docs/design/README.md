# Masslak design

- `system/`: the Masslak design system (visual identity, Material 3 tokens in `tokens.json`, brand book `README.md`, user experience guide `Experience.md`, platform rules `Platforms.md`, React components in `components/`, logos and icons in `assets/`).
  Live version: https://claude.ai/artifact/QYFnZxJJatkay9rwqJVDXL
- `prototype/`: source of the portal prototype canvas (mobile passenger flow, shuttle, driver app, public website, carrier, agency and regulator portals).
  Live version: https://claude.ai/artifact/FLzQVmcGudQwCcx7KNp5Z7

- `STATION_SCREENS_REVIEW.md`: the design review of the boarding-station screens (October 2026), its findings, what was changed and the owner's decisions.
- `STATION_USER_TESTING.md`: the protocol for testing those screens with real users at the pilot station.
- `TRIP_NUMBERS.md`: the short trip number passengers read ("DC 1201") and the trip reference staff use; four digits, odd outbound and even return, the legs of a vehicle's day and the return on the same vehicle (owner's decisions, 1114 and 1119).
- `REGULAR_TRIPS.md`: regular trips the carrier defines (every day, on days of the week or of the month, with or without an end) under one number, their requests and approval stages, number blocks and settings (owner's decision, 1117).
- `STATION_DISPLAY_SCREENS.md`: separate Departures and Arrivals screens at a station: the kinds the platform allows, the screens the station's administration registers and distributes, their links, last seen, and the board of one kind (owner's decision, 1120).
- `JOURNEYS.md`: one way, round trip and several places booked together, direct trips or trips with stops, and tourism groups booked by agencies as one journey (owner's request, 1121).
- `ADMIN_GEOGRAPHY.md`: the country's administrative geography from the United Nations' P-code file (governorates, districts, sub-districts, communities, neighbourhoods), how it is loaded and how a place is opened for routes (owner's request, 1124).
- `CHARTER.md`: carriers hire out a vehicle apart from their trips or a scheduled trip whole or in blocks of seats, to tourism companies and, by special request, to travellers, on their own terms; requests are priced, paid into escrow, the seats held, and the carrier paid when done (owner's request, 1123).
- `CONNECTIONS.md`: connections across carriers where no trip runs direct (Daraa to Aleppo through Damascus), the risks the traveller accepts, each carrier's policy for a missed trip, and a booking changed to another trip under that policy or the fare's rules (owner's request, 1130).
- `FREIGHT_TRANSPORT.md`: trucks carrying goods and containers inside Syria, to and from the port, in transit and across borders: bills of lading, house bills and containers, consignments, the truck owner's prices, trucks and trailers, transport invoices per bill or container, and consignment notes and TCNs issued by the platform (owner's request, 1131).
- `TRIP_CHANGES.md`: changes to a scheduled trip that keep its number: another vehicle before or during the trip, a moved departure, passengers moved to another trip before cancelling it, each with a reason from the platform's list; every passenger told, those unreachable listed for a call (owner's request N42, 1148).
- `SIGNIN_DOORS.md`: two sign-in doors, individuals by e-mail or mobile and businesses by company number and username, with temporary passwords changed at the first sign-in (owner's request N16, 1150).
- `SECOND_FACTOR.md`: second-factor codes by e-mail, Telegram (linked by a one-time bot link) and WhatsApp besides the authenticator app and recovery codes; text messages closed until a provider is contracted (owner's request N36, 1151).
- `TRAVELLERS_AND_GUESTS.md`: the traveller "Me" filled from the account, saved travellers kept with consent and an encrypted document, and booking without an account by an e-mail code with a later claim (owner's request N18, 1153).
- `USERS_AND_ROLES.md`: one users-and-roles section in every portal, ready roles, nobody gives what they do not hold, time-limited per-user exceptions approved by a second person (owner's request N1, 1154).
- `INTEGRATION_REQUESTS.md`: companies request programmatic connections; platform security builds and another officer approves the client; the company takes its key once (owner's request N2, 1155).
- `BANKS_AND_INSURERS.md`: registries of banks, branches and insurers kept by the platform with a second-person review; company bank accounts picked from them with a verification status; insurance policies pick their insurer (owner's requests N6 and N9, 1156).
- `COMPANY_KYC.md`: the know-your-customer file of each company on the platform: the form and the standards it follows, its review stages, risk rules, encrypted values, settings and screens (owner's request, 1118).

The web frontend (`frontend/src/theme.css`) uses the same colour roles and radii as `system/tokens.json`.
