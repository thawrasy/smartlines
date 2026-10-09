"""Malware scanning of uploaded files (audit T3-15).

Every file is stored as PENDING and stays in quarantine until it is scanned: nothing downloads, signs or approves a file
that is not CLEAN (the database refuses it too). The scan runs right after the upload, and the outbox worker retries
files still pending.

Two layers:
* Built-in checks, always on: the real type from the first bytes must be one we accept and match the stored type, the
  EICAR test signature, active content in PDFs (JavaScript, launch actions, embedded files), and content appended after
  an image's end marker or a PDF's last %%EOF (polyglot files).
* ClamAV, through clamd's INSTREAM command, when MASSLAK_CLAMD is set (host:port or a unix socket path). In production
  ClamAV is required: without it a file stays PENDING (fail closed) and the worker logs an alert. The sandbox may run on
  the built-in checks alone.
"""
from __future__ import annotations

import logging
import os
import re
import socket
import struct
import uuid
from dataclasses import dataclass
from typing import Optional

import asyncpg

from ... import crypto, db
from ...config import get_settings
from . import storage

log = logging.getLogger("masslak.scanner")

EICAR = b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"
PDF_ACTIVE = re.compile(rb"/(JavaScript|JS|Launch|EmbeddedFile|RichMedia|XFA|SubmitForm|ImportData)\b")
MAX_ATTEMPTS = 5


@dataclass(frozen=True)
class Verdict:
    status: str          # CLEAN, REJECTED or QUARANTINED; None-like PENDING is expressed by raising Unavailable
    engine: str
    detail: str


class Unavailable(RuntimeError):
    """The required engine could not give a verdict; the file stays PENDING for a retry."""


def builtin(data: bytes, stored_mime: str) -> Optional[str]:
    """Returns the reason to reject, or None when the built-in checks pass."""
    try:
        mime = storage.detect(data)
    except storage.FileRejected:
        return "TYPE_NOT_ACCEPTED"
    if mime != stored_mime:
        return "TYPE_MISMATCH"
    if EICAR in data:
        return "EICAR_TEST_SIGNATURE"
    if mime == "application/pdf":
        if PDF_ACTIVE.search(data):
            return "PDF_ACTIVE_CONTENT"
        tail = data[data.rfind(b"%%EOF") + 5:] if b"%%EOF" in data else b""
        if len(tail.strip()) > 1024:
            return "DATA_AFTER_EOF"
    elif mime == "image/jpeg":
        end = data.rfind(b"\xff\xd9")
        if end < 0 or len(data) - end - 2 > 1024:
            return "DATA_AFTER_IMAGE"
    elif mime == "image/png":
        end = data.rfind(b"IEND")
        if end < 0 or len(data) - end - 8 > 1024:
            return "DATA_AFTER_IMAGE"
    return None


def _clamd_target() -> Optional[str]:
    return os.environ.get("MASSLAK_CLAMD") or None


def clamav(data: bytes, target: str, timeout: float = 30.0) -> Optional[str]:
    """Streams the file to clamd; returns the signature name when infected, None when clean."""
    if target.startswith("/"):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        address: object = target
    else:
        host, _, port = target.rpartition(":")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        address = (host or "127.0.0.1", int(port or 3310))
    sock.settimeout(timeout)
    try:
        sock.connect(address)
        sock.sendall(b"zINSTREAM\0")
        for i in range(0, len(data), 65536):
            chunk = data[i:i + 65536]
            sock.sendall(struct.pack("!L", len(chunk)) + chunk)
        sock.sendall(struct.pack("!L", 0))
        reply = b""
        while not reply.endswith(b"\0"):
            part = sock.recv(4096)
            if not part:
                break
            reply += part
    except OSError as exc:
        raise Unavailable(f"clamd: {exc}") from exc
    finally:
        sock.close()
    text = reply.rstrip(b"\0").decode(errors="replace")
    if text.endswith("OK"):
        return None
    if text.endswith("FOUND"):
        return text.split(":", 1)[-1].strip().removesuffix(" FOUND")[:120]
    raise Unavailable(f"clamd: {text[:200]}")


def scan(data: bytes, stored_mime: str) -> Verdict:
    reason = builtin(data, stored_mime)
    if reason:
        return Verdict("REJECTED", "builtin", reason)
    target = _clamd_target()
    if target:
        found = clamav(data, target)
        if found:
            return Verdict("QUARANTINED", "clamav", found)
        return Verdict("CLEAN", "builtin+clamav", "")
    if not get_settings().sandbox:
        raise Unavailable("MASSLAK_CLAMD is not set; production files wait for ClamAV")
    return Verdict("CLEAN", "builtin", "sandbox: built-in checks only")


async def scan_file(conn: asyncpg.Connection, ctx: db.Context, file_id: int) -> str:
    """Scans one file inside the caller's transaction; returns its scan status afterwards."""
    async with db.system_scope(conn, ctx):
        f = await conn.fetchrow("""SELECT id, storage_key, enc_key_id, sha256, mime_type, scan_status FROM ref.file_object
                                    WHERE id = $1 FOR UPDATE SKIP LOCKED""", file_id)
        if f is None or f["scan_status"] not in ("PENDING", "SCANNING"):
            return f["scan_status"] if f else "PENDING"
        fc = await crypto.cipher(conn)
        try:
            data = storage.get(fc, f["storage_key"], f["enc_key_id"], bytes(f["sha256"]))
            verdict = scan(data, f["mime_type"])
        except storage.FileRejected as exc:
            verdict = Verdict("QUARANTINED", "integrity", str(exc)[:200])
        except Unavailable as exc:
            # the engine is down, not the file at fault: no attempt is used up, so the file is scanned as soon as the
            # engine is back, however long the outage (the FilesWaitingForScan alert watches the wait)
            log.warning("scanner.unavailable file=%s %s", file_id, exc)
            return "PENDING"
        except Exception:
            # the file made the scan itself fail: count the attempt, so a file that always fails stops being retried
            # after MAX_ATTEMPTS and waits for an operator instead
            log.exception("scanner.error file=%s", file_id)
            await conn.execute("UPDATE ref.file_object SET scan_attempts = scan_attempts + 1 WHERE id = $1", file_id)
            return "PENDING"
        await conn.execute(
            """UPDATE ref.file_object SET scan_status = $2, scanned_at = now(), scan_engine = $3, scan_detail = nullif($4, '')
                WHERE id = $1""", file_id, verdict.status, verdict.engine, verdict.detail)
        if verdict.status != "CLEAN":
            await conn.execute(
                """INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
                   VALUES ('security.file_rejected', 'file_object', $1, jsonb_build_object('engine', $2::text, 'detail', $3::text))""",
                file_id, verdict.engine, verdict.detail)
    return verdict.status


async def scan_pending(limit: int = 20) -> int:
    """Called by the outbox worker: retries files still in quarantine. Returns how many got a verdict."""
    done = 0
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        ids = [r["id"] for r in await conn.fetch(
            """SELECT id FROM ref.file_object WHERE scan_status IN ('PENDING','SCANNING') AND scan_attempts < $1
                ORDER BY created_at LIMIT $2""", MAX_ATTEMPTS, limit)]
    for fid in ids:
        async with db.transaction(ctx) as conn:
            if await scan_file(conn, ctx, fid) != "PENDING":
                done += 1
    return done
