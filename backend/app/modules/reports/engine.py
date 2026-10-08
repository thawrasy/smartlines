"""Turns a report spec into one parameterized query and runs it under the caller's row-level security.

A spec only names dataset column keys, filter operators and values
anything else is refused before any SQL is
written. Values always travel as bind parameters. Company portals get an explicit filter on their own company on
top of row-level security, and readers who hold only the regulator role get grouped results without personal data.
"""
import time
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any, Optional

import asyncpg

from ...errors import ApiError
from .catalog import BY_CODE, CATEGORY_OF, Report
from .datasets import BOOL, DATASETS, DATE, INT, MONEY, NUM, PCT, TIME, Col, Dataset

OPS = {"eq": "=", "ne": "<>", "gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "in": "IN", "not_in": "NOT IN",
       "contains": "ILIKE", "starts": "ILIKE", "is_null": "IS NULL", "not_null": "IS NOT NULL", "between": "BETWEEN"}
AGGS = {"count", "count_distinct", "sum", "avg", "min", "max"}
PREVIEW_ROWS, EXPORT_ROWS, PDF_ROWS = 500, 50_000, 5_000
MAX_PERIOD_DAYS = 3 * 366


@dataclass
class Viewer:
    portal: str                 # PLATFORM, OPERATOR, AGENCY
    company_id: Optional[int]
    permissions: set
    roles: set

    @property
    def regulator_only(self) -> bool:
        return self.portal == "PLATFORM" and "REGULATOR" in self.roles and not (self.roles - {"REGULATOR"})


@dataclass
class OutCol:
    key: str
    label_key: str              # column key or aggregate key, translated by the exporter
    type: str
    values: str = ""
    agg: str = ""


@dataclass
class Result:
    dataset: str
    columns: list
    rows: list
    totals: dict = field(default_factory=dict)
    truncated: bool = False
    duration_ms: int = 0
    data_as_of: Optional[datetime] = None     # the moment the figures reflect (replica replay time or now)
    freshness: Optional[dict] = None          # replica lag, its limit and whether it was passed (freshness.py)
    source_version: Optional[str] = None      # the schema release the figures were computed against (release.py)


def can_read(ds: Dataset, v: Viewer) -> bool:
    if v.portal not in ds.portals:
        return False
    if ds.permission and ds.permission not in v.permissions:
        return False
    return True


def visible_reports(v: Viewer) -> list[Report]:
    out = []
    for r in BY_CODE.values():
        ds = DATASETS[r.dataset]
        if not can_read(ds, v) or (r.portals and v.portal not in r.portals):
            continue
        if v.regulator_only and not r.aggregate:
            continue
        out.append(r)
    return out


def category(code: str) -> str:
    return CATEGORY_OF.get(code.split(".")[0], "other")


def _cast(col: Col) -> str:
    return {INT: "bigint", MONEY: "bigint", NUM: "numeric", PCT: "numeric", DATE: "date", TIME: "timestamptz", BOOL: "boolean"}.get(col.type, "text")


def _value(col: Col, raw: Any) -> Any:
    """A filter value converted to the column's type (refused when it does not fit)."""
    try:
        if col.type in (INT,):
            return int(raw)
        if col.type == MONEY:                         # filters on money are entered in pounds
            return int(Decimal(str(raw)) * 100)
        if col.type in (NUM, PCT):
            return Decimal(str(raw))
        if col.type == DATE:
            return raw if isinstance(raw, date) else date.fromisoformat(str(raw)[:10])
        if col.type == TIME:
            return raw if isinstance(raw, datetime) else datetime.fromisoformat(str(raw))
        if col.type == BOOL:
            if isinstance(raw, bool):
                return raw
            return str(raw).lower() in ("1", "true", "yes")
        s = str(raw)
        if len(s) > 120:
            raise ValueError("too long")
        return s
    except (ValueError, ArithmeticError, TypeError) as e:
        raise ApiError(422, "REPORT_BAD_FILTER", f"bad value for {col.key}") from e


def build(ds: Dataset, spec: dict, v: Viewer, params: dict, limit: int) -> tuple[str, list, list[OutCol]]:
    if not isinstance(spec, dict):
        raise ApiError(422, "REPORT_BAD_SPEC", "spec must be an object")
    hidden = {c.key for c in ds.columns if c.personal} if v.regulator_only else set()
    def col(key: str) -> Col:
        try:
            c = ds.col(key)
        except KeyError:
            raise ApiError(422, "REPORT_UNKNOWN_COLUMN", f"unknown column {key}") from None
        if c.key in hidden:
            raise ApiError(403, "REPORT_PERSONAL_DATA", f"column {key} holds personal data")
        return c

    args: list = []
    def bind(value: Any, c: Col) -> str:
        args.append(value)
        return f"${len(args)}::{_cast(c)}"

    where: list[str] = []
    # company portals: their own company only, whatever the table's own policy allows
    if v.portal == "OPERATOR":
        if not ds.company_sql or not v.company_id:
            raise ApiError(403, "REPORT_NOT_ALLOWED", "dataset not available to this portal")
        args.append(v.company_id)
        where.append(f"{ds.company_sql} = ${len(args)}")
    elif v.portal == "AGENCY":
        if not ds.agency_sql or not v.company_id:
            raise ApiError(403, "REPORT_NOT_ALLOWED", "dataset not available to this portal")
        args.append(v.company_id)
        where.append(f"{ds.agency_sql} = ${len(args)}")

    # the period on the dataset's date column (default: the last 30 days)
    dcol = ds.col(ds.date_col)
    today = date.today()
    d_from = _value(Col("from", "", DATE), params.get("from") or (today - timedelta(days=30)).isoformat())
    d_to = _value(Col("to", "", DATE), params.get("to") or today.isoformat())
    if d_to < d_from:
        raise ApiError(422, "REPORT_BAD_PERIOD", "the period ends before it starts")
    if (d_to - d_from).days > MAX_PERIOD_DAYS:
        raise ApiError(422, "REPORT_PERIOD_TOO_LONG", "the period is limited to three years")
    if not params.get("all_time"):
        where.append(f"{dcol.sql} BETWEEN {bind(d_from, Col('', '', DATE))} AND {bind(d_to, Col('', '', DATE))}")

    for f in list(spec.get("filters") or []) + list(params.get("filters") or []):
        if not isinstance(f, (list, tuple)) or len(f) < 2 or f[1] not in OPS:
            raise ApiError(422, "REPORT_BAD_FILTER", "filters are [column, operator, value]")
        c, op = col(f[0]), f[1]
        if not c.filter:
            raise ApiError(422, "REPORT_BAD_FILTER", f"column {c.key} cannot be filtered")
        val = f[2] if len(f) > 2 else None
        if op in ("is_null", "not_null"):
            where.append(f"{c.sql} {OPS[op]}")
        elif op in ("in", "not_in"):
            vals = val if isinstance(val, list) else [val]
            if not 1 <= len(vals) <= 50:
                raise ApiError(422, "REPORT_BAD_FILTER", "between 1 and 50 values")
            args.append([_value(c, x) for x in vals])
            where.append(f"{'NOT ' if op == 'not_in' else ''}({c.sql} = ANY(${len(args)}::{_cast(c)}[]))")
        elif op == "between":
            if not isinstance(val, list) or len(val) != 2:
                raise ApiError(422, "REPORT_BAD_FILTER", "between takes two values")
            where.append(f"{c.sql} BETWEEN {bind(_value(c, val[0]), c)} AND {bind(_value(c, val[1]), c)}")
        elif op in ("contains", "starts"):
            s = str(_value(c, val)).replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            args.append(f"%{s}%" if op == "contains" else f"{s}%")
            where.append(f"({c.sql})::text ILIKE ${len(args)}")
        else:
            where.append(f"{c.sql} {OPS[op]} {bind(_value(c, val), c)}")

    out: list[OutCol] = []
    group = list(spec.get("group_by") or [])
    if v.regulator_only and not group:
        raise ApiError(403, "REPORT_AGGREGATE_ONLY", "this account sees grouped figures only")
    select: list[str] = []
    order_keys: dict[str, str] = {}
    if group:
        if len(group) > 4:
            raise ApiError(422, "REPORT_BAD_SPEC", "at most four grouping columns")
        for k in group:
            c = col(k)
            if not c.group:
                raise ApiError(422, "REPORT_BAD_SPEC", f"column {k} cannot be grouped")
            select.append(f"{c.sql} AS \"{c.key}\"")
            out.append(OutCol(c.key, c.key, c.type, c.values))
            order_keys[c.key] = f"\"{c.key}\""
        totals = list(spec.get("totals") or [["count", "*"]])
        if len(totals) > 8:
            raise ApiError(422, "REPORT_BAD_SPEC", "at most eight totals")
        for t in totals:
            if not isinstance(t, (list, tuple)) or len(t) != 2 or t[0] not in AGGS:
                raise ApiError(422, "REPORT_BAD_SPEC", "totals are [function, column]")
            fn, k = t
            alias = f"{fn}__{k}"
            if k == "*":
                if fn != "count":
                    raise ApiError(422, "REPORT_BAD_SPEC", "only count applies to *")
                select.append(f"count(*) AS \"{alias}\"")
                out.append(OutCol(alias, "count", INT, agg="count"))
            else:
                c = col(k)
                if fn == "count_distinct":
                    select.append(f"count(DISTINCT {c.sql}) AS \"{alias}\"")
                    out.append(OutCol(alias, c.key, INT, agg=fn))
                else:
                    if not c.agg and fn in ("sum", "avg"):
                        raise ApiError(422, "REPORT_BAD_SPEC", f"column {k} cannot be summed")
                    typ = c.type if fn != "avg" or c.type == MONEY else NUM
                    expr = f"round(avg({c.sql}))" if fn == "avg" and c.type in (MONEY, INT) else f"{fn}({c.sql})"
                    select.append(f"{expr} AS \"{alias}\"")
                    out.append(OutCol(alias, c.key, typ, c.values, agg=fn))
            order_keys[alias] = f"\"{alias}\""
        group_sql = " GROUP BY " + ", ".join(str(i + 1) for i in range(len(group)))
    else:
        cols = list(spec.get("columns") or [])
        if not 1 <= len(cols) <= 30:
            raise ApiError(422, "REPORT_BAD_SPEC", "choose between 1 and 30 columns")
        for k in cols:
            c = col(k)
            select.append(f"{c.sql} AS \"{c.key}\"")
            out.append(OutCol(c.key, c.key, c.type, c.values))
            order_keys[c.key] = f"\"{c.key}\""
        group_sql = ""

    order = []
    for s in spec.get("sort") or ([list(ds.default_sort)] if ds.default_sort and not group else []):
        if not isinstance(s, (list, tuple)) or len(s) != 2 or s[1] not in ("asc", "desc"):
            raise ApiError(422, "REPORT_BAD_SPEC", "sort is [column, asc|desc]")
        if s[0] in order_keys:
            order.append(f"{order_keys[s[0]]} {s[1].upper()} NULLS LAST")
    sql = (f"SELECT {', '.join(select)} FROM {ds.from_sql} WHERE {' AND '.join(where) or 'true'}{group_sql}"
           f"{' ORDER BY ' + ', '.join(order) if order else ''} LIMIT {int(limit) + 1}")
    return sql, args, out


async def run(conn: asyncpg.Connection, v: Viewer, *, dataset: str, spec: dict, params: dict, limit: int) -> Result:
    ds = DATASETS.get(dataset)
    if ds is None or not can_read(ds, v):
        raise ApiError(403, "REPORT_NOT_ALLOWED", "dataset not available")
    sql, args, cols = build(ds, spec, v, params or {}, limit)
    t0 = time.monotonic()
    await conn.execute("SET LOCAL statement_timeout = '25s'")
    try:
        records = await conn.fetch(sql, *args)
    except asyncpg.QueryCanceledError as e:
        raise ApiError(422, "REPORT_TOO_SLOW", "narrow the period or add filters") from e
    truncated = len(records) > limit
    rows = [dict(r) for r in records[:limit]]
    totals = {}
    for c in cols:                                   # page totals for money and counts
        if c.type in (MONEY, INT, NUM) and (c.agg in ("count", "sum", "count_distinct") or (not c.agg and DATASETS[dataset].col(c.key).agg)):
            totals[c.key] = sum((r[c.key] or 0) for r in rows)
    return Result(dataset, cols, rows, totals, truncated, int((time.monotonic() - t0) * 1000))


def resolve(code: Optional[str], v: Viewer) -> Report:
    r = BY_CODE.get(code or "")
    if r is None or r not in visible_reports(v):
        raise ApiError(404, "REPORT_NOT_FOUND", "unknown report")
    return r


def sensitive(ds: Dataset, spec: dict) -> bool:
    """A report is sensitive when it shows a personal or a money column (audit T3-05): scheduled copies then go by
    short-lived link to named accounts, with the owner's consent, never as an attachment."""
    keys: set[str] = set()

    def walk(x):
        if isinstance(x, str):
            keys.add(x)
        elif isinstance(x, dict):
            for k, v in x.items():
                keys.add(k)
                walk(v)
        elif isinstance(x, (list, tuple)):
            for v in x:
                walk(v)
    walk(spec)
    return any(c.key in keys and (c.personal or c.type == MONEY) for c in ds.columns)
