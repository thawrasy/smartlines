// Signed-in state for the app. The keystore holds the tokens; this context holds only who is signed in.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { api, ApiError, session, signIn as apiSignIn, signOut as apiSignOut } from "./api";
import { getJSON, putJSON, wipe } from "./secure";

export interface Me { uid: string; name: string; email: string | null; portal: string; mfa: { enrolled: boolean; required: boolean } }
type Status = "loading" | "signedOut" | "mfa" | "signedIn";

interface Auth {
  status: Status; me: Me | null;
  signIn: (identifier: string, password: string) => Promise<void>;
  verifyMfa: (code: string) => Promise<void>;
  signOut: () => Promise<void>;
  refresh: () => Promise<void>;
}

/** Keys written while signed in; all erased on sign-out so the next person on this phone sees nothing. */
export const CACHE_KEYS = ["me", "tickets", "wallet", "bookings"];
export const cacheKey = {
  credential: (ticketUid: string) => `cred.${ticketUid}`,
  pack: (tripUid: string) => `pack.${tripUid}`,
  scans: (tripUid: string) => `scans.${tripUid}`,
};

const Ctx = createContext<Auth | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<Status>("loading");
  const [me, setMe] = useState<Me | null>(null);

  const refresh = useCallback(async () => {
    try {
      if (!(await session.accessToken())) { setStatus("signedOut"); setMe(null); return; }
      const fresh = await api.get<Me>("/api/auth/me");
      await putJSON("me", fresh);
      setMe(fresh); setStatus("signedIn");
    } catch (e) {
      if (e instanceof ApiError && e.code === "MFA_REQUIRED") { setStatus("mfa"); return; }
      const cached = e instanceof ApiError && e.status === 0 ? await getJSON<Me>("me") : null;
      if (cached) { setMe(cached); setStatus("signedIn"); return; }   // offline: saved tickets still open
      setStatus("signedOut"); setMe(null);
    }
  }, []);

  useEffect(() => {
    void refresh();
    session.onSignedOut = () => { void wipe(CACHE_KEYS); setStatus("signedOut"); setMe(null); };
  }, [refresh]);

  const value = useMemo<Auth>(() => ({
    status, me, refresh,
    signIn: async (identifier, password) => {
      const r = await apiSignIn(identifier, password);
      if (r.mfa === "VERIFY") { setStatus("mfa"); return; }
      if (r.mfa === "ENROLL") { await apiSignOut(); throw new ApiError(403, "MFA_ENROLL_ON_WEB", "enrol on the website"); }
      await refresh();
    },
    verifyMfa: async (code) => {
      await api.post("/api/auth/mfa/verify", { code: code.replace(/\s/g, "") });
      await refresh();
    },
    signOut: async () => {
      await apiSignOut();
      await wipe(CACHE_KEYS);
      setMe(null); setStatus("signedOut");
    },
  }), [status, me, refresh]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth(): Auth {
  const v = useContext(Ctx);
  if (!v) throw new Error("useAuth outside AuthProvider");
  return v;
}
