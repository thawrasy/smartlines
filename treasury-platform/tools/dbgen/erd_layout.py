#!/usr/bin/env python3
"""erd_layout.py — entity-relationship charts in the style of SQL Server database diagrams.

A table is a box: a header with the schema-qualified name, then one row per key column with
KEY (PK / FK / UQ), COLUMN, TYPE and NULL, taken from the generated T-SQL DDL (the source of truth).
Every relationship is an orthogonal connector anchored on the exact key row it uses:

- parent end: one bar (exactly one parent) or two bars (mandatory foreign key); a bar with a circle
  when the foreign key is optional (zero or one parent);
- child end: a crow's foot with a circle (zero or many children).

Layout: tables sit in columns by dependency depth, parents on the left. A connector leaves its parent on
the right edge, bends only inside the gap between two columns, and enters the child on the left edge.
A connector that spans more than one column runs over the top of the chart, above every table, so it
never crosses a table. Relationships inside a self-referencing table leave and enter on the right edge.

Tenant columns: every composite key starts with TenantId. TenantId is not drawn (the legend says so), and
the relations tables in the document list the full key. TenantId → plat.Tenant (ownership) is not drawn.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ddl_keys

FONT_DIR = '/usr/share/fonts/truetype/liberation'
FONT_FILES = {'reg': 'LiberationSans-Regular.ttf', 'bold': 'LiberationSans-Bold.ttf', 'ital': 'LiberationSans-Italic.ttf'}
DPI = 220
PX = DPI / 72                       # pixels per point
NAVY, GREY, LIGHT, RULE = '#1F3A5F', '#5B6670', '#E8EEF6', '#D5DCE5'
INK, MUTED, EDGE, WHITE = '#1F2937', '#6B7280', '#1F2937', '#FFFFFF'
TENANT = 'TenantId'

# provenance and audit columns: traceability links, listed in the relations tables but not drawn
PROVENANCE = {'SourceDocumentId', 'CandidateASourceDocumentId', 'CandidateBSourceDocumentId', 'VerifiedBy',
              'ConflictId', 'SupersedesId', 'CreatedBy', 'UpdatedBy', 'AssignedBy', 'GrantedBy', 'RevokedBy',
              'EndedBy', 'ActorUserId', 'OnBehalfOfUserId'}

# sizes in points (every text size is at least 7 pt at natural scale)
TITLE_PT, HEAD_PT, CELL_PT, TYPE_PT, KEY_PT, MORE_PT = 9.0, 7.0, 8.0, 7.6, 7.6, 7.4
HEAD_H, COL_H, ROW_H, MORE_H = 17.0, 12.0, 13.5, 12.0
PAD = 4.0
GAP_X = 100.0                       # distance between two columns (rank gap)
GAP_Y = 24.0                        # vertical distance between two tables in a column
MARGIN_GAP = 18.0                   # connector bends stay this far from the table edges
LANE_SP = 8.0
EXIT_SP = 4.2                     # spacing of connectors that leave the same parent key row
SHARED_MH, SHARED_CR = 1.6, 1.6   # bar half-height and circle radius when several relations leave one key row
HOP = 2.6                          # radius of the bump where a connector crosses another one
CHART_MARGIN = 14.0
LINE_PT = 1.0
BOX_PT = 0.9

_fonts = {}


def _font(style, size):
    k = (style, size)
    if k not in _fonts:
        _fonts[k] = ImageFont.truetype(os.path.join(FONT_DIR, FONT_FILES[style]), size)
    return _fonts[k]


def text_w(s, style, pt):
    """Width in points, measured with the font at ten times the size for precision."""
    return _font(style, pt * 10).getlength(s) / 10


# ---------------------------------------------------------------- model → chart

def is_owner_fk(f):
    return f['cols'] == [TENANT] and f['parent'] == 'plat.Tenant'


def is_provenance_fk(f):
    return any(c in PROVENANCE for c in f['cols'] if c != TENANT)


def non_tenant(cols):
    out = [c for c in cols if c != TENANT]
    return out or [TENANT]


def build_chart(key, members, allowed=None):
    """Chart model for the tables in `members`. Parents outside the chart appear as grey reference boxes."""
    inside = set(members)
    fks = [f for f in ddl_keys.foreign_keys()
           if f['child'] in inside and not is_owner_fk(f) and not is_provenance_fk(f)
           and (allowed is None or f['parent'] in allowed)]
    refs = sorted({f['parent'] for f in fks if f['parent'] not in inside})
    col_info = {}
    for fq in list(members) + refs:
        col_info[fq] = {n: nn for n, _, nn in ddl_keys.columns(fq)}
    edges = []
    for f in fks:
        ccol, pcol = non_tenant(f['cols'])[-1], non_tenant(f['pcols'])[-1]
        mandatory = all(col_info[f['child']][c] for c in non_tenant(f['cols']))
        edges.append({'child': f['child'], 'parent': f['parent'], 'ccol': ccol, 'pcol': pcol,
                      'mandatory': mandatory, 'columns': non_tenant(f['cols'])})
    nodes = []
    for fq in list(members) + refs:
        own = fq in inside
        pk = [c for c in ddl_keys.pk_cols(fq)]
        pk_show = [c for c in pk if c != TENANT] or [c for c in pk]
        fk_cols = {c for f in fks if f['child'] == fq for c in non_tenant(f['cols'])}
        ref_cols = {c for f in fks if f['parent'] == fq for c in non_tenant(f['pcols'])}
        names = [n for n, _, _ in ddl_keys.columns(fq)]
        types = {n: t for n, t, _ in ddl_keys.columns(fq)}
        shown = [c for c in pk_show]
        for c in names:
            if c == TENANT or c in shown:
                continue
            if (own and c in fk_cols) or c in ref_cols:
                shown.append(c)
        rows = []
        for c in shown:
            k = []
            if c in pk: k.append('PK')
            if c in fk_cols and own: k.append('FK')
            if c in ref_cols and c not in pk: k.append('UQ')
            rows.append({'name': c, 'type': types.get(c, ''), 'not_null': col_info[fq].get(c, False),
                         'key': ' '.join(k),
                         'exits': sum(1 for e in edges if e['parent'] == fq and e['pcol'] == c)})
        hidden = sum(1 for c in names if c != TENANT and c not in shown)
        nodes.append({'fq': fq, 'own': own, 'rows': rows, 'hidden': hidden})
    return {'key': key, 'nodes': nodes, 'edges': edges}


# ---------------------------------------------------------------- geometry

def col_h(node):
    """Reference boxes (grey, outside the chart's own tables) have no column-header band: they are compact."""
    return COL_H if node['own'] else 0.0


def row_h(r):
    """A key row is ROW_H high; a key that several relations leave is taller, so each connector has its own band."""
    k = r.get('exits', 0)
    return ROW_H if k <= 1 else max(ROW_H, (k - 1) * EXIT_SP + 2 * SHARED_MH + 4)


def row_top(node, i):
    """Offset of the top of key row i, measured from the top of its table."""
    return HEAD_H + col_h(node) + sum(row_h(r) for r in node['rows'][:i])


def body_h(node):
    return sum(row_h(r) for r in node['rows'])


def table_geom(node):
    rows = node['rows']
    key_w = max([text_w(r['key'], 'bold', KEY_PT) for r in rows if r['key']] + [text_w('KEY', 'reg', HEAD_PT)]) + 2 * PAD
    name_w = max([text_w(r['name'], 'reg', CELL_PT) for r in rows] + [text_w('COLUMN', 'reg', HEAD_PT)]) + 2 * PAD + 6
    type_w = max([text_w(r['type'], 'reg', TYPE_PT) for r in rows] + [text_w('TYPE', 'reg', HEAD_PT)]) + 2 * PAD + 6
    null_w = max(text_w('not null', 'reg', TYPE_PT), text_w('NULL', 'reg', HEAD_PT)) + 2 * PAD + 2
    head_w = text_w(node['fq'], 'bold', TITLE_PT) + 2 * PAD + 2
    body_w = key_w + name_w + type_w + null_w
    w = max(head_w, body_w)
    name_w += w - body_w
    h = HEAD_H + col_h(node) + body_h(node) + (MORE_H if node['hidden'] else 0) + 2
    return {'w': w, 'h': h, 'key_w': key_w, 'name_w': name_w, 'type_w': type_w, 'null_w': null_w}


def row_index(node, col):
    for i, r in enumerate(node['rows']):
        if r['name'] == col:
            return i
    raise ValueError(f'{node["fq"]} does not show column {col}')


def row_off(node, col):
    """Vertical offset of the centre of a key row, measured from the top of its table."""
    i = row_index(node, col)
    return row_top(node, i) + row_h(node['rows'][i]) / 2


def ranks(nodes, edges):
    """Dependency depth: parents in lower columns. Cycles are broken by DFS; back edges are drawn leftwards."""
    names = [n['fq'] for n in nodes]
    succ = {n: [] for n in names}
    for e in edges:
        if e['child'] != e['parent']:
            succ[e['parent']].append(e['child'])
    state, order, back = {}, [], set()

    def dfs(u):
        state[u] = 1
        for v in succ[u]:
            if state.get(v) == 1:
                back.add((u, v))
            elif v not in state:
                dfs(v)
        state[u] = 2
        order.append(u)

    for n in names:
        if n not in state:
            dfs(n)
    rank = {n: 0 for n in names}
    for u in reversed(order):
        for v in succ[u]:
            if (u, v) not in back:
                rank[v] = max(rank[v], rank[u] + 1)
    return rank


def layout(chart, rk, geo):
    """Columns by depth, tables stacked inside each column. Returns columns, x positions, widths and tops."""
    nodes = {n['fq']: n for n in chart['nodes']}
    edges = chart['edges']
    ncol = max(rk.values()) + 1
    cols = [sorted(f for f in nodes if rk[f] == r) for r in range(ncol)]
    assert all(cols), 'columns must be contiguous'
    col_w = [max(geo[f]['w'] for f in cols[r]) for r in range(ncol)]
    col_x = []
    x = 0.0
    for r in range(ncol):
        col_x.append(x)
        x += col_w[r] + GAP_X
    top = {}
    for r in range(ncol):
        t = 0.0
        for f in cols[r]:
            top[f] = t
            t += geo[f]['h'] + GAP_Y

    def ay(f, col):
        return top[f] + row_off(nodes[f], col)

    # Gauss-Seidel sweeps: each table moves towards the rows its connectors reach, then the whole chart is re-based
    for _ in range(12):
        for r in list(range(ncol)) + list(range(ncol - 1, -1, -1)):
            want = {}
            for f in cols[r]:
                vals = []
                for e in edges:
                    if e['parent'] == e['child']:
                        continue
                    if e['child'] == f:
                        vals.append(ay(e['parent'], e['pcol']) - row_off(nodes[f], e['ccol']))
                    elif e['parent'] == f:
                        vals.append(ay(e['child'], e['ccol']) - row_off(nodes[f], e['pcol']))
                want[f] = sum(vals) / len(vals) if vals else top[f]
            order = sorted(cols[r], key=lambda f: (want[f], f))
            prev = None
            for f in order:
                y = want[f] if prev is None else max(want[f], prev)
                top[f] = y
                prev = y + geo[f]['h'] + GAP_Y
            cols[r] = order
        base = min(top.values())
        for f in top:
            top[f] -= base
    return cols, col_x, col_w, top


def _gap_x(g, col_x, col_w):
    return col_x[g] + col_w[g] + GAP_X / 2


def route(chart, rk, geo, col_x, col_w, top):
    """Orthogonal path for every relation. Preference: one bend in the gap next to the child (the horizontal
    leg at the parent row crosses the columns in between only where no table sits), then one bend in the gap
    next to the parent (horizontal leg at the child row), then a route over the top of the chart."""
    nodes = {n['fq']: n for n in chart['nodes']}
    rects = [(fq, (col_x[rk[fq]], top[fq], col_x[rk[fq]] + geo[fq]['w'], top[fq] + geo[fq]['h'])) for fq in nodes]

    def clear(pts, skip=()):
        for a, b in zip(pts, pts[1:]):
            for fq, r in rects:
                if fq not in skip and _hits(a, b, (r[0] - 3, r[1] - 3, r[2] + 3, r[3] + 3)):
                    return False
        return True

    exit_n, exit_k, exit_offset, exit_marks = {}, {}, {}, {}
    for e in chart['edges']:
        exit_n[(e['parent'], e['pcol'])] = exit_n.get((e['parent'], e['pcol']), 0) + 1
    for i, e in enumerate(chart['edges']):
        key = (e['parent'], e['pcol'])
        k = exit_k.get(key, 0)
        exit_k[key] = k + 1
        n = exit_n[key]
        exit_offset[i] = (k - (n - 1) / 2) * EXIT_SP
        exit_marks[i] = (4.5, 3.1) if n == 1 else (SHARED_MH, SHARED_CR)
    plans = []
    for i, e in enumerate(chart['edges']):
        p, c = e['parent'], e['child']
        pn, cn = nodes[p], nodes[c]
        ya = top[p] + row_off(pn, e['pcol']) + exit_offset[i]
        yb = top[c] + row_off(cn, e['ccol'])
        if p == c:
            right = col_x[rk[p]] + geo[p]['w']
            plans.append({'i': i, 'kind': 'self', 'A': (right, ya), 'B': (right, yb), 'pd': 1, 'cd': 1,
                          'vx': right + 24, 'ya': ya, 'yb': yb, 'mandatory': e['mandatory'],
                          'mh': exit_marks[i][0], 'cr': exit_marks[i][1]})
            continue
        fwd = rk[c] > rk[p]
        A = (col_x[rk[p]] + geo[p]['w'], ya) if fwd else (col_x[rk[p]], ya)
        B = (col_x[rk[c]], yb) if fwd else (col_x[rk[c]] + geo[c]['w'], yb)
        pd, cd = (1, -1) if fwd else (-1, 1)
        ge = rk[p] if fwd else rk[p] - 1          # gap next to the parent
        gn = rk[c] - 1 if fwd else rk[c]          # gap next to the child
        pl = {'i': i, 'A': A, 'B': B, 'pd': pd, 'cd': cd, 'ya': ya, 'yb': yb, 'mandatory': e['mandatory'],
              'mh': exit_marks[i][0], 'cr': exit_marks[i][1]}
        if ge == gn:
            pl.update(kind='direct', gap=ge)
        elif clear([A, (_gap_x(gn, col_x, col_w), ya), (_gap_x(gn, col_x, col_w), yb), B], skip=(p, c)):
            pl.update(kind='direct', gap=gn)
        elif clear([A, (_gap_x(ge, col_x, col_w), ya), (_gap_x(ge, col_x, col_w), yb), B], skip=(p, c)):
            pl.update(kind='direct', gap=ge)
        else:
            pl.update(kind='over', gap_x=ge, gap_y=gn)
        plans.append(pl)

    # one vertical segment per request; requests in the same gap are spread across the gap, sorted by height
    requests = {}
    for pl in plans:
        if pl['kind'] == 'direct':
            requests.setdefault(pl['gap'], []).append(((pl['ya'] + pl['yb']) / 2, pl['i'], 'm'))
        elif pl['kind'] == 'over':
            pl['lane'] = None
            requests.setdefault(pl['gap_x'], []).append((pl['ya'], pl['i'], 'x1'))
            requests.setdefault(pl['gap_y'], []).append((pl['yb'], pl['i'], 'x2'))
    slot = {}
    for g, reqs in requests.items():
        reqs.sort()
        lo, hi = col_x[g] + col_w[g] + MARGIN_GAP, col_x[g + 1] - MARGIN_GAP
        for j, (_, i, which) in enumerate(reqs):
            slot[(i, which)] = lo + (hi - lo) * (j + 1) / (len(reqs) + 1)
    lane_n = 0
    for pl in plans:
        if pl['kind'] == 'self':
            pts = [pl['A'], (pl['vx'], pl['ya']), (pl['vx'], pl['yb']), pl['B']]
        elif pl['kind'] == 'direct':
            xm = slot[(pl['i'], 'm')]
            pts = [pl['A'], (xm, pl['ya']), (xm, pl['yb']), pl['B']]
        else:
            lane = -10 - lane_n * LANE_SP          # above the top of the chart (layout coordinates)
            lane_n += 1
            x1, x2 = slot[(pl['i'], 'x1')], slot[(pl['i'], 'x2')]
            pts = [pl['A'], (x1, pl['ya']), (x1, lane), (x2, lane), (x2, pl['yb']), pl['B']]
            pl['lane'] = lane
        pl['pts'] = pts
    return plans, lane_n


# ---------------------------------------------------------------- checks

def _hits(p, q, r, eps=0.6):
    (x1, y1), (x2, y2) = p, q
    rx0, ry0, rx1, ry1 = r
    return not (max(x1, x2) <= rx0 + eps or min(x1, x2) >= rx1 - eps or
                max(y1, y2) <= ry0 + eps or min(y1, y2) >= ry1 - eps)


def check(plans, rects):
    """Every connector is orthogonal, every segment avoids every table interior, and every endpoint sits on a row."""
    problems = []
    for pl in plans:
        pts = pl['pts']
        for a, b in zip(pts, pts[1:]):
            if a[0] != b[0] and a[1] != b[1]:
                problems.append(f'diagonal segment in edge {pl["i"]}')
            for rect_name, r in rects.items():
                if _hits(a, b, r):
                    problems.append(f'edge {pl["i"]} crosses {rect_name}')
    return problems


# ---------------------------------------------------------------- drawing

def hop_line(d, T, x0, x1, y, crossings, lw):
    """Horizontal connector from x0 to x1 at height y, with a small bump over each crossing vertical."""
    cur = x0
    for xc in crossings:
        d.line([T(cur, y), T(xc - HOP, y)], fill=EDGE, width=lw)
        p0, p1 = T(xc - HOP, y - HOP), T(xc + HOP, y + HOP)
        d.arc([p0[0], p0[1], p1[0], p1[1]], 180, 360, fill=EDGE, width=lw)
        cur = xc + HOP
    d.line([T(cur, y), T(x1, y)], fill=EDGE, width=lw)


def render(chart, out_png):
    nodes = {n['fq']: n for n in chart['nodes']}
    geo = {fq: table_geom(n) for fq, n in nodes.items()}
    rk = ranks(chart['nodes'], chart['edges'])
    cols, col_x, col_w, top = layout(chart, rk, geo)
    plans, n_lanes = route(chart, rk, geo, col_x, col_w, top)
    if n_lanes:                                        # make room above the chart for the over-the-top connectors
        shift = 10 + n_lanes * LANE_SP + 4
        for f in top:
            top[f] += shift
        for pl in plans:
            pl['pts'] = [(x, y + shift) for x, y in pl['pts']]
    rects = {fq: (col_x[rk[fq]], top[fq], col_x[rk[fq]] + geo[fq]['w'], top[fq] + geo[fq]['h']) for fq in nodes}
    problems = check(plans, {k: v for k, v in rects.items()})
    # self-loops sit in the gap to the right of their table; they are checked by construction
    xs = [p[0] for pl in plans for p in pl['pts']] + [r[0] for r in rects.values()] + [r[2] for r in rects.values()]
    ys = [p[1] for pl in plans for p in pl['pts']] + [r[1] for r in rects.values()] + [r[3] for r in rects.values()]
    minx, maxx = min(xs) - CHART_MARGIN, max(xs) + CHART_MARGIN
    miny, maxy = min(ys) - CHART_MARGIN, max(ys) + CHART_MARGIN
    W, H = round((maxx - minx) * PX), round((maxy - miny) * PX)
    img = Image.new('RGB', (W, H), WHITE)
    d = ImageDraw.Draw(img)
    T = lambda x, y: ((x - minx) * PX, (y - miny) * PX)
    lw = max(1, round(LINE_PT * PX))

    verticals = []
    for idx, pl in enumerate(plans):
        for a, b in zip(pl['pts'], pl['pts'][1:]):
            if a[0] == b[0] and a[1] != b[1]:
                verticals.append((idx, a[0], min(a[1], b[1]), max(a[1], b[1])))
    for idx, pl in enumerate(plans):                   # connectors first, under the tables
        for a, b in zip(pl['pts'], pl['pts'][1:]):
            if a[1] == b[1] and a[0] != b[0]:
                x0, x1 = sorted((a[0], b[0]))
                crossings = sorted(x for j, x, y1, y2 in verticals
                                   if j != idx and x0 + HOP + 1.5 < x < x1 - HOP - 1.5 and y1 < a[1] < y2)
                hop_line(d, T, x0, x1, a[1], crossings, lw)
            elif a[0] == b[0] and a[1] != b[1]:
                d.line([T(*a), T(*b)], fill=EDGE, width=lw)

    for fq, n in nodes.items():                        # tables
        x, y = col_x[rk[fq]], top[fq]
        g = geo[fq]
        head = NAVY if n['own'] else GREY
        x0, y0 = T(x, y)
        x1, y1 = T(x + g['w'], y + g['h'])
        d.rectangle([x0, y0, x1, y1], fill=WHITE, outline=head, width=max(1, round(BOX_PT * PX)))
        hx1, hy1 = T(x + g['w'], y + HEAD_H)
        d.rectangle([x0, y0, hx1, hy1], fill=head)
        d.text(T(x + PAD, y + HEAD_H * 0.5 + 0.36 * TITLE_PT), fq, font=_font('bold', TITLE_PT * PX),
               fill=WHITE, anchor='ls')
        if n['rows'] and n['own']:
            cx0, cy0 = T(x, y + HEAD_H)
            cx1, cy1 = T(x + g['w'], y + HEAD_H + col_h(n))
            d.rectangle([cx0, cy0, cx1, cy1], fill=LIGHT)
            kx, nx = x + PAD, x + g['key_w']
            tx, ux = nx + g['name_w'], nx + g['name_w'] + g['type_w']
            ly = y + HEAD_H + col_h(n) / 2 + 0.36 * HEAD_PT
            for label, lx in (('KEY', kx), ('COLUMN', nx + PAD), ('TYPE', tx + PAD), ('NULL', ux + PAD)):
                d.text(T(lx, ly), label, font=_font('reg', HEAD_PT * PX), fill=MUTED, anchor='ls')
        for i, r in enumerate(n['rows']):
            cy = y + row_top(n, i) + row_h(r) / 2
            base = cy + 0.36 * CELL_PT
            if r['key']:
                d.text(T(x + PAD, base), r['key'], font=_font('bold', KEY_PT * PX), fill=NAVY, anchor='ls')
            kx = x + g['key_w']
            d.text(T(kx + PAD, base), r['name'], font=_font('reg', CELL_PT * PX), fill=INK, anchor='ls')
            tx = kx + g['name_w']
            d.text(T(tx + PAD, base), r['type'], font=_font('reg', TYPE_PT * PX), fill=MUTED, anchor='ls')
            ux = tx + g['type_w']
            d.text(T(ux + PAD, base), 'not null' if r['not_null'] else 'null', font=_font('reg', TYPE_PT * PX),
                   fill=MUTED, anchor='ls')
            if i < len(n['rows']) - 1:
                sy = y + row_top(n, i + 1)
                a, b = T(x + 0.5, sy), T(x + g['w'] - 0.5, sy)
                d.line([a, b], fill=RULE, width=max(1, round(0.5 * PX)))
        if n['hidden']:
            my = y + HEAD_H + col_h(n) + body_h(n) + MORE_H / 2 + 0.36 * MORE_PT
            label = f'+ {n["hidden"]} more column' + ('s' if n['hidden'] != 1 else '')
            d.text(T(x + PAD, my), label, font=_font('ital', MORE_PT * PX), fill=MUTED, anchor='ls')

    for pl in plans:                                   # bars, circles and crow's feet, on top of the tables
        ax, ay = pl['A']
        mh, cr, pd = pl['mh'], pl['cr'], pl['pd']
        if pl['mandatory']:
            for off in (5.0, 8.0):
                d.line([T(ax + pd * off, ay - mh), T(ax + pd * off, ay + mh)], fill=EDGE, width=lw)
        else:
            d.line([T(ax + pd * 5.0, ay - mh), T(ax + pd * 5.0, ay + mh)], fill=EDGE, width=lw)
            cx, cy = T(ax + pd * 11.0, ay)
            r = cr * PX
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE, outline=EDGE, width=lw)
        bx, by = pl['B']
        cd = pl['cd']
        apex = (bx + cd * 9.0, by)
        for toe in ((bx, by - 4.5), (bx, by), (bx, by + 4.5)):
            d.line([T(*toe), T(*apex)], fill=EDGE, width=lw)
        cx, cy = T(bx + cd * 13.5, by)
        r = 3.1 * PX
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE, outline=EDGE, width=lw)
    img = img.convert('P', palette=Image.Palette.ADAPTIVE, colors=128)   # print-quality text, small file
    img.save(out_png, dpi=(DPI, DPI), optimize=True)
    return {'w_pt': round(maxx - minx, 1), 'h_pt': round(maxy - miny, 1), 'tables': len(nodes),
            'edges': len(plans), 'over_top': n_lanes, 'columns': len(cols), 'problems': problems}


if __name__ == '__main__':
    import json
    key = sys.argv[1]
    members = sys.argv[2:]
    out = os.path.join(HERE, '..', '..', 'docs', 'diagrams', 'erd-en', key + '.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    print(json.dumps(render(build_chart(key, members), out)))
