// Saved ticket credentials: fetched once online, kept in the keystore, shown with no connection.
import { ApiError, api } from "./api";
import { cacheKey } from "./auth";
import { getJSON, putJSON } from "./secure";
import { isFresh } from "../core/credentialFreshness";

// verified_at: when the server last issued it, in epoch seconds (set here, not by the server)
export interface SavedCredential { credential: string; valid_until: number; trip_no: string; verified_at?: number }

export async function saveCredential(ticketUid: string): Promise<SavedCredential> {
  const c = await api.get<Omit<SavedCredential, "verified_at">>(`/api/tickets/${ticketUid}/offline`);
  const stored: SavedCredential = { ...c, verified_at: Date.now() / 1000 };
  await putJSON(cacheKey.credential(ticketUid), stored);
  return stored;
}

/**
 * The saved credential when it is still valid and was checked within 72 hours; otherwise a fresh one from the server.
 * Throws when a fresh one is needed and there is no connection (CONNECTION_REQUIRED, when the saved one is too old).
 */
export async function credentialFor(ticketUid: string): Promise<{ cred: SavedCredential; saved: boolean }> {
  const saved = await getJSON<SavedCredential>(cacheKey.credential(ticketUid));
  const now = Date.now() / 1000;
  if (saved && saved.valid_until > now && isFresh(saved.verified_at, now)) {
    void saveCredential(ticketUid).catch(() => {});          // refresh quietly (status may have changed)
    return { cred: saved, saved: true };
  }
  try {
    return { cred: await saveCredential(ticketUid), saved: true };
  } catch (e) {
    if (saved && saved.valid_until > now && !(e instanceof ApiError)) {
      throw new ApiError(0, "CONNECTION_REQUIRED", "connect to the internet to show this ticket");
    }
    throw e;
  }
}

/** After booking, and when the trip list opens: save every valid ticket so it works without a connection. */
export async function saveBooking(ref: string): Promise<void> {
  const b = await api.get<{ tickets: { uid: string; status: string }[] }>(`/api/bookings/${ref}`);
  for (const k of b.tickets) if (k.status === "ISSUED" || k.status === "BOARDED") await saveCredential(k.uid).catch(() => {});
}
