"""Device attestation (audit T3-11): whether the driver app runs unmodified on a genuine device.

Providers:
* PLAY_INTEGRITY (Android) and APP_ATTEST (iOS): the token is checked by the provider's service, through the egress proxy.
  They need the platform's developer accounts. Their verifier URL and credentials come from MASSLAK_ATTESTATION_URL and
  MASSLAK_ATTESTATION_TOKEN, served by a small service that holds the Google and Apple keys. Until those are set,
  attestation is refused (503), never assumed.
* SIMULATED: sandbox only, for tests. A token starting with "pass-" passes; anything else fails.

Whether attestation is required is a regulator decision: requirement tracking.device_attestation (OFF until imposed).
"""
from __future__ import annotations

import json
import os
import urllib.request

from . import egress
from .config import get_settings
from .errors import ApiError


async def verify(provider: str, token: str) -> bool:
    if provider == "SIMULATED":
        if not get_settings().sandbox:
            raise ApiError(422, "ATTESTATION_PROVIDER", "simulated attestation exists only in the sandbox")
        return token.startswith("pass-")
    url = os.environ.get("MASSLAK_ATTESTATION_URL", "")
    if not url.startswith("https://"):
        raise ApiError(503, "ATTESTATION_NOT_CONFIGURED", "device attestation is not configured on this platform yet")
    req = urllib.request.Request(url, method="POST", data=json.dumps({"provider": provider, "token": token}).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {os.environ.get('MASSLAK_ATTESTATION_TOKEN', '')}"})
    import asyncio
    try:
        # https is checked above, so file:// and custom schemes can never be opened
        body = await asyncio.to_thread(lambda: json.loads(egress.urlopen(req, timeout=10).read() or b"{}"))  # nosec B310
    except Exception as exc:
        raise ApiError(502, "ATTESTATION_UNAVAILABLE", "the attestation service did not answer") from exc
    return body.get("verdict") == "PASS"
