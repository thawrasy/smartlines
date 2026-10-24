# Truck transport of goods and containers

Owner's request, October 2026. Built in migration 1131 (`db/schema/1131_freight_transport.sql`) and the module
`backend/app/modules/freight/api.py`. It is part of phase 8, module E33, and is opened by the freight switch
(`features.freight`). The website and the apps are not changed yet. The owner asked to finish the core and the
documents first, then change the website once and as a whole.

## What the owner asked

Trucks carry goods and containers on these routes:
- inside Syria;
- from the port into Syria, and from Syria to the port;
- in transit from the port out of Syria;
- from abroad into Syria or to the port.

For containers leaving the port, the platform records:
- the container number and the shipping line;
- the customs release number;
- the bill of lading number and the number of containers on it;
- the freight forwarder's house bill (in-house BL).

The truck owner, a company or a person, sets the transport price. An invoice covers either the whole bill of lading
with all its containers, or one container.

The platform also issues a consignment document holding all the shipment's data:
- the seller and the buyer;
- where the load is picked up and where it is delivered;
- the commercial invoices of the shipment;
- the export approval and its number;
- the port of arrival or the border crossing, and the country of arrival;
- each container's number, with its truck and the truck's details;
- the kind of goods.

A shipment inside Syria takes a TCN (Truck Consignment Note). One TCN covers one consignment, or several consignments
with every trailer in one statement.

## The records

| Record | Table | What it holds |
|---|---|---|
| Shipping line | `frt.shipping_line` | Code (SCAC or the line's usual code), name and country. Seeded with ten lines that call at Syrian ports. |
| Bill of lading | `frt.bill_of_lading` | Line and number (unique per company and line), direction (import, export or transit), vessel and voyage, ports (UN/LOCODE) and the Syrian port, consignee and notify party, the containers declared, the customs release number and date, and the status. A bill is released only with its release number. |
| House bill | `frt.house_bill` | The forwarder's in-house bill under the master bill. Its containers are a subset of the master bill's. |
| Bill container | `frt.bl_container` | Container number with a valid ISO 6346 check digit, ISO size and type code, seal, weight, the depot for the empty return, and the end of the free days. A bill never lists more containers than it declares (`BL_CONTAINER_COUNT`). |
| Consignment | `frt.consignment` | Number `CS-YYYY-NNNNNNN`; route kind; load type; seller and buyer (name, address, country, tax number, platform party when known); origin and destination (country, city, station or address); port, exit and entry border, port abroad; bill and house bill; export permit, customs declaration, release and TIR carnet numbers; incoterm and who pays the freight; the goods (category, HS code, packages, weights, volume, UN number and ADR class, temperatures, declared value). |
| Commercial invoice | `frt.consignment_invoice` | The seller's invoices that travel with the goods. |
| Consignment container | `frt.consignment_container` | A container of the consignment. One taken from its bill keeps the bill's size and seal. One not on the bill is refused (`CONTAINER_NOT_ON_BL`). |
| Rate | `frt.rate_card` | The truck owner's price on a lane: from a city or station, to a city, station or country. Units: per 20, 40 or 45 ft container, per truck, per ton or per bill. The rate also holds whether the empty return is included, the free waiting hours, the charge per extra day, and the dates it is valid. There is one active price per lane and unit at a time (`rate_card_one_price`). |
| Truck movement | `frt.truck_movement` | One truck carrying part or all of a consignment. It holds the truck, the trailer (from the fleet or hired, by plate and length) and the driver, each copied as they were. It also holds the price, its currency and the rate used, the steps taken, and the proof of delivery. A truck and a trailer are each on one active movement at a time. The truck and trailer must be the carrier's own (`TRUCK_NOT_OWNED`). |
| Movement container | `frt.movement_container` | The containers on a truck: of its consignment, on one active truck only, and within the trailer's length (`TRAILER_TOO_SHORT`). A 40 ft trailer takes one 40 ft or two 20 ft containers; a 45 ft container needs a 45 ft trailer. |
| Movement event | `frt.movement_event` | Each step with its station, note and user. Steps are appended, never changed. |
| Transport invoice | `frt.transport_invoice`, `frt.transport_invoice_line` | Number `<carrier code>-TI-YYYY-NNNNNN`. It covers the whole bill, one container or the whole consignment, and is billed to whoever pays the freight. It is frozen once issued: only paid or void (with a reason) may change. |
| Document | `frt.transport_document`, `frt.document_consignment`, `frt.document_vehicle` | A consignment note (`MCN-YYYY-NNNNNNN`) or a TCN (`TCN-YYYY-NNNNNNN`). Each is a frozen snapshot with its SHA-256 and a ten-character verification code. A new version is numbered `<no>/<version>` and marks the old one superseded. |

### The route kinds

| Kind | From | To | Papers the document needs |
|---|---|---|---|
| `DOMESTIC` | Syria | Syria | origin, destination |
| `PORT_IMPORT` | Syrian port | Syria | port; the customs release when it has a bill of lading |
| `PORT_EXPORT` | Syria | Syrian port | port, export permit |
| `EXPORT` | Syria | abroad | exit border, export permit, commercial invoices |
| `IMPORT` | abroad | Syria | entry border, commercial invoices |
| `TRANSIT_PORT_OUT` | Syrian port | abroad | port, exit border, commercial invoices |
| `TRANSIT_IN_PORT` | abroad | Syrian port | entry border, port, commercial invoices |
| `TRANSIT_LAND` | abroad | abroad | entry and exit borders, commercial invoices |

The countries must match the kind (`consignment_countries_ck`). A TCN is for the three domestic kinds only. An
international shipment takes a consignment note.

## How it runs

1. **Bill of lading.** The carrier or forwarder registers the bill: line, number, port, containers declared. It then
   adds the house bills and the containers. The customs release number is recorded when customs releases the goods.
2. **Consignment.** The seller, buyer, route, papers and goods are recorded. The containers are taken from the bill
   (or its house bill), or listed for goods not from the port.
3. **Trucks.** The truck owner puts a truck on the consignment, with its trailer, driver and containers. The price is
   given, or taken from the owner's rate: per container of the rate's size, per truck, or per ton.
4. **Document.** `frt.document_gaps` lists what is still missing. Issuing is refused until it is complete
   (`DOCUMENT_INCOMPLETE` with the list). A TCN takes up to 50 consignments in one statement, with every truck and
   trailer. Issuing confirms the consignments. An issued document is never changed: it is voided with a reason, or
   replaced by a new version.
5. **On the road.** Each truck goes through its steps: assigned, loading, in transit, at the border, delivered. A step
   out of order is refused (`MOVEMENT_STEP`). Delivery names who received the goods (`POD_REQUIRED`). The containers
   and the bill's containers follow the truck. The consignment is delivered when every truck is.
6. **Invoice.** The truck owner invoices the whole bill, one container or the consignment. A truck's price is split
   across its containers, and the last container takes the remainder. A container is never invoiced twice
   (`ALREADY_INVOICED`); a voided invoice frees it. Loose cargo is invoiced per truck.
7. **Checking.** Anyone with the document number and its code checks it at
   `/api/public/freight/documents/{doc_no}?code=`. The check shows the status, the issuer, the hash, the consignments,
   trucks and containers, and the version that replaced it.

## Who sees what

| Who | Sees |
|---|---|
| The company that registered a bill or consignment | All of it |
| A truck owner with a truck on a consignment | That consignment, its bill and its documents |
| The seller or buyer, when they are platform parties | Their consignments |
| The platform | Everything |
| Anyone | Shipping lines, active rates, a document they hold the code of |

Rows are isolated in the database (`frt.can_see_consignment`, `frt.can_see_bill`, `frt.can_see_document`). Writes
belong to the owning company. Invoices, documents and events are read-only to the application; they are written only
by the database's own functions.

## Interfaces

All carrier routes take the OPERATOR portal and the company permission `freight.operate`, which owners and carrier
operations hold.

| Route | What |
|---|---|
| `GET/POST /api/carrier/freight/bills`, `GET /bills/{uid}` | Bills of lading |
| `POST /bills/{uid}/house-bills`, `/bills/{uid}/containers`, `/bills/{uid}/release` | House bills, containers, customs release |
| `GET/POST /api/carrier/freight/consignments`, `GET /consignments/{uid}` | Consignments, with containers, trucks, documents and what is missing |
| `POST /consignments/{uid}/containers`, `/consignments/{uid}/invoices` | Containers (from the bill or listed), commercial invoices |
| `POST /consignments/{uid}/movements`, `POST /movements/{uid}/status` | A truck on the consignment; its steps |
| `GET/POST /api/carrier/freight/rates`, `POST /rates/{uid}/archive` | The truck owner's prices |
| `GET/POST /api/carrier/freight/invoices`, `POST /invoices/{uid}/void`, `/invoices/{uid}/paid` | Transport invoices |
| `GET/POST /api/carrier/freight/documents`, `GET /documents/{doc_no}`, `POST /documents/{doc_no}/void` | Consignment notes and TCNs |
| `GET /api/public/freight/shipping-lines`, `/rates`, `/documents/{doc_no}?code=` | Anyone |

## Points the owner did not mention: recommendations

These are open for the owner's decision. The core leaves room for each.

1. **The consignment note follows the CMR layout.** For a shipment that crosses a border, the note should carry the
   boxes of the international road consignment note (CMR), so customs and carriers abroad can read it. The snapshot
   already holds every field. The printed layout comes with the website. Legal advice should confirm which form Syrian
   customs and the neighbouring countries accept.
2. **Container waiting and return charges.** The shipping line charges for keeping a container past its free days
   (demurrage and detention), and the truck owner charges for waiting. The database already records the free days and
   the rate's waiting terms. Recommendation: add the empty return as a movement of its own, and waiting charges as
   invoice lines, in the next step.
3. **Payment through the wallet and escrow.** Transport invoices are records today: the truck owner marks them paid.
   Recommendation: let the payer pay the invoice from the wallet, with the money held in escrow until proof of
   delivery, as charter is paid. The platform's commission would be taken at that point.
4. **The national e-invoice.** A transport invoice should also go through the platform's e-invoice chain (numbered,
   chained and signed), like ticket invoices, once the tax treatment of freight is set.
5. **Weight and axle loads.** Recommendation: refuse a movement whose load exceeds the truck's gross vehicle weight
   (`fleet.truck_unit`), with a weighbridge ticket number at the port gate.
6. **Dangerous goods.** The database already refuses a document when an ADR load sits on a truck without hazmat
   approval. Recommendation: also require the driver's ADR certificate (`fleet.crew_profile.hazmat_certified`).
7. **Tracking.** A movement in transit should take its positions from the telemetry cluster, so that the shipper
   sees the truck and the platform sees a truck standing too long at a border.
8. **The shipper's side.** Sellers and buyers who are platform parties already see their consignments in the
   database. Recommendation: one screen for them, and a link from the existing freight marketplace (a load posted,
   bids, an award) to a consignment, so an award becomes a consignment with its truck.
9. **Customs and port systems.** The customs declaration and release numbers are entered by hand today. When the
   port and customs open an interface, they should be read from it.

## Tests

- **Database** (`db/tests/run_tests.sql`, "Truck transport (1131)"), 30 checks:
  - container numbers and their check digit;
  - the bill's container count and its release;
  - a consignment's countries and containers taken from the bill;
  - what a document lacks;
  - a truck on one active movement, and only the carrier's own;
  - a TCN refused before the release, then issued, frozen, checked and versioned;
  - an export refused a TCN;
  - invoices per container and per bill, never twice, frozen;
  - truck steps and proof of delivery;
  - one price per lane;
  - isolation between carriers;
  - a passenger checking a document.
- **API** (`backend/tests/test_freight_transport.py`):
  - from the port to Damascus end to end: bill, house bill, containers, consignment, rate, truck and hired trailer,
    TCN, public check, invoices, steps and delivery, another carrier and a passenger kept out;
  - an export that lacks its papers.
