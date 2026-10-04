// Saved ticket credentials: fetched once online, kept in the keystore, shown with no connection.
import { api } from "./api";
import { cacheKey } from "./auth";
import { getJSON, putJSON } from "./secure";

export interface SavedCredential { credential: string; valid_until: number; trip_no: string }

export async function saveCredential(ticketUid: string): Promise<SavedCredential> {
  const c = await api.get<SavedCredential>(`/api/tickets/${ticketUid}/offline`);
  await putJSON(cacheKey.credential(ticketUid), c);
  return c;
}

/** The saved credential if still valid; otherwise a fresh one from the server (throws when offline). */
export async function credentialFor(ticketUid: string): Promise<{ cred: SavedCredential; saved: boolean }> {
  const saved = await getJSON<SavedCredential>(cacheKey.credential(ticketUid));
  if (saved && saved.valid_until > Date.now() / 1000) {
    void saveCredential(ticketUid).catch(() => {});          // refresh quietly (status may have changed)
    return { cred: saved, saved: true };
  }
  return { cred: await saveCredential(ticketUid), saved: true };
}

/** After booking, and when the trip list opens: save every valid ticket so it works without a connection. */
export async function saveBooking(ref: string): Promise<void> {
  const b = await api.get<{ tickets: { uid: string; status: string }[] }>(`/api/bookings/${ref}`);
  for (const k of b.tickets) if (k.status === "ISSUED" || k.status === "BOARDED") await saveCredential(k.uid).catch(() => {});
}
