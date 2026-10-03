"""Data flow diagrams (Gane & Sarson notation) of Masslak, derived from the study v2.5, rendered with Graphviz."""
import os, subprocess, sys, textwrap
from model import STORE, PROCESSES

OUT = "out"; os.makedirs(OUT, exist_ok=True)
FONT = "Liberation Sans"
NAVY, PFILL, LINE, EXT_FILL, EXT_LINE = "#1F3864", "#EAF1FB", "#4F5D6E", "#FFF6DA", "#7A6327"
PNAME = dict(PROCESSES)


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def wrap(t, n):
    return "<BR/>".join(esc(x) for x in textwrap.wrap(t, n))


def ext_node(nid, label):
    """External entity; a duplicate copy (id containing '#') is drawn with a double border."""
    dup = ", peripheries=2" if "#" in nid else ""
    return (f'"{nid}" [shape=box, style="filled", fillcolor="{EXT_FILL}", color="{EXT_LINE}", penwidth=1.6{dup}, '
            f'margin="0.14,0.08", label=<<B>{wrap(label, 18)}</B>>, fontsize=11];')


def proc_node(nid, pid, label, ref=False):
    style = 'rounded,filled,dashed' if ref else 'rounded,filled'
    fill = "#F4F6F8" if ref else PFILL
    note = '<TR><TD><FONT POINT-SIZE="8" COLOR="#6B7785">(see its own diagram)</FONT></TD></TR>' if ref else ""
    lab = (f'<<TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="3">'
           f'<TR><TD><FONT POINT-SIZE="9" COLOR="#5B6B7F"><B>{pid}</B></FONT></TD></TR><HR/>'
           f'<TR><TD>{wrap(label, 20)}</TD></TR>{note}</TABLE>>')
    return (f'"{nid}" [shape=box, style="{style}", fillcolor="{fill}", color="{NAVY}", penwidth=1.5, '
            f'margin="0.08,0.04", label={lab}, fontsize=11];')


def store_node(nid, sid, duplicate=False):
    """Gane & Sarson data store: open at the right; a duplicate symbol carries an extra bar."""
    name = STORE[sid][1]
    dup = '<TD SIDES="TBL" WIDTH="4" BGCOLOR="#E3E8EE"></TD>' if duplicate else ""
    lab = (f'<<TABLE BORDER="0" CELLBORDER="1" CELLSPACING="0" CELLPADDING="5" COLOR="#5B6B7F">'
           f'<TR>{dup}<TD SIDES="TBL" BGCOLOR="#E3E8EE"><B>{sid}</B></TD><TD SIDES="TB" BGCOLOR="#F7F8FA" ALIGN="LEFT">{wrap(name, 22)}</TD></TR></TABLE>>')
    return f'"{nid}" [shape=none, margin=0, label={lab}, fontsize=10.5];'


def render(name, title, body, rankdir="TB", extra="", engine="dot"):
    layout = 'layout=neato, splines=true, esep="+14", ' if engine == "neato" else ""
    dot = (f'digraph G {{\n graph [{layout}rankdir={rankdir}, fontname="{FONT}", splines=spline, nodesep=0.35, ranksep=0.75, '
           f'pad=0.35, {"label=<<B>" + esc(title) + "</B>>, labelloc=t, " if title else ""}fontsize=17, {extra}];\n'
           f' node [fontname="{FONT}"]; edge [fontname="{FONT}", fontsize=9, color="{LINE}", fontcolor="#33404D", arrowsize=0.75, penwidth=1.1];\n'
           + body + "\n}")
    open(f"{OUT}/{name}.dot", "w").write(dot)
    for fmt, extra_args in (("png", ["-Gdpi=170"]), ("svg", [])):
        r = subprocess.run([engine, f"-T{fmt}", *extra_args, "-o", f"{OUT}/{name}.{fmt}", f"{OUT}/{name}.dot"], capture_output=True, text=True)
        if r.returncode:
            sys.exit(f"{name}: {r.stderr}")
    print(name, "ok")


XLABEL = False   # set while building neato diagrams: labels placed after routing to avoid overlaps


def flow(a, b, label, back=False, constraint=True):
    attrs = [f'{"xlabel" if XLABEL else "label"}=<{wrap(label, 24)}>']
    if back:
        attrs.append("dir=back")
    if not constraint:
        attrs.append("constraint=false")
    return f'"{a}" -> "{b}" [{", ".join(attrs)}];'


# ---------------------------------------------------------------- generic level diagram
def level(spec):
    """spec: externals [(id,label)], procs [(id, pid, label)], refs [(id, pid)], stores [(node_id, store_id)], flows [(a,b,label)]."""
    L = []
    for nid, label in spec["externals"]:
        L.append(ext_node(nid, label))
    for nid, pid, label in spec["procs"]:
        L.append(proc_node(nid, pid, label))
    for nid, pid in spec.get("refs", []):
        L.append(proc_node(nid, pid, PNAME[pid.lstrip("P")], ref=True))
    seen = {}
    store_nodes = set()
    for nid, sid in spec["stores"]:
        L.append(store_node(nid, sid, duplicate=sid in seen))
        seen[sid] = True; store_nodes.add(nid)
    for f in spec["flows"]:
        a, b, label = f[:3]
        opts = dict(f[3]) if len(f) > 3 else {}
        # reads from a store do not drive the layout; writes place the store below its writer
        if a in store_nodes:
            opts.setdefault("constraint", False)
        L.append(flow(a, b, label, **opts))
    if "pos" not in spec:
        for group in spec.get("same_rank", []):
            L.append("{ rank=same; " + " ".join(f'"{n}";' for n in group) + " }")
    for nid, (x, y) in spec.get("pos", {}).items():
        L.append(f'"{nid}" [pos="{x},{y}!"];')
    return "\n".join(" " + x for x in L)


def render_level(name, title, spec, extra=""):
    global XLABEL
    if "pos" in spec:
        XLABEL = True
        body = level(spec)
        XLABEL = False
        missing = [n for n, *_ in spec["externals"] + spec["procs"] + spec.get("refs", []) + spec["stores"] if n not in spec["pos"]]
        assert not missing, (name, missing)
        render(name, title, body, extra="forcelabels=true, " + extra, engine="neato")
        return
    if False:
        missing = [n for n, *_ in spec["externals"] + spec["procs"] + spec.get("refs", []) + spec["stores"] if n not in spec["pos"]]
        assert not missing, (name, missing)
        render(name, title, level(spec), extra=extra, engine="neato")
    else:
        render(name, title, level(spec), extra=extra)


# ---------------------------------------------------------------- context diagram
CONTEXT_LEFT = [
    ("passenger", "Passengers and visitors", "search criteria, booking and passenger data, top-ups, boarding and station scans, ratings and complaints", "trip offers, tickets and rotating QR, receipts, refunds, notifications"),
    ("carrier", "Carriers (owners and staff)", "company and documents, fleet, crews, routes and tariffs, trip schedules", "manifests, sales and account statements, settlements, alerts"),
    ("driver", "Drivers and hosts", "live location, boarding scans, stop events, cash sales, SOS, presence token", "assigned trips, passenger lists, boarding results, authority orders"),
    ("shipper", "Shippers and recipients", "shipment orders, payments, delivery instructions", "labels, tracking events, delivery windows, proof of delivery"),
    ("logistics", "Courier companies, hubs, couriers and access points", "check-in, sorting and loading scans, proof of delivery, attempt reasons", "routes, assignments, loading lists, custody records"),
    ("partners", "Service partners (fuel, rest stops, merchants, loyalty)", "partner sales, redemptions, point conversions", "authorizations, receipts, settlement statements"),
    ("agencies", "Agencies and intermediary platforms", "searches and bookings through the portal or API", "availability, prices, tickets, commission statements"),
]
CONTEXT_RIGHT = [
    ("staff", "Platform staff (administration, finance, support, compliance)", "approvals, policies and tariffs, case decisions, compensation approvals", "dashboards, reconciliation reports, queues and alerts"),
    ("regulator", "Regulator", "delegated policies", "aggregated governance, tracking and alert indicators"),
    ("authorities", "Security, government and border authorities", "screening results, orders, official data requests, clearances, crossing events", "screening requests, manifests, incident data, encrypted responses"),
    ("bank", "Payment gateways and bank", "signed payment notifications, bank statements", "payment requests, payout and withdrawal orders"),
    ("tax", "Tax authority", "clearance and reporting responses", "e-invoices and notes"),
    ("erp", "Accounting / ERP and CRM systems", "acknowledgements, case updates", "journal entries, invoices, case events"),
    ("global", "Global courier companies", "pre-alerts, creation orders", "tracking updates, proof of delivery"),
    ("notify", "Notification providers", "delivery receipts", "SMS, push and e-mail messages"),
]


def context():
    L = [proc_node("P0", "0", "Masslak national transport and shipping platform").replace("fontsize=11", "fontsize=14")
         .replace('margin="0.08,0.04"', 'margin="0.3,0.3", width=3.2, height=2.2')]
    for nid, label, inflow, outflow in CONTEXT_LEFT:
        L.append(ext_node(nid, label))
        L.append(flow(nid, "P0", inflow))
        L.append(flow(nid, "P0", outflow, back=True))
    for nid, label, inflow, outflow in CONTEXT_RIGHT:
        L.append(ext_node(nid, label))
        L.append(flow("P0", nid, outflow))
        L.append(flow("P0", nid, inflow, back=True))
    render("DFD-0", "DFD-0 Context diagram", "\n".join(" " + x for x in L), rankdir="LR", extra="ranksep=2.2, nodesep=0.25")


# ---------------------------------------------------------------- level 1
LEVEL1A = dict(
    externals=[("pax", "Passenger"), ("carrier", "Carrier"), ("driver", "Driver / host"), ("bank", "Payment gateways and bank"),
               ("pax#2", "Passenger"), ("carrier#2", "Carrier")],
    procs=[("p1", "P1", PNAME["1"]), ("p2", "P2", PNAME["2"]), ("p3", "P3", PNAME["3"]), ("p4", "P4", PNAME["4"]),
           ("p5", "P5", PNAME["5"]), ("p6", "P6", PNAME["6"]), ("p7", "P7", PNAME["7"]), ("p8", "P8", PNAME["8"])],
    refs=[("p10", "P10"), ("p12", "P12")],
    stores=[("d1", "D1"), ("d2", "D2"), ("d3", "D3"), ("d4", "D4"), ("d5", "D5"), ("d6", "D6"), ("d7", "D7"),
            ("d8", "D8"), ("d9", "D9"), ("d10", "D10"), ("d4b", "D4")],
    pos={"carrier": (1.5, 11.2), "pax": (8.5, 11.2), "driver": (15.5, 11.2),
         "p2": (2.8, 9.3), "p1": (5.9, 9.7), "p4": (8.5, 8.6), "p8": (12.2, 9.4), "p7": (15.5, 9.0),
         "d2": (3.4, 7.7), "d3": (1.5, 7.8), "d4": (5.2, 7.0), "d1": (6.4, 8.3), "d4b": (10.4, 10.6),
         "d10": (11.4, 7.6), "d9": (16.0, 7.3), "d6": (13.0, 6.2),
         "p3": (-0.6, 6.0), "d5": (2.4, 4.4), "p5": (6.8, 5.9), "d7": (6.0, 4.5),
         "p10": (13.2, 4.4), "p6": (9.6, 4.1), "pax#2": (7.0, 3.4), "carrier#2": (12.0, 2.6),
         "d8": (7.6, 1.8), "bank": (9.6, 1.5), "p12": (11.6, 0.9)},
    same_rank=[["carrier", "pax", "driver"], ["p1", "p2", "p3"], ["p4", "p7", "p8"], ["p5", "p6"]],
    flows=[("pax", "p1", "registration, credentials, KYC data"), ("p1", "d1", "users, sessions, permission state"),
           ("carrier", "p2", "company, documents, vehicles, crews, routes, tariffs"), ("p2", "d2", "parties, documents"),
           ("p2", "d3", "vehicles, licenses, crews"), ("p2", "d4", "stations, routes, tariffs"),
           ("carrier", "p3", "trip patterns, assignments"), ("d4", "p3", "routes, fare ladders"), ("d3", "p3", "vehicles, crews"),
           ("p3", "d5", "trips, stops, seat segments"),
           ("pax", "p4", "search, seats, passenger data"), ("d5", "p4", "availability, seat map"), ("p4", "d5", "holds, sold seats"),
           ("p4", "p5", "pricing request"), ("d7", "p5", "fare brands, tax and commission rules"), ("p5", "d7", "price snapshot, allocation"),
           ("p5", "p4", "priced booking"), ("p4", "p10", "screening request"), ("p10", "p4", "ALLOW / REVIEW / DENY"),
           ("p4", "p6", "payment request"), ("p6", "p4", "payment confirmed"), ("p4", "d6", "bookings, tickets"),
           ("p4", "pax", "tickets, rotating QR", {"constraint": False}),
           ("pax#2", "p6", "top-up"), ("p6", "bank", "payment requests, payout orders"), ("bank", "p6", "payment notifications, statements", {"constraint": False}),
           ("p6", "d8", "ledger entries"), ("p6", "carrier#2", "settlements, statements"),
           ("driver", "p7", "location, boarding scans, stop events, cash sales"), ("d6", "p7", "tickets, manifest"),
           ("p7", "d6", "boarding events"), ("p7", "d9", "positions, stop events, alerts"), ("p7", "p6", "trip completed"),
           ("p7", "p10", "manifest, SOS"),
           ("pax", "p8", "sticker scan, presence signals, station QR"), ("driver", "p8", "presence token"),
           ("d4b", "p8", "line fare table"), ("d9", "p8", "vehicle position, departures"), ("p8", "d10", "rides, segment charges"),
           ("p8", "p6", "segment charges"), ("p6", "p12", "financial events")],
)

LEVEL1B = dict(
    externals=[("cust", "Customers (passengers, shippers, recipients)"), ("logistics", "Logistics operators"),
               ("global", "Global courier companies"), ("partners", "Service partners"), ("agencies", "Agencies and intermediary platforms"),
               ("auth", "Security, government and border authorities"), ("regulator", "Regulator"), ("staff", "Platform staff"),
               ("tax", "Tax authority"), ("erp", "Accounting / ERP and CRM"), ("notify", "Notification providers")],
    procs=[("p9", "P9", PNAME["9"]), ("p10", "P10", PNAME["10"]), ("p11", "P11", PNAME["11"]),
           ("p12", "P12", PNAME["12"]), ("p13", "P13", PNAME["13"]), ("p14", "P14", PNAME["14"])],
    refs=[("p4", "P4"), ("p6", "P6"), ("p7", "P7")],
    stores=[("d11", "D11"), ("d12", "D12"), ("d13", "D13"), ("d14", "D14"), ("d15", "D15"), ("d17", "D17"), ("d16", "D16")],
    flows=[("cust", "p9", "shipment orders, delivery instructions"), ("p9", "cust", "labels, tracking, proof of delivery", {"constraint": False}),
           ("logistics", "p9", "scans, proof of delivery, attempts"), ("p9", "logistics", "routes, assignments", {"constraint": False}),
           ("global", "p9", "pre-alerts, orders"), ("p9", "global", "tracking updates, POD", {"constraint": False}),
           ("p9", "d11", "shipments, events, custody"), ("p9", "p6", "fares, COD"),
           ("p4", "p10", "screening requests"), ("p7", "p10", "manifests, SOS"), ("auth", "p10", "results, orders, data requests"),
           ("p10", "auth", "screening requests, manifests, incident data", {"constraint": False}), ("p10", "d12", "screening, orders, requests"),
           ("p10", "p7", "stop / divert orders", {"constraint": False}), ("p10", "regulator", "governance indicators"), ("p10", "d16", "access logs"),
           ("partners", "p11", "partner sales, redemptions"), ("p11", "partners", "authorizations, settlements", {"constraint": False}),
           ("p11", "d13", "sales, points ledger"), ("p11", "p6", "partner charges, netting"),
           ("p6", "p12", "financial events"), ("p12", "d14", "invoices, journal entries"), ("p12", "tax", "e-invoices"),
           ("tax", "p12", "clearance responses", {"constraint": False}), ("p12", "erp", "journal entries, invoices"), ("p12", "cust", "e-invoices", {"constraint": False}),
           ("cust", "p13", "complaints, questions"), ("p13", "cust", "responses, notifications", {"constraint": False}), ("p13", "d15", "cases, notification log"),
           ("staff", "p13", "case decisions"), ("p13", "p6", "approved compensation"), ("p13", "erp", "case events"), ("p13", "notify", "messages"),
           ("agencies", "p14", "searches, bookings (API)"), ("p14", "agencies", "availability, statements", {"constraint": False}),
           ("p14", "d17", "quotas, commissions"), ("p14", "p4", "channel bookings"), ("staff", "p10", "authority policies")],
)

# ---------------------------------------------------------------- level 2
L2 = {}
L2["DFD-4"] = ("DFD-4 Level 2: P4 Book and ticket", dict(
    externals=[("pax", "Passenger"), ("pax#2", "Passenger"), ("auth", "Security authorities")],
    procs=[("a1", "4.1", "Search trips"), ("a2", "4.2", "Hold seats"), ("a3", "4.3", "Capture passenger data"),
           ("a4", "4.4", "Screen passengers"), ("a5", "4.5", "Price the booking"), ("a6", "4.6", "Collect payment"),
           ("a7", "4.7", "Confirm and issue tickets"), ("a8", "4.8", "Cancel and refund")],
    refs=[("p6", "P6"), ("p12", "P12")],
    stores=[("d4", "D4"), ("d5", "D5"), ("d6", "D6"), ("d7", "D7"), ("d12", "D12"), ("d5r", "D5")],
    flows=[("pax", "a1", "origin, destination, date, passengers"), ("d5r", "a1", "trips, availability"), ("d4", "a1", "stations, stops"),
           ("a1", "pax", "trip offers", {"constraint": False}), ("pax", "a2", "pair and seats"), ("a2", "d5", "seat locks (10 min)"),
           ("a2", "a3", "hold token"), ("pax", "a3", "names as on ID, document, nationality"), ("a3", "a4", "passenger list"),
           ("a4", "auth", "screening request"), ("auth", "a4", "ALLOW / REVIEW / DENY", {"constraint": False}), ("a4", "d12", "screening records"),
           ("a4", "a5", "cleared passengers"), ("d4", "a5", "fare ladder"), ("d7", "a5", "fare brands, tax, commission rules"),
           ("a5", "d7", "price snapshot, allocation lines"), ("a5", "a6", "amount due"), ("a6", "p6", "payment request + idempotency key"),
           ("p6", "a6", "funds in escrow", {"constraint": False}), ("a6", "a7", "paid booking"), ("a7", "d5", "seats committed"),
           ("a7", "d6", "booking, passengers, tickets"), ("a7", "pax#2", "tickets, rotating QR"), ("a7", "p12", "sale for e-invoice"),
           ("pax#2", "a8", "cancellation request", {"constraint": False}), ("d6", "a8", "booking, fare rules"), ("a8", "d6", "cancelled tickets"),
           ("a8", "d5", "released seats"), ("a8", "p6", "refund amount")]))

L2["DFD-6"] = ("DFD-6 Level 2: P6 Manage wallet, payments and settlement", dict(
    externals=[("pax", "Passenger / customer"), ("carrier", "Carrier"), ("bank", "Payment gateways and bank"), ("finance", "Platform finance")],
    procs=[("b1", "6.1", "Top up the wallet"), ("b2", "6.2", "Hold booking funds in escrow"), ("b3", "6.3", "Release funds on completion"),
           ("b4", "6.4", "Refund"), ("b5", "6.5", "Clear carrier cash"), ("b6", "6.6", "Pay out carriers"),
           ("b7", "6.7", "Withdraw customer balance"), ("b8", "6.8", "Reconcile daily")],
    refs=[("p4", "P4"), ("p7", "P7"), ("p12", "P12")],
    stores=[("d8", "D8"), ("d7", "D7"), ("d2", "D2")],
    flows=[("pax", "b1", "top-up request"), ("b1", "bank", "payment request"), ("bank", "b1", "signed payment notification", {"constraint": False}),
           ("b1", "d8", "TOPUP entries"), ("p4", "b2", "payment request"), ("d8", "b2", "wallet balance"), ("b2", "d8", "USER to ESCROW entries"),
           ("b2", "p4", "payment confirmed", {"constraint": False}), ("p7", "b3", "trip completed"), ("d7", "b3", "allocation lines"),
           ("b3", "d8", "ESCROW to carrier, platform, tax entries"), ("p4", "b4", "refund amount"), ("b4", "d8", "ESCROW to USER entries"),
           ("p7", "b5", "cash sales"), ("carrier", "b5", "cash remittance"), ("b5", "d8", "COLLECT clearing"),
           ("d8", "b6", "released payables"), ("d2", "b6", "beneficiary account"), ("b6", "bank", "transfer order"),
           ("b6", "carrier", "payout statement", {"constraint": False}), ("pax", "b7", "withdrawal request"), ("b7", "bank", "transfer order"),
           ("b7", "d8", "withdrawal entries"), ("bank", "b8", "bank statement"), ("d8", "b8", "wallet balances, receivables"),
           ("b8", "finance", "discrepancy alerts"), ("b8", "p12", "daily summary entries")]))

L2["DFD-7"] = ("DFD-7 Level 2: P7 Operate trips (boarding and tracking)", dict(
    externals=[("driver", "Driver / host"), ("carrier", "Carrier"), ("pax", "Passenger")],
    procs=[("c1", "7.1", "Track the trip"), ("c2", "7.2", "Scan boarding codes"), ("c3", "7.3", "Record stop events"),
           ("c4", "7.4", "Raise tracking alerts"), ("c5", "7.5", "Complete the trip")],
    refs=[("p6", "P6"), ("p10", "P10"), ("p11", "P11")],
    stores=[("d5", "D5"), ("d6", "D6"), ("d9", "D9")],
    flows=[("driver", "c1", "position every ~15 s, location state"), ("c1", "d9", "trip positions, tracking state"),
           ("d9", "c4", "last ping, route corridor"), ("c4", "driver", "in-app alert + SMS", {"constraint": False}),
           ("c4", "carrier", "escalation", {"constraint": False}), ("c4", "d9", "tracking alerts"),
           ("pax", "driver", "rotating QR", {"constraint": False}), ("driver", "c2", "scanned code"), ("d6", "c2", "ticket status"),
           ("c2", "d6", "boarding event"), ("c2", "driver", "OK / DUPLICATE / INVALID", {"constraint": False}),
           ("driver", "c3", "arrival, departure"), ("c3", "d5", "actual times, sales closed"), ("c3", "d9", "stop events, delay"),
           ("d6", "p10", "manifest"), ("driver", "p10", "SOS"), ("carrier", "c5", "completion"), ("d5", "c5", "trip status"),
           ("c5", "d5", "COMPLETED"), ("c5", "p6", "release escrow"), ("c5", "p11", "points earned")]))

L2["DFD-8"] = ("DFD-8 Level 2: P8 Operate shuttle rides", dict(
    externals=[("pax", "Shuttle passenger (app)"), ("driver", "Driver phone / vehicle beacon")],
    procs=[("e1", "8.1", "Check location and Bluetooth"), ("e2", "8.2", "Open ride at boarding"), ("e3", "8.3", "Confirm presence"),
           ("e4", "8.4", "Charge segment at departure"), ("e5", "8.5", "Warn and record outstanding"),
           ("e6", "8.6", "Close ride on alighting"), ("e7", "8.7", "Track vehicle capacity")],
    refs=[("p6", "P6")],
    stores=[("d1", "D1"), ("d4", "D4"), ("d9", "D9"), ("d10", "D10")],
    flows=[("pax", "e1", "location and Bluetooth state"), ("e1", "d1", "permission state"), ("e1", "pax", "lock or unlock", {"constraint": False}),
           ("pax", "e2", "vehicle sticker scan"), ("e7", "e2", "capacity status"), ("d4", "e2", "first-station fare"),
           ("e2", "p6", "first charge"), ("e2", "d10", "open ride"), ("driver", "e3", "signed rotating token (BLE)"),
           ("pax", "e3", "proximity, position samples"), ("d9", "e3", "vehicle live position"), ("e3", "d10", "proximity samples"),
           ("e3", "e4", "present at departure"), ("d9", "e4", "departure events"), ("d4", "e4", "segment or band fare"),
           ("e4", "p6", "segment charge"), ("e4", "d10", "segment charges"), ("e4", "e5", "balance shortfall"),
           ("e5", "pax", "low-balance warning", {"constraint": False}), ("e5", "p6", "outstanding amount"),
           ("pax", "e6", "station QR"), ("e3", "e6", "presence lost (90 s, 150 m)"), ("e6", "d10", "closed ride"),
           ("e6", "pax", "receipt with alighting point", {"constraint": False}), ("e2", "e7", "boarding"), ("e6", "e7", "alighting"),
           ("e7", "driver", "counter, capacity alerts", {"constraint": False})]))

L2["DFD-9"] = ("DFD-9 Level 2: P9 Ship and deliver consignments", dict(
    externals=[("shipper", "Shipper"), ("recipient", "Recipient"), ("operator", "Hub / access point operator"),
               ("courier", "Courier"), ("global", "Global courier company")],
    procs=[("f1", "9.1", "Create and price shipment"), ("f2", "9.2", "Accept at station or point"), ("f3", "9.3", "Route and sort"),
           ("f4", "9.4", "Transport on linehaul"), ("f5", "9.5", "Deliver with proof"), ("f6", "9.6", "Manage delivery options"),
           ("f7", "9.7", "Settle fares and COD"), ("f8", "9.8", "Exchange with global partners")],
    refs=[("p6", "P6")],
    stores=[("d7", "D7"), ("d5", "D5"), ("d11", "D11")],
    flows=[("shipper", "f1", "parties, contents, weight, value"), ("d7", "f1", "rate card, surcharges"), ("f1", "p6", "payment or COD"),
           ("f1", "d11", "shipment CREATED"), ("f1", "shipper", "label, tracking number", {"constraint": False}),
           ("operator", "f2", "check-in scan, actual weight"), ("f2", "d11", "ACCEPTED, custody"), ("f2", "f3", "accepted shipment"),
           ("d5", "f3", "trip and load capacity"), ("f3", "d11", "handling units, route"), ("f3", "f4", "loading list"),
           ("operator", "f4", "load and unload scans"), ("f4", "d11", "IN_TRANSIT / ARRIVED"), ("f4", "f5", "arrived shipments"),
           ("f5", "courier", "daily route", {"constraint": False}), ("courier", "f5", "POD, attempt reason"), ("f5", "d11", "DELIVERED or attempt"),
           ("recipient", "f6", "instructions (after OTP)"), ("f6", "f5", "updated instructions"), ("f6", "d11", "option events"),
           ("f6", "recipient", "tracking, delivery window", {"constraint": False}), ("f5", "f7", "delivered with POD"),
           ("f7", "p6", "fare release, COD to sender"), ("global", "f8", "pre-alerts, orders"), ("f8", "d11", "pre-created shipments"),
           ("f8", "global", "status updates, POD", {"constraint": False})]))

L2["DFD-10"] = ("DFD-10 Level 2: P10 Security and compliance hub", dict(
    externals=[("auth", "Security and government authorities"), ("border", "Border systems"), ("compliance", "Compliance officer"),
               ("regulator", "Regulator"), ("driver", "Driver / host")],
    procs=[("g1", "10.1", "Screen persons and vehicles"), ("g2", "10.2", "Submit manifest, obtain clearance"),
           ("g3", "10.3", "Apply authority orders"), ("g4", "10.4", "Handle official data requests"),
           ("g5", "10.5", "Handle SOS and incidents"), ("g6", "10.6", "Exchange border messages"), ("g7", "10.7", "Publish governance indicators")],
    refs=[("p4", "P4")],
    stores=[("d5", "D5"), ("d6", "D6"), ("d9", "D9"), ("d12", "D12"), ("d16", "D16")],
    flows=[("p4", "g1", "screening request"), ("g1", "auth", "query (check)"), ("auth", "g1", "result", {"constraint": False}),
           ("g1", "d12", "screening results"), ("g1", "p4", "decision", {"constraint": False}), ("d6", "g2", "tickets, boarded passengers"),
           ("g2", "auth", "manifest (push)"), ("auth", "g2", "clearance", {"constraint": False}), ("g2", "d5", "clearance status"),
           ("g2", "g6", "manifest versions"), ("g6", "border", "PRE / FINAL_MANIFEST, AMENDMENT"),
           ("border", "g6", "RESPONSE, CROSSING_EVENT", {"constraint": False}), ("g6", "d12", "submissions, discrepancies"),
           ("auth", "g3", "ban, stop, divert orders"), ("g3", "d12", "authority orders"), ("g3", "driver", "order notice", {"constraint": False}),
           ("g3", "d5", "trip and vehicle restrictions"), ("auth", "g4", "request with reference"), ("compliance", "g4", "authority verification"),
           ("d6", "g4", "trip record"), ("d9", "g4", "GPS route"), ("g4", "auth", "encrypted delivery", {"constraint": False}), ("g4", "d16", "access log"),
           ("driver", "g5", "SOS"), ("d9", "g5", "position"), ("g5", "auth", "incident alert", {"constraint": False}), ("g5", "d12", "SOS events"),
           ("d12", "g7", "orders, alerts"), ("d9", "g7", "tracking alerts"), ("g7", "regulator", "aggregated indicators")]))

L2["DFD-11"] = ("DFD-11 Level 2: P11 Partners and loyalty", dict(
    externals=[("driver", "Driver"), ("carrier", "Carrier owner"), ("fuel", "Fuel station attendant"), ("pax", "Passenger"),
               ("rest", "Rest stop / merchant"), ("loyalty", "Loyalty partner")],
    procs=[("h1", "11.1", "Authorize fuel purchase"), ("h2", "11.2", "Record partner sale"), ("h3", "11.3", "Earn points"),
           ("h4", "11.4", "Redeem and convert points"), ("h5", "11.5", "Net and settle partners")],
    refs=[("p6", "P6"), ("p7", "P7")],
    stores=[("d3", "D3"), ("d9", "D9"), ("d13", "D13")],
    flows=[("driver", "h1", "virtual fuel card QR"), ("carrier", "h1", "limits per vehicle, driver, day"), ("d9", "h1", "vehicle location"),
           ("d3", "h1", "vehicle, fuel type, tank"), ("h1", "fuel", "authorization", {"constraint": False}), ("fuel", "h2", "quantity, unit price, amount"),
           ("pax", "h2", "payment QR"), ("rest", "h2", "order total"), ("h2", "d13", "partner sale"), ("h2", "p6", "wallet charge or receivable"),
           ("h2", "h3", "eligible purchase"), ("p7", "h3", "trip completed"), ("h3", "d13", "points ledger"), ("pax", "h4", "redemption request"),
           ("h4", "loyalty", "conversion request"), ("loyalty", "h4", "confirmation", {"constraint": False}), ("h4", "d13", "redemptions"),
           ("d13", "h5", "sales, commissions, redemptions"), ("h5", "p6", "netting and settlement entries"),
           ("h5", "fuel", "settlement statement", {"constraint": False}), ("h5", "rest", "settlement statement", {"constraint": False}),
           ("h5", "carrier", "fuel statement", {"constraint": False})]))

L2["DFD-12"] = ("DFD-12 Level 2: P12 Accounting and e-invoicing", dict(
    externals=[("cust", "Customer (buyer)"), ("tax", "Tax authority"), ("erp", "Accounting / ERP system"),
               ("finance", "Platform finance"), ("officer", "Accounting integration officer")],
    procs=[("k1", "12.1", "Build draft invoice"), ("k2", "12.2", "Finalize and sign"), ("k3", "12.3", "Submit to tax authority"),
           ("k4", "12.4", "Issue credit or debit note"), ("k5", "12.5", "Post journal entries"), ("k6", "12.6", "Synchronize with ERP"),
           ("k7", "12.7", "Reconcile sub-ledger")],
    refs=[("p4", "P4"), ("p6", "P6")],
    stores=[("d2", "D2"), ("d7", "D7"), ("d8", "D8"), ("d14", "D14")],
    flows=[("p4", "k1", "sale (booking, shipment, service)"), ("d7", "k1", "allocation lines, taxes"), ("d2", "k1", "seller and buyer tax profiles"),
           ("k1", "d14", "DRAFT invoice"), ("p6", "k2", "payment completed"), ("k2", "d14", "FINALIZED: number, UUID, hash, QR"),
           ("k2", "cust", "e-invoice (PDF, QR)", {"constraint": False}), ("k2", "k3", "signed XML"), ("k3", "tax", "clearance or report"),
           ("tax", "k3", "CLEARED / REPORTED / REJECTED", {"constraint": False}), ("k3", "d14", "authority response"),
           ("finance", "k4", "correction"), ("k4", "k3", "linked note"), ("k4", "d14", "note"),
           ("p6", "k5", "financial events"), ("k5", "d14", "journal entries"), ("officer", "k6", "account mappings"),
           ("d14", "k6", "entries, invoices"), ("k6", "erp", "push via API"), ("erp", "k6", "acknowledgements", {"constraint": False}),
           ("d8", "k7", "daily wallet summaries"), ("d14", "k7", "general ledger balances"), ("k7", "finance", "reconciliation report")]))


# ---------------------------------------------------------------- planned layouts (inches) and duplicate symbols
def _patch(spec, externals=(), refs=(), stores=(), renames=(), pos=None):
    spec["externals"] = spec["externals"] + list(externals)
    spec["refs"] = spec.get("refs", []) + list(refs)
    spec["stores"] = spec["stores"] + list(stores)
    flows = []
    for f in spec["flows"]:
        f = list(f)
        for (a, b, old_end, new_end) in renames:
            if f[0] == a and f[1] == b:
                if old_end == "src":
                    f[0] = new_end
                else:
                    f[1] = new_end
        flows.append(tuple(f))
    spec["flows"] = flows
    spec["pos"] = pos


_patch(LEVEL1B, externals=[("cust#2", "Customers"), ("staff#2", "Platform staff"), ("erp#2", "Accounting / ERP and CRM")],
       renames=[("p12", "cust", "dst", "cust#2"), ("staff", "p13", "src", "staff#2"), ("p13", "erp", "dst", "erp#2")],
       pos={"agencies": (0, 11.2), "p14": (2.6, 10.4), "d17": (0.2, 9.0), "p4": (6.0, 11.0), "p7": (10.6, 11.0),
            "staff": (13.2, 12.4), "auth": (16.4, 11.2), "p10": (13.6, 9.4), "d12": (11.8, 7.6), "d16": (15.0, 7.4),
            "regulator": (17.0, 9.0), "cust": (0, 6.4), "logistics": (0, 4.6), "global": (0.4, 2.6), "p9": (3.0, 5.0),
            "d11": (3.4, 3.0), "p6": (7.4, 5.6), "partners": (17.0, 4.6), "p11": (13.8, 4.8), "d13": (14.8, 2.8),
            "p12": (9.0, 2.4), "d14": (6.6, 0.8), "tax": (11.2, 0.6), "erp": (13.4, 1.0), "cust#2": (8.8, 0.2),
            "p13": (4.8, 8.2), "d15": (2.4, 7.6), "notify": (7.2, 8.6), "staff#2": (5.0, 10.0), "erp#2": (7.4, 7.2)})

_patch(L2["DFD-4"][1], stores=[("d5c", "D5"), ("d6b", "D6")],
       renames=[("a7", "d5", "dst", "d5c"), ("a8", "d5", "dst", "d5c"), ("d6", "a8", "src", "d6b"), ("a8", "d6", "dst", "d6b")],
       pos={"pax": (0, 9.4), "a1": (3.0, 10.4), "d5r": (5.8, 11.2), "d4": (5.8, 9.6), "a2": (2.6, 8.0), "d5": (0.4, 6.6),
            "a3": (5.4, 8.0), "a4": (8.6, 8.0), "auth": (11.6, 9.4), "d12": (11.6, 7.0), "a5": (8.6, 5.8), "d7": (11.6, 5.2),
            "a6": (6.0, 4.6), "p6": (3.0, 3.8), "a7": (9.0, 3.2), "d6": (11.8, 2.6), "p12": (11.6, 0.8), "pax#2": (6.0, 1.8),
            "a8": (3.4, 1.4), "d6b": (0.6, 0.6), "d5c": (7.8, 0.4)})

_patch(L2["DFD-6"][1], externals=[("bank#2", "Payment gateways and bank")],
       renames=[("b6", "bank", "dst", "bank#2"), ("bank", "b8", "src", "bank#2")],
       pos={"pax": (0, 9.6), "b1": (2.6, 8.6), "bank": (5.6, 10.4), "b7": (2.6, 6.6), "p4": (6.4, 8.0), "b2": (8.8, 8.8),
            "b4": (8.8, 6.6), "d8": (6.0, 5.2), "p7": (12.8, 9.0), "b3": (12.8, 6.8), "d7": (15.0, 8.2), "b5": (12.8, 4.6),
            "carrier": (15.4, 3.4), "b6": (9.8, 2.8), "d2": (12.4, 1.6), "bank#2": (6.6, 1.0), "b8": (3.0, 3.0),
            "finance": (0.4, 1.6), "p12": (3.2, 0.8)})

_patch(L2["DFD-7"][1], externals=[("driver#2", "Driver / host")],
       renames=[("c4", "driver", "dst", "driver#2")],
       pos={"pax": (0, 9.6), "driver": (2.2, 7.4), "c1": (5.2, 9.0), "d9": (8.2, 7.8), "c4": (11.0, 9.2), "driver#2": (8.4, 10.6),
            "carrier": (14.0, 10.2), "c2": (5.2, 6.4), "d6": (8.2, 5.8), "c3": (5.2, 3.8), "d5": (8.2, 3.4), "c5": (11.2, 4.8),
            "p6": (14.0, 6.0), "p11": (14.0, 3.6), "p10": (8.2, 1.4)})

_patch(L2["DFD-8"][1], externals=[("driver#2", "Driver phone"), ("pax#2", "Shuttle passenger (app)")],
       renames=[("e7", "driver", "dst", "driver#2"), ("e5", "pax", "dst", "pax#2"), ("e6", "pax", "dst", "pax#2")],
       pos={"pax": (0, 7.6), "e1": (2.8, 10.0), "d1": (5.8, 10.6), "e2": (2.8, 6.6), "d4": (5.8, 8.0), "e3": (8.8, 8.8),
            "driver": (12.6, 10.4), "d9": (11.6, 6.8), "d10": (5.8, 5.0), "e4": (8.8, 4.6), "e5": (11.6, 3.2), "p6": (8.8, 1.2),
            "e6": (2.8, 3.6), "e7": (0.2, 4.8), "driver#2": (0.2, 2.4), "pax#2": (5.0, 1.8)})

_patch(L2["DFD-9"][1], refs=[("p6b", "P6")],
       renames=[("f7", "p6", "dst", "p6b")],
       pos={"shipper": (0, 10.0), "d7": (2.6, 11.8), "f1": (2.6, 9.6), "p6": (5.0, 11.6), "operator": (8.0, 11.2),
            "f2": (5.2, 8.2), "d5": (10.8, 10.0), "f3": (8.0, 8.4), "f4": (10.8, 7.6), "d11": (7.0, 5.4), "f5": (10.8, 4.4),
            "courier": (13.8, 5.0), "f6": (7.6, 2.8), "recipient": (4.4, 1.4), "f7": (12.8, 2.4), "p6b": (15.0, 1.0),
            "global": (0, 4.2), "f8": (2.8, 4.6)})

_patch(L2["DFD-10"][1],
       pos={"p4": (0.8, 10.0), "g1": (3.6, 10.0), "auth": (8.0, 11.8), "g3": (11.8, 10.0), "driver": (15.6, 10.6),
            "d6": (0.8, 7.2), "g2": (3.6, 7.2), "d5": (8.0, 8.8), "g6": (3.4, 4.0), "border": (0.4, 2.4), "d12": (6.6, 4.8),
            "g4": (10.2, 6.8), "compliance": (13.0, 8.6), "d16": (13.0, 5.4), "d9": (10.2, 4.2), "g5": (15.0, 7.2),
            "g7": (7.8, 2.4), "regulator": (11.2, 1.8)})

_patch(L2["DFD-11"][1], externals=[("fuel#2", "Fuel station attendant"), ("rest#2", "Rest stop / merchant"),
                                   ("carrier#2", "Carrier owner"), ("pax#2", "Passenger")],
       renames=[("h5", "fuel", "dst", "fuel#2"), ("h5", "rest", "dst", "rest#2"), ("h5", "carrier", "dst", "carrier#2"),
                ("pax", "h4", "src", "pax#2")],
       pos={"driver": (0, 10.0), "carrier": (3.4, 11.8), "d3": (6.4, 11.6), "d9": (6.8, 10.0), "h1": (3.4, 9.4),
            "fuel": (8.6, 8.8), "h2": (6.0, 6.6), "pax": (2.4, 6.8), "rest": (10.0, 6.8), "d13": (6.2, 4.2), "p6": (10.0, 4.6),
            "h3": (3.0, 4.2), "p7": (0.2, 4.8), "h4": (3.0, 1.8), "loyalty": (0.2, 1.2), "pax#2": (5.8, 0.8),
            "h5": (9.0, 2.0), "fuel#2": (12.2, 0.6), "rest#2": (12.2, 2.4), "carrier#2": (9.2, 0.2)})

_patch(L2["DFD-12"][1], refs=[("p6b", "P6")],
       renames=[("p6", "k5", "src", "p6b")],
       pos={"p4": (0, 10.0), "k1": (3.0, 9.6), "d7": (1.4, 11.8), "d2": (4.6, 11.8), "p6": (8.4, 11.2), "k2": (6.2, 9.0),
            "cust": (9.6, 10.2), "k3": (9.8, 7.6), "tax": (13.2, 8.2), "k4": (12.6, 5.6), "finance": (15.0, 4.0),
            "d14": (6.6, 6.0), "p6b": (0.4, 7.0), "k5": (3.2, 5.8), "k6": (6.6, 3.4), "officer": (3.4, 2.4),
            "erp": (10.0, 2.6), "k7": (12.4, 2.2), "d8": (14.6, 1.0)})


if __name__ == "__main__":
    only = sys.argv[1:]
    if not only or "DFD-0" in only:
        context()
    if not only or "DFD-1A" in only:
        render_level("DFD-1A", "DFD-1A Level 1: passenger transport core (P1 to P8)", LEVEL1A)
    if not only or "DFD-1B" in only:
        render_level("DFD-1B", "DFD-1B Level 1: logistics, compliance, partners, finance and channels (P9 to P14)", LEVEL1B)
    for name, (title, spec) in L2.items():
        if not only or name in only:
            render_level(name, title, spec)
