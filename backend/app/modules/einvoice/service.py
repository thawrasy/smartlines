"""E-invoices for paid sales and credit notes for refunds (study 5.14; core in 080_acct.sql, issuing in 1104).

A paid booking gets one simplified invoice from each seller that has an active issuing unit and a tax profile valid
now: the carrier for the tickets, the platform for its booking fee. A refunded booking gets, against each invoice, a
credit note for what was refunded of that seller's allocation lines. The worker issues them every minute
(issue_due), each booking in its own transaction, so a seller without a unit or a failing document never holds up the
others.

Each document is numbered by acct.finalize_einvoice under the unit's row lock (gapless, never reset). Its hash is the
SHA-256 of a canonical JSON of its content, number, time and the previous document's hash, so the documents of a unit
form a chain; the hash is signed with the e-invoice key ring's signing key (Ed25519), whose id the document names, and
the QR code carries seller, tax number, time, totals, hash, signature and key id as TLV in base64. verify() recomputes
all of it from the stored rows, with the public key kept for that key id.

Taxes (1108) come from the platform's tax schemes (taxes.py): each line carries every tax that applies to it, extracted
from the price paid, and a credit note takes back each tax of its invoice in proportion. Documents issued before 1108
keep canonical version 1 (one rate per line, no key id) and verify as issued.
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import uuid
from decimal import Decimal
from typing import Optional

import asyncpg

from ... import db, markets
from ...security import einvoice_sign, einvoice_signature_valid, einvoice_signer
from . import taxes
from .taxes import LineTax, Sale

log = logging.getLogger("masslak.einvoice")
PLATFORM_PARTY = "(SELECT id FROM iam.party WHERE legal_name = 'Masslak Platform' AND party_type = 'COMPANY')"
SELLER_SQL = """SELECT p.id AS profile_id, p.party_id, p.legal_name, p.tax_no, u.id AS unit_id
                  FROM acct.tax_profile p JOIN acct.einvoice_unit u ON u.profile_id = p.id AND u.status = 'ACTIVE'
                 WHERE p.party_id = $1 AND p.valid @> now() ORDER BY u.id LIMIT 1"""


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


def canonical(doc: dict, lines: list[dict]) -> bytes:
    """The bytes that are hashed: every field a reader relies on, in a fixed form (amounts in minor units). Version 2
    (1108) adds the signing key id and each line's taxes; version 1 documents are hashed as they were issued."""
    body = {
        "v": 1, "uuid": str(doc["uuid"]), "type": doc["doc_type"], "subtype": doc["subtype"], "number": doc["number"],
        "counter": doc["counter_value"], "issued_at": doc["issued_at"].isoformat(), "currency": doc["currency"],
        "seller": {"name": doc["seller_name"], "tax_no": doc["seller_tax_no"]}, "buyer_tax_no": doc["buyer_tax_no"],
        "original": doc.get("original_number"), "subtotal": doc["subtotal"], "tax_total": doc["tax_total"], "total": doc["total"],
        "previous_hash": doc["previous_hash"],
        "lines": [[ln["line_no"], ln["description"], f"{Decimal(ln['qty']):.3f}", ln["unit_price"], ln["net_amount"],
                   f"{Decimal(ln['tax_rate']):.6f}", ln["tax_amount"]] for ln in lines],
    }
    if doc.get("canonical_version", 1) >= 2:
        body["v"] = 2
        body["kid"] = doc["signing_kid"]
        body["lines"] = [row + [ln["treatment"], [[t["seq"], t["scheme_code"], t["tax_type"], t["treatment"], f"{Decimal(t['rate']):.6f}",
                                                    t["base"], t["amount"], t["payable_to_party_id"]] for t in ln["taxes"]]]
                         for row, ln in zip(body["lines"], lines)]
    return json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def _tlv(fields: list[tuple[int, str]]) -> str:
    out = b""
    for tag, value in fields:
        v = value.encode()[:255]
        out += bytes([tag, len(v)]) + v
    return base64.b64encode(out).decode()


def qr_payload(doc: dict, digest_hex: str, signature: str) -> str:
    major = lambda minor: f"{Decimal(minor) / 100:.2f}"            # noqa: E731
    fields = [(1, doc["seller_name"]), (2, doc["seller_tax_no"] or ""), (3, doc["issued_at"].isoformat()),
              (4, major(doc["total"])), (5, major(doc["tax_total"])), (6, digest_hex), (7, signature)]
    if doc.get("signing_kid"):
        fields.append((8, doc["signing_kid"]))
    return _tlv(fields)


def read_qr(payload: str) -> dict:
    raw, out, i = base64.b64decode(payload), {}, 0
    while i < len(raw):
        tag, n = raw[i], raw[i + 1]
        out[tag] = raw[i + 2:i + 2 + n].decode()
        i += 2 + n
    return out


def _line(no: int, description: str, net: int, line_taxes: list[LineTax]) -> dict:
    tax = sum(t.amount for t in line_taxes)
    return {"line_no": no, "description": description, "qty": Decimal(1), "unit_price": net, "net_amount": net,
            "tax_rate": (Decimal(tax * 100) / Decimal(net) if net else Decimal(0)).quantize(Decimal("0.000001")), "tax_amount": tax,
            "treatment": taxes.line_treatment(line_taxes),
            "tax_scheme_id": line_taxes[0].scheme_id if len(line_taxes) == 1 else None,
            "taxes": [{"seq": i, "scheme_id": t.scheme_id, "scheme_code": t.code, "tax_type": t.tax_type, "treatment": t.treatment,
                       "rate": t.rate, "base": t.base, "amount": t.amount, "payable_to_party_id": t.payable_to_party_id}
                      for i, t in enumerate(line_taxes, start=1)]}


async def _signing_key(conn: asyncpg.Connection, digest: bytes) -> tuple[str, str]:
    """Signs with the ring's signing key; its public key is kept for that key id on first use. A key id that already
    names another public key means two different keys were given the same id: nothing is issued until that is fixed."""
    kid, signature, public = einvoice_sign(digest)
    await conn.execute("INSERT INTO acct.einvoice_signing_key (kid, public_key) VALUES ($1, $2) ON CONFLICT (kid) DO NOTHING", kid, public)
    if await conn.fetchval("SELECT public_key FROM acct.einvoice_signing_key WHERE kid = $1", kid) != public:
        raise RuntimeError(f"e-invoice key id {kid} already names another public key; give the new key a new id (MASSLAK_EINVOICE_KEYS)")
    return kid, base64.b64encode(signature).decode()


async def _issue(conn: asyncpg.Connection, seller: asyncpg.Record, *, doc_type: str, company_id: Optional[int],
                 buyer_party_id: Optional[int], source_type: str, source_id: int, currency: str, rows: list[dict],
                 original: Optional[asyncpg.Record] = None, reason: Optional[str] = None) -> int:
    """Writes the draft, its lines and their taxes, then numbers, hashes, signs and finalizes it under the unit's lock."""
    subtotal = sum(r["net_amount"] for r in rows)
    tax_total = sum(r["tax_amount"] for r in rows)
    kid, public = einvoice_signer()                                # the key that will sign: registered before the draft names it
    await conn.execute("INSERT INTO acct.einvoice_signing_key (kid, public_key) VALUES ($1, $2) ON CONFLICT (kid) DO NOTHING", kid, public)
    doc_id, doc_uuid = await conn.fetchrow(
        """INSERT INTO acct.einvoice_document (doc_type, subtype, seller_profile_id, unit_id, company_id, buyer_party_id,
                                               source_type, source_id, original_doc_id, reason_code, currency, subtotal, tax_total, total,
                                               canonical_version, signing_kid)
           VALUES ($1, 'SIMPLIFIED', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 2, $14) RETURNING id, uuid""",
        doc_type, seller["profile_id"], seller["unit_id"], company_id, buyer_party_id, source_type, source_id,
        original["id"] if original else None, reason, currency, subtotal, tax_total, subtotal + tax_total, kid)
    for r in rows:
        line_id = await conn.fetchval(
            """INSERT INTO acct.einvoice_line (document_id, line_no, description, qty, unit_price, net_amount, tax_scheme_id, treatment,
                                               tax_rate, tax_amount)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id""",
            doc_id, r["line_no"], r["description"], r["qty"], r["unit_price"], r["net_amount"], r["tax_scheme_id"], r["treatment"],
            r["tax_rate"], r["tax_amount"])
        await conn.executemany(
            """INSERT INTO acct.einvoice_line_tax (line_id, seq, tax_scheme_id, scheme_code, tax_type, treatment, rate, base, amount,
                                                   payable_to_party_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)""",
            [(line_id, t["seq"], t["scheme_id"], t["scheme_code"], t["tax_type"], t["treatment"], t["rate"], t["base"], t["amount"],
              t["payable_to_party_id"]) for t in r["taxes"]])
    unit = await conn.fetchrow("SELECT number_prefix, counter_value, last_hash FROM acct.einvoice_unit WHERE id = $1 FOR UPDATE",
                               seller["unit_id"])
    counter = unit["counter_value"] + 1
    doc = {"uuid": doc_uuid, "doc_type": doc_type, "subtype": "SIMPLIFIED", "number": unit["number_prefix"] + str(counter).zfill(10),
           "counter_value": counter, "issued_at": await conn.fetchval("SELECT now()"), "currency": currency,
           "seller_name": seller["legal_name"], "seller_tax_no": seller["tax_no"], "buyer_tax_no": None,
           "original_number": original["number"] if original else None, "subtotal": subtotal, "tax_total": tax_total,
           "total": subtotal + tax_total, "previous_hash": unit["last_hash"], "canonical_version": 2, "signing_kid": kid}
    digest = hashlib.sha256(canonical(doc, rows)).hexdigest()
    signed_kid, signature = await _signing_key(conn, bytes.fromhex(digest))
    if signed_kid != kid:
        raise RuntimeError("the e-invoice signing key changed while a document was being issued")
    done = await conn.fetchrow("SELECT number, finalized_at FROM acct.finalize_einvoice($1, $2, $3, $4)",
                               doc_id, digest, signature, qr_payload(doc, digest, signature))
    if done["number"] != doc["number"] or done["finalized_at"] != doc["issued_at"]:   # the database numbers; both must agree
        raise RuntimeError(f"e-invoice {doc_id}: number or time differs from the hashed content")
    return doc_id


async def _sale(conn: asyncpg.Connection, seller_party_id: int, seller: str, product: str, b: asyncpg.Record) -> Sale:
    country = (await markets.of_party(conn, seller_party_id)).country
    return Sale(country=country, seller=seller, product=product, company_id=b["company_id"], origin_city=b["origin_city"],
                distance_km=b["distance_km"], at=b["confirmed_at"])


async def issue_for_booking(conn: asyncpg.Connection, booking_id: int) -> list[int]:
    """The invoices of a paid booking: the carrier's for its tickets, the platform's for its fee. The caller holds the
    system scope."""
    b = await conn.fetchrow(
        """SELECT b.id, b.booking_ref, b.company_id, b.booker_party_id, b.currency, b.price_breakdown, b.status, b.confirmed_at, t.trip_no,
                  c.code AS origin_city, r.distance_km
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id LEFT JOIN net.route r ON r.id = t.route_id
             LEFT JOIN net.station st ON st.id = r.origin_station_id LEFT JOIN ref.city c ON c.id = st.city_id
            WHERE b.id = $1 FOR UPDATE OF b""", booking_id)
    if b is None or b["status"] not in ("CONFIRMED", "COMPLETED", "CANCELLED"):
        return []
    issued = {r["seller_profile_id"] for r in await conn.fetch(
        "SELECT seller_profile_id FROM acct.einvoice_document WHERE source_type = 'BOOKING' AND source_id = $1 AND doc_type = 'INVOICE'", b["id"])}
    out = []
    carrier = await conn.fetchrow(SELLER_SQL, b["company_id"])
    if carrier and carrier["profile_id"] not in issued:
        sale = await _sale(conn, carrier["party_id"], "CARRIER", "TICKET", b)
        schemes = await taxes.schemes_for(conn, sale)
        rows = []
        for no, k in enumerate(await conn.fetch("SELECT ticket_no, total_amount FROM sales.ticket WHERE booking_id = $1 ORDER BY id", b["id"]),
                               start=1):
            net, line_taxes = taxes.split_inclusive(int(k["total_amount"]), schemes, sale, first_line=no == 1)
            rows.append(_line(no, f"Ticket {k['ticket_no']}, trip {b['trip_no']}", net, line_taxes))
        out.append(await _issue(conn, carrier, doc_type="INVOICE", company_id=b["company_id"], buyer_party_id=b["booker_party_id"],
                                source_type="BOOKING", source_id=b["id"], currency=b["currency"], rows=rows))
    fee = (json.loads(b["price_breakdown"]) if isinstance(b["price_breakdown"], str) else b["price_breakdown"]).get("platform_fee", 0)
    platform = await conn.fetchrow(SELLER_SQL.replace("$1", PLATFORM_PARTY)) if fee else None
    if platform and platform["profile_id"] not in issued:
        sale = await _sale(conn, platform["party_id"], "PLATFORM", "BOOKING_FEE", b)
        net, line_taxes = taxes.split_inclusive(int(fee), await taxes.schemes_for(conn, sale), sale)
        out.append(await _issue(conn, platform, doc_type="INVOICE", company_id=None, buyer_party_id=b["booker_party_id"],
                                source_type="BOOKING", source_id=b["id"], currency=b["currency"],
                                rows=[_line(1, f"Booking fee, booking {b['booking_ref']}", net, line_taxes)]))
    return out


async def _document_taxes(conn: asyncpg.Connection, inv: asyncpg.Record) -> list[LineTax]:
    """An invoice's taxes summed over its lines, per tax; a version 1 invoice has one rate per line."""
    rows = await conn.fetch(
        """SELECT t.tax_scheme_id, t.scheme_code, t.tax_type, t.treatment, t.rate, t.payable_to_party_id, sum(t.base) AS base,
                  sum(t.amount) AS amount, min(t.seq) AS seq
             FROM acct.einvoice_line_tax t JOIN acct.einvoice_line l ON l.id = t.line_id WHERE l.document_id = $1
            GROUP BY 1, 2, 3, 4, 5, 6 ORDER BY min(t.seq), 2""", inv["id"])
    if rows:
        return [LineTax(r["tax_scheme_id"], r["scheme_code"], r["tax_type"], r["treatment"], r["rate"], int(r["base"]), int(r["amount"]),
                        r["payable_to_party_id"]) for r in rows]
    if inv["tax_total"]:
        rate = (Decimal(inv["tax_total"] * 100) / Decimal(inv["subtotal"])).quantize(Decimal("0.000001")) if inv["subtotal"] else Decimal(0)
        return [LineTax(None, "TAX", "OTHER", "STANDARD", rate, int(inv["subtotal"]), int(inv["tax_total"]), None)]
    return []


async def credit_for_booking(conn: asyncpg.Connection, booking_id: int) -> list[int]:
    """Credit notes for what a cancelled booking refunded, against each of its invoices, up to what is not yet credited."""
    b = await conn.fetchrow("SELECT id, booking_ref, price_allocation_id, cancel_reason, status FROM sales.booking WHERE id = $1",
                            booking_id)
    if b is None or b["status"] != "CANCELLED":
        return []
    refunded = {r["code"]: r["refunded_amount"] for r in await conn.fetch(
        "SELECT code, refunded_amount FROM fin.price_allocation_line WHERE allocation_id = $1", b["price_allocation_id"])}
    platform_id = await conn.fetchval(f"SELECT {PLATFORM_PARTY}")
    out = []
    for inv in await conn.fetch(
            """SELECT d.*, p.party_id AS seller_party_id, p.legal_name, p.tax_no,
                      (SELECT coalesce(sum(c.total), 0) FROM acct.einvoice_document c WHERE c.original_doc_id = d.id
                          AND c.doc_type = 'CREDIT_NOTE' AND c.status NOT IN ('DRAFT','CANCELLED_DRAFT','REJECTED')) AS credited
                 FROM acct.einvoice_document d JOIN acct.tax_profile p ON p.id = d.seller_profile_id
                WHERE d.source_type = 'BOOKING' AND d.source_id = $1 AND d.doc_type = 'INVOICE'
                  AND d.status NOT IN ('DRAFT','CANCELLED_DRAFT','REJECTED') ORDER BY d.id FOR UPDATE OF d""", b["id"]):
        back = refunded.get("PLATFORM_FEE", 0) if inv["seller_party_id"] == platform_id else \
            refunded.get("CARRIER_FARE", 0) + refunded.get("AGENCY_COMMISSION", 0)
        amount = int(min(back, inv["total"]) - inv["credited"])
        if amount <= 0:
            continue
        seller = {"profile_id": inv["seller_profile_id"], "unit_id": inv["unit_id"], "legal_name": inv["legal_name"], "tax_no": inv["tax_no"]}
        line_taxes = taxes.proportion(await _document_taxes(conn, inv), amount, int(inv["total"]))
        net = amount - sum(t.amount for t in line_taxes)
        out.append(await _issue(conn, seller, doc_type="CREDIT_NOTE", company_id=inv["company_id"], buyer_party_id=inv["buyer_party_id"],
                                source_type="BOOKING", source_id=b["id"], currency=inv["currency"],
                                rows=[_line(1, f"Refund, booking {b['booking_ref']}", net, line_taxes)], original=inv,
                                reason=(b["cancel_reason"] or "CANCELLED")[:60]))
    return out


async def issue_due(limit: int = 100) -> dict:
    """The worker's pass: invoices for paid bookings and credit notes for refunded ones, within the look-back window."""
    async with db.transaction(_ctx()) as conn:
        window = int(await conn.fetchval(
            "SELECT coalesce((SELECT (value #>> '{}')::int FROM sys.setting WHERE key = 'einvoice.issue_window_days'), 30)"))
        if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM acct.einvoice_unit WHERE status = 'ACTIVE')"):
            return {"invoices": 0, "credit_notes": 0}
        to_invoice = [r["id"] for r in await conn.fetch(
            f"""SELECT b.id FROM sales.booking b
                 WHERE b.status IN ('CONFIRMED','COMPLETED','CANCELLED') AND b.confirmed_at > now() - make_interval(days => $1)
                   AND EXISTS (SELECT 1 FROM acct.tax_profile p JOIN acct.einvoice_unit u ON u.profile_id = p.id AND u.status = 'ACTIVE'
                                WHERE p.party_id IN (b.company_id, {PLATFORM_PARTY}) AND p.valid @> now()
                                  AND NOT EXISTS (SELECT 1 FROM acct.einvoice_document d WHERE d.source_type = 'BOOKING'
                                                     AND d.source_id = b.id AND d.doc_type = 'INVOICE' AND d.seller_profile_id = p.id))
                 ORDER BY b.id LIMIT $2""", window, limit)]
        to_credit = [r["source_id"] for r in await conn.fetch(
            """SELECT DISTINCT d.source_id FROM acct.einvoice_document d JOIN sales.booking b ON b.id = d.source_id
                WHERE d.source_type = 'BOOKING' AND d.doc_type = 'INVOICE' AND d.status NOT IN ('DRAFT','CANCELLED_DRAFT','REJECTED')
                  AND b.status = 'CANCELLED' AND b.cancelled_at > now() - make_interval(days => $1)
                  AND d.total > (SELECT coalesce(sum(c.total), 0) FROM acct.einvoice_document c WHERE c.original_doc_id = d.id
                                    AND c.doc_type = 'CREDIT_NOTE' AND c.status NOT IN ('DRAFT','CANCELLED_DRAFT','REJECTED'))
                  AND EXISTS (SELECT 1 FROM fin.price_allocation_line l WHERE l.allocation_id = b.price_allocation_id AND l.refunded_amount > 0)
                LIMIT $2""", window, limit)]
    invoices = credits = 0
    for bid in to_invoice:
        try:
            async with db.transaction(_ctx()) as conn:
                invoices += len(await issue_for_booking(conn, bid))
        except Exception:                                   # noqa: BLE001 - one booking never stops the others
            log.exception("e-invoice for booking %s failed; tried again on the next pass", bid)
    for bid in to_credit:
        try:
            async with db.transaction(_ctx()) as conn:
                credits += len(await credit_for_booking(conn, bid))
        except Exception:                                   # noqa: BLE001
            log.exception("credit note for booking %s failed; tried again on the next pass", bid)
    return {"invoices": invoices, "credit_notes": credits}


async def verify(conn: asyncpg.Connection, doc_uuid: uuid.UUID) -> Optional[dict]:
    """Recomputes the hash from the stored document, checks the signature, the QR and the link to the previous one."""
    d = await conn.fetchrow(
        """SELECT d.*, p.legal_name AS seller_name, p.tax_no AS seller_tax_no, o.number AS original_number,
                  (SELECT x.hash FROM acct.einvoice_document x WHERE x.unit_id = d.unit_id AND x.counter_value = d.counter_value - 1) AS before_hash
             FROM acct.einvoice_document d JOIN acct.tax_profile p ON p.id = d.seller_profile_id
             LEFT JOIN acct.einvoice_document o ON o.id = d.original_doc_id
            WHERE d.uuid = $1 AND d.status NOT IN ('DRAFT','CANCELLED_DRAFT')""", doc_uuid)
    if d is None:
        return None
    lines = [dict(r) for r in await conn.fetch(
        """SELECT id, line_no, description, qty, unit_price, net_amount, treatment, tax_rate, tax_amount FROM acct.einvoice_line
            WHERE document_id = $1 ORDER BY line_no""", d["id"])]
    if d["canonical_version"] >= 2:
        for ln in lines:
            ln["taxes"] = [dict(t) for t in await conn.fetch(
                """SELECT seq, scheme_code, tax_type, treatment, rate, base, amount, payable_to_party_id FROM acct.einvoice_line_tax
                    WHERE line_id = $1 ORDER BY seq""", ln["id"])]
    public_key = await conn.fetchval("SELECT public_key FROM acct.einvoice_signing_key WHERE kid = $1", d["signing_kid"]) \
        if d["signing_kid"] else None
    doc = dict(d)
    doc["issued_at"] = d["finalized_at"]
    digest = hashlib.sha256(canonical(doc, lines)).hexdigest()
    qr = read_qr(d["qr_payload"])
    return {
        "number": d["number"], "doc_type": d["doc_type"], "seller": d["seller_name"], "seller_tax_no": d["seller_tax_no"],
        "issued_at": d["finalized_at"].isoformat(), "currency": d["currency"], "total": d["total"], "tax_total": d["tax_total"],
        "status": d["status"], "original_number": d["original_number"], "kid": d["signing_kid"],
        "taxes": _tax_summary(lines),
        "hash_valid": digest == d["hash"],
        "signature_valid": (d["signing_kid"] is None or public_key is not None)
                           and einvoice_signature_valid(bytes.fromhex(d["hash"]), base64.b64decode(d["signature"]), public_key),
        "qr_matches": qr.get(6) == d["hash"] and qr.get(7) == d["signature"] and qr.get(8) == d["signing_kid"],
        "chain_valid": d["previous_hash"] == ("0" if d["counter_value"] == 1 else d["before_hash"]),
        "public_key": public_key,
    }


def _tax_summary(lines: list[dict]) -> list[dict]:
    """The document's taxes per tax, for a reader: what was charged and on what base."""
    out: dict[tuple, dict] = {}
    for ln in lines:
        for t in ln.get("taxes", []):
            k = (t["scheme_code"], t["treatment"], str(t["rate"]))
            row = out.setdefault(k, {"tax": t["scheme_code"], "type": t["tax_type"], "treatment": t["treatment"],
                                     "rate": f"{Decimal(t['rate']):.2f}", "base": 0, "amount": 0})
            row["base"] += t["base"]
            row["amount"] += t["amount"]
    return list(out.values())
