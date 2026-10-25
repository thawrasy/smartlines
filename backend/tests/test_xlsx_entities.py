"""Uploaded workbooks are parsed with defusedxml (the review before release 1.52.0): an Excel file whose XML declares
entities, the "billion laughs" expansion among them, is refused by every importer as a file error, never expanded and
never answered with a server error. openpyxl uses defusedxml only when it is installed, so the image's locked
requirements name it."""
import io
import zipfile

import openpyxl
import pytest

from app.errors import ApiError
from app.modules.geo import importer, ports, roads
from app.modules.geo.importer import GeoFileError
from app.modules.registry import importer as registry_importer
from app.modules.registry import vehicles
from app.modules.registry.importer import RegistryFileError

BOMB = (b'<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaaaaaaaa">'
        + b"".join(b'<!ENTITY %s "%s">' % (bytes([98 + i]), (b"&" + bytes([97 + i]) + b";") * 10) for i in range(8))
        + b"]>")


def _workbook(part: str) -> bytes:
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(["crossing_code", "name"])
    ws.append(["LND-LB-01", "text"])
    plain = io.BytesIO()
    wb.save(plain)
    out = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(plain.getvalue())) as zin, zipfile.ZipFile(out, "w") as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == part:
                data = BOMB + (data.split(b"?>", 1)[1] if data.startswith(b"<?xml") else data)
            zout.writestr(item, data)
    return out.getvalue()


def test_openpyxl_parses_with_defusedxml():
    import openpyxl.xml
    assert openpyxl.xml.DEFUSEDXML, "defusedxml is not installed: uploaded workbooks would expand XML entities"


@pytest.mark.parametrize("part", ["xl/worksheets/sheet1.xml", "xl/workbook.xml"])
@pytest.mark.parametrize("reader,error", [
    (ports.read, GeoFileError), (roads.read, GeoFileError), (importer.read, GeoFileError),
    (lambda d: registry_importer.read(d, "BANK"), RegistryFileError), (vehicles.read, ApiError)])
def test_a_workbook_with_entities_is_a_file_error(part, reader, error):
    with pytest.raises(error):
        reader(_workbook(part))
