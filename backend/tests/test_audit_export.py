"""Write-once archive of the audit logs (third-party audit R-09): the export chains its manifests, and an edited or removed exported
file is found by verify."""
import asyncio
import gzip
import json

from app.tools import audit_export


def test_export_is_incremental_and_tampering_is_detected(tmp_path):
    first = asyncio.run(audit_export.export(tmp_path))
    assert first is not None and audit_export.verify(tmp_path) == []
    files = json.loads(first.read_text())["files"]
    assert {f["table"] for f in files} >= {"audit.activity_log", "audit.row_change"}
    # nothing is exported twice
    second = asyncio.run(audit_export.export(tmp_path))
    if second is not None:
        old = {f["table"]: f["last_id"] for f in files}
        assert all(f["first_id"] > old.get(f["table"], 0) for f in json.loads(second.read_text())["files"])
    # an edited file breaks the chain
    victim = tmp_path / files[0]["file"]
    with gzip.open(victim, "at", encoding="utf-8") as fh:
        fh.write('{"forged": true}\n')
    assert any("content changed" in p for p in audit_export.verify(tmp_path))
    # and so does a removed file
    victim.unlink()
    assert any("missing" in p for p in audit_export.verify(tmp_path))
