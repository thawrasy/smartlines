#!/usr/bin/env python3
"""Visual identity checks (identity 1.0, docs/design/system/IDENTITY.md): the tokens are the one source of colour.

It fails when
* a text or control pair the identity promises misses WCAG 2.2 AA in either theme: 4.5:1 for text (each on-* role on
  its fill, content and label text on every surface, the role colours used as text), 3:1 for control borders and focus
  rings (outline and primary on every surface);
* the web theme (frontend/src/theme.css) gives a token a value other than the token's light value;
* the mobile theme (mobile/src/ui/theme.ts) uses a colour that is not a token's light value, or maps a role to the
  wrong token;
* a screen (frontend/src/**/*.tsx) names a CSS variable the web theme does not define: the browser then draws nothing
  (a warning text with no colour), and an old fallback colour of another palette shows instead.

    python3 scripts/check_design_tokens.py [--table]      --table prints every pair with its ratio
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOKENS = ROOT / "docs" / "design" / "system" / "tokens.json"
WEB = ROOT / "frontend" / "src" / "theme.css"
MOBILE = ROOT / "mobile" / "src" / "ui" / "theme.ts"

SURFACES = ["surface", "surface-dim", "surface-container-low", "surface-container", "surface-container-high"]
# the mobile theme's own names and the token each one stands for
MOBILE_ROLES = {"navy": "brand-navy", "primary": "primary", "primarySoft": "primary-container", "green": "success",
                "greenSoft": "success-container", "amber": "secondary", "amberSoft": "secondary-container",
                "error": "error", "errorSoft": "error-container", "surface": "surface", "background": "surface-dim",
                "outline": "outline-variant", "text": "on-surface", "muted": "on-surface-variant"}


def luminance(hex_: str) -> float:
    def ch(c: int) -> float:
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex_.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def ratio(a: str, b: str) -> float:
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def pairs(names: set[str]) -> list[tuple[str, str, float, str]]:
    """(foreground, background, minimum, why) the identity promises."""
    out = []
    for n in sorted(names):
        if n.startswith("on-") and n[3:] in names:
            out.append((n, n[3:], 4.5, "text on its fill"))
    for s in SURFACES:
        out += [("on-surface", s, 4.5, "content text"), ("on-surface-variant", s, 4.5, "labels")]
        out += [(r, s, 4.5, "role colour as text") for r in ("primary", "secondary", "tertiary", "success", "error")]
        out += [("outline", s, 3.0, "control border"), ("primary", s, 3.0, "focus ring")]
    out.append(("inverse-on-surface", "inverse-surface", 4.5, "snackbar text"))
    return out


def main() -> int:
    tokens = json.loads(TOKENS.read_text())
    colour = {t["name"]: t["value"] for t in tokens["color"]["tokens"]}
    bad, rows = [], []
    for theme in ("light", "dark"):
        for fg, bg, need, why in pairs(set(colour)):
            r = ratio(colour[fg][theme], colour[bg][theme])
            rows.append(f"{theme:5} {fg:24} on {bg:24} {r:5.2f}:1 (needs {need}, {why})")
            if r < need:
                bad.append(f"{theme}: {fg} {colour[fg][theme]} on {bg} {colour[bg][theme]} is {r:.2f}:1, needs {need}:1 ({why})")

    light = {n: v["light"].upper() for n, v in colour.items()}
    for name, value in re.findall(r"--([a-z0-9-]+):\s*(#[0-9A-Fa-f]{6})\b", WEB.read_text()):
        if name in light and value.upper() != light[name]:
            bad.append(f"web theme: --{name} is {value}, the token is {light[name]}")
    known = set(light.values())
    for name, value in re.findall(r"\b([A-Za-z]+):\s*\"(#[0-9A-Fa-f]{6})\"", MOBILE.read_text()):
        if name in MOBILE_ROLES and value.upper() != light[MOBILE_ROLES[name]]:
            bad.append(f"mobile theme: {name} is {value}, it stands for {MOBILE_ROLES[name]} = {light[MOBILE_ROLES[name]]}")
        elif value.upper() not in known:
            bad.append(f"mobile theme: {name} = {value} is not a token colour")

    web_text = WEB.read_text()
    defined = set(re.findall(r"--([a-z0-9-]+)\s*:", web_text))
    for f in sorted((ROOT / "frontend" / "src").rglob("*.tsx")):
        for name in sorted(set(re.findall(r"var\(--([a-z0-9-]+)", f.read_text()))):
            if name not in defined:
                bad.append(f"{f.relative_to(ROOT)}: var(--{name}) is not defined in the web theme")

    if "--table" in sys.argv:
        print("\n".join(rows))
    for b in bad:
        print(f"FAIL {b}")
    version = tokens.get("version")
    print(f"design tokens {version}: {len(rows)} contrast pairs, web and mobile themes checked: "
          + ("ok" if not bad else f"{len(bad)} problem(s)"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
