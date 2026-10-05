"""Declarative resources: list, read, create, update, delete and state actions for the tables of the modules.

A Resource names its table, the columns shown and edited, the portals that may use it (with the permission each
needs) and its state actions. Everything else is read from the database itself: column types, required columns,
choice lists (CHECK ... IN constraints) and references (foreign keys). Identifiers come only from the resource
definitions and the catalog, never from the request; every value is a bound parameter; every query runs in the
caller's transaction, so row-level security decides which rows exist for the caller.
"""
import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal
from typing import Any, Optional

import asyncpg

from ..deps import Principal
from ..errors import ApiError, forbidden, not_found

LABEL_CANDIDATES = ("code", "name", "label", "title", "legal_name", "plate_no", "tracking_no", "trip_no", "contract_no",
                    "invoice_no", "permit_no", "declaration_no", "container_no", "booking_ref", "account_no", "email",
                    "pass_no", "device_serial", "manifest_no", "brand", "ticket_no", "receipt_no", "voucher_no", "credit_no")
# Labels of tables whose own columns do not name them
SPECIAL_LABELS = {
    "iam.company": "(SELECT p.legal_name FROM iam.party p WHERE p.id = t.id)",
    "iam.party": "t.legal_name",
    "iam.app_user": "coalesce(t.email::text, t.mobile)",
    "fleet.crew_profile": "(SELECT p.legal_name FROM iam.party p WHERE p.id = t.party_id)",
    "fleet.truck_unit": "(SELECT v.plate_no FROM fleet.vehicle v WHERE v.id = t.vehicle_id)",
    "rent.rental_fleet": "(SELECT v.plate_no FROM fleet.vehicle v WHERE v.id = t.vehicle_id)",
    "rent.rental_company": "t.brand",
    "brd.border_point": "(SELECT s.name FROM net.station s WHERE s.id = t.station_id)",
    "ptn.partner": "t.code || ' ' || (SELECT p.legal_name FROM iam.party p WHERE p.id = t.party_id)",
    "ship.hub": "(SELECT s.name FROM net.station s WHERE s.id = t.station_id)",
    "ship.access_point": "(SELECT s.name FROM net.station s WHERE s.id = t.station_id)",
    "net.line_version": "(SELECT l.code FROM net.line l WHERE l.id = t.line_id) || ' v' || t.version",
    "net.line_tariff": "(SELECT l.code FROM net.line l WHERE l.id = t.line_id) || ' tariff v' || t.version",
    "ops.trip": "t.trip_no",
    "sales.ticket": "t.ticket_no",
    "sales.channel": "t.code",
    "crm.call_agent": "(SELECT coalesce(u.email::text, u.mobile) FROM iam.app_user u WHERE u.id = t.user_id)",
    "ship.shipment_leg": "'leg ' || t.seq || coalesce(' of ' || (SELECT s.tracking_no FROM ship.shipment s WHERE s.id = t.shipment_id), '')",
    "ctr.contract_rider": "(SELECT p.legal_name FROM iam.party p WHERE p.id = t.passenger_party_id)",
    "ship.address": "t.address_text",
    "taxi.taxi_shift": "'shift ' || t.id",
    "fin.wallet": "coalesce(t.label, t.wallet_type) || ' ' || t.currency",
}
HIDDEN_TYPES = {"bytea"}
SAFE_IDENT = re.compile(r"^[a-z_][a-z0-9_]*$")
# bigint columns holding amounts in minor units (shown and entered in currency units by the portals)
MONEY_RE = re.compile(r"(^|_)(amount|price|fee|fees|total|subtotal|tax|taxes|discount|gross|net|commission|fare|balance|value|"
                      r"principal|charge|refund|refunds|deposit|budget|cost|limit|cap|per_km|flag_fall|min_fare|per_wait_min|"
                      r"min_charge|share|redemptions|claims|due|sales|liabilities|assets|accrued|ref|overage_\w+|spent|"
                      r"remainder|outstanding|charged|paid|captured|rate|rate_per_hour|per_kg_over|surcharge|estimate|opening|"
                      r"closing|expected|variance|override)$")
NOT_MONEY = {"rate_bp", "commission_bp", "uses", "max_uses", "rides_limit", "item_count", "qty"}


def is_money(col: "ColMeta") -> bool:
    return col.pg_type == "bigint" and col.name not in NOT_MONEY and not col.name.endswith("_id") and bool(MONEY_RE.search(col.name))


@dataclass
class Action:
    """A state transition: UPDATE ... SET <set> WHERE <column> IN <when>."""
    name: str
    set: dict
    when: dict = field(default_factory=dict)
    permission: Optional[str] = None         # overrides the resource permission for this action
    portals: Optional[tuple] = None          # limits the action to these portals
    four_eyes: Optional[tuple] = None        # (creator column, approver column): approver must differ, gets the caller
    stamp: Optional[str] = None              # timestamp column set to now()
    by: Optional[str] = None                 # column set to the caller's user id


@dataclass
class Resource:
    key: str                                 # URL name, e.g. "line-version"
    module: str                              # feature flag
    table: str                               # schema.table
    list: tuple                              # columns shown in lists
    form: tuple = ()                         # columns accepted on create and update
    portals: dict = field(default_factory=dict)   # portal -> permission (None: any user of the portal)
    company_col: Optional[str] = None        # set to the caller's company in company portals
    owner_col: Optional[str] = None          # set to the caller's party (party ids) in the passenger portal
    owner_from_company: bool = False         # in company portals owner_col takes the company's party (company id = party id)
    user_col: Optional[str] = None           # set to the caller's user id in the passenger portal
    creator_col: Optional[str] = None        # set to the caller's user id on create
    create: bool = True
    update: bool = True
    delete: bool = False
    actions: tuple = ()
    filters: tuple = ()                      # columns usable as ?f_<col>= filters (foreign keys are always allowed)
    order: str = "id DESC"
    readonly_portals: tuple = ()             # portals that may only read
    defaults: dict = field(default_factory=dict)
    group: str = ""                          # menu group inside the module

    def perm_for(self, portal: str) -> Any:
        if portal not in self.portals:
            return False
        return self.portals[portal]


# ------------------------------------------------------------------ catalog introspection (cached per table)
_meta: dict = {}


@dataclass
class ColMeta:
    name: str
    pg_type: str          # format_type(): e.g. bigint, text, timestamp with time zone, daterange, smallint[]
    notnull: bool
    has_default: bool
    generated: bool
    choices: Optional[list] = None
    ref: Optional[str] = None     # referenced table (single-column foreign key)
    ref_col: Optional[str] = None


@dataclass
class TableMeta:
    table: str
    cols: dict
    pk: list


async def table_meta(conn: asyncpg.Connection, table: str) -> TableMeta:
    if table in _meta:
        return _meta[table]
    schema, name = table.split(".")
    rows = await conn.fetch(
        """SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ, a.attnotnull,
                  (a.atthasdef OR a.attidentity <> '') AS has_default, a.attgenerated <> '' AS generated
             FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum""", schema, name)
    if not rows:
        raise RuntimeError(f"unknown table {table}")
    cols = {r["attname"]: ColMeta(r["attname"], r["typ"], r["attnotnull"], r["has_default"], r["generated"]) for r in rows}
    cons = await conn.fetch(
        """SELECT k.contype::text AS contype, pg_get_constraintdef(k.oid) AS def,
                  (SELECT array_agg(a.attname ORDER BY x.ord) FROM unnest(k.conkey) WITH ORDINALITY x(n, ord)
                     JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.n) AS cols,
                  fn.nspname || '.' || fc.relname AS ref,
                  (SELECT a.attname FROM pg_attribute a WHERE a.attrelid = k.confrelid AND a.attnum = k.confkey[1]) AS ref_col
             FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             LEFT JOIN pg_class fc ON fc.oid = k.confrelid LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2""", schema, name)
    pk: list = []
    for k in cons:
        if k["contype"] == "p":
            pk = list(k["cols"])
        elif k["contype"] == "f" and len(k["cols"]) == 1:
            cols[k["cols"][0]].ref, cols[k["cols"][0]].ref_col = k["ref"], k["ref_col"]
        elif k["contype"] == "c" and len(k["cols"] or []) == 1:
            m = re.search(r"IN \((.*)\)|= ANY \(ARRAY\[(.*)\]\)", k["def"])
            if m:
                vals = re.findall(r"'([^']*)'", m.group(1) or m.group(2))
                if vals and cols[k["cols"][0]].choices is None:
                    cols[k["cols"][0]].choices = vals
    meta = TableMeta(table, cols, pk or ["id"])
    _meta[table] = meta
    return meta


async def label_expr(conn: asyncpg.Connection, table: str) -> str:
    if table in SPECIAL_LABELS:
        return SPECIAL_LABELS[table]
    meta = await table_meta(conn, table)
    for c in LABEL_CANDIDATES:
        if c in meta.cols:
            return f"t.{c}::text"
    return f"t.{meta.pk[0]}::text"


# ------------------------------------------------------------------ value conversion
def _read_expr(col: ColMeta, alias: str = "t") -> str:
    q = f"{alias}.{col.name}"
    if col.pg_type.endswith("range"):
        return f"CASE WHEN {q} IS NULL THEN NULL ELSE json_build_array(lower({q}), upper({q})) END"
    return q


def _convert(col: ColMeta, value: Any) -> Any:
    """Client JSON value -> parameter for $n::<type>."""
    if value is None or value == "":
        return None
    t = col.pg_type
    if t.endswith("range"):
        if not isinstance(value, (list, tuple)) or len(value) != 2:
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected [from, to]")
        lo, hi = (v or "" for v in value)
        closed = "]" if t == "daterange" and hi else ")"
        return f"[{lo},{hi}{closed}"
    if t in ("jsonb", "json"):
        return json.dumps(value)
    if t.endswith("[]"):
        if not isinstance(value, list):
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected a list")
        base = t[:-2]
        if base in ("smallint", "integer", "bigint"):
            return [int(v) for v in value]
        return [str(v) for v in value]
    if t in ("smallint", "integer", "bigint"):
        try:
            return int(value)
        except (TypeError, ValueError):
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected a whole number")
    if t.startswith("numeric"):
        try:
            return Decimal(str(value))
        except Exception:
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected a number")
    if t == "boolean":
        if isinstance(value, bool):
            return value
        raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected true or false")
    if t == "date":
        try:
            return date.fromisoformat(str(value)[:10])
        except ValueError:
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected a date")
    if t.startswith("timestamp"):
        try:
            return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            raise ApiError(422, "INVALID_VALUE", f"{col.name}: expected a date and time")
    if t.startswith("time"):
        return str(value)
    if col.choices and str(value) not in col.choices:
        raise ApiError(422, "INVALID_VALUE", f"{col.name}: not one of the allowed values")
    s = str(value)
    if len(s) > 4000:
        raise ApiError(422, "INVALID_VALUE", f"{col.name}: too long")
    return s


def _param(col: ColMeta, n: int) -> str:
    """Placeholder with the casts asyncpg cannot infer from a Python value."""
    t = col.pg_type
    via_text = (t.endswith("range") or t in ("jsonb", "json", "citext", "inet", "uuid", "cidr[]")
                or (t.startswith("time") and not t.startswith("timestamp")) or t.startswith("character"))
    return f"${n}::text::{t}" if via_text else f"${n}"


# ------------------------------------------------------------------ operations
def _key_where(meta: TableMeta, key: str, start: int) -> tuple:
    parts = key.split("~")
    if len(parts) != len(meta.pk):
        raise not_found("record")
    conds, params = [], []
    for i, (c, v) in enumerate(zip(meta.pk, parts)):
        conds.append(f"t.{c} = {_param(meta.cols[c], start + i)}")
        # range parts of a key arrive in their text form, e.g. [2026-01-01,)
        params.append(v if meta.cols[c].pg_type.endswith("range") else _convert(meta.cols[c], v))
    return " AND ".join(conds), params


def _key_expr(meta: TableMeta) -> str:
    return " || '~' || ".join(f"t.{c}::text" for c in meta.pk)


def check_access(res: Resource, pr: Principal, write: bool = False) -> None:
    perm = res.perm_for(pr.portal)
    if perm is False:
        raise forbidden("this portal cannot use this resource")
    if write and pr.portal in res.readonly_portals:
        raise forbidden("read-only in this portal")
    if perm and perm not in pr.permissions:
        raise forbidden("missing permission: " + perm)


async def describe(conn: asyncpg.Connection, res: Resource, pr: Principal) -> dict:
    meta = await table_meta(conn, res.table)
    auto = {c for c in (res.company_col if pr.portal != "PLATFORM" else None,
                        res.owner_col if pr.portal == "PASSENGER" or (res.owner_from_company and pr.portal != "PLATFORM") else None,
                        res.user_col if pr.portal == "PASSENGER" else None, res.creator_col) if c}

    def col_info(name: str) -> dict:
        c = meta.cols[name]
        return {"name": name, "type": c.pg_type, "required": c.notnull and not c.has_default and name not in auto,
                "choices": c.choices, "ref": c.ref, "money": is_money(c)}
    can_write = pr.portal not in res.readonly_portals
    actions = [{"name": a.name, "when": a.when} for a in res.actions
               if (a.portals is None or pr.portal in a.portals) and (not a.permission or a.permission in pr.permissions)]
    return {"key": res.key, "module": res.module, "group": res.group, "table": res.table, "pk": meta.pk,
            "list": [col_info(c) for c in res.list if c in meta.cols],
            "form": [col_info(c) for c in res.form if c in meta.cols and c not in auto] if can_write else [],
            "create": res.create and can_write, "update": res.update and can_write, "delete": res.delete and can_write,
            "actions": actions if can_write else []}


async def list_rows(conn: asyncpg.Connection, res: Resource, pr: Principal, q: Optional[str], filters: dict,
                    limit: int, offset: int) -> dict:
    meta = await table_meta(conn, res.table)
    cols = [c for c in dict.fromkeys(res.list + res.form) if c in meta.cols and meta.cols[c].pg_type not in HIDDEN_TYPES]
    refs = {c: meta.cols[c].ref for c in cols if meta.cols[c].ref}
    where, params = ["true"], []
    allowed_filters = set(res.filters) | {c for c, m in meta.cols.items() if m.ref} | set(meta.pk)
    for k, v in filters.items():
        if k not in allowed_filters or k not in meta.cols:
            raise ApiError(422, "INVALID_FILTER", f"cannot filter on {k}")
        params.append(_convert(meta.cols[k], v))
        where.append(f"t.{k} = {_param(meta.cols[k], len(params))}")
    if q:
        text_cols = [c for c in cols if meta.cols[c].pg_type in ("text", "citext") or meta.cols[c].pg_type.startswith("character")]
        if text_cols:
            params.append(f"%{q}%")
            where.append("(" + " OR ".join(f"t.{c}::text ILIKE ${len(params)}" for c in text_cols) + ")")
    labels = await _label_pairs(conn, meta, refs)
    order = res.order if all(SAFE_IDENT.match(p.split()[0]) for p in res.order.split(",")) else "1"
    sql_where = " AND ".join(where)
    total = await conn.fetchval(f"SELECT count(*) FROM {res.table} t WHERE {sql_where}", *params)
    params += [limit, offset]
    inner = (f"SELECT {_key_expr(meta)} AS _key, t.* FROM {res.table} t WHERE {sql_where} "
             f"ORDER BY {', '.join('t.' + p.strip() for p in order.split(','))} LIMIT ${len(params) - 1} OFFSET ${len(params)}")
    obj_x = ", ".join(f"'{c}', {_read_expr(meta.cols[c], 'x')}" for c in cols)
    rows = await conn.fetch(
        f"SELECT json_build_object('_key', x._key, {obj_x}{', ' if labels else ''}{', '.join(labels)})::text AS j FROM ({inner}) x",
        *params)
    return {"rows": [json.loads(r["j"]) for r in rows], "total": total}


async def _label_pairs(conn: asyncpg.Connection, meta: TableMeta, refs: dict) -> list:
    """json_build_object pairs that add a readable "<column>__label" next to every reference of the row x."""
    pairs = []
    for c, ref in refs.items():
        lab = await label_expr(conn, ref)
        ref_meta = await table_meta(conn, ref)
        pairs.append(f"'{c}__label', (SELECT {lab} FROM {ref} t WHERE t.{meta.cols[c].ref_col or ref_meta.pk[0]} = x.{c})")
    return pairs


async def get_row(conn: asyncpg.Connection, res: Resource, key: str) -> dict:
    meta = await table_meta(conn, res.table)
    cond, params = _key_where(meta, key, 1)
    cols = [c for c in meta.cols if meta.cols[c].pg_type not in HIDDEN_TYPES]
    obj = ", ".join(f"'{c}', {_read_expr(meta.cols[c], 'x')}" for c in cols)
    labels = await _label_pairs(conn, meta, {c: meta.cols[c].ref for c in cols if meta.cols[c].ref})
    raw = await conn.fetchval(
        f"SELECT json_build_object('_key', x._key, {obj}{', ' if labels else ''}{', '.join(labels)})::text "
        f"FROM (SELECT {_key_expr(meta)} AS _key, t.* FROM {res.table} t WHERE {cond}) x", *params)
    if raw is None:
        raise not_found("record")
    return json.loads(raw)


def _values(res: Resource, meta: TableMeta, body: dict, pr: Principal, creating: bool) -> dict:
    unknown = set(body) - set(res.form)
    if unknown:
        raise ApiError(422, "UNKNOWN_FIELDS", "fields not accepted: " + ", ".join(sorted(unknown)[:5]))
    vals = {k: _convert(meta.cols[k], v) for k, v in body.items() if k in meta.cols and not meta.cols[k].generated}
    if res.company_col and pr.portal != "PLATFORM":
        if creating:
            vals[res.company_col] = pr.company_id
        else:
            vals.pop(res.company_col, None)          # a company never moves a row to another company
    if res.owner_col and res.owner_from_company and pr.portal != "PLATFORM" and pr.portal != "PASSENGER":
        if creating:
            vals[res.owner_col] = pr.company_id
        else:
            vals.pop(res.owner_col, None)
    if pr.portal == "PASSENGER":
        for col, own in ((res.owner_col, pr.party_id), (res.user_col, pr.user_id)):
            if col:
                if creating:
                    vals[col] = own                      # a passenger always acts for themselves
                else:
                    vals.pop(col, None)
    if creating and res.creator_col and res.creator_col in meta.cols:
        vals[res.creator_col] = pr.user_id
    if creating:
        for k, v in res.defaults.items():
            vals.setdefault(k, v)
    return vals


async def create_row(conn: asyncpg.Connection, res: Resource, pr: Principal, body: dict) -> dict:
    if not res.create:
        raise forbidden("records of this kind are not created here")
    meta = await table_meta(conn, res.table)
    vals = _values(res, meta, body, pr, creating=True)
    missing = [c for c, m in meta.cols.items() if m.notnull and not m.has_default and not m.generated and vals.get(c) is None]
    if missing:
        raise ApiError(422, "REQUIRED_FIELDS", "required: " + ", ".join(missing), fields=missing)
    names = list(vals)
    params = [vals[n] for n in names]
    placeholders = ", ".join(_param(meta.cols[n], i + 1) for i, n in enumerate(names))
    key = await conn.fetchval(
        f"INSERT INTO {res.table} AS t ({', '.join(names)}) VALUES ({placeholders}) RETURNING {_key_expr(meta)}", *params)
    return await get_row(conn, res, key)


async def update_row(conn: asyncpg.Connection, res: Resource, pr: Principal, key: str, body: dict) -> dict:
    if not res.update:
        raise forbidden("records of this kind are not changed here")
    meta = await table_meta(conn, res.table)
    vals = _values(res, meta, body, pr, creating=False)
    for c in meta.pk:
        vals.pop(c, None)
    if not vals:
        return await get_row(conn, res, key)
    names = list(vals)
    sets = ", ".join(f"{n} = {_param(meta.cols[n], i + 1)}" for i, n in enumerate(names))
    cond, kparams = _key_where(meta, key, len(names) + 1)
    done = await conn.fetchval(f"UPDATE {res.table} AS t SET {sets} WHERE {cond} RETURNING 1", *[vals[n] for n in names], *kparams)
    if not done:
        raise not_found("record")
    return await get_row(conn, res, key)


async def delete_row(conn: asyncpg.Connection, res: Resource, key: str) -> None:
    if not res.delete:
        raise forbidden("records of this kind are not deleted")
    meta = await table_meta(conn, res.table)
    cond, params = _key_where(meta, key, 1)
    if not await conn.fetchval(f"DELETE FROM {res.table} AS t WHERE {cond} RETURNING 1", *params):
        raise not_found("record")


async def run_action(conn: asyncpg.Connection, res: Resource, pr: Principal, key: str, name: str) -> dict:
    act = next((a for a in res.actions if a.name == name), None)
    if act is None or (act.portals and pr.portal not in act.portals):
        raise not_found("action")
    if act.permission and act.permission not in pr.permissions:
        raise forbidden("missing permission: " + act.permission)
    meta = await table_meta(conn, res.table)
    row = await get_row(conn, res, key)
    for col, allowed in act.when.items():
        if row.get(col) not in allowed:
            raise ApiError(409, "INVALID_STATE", f"{name} is not allowed when {col} is {row.get(col)}")
    sets, params = [], []
    for col, v in act.set.items():
        params.append(_convert(meta.cols[col], v))
        sets.append(f"{col} = {_param(meta.cols[col], len(params))}")
    if act.four_eyes:
        creator, approver = act.four_eyes
        if row.get(creator) == pr.user_id:
            raise ApiError(409, "FOUR_EYES", "a different person must approve")
        params.append(pr.user_id)
        sets.append(f"{approver} = ${len(params)}")
    if act.stamp:
        sets.append(f"{act.stamp} = now()")
    if act.by:
        params.append(pr.user_id)
        sets.append(f"{act.by} = ${len(params)}")
    cond, kparams = _key_where(meta, key, len(params) + 1)
    await conn.execute(f"UPDATE {res.table} AS t SET {', '.join(sets)} WHERE {cond}", *params, *kparams)
    return await get_row(conn, res, key)


async def lookup(conn: asyncpg.Connection, table: str, q: Optional[str], limit: int = 30, key: Optional[str] = None) -> list:
    """Options for a reference column; key is the referenced column when the foreign key does not point at the primary key."""
    meta = await table_meta(conn, table)
    lab = await label_expr(conn, table)
    key = key if key in meta.cols else meta.pk[0]
    params: list = [limit]
    where = "true"
    if q:
        params.append(f"%{q}%")
        where = f"({lab}) ILIKE $2"
    rows = await conn.fetch(f"SELECT t.{key} AS id, {lab} AS label FROM {table} t WHERE {where} ORDER BY 2 LIMIT $1", *params)
    return [{"id": r["id"], "label": r["label"]} for r in rows]
