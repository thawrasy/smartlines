// The Content-Security-Policy in a real browser (reviews of release 1.49.0: 'unsafe-inline' is gone from style-src).
//
// Opens the main pages of every portal, and the server-rendered landing pages, with the site's own policy in force
// (ui-checks.mjs bypasses it to inject axe), in English and Arabic, and fails when:
//   * the browser reports a violation (a securitypolicyviolation event or a "Refused to ..." console message): an
//     inline style or script, a style attribute in served HTML, a resource from a host the policy does not name;
//   * a page answers without a policy, or with one that still allows inline code ('unsafe-inline', 'unsafe-eval').
//
//   npm run build && node e2e/csp-check.mjs
//   MASSLAK_UI_BASE   the API serving frontend/dist (default http://localhost:8077)
//   CHROME            a Chromium or Chrome executable (default: Playwright's own, or /usr/bin/google-chrome)
import { existsSync } from "node:fs";
import { chromium } from "playwright-core";

const BASE = (process.env.MASSLAK_UI_BASE ?? "http://localhost:8077").replace(/\/$/, "");
const PASSWORD = process.env.MASSLAK_DEMO_PASSWORD ?? "Masslak-Demo-2026";
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
// the landing pages are rendered by the server (backend/app/modules/seo), outside the web app
const LANDING = ["/ar", "/en", "/ar/faq", "/en/faq", "/ar/international", "/en/services/shipping", "/en/no-such-page"];

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

// runs before any script of the page (the policy does not apply to it): keeps every violation the browser reports
const RECORD = () => {
  window.__csp = [];
  document.addEventListener("securitypolicyviolation", (e) => {
    window.__csp.push(`${e.effectiveDirective} blocked ${e.blockedURI || "inline"} at ${e.sourceFile || "?"}:${e.lineNumber} ${e.sample || ""}`.trim());
  });
};

const failures = [];
let checked = 0;

async function visit(page, where, path, spa) {
  const refused = [];
  const onConsole = (m) => { if (/Content Security Policy|Refused to /.test(m.text())) refused.push(m.text().slice(0, 240)); };
  page.on("console", onConsole);
  try {
    const resp = await page.goto(BASE + path, { waitUntil: "networkidle" });
    if (!resp) { failures.push(`${where}: no answer`); return; }
    if (resp.status() >= 500) { failures.push(`${where}: answered ${resp.status()}`); return; }
    const policy = (await resp.allHeaders())["content-security-policy"] ?? "";
    if (!policy) failures.push(`${where}: no Content-Security-Policy`);
    else if (/'unsafe-inline'|'unsafe-eval'/.test(policy)) failures.push(`${where}: the policy still allows inline code: ${policy}`);
    if (spa) await page.waitForSelector("#root *", { timeout: 10000 });
    await page.waitForTimeout(300);
    checked += 1;
    const seen = await page.evaluate(() => window.__csp ?? []);
    for (const v of new Set([...seen, ...refused])) failures.push(`${where}: ${v}`);
  } finally {
    page.off("console", onConsole);
  }
}

const browser = await chromium.launch({ executablePath: executable() });
try {
  for (const locale of LOCALES) {
    for (const portal of PORTALS) {
      const context = await browser.newContext({ locale: locale === "ar" ? "ar-SY" : "en-GB" });
      await context.addInitScript(RECORD);
      await context.addInitScript((l) => { try { localStorage.setItem("masslak.locale", l); } catch { /* none */ } }, locale);
      const headers = { "X-Masslak-Client": "web", "Content-Type": "application/json" };
      if (portal.who) {
        const r = await context.request.post(`${BASE}/api/auth/login`,
          { headers, data: { identifier: portal.who[0], password: PASSWORD, portal: portal.who[1] } });
        if (!r.ok()) throw new Error(`sign-in of ${portal.who[0]} failed: ${r.status()} ${await r.text()}`);
        await context.request.patch(`${BASE}/api/auth/me/locale`, { headers, data: { locale } });
      }
      const page = await context.newPage();
      for (let path of portal.pages) {
        if (path === "@trip") path = await firstTrip(context.request);
        if (path) await visit(page, `${locale} ${portal.who?.[1] ?? "VISITOR"} ${path}`, path, true);
      }
      await context.close();
    }
  }
  const context = await browser.newContext();
  await context.addInitScript(RECORD);
  const page = await context.newPage();
  for (const path of LANDING) await visit(page, `landing ${path}`, path, false);
  await context.close();
} finally {
  await browser.close();
}

console.log(`checked ${checked} page views with the site's Content-Security-Policy in force`);
if (failures.length) {
  console.error(`\n${failures.length} failure(s):\n` + failures.join("\n"));
  process.exit(1);
}
console.log("no Content-Security-Policy violation, and no page allows inline code");
