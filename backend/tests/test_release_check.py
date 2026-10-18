"""A production server does not start on a schema changed outside the build and upgrade tools (systems review of study
3.8, recommendation 17): the API and the worker compare the schema hash with the release manifest when they start."""
import pytest

from app import release

MATCHING = {"version": "1.48.0", "schema_hash": "269eafb859e536e2fa30f7f04be2", "hash_matches": True}


@pytest.fixture()
def production(monkeypatch):
    monkeypatch.setattr(release, "is_test_server", lambda: False)


def test_a_matching_schema_starts(production):
    release.check(MATCHING)


def test_a_changed_schema_stops_a_production_start(production):
    with pytest.raises(RuntimeError, match="schema differs from the one release 1.48.0 recorded"):
        release.check({**MATCHING, "hash_matches": False})


def test_a_database_without_a_manifest_stops_a_production_start(production):
    with pytest.raises(RuntimeError, match="no release manifest"):
        release.check(None)


def test_test_servers_start_on_any_schema(monkeypatch):
    monkeypatch.setattr(release, "is_test_server", lambda: True)
    release.check(None)
    release.check({**MATCHING, "hash_matches": False})


def test_the_api_and_the_worker_check_at_start():
    from pathlib import Path
    app = Path(release.__file__).parent
    assert "release.require_match_in_production()" in (app / "main.py").read_text(encoding="utf-8")
    assert "release.require_match_in_production()" in (app / "modules/notify/worker.py").read_text(encoding="utf-8")
