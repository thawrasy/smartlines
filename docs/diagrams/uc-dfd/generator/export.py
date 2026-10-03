"""Collects the model, diagram data and narrative into one JSON file for the Word builder."""
import json
from model import ACTORS, ACTOR, UC, SUBSYSTEMS, STORES, PROCESSES
import dfd
from texts import LEVEL1_DESC, LEVEL2_DESC, SPECS, ASSUMPTIONS

# ---- process <-> store access derived from every DFD
access = {}   # (P#, D#) -> set("R"/"W")


def node_maps(spec, level2_parent=None):
    procs = {}
    for nid, pid, _ in spec["procs"]:
        procs[nid] = "P" + (pid.split(".")[0] if level2_parent else pid.lstrip("P"))
    for nid, pid in spec.get("refs", []):
        procs[nid] = pid
    stores = {nid: sid for nid, sid in spec["stores"]}
    return procs, stores


def collect(spec, level2=False):
    procs, stores = node_maps(spec, level2)
    for f in spec["flows"]:
        a, b = f[0], f[1]
        if a in procs and b in stores:
            access.setdefault((procs[a], stores[b]), set()).add("W")
        elif a in stores and b in procs:
            access.setdefault((procs[b], stores[a]), set()).add("R")


collect(dfd.LEVEL1A); collect(dfd.LEVEL1B)
for name, (title, spec) in dfd.L2.items():
    collect(spec, level2=True)
# audit logs are written by every process (see assumptions); the auditor reads them in P10
for pid, _ in PROCESSES:
    access.setdefault((f"P{pid}", "D16"), set()).add("W")

# reads implied by the use cases but not drawn, to keep the diagrams readable
IMPLIED_READS = [("P1", "D1"), ("P13", "D6"), ("P13", "D15"), ("P14", "D17"), ("P14", "D5"), ("P10", "D16"), ("P2", "D2"), ("P2", "D3")]
for pk in IMPLIED_READS:
    access.setdefault(pk, set()).add("R")

matrix = {f"P{pid}": {sid: "".join(sorted(access.get((f"P{pid}", sid), set()), key=lambda x: "WR".index(x)))
                      for sid, *_ in STORES} for pid, _ in PROCESSES}
store_rows = []
for sid, name, entities, protection in STORES:
    writers = [p for p in matrix if "W" in matrix[p][sid]]
    readers = [p for p in matrix if "R" in matrix[p][sid]]
    if sid == "D16":
        writers = ["All processes"]
    store_rows.append(dict(id=sid, name=name, entities=entities, protection=protection,
                           writers=", ".join(writers) or "-", readers=", ".join(readers) or "-"))

TRACE = {"UC-1": (["P1", "P4", "P5", "P6", "P10"], ["DFD-4", "DFD-6"]), "UC-2": (["P1", "P8", "P6"], ["DFD-8"]),
         "UC-3": (["P1", "P2", "P3", "P6"], ["DFD-1A"]), "UC-4": (["P7", "P10", "P11"], ["DFD-7", "DFD-10"]),
         "UC-5": (["P9", "P6"], ["DFD-9"]), "UC-6": (["P11", "P6"], ["DFD-11"]), "UC-7": (["P2", "P5", "P6", "P13"], ["DFD-6", "DFD-1B"]),
         "UC-8": (["P10", "P1"], ["DFD-10"]), "UC-9": (["P14", "P4", "P6"], ["DFD-1B"]), "UC-10": (["P12", "P6"], ["DFD-12"])}

uc_out = []
for u in UC:
    rows = []
    for cid, name, phase in u["cases"]:
        actors = [ACTOR[a][1] for a, b in u["assoc"] if b == cid and a in ACTOR] + \
                 [ACTOR[b][1] for a, b in u["assoc"] if a == cid and b in ACTOR]
        desc, ref = u["details"][cid]
        rows.append(dict(id=f"UC-{cid}", name=name, phase=phase, actors=", ".join(actors) or "(included or extending)", desc=desc, ref=ref))
    procs, dfds = TRACE[u["id"]]
    uc_out.append(dict(id=u["id"], title=u["title"], boundary=u["boundary"], rows=rows,
                       primary=[ACTOR[a][1] for a in u["primary"]], secondary=[ACTOR[a][1] for a in u["secondary"]],
                       procs=procs, dfds=dfds,
                       refs=sorted({r.strip() for row in rows for r in row["ref"].replace(" and ", ", ").split(",")}, key=lambda s: [int(x) if x.isdigit() else 0 for x in s.replace("a", "").split(".")[:2] if x.strip().isdigit()] or [99])))

context = dict(left=[dict(name=l, inp=i, out=o) for _, l, i, o in dfd.CONTEXT_LEFT],
               right=[dict(name=l, inp=i, out=o) for _, l, i, o in dfd.CONTEXT_RIGHT])

level2 = []
for name, (title, spec) in dfd.L2.items():
    parent = name.split("-")[1]
    level2.append(dict(id=name, title=title, parent=f"P{parent}", rows=[dict(id=a, name=b, desc=c) for a, b, c in LEVEL2_DESC[name]],
                       stores=sorted({sid for _, sid in spec["stores"]}, key=lambda s: int(s[1:]))))

data = dict(
    actors=[dict(name=n, kind=k, desc=d, ref=r) for _, n, k, d, r in ACTORS],
    subsystems=[dict(id=s, name=n, uc=u) for s, n, u in SUBSYSTEMS],
    uc=uc_out, specs=SPECS, assumptions=ASSUMPTIONS, context=context,
    processes=[dict(id=f"P{pid}", name=name, desc=LEVEL1_DESC[pid][0], ref=LEVEL1_DESC[pid][1],
                    level=("DFD-1A" if int(pid) <= 8 else "DFD-1B"),
                    detail=next((d["id"] for d in level2 if d["parent"] == f"P{pid}"), None)) for pid, name in PROCESSES],
    level2=level2, stores=store_rows, matrix=matrix, store_ids=[s[0] for s in STORES],
)
json.dump(data, open("out/data.json", "w"), indent=1)
print("processes", len(data["processes"]), "use cases", sum(len(u["rows"]) for u in uc_out), "actors", len(data["actors"]))
