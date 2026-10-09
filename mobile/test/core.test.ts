// Unit tests for the security-critical mobile logic: node --test --experimental-strip-types test/
import { test } from "node:test";
import assert from "node:assert/strict";
import * as ed from "@noble/ed25519";
import { verifyCredential } from "../src/core/ticketCredential.ts";
import { clockIsOff, clockOffset, decide, reconcile, serverNow, type OfflinePack, type LocalScan } from "../src/core/offlineBoarding.ts";
import { SessionManager, type Tokens } from "../src/core/session.ts";

const b64url = (b: Uint8Array) => Buffer.from(b).toString("base64url");

function issue(secret: Uint8Array, claims: object): string {
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ v: 2, ...claims })));
  return `T2.${payload}.${b64url(ed.sign(new TextEncoder().encode(payload), secret))}`;
}

const secret = ed.utils.randomSecretKey();
const pub = b64url(ed.getPublicKey(secret));
const later = Math.floor(Date.now() / 1000) + 3600;
const claims = { k: "ticket-1", t: "trip-1", s: "3C", n: "Rami Haddad", a: 0, b: 2, x: later };

test("a genuine credential verifies with the public key alone", () => {
  const r = verifyCredential(issue(secret, claims), pub);
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.claims.s, "3C");
});

test("forged, altered and expired credentials are refused", () => {
  const other = ed.utils.randomSecretKey();
  assert.deepEqual(verifyCredential(issue(other, claims), pub), { ok: false, reason: "SIGNATURE" });
  const [, payload, sig] = issue(secret, claims).split(".");
  const altered = b64url(new TextEncoder().encode(JSON.stringify({ v: 2, ...claims, s: "1A" })));
  assert.deepEqual(verifyCredential(`T2.${altered}.${sig}`, pub), { ok: false, reason: "SIGNATURE" });
  assert.deepEqual(verifyCredential(`T1.${payload}.${sig}`, pub), { ok: false, reason: "FORMAT" });
  assert.deepEqual(verifyCredential(issue(secret, { ...claims, x: 1000 }), pub), { ok: false, reason: "EXPIRED" });
  assert.deepEqual(verifyCredential("garbage", pub), { ok: false, reason: "FORMAT" });
});

const pack: OfflinePack = {
  trip_uid: "trip-1", trip_no: "DCA-1", generated_at: "", public_key: pub,
  tickets: [
    { uid: "ticket-1", status: "ISSUED", seat_no: 9, name: "Rami Haddad", from_seq: 0, to_seq: 2 },
    { uid: "ticket-2", status: "CANCELLED", seat_no: 10, name: "Lina Nasser", from_seq: 0, to_seq: 2 },
  ],
};

test("offline boarding decisions", () => {
  const ok = { ok: true as const, claims };
  assert.equal(decide(pack, ok, []).result, "OK");
  const history: LocalScan[] = [{ scan_id: "s1", token: "t", ticket_uid: "ticket-1", result: "OK", scanned_at: "", synced: false }];
  assert.equal(decide(pack, ok, history).result, "DUPLICATE");
  assert.equal(decide(pack, { ok: true, claims: { ...claims, t: "trip-2" } }, []).result, "WRONG_TRIP");
  assert.equal(decide(pack, { ok: true, claims: { ...claims, k: "ticket-2" } }, []).result, "CANCELLED");
  assert.equal(decide(pack, { ok: true, claims: { ...claims, k: "unknown" } }, []).result, "INVALID_QR");
  assert.equal(decide(pack, { ok: false }, []).result, "INVALID_QR");
  const fixed = reconcile(history, [{ scan_id: "s1", result: "DUPLICATE" }]);
  assert.equal(fixed[0].result, "DUPLICATE");
  assert.equal(fixed[0].synced, true);
});

function memoryStore(initial: Tokens | null) {
  let t = initial;
  return { load: async () => t, save: async (n: Tokens) => { t = n; }, clear: async () => { t = null; }, peek: () => t };
}

test("concurrent requests share one refresh, so a refresh token is never sent twice", async () => {
  const store = memoryStore({ access_token: "a1", refresh_token: "r1", access_expires_at: new Date(Date.now() - 1000).toISOString() });
  const sent: string[] = [];
  const mgr = new SessionManager(store, async (rt) => {
    sent.push(rt);
    await new Promise((r) => setTimeout(r, 20));
    return { status: 200, body: { access_token: "a2", refresh_token: "r2", access_expires_at: new Date(Date.now() + 900_000).toISOString() } };
  });
  const tokens = await Promise.all([mgr.accessToken(), mgr.accessToken(), mgr.accessToken()]);
  assert.deepEqual(tokens, ["a2", "a2", "a2"]);
  assert.deepEqual(sent, ["r1"]);
  assert.equal(await mgr.accessToken(), "a2");                       // still fresh: no new refresh
  assert.deepEqual(sent, ["r1"]);
});

test("a refused refresh signs the person out", async () => {
  const store = memoryStore({ access_token: "a1", refresh_token: "r1", access_expires_at: new Date(0).toISOString() });
  const mgr = new SessionManager(store, async () => ({ status: 401 }));
  assert.equal(await mgr.accessToken(), null);
  assert.equal(store.peek(), null);
});

test("a phone whose clock is wrong judges credentials by the server's time", () => {
  // The phone runs a day ahead: by its own clock the credential has expired, by the server's it is valid
  const deviceNow = Date.now() + 24 * 3600 * 1000;
  const offset = clockOffset(new Date().toISOString(), deviceNow);
  assert.ok(Math.abs(offset + 24 * 3600 * 1000) < 2000);
  const token = issue(secret, claims);
  assert.deepEqual(verifyCredential(token, pub, deviceNow / 1000), { ok: false, reason: "EXPIRED" });
  assert.equal(verifyCredential(token, pub, serverNow({ clock_offset_ms: offset }, deviceNow) / 1000).ok, true);
  assert.equal(clockIsOff({ clock_offset_ms: offset }), true);
});

test("a small clock difference is tolerated and an unreadable server time is ignored", () => {
  assert.equal(clockIsOff({ clock_offset_ms: 90 * 1000 }), false);
  assert.equal(clockIsOff(null), false);
  assert.equal(clockOffset("not a time", Date.now()), 0);
  assert.equal(serverNow(null, 1000), 1000);
});
