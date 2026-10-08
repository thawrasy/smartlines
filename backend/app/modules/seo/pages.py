"""Landing pages for search engines, in Arabic (/ar/...) and English (/en/...).

    /robots.txt  /sitemap.xml  /og-ar.png  /og-en.png  /logo.png
    /ar  /en                          home: search form, popular routes, international, services, cities, FAQ
    /{lang}/bus/{from}-to-{to}        a route: facts, next departures with prices, how to book, documents, FAQ
    /{lang}/city/{city}               routes from and to a city, its bus stations
    /{lang}/international             cross-border routes and travel documents
    /{lang}/services/{service}        parcels, taxi, car rental, shuttle passes, freight
    /{lang}/faq  /{lang}/about  /{lang}/contact  /{lang}/terms  /{lang}/privacy  /{lang}/business

Pages are rendered on the server from the live catalog (data.py), so a crawler reads the full content without
JavaScript; the booking itself happens in the web app (/search). Unknown addresses under /ar or /en answer 404.
"""
from __future__ import annotations

from datetime import date
from html import escape

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, PlainTextResponse, Response

from ...config import get_settings
from . import data, images
from .render import (base, breadcrumbs, city_name, day_label, distance, duration, faq, local, money, page, search_form,
                     search_url, station_name, words)

router = APIRouter(include_in_schema=False)
LANGS = ("ar", "en")
CACHE = {"Cache-Control": "public, max-age=600"}


def _html(body: str, status: int = 200) -> HTMLResponse:
    headers = dict(CACHE) if status == 200 else {"Cache-Control": "no-store", "X-Robots-Tag": "noindex"}
    return HTMLResponse(body, status_code=status, headers=headers)


def _cities_for_form(cat: data.Catalog, lang: str) -> list[tuple[str, str]]:
    return sorted(((c, city_name(lang, c, x.name)) for c, x in cat.cities.items()), key=lambda p: p[1])


def _route_card(lang: str, r: data.Route) -> str:
    w = words(lang)["common"]
    price = w["from_price"].format(price=money(lang, r.cheapest)) if r.cheapest else duration(lang, r.minutes)
    return (f'<a class="card" href="/{lang}/bus/{r.slug}"><b>{escape(city_name(lang, r.a))} ← {escape(city_name(lang, r.b))}</b>'
            if lang == "ar" else
            f'<a class="card" href="/{lang}/bus/{r.slug}"><b>{escape(city_name(lang, r.a))} → {escape(city_name(lang, r.b))}</b>') + \
        f"<small>{escape(price)} · {escape(distance(lang, r.km))}</small></a>"


def _popular(cat: data.Catalog, limit: int = 16, international: bool | None = False) -> list[data.Route]:
    routes = [r for r in cat.routes.values() if international is None or cat.international(r) == international]
    order = {p: i for i, p in enumerate(data.CORRIDORS)}
    return sorted(routes, key=lambda r: (-len(r.trips), order.get((r.a, r.b), order.get((r.b, r.a), 999) + 0.5)))[:limit]


# ------------------------------------------------------------------ robots, sitemap, images
@router.get("/robots.txt")
async def robots():
    private = ["/api/", "/admin", "/carrier", "/agency", "/driver", "/inspector", "/regulator", "/account", "/wallet", "/family", "/trips",
               "/booking/", "/pay/", "/m/", "/mfa", "/search", "/trip/"]
    lines = ["User-agent: *", "Allow: /", *[f"Disallow: {p}" for p in private], "", f"Sitemap: {base()}/sitemap.xml", ""]
    return PlainTextResponse("\n".join(lines), headers=CACHE)


async def _paths() -> list[str]:
    cat = await data.catalog()
    paths = ["", "/international", "/faq", "/about", "/contact", "/terms", "/privacy", "/business"]
    paths += [f"/services/{k}" for k in words("en")["services"]["items"]]
    paths += [f"/city/{c.slug}" for c in cat.cities.values()]
    paths += [f"/bus/{s}" for s in sorted(cat.routes)]
    return paths


@router.get("/sitemap.xml")
async def sitemap():
    today = date.today().isoformat()
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">']
    for p in await _paths():
        alts = "".join(f'<xhtml:link rel="alternate" hreflang="{lg}" href="{base()}/{lg}{p}"/>' for lg in LANGS) + \
            f'<xhtml:link rel="alternate" hreflang="x-default" href="{base()}/ar{p}"/>'
        for lg in LANGS:
            out.append(f"<url><loc>{base()}/{lg}{p}</loc><lastmod>{today}</lastmod>{alts}</url>")
    out.append("</urlset>")
    return Response("\n".join(out), media_type="application/xml", headers=CACHE)


@router.get("/og-{lang}.png")
async def og_image(lang: str):
    if lang not in LANGS:
        return Response(status_code=404)
    return Response(images.og(lang), media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})


@router.get("/logo.png")
async def logo_image():
    return Response(images.logo(), media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})


# ------------------------------------------------------------------ home
async def home(lang: str):
    cat = await data.catalog()
    w = words(lang)
    h = w["home"]
    hero = (f'<section class="hero"><div class="wrap"><h1>{escape(h["h1"])}</h1><p class="lead">{escape(h["lead"])}</p>'
            f"{search_form(lang, _cities_for_form(cat, lang))}</div></section>")
    body = [f'<section><p style="margin-top:24px">{escape(h["intro"])}</p></section>']
    body.append(f'<section id="routes"><h2>{escape(h["popular_title"])}</h2><div class="grid">'
                + "".join(_route_card(lang, r) for r in _popular(cat)) + "</div></section>")
    body.append(f'<section><h2>{escape(h["intl_title"])}</h2><p>{escape(h["intl_text"])}</p><div class="grid">'
                + "".join(_route_card(lang, r) for r in _popular(cat, 8, True)) + "</div></section>")
    svc = w["services"]["items"]
    body.append(f'<section><h2>{escape(h["services_title"])}</h2><div class="grid">' + "".join(
        f'<a class="card" href="/{lang}/services/{k}"><b>{escape(v["h1"])}</b><small>{escape(v["description"])}</small></a>' for k, v in svc.items())
        + "</div></section>")
    body.append(f'<section><h2>{escape(h["cities_title"])}</h2><div class="grid">' + "".join(
        f'<a class="card" href="/{lang}/city/{c.slug}"><b>{escape(city_name(lang, c.code, c.name))}</b></a>'
        for c in sorted(cat.cities.values(), key=lambda c: city_name(lang, c.code))) + "</div></section>")
    body.append(f'<section><h2>{escape(h["why_title"])}</h2><div class="grid">' + "".join(
        f'<div class="card"><b>{escape(x["title"])}</b><small>{escape(x["text"])}</small></div>' for x in h["why"]) + "</div></section>")
    body.append(f'<section><h2>{escape(h["how_title"])}</h2><ol class="steps">' + "".join(f"<li>{escape(s)}</li>" for s in h["how"]) + "</ol></section>")
    faq_html, faq_ld = faq(w["faq"]["items"][:6])
    body.append(f'<section><h2>{escape(w["faq"]["h1"])}</h2>{faq_html}</section>')
    items = {"@type": "ItemList", "name": h["popular_title"], "itemListElement": [
        {"@type": "ListItem", "position": i + 1, "url": f"{base()}/{lang}/bus/{r.slug}",
         "name": f"{city_name(lang, r.a)} – {city_name(lang, r.b)}"} for i, r in enumerate(_popular(cat))]}
    return _html(page(lang=lang, path="", title=h["title"], description=h["description"], body="".join(body), hero=hero, jsonld=[items, faq_ld]))


# ------------------------------------------------------------------ route
async def route(lang: str, slug: str):
    cat = await data.catalog()
    r = cat.routes.get(slug)
    if r is None:
        return await not_found(lang)
    w = words(lang)
    t = w["route"]
    A, B = city_name(lang, r.a), city_name(lang, r.b)
    intl = cat.international(r)
    price = money(lang, r.cheapest) if r.cheapest else None
    dur = duration(lang, r.minutes)
    dist = distance(lang, r.km)
    title = t["title"].format(**{"from": A, "to": B})
    desc = t["description"].format(**{"from": A, "to": B, "price_part": t["price_part"].format(price=price) if price else "",
                                      "duration_part": t["duration_part"].format(duration=dur) if r.minutes else ""}).strip()
    crumbs, crumbs_ld = breadcrumbs(lang, [(A, f"/{lang}/city/{data.SLUG[r.a]}"), (f"{A} – {B}", f"/{lang}/bus/{r.slug}")])
    first = min((local(x.departs, x.zone) for x in r.trips), default=None, key=lambda d: (d.hour, d.minute))
    last = max((local(x.departs, x.zone) for x in r.trips), default=None, key=lambda d: (d.hour, d.minute))
    facts = [(t["fact"]["distance"], dist), (t["fact"]["duration"], dur), (t["fact"]["trips"], str(len(r.trips))),
             (t["fact"]["price"], price or "—"), (t["fact"]["first"], first.strftime("%H:%M") if first else "—"),
             (t["fact"]["last"], last.strftime("%H:%M") if last else "—"), (t["fact"]["carriers"], str(r.carriers or "—"))]
    border = w["border"].get(r.b if cat.cities[r.a].country == "SY" else r.a) if intl else None
    if border:
        facts.append((t["fact"]["border"], border))
    body = [crumbs, f"<h1>{escape(t['h1'].format(**{'from': A, 'to': B}))}</h1>",
            f"<p><strong>{escape(t['lead'].format(**{'from': A, 'to': B}))}</strong></p>",
            f"<p>{escape(t['intro'].format(**{'from': A, 'to': B, 'distance': dist, 'duration': dur}))}</p>",
            search_form(lang, _cities_for_form(cat, lang), r.a, r.b),
            f"<h2>{escape(t['facts_title'].format(**{'from': A, 'to': B}))}</h2><div class='facts'>"
            + "".join(f"<div class='fact'><span>{escape(k)}</span><b>{escape(v)}</b></div>" for k, v in facts) + "</div>"]
    trips_ld = []
    body.append(f"<h2>{escape(t['schedule_title'].format(**{'from': A, 'to': B}))}</h2>")
    if r.trips:
        c = t["col"]
        rows = []
        for x in r.trips[:15]:
            d = local(x.departs, x.zone)
            rows.append(f"<tr><td>{escape(day_label(lang, x.departs, x.zone))}</td><td>{d.strftime('%H:%M')}</td><td>{escape(x.carrier)}</td>"
                        f"<td>{escape(money(lang, x.price))}</td><td><a href=\"{escape(search_url(r.a, r.b, lang, d.date().isoformat()))}\">"
                        f"{escape(w['nav']['book'])}</a></td></tr>")
            trips_ld.append({"@type": "BusTrip", "name": f"{A} – {B}", "provider": {"@type": "Organization", "name": x.carrier},
                             "departureTime": x.departs.isoformat(), **({"arrivalTime": x.arrives.isoformat()} if x.arrives else {}),
                             "departureBusStop": {"@type": "BusStation", "name": station_name(lang, x.origin_code, x.origin_station)},
                             "arrivalBusStop": {"@type": "BusStation", "name": station_name(lang, x.dest_code, x.dest_station)},
                             "offers": {"@type": "Offer", "price": round(x.price / 100), "priceCurrency": x.currency,
                                        "url": f"{base()}{search_url(r.a, r.b, lang, d.date().isoformat())}",
                                        "availability": "https://schema.org/InStock"}})
        body.append(f"<table><thead><tr><th>{escape(c['date'])}</th><th>{escape(c['time'])}</th><th>{escape(c['carrier'])}</th>"
                    f"<th>{escape(c['price'])}</th><th></th></tr></thead><tbody>{''.join(rows)}</tbody></table>"
                    f"<p class='note'>{escape(w['common']['updated'])}</p>")
    else:
        body.append(f"<p class='note'>{escape(t['no_trips'])}</p>")
    body.append(f"<p><a class='btn' href=\"{escape(search_url(r.a, r.b, lang))}\">{escape(t['cta'].format(**{'from': A, 'to': B}))}</a></p>")
    body.append(f"<h2>{escape(t['how_title'].format(**{'from': A, 'to': B}))}</h2><ol class='steps'>"
                + "".join(f"<li>{escape(s)}</li>" for s in w["home"]["how"]) + "</ol>")
    body.append(f"<h2>{escape(t['needs_title'])}</h2><p>{escape(t['needs_international'] if intl else t['needs_domestic'])}</p>")
    first_time = min((local(x.departs, x.zone) for x in r.trips), default=None)
    answers = {"from": A, "to": B, "duration": dur, "distance": dist,
               "price_answer": t["price_answer"].format(price=price) if price else t["price_unknown"],
               "today_answer": t["today_yes"].format(n=len(r.trips), time=first_time.strftime("%H:%M")) if first_time else t["today_no"]}
    qa = [{"q": i["q"].format(**answers), "a": i["a"].format(**answers)} for i in t["faq"]]
    faq_html, faq_ld = faq(qa)
    body.append(f"<h2>{escape(t['faq_title'].format(**{'from': A, 'to': B}))}</h2>{faq_html}")
    links = []
    back = cat.routes.get(f"{data.SLUG[r.b]}-to-{data.SLUG[r.a]}")
    if back:
        links.append(f"<a class='card' href='/{lang}/bus/{back.slug}'><b>{escape(t['return_link'].format(**{'from': A, 'to': B}))}</b></a>")
    others = [x for x in _popular(cat, 100, None) if x.a == r.a and x.slug != r.slug][:6]
    body.append("<div class='grid'>" + "".join(links) + "</div>")
    if others:
        body.append(f"<h2>{escape(t['more_title'].format(**{'from': A}))}</h2><div class='grid'>" + "".join(_route_card(lang, x) for x in others) + "</div>")
    ld = [crumbs_ld, faq_ld]
    if trips_ld:
        ld.append({"@type": "ItemList", "name": t["schedule_title"].format(**{"from": A, "to": B}),
                   "itemListElement": [{"@type": "ListItem", "position": i + 1, "item": x} for i, x in enumerate(trips_ld)]})
    return _html(page(lang=lang, path=f"/bus/{r.slug}", title=title, description=desc, body="".join(body), jsonld=ld))


# ------------------------------------------------------------------ city
async def city(lang: str, slug: str):
    cat = await data.catalog()
    code = data.CODE.get(slug)
    c = cat.cities.get(code) if code else None
    if c is None:
        return await not_found(lang)
    w = words(lang)
    t = w["city"]
    N = city_name(lang, c.code, c.name)
    crumbs, crumbs_ld = breadcrumbs(lang, [(N, f"/{lang}/city/{c.slug}")])
    out = [r for r in _popular(cat, 100, None) if r.a == c.code]
    inn = [r for r in _popular(cat, 100, None) if r.b == c.code]
    body = [crumbs, f"<h1>{escape(t['h1'].format(city=N))}</h1>", f"<p>{escape(t['intro'].format(city=N))}</p>",
            search_form(lang, _cities_for_form(cat, lang), c.code, out[0].b if out else "ALP")]
    if out:
        body.append(f"<h2>{escape(t['from_title'].format(city=N))}</h2><div class='grid'>" + "".join(_route_card(lang, r) for r in out) + "</div>")
    if inn:
        body.append(f"<h2>{escape(t['to_title'].format(city=N))}</h2><div class='grid'>" + "".join(_route_card(lang, r) for r in inn) + "</div>")
    stations_ld = []
    if c.stations:
        body.append(f"<h2>{escape(t['stations_title'].format(city=N))}</h2><ul>"
                    + "".join(f"<li>{escape(station_name(lang, s['code'], s['name']))}</li>" for s in c.stations) + "</ul>")
        stations_ld = [{"@type": "BusStation", "name": station_name(lang, s["code"], s["name"]),
                        "address": {"@type": "PostalAddress", "addressLocality": N, "addressCountry": c.country}} for s in c.stations]
    ld = [crumbs_ld, {"@type": "ItemList", "itemListElement": [
        {"@type": "ListItem", "position": i + 1, "url": f"{base()}/{lang}/bus/{r.slug}"} for i, r in enumerate(out + inn)]}, *stations_ld]
    return _html(page(lang=lang, path=f"/city/{c.slug}", title=t["title"].format(city=N), description=t["description"].format(city=N),
                      body="".join(body), jsonld=ld))


# ------------------------------------------------------------------ international, services, faq, about
async def international(lang: str):
    cat = await data.catalog()
    w = words(lang)
    t = w["intl"]
    crumbs, crumbs_ld = breadcrumbs(lang, [(w["nav"]["international"], f"/{lang}/international")])
    routes = _popular(cat, 40, True)
    body = [crumbs, f"<h1>{escape(t['h1'])}</h1>", f"<p>{escape(t['intro'])}</p>", "<div class='grid'>"
            + "".join(_route_card(lang, r) for r in routes) + "</div>",
            f"<h2>{escape(t['docs_title'])}</h2><p>{escape(w['route']['needs_international'])}</p>"]
    ld = [crumbs_ld, {"@type": "ItemList", "itemListElement": [
        {"@type": "ListItem", "position": i + 1, "url": f"{base()}/{lang}/bus/{r.slug}"} for i, r in enumerate(routes)]}]
    return _html(page(lang=lang, path="/international", title=t["title"], description=t["description"], body="".join(body), jsonld=ld))


async def service(lang: str, key: str):
    w = words(lang)
    s = w["services"]["items"].get(key)
    if s is None:
        return await not_found(lang)
    crumbs, crumbs_ld = breadcrumbs(lang, [(w["nav"]["services"], f"/{lang}/services/shipping"), (s["h1"], f"/{lang}/services/{key}")])
    target = {"shipping": "/services", "taxi": "/services", "car-rental": "/services", "shuttle-passes": "/services", "freight": "/services"}[key]
    others = "".join(f'<a class="card" href="/{lang}/services/{k}"><b>{escape(v["h1"])}</b></a>' for k, v in w["services"]["items"].items() if k != key)
    body = [crumbs, f"<h1>{escape(s['h1'])}</h1>", f"<p>{escape(s['body'])}</p><ul>" + "".join(f"<li>{escape(p)}</li>" for p in s["points"]) + "</ul>",
            f"<p><a class='btn' href='{target}?lang={lang}'>{escape(s['cta'])}</a></p>", f"<h2>{escape(w['services']['title_index'])}</h2><div class='grid'>{others}</div>"]
    ld = [crumbs_ld, {"@type": "Service", "name": s["h1"], "description": s["description"], "serviceType": s["h1"],
                      "provider": {"@id": f"{base()}/#organization"}, "areaServed": {"@type": "Country", "name": "Syria"}}]
    return _html(page(lang=lang, path=f"/services/{key}", title=s["title"], description=s["description"], body="".join(body), jsonld=ld))


async def faq_page(lang: str):
    w = words(lang)
    t = w["faq"]
    crumbs, crumbs_ld = breadcrumbs(lang, [(t["h1"], f"/{lang}/faq")])
    faq_html, faq_ld = faq(t["items"])
    return _html(page(lang=lang, path="/faq", title=t["title"], description=t["description"],
                      body=f"{crumbs}<h1>{escape(t['h1'])}</h1>{faq_html}", jsonld=[crumbs_ld, faq_ld]))


async def about(lang: str):
    w = words(lang)
    t = w["about"]
    crumbs, crumbs_ld = breadcrumbs(lang, [(t["h1"], f"/{lang}/about")])
    body = f"{crumbs}<h1>{escape(t['h1'])}</h1>" + "".join(f"<p>{escape(p)}</p>" for p in t["body"])
    return _html(page(lang=lang, path="/about", title=t["title"], description=t["description"], body=body,
                      jsonld=[crumbs_ld, {"@type": "AboutPage", "name": t["h1"], "about": {"@id": f"{base()}/#organization"}}]))


def _sections(sections: list) -> str:
    """Numbered sections of a policy page: a heading and its paragraphs, or bullet points when an item is a list."""
    out = []
    for sec in sections:
        out.append(f"<h2>{escape(sec['h'])}</h2>")
        for p in sec["p"]:
            if isinstance(p, list):
                out.append("<ul>" + "".join(f"<li>{escape(x)}</li>" for x in p) + "</ul>")
            else:
                out.append(f"<p>{escape(p)}</p>")
    return "".join(out)


async def contact(lang: str):
    w = words(lang)
    t = w["contact"]
    s = get_settings()
    crumbs, crumbs_ld = breadcrumbs(lang, [(t["h1"], f"/{lang}/contact")])
    lines = [(t["email"], s.support_email, f"mailto:{s.support_email}"), (t["phone"], s.support_phone, f"tel:{s.support_phone}"),
             (t["whatsapp"], s.support_whatsapp, f"https://wa.me/{''.join(ch for ch in s.support_whatsapp if ch.isdigit())}"),
             (t["business"], s.business_email, f"mailto:{s.business_email}"), (t["address"], s.office_address, ""),
             (t["hours"], s.support_hours, "")]
    rows = "".join(f"<li><b>{escape(k)}:</b> " + (f'<a href="{escape(href)}" dir="ltr">{escape(v)}</a>' if href else escape(v)) + "</li>"
                   for k, v, href in lines if v)
    body = (f"{crumbs}<h1>{escape(t['h1'])}</h1><p>{escape(t['intro'])}</p>"
            f"<h2>{escape(t['passengers_h'])}</h2><p>{escape(t['passengers'])}</p>"
            f"<p><a class='btn' href='/support?lang={lang}'>{escape(t['cta'])}</a></p>"
            f"<h2>{escape(t['details_h'])}</h2>" + (f"<ul>{rows}</ul>" if rows else f"<p>{escape(t['soon'])}</p>") +
            f"<h2>{escape(t['companies_h'])}</h2><p>{escape(t['companies'])}</p>"
            f"<p><a href='/{lang}/business'>{escape(w['nav']['business'])}</a></p>")
    org = {"@type": "Organization", "@id": f"{base()}/#organization", "name": w["brand"]}
    if s.support_email or s.support_phone:
        org["contactPoint"] = {"@type": "ContactPoint", "contactType": "customer support", "availableLanguage": ["ar", "en"],
                               **({"email": s.support_email} if s.support_email else {}), **({"telephone": s.support_phone} if s.support_phone else {})}
    return _html(page(lang=lang, path="/contact", title=t["title"], description=t["description"], body=body,
                      jsonld=[crumbs_ld, {"@type": "ContactPage", "name": t["h1"]}, org]))


async def policy(lang: str, key: str):
    """Terms of use and the privacy notice: the published text, with its version date."""
    w = words(lang)
    t = w[key]
    crumbs, crumbs_ld = breadcrumbs(lang, [(t["h1"], f"/{lang}/{key}")])
    body = (f"{crumbs}<h1>{escape(t['h1'])}</h1><p class='muted'>{escape(t['updated'])}</p><p>{escape(t['intro'])}</p>"
            + _sections(t["sections"]))
    return _html(page(lang=lang, path=f"/{key}", title=t["title"], description=t["description"], body=body,
                      jsonld=[crumbs_ld, {"@type": "WebPage", "name": t["h1"]}]))


async def business(lang: str):
    w = words(lang)
    t = w["business"]
    crumbs, crumbs_ld = breadcrumbs(lang, [(t["h1"], f"/{lang}/business")])
    cards = "".join(f'<div class="card"><b>{escape(c["h"])}</b><p>{escape(c["p"])}</p></div>' for c in t["who"])
    steps = "".join(f"<li>{escape(x)}</li>" for x in t["steps"])
    body = (f"{crumbs}<h1>{escape(t['h1'])}</h1><p>{escape(t['intro'])}</p><div class='grid'>{cards}</div>"
            f"<h2>{escape(t['steps_h'])}</h2><ol>{steps}</ol>"
            f"<h2>{escape(t['docs_h'])}</h2><ul>" + "".join(f"<li>{escape(x)}</li>" for x in t["docs"]) + "</ul>"
            f"<h2>{escape(t['why_h'])}</h2><ul>" + "".join(f"<li>{escape(x)}</li>" for x in t["why"]) + "</ul>"
            f"<p><a class='btn' href='/{lang}/contact'>{escape(t['cta'])}</a></p>")
    return _html(page(lang=lang, path="/business", title=t["title"], description=t["description"], body=body,
                      jsonld=[crumbs_ld, {"@type": "WebPage", "name": t["h1"]}]))


async def not_found(lang: str):
    cat = await data.catalog()
    w = words(lang)
    t = w["notfound"]
    body = (f"<h1 style='margin-top:32px'>{escape(t['h1'])}</h1><p>{escape(t['text'])}</p>{search_form(lang, _cities_for_form(cat, lang))}"
            f"<div class='grid'>" + "".join(_route_card(lang, r) for r in _popular(cat, 8)) + "</div>")
    return _html(page(lang=lang, path="", title=t["title"], description=t["text"], body=body, status_noindex=True), 404)


# ------------------------------------------------------------------ routing table (one handler per language and kind)
def _register(lang: str) -> None:
    async def _home():
        return await home(lang)

    async def _route(slug: str):
        return await route(lang, slug)

    async def _city(slug: str):
        return await city(lang, slug)

    async def _intl():
        return await international(lang)

    async def _service(key: str):
        return await service(lang, key)

    async def _faq():
        return await faq_page(lang)

    async def _about():
        return await about(lang)

    async def _contact():
        return await contact(lang)

    async def _terms():
        return await policy(lang, "terms")

    async def _privacy():
        return await policy(lang, "privacy")

    async def _business():
        return await business(lang)

    async def _missing(rest: str):
        return await not_found(lang)

    router.add_api_route(f"/{lang}", _home, methods=["GET"])
    router.add_api_route(f"/{lang}/bus/{{slug}}", _route, methods=["GET"])
    router.add_api_route(f"/{lang}/city/{{slug}}", _city, methods=["GET"])
    router.add_api_route(f"/{lang}/international", _intl, methods=["GET"])
    router.add_api_route(f"/{lang}/services/{{key}}", _service, methods=["GET"])
    router.add_api_route(f"/{lang}/faq", _faq, methods=["GET"])
    router.add_api_route(f"/{lang}/about", _about, methods=["GET"])
    router.add_api_route(f"/{lang}/contact", _contact, methods=["GET"])
    router.add_api_route(f"/{lang}/terms", _terms, methods=["GET"])
    router.add_api_route(f"/{lang}/privacy", _privacy, methods=["GET"])
    router.add_api_route(f"/{lang}/business", _business, methods=["GET"])
    router.add_api_route(f"/{lang}/{{rest:path}}", _missing, methods=["GET"])


for _lang in LANGS:
    _register(_lang)
