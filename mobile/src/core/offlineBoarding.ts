// Offline boarding decision for the driver app. The pack is downloaded before departure; scans are kept on the
// device and uploaded later, and the server's answer is final. Pure module, unit-tested with Node.

export type ScanResult = "OK" | "DUPLICATE" | "INVALID_QR" | "WRONG_TRIP" | "CANCELLED";

export interface PackTicket { uid: string; status: "ISSUED" | "BOARDED" | "CANCELLED"; seat_no: number; name: string; from_seq: number; to_seq: number }
export interface OfflinePack {
  trip_uid: string; trip_no: string; generated_at: string; public_key: string; tickets: PackTicket[];
  clock_offset_ms?: number;   // server time minus device time when the pack arrived (set by the app)
}
export interface LocalScan { scan_id: string; token: string; ticket_uid: string | null; result: ScanResult; scanned_at: string; synced: boolean }

export interface Decision { result: ScanResult; ticket?: PackTicket; seat?: string; name?: string }

/**
 * Decides one scan without a connection.
 * verified: the signature check result for the scanned code (done with the pinned public key).
 */
export function decide(
  pack: OfflinePack,
  verified: { ok: true; claims: { k: string; t: string; s: string; n: string } } | { ok: false },
  history: LocalScan[],
): Decision {
  if (!verified.ok) return { result: "INVALID_QR" };
  const { claims } = verified;
  if (claims.t !== pack.trip_uid) return { result: "WRONG_TRIP" };
  const ticket = pack.tickets.find((t) => t.uid === claims.k);
  if (!ticket) return { result: "INVALID_QR" };          // sold after the pack was made: board online instead
  if (ticket.status === "CANCELLED") return { result: "CANCELLED", ticket };
  const boardedHere = history.some((s) => s.ticket_uid === claims.k && s.result === "OK");
  if (ticket.status === "BOARDED" || boardedHere) return { result: "DUPLICATE", ticket, seat: claims.s, name: claims.n };
  return { result: "OK", ticket, seat: claims.s, name: claims.n };
}

/** Applies the server's answers to the local history after an upload. */
export function reconcile(history: LocalScan[], answers: { scan_id: string; result: string }[]): LocalScan[] {
  const byId = new Map(answers.map((a) => [a.scan_id, a.result as ScanResult]));
  return history.map((s) => (byId.has(s.scan_id) ? { ...s, result: byId.get(s.scan_id)!, synced: true } : s));
}

// The device clock decides whether a credential has expired and dates each offline scan, so it is corrected with the
// server's time from the pack. Network delay is under a second, far below anything that matters here.
export const CLOCK_TOLERANCE_MS = 5 * 60 * 1000;

/** Server time minus device time, from the time the server made the pack and the device time it arrived. */
export function clockOffset(generatedAt: string, receivedAtMs: number): number {
  const server = Date.parse(generatedAt);
  return Number.isFinite(server) ? server - receivedAtMs : 0;
}

/** The server's time now, by the device clock corrected with the pack's offset. */
export const serverNow = (pack: Pick<OfflinePack, "clock_offset_ms"> | null, deviceNowMs = Date.now()): number =>
  deviceNowMs + (pack?.clock_offset_ms ?? 0);

/** True when the device clock is off by more than the tolerance: the driver is asked to set it. */
export const clockIsOff = (pack: Pick<OfflinePack, "clock_offset_ms"> | null): boolean =>
  Math.abs(pack?.clock_offset_ms ?? 0) > CLOCK_TOLERANCE_MS;
