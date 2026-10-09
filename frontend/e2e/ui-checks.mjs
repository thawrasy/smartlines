// Accessibility and right-to-left layout of the web interface (code review of October 2026, 6.2).
//
// Opens the main pages of every portal in English and Arabic, on a phone and a desktop screen, against a running API
// that serves the built interface with demo data, and checks on each:
//   * accessibility with axe-core (WCAG 2.1 A and AA rules): a critical finding fails the run, serious ones are listed;
//   * the page direction and language follow the locale (dir="rtl" lang="ar" in Arabic);
//   * nothing makes the page scroll sideways (a common right-to-left fault), with the elements that stick out.
//
//   npm run build && node e2e/ui-checks.mjs
//   MASSLAK_UI_BASE   the API serving frontend/dist (default http://localhost:8077)
//   CHROME            a Chromium or Chrome executable (default: Playwright's own, or /usr/bin/google-chrome)
import { readFileSync, existsSync } from "node:fs";
import { chromium } from "playwright-core";

const BASE = (process.env.MASSLAK_UI_BASE ?? "http://localhost:8077").replace(/\/$/, "");
const AXE = readFileSync(new URL("../node_modules/axe-core/axe.min.js", import.meta.url), "utf8");
const PASSWORD = process.env.MASSLAK_DEMO_PASSWORD ?? "Masslak-Demo-2026";
const SCREENS = { phone: { width: 390, height: 844 }, desktop: { width: 1280, height: 800 } };
const LOCALES = ["en", "ar"];

const tomorrow = new Date(Date.now() + 27 * 3600e3).toISOString().slice(0, 10);    // Damascus time, roughly
const PORTALS = [
  { who: null, pages: ["/", `/search?origin=DAM&destination=ALP&on=${tomorrow}`, "@trip", "/login", "/register", "/track", "/verify"] },
  { who: ["passenger@masslak.test", "PASSENGER"], pages: ["/trips", "/wallet", "/family", "/account", "/services", "/support"] },
  { who: ["owner@carrier.test", "OPERATOR"],
    pages: ["/carrier", "/carrier/trips", "/carrier/routes", "/carrier/vehicles", "/carrier/finance", "/carrier/documents", "/carrier/reports"] },
  { who: ["counter@carrier.test", "OPERATOR"], pages: ["/carrier/counter", "/carrier/counter/report"] },
  { who: ["agency@agency.test", "AGENCY"], pages: ["/agency", "/agency/bookings", "/agency/statement", "/agency/staff"] },
  { who: ["driver@carrier.test", "DRIVER"], pages: ["/driver"] },
  { who: ["admin@masslak.test", "PLATFORM"],
    pages: ["/admin", "/admin/companies", "/admin/finance", "/admin/documents", "/admin/stations", "/admin/modules", "/admin/payments"] },
];

function executable() {
  if (process.env.CHROME) return process.env.CHROME;
  for (const p of ["/usr/bin/google-chrome", "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"]) if (existsSync(p)) return p;
  return undefined;
}

async function firstTrip(request) {
  const r = await request.get(`${BASE}/api/trips/search?origin=DAM&destination=ALP&on=${tomorrow}`);
  const trip = (await r.json()).trips?.[0];
  return trip ? `/trip/${trip.uid}?from=${trip.from_seq}&to=${trip.to_seq}&pax=1` : null;
}

// Elements that reach past the screen's edges, outside any box that scrolls them on purpose (tables, carousels)
const OVERFLOW = () => {
  const width = document.documentElement.clientWidth;
  const out = [];
  const scrolls = (el) => {
    for (let p = el.parentElement; p; p = p.parentElement) {
      const o = getComputedStyle(p).overflowX;
      if (o === "auto" || o === "scroll" || o === "hidden" || o === "clip") return true;
    }
    return false;
  };
  for (const el of document.body.querySelectorAll("*")) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0 || getComputedStyle(el).visibility === "hidden") continue;
    if ((r.right > width + 1 || r.left < -1) && !scrolls(el)) {
      out.push(`${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""}${el.className && typeof el.className === "string" ? "." + el.className.trim().split(/\s+/).join(".") : ""} [${Math.round(r.left)}..${Math.round(r.right)} of ${width}]`);
    }
  }
  return { scroll: document.documentElement.scrollWidth - width, elements: out.slice(0, 6) };
};

const failures = [];
const serious = new Map();
let checked = 0;

const browser = await chromium.launch({ executablePath: executable() });
try {
  for (const portal of PORTALS) {
    for (const locale of LOCALES) {
      // the site's CSP refuses inline scripts, axe included: only this test browser bypasses it
      const context = await browser.newContext({ locale: locale === "ar" ? "ar-SY" : "en-GB", bypassCSP: true });
      await context.addInitScript((l) => { try { localStorage.setItem("masslak.locale", l); } catch { /* none */ } }, locale);
      const headers = { "X-Masslak-Client": "web", "Content-Type": "application/json" };
      if (portal.who) {
        const r = await context.request.post(`${BASE}/api/auth/login`,
          { headers, data: { identifier: portal.who[0], password: PASSWORD, portal: portal.who[1] } });
        if (!r.ok()) throw new Error(`sign-in of ${portal.who[0]} failed: ${r.status()} ${await r.text()}`);
        await context.request.patch(`${BASE}/api/auth/me/locale`, { headers, data: { locale } });
      }
      const page = await context.newPage();
      for (const [screen, size] of Object.entries(SCREENS)) {
        await page.setViewportSize(size);
        for (let path of portal.pages) {
          if (path === "@trip") path = await firstTrip(context.request);
          if (!path) continue;
          const where = `${locale} ${screen} ${portal.who?.[1] ?? "VISITOR"} ${path}`;
          const resp = await page.goto(BASE + path, { waitUntil: "networkidle" });
          if (!resp || resp.status() >= 400) { failures.push(`${where}: answered ${resp?.status()}`); continue; }
          await page.waitForSelector("#root *", { timeout: 10000 });
          await page.waitForTimeout(300);
          checked += 1;
          const [dir, lang] = await page.evaluate(() => [document.documentElement.dir, document.documentElement.lang]);
          if (dir !== (locale === "ar" ? "rtl" : "ltr") || lang !== locale) failures.push(`${where}: dir="${dir}" lang="${lang}"`);
          const o = await page.evaluate(OVERFLOW);
          if (o.scroll > 1) failures.push(`${where}: the page scrolls sideways by ${o.scroll}px: ${o.elements.join(", ")}`);
          await page.addScriptTag({ content: AXE });
          const found = await page.evaluate(async () => (await window.axe.run(document, {
            runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] }, resultTypes: ["violations"],
          })).violations.map((v) => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.slice(0, 3).map((n) => n.target.join(" ") + (n.any?.[0]?.message ? ` (${n.any[0].message.split(". ")[0]})` : "")) })));
          for (const v of found) {
            if (v.impact === "critical") failures.push(`${where}: ${v.id} (${v.help}) at ${v.nodes.join(" | ")}`);
            else if (v.impact === "serious") {
              const k = `${v.id}: ${v.help}`;
              serious.set(k, [...(serious.get(k) ?? []), `${where} ${v.nodes[0] ?? ""}`]);
            }
          }
        }
      }
      await context.close();
    }
  }
} finally {
  await browser.close();
}

console.log(`checked ${checked} page views (${LOCALES.length} languages, ${Object.keys(SCREENS).length} screen sizes)`);
for (const [k, where] of serious) console.log(`serious: ${k} (${where.length} views, e.g. ${where[0]})`);
if (failures.length) {
  console.error(`\n${failures.length} failure(s):\n` + failures.join("\n"));
  process.exit(1);
}
console.log("no critical accessibility finding, direction and language follow the locale, no page scrolls sideways");
