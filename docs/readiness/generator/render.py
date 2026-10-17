"""Renders the addendum diagrams: use case and data flow diagrams with the v1.0 renderers (same notation and look), state
and sequence diagrams with Mermaid. Run from this folder:

    MMDC=/path/to/mmdc PUPPETEER_CONFIG=/path/to/config.json python3 render.py

Output: ../png (the document embeds these files)."""
import os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
V1 = os.path.join(HERE, "..", "..", "diagrams", "uc-dfd", "generator")
WORK = os.path.join(HERE, "work")
PNG = os.path.join(HERE, "..", "png")
os.makedirs(WORK, exist_ok=True); os.makedirs(PNG, exist_ok=True)
os.chdir(WORK)                       # the v1.0 renderers write to ./out
sys.path.insert(0, V1); sys.path.insert(0, HERE)

import model                          # noqa: E402  (v1.0 model, extended before the renderers read it)
from models import NEW_ACTORS, NEW_UC, NEW_PROCESSES, NEW_STORES, DFD15, DFD16, STATES, SEQUENCES   # noqa: E402

model.ACTORS += NEW_ACTORS
model.ACTOR.update({a[0]: a for a in NEW_ACTORS})
model.STORES += NEW_STORES
model.STORE.update({s[0]: s for s in NEW_STORES})
model.PROCESSES += NEW_PROCESSES

import ucsvg                          # noqa: E402
import dfd                            # noqa: E402

for spec in NEW_UC:
    ucsvg.render_uc(spec, spec["id"])
for name, title, spec in (DFD15, DFD16):
    # left to right: the externals, the processes and the stores stack in columns, so the diagram fits a portrait page
    dfd.render(name, title, dfd.level(spec), rankdir="LR", extra="ranksep=1.4, nodesep=0.3")

mmdc, config = os.environ.get("MMDC", "mmdc"), os.environ.get("PUPPETEER_CONFIG")
for name, (_, text) in {**STATES, **SEQUENCES}.items():
    src = os.path.join("out", f"{name}.mmd")
    open(src, "w").write(text)
    cmd = [mmdc, "-i", src, "-o", os.path.join("out", f"{name}.png"), "-b", "white", "-s", "2"]
    if config:
        cmd += ["-p", config]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"{name}: {r.stderr[-400:]}")
    print(name, "ok")

for f in os.listdir("out"):
    if f.endswith(".png"):
        shutil.copy(os.path.join("out", f), os.path.join(PNG, f))
print("copied to", os.path.normpath(PNG))
