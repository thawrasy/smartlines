"""The vehicle's placard (1169, N48): two pages, one for the front windscreen and one for the rear window, A3 by default
or A4. The code is short (16 capital letters and digits), so the QR is the smallest symbol (21 x 21 modules) and fills
the page's width: about 12 mm a module on A3 and 9 mm on A4, readable from a distance and from a moving vehicle. Under
it: the plate, the carrier and the placard's serial, in Arabic and English (the API's message files, placard)."""
from __future__ import annotations

import io

from ..notify.render import messages
from ..reports.export import _fonts, _shape


def pdf(token: str, carrier: str, plate: str, seats: int | None, serial: int, size: str = "A3") -> bytes:
    from reportlab.graphics import renderPDF
    from reportlab.graphics.barcode.qr import QrCodeWidget
    from reportlab.graphics.shapes import Drawing
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import A3, A4
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas

    regular, bold, mono = _fonts()
    ar, en = messages("ar")["placard"], messages("en")["placard"]
    navy = colors.HexColor("#0B1F3F")
    out = io.BytesIO()
    page = A3 if size == "A3" else A4
    k = 1.41 if size == "A3" else 1.0                       # type scales with the page
    c = canvas.Canvas(out, pagesize=page)
    c.setTitle(f"{plate} {en['title']}")
    w, h = page
    for side in ("front", "rear"):
        # a thin band in the identity navy, with the title in both languages
        band = 26 * mm * k
        c.setFillColor(navy)
        c.rect(0, h - band, w, band, stroke=0, fill=1)
        c.setFillColor(colors.white)
        c.setFont(bold, 22 * k)
        c.drawRightString(w - 12 * mm, h - band + 9 * mm * k, _shape(ar["title"], True))
        c.setFont(bold, 17 * k)
        c.drawString(12 * mm, h - band + 9 * mm * k, en["title"])
        c.setFont(regular, 9 * k)
        c.drawRightString(w - 12 * mm, h - band + 3.5 * mm * k, _shape(ar[side], True))
        c.drawString(12 * mm, h - band + 3.5 * mm * k, en[side])
        # the code fills the width; the symbol keeps its own quiet margin of modules
        side_len = w - 16 * mm
        widget = QrCodeWidget(token, barLevel="M", barBorder=2)
        x0, y0, x1, y1 = widget.getBounds()
        d = Drawing(side_len, side_len, transform=[side_len / (x1 - x0), 0, 0, side_len / (y1 - y0), 0, 0])
        d.add(widget)
        renderPDF.draw(d, c, 8 * mm, h - band - 4 * mm - side_len)
        # the vehicle: the plate in very large type, then the carrier, seats and serial, then what the code is for
        y = h - band - 14 * mm * k - side_len
        c.setFillColor(navy)
        c.setFont(mono, 40 * k)
        c.drawCentredString(w / 2, y, plate)
        c.setFont(bold, 15 * k)
        c.drawCentredString(w / 2, y - 11 * mm * k, _shape(carrier, True))
        c.setFont(regular, 11 * k)
        c.drawCentredString(w / 2, y - 18 * mm * k, f"{en['seats']} {seats or '-'}   |   {en['serial']} {serial}   |   {token}")
        c.setFont(regular, 9.5 * k)
        c.setFillColor(colors.HexColor("#333333"))
        c.drawCentredString(w / 2, y - 26 * mm * k, _shape(ar["scan"], True))
        c.drawCentredString(w / 2, y - 31 * mm * k, en["scan"])
        c.setFont(regular, 8 * k)
        c.drawCentredString(w / 2, 10 * mm, _shape(ar["keep"], True))
        c.drawCentredString(w / 2, 6 * mm, en["keep"])
        c.showPage()
    c.save()
    return out.getvalue()
