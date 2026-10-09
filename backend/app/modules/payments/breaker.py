"""Circuit breaker for calls to payment providers (review of release 1.47.0, technical guidance 1.3).

A provider that stops answering must not hold every payer for its full timeout, nor take the API's threads with it.
After MASSLAK_PSP_BREAKER_FAILURES calls in a row that got no answer (timeouts, network errors, server errors), the
provider is considered down for MASSLAK_PSP_BREAKER_OPEN_SECONDS: calls are refused at once with 503 and a
Retry-After. Then one call is let through; its success closes the circuit, its failure opens it again. A refusal by
the provider (a 4xx answer) is an answer, not a failure.

The state is per process; each process learns on its own within a few calls. Every call and the state are counted:
masslak_payment_provider_calls_total{provider,outcome} and masslak_payment_provider_circuit_open{provider}.
"""
from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass

from ... import metrics
from ...errors import ApiError


def _setting(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


@dataclass
class _State:
    failures: int = 0
    open_until: float = 0.0
    trial: bool = False


_states: dict[str, _State] = {}
_lock = threading.Lock()


def before(provider: str) -> None:
    """Raises 503 while the circuit of this provider is open; lets one trial call through when the pause is over."""
    now = time.monotonic()
    with _lock:
        st = _states.setdefault(provider, _State())
        if st.open_until == 0.0:
            return
        if now < st.open_until or st.trial:
            wait = max(1, int(st.open_until - now)) if now < st.open_until else 1
            metrics.event("masslak_payment_provider_calls_total", provider=provider, outcome="short_circuited")
            raise ApiError(503, "PAYMENT_PROVIDER_UNAVAILABLE", "the payment provider is not answering; try again shortly",
                           retry_after=wait)
        st.trial = True                       # half open: this call decides


def after(provider: str, answered: bool) -> None:
    """Records the outcome of a call: answered (even with a refusal) or not."""
    threshold = int(_setting("MASSLAK_PSP_BREAKER_FAILURES", 5))
    pause = _setting("MASSLAK_PSP_BREAKER_OPEN_SECONDS", 30)
    with _lock:
        st = _states.setdefault(provider, _State())
        st.trial = False
        if answered:
            st.failures, st.open_until = 0, 0.0
        else:
            st.failures += 1
            if st.failures >= threshold or st.open_until:
                st.open_until = time.monotonic() + pause
        is_open = st.open_until > 0.0
    metrics.event("masslak_payment_provider_calls_total", provider=provider, outcome="answered" if answered else "no_answer")
    metrics.gauge("masslak_payment_provider_circuit_open", 1.0 if is_open else 0.0, provider=provider)


def is_open(provider: str) -> bool:
    with _lock:
        st = _states.get(provider)
        return bool(st and st.open_until and time.monotonic() < st.open_until)


def reset() -> None:
    """Tests only."""
    with _lock:
        _states.clear()
