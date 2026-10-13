// Driver boarding: online scans go straight to the server; with no connection the app decides from the downloaded
// pack and the signed credential, keeps the scan in the keystore and uploads it later. The server's answer wins.
import { CryptoDigestAlgorithm, digestStringAsync, getRandomBytes } from "expo-crypto";
import { api, ApiError } from "./api";
import { cacheKey } from "./auth";
import { getJSON, putJSON } from "./secure";
import { clockOffset, decide, decideTyped, reconcile, refKey, serverNow, type LocalScan, type OfflinePack, type ScanResult } from "../core/offlineBoarding";
import { verifyCredential } from "../core/ticketCredential";

export interface Outcome { result: ScanResult | string; seat?: string; name?: string; ticket?: string; offline: boolean }

const scanId = () => Array.from(getRandomBytes(12), (b) => b.toString(16).padStart(2, "0")).join("");

export async function downloadPack(tripUid: string): Promise<OfflinePack> {
  const fetched = await api.get<OfflinePack>(`/api/driver/trips/${tripUid}/offline`);
  const pack = { ...fetched, clock_offset_ms: clockOffset(fetched.generated_at, Date.now()) };
  await putJSON(cacheKey.pack(tripUid), pack);
  return pack;
}

export const loadPack = (tripUid: string) => getJSON<OfflinePack>(cacheKey.pack(tripUid));
export const loadScans = async (tripUid: string) => (await getJSON<LocalScan[]>(cacheKey.scans(tripUid))) ?? [];

export async function scan(tripUid: string, token: string): Promise<Outcome> {
  const history = await loadScans(tripUid);
  try {
    const r = await api.post<{ result: string; seat_no?: number; seat_label?: string; passenger?: string; ticket_uid?: string }>("/api/driver/scan", { trip_uid: tripUid, token });
    const claims = token.startsWith("T2.") ? verifyCredential(token, (await loadPack(tripUid))?.public_key ?? "") : null;
    // Remember online boardings too, so a second scan of the same ticket is caught if the connection drops.
    history.push({ scan_id: scanId(), token, ticket_uid: claims?.ok ? claims.claims.k : null, result: r.result as ScanResult,
                   scanned_at: new Date().toISOString(), synced: true });
    await putJSON(cacheKey.scans(tripUid), history.slice(-500));
    return { result: r.result, seat: r.seat_label ?? (r.seat_no !== undefined ? String(r.seat_no) : undefined), name: r.passenger,
             ticket: r.ticket_uid, offline: false };
  } catch (e) {
    if (!(e instanceof ApiError) || e.status !== 0) throw e;
  }
  const pack = await loadPack(tripUid);
  if (!pack) return { result: "NOT_IN_PACK", offline: true };
  // judged and dated by the server's time, so a wrong device clock neither refuses a valid ticket nor misdates the scan
  const now = serverNow(pack);
  const verified = verifyCredential(token, pack.public_key, now / 1000);
  const d = decide(pack, verified.ok ? { ok: true, claims: verified.claims } : { ok: false }, history);
  // A valid signature for a ticket sold after the pack was made: cannot decide offline.
  const result = verified.ok && !d.ticket && d.result === "INVALID_QR" ? "NOT_IN_PACK" : d.result;
  history.push({ scan_id: scanId(), token, ticket_uid: verified.ok ? verified.claims.k : null, result: d.result,
                 scanned_at: new Date(now).toISOString(), synced: false });
  await putJSON(cacheKey.scans(tripUid), history);
  return { result, seat: d.seat, name: d.name, offline: true };
}

/**
 * Boards a ticket typed in by its number and booking reference, once the driver has checked the identity document
 * (owner's decision O1): online against the manifest, or offline from the pack, matched by its number and a hash of
 * number and reference. A typed boarding is uploaded later as typed, never as a code.
 */
export async function boardTyped(tripUid: string, ticketNo: string, bookingRef: string): Promise<Outcome> {
  const no = ticketNo.trim().toUpperCase(), ref = bookingRef.trim().toUpperCase();
  const history = await loadScans(tripUid);
  try {
    const r = await api.post<{ result: string; seat_no?: number; seat_label?: string; passenger?: string; ticket_uid?: string }>(
      "/api/driver/scan", { trip_uid: tripUid, ticket_no: no, booking_ref: ref, identity_checked: true });
    history.push({ scan_id: scanId(), token: "", ticket_uid: r.ticket_uid ?? null, result: r.result as ScanResult,
                   scanned_at: new Date().toISOString(), synced: true });
    await putJSON(cacheKey.scans(tripUid), history.slice(-500));
    return { result: r.result, seat: r.seat_label ?? (r.seat_no !== undefined ? String(r.seat_no) : undefined), name: r.passenger,
             ticket: r.ticket_uid, offline: false };
  } catch (e) {
    if (!(e instanceof ApiError) || e.status !== 0) throw e;
  }
  const pack = await loadPack(tripUid);
  if (!pack) return { result: "NOT_IN_PACK", offline: true };
  const now = serverNow(pack);
  const d = decideTyped(pack, no, await digestStringAsync(CryptoDigestAlgorithm.SHA256, refKey(no, ref)), history);
  if (d.result !== "NOT_FOUND") {                // nothing to upload for a ticket the pack does not know
    history.push({ scan_id: scanId(), token: "", ticket_no: no, booking_ref: ref, ticket_uid: d.ticket?.uid ?? null, result: d.result,
                   scanned_at: new Date(now).toISOString(), synced: false });
    await putJSON(cacheKey.scans(tripUid), history);
  }
  return { result: d.result, seat: d.seat, name: d.name, offline: true };
}

/** Uploads unsynced scans (200 per request) and applies the server's answers. Returns how many remain. */
export async function sync(tripUid: string): Promise<number> {
  let history = await loadScans(tripUid);
  const pending = history.filter((s) => !s.synced);
  for (let i = 0; i < pending.length; i += 200) {
    const batch = pending.slice(i, i + 200);
    const r = await api.post<{ results: { scan_id: string; result: string }[] }>("/api/driver/scans/batch", {
      trip_uid: tripUid, scans: batch.map((s) => (s.ticket_no && s.booking_ref
        ? { scan_id: s.scan_id, ticket_no: s.ticket_no, booking_ref: s.booking_ref, identity_checked: true, scanned_at: s.scanned_at }
        : { scan_id: s.scan_id, token: s.token, scanned_at: s.scanned_at })),
    });
    history = reconcile(history, r.results);
    await putJSON(cacheKey.scans(tripUid), history);
  }
  return history.filter((s) => !s.synced).length;
}
