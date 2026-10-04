"""Every resource of the modules, by URL key."""
from . import border, business, freight, lines, shipping, transport

RESOURCES = {}
for _m in (lines, shipping, freight, border, business, transport):
    for _r in _m.RESOURCES:
        if _r.key in RESOURCES:
            raise RuntimeError(f"duplicate resource key {_r.key}")
        RESOURCES[_r.key] = _r
