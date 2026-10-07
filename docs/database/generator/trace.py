#!/usr/bin/env python3
"""Traceability: maps every entity row of the study v2.6 (tables "Entity | Main fields | Keys and relationships",
section 4.10 and the "New entities" lists of 21.1 and 21.2) to the database tables that implement it.

Usage: python3 trace.py <study.docx>   (after render.py; adds "trace" to ../build/model.json)
"""
import json
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "..", "build", "model.json")

# Study names that the database implements under another name, or as columns, or by a generalization the study adopts
RENAMED = {
    "company_profile": (["iam.company"], "1:1 with the party; the tenant"),
    "route": (["net.route"], ""), "route_stop": (["net.route_stop"], ""),     # school routes are named sch.route in 21.3
    "driver_profile": (["fleet.crew_profile", "fleet.license_record", "fleet.driving_hours_log"], "licences are locked licence records"),
    "host_profile": (["fleet.crew_profile"], "crew_type HOST or ASSISTANT"),
    "trip_segment": (["ops.trip_stop", "ops.trip_pair_fare"], "sellable sections are stop pairs"),
    "seat_occupancy": (["ops.seat_segment"], "one row per seat and segment"),
    "seat_inventory": (["ops.seat_segment"], ""),
    "promotion": (["pricing.campaign"], ""), "coupon": (["pricing.promo_code"], ""),
    "redemption": (["sales.campaign_redemption"], ""),
    "price_snapshot": (["sales.booking"], "column price_breakdown with rules_version"),
    "partner": (["ptn.partner", "pricing.loyalty_partner"], ""),
    "ledger_transaction": (["fin.ledger_txn"], ""),
    "webhook_subscription": (["sys.webhook_endpoint"], ""),
    "audit_log": (["audit.activity_log", "audit.row_change"], "request log and database change capture"),
    "complaint": (["crm.case"], "kind COMPLAINT"), "rating": (["crm.trip_rating"], ""),
    "incident_report": (["ops.incident"], ""),
    "security_audit_log": (["audit.data_access_log", "audit.log_seal"], "hash chain sealed in blocks"),
    "company_role": (["iam.role"], "roles with a company_id"),
    "user": (["iam.app_user", "iam.company_member"], ""),
    "portal_login_event": (["audit.auth_event"], ""),
    "identity_verification": (["iam.verification"], ""),
    "device_registry": (["iam.device"], ""),
    "trip_position": (["ops.geo_event"], "high-volume table, partitioned"),
    "carrier_api_key": (["iam.api_client", "iam.api_key"], ""),
    "campaign_budget": (["pricing.campaign"], "budget columns and budget_alert_pct"),
    "allocation_line": (["fin.price_allocation_line"], "sponsor_account_id and funded_by"),
    "integration_endpoint": (["sys.webhook_endpoint", "sys.webhook_delivery"], ""),
    "event": (["sys.outbox_event"], ""),
    "authority_incident_link": (["ops.incident_external_link"], ""),
    "agent": (["crm.call_agent", "crm.call_agent_skill"], ""), "queue": (["crm.call_queue"], ""),
    "skill": (["crm.call_skill", "crm.call_queue_skill"], ""),
    "line_fare_table": (["net.line_fare"], "merged into the tariff's fare rows"),
    "cargo_assignment": (["ship.shipment_leg"], "a BUS_HOLD leg (9.9 generalization)"),
    "cargo_booking": (["ship.capacity_booking"], "9.9 generalization"),
    "shipment_event": (["ship.tracking_event"], "9.9 generalization"),
    "transit_pax_reconciliation": (["ops.transit_reconciliation"], ""),
    "invoice_line": (["acct.sales_invoice_line"], ""),
    "line": (["acct.sales_invoice_line", "sales.channel_statement_line"], ""),
    "tier": (["pricing.loyalty_tier"], ""), "rule": (["pricing.loyalty_rule"], ""),
    "template": (["crm.notification_template"], ""),
    "trip_position_retention": ([], ""),
    "subscription_plan": (["sales.subscription_plan"], ""), "subscription": (["sales.subscription"], ""),
    "gov_adapter_config": (["sec.gov_adapter_config"], ""), "verification_job": (["sec.verification_job"], ""),
    "journey": (["rail.journey", "rail.journey_leg"], ""),
    "telematics_device": (["rent.telematics_device"], ""),
    "exchange_rate": (["ref.exchange_rate"], ""),
    "tax_fee_rule": (["pricing.tax_rule", "pricing.commission_rule"], "replaced by the 5.8 engine"),
    "price_allocation": (["fin.price_allocation", "fin.price_allocation_line"], ""),
    "trip_delay": (["ops.trip_delay"], ""), "station_gate": (["net.station_gate"], ""),
    "station_display": (["net.station_display"], ""),
}
# Names that exist in more than one schema: chosen by the study section
BY_SECTION = {
    "partner_contract": lambda sec: "ship.partner_contract" if sec.startswith("9.") else "ptn.partner_contract",
    "partner_settlement": lambda sec: "ship.partner_settlement" if sec.startswith("9.") else "ptn.partner_settlement",
}
SKIP = {"payment_fees", "cost_model", "additions", "addition", "extended", "generalized", "generalizes", "shared", "new", "types", "b2b", "rest_stop", "or"}


def study_rows(docx):
    s = zipfile.ZipFile(docx).read("word/document.xml").decode("utf8")
    out, sec = [], ""
    for blk in re.findall(r"<w:p[ >].*?</w:p>|<w:tbl>.*?</w:tbl>", s, re.S):
        if blk.startswith("<w:tbl>"):
            rows = re.findall(r"<w:tr[ >].*?</w:tr>", blk, re.S)
            cells = [[re.sub(r"&amp;", "&", "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", tc)))
                      for tc in re.findall(r"<w:tc>.*?</w:tc>", r, re.S)] for r in rows]
            if not cells:
                continue
            hdr = cells[0]
            if hdr[:1] == ["Entity"] and len(hdr) == 3 and "fields" in hdr[1].lower() or hdr[:2] == ["Entity", "Change"]:
                out += [(sec, c[0], c[1] if len(c) > 1 else "") for c in cells[1:]]
            elif hdr[:2] == ["Phase", "New entities"]:
                out += [(sec, n.strip(), "") for c in cells[1:] for n in re.split(r",", re.sub(r"\(.*?\)", "", c[1]))]
            continue
        st = re.search(r'w:pStyle w:val="(Heading\d)"', blk)
        txt = "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", blk))
        if st:
            sec = txt
        elif txt.startswith("New entities:"):
            out += [(sec, n.strip(" ."), "") for n in txt[len("New entities:"):].split(",")]
    return out


def main():
    model = json.load(open(MODEL))
    tables = {f'{t["schema"]}.{t["name"]}' for t in model["tables"]}
    by_name = {}
    for full in tables:
        by_name.setdefault(full.split(".")[1], []).append(full)
    trace, unresolved = [], []
    for sec, entity, fields in study_rows(sys.argv[1]):
        if len(entity) > 70 or not re.search(r"[a-z]_|^[a-z]+$|\.", entity):
            continue
        tokens = [t for t in re.findall(r"[a-z][a-z0-9_]*(?:\.[a-z_]+)?", entity) if t not in SKIP]
        found, notes = [], []
        for tok in tokens:
            name = tok.split(".")[-1]
            if "." in tok and tok in tables:              # a schema-qualified name is exact
                found.append(tok)
            elif name in BY_SECTION:
                found.append(BY_SECTION[name](sec))
            elif name in by_name and len(by_name[name]) == 1:
                found.append(by_name[name][0])
            elif name in RENAMED:
                found += RENAMED[name][0]
                if RENAMED[name][1]:
                    notes.append(RENAMED[name][1])
            else:
                unresolved.append((sec, entity, tok))
        if "addition" in entity or "extended" in entity or "Change" in fields or sec.startswith("D.1.8") and "(new)" not in entity:
            notes.append("columns added to the existing table")
        found = list(dict.fromkeys(found))
        if found:
            trace.append({"section": sec.split(" ")[0] if re.match(r"^[0-9A-D]", sec) else sec[:40], "heading": sec,
                          "entity": entity, "tables": found, "note": "; ".join(dict.fromkeys(notes))})
    model["trace"] = trace
    json.dump(model, open(MODEL, "w"), indent=0)
    print(f"traced {len(trace)} study entities; unresolved tokens: {len(unresolved)}")
    for u in unresolved:
        print("  ?", u)


if __name__ == "__main__":
    main()
