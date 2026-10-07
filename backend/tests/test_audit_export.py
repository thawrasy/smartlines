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


def test_signed_chain_detects_forgery_and_truncation(tmp_path, monkeypatch):
    """Tamper drill (audit T3-13): a forged manifest, an unsigned one and a chain cut short are all found."""
    priv, pub = tmp_path / "audit.key", tmp_path / "audit.pub"
    audit_export.keygen(priv, pub)
    monkeypatch.setenv("MASSLAK_AUDIT_SIGNING_KEY", str(priv))
    out = tmp_path / "archive"
    first = asyncio.run(audit_export.export(out))
    assert first is not None and first.with_suffix(".sig").exists()
    key = audit_export._public_key(pub)
    assert audit_export.verify(out, key) == []
    tip = audit_export.head(out)
    assert tip["signed"] and tip["sequence"] == 1
    # an administrator rewrites the manifest to hide a file: the hash chain alone could be rebuilt, the signature cannot
    data = json.loads(first.read_text())
    data["files"] = data["files"][1:]
    first.write_text(json.dumps(data, indent=1))
    assert any("signature does not match" in p for p in audit_export.verify(out, key))
    # a manifest without its signature is reported
    first.with_suffix(".sig").unlink()
    assert any("not signed" in p for p in audit_export.verify(out, key))
    # removing the tip of the chain is found against the sequence the custodian recorded
    for m in (out / "manifests").glob("*"):
        m.unlink()
    assert any("manifests removed from the end" in p for p in audit_export.verify(out, key, min_sequence=tip["sequence"]))
