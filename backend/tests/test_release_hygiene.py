"""Release hygiene after the code review of October 2026: the API reports the release the database is at (not a number
kept by hand), and production does not publish the internal API's document."""
import asyncio
import os
import subprocess
import sys
from pathlib import Path

import asyncpg
import pytest

import test_e2e as e2e
from test_e2e import OWNER_URL


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_api_reports_the_release_of_its_database():
    async def version():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            return await conn.fetchval("SELECT version FROM sys.current_release()")
        finally:
            await conn.close()
    spec = e2e.client().get("/api/openapi.json")          # the sandbox publishes it
    assert spec.status_code == 200
    assert spec.json()["info"]["version"] == asyncio.run(version()) != "0.1.0"


def _docs(**env) -> str:
    out = subprocess.run([sys.executable, "-c", "import app.main as m; print(m.app.docs_url, m.app.openapi_url)"],
                         cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True, check=True,
                         env={"PATH": os.environ.get("PATH", ""), "MASSLAK_SIGNING_SECRET": "x", **env})
    return out.stdout.strip()


def test_production_does_not_publish_the_internal_api_document():
    assert _docs(MASSLAK_SANDBOX="false") == "None None"
    assert _docs(MASSLAK_SANDBOX="false", MASSLAK_API_DOCS="true") == "/api/docs /api/openapi.json"
    assert _docs(MASSLAK_SANDBOX="true") == "/api/docs /api/openapi.json"
