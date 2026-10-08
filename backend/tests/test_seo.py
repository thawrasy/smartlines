"""Search engine pages: every landing page is complete without JavaScript, carries its canonical address, its Arabic and
English alternates and valid structured data, and private screens are kept out of the index."""
import json
import re
import xml.etree.ElementTree as ET

import httpx
import pytest

from test_e2e import BASE


def get(path: str) -> httpx.Response:
    return httpx.get(BASE + path, timeout=30, follow_redirects=False)


def head_of(html: str) -> dict:
    title = re.search(r"<title>(.*?)</title>", html, re.S).group(1)
    desc = re.search(r'<meta name="description" content="([^"]*)"', html).group(1)
    canonical = re.search(r'<link rel="canonical" href="([^"]*)"', html)
    alts = dict(re.findall(r'<link rel="alternate" hreflang="([^"]+)" href="([^"]+)"', html))
    blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', html, re.S)
    graph = [n for b in blocks for n in json.loads(b).get("@graph", [])]
    return {"title": title, "desc": desc, "canonical": canonical.group(1) if canonical else None, "alts": alts,
            "types": {n["@type"] for n in graph}, "graph": graph, "h1": len(re.findall(r"<h1[ >]", html))}


@pytest.mark.parametrize("path", ["/ar", "/en", "/ar/bus/damascus-to-aleppo", "/en/bus/beirut-to-damascus", "/ar/city/damascus",
                                  "/en/international", "/ar/services/shipping", "/en/services/car-rental", "/ar/faq", "/en/about",
                                  "/ar/contact", "/en/terms", "/ar/privacy", "/en/business"])
def test_landing_pages_are_complete(path):
    r = get(path)
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/html")
    assert "max-age" in r.headers.get("cache-control", "")
    h = head_of(r.text)
    lang = path.split("/")[1]
    assert f'<html lang="{lang}" dir="{"rtl" if lang == "ar" else "ltr"}">' in r.text
    assert 10 <= len(h["title"]) <= 75, h["title"]
    assert 50 <= len(h["desc"]) <= 200, h["desc"]
    assert h["canonical"].endswith(path)
    rest = path[3:]
    assert h["alts"]["ar"].endswith("/ar" + rest) and h["alts"]["en"].endswith("/en" + rest) and h["alts"]["x-default"].endswith("/ar" + rest)
    assert {"Organization", "WebSite"} <= h["types"]
    assert h["h1"] == 1
    assert 'property="og:image"' in r.text and "summary_large_image" in r.text


def test_route_page_has_live_trips_and_faq():
    h = head_of(get("/ar/bus/damascus-to-aleppo").text)
    assert {"BreadcrumbList", "FAQPage"} <= h["types"]
    faq = next(n for n in h["graph"] if n["@type"] == "FAQPage")
    assert len(faq["mainEntity"]) >= 4 and all(q["acceptedAnswer"]["text"] for q in faq["mainEntity"])
    trips = next((n for n in h["graph"] if n["@type"] == "ItemList"), None)
    if trips:   # demo data publishes trips on this corridor
        trip = trips["itemListElement"][0]["item"]
        assert trip["@type"] == "BusTrip" and trip["offers"]["priceCurrency"] == "SYP" and trip["departureBusStop"]["name"]


def test_alternates_are_reciprocal():
    ar, en = head_of(get("/ar/bus/damascus-to-homs").text), head_of(get("/en/bus/damascus-to-homs").text)
    assert ar["alts"] == en["alts"]


def test_sitemap_lists_every_page_in_both_languages():
    r = get("/sitemap.xml")
    assert r.status_code == 200 and "xml" in r.headers["content-type"]
    ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9", "x": "http://www.w3.org/1999/xhtml"}
    root = ET.fromstring(r.content)
    locs = [u.find("s:loc", ns).text for u in root.findall("s:url", ns)]
    assert len(locs) > 50 and len(locs) == len(set(locs))
    assert sum("/ar/" in x or x.endswith("/ar") for x in locs) == sum("/en/" in x or x.endswith("/en") for x in locs)
    assert all(len(u.findall("x:link", ns)) == 3 for u in root.findall("s:url", ns))
    for loc in locs[:: max(1, len(locs) // 12)]:
        assert get(re.sub(r"^https?://[^/]+", "", loc)).status_code == 200, loc


def test_robots_and_private_screens():
    robots = get("/robots.txt").text
    assert "Sitemap: " in robots and "Disallow: /api/" in robots and "Disallow: /admin" in robots
    assert "noindex" in get("/api/health").headers.get("x-robots-tag", "")
    login = get("/login")
    if login.status_code == 200:          # the app screens exist only when the web interface is built
        assert "noindex" in login.headers.get("x-robots-tag", "")


def test_unknown_addresses_are_real_404s():
    for path in ("/ar/no-such-page", "/en/bus/atlantis-to-mars", "/no-such-page"):
        r = get(path)
        assert r.status_code == 404, path
    assert "noindex" in get("/ar/no-such-page").text


def test_app_home_has_search_metadata():
    r = get("/")
    if r.status_code != 200 or "<div id=\"root\">" not in r.text:
        pytest.skip("web interface not built")
    h = head_of(r.text)
    assert '<html lang="ar" dir="rtl">' in r.text and h["canonical"].endswith("/")
    assert {"Organization", "WebSite"} <= h["types"] and "<noscript>" in r.text


def test_share_images():
    for path in ("/og-ar.png", "/og-en.png", "/logo.png"):
        r = get(path)
        assert r.status_code == 200 and r.content[:8] == b"\x89PNG\r\n\x1a\n"


def test_head_requests_answer_like_get():
    """Uptime monitors and some crawlers check pages with HEAD."""
    for path in ("/ar", "/en/bus/beirut-to-damascus", "/sitemap.xml", "/api/health"):
        r = httpx.head(BASE + path, timeout=30)
        assert r.status_code == 200, path
        assert r.content == b""
    assert httpx.head(BASE + "/en/nowhere", timeout=30).status_code == 404
