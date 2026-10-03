"""Notation legends for the use case and data flow diagrams."""
import cairosvg
from ucsvg import Diagram, draw_actor, open_head, NAVY, FILL, LINE, MUTED
import dfd

# use case legend
d = Diagram("legend")
draw_actor(d, 60, 20, "Actor")
d.add(f'<rect x="150" y="14" width="190" height="70" rx="12" fill="#FBFCFE" stroke="{NAVY}" stroke-width="1.6"/>'
      f'<text x="245" y="104" text-anchor="middle" font-size="12" fill="#1A1C1A">System boundary</text>')
d.add(f'<ellipse cx="245" cy="49" rx="80" ry="22" fill="{FILL}" stroke="{NAVY}" stroke-width="1.4"/>'
      f'<text x="245" y="53" text-anchor="middle" font-size="12" fill="#1A1C1A">Use case</text>')
y = 30
for label, dash, marker in (("Association", "", ""), ("«include» (base to included)", "6,4", "open"),
                            ("«extend» (extension to base)", "6,4", "open"), ("Generalization (actor)", "", "url(#tri)")):
    da = f' stroke-dasharray="{dash}"' if dash else ""
    mk = f' marker-end="{marker}"' if marker.startswith("url") else ""
    if marker == "open":
        d.add(open_head(470, y, 0))
    d.add(f'<line x1="390" y1="{y}" x2="470" y2="{y}" stroke="{LINE}" stroke-width="1.4"{da}{mk}/>'
          f'<text x="484" y="{y + 4}" font-size="12" fill="#1A1C1A">{label}</text>')
    y += 22
svg = d.svg(720, 125)
open("out/legend-uc.svg", "w").write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to="out/legend-uc.png", output_width=1440)

# data flow legend
dfd.XLABEL = True
body = "\n".join([
    dfd.ext_node("e", "External entity"), dfd.ext_node("e#2", "Duplicate entity"),
    dfd.proc_node("p", "4.2", "Process"), dfd.proc_node("r", "P6", "Process in another diagram", ref=True),
    dfd.store_node("s", "D6"), dfd.store_node("s2", "D6", duplicate=True),
    '"a1" [shape=point, width=0.01]; "a2" [shape=point, width=0.01];',
    '"a1" -> "a2" [xlabel=<data flow>];',
    '"e" [pos="0,1!"]; "e#2" [pos="2.4,1!"]; "p" [pos="4.8,1!"]; "r" [pos="7.4,1!"]; "s" [pos="0.6,0!"]; "s2" [pos="3.6,0!"];'
    '"a1" [pos="6.0,0!"]; "a2" [pos="7.8,0!"];'])
dfd.render("legend-dfd", "", body, engine="neato", extra="forcelabels=true")
