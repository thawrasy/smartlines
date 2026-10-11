"""A production declaration cannot be lowered by another setting (reviews of the 1.50.0 release).

A server declares production with MASSLAK_ENVIRONMENT=production, or with the production profile (MASSLAK_PROFILE). Such a
server is never a test server: with the sandbox on, or with a test environment, it does not start. Without a declaration,
the sandbox and a development or staging environment still mark a test server, as before.
"""
import base64
import os

import pytest

from app import config, profile, security

GOOD_TICKET_KEY = base64.b64encode(os.urandom(32)).decode()


@pytest.fixture()
def settings(monkeypatch):
    for name in ("MASSLAK_SANDBOX", "MASSLAK_ENVIRONMENT", "MASSLAK_PROFILE"):
        monkeypatch.delenv(name, raising=False)
    config.get_settings.cache_clear()

    def apply(**env):
        for name, value in env.items():
            monkeypatch.setenv(name, value)
        config.get_settings.cache_clear()

    yield apply
    config.get_settings.cache_clear()


@pytest.mark.parametrize("env, test_server, conflicts", [
    ({}, False, 0),                                                          # unset counts as production
    ({"MASSLAK_SANDBOX": "true"}, True, 0),                                  # the developer's sandbox
    ({"MASSLAK_ENVIRONMENT": "development"}, True, 0),
    ({"MASSLAK_ENVIRONMENT": "staging"}, True, 0),
    ({"MASSLAK_ENVIRONMENT": "production"}, False, 0),
    ({"MASSLAK_ENVIRONMENT": "production", "MASSLAK_SANDBOX": "true"}, False, 1),
    ({"MASSLAK_ENVIRONMENT": "staging", "MASSLAK_PROFILE": "production"}, False, 1),
    ({"MASSLAK_PROFILE": "production", "MASSLAK_SANDBOX": "true"}, False, 1),
    ({"MASSLAK_PROFILE": "production", "MASSLAK_ENVIRONMENT": "production"}, False, 0),
])
def test_declaration_matrix(settings, env, test_server, conflicts):
    settings(**env)
    assert config.is_test_server() is test_server
    assert len(config.declaration_conflicts()) == conflicts


def test_a_conflicting_declaration_stops_the_start(settings):
    settings(MASSLAK_PROFILE="production", MASSLAK_SANDBOX="true")
    with pytest.raises(RuntimeError, match="declarations contradict"):
        profile.require_in_production()


def test_a_test_server_skips_the_production_profile(settings):
    settings(MASSLAK_SANDBOX="true")
    profile.require_in_production()                                          # no error: a test server


def test_the_key_check_does_not_yield_to_a_production_declaration(settings):
    """With the sandbox on and a production declaration, the signing keys are checked: the placeholder is refused."""
    settings(MASSLAK_ENVIRONMENT="production", MASSLAK_SANDBOX="true",
             MASSLAK_SIGNING_SECRET=security.DEFAULT_SIGNING_SECRET, MASSLAK_TICKET_SIGNING_KEY=GOOD_TICKET_KEY)
    with pytest.raises(security.KeyConfigError):
        security.require_keys_in_production()
