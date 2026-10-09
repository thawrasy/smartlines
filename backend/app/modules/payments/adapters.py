"""Payment provider adapters.

Each adapter speaks to one kind of provider. The rest of the platform only sees four operations: start a payment
(which returns what the payer must do next), verify a provider notification, confirm a one-time code, and refund.

The wire contract below is the platform's own generic contract; a provider whose API differs gets its own adapter
class with the same four methods. Notifications are signed with HMAC-SHA256 over "<timestamp>.<raw body>" and sent
as  X-Masslak-Signature: t=<unix seconds>,v1=<hex>  — older than five minutes or signed with another key is refused.

With no base_url configured and MASSLAK_SANDBOX=true, the adapter runs against the built-in simulator: the payer
sees a test payment page (card) or receives the test code 123456 (e-wallet), and the simulator posts a correctly
signed notification exactly as a provider would.
"""
import hashlib
import hmac
import json
import os
import secrets
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Optional

from ... import egress
from ...config import get_settings
from ...errors import ApiError

SIGNATURE_HEADER = "x-masslak-signature"
TOLERANCE_S = 300
SANDBOX_OTP = "123456"


@dataclass
class Action:
    """What the payer must do next."""
    kind: str                         # REDIRECT, OTP, TRANSFER, DONE
    url: Optional[str] = None
    provider_ref: Optional[str] = None
    details: dict = field(default_factory=dict)


@dataclass
class Notice:
    event_id: str
    provider_ref: str
    status: str                       # SUCCESS or FAILED
    amount: int
    currency: Optional[str]           # None: the payment's own currency
    failure_code: Optional[str] = None
    card_last4: Optional[str] = None


def secret_for(provider: dict) -> bytes:
    """The provider's signing secret from the environment; in the sandbox a key derived from the platform secret."""
    cfg = provider["config"]
    name = cfg.get("secret_env") or f"MASSLAK_PSP_{provider['code']}_SECRET"
    value = os.environ.get(name)
    if value:
        return value.encode()
    if get_settings().sandbox:
        return hmac.new(get_settings().signing_secret.encode(), f"psp:{provider['code']}".encode(), hashlib.sha256).digest()
    raise ApiError(503, "PAYMENT_PROVIDER_NOT_CONFIGURED", f"{name} is not set")


def sign(secret: bytes, body: bytes, ts: Optional[int] = None) -> str:
    ts = ts or int(time.time())
    mac = hmac.new(secret, f"{ts}.".encode() + body, hashlib.sha256).hexdigest()
    return f"t={ts},v1={mac}"


def verify(secret: bytes, body: bytes, header: Optional[str]) -> bool:
    if not header:
        return False
    try:
        parts = dict(p.split("=", 1) for p in header.split(","))
        ts = int(parts["t"])
    except (ValueError, KeyError):
        return False
    if abs(time.time() - ts) > TOLERANCE_S:
        return False
    expected = hmac.new(secret, f"{ts}.".encode() + body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, parts.get("v1", ""))


def simulated(provider: dict) -> bool:
    return not provider["config"].get("base_url") and get_settings().sandbox


class ProviderUnknown(ApiError):
    """No answer: a timeout, a network error or a server error. The provider may have acted, so the same request is
    sent again later with the same reference, never a new one (review of 1.47.0, R-16, R-17)."""

    def __init__(self, message: str = "the payment provider did not answer"):
        super().__init__(502, "PAYMENT_PROVIDER_UNAVAILABLE", message)


class ProviderRefused(ApiError):
    """A definite answer that the provider did not do it (a 4xx answer, or a refusal in the body)."""

    def __init__(self, code: str = "PAYMENT_PROVIDER_REFUSED", message: str = "the payment provider refused the request"):
        super().__init__(502, code, message)


def reference(prefix: str, uid) -> str:
    """The merchant reference of a payment or refund: fixed by its row, so a repeated call is the same request."""
    return prefix + str(uid).replace("-", "")[:20].upper()


def _call(provider: dict, path: str, payload: dict) -> dict:
    """A signed JSON request to the provider (HTTPS only), through the circuit breaker. Never called inside a database
    transaction or on the event loop: the payments service runs it in a thread between two transactions."""
    from . import breaker
    base = provider["config"].get("base_url", "")
    if not base.startswith("https://"):
        raise ApiError(503, "PAYMENT_PROVIDER_NOT_CONFIGURED", "the provider base_url must use https")
    body = json.dumps(payload).encode()
    key_env = provider["config"].get("api_key_env") or f"MASSLAK_PSP_{provider['code']}_KEY"
    req = urllib.request.Request(base.rstrip("/") + path, data=body, method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {os.environ.get(key_env, '')}",
        "Idempotency-Key": str(payload.get("reference") or payload.get("refund_reference") or ""),
        "X-Masslak-Signature": sign(secret_for(provider), body)})
    breaker.before(provider["code"])
    try:
        # https is checked above, so file:// and custom schemes can never be opened
        with egress.urlopen(req, timeout=float(provider["config"].get("timeout_s", 20))) as r:  # nosec B310
            raw = r.read()
    except urllib.error.HTTPError as exc:
        answered = 400 <= exc.code < 500
        breaker.after(provider["code"], answered)
        if answered:
            raise ProviderRefused(message=f"the payment provider refused the request ({exc.code})") from exc
        raise ProviderUnknown() from exc
    except Exception as exc:
        breaker.after(provider["code"], False)
        raise ProviderUnknown() from exc
    breaker.after(provider["code"], True)
    try:
        return json.loads(raw or b"{}")
    except ValueError as exc:
        raise ProviderUnknown("the payment provider answered something unreadable") from exc


def parse_notice(body: bytes) -> Notice:
    try:
        d = json.loads(body)
        return Notice(event_id=str(d["event_id"])[:80], provider_ref=str(d["reference"])[:80], status=str(d["status"]).upper(),
                      amount=int(d["amount"]), currency=(str(d["currency"])[:3] if d.get("currency") else None),
                      failure_code=(str(d["failure_code"])[:40] if d.get("failure_code") else None),
                      card_last4=(str(d["card_last4"])[-4:] if d.get("card_last4") else None))
    except (ValueError, KeyError, TypeError) as exc:
        raise ApiError(400, "BAD_NOTIFICATION", "malformed notification") from exc


def _simulated_failure(provider: dict, key: str) -> None:
    """Sandbox only: the simulator can play a provider that never answers or that refuses, so the platform's handling
    of both is tested end to end (set in the provider's config by an owner connection, never through the API)."""
    how = provider["config"].get(key)
    if how == "no_answer":
        raise ProviderUnknown()
    if how == "refuse":
        raise ProviderRefused("REFUND_REFUSED" if key == "simulate_refund" else "PAYMENT_PROVIDER_REFUSED", "the simulator refused")


class HostedCard:
    """Card gateway with a hosted payment page: card numbers never touch the platform."""
    prefix, product = "CRD", "CARD"

    def start(self, provider: dict, payment: dict, return_url: str) -> Action:
        ref = payment["reference"]                     # fixed by the payment row: a retry opens the same session
        if simulated(provider):
            _simulated_failure(provider, "simulate_start")
            return Action("REDIRECT", url=f"/pay/test/{payment['uid']}", provider_ref=ref)
        out = _call(provider, "/v1/checkout-sessions", {
            "merchant_id": provider["config"].get("merchant_id"), "reference": ref, "amount": payment["amount"],
            "currency": payment["currency"], "return_url": return_url, "product": self.product,
            "description": payment.get("description", "Masslak wallet top-up")})
        url = out.get("checkout_url", "")
        if not url.startswith("https://"):
            raise ProviderUnknown("the provider returned no secure payment page")
        return Action("REDIRECT", url=url, provider_ref=ref)

    def confirm(self, provider: dict, payment: dict, code: str) -> Optional[Notice]:
        raise ApiError(409, "PAYMENT_NO_CODE", "card payments are confirmed on the payment page")

    def refund(self, provider: dict, payment: dict, amount: int, ref: str) -> str:
        """ref is fixed by the refund row: the provider treats a repeated call as the same refund."""
        if simulated(provider):
            _simulated_failure(provider, "simulate_refund")
            return "RFD" + secrets.token_hex(6).upper()
        out = _call(provider, "/v1/refunds", {"payment_reference": payment["provider_ref"], "amount": amount,
                                              "refund_reference": ref})
        status = str(out.get("status", "")).upper()
        if status in ("SUCCESS", "ACCEPTED"):
            return str(out.get("refund_id", ref))
        if status in ("REFUSED", "DECLINED", "FAILED"):
            raise ProviderRefused("REFUND_REFUSED", "the provider refused the refund")
        raise ProviderUnknown("the provider did not say whether it refunded")


class Instalments(HostedCard):
    """Buy now, pay later (Tabby, Tamara or a local equivalent): the payer is approved on the provider's page, the
    provider pays the platform the whole amount and collects the instalments from the payer itself (1056)."""
    prefix, product = "INS", "INSTALLMENT"


class Financing(HostedCard):
    """A financing company for high-value trips (Umrah, Hajj, tours): it approves the traveller on its own page, pays
    the platform the whole amount and recovers it from the traveller under its own contract (1056)."""
    prefix, product = "FIN", "FINANCING"


class PartnerWallet:
    """Another e-wallet or bank app: a payment request to the payer's mobile, approved with a one-time code."""

    def start(self, provider: dict, payment: dict, return_url: str, mobile: str = "") -> Action:
        ref = payment["reference"]                     # fixed by the payment row: a retry is the same request
        if simulated(provider):
            return Action("OTP", provider_ref=ref, details={"test_code": SANDBOX_OTP})
        _call(provider, "/v1/payment-requests", {
            "merchant_code": provider["config"].get("merchant_code"), "reference": ref, "amount": payment["amount"],
            "currency": payment["currency"], "payer_mobile": mobile, "description": "Masslak wallet top-up"})
        return Action("OTP", provider_ref=ref)

    def confirm(self, provider: dict, payment: dict, code: str) -> Optional[Notice]:
        if simulated(provider):
            ok = hmac.compare_digest(code, SANDBOX_OTP)
            return Notice(event_id=f"sim-{payment['provider_ref']}-{secrets.token_hex(4)}", provider_ref=payment["provider_ref"],
                          status="SUCCESS" if ok else "FAILED", amount=payment["amount"], currency=payment["currency"],
                          failure_code=None if ok else "OTP_INVALID")
        out = _call(provider, f"/v1/payment-requests/{payment['provider_ref']}/confirm", {"otp": code})
        status = str(out.get("status", "")).upper()
        if status == "PENDING" or (status == "SUCCESS" and out.get("amount") is None):
            return None                           # the provider will send a (signed) notification
        # what the provider says it took, never what was asked: the service compares both with the payment (R-19)
        return Notice(event_id=str(out.get("event_id") or f"confirm-{payment['provider_ref']}"), provider_ref=payment["provider_ref"],
                      status="SUCCESS" if status == "SUCCESS" else "FAILED", amount=int(out.get("amount") or 0),
                      currency=str(out["currency"]) if out.get("currency") else None, failure_code=out.get("failure_code"))

    def refund(self, provider: dict, payment: dict, amount: int, ref: str) -> str:
        return HostedCard().refund(provider, payment, amount, ref)


class Sandbox:
    """The original test gateway: the top-up succeeds at once (sandbox only)."""

    def start(self, provider: dict, payment: dict, return_url: str) -> Action:
        if not get_settings().sandbox:
            raise ApiError(503, "PAYMENT_PROVIDER_UNAVAILABLE", "the sandbox gateway is disabled")
        return Action("DONE", provider_ref=payment["reference"])

    def confirm(self, provider: dict, payment: dict, code: str) -> Optional[Notice]:
        raise ApiError(409, "PAYMENT_NO_CODE", "nothing to confirm")

    def refund(self, provider: dict, payment: dict, amount: int, ref: str) -> str:
        return "SBX-RFD-" + secrets.token_hex(6)


ADAPTERS = {"HOSTED_CARD": HostedCard(), "PARTNER_WALLET": PartnerWallet(), "SANDBOX": Sandbox(),
            "INSTALLMENT": Instalments(), "FINANCING": Financing()}
HOSTED = ("HOSTED_CARD", "INSTALLMENT", "FINANCING")         # adapters with a hosted page and signed notifications
NOTIFYING = HOSTED + ("PARTNER_WALLET",)


def simulator_notice(provider: dict, payment: dict, approve: bool) -> tuple[bytes, str]:
    """The notification the test gateway sends after the payer approves or declines (sandbox only)."""
    if not get_settings().sandbox:
        raise ApiError(404, "NOT_FOUND", "unknown endpoint")
    body = json.dumps({"event_id": f"sim-{payment['provider_ref']}", "reference": payment["provider_ref"],
                       "status": "SUCCESS" if approve else "FAILED", "amount": payment["amount"] + payment.get("fee", 0),
                       "currency": payment["currency"],
                       "card_last4": "4242" if approve else None, "failure_code": None if approve else "DECLINED"}).encode()
    return body, sign(secret_for(provider), body)
