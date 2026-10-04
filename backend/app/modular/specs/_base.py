"""Shorthands shared by the resource definitions."""
from ..engine import Action, Resource

P, O, PA, AG, D = "PLATFORM", "OPERATOR", "PASSENGER", "AGENCY", "DRIVER"  # noqa: E741 (portal codes)


def c(names: str) -> tuple:
    """Column list from a space-separated string."""
    return tuple(names.split())


def activate(when=("DRAFT", "PENDING"), to="ACTIVE", **kw) -> Action:
    return Action("activate", {"status": to}, {"status": list(when)}, **kw)


def retire(when=("ACTIVE",), to="RETIRED", name="retire", **kw) -> Action:
    return Action(name, {"status": to}, {"status": list(when)}, **kw)


def suspend(when=("ACTIVE",), **kw) -> Action:
    return Action("suspend", {"status": "SUSPENDED"}, {"status": list(when)}, **kw)


def resume(when=("SUSPENDED",), **kw) -> Action:
    return Action("resume", {"status": "ACTIVE"}, {"status": list(when)}, **kw)


__all__ = ["Action", "Resource", "P", "O", "PA", "AG", "D", "c", "activate", "retire", "suspend", "resume"]
