"""UML use case diagrams with a deterministic layout, written as SVG and converted to PNG.

Layout: primary actors on the left, secondary (system) actors on the right, use cases inside the
system boundary in two columns: column 0 holds cases a primary actor uses directly; column 1 holds
included, extending and system-side cases, ordered next to the cases they relate to.
"""
import math, os, sys, textwrap
from xml.sax.saxutils import escape
import cairosvg
from model import UC, ACTOR, SUBSYSTEMS

OUT = "out"; os.makedirs(OUT, exist_ok=True)
NAVY, FILL, LINE, MUTED, WHEAT = "#1F3864", "#EAF1FB", "#5B6B7F", "#6B7785", "#7A6327"
FONT = "Liberation Sans, Arial, sans-serif"
CW = 6.6           # average character width at 12.5 px
ROW = 84           # vertical pitch of use cases
EW = 228           # ellipse width
def act_h(name):
    """Vertical room for an actor: figure plus its wrapped name."""
    return 64 + 22 + 14 * len(lines_of(name, 18)) + 14


def name_of(a):
    return ACTOR[a][1] if a in ACTOR else a


def lines_of(text, n):
    return textwrap.wrap(text, n) or [""]


class Diagram:
    def __init__(self, title):
        self.title = title
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def svg(self, w, h):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
                f'font-family="{FONT}">'
                '<defs>'
                f'<marker id="open" viewBox="0 0 10 10" refX="9.5" refY="5" markerWidth="9" markerHeight="9" orient="auto-start-reverse">'
                f'<path d="M0,0 L10,5 L0,10" fill="none" stroke="{LINE}" stroke-width="1.4" stroke-dasharray="none"/></marker>'
                f'<marker id="tri" viewBox="0 0 12 12" refX="11.5" refY="6" markerWidth="13" markerHeight="13" orient="auto">'
                f'<path d="M0,0 L12,6 L0,12 Z" fill="#fff" stroke="{LINE}" stroke-width="1.2" stroke-dasharray="none"/></marker>'
                '</defs>'
                f'<rect width="{w}" height="{h}" fill="#ffffff"/>')
        return head + "".join(self.parts) + "</svg>"


def open_head(x, y, angle, size=10):
    """Solid open arrowhead at (x, y) pointing along angle (drawn as a path, not a marker)."""
    a1, a2 = angle + math.pi - 0.45, angle + math.pi + 0.45
    return (f'<path d="M{x + size * math.cos(a1):.1f},{y + size * math.sin(a1):.1f} L{x:.1f},{y:.1f} '
            f'L{x + size * math.cos(a2):.1f},{y + size * math.sin(a2):.1f}" fill="none" stroke="{LINE}" stroke-width="1.4"/>')


def ellipse_point(cx, cy, rx, ry, tx, ty):
    """Point on the ellipse boundary in the direction of (tx, ty)."""
    dx, dy = tx - cx, ty - cy
    if dx == 0 and dy == 0:
        return cx, cy
    t = 1 / math.sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry))
    return cx + dx * t, cy + dy * t


def draw_actor(d, x, y, name):
    """Stick figure centred at x with its head top at y; name below."""
    c = NAVY
    d.add(f'<g stroke="{c}" stroke-width="2" fill="none" stroke-linecap="round">'
          f'<circle cx="{x}" cy="{y + 9}" r="9" fill="#fff"/>'
          f'<line x1="{x}" y1="{y + 18}" x2="{x}" y2="{y + 44}"/>'
          f'<line x1="{x - 15}" y1="{y + 27}" x2="{x + 15}" y2="{y + 27}"/>'
          f'<line x1="{x}" y1="{y + 44}" x2="{x - 13}" y2="{y + 64}"/>'
          f'<line x1="{x}" y1="{y + 44}" x2="{x + 13}" y2="{y + 64}"/></g>')
    lns = lines_of(name, 18)
    wmax = max(len(l) for l in lns) * 7.6 + 8
    d.add(f'<rect x="{x - wmax / 2}" y="{y + 68}" width="{wmax}" height="{14 * len(lns) + 6}" fill="#ffffff" opacity="0.94"/>')
    for i, ln in enumerate(lns):
        d.add(f'<text x="{x}" y="{y + 80 + i * 14}" text-anchor="middle" font-size="12.5" font-weight="bold" fill="#1A1C1A">{escape(ln)}</text>')


def layout(spec):
    """Returns positions for cases and actors."""
    cases = [c[0] for c in spec["cases"]]
    prim, sec = spec["primary"], spec["secondary"]
    assoc = spec["assoc"]
    prim_cases = {}
    for a, b in assoc:
        if a in prim:
            prim_cases.setdefault(b, []).append(prim.index(a))
    col = {c: (0 if c in prim_cases else 1) for c in cases}
    rel = {}
    for a, b in spec["include"] + spec["extend"]:
        rel.setdefault(a, set()).add(b); rel.setdefault(b, set()).add(a)
    sec_of = {}
    for a, b in assoc:
        if b in sec:
            sec_of.setdefault(a, []).append(sec.index(b))
    # column 0 order: by first primary actor, then declaration order
    def edge_hint(c):
        """Cases related to another actor group's case go to the edge facing that group."""
        mine = min(prim_cases[c])
        others = [min(prim_cases[r]) for r in rel.get(c, ()) if r in prim_cases]
        if any(o > mine for o in others):
            return 1
        if any(o < mine for o in others):
            return -1
        return 0
    c0 = sorted([c for c in cases if col[c] == 0], key=lambda c: (min(prim_cases[c]), edge_hint(c), cases.index(c)))
    pos0 = {c: i for i, c in enumerate(c0)}
    # column 1 order: barycenter of related column-0 cases, else of secondary actors; chained cases follow their partner
    c1 = [c for c in cases if col[c] == 1]
    c1_set = set(c1)   # list.sort empties the list while sorting, so membership uses a copy

    parents = {}
    for base, inc in spec["include"]:
        parents.setdefault(inc, []).append(base)
    for ext, base in spec["extend"]:
        parents.setdefault(ext, []).append(base)
    children = {}
    for base, inc in spec["include"]:
        children.setdefault(base, []).append(inc)

    def bary(c, seen=()):
        ps = [pos0[r] for r in rel.get(c, ()) if r in pos0]
        if ps:
            return sum(ps) / len(ps)
        # an included or extending case sits right after its base
        others = [r for r in parents.get(c, ()) if r in c1_set and r not in seen]
        if others:
            return min(bary(o, seen + (c,)) for o in others) + 0.4
        if c in sec_of:
            return min(sec_of[c]) * max(1, len(c0)) / max(1, len(sec))
        # a system-side case with no other anchor sits just before the case it includes
        kids = [k for k in children.get(c, ()) if k in c1_set and k not in seen]
        if kids:
            return min(bary(k, seen + (c,)) for k in kids) - 0.4
        return len(c0)
    c1.sort(key=lambda c: (bary(c), cases.index(c)))
    n = max(len(c0), len(c1), 1)
    return c0, c1, n


def case_size(name, phase):
    ln = lines_of(name, 26)
    h = 34 + 15 * len(ln) + (12 if phase != 1 else 0)
    return EW, max(56, h), ln


def render_uc(spec, fname, package_mode=False):
    c0, c1, n = layout(spec)
    phases = {c[2] for c in spec["cases"]}
    boundary = spec["boundary"]
    if len(phases) == 1 and phases != {1}:
        boundary += f" (Phase {phases.pop()})"
        spec = {**spec, "cases": [(a, b, 1) for a, b, _ in spec["cases"]]}
    info = {c[0]: c for c in spec["cases"]}
    left_x, box_x0 = 92, 196
    col_x = [box_x0 + 40 + EW / 2]
    col_x.append(col_x[0] + EW + (110 if c1 else 0))
    box_x1 = (col_x[1] if c1 else col_x[0]) + EW / 2 + 40
    right_x = box_x1 + 104
    top = 92
    height_cases = n * ROW
    # distribute each column over the full height
    def ys(items):
        k = len(items)
        if not k:
            return {}
        step = height_cases / k
        return {c: top + 30 + step * (i + 0.5) for i, c in enumerate(items)}
    y = {**ys(c0), **ys(c1)}
    x = {c: col_x[0] for c in c0}; x.update({c: col_x[1] for c in c1})
    box_y1 = top + 30 + height_cases + 18

    # actors at the barycenter of their cases, then spread to avoid overlaps
    def place(actors, side):
        want = []
        for a in actors:
            linked = [b for p, b in spec["assoc"] if p == a] + [p for p, b in spec["assoc"] if b == a]
            linked = [c for c in linked if c in y]
            want.append(sum(y[c] for c in linked) / len(linked) if linked else top + height_cases / 2)
        order = sorted(range(len(actors)), key=lambda i: want[i])
        placed, last, last_h = {}, top - 200, 0
        for i in order:
            yy = max(want[i] - 40, last + last_h)
            placed[actors[i]] = yy; last = yy; last_h = act_h(name_of(actors[i]))
        # pull the group up if it overflows the box
        overflow = last + last_h - (box_y1 + 30)
        if overflow > 0:
            for a in placed:
                placed[a] -= overflow
            mn = min(placed.values())
            if mn < top - 20:
                for a in placed:
                    placed[a] += (top - 20 - mn)
        return placed
    ay = place(spec["primary"], "L"); sy = place(spec["secondary"], "R")
    bottoms = [v + act_h(name_of(a)) for a, v in list(ay.items()) + list(sy.items())]
    H = int(max([box_y1] + bottoms) + 40)
    W = int(right_x + 100 if spec["secondary"] else box_x1 + 40)
    d = Diagram(spec["title"])
    # boundary
    d.add(f'<rect x="{box_x0}" y="{top}" width="{box_x1 - box_x0}" height="{box_y1 - top}" rx="14" fill="#FBFCFE" stroke="{NAVY}" stroke-width="1.6"/>')
    d.add(f'<text x="{box_x0 + 16}" y="{top + 24}" font-size="14.5" font-weight="bold" fill="{NAVY}">{escape(boundary)}</text>')
    d.add(f'<text x="{W / 2}" y="34" text-anchor="middle" font-size="17" font-weight="bold" fill="#1A1C1A">{escape(spec["id"] + "  " + spec["title"])}</text>')

    sizes = {c: case_size(info[c][1], info[c][2]) for c in x}
    # associations (drawn first, under the shapes)
    for a, b in spec["assoc"]:
        if a in ay:   # primary actor -> case
            ax, ayy = left_x + 22, ay[a] + 30
            if package_mode:   # attach to the package's near edge so no line crosses a package
                ex, eyy = x[b] - sizes[b][0] / 2, y[b] + 5
            else:
                ex, eyy = ellipse_point(x[b], y[b], sizes[b][0] / 2, sizes[b][1] / 2, ax, ayy)
        else:         # case -> secondary actor: leave the box horizontally, through a gap if needed
            ax, ayy = right_x - 22, sy[b] + 30
            if package_mode:
                ex, eyy = x[a] + sizes[a][0] / 2, y[a] + 5
                d.add(f'<line x1="{ax:.1f}" y1="{ayy:.1f}" x2="{ex:.1f}" y2="{eyy:.1f}" stroke="{LINE}" stroke-width="1.3"/>')
                continue
            exit_x = box_x1 + 12
            pts = [(x[a] + sizes[a][0] / 2, y[a])]
            if x[a] == col_x[0] and c1:
                blocking = [c for c in c1 if abs(y[c] - y[a]) < sizes[c][1] / 2 + 8]
                if blocking:
                    spans = sorted((y[c] - sizes[c][1] / 2, y[c] + sizes[c][1] / 2) for c in c1)
                    gaps = [(top + 34 + spans[0][0]) / 2] + [(spans[i][1] + spans[i + 1][0]) / 2 for i in range(len(spans) - 1)] + [(spans[-1][1] + box_y1) / 2]
                    gy = min(gaps, key=lambda g: abs(g - y[a]))
                    gx = (col_x[0] + EW / 2 + col_x[1] - EW / 2) / 2
                    pts += [(gx, y[a]), (gx, gy)]
                    pts.append((exit_x, gy))
                else:
                    pts.append((exit_x, y[a]))
            else:
                pts.append((exit_x, y[a]))
            pts.append((ax, ayy))
            path = " ".join(f"{px:.1f},{py:.1f}" for px, py in pts)
            d.add(f'<polyline points="{path}" fill="none" stroke="{LINE}" stroke-width="1.3" stroke-linejoin="round"/>')
            continue
        d.add(f'<line x1="{ax:.1f}" y1="{ayy:.1f}" x2="{ex:.1f}" y2="{eyy:.1f}" stroke="{LINE}" stroke-width="1.3"/>')
    # include / extend
    labels = []
    for kind, pairs in (("include", spec["include"]), ("extend", spec["extend"])):
        for s, t in pairs:
            sx0, sy0 = ellipse_point(x[s], y[s], sizes[s][0] / 2, sizes[s][1] / 2, x[t], y[t])
            tx0, ty0 = ellipse_point(x[t], y[t], sizes[t][0] / 2, sizes[t][1] / 2, x[s], y[s])
            if x[s] == x[t] and abs(y[s] - y[t]) > ROW * 1.2:   # same column, not adjacent: bow outwards
                bow = 70 if x[s] == col_x[1] else -70
                side = x[s] + (sizes[s][0] / 2 if bow > 0 else -sizes[s][0] / 2)
                sx0, sy0, tx0, ty0 = side, y[s], side, y[t]
                cx_ = side + bow
                d.add(f'<path d="M{sx0:.1f},{sy0:.1f} C{cx_:.1f},{sy0:.1f} {cx_:.1f},{ty0:.1f} {tx0:.1f},{ty0:.1f}" fill="none" '
                      f'stroke="{LINE}" stroke-width="1.3" stroke-dasharray="6,4"/>')
                d.add(open_head(tx0, ty0, math.atan2(0, tx0 - cx_)))
                labels.append((cx_ - bow * 0.25, (sy0 + ty0) / 2, kind))
            else:
                d.add(f'<line x1="{sx0:.1f}" y1="{sy0:.1f}" x2="{tx0:.1f}" y2="{ty0:.1f}" stroke="{LINE}" stroke-width="1.3" '
                      f'stroke-dasharray="6,4"/>')
                d.add(open_head(tx0, ty0, math.atan2(ty0 - sy0, tx0 - sx0)))
                for f in (0.5, 0.38, 0.62, 0.3, 0.7):
                    lx, ly = sx0 + (tx0 - sx0) * f, sy0 + (ty0 - sy0) * f
                    if all(abs(lx - a) > 60 or abs(ly - b) > 16 for a, b, _ in labels):
                        break
                labels.append((lx, ly, kind))
    # generalization between primary actors
    for child, parent in spec.get("gen", []):
        if child in ay and parent in ay:
            y1, y2 = ay[child] + 64, ay[parent]
            if y1 > y2:
                y1, y2 = ay[child], ay[parent] + 92
            d.add(f'<line x1="{left_x - 30}" y1="{y1 + 8}" x2="{left_x - 30}" y2="{y2 - 4}" stroke="{LINE}" stroke-width="1.3" marker-end="url(#tri)"/>')
    # use cases
    for c in x:
        w, h, ln = sizes[c]
        cid, name, phase = info[c]
        if package_mode:
            d.add(f'<path d="M{x[c] - w / 2},{y[c] - h / 2 + 10} h{70} v-10 h{48} v10 H{x[c] + w / 2} V{y[c] + h / 2} H{x[c] - w / 2} Z" '
                  f'fill="{FILL}" stroke="{NAVY}" stroke-width="1.4"/>')
        else:
            d.add(f'<ellipse cx="{x[c]}" cy="{y[c]}" rx="{w / 2}" ry="{h / 2}" fill="{FILL}" stroke="{NAVY}" stroke-width="1.4"/>')
        ty = y[c] - (len(ln) * 15 + (12 if phase != 1 else 0)) / 2 + 2
        tagtxt = cid if package_mode else f"UC-{cid}"
        d.add(f'<text x="{x[c]}" y="{ty}" text-anchor="middle" font-size="9.5" fill="{MUTED}">{tagtxt}</text>')
        for i, l in enumerate(ln):
            d.add(f'<text x="{x[c]}" y="{ty + 15 + i * 15}" text-anchor="middle" font-size="12.5" fill="#1A1C1A">{escape(l)}</text>')
        if phase != 1:
            d.add(f'<text x="{x[c]}" y="{ty + 15 + len(ln) * 15}" text-anchor="middle" font-size="9.5" fill="{WHEAT}">Phase {phase}</text>')
    # relationship labels on top
    for lx, ly, kind in labels:
        t = f"«{kind}»"
        d.add(f'<rect x="{lx - 27}" y="{ly - 10}" width="54" height="14" fill="#ffffff" opacity="0.92"/>'
              f'<text x="{lx}" y="{ly + 1}" text-anchor="middle" font-size="10" font-style="italic" fill="{LINE}">{t}</text>')
    for a, yy in ay.items():
        draw_actor(d, left_x, yy, ACTOR[a][1] if a in ACTOR else a)
    for a, yy in sy.items():
        draw_actor(d, right_x, yy, ACTOR[a][1] if a in ACTOR else a)
    svg = d.svg(W, H)
    open(f"{OUT}/{fname}.svg", "w").write(svg)
    cairosvg.svg2png(bytestring=svg.encode(), write_to=f"{OUT}/{fname}.png", output_width=W * 2)
    print(fname, W, H)


# ---------------------------------------------------------------- overview (actor groups to subsystems)
GROUPS = [
    ("g_cust", "Customers", ["visitor", "passenger", "daily", "shipper", "recipient"]),
    ("g_carr", "Carriers and crews", ["owner", "scheduler", "accountant", "driver"]),
    ("g_log", "Logistics operators", ["hub", "courier", "apoint"]),
    ("g_part", "Service partners", ["fuel", "reststop", "loyalty"]),
    ("g_chan", "Agencies and corporate", ["agency", "corporate", "affiliate"]),
    ("g_staff", "Platform staff", ["admin", "finance", "support", "marketing", "dpo", "aisup", "acctofficer", "compliance"]),
    ("g_auth", "Authorities and regulator", ["authority", "regulator", "inspector", "verifier"]),
]
SYSGROUPS = [
    ("x_pay", "Payment gateways and bank", ["gateway"]),
    ("x_gov", "Government, security and border systems", ["secauth", "border", "govlic"]),
    ("x_fin", "Tax authority and ERP", ["tax", "erp"]),
    ("x_ext", "Global couriers and intermediary platforms", ["global", "ota"]),
    ("x_svc", "CRM, notification providers and devices", ["crm", "notify", "gate"]),
]


def overview_spec():
    members = {g: m for g, _, m in GROUPS + SYSGROUPS}
    for g, name, _ in GROUPS + SYSGROUPS:
        ACTOR[g] = (g, name)
    assoc = set()
    for u in UC:
        sid = [s for s, _, uc in SUBSYSTEMS if uc == u["id"]][0]
        involved = set(u["primary"]) | set(u["secondary"])
        for g, _, m in GROUPS:
            if involved & set(m):
                assoc.add((g, sid))
        for g, _, m in SYSGROUPS:
            if involved & set(m):
                assoc.add((sid, g))
    return dict(id="UC-0", title="System use case overview", boundary="Masslak platform: subsystems",
                primary=[g for g, _, _ in GROUPS], secondary=[g for g, _, _ in SYSGROUPS],
                cases=[(s, name, 1) for s, name, _ in SUBSYSTEMS], assoc=sorted(assoc), include=[], extend=[])


if __name__ == "__main__":
    only = sys.argv[1:]
    if not only or "UC-0" in only:
        render_uc(overview_spec(), "UC-0", package_mode=True)
    for u in UC:
        if not only or u["id"] in only:
            render_uc(u, u["id"])
