// Cross-language check: a credential signed by the Python server verifies with the app's JavaScript code.
// Runs against a live API: MASSLAK_TEST_URL=http://localhost:8077 node --test --experimental-strip-types test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyCredential } from "../src/core/ticketCredential.ts";

const BASE = process.env.MASSLAK_TEST_URL;
const H = { "X-Masslak-Client": "web", "Content-Type": "application/json", "X-Forwarded-For": "198.18.250.9" };

test("server-signed credentials verify in the app", { skip: !BASE && "set MASSLAK_TEST_URL" }, async (t) => {
  const login = await fetch(`${BASE}/api/auth/login`, { method: "POST", headers: H,
    body: JSON.stringify({ identifier: "passenger@masslak.test", password: "Masslak-Demo-2026", portal: "PASSENGER" }) });
  assert.equal(login.status, 200);
  const cookie = (login.headers.get("set-cookie") ?? "").split(";")[0];
  const get = (p: string) => fetch(`${BASE}${p}`, { headers: { ...H, Cookie: cookie } }).then((r) => r.json());
  const { bookings } = await get("/api/bookings");
  let token: string | undefined;
  for (const b of bookings.filter((x: { status: string }) => x.status === "CONFIRMED")) {
    const { tickets } = await get(`/api/bookings/${b.booking_ref}`);
    const k = tickets.find((x: { status: string }) => x.status === "ISSUED");
    if (k) { token = (await get(`/api/tickets/${k.uid}/offline`)).credential; break; }
  }
  if (!token) { t.skip("no upcoming ticket in this database"); return; }
  const { public_key } = await get("/api/public/keys/ticket");
  const r = verifyCredential(token, public_key);
  assert.equal(r.ok, true);
  assert.equal(verifyCredential(token.slice(0, -4) + "AAAA", public_key).ok, false);
});
