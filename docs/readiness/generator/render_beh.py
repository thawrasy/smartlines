"""Renders the behaviour diagrams (state, sequence, activity) of models.py and models_beh.py with Mermaid. Run from this
folder:

    MMDC=/path/to/mmdc PUPPETEER_CONFIG=/path/to/config.json python3 render_beh.py

Output: ../png/v2."""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work2", "mmd")
PNG = os.path.join(HERE, "..", "png", "v2")
os.makedirs(WORK, exist_ok=True); os.makedirs(PNG, exist_ok=True)
sys.path.insert(0, HERE)
from models import STATES, SEQUENCES                      # noqa: E402
from models_beh import STATES2, SEQUENCES2, ACTIVITIES     # noqa: E402

mmdc, config = os.environ.get("MMDC", "mmdc"), os.environ.get("PUPPETEER_CONFIG")
for name, (_, text) in {**STATES, **STATES2, **SEQUENCES, **SEQUENCES2, **ACTIVITIES}.items():
    src = os.path.join(WORK, f"{name}.mmd")
    open(src, "w").write(text)
    cmd = [mmdc, "-i", src, "-o", os.path.join(PNG, f"{name}.png"), "-b", "white", "-s", "2"]
    if config:
        cmd += ["-p", config]
    if name.startswith("AC-"):            # activity diagrams: tighter spacing, drawn at their real size
        cmd += ["-c", os.path.join(HERE, "mermaid_flow.json")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"{name}: {r.stderr[-400:]}")
    print(name, "ok")
