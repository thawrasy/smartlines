"""The API's contract baseline and its breaking-change check (review of release 1.47.0, R-51).

docs/api/openapi-baseline.json keeps, for every operation of the web/mobile API and of the partner API v1, what a
client depends on: its parameters, its request body, its success statuses and, where declared, its response body, with
every $ref resolved. The check compares the running code with it and names each change that would break a client
already in use:

  * an operation or a success status removed;
  * a parameter or a request field that became required, or a new required one;
  * a type changed; a value removed from a request enum (a client may still send it) or added to a response enum
    (a client may not know it); a length or range limit tightened on a request;
  * a response field removed, or no longer always present.

Additions (new operations, optional parameters or fields, response fields) pass. A deliberate break is accepted by
writing a new baseline with a reason, which is recorded in docs/api/API_CHANGES.md next to the list of breaks:

    python -m app.tools.api_baseline check
    python -m app.tools.api_baseline write --reason "bookings: passengers[] now requires category (mobile 2.3+)"

Most routes return plain dicts, which the document cannot describe, so the responses the clients cannot do without are
also recorded as shapes (docs/api/response-shapes.json, field names and types only) by tests/test_api_baseline.py
against a running server, with the same rule: a field removed or retyped fails unless accepted with a reason.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
BASELINE = ROOT / "docs" / "api" / "openapi-baseline.json"
CHANGES = ROOT / "docs" / "api" / "API_CHANGES.md"
METHODS = ("get", "post", "put", "patch", "delete")
_DROP = {"title", "description", "examples", "example", "deprecated"}
_TIGHTER_IF_SMALLER = ("maxLength", "maximum", "exclusiveMaximum", "maxItems")
_TIGHTER_IF_LARGER = ("minLength", "minimum", "exclusiveMinimum", "minItems")


# ------------------------------------------------------------------ the document as a client sees it
def _resolve(node: Any, components: dict, seen: tuple = ()) -> Any:
    if isinstance(node, list):
        return [_resolve(x, components, seen) for x in node]
    if not isinstance(node, dict):
        return node
    if "$ref" in node:
        name = node["$ref"].rsplit("/", 1)[-1]
        if name in seen:                                       # a recursive schema: name it, do not unfold forever
            return {"recursive": name}
        return _resolve(components.get(name, {}), components, seen + (name,))
    return {k: _resolve(v, components, seen) for k, v in node.items() if k not in _DROP}


def _simplify(schema: Any) -> Any:
    """Optional[X] is written anyOf [X, null] by FastAPI: keep X with nullable, so a field gaining or losing None stays
    comparable."""
    if isinstance(schema, list):
        return [_simplify(x) for x in schema]
    if not isinstance(schema, dict):
        return schema
    out = {k: _simplify(v) for k, v in schema.items()}
    for key in ("anyOf", "oneOf"):
        options = out.get(key)
        if isinstance(options, list) and len(options) == 2 and {"type": "null"} in options:
            other = next(o for o in options if o != {"type": "null"})
            out.pop(key)
            out = {**other, **{k: v for k, v in out.items() if k != "default"}, "nullable": True}
            if "default" in schema:
                out["default"] = schema["default"]
    return out


def canonical(spec: dict) -> dict:
    components = spec.get("components", {}).get("schemas", {})
    ops = {}
    for path, item in sorted(spec.get("paths", {}).items()):
        for method in METHODS:
            op = item.get(method)
            if not op:
                continue
            params = {}
            for p in item.get("parameters", []) + op.get("parameters", []):
                p = _resolve(p, components)
                params[f"{p['in']}:{p['name']}"] = {"required": bool(p.get("required")),
                                                     "schema": _simplify(p.get("schema", {}))}
            body = op.get("requestBody")
            body = None if body is None else {
                "required": bool(body.get("required")),
                "content": {ct: _simplify(_resolve(c.get("schema", {}), components))
                            for ct, c in sorted(body.get("content", {}).items())}}
            responses = {code: _simplify(_resolve(r.get("content", {}).get("application/json", {}).get("schema", {}), components))
                         for code, r in sorted(op.get("responses", {}).items()) if code.startswith("2")}
            ops[f"{method.upper()} {path}"] = {"parameters": params, "body": body, "responses": responses}
    return ops


def current() -> dict:
    """The contract of the code as it is now: the web/mobile API and the partner API v1."""
    from fastapi.openapi.utils import get_openapi

    from app.main import app
    from app.modules.integration import v1
    return {"app": canonical(app.openapi()),
            "v1": canonical(get_openapi(title="Masslak Integration API", version="1.0.0", routes=v1.router.routes))}


# ------------------------------------------------------------------ what breaks a client
def _types(schema: dict) -> set:
    t = schema.get("type")
    out = set(t) if isinstance(t, list) else ({t} if t else set())
    if "integer" in out:
        out.add("number")                                     # an integer is still a number to a JSON client
    return out


def _schema(old: Any, new: Any, where: str, request: bool, out: list) -> None:
    if not isinstance(old, dict) or not isinstance(new, dict) or not old:
        return                                               # nothing was promised: anything goes
    if "recursive" in old or "recursive" in new:
        return
    ot, nt = _types(old), _types(new)
    if ot and nt and not (ot <= nt if request else nt <= ot):
        out.append(f"{where}: type {sorted(ot)} became {sorted(nt)}")
        return
    if old.get("nullable") != new.get("nullable"):
        if request and old.get("nullable") and not new.get("nullable"):
            out.append(f"{where}: no longer accepts null")
        if not request and new.get("nullable") and not old.get("nullable"):
            out.append(f"{where}: may now be null")
    if "enum" in old or "enum" in new:
        oe, ne = set(map(json.dumps, old.get("enum", []))), set(map(json.dumps, new.get("enum", [])))
        if request and "enum" in new and oe - ne:
            out.append(f"{where}: no longer accepts {', '.join(sorted(oe - ne))}")
        if not request and "enum" in old and ne - oe:
            out.append(f"{where}: may now return {', '.join(sorted(ne - oe))}")
    if request:
        for key in _TIGHTER_IF_SMALLER:
            if key in new and (key not in old or new[key] < old[key]):
                out.append(f"{where}: {key} tightened to {new[key]}")
        for key in _TIGHTER_IF_LARGER:
            if key in new and (key not in old or new[key] > old[key]):
                out.append(f"{where}: {key} tightened to {new[key]}")
        if "pattern" in new and new.get("pattern") != old.get("pattern"):
            out.append(f"{where}: pattern changed to {new['pattern']}")
    op, np_ = old.get("properties", {}), new.get("properties", {})
    oreq, nreq = set(old.get("required", [])), set(new.get("required", []))
    if request:
        for name in sorted(nreq - oreq):
            out.append(f"{where}.{name}: now required" if name in op else f"{where}.{name}: new required field")
        if old.get("additionalProperties") is not False and new.get("additionalProperties") is False and not op:
            out.append(f"{where}: no longer accepts extra fields")
    else:
        for name in sorted(oreq - nreq):
            out.append(f"{where}.{name}: no longer always returned" if name in np_ else f"{where}.{name}: removed")
        for name in sorted(set(op) - set(np_) - (oreq - nreq)):
            out.append(f"{where}.{name}: removed")
    for name in sorted(set(op) & set(np_)):
        _schema(op[name], np_[name], f"{where}.{name}", request, out)
    if "items" in old and "items" in new:
        _schema(old["items"], new["items"], f"{where}[]", request, out)


def breaking(old: dict, new: dict) -> list[str]:
    out: list[str] = []
    for api in sorted(old):
        for key, o in sorted(old[api].items()):
            n = new.get(api, {}).get(key)
            name = f"{api} {key}"
            if n is None:
                out.append(f"{name}: removed")
                continue
            for pk, po in o["parameters"].items():
                pn = n["parameters"].get(pk)
                if pn is None:
                    if pk.startswith("path:"):
                        out.append(f"{name} parameter {pk}: removed")
                    continue                                  # a query parameter dropped is ignored by the server
                if pn["required"] and not po["required"]:
                    out.append(f"{name} parameter {pk}: now required")
                _schema(po["schema"], pn["schema"], f"{name} parameter {pk}", True, out)
            for pk, pn in n["parameters"].items():
                if pk not in o["parameters"] and pn["required"]:
                    out.append(f"{name} parameter {pk}: new required parameter")
            ob, nb = o["body"], n["body"]
            if nb and nb["required"] and not (ob and ob["required"]):
                out.append(f"{name} body: now required")
            if ob and nb:
                for ct, schema in ob["content"].items():
                    if ct not in nb["content"]:
                        out.append(f"{name} body {ct}: no longer accepted")
                    else:
                        _schema(schema, nb["content"][ct], f"{name} body", True, out)
            for code, schema in o["responses"].items():
                if code not in n["responses"]:
                    out.append(f"{name} response {code}: removed")
                else:
                    _schema(schema, n["responses"][code], f"{name} response {code}", False, out)
    return out


# ------------------------------------------------------------------ response shapes
# Almost every route returns a plain dict, so the document above says nothing about responses. The responses the
# clients cannot do without are therefore recorded as shapes by tests/test_api_baseline.py against a running server:
# the fields always present and the type of each, with lists described by the fields every element has.
SHAPES = ROOT / "docs" / "api" / "response-shapes.json"


def shape(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: shape(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        items = [shape(v) for v in value]
        if not items:
            return []
        if all(isinstance(i, dict) for i in items):
            common = set.intersection(*(set(i) for i in items))   # a field only some elements carry is not promised
            merged = {}
            for k in sorted(common):
                kinds = [i[k] for i in items if i[k] != "null"]
                merged[k] = kinds[0] if kinds else "null"
            return [merged]
        kinds = [i for i in items if i != "null"]
        return [kinds[0] if kinds else "null"]
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    return "string"


def shape_breaks(old: Any, new: Any, where: str) -> list[str]:
    """A field gone or a type changed; null on either side says nothing (the data decide), nor does an empty list."""
    if old == "null" or new == "null" or old == [] or new == []:
        return []
    if isinstance(old, dict):
        if not isinstance(new, dict):
            return [f"{where}: was an object"]
        out = []
        for k, v in old.items():
            out += [f"{where}.{k}: removed"] if k not in new else shape_breaks(v, new[k], f"{where}.{k}")
        return out
    if isinstance(old, list):
        return shape_breaks(old[0], new[0], f"{where}[]") if isinstance(new, list) else [f"{where}: was a list"]
    return [] if old == new else [f"{where}: {old} became {new if isinstance(new, str) else type(new).__name__}"]


def load() -> dict:
    return json.loads(BASELINE.read_text(encoding="utf-8"))


def write(reason: str | None) -> list[str]:
    now = current()
    breaks = breaking(load(), now) if BASELINE.exists() else []
    if breaks and not reason:
        raise SystemExit("breaking changes need --reason, which is recorded in docs/api/API_CHANGES.md:\n  "
                         + "\n  ".join(breaks))
    BASELINE.parent.mkdir(parents=True, exist_ok=True)
    BASELINE.write_text(json.dumps(now, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    if breaks:
        head = "" if CHANGES.exists() else ("# API changes that break clients\n\nEach entry was accepted with "
                                             "`python -m app.tools.api_baseline write --reason ...` (R-51).\n")
        with CHANGES.open("a", encoding="utf-8") as f:
            f.write(head + f"\n## {date.today().isoformat()}: {reason}\n\n" + "".join(f"- {b}\n" for b in breaks))
    return breaks


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="list the changes that would break a client (exit 1 when there are any)")
    w = sub.add_parser("write", help="write a new baseline; breaking changes need a reason")
    w.add_argument("--reason")
    args = ap.parse_args(argv)
    if args.cmd == "check":
        breaks = breaking(load(), current())
        print("\n".join(breaks) if breaks else "no breaking change against docs/api/openapi-baseline.json")
        return 1 if breaks else 0
    breaks = write(args.reason)
    print(f"baseline written; {len(breaks)} breaking change(s) recorded" if breaks else "baseline written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
