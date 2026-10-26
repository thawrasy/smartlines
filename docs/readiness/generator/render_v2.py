"""Renders the use case and data flow diagrams of edition 2.0 and exports the model for the document. Run from this folder:

    python3 render_v2.py

Output: ../png/v2 (the diagrams) and work2/model_v2.json (the model the document builder reads)."""
import json, os, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
V1 = os.path.join(HERE, "..", "..", "diagrams", "uc-dfd", "generator")
WORK = os.path.join(HERE, "work2")
PNG = os.path.join(HERE, "..", "png", "v2")
os.makedirs(WORK, exist_ok=True); os.makedirs(PNG, exist_ok=True)
os.chdir(WORK)                       # the v1.0 renderers write to ./out
sys.path.insert(0, V1); sys.path.insert(0, HERE)

import model                          # noqa: E402  (v1.0 model, extended before the renderers read it)
from models import NEW_ACTORS, NEW_UC, NEW_PROCESSES, NEW_STORES, DFD15, DFD16   # noqa: E402
import models_v2 as v2               # noqa: E402

# ---------------------------------------------------------------- the model of edition 2.0
model.ACTORS += NEW_ACTORS + v2.NEW_ACTORS_V2
model.ACTOR.update({a[0]: a for a in model.ACTORS})
model.STORES += NEW_STORES
model.STORE.update({s[0]: s for s in NEW_STORES})
model.PROCESSES += NEW_PROCESSES
for spec in model.UC:
    add = v2.ADDED.get(spec["id"])
    if add:
        spec["cases"] = spec["cases"] + add["cases"]
        spec["assoc"] = spec["assoc"] + add.get("assoc", [])
        spec["include"] = spec["include"] + add.get("include", [])
        spec["extend"] = spec["extend"] + add.get("extend", [])
model.UC += NEW_UC + v2.NEW_UC_V2
model.SUBSYSTEMS += [(f"S{u['id'][3:]}", u["title"], u["id"]) for u in NEW_UC + v2.NEW_UC_V2]

missing = [c[0] for u in model.UC for c in u["cases"] if c[0] not in v2.STATUS]
assert not missing, f"cases without a status: {missing}"

import ucsvg                          # noqa: E402
import dfd                            # noqa: E402

ucsvg.CASE_LOOK.update({cid: v2.LOOK[st] for cid, (st, _) in v2.STATUS.items()})
groups = {g: (name, members) for g, name, members in ucsvg.GROUPS}
groups["g_cust"][1].extend(["head", "member"])
groups["g_carr"][1].extend(["counter", "boardstaff"])
groups["g_staff"][1].extend(["privacy", "secofficer"])
ucsvg.GROUPS.append(("g_stat", "Station operating companies", ["stationop"]))
sysgroups = {g: (name, members) for g, name, members in ucsvg.SYSGROUPS}
sysgroups["x_gov"][1].append("idprov")
sysgroups["x_svc"][1].extend(["stationsys", "screens"])
ucsvg.SYSGROUPS[:] = [(g, "CRM, notification providers, station systems and devices" if g == "x_svc" else n, m)
                      for g, n, m in ucsvg.SYSGROUPS]

# ---------------------------------------------------------------- use case diagrams
ucsvg.render_uc(ucsvg.overview_spec(), "UC-0", package_mode=True)
for spec in model.UC:
    ucsvg.render_uc(spec, spec["id"])


def status_legend():
    items = list(v2.LOOK.items())
    w, h = 1080, 130
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="{ucsvg.FONT}">',
             f'<rect width="{w}" height="{h}" fill="#ffffff"/>']
    for i, (code, (fill, stroke, dash, _, _)) in enumerate(items):
        x, y = 20 + (i % 3) * 350, 36 + (i // 3) * 58
        dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
        parts.append(f'<ellipse cx="{x + 46}" cy="{y}" rx="44" ry="20" fill="{fill}" stroke="{stroke}" stroke-width="1.4"{dash_attr}/>')
        parts.append(f'<text x="{x + 46}" y="{y + 4}" text-anchor="middle" font-size="12" font-weight="bold" fill="#1A1C1A">{code}</text>')
        parts.append(f'<text x="{x + 100}" y="{y + 4}" font-size="13" fill="#1A1C1A">{v2.STATUS_NAMES[code]}</text>')
    parts.append('</svg>')
    svg = "".join(parts)
    import cairosvg
    cairosvg.svg2png(bytestring=svg.encode(), write_to="out/legend-status.png", output_width=w * 2)


status_legend()

# ---------------------------------------------------------------- data flow diagrams
dfd.CONTEXT_LEFT[:] = [(n, lab, i + (", " + v2.CONTEXT_FLOW_CHANGES[n][0] if n in v2.CONTEXT_FLOW_CHANGES else ""),
                        o + (", " + v2.CONTEXT_FLOW_CHANGES[n][1] if n in v2.CONTEXT_FLOW_CHANGES else ""))
                       for n, lab, i, o in dfd.CONTEXT_LEFT] + v2.CONTEXT_LEFT_ADD
dfd.CONTEXT_RIGHT[:] = [(n, lab, i + (", " + v2.CONTEXT_FLOW_CHANGES[n][0] if n in v2.CONTEXT_FLOW_CHANGES else ""),
                         o + (", " + v2.CONTEXT_FLOW_CHANGES[n][1] if n in v2.CONTEXT_FLOW_CHANGES else ""))
                        for n, lab, i, o in dfd.CONTEXT_RIGHT] + v2.CONTEXT_RIGHT_ADD
dfd.context()
dfd.render_level("DFD-1A", "DFD-1A Level 1: passenger transport core (P1 to P8)", dfd.LEVEL1A)
dfd.render_level("DFD-1B", "DFD-1B Level 1: logistics, compliance, partners, finance and channels (P9 to P14)", dfd.LEVEL1B)
lr = dict(rankdir="LR", extra="ranksep=1.4, nodesep=0.3")
dfd.render("DFD-1C", "DFD-1C Level 1: boarding stations and boarding photos (P15, P16)", dfd.level(v2.LEVEL1C), **lr)
for name, (title, spec) in dfd.L2.items():
    dfd.render_level(name, title, spec)
for name, title, spec in (DFD15, DFD16):
    dfd.render(name, title, dfd.level(spec), **lr)
for name, (title, spec) in v2.L2_NEW.items():
    dfd.render(name, title, dfd.level(spec), **lr)

import legend                         # noqa: E402,F401  (importing it writes the notation legends of v1.0)

for f in os.listdir("out"):
    if f.endswith(".png"):
        shutil.copy(os.path.join("out", f), os.path.join(PNG, f))

# ---------------------------------------------------------------- the model for the document
level2 = {name: title for name, (title, _) in dfd.L2.items()}
level2.update({DFD15[0]: DFD15[1], DFD16[0]: DFD16[1]})
level2.update({name: title for name, (title, _) in v2.L2_NEW.items()})
level2_procs = {}
for name, (_, spec) in list(dfd.L2.items()) + [(DFD15[0], (None, DFD15[2])), (DFD16[0], (None, DFD16[2]))] + list(v2.L2_NEW.items()):
    level2_procs[name] = [(pid, label) for _, pid, label in spec["procs"]]
export = dict(
    actors=[list(a) for a in model.ACTORS],
    ucs=[dict(id=u["id"], title=u["title"], boundary=u["boundary"], primary=u["primary"], secondary=u["secondary"],
              cases=[dict(id=c[0], name=c[1], phase=c[2], status=v2.STATUS[c[0]][0], evidence=v2.STATUS[c[0]][1],
                          actors=sorted({a for a, b in u["assoc"] if b == c[0]} | {b for a, b in u["assoc"] if a == c[0]}),
                          detail=(u.get("details") or {}).get(c[0], ("", ""))[0])
                     for c in u["cases"]],
              include=u["include"], extend=u["extend"]) for u in model.UC],
    processes=[list(p) for p in model.PROCESSES],
    stores=[dict(id=s[0], name=s[1], contents=v2.STORE_TABLES.get(s[0], s[2]), protection=s[3]) for s in model.STORES],
    level2=level2, level2_procs=level2_procs, status_names=v2.STATUS_NAMES,
)
json.dump(export, open("model_v2.json", "w"), indent=1)
counts = {}
for u in export["ucs"]:
    for c in u["cases"]:
        counts[c["status"]] = counts.get(c["status"], 0) + 1
print("cases:", sum(counts.values()), counts)
print("copied to", os.path.normpath(PNG))
