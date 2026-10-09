// Signed-in state for the app. The keystore holds the tokens; this context holds only who is signed in.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { api, ApiError, session, signIn as apiSignIn, signOut as apiSignOut } from "./api";
import { getJSON, putJSON, wipe } from "./secure";
import { useI18n, type Market } from "../i18n";

export interface Me { uid: string; name: string; email: string | null; portal: string; mfa: { enrolled: boolean; required: boolean };
                     market?: Market }
type Status = "loading" | "signedOut" | "mfa" | "signedIn";
export type MfaMethod = "TOTP" | "SMS" | "WHATSAPP";

interface Auth {
  status: Status; me: Me | null;
  /** The second step the session owes: a code (VERIFY) or the first set-up of a method (ENROLL). */
  mfaStep: "VERIFY" | "ENROLL";
  signIn: (identifier: string, password: string) => Promise<void>;
  verifyMfa: (code: string, method?: MfaMethod | null) => Promise<void>;
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
  const [mfaStep, setMfaStep] = useState<"VERIFY" | "ENROLL">("VERIFY");
  const { setMarket } = useI18n();

  const refresh = useCallback(async () => {
    try {
      if (!(await session.accessToken())) { setStatus("signedOut"); setMe(null); return; }
      const fresh = await api.get<Me>("/api/auth/me");
      await putJSON("me", fresh);
      if (fresh.market) setMarket(fresh.market);            // the user's market: its time zone and currency (1061)
      setMe(fresh); setStatus("signedIn");
    } catch (e) {
      if (e instanceof ApiError && e.code === "MFA_REQUIRED") {
        setMfaStep((e.details?.next as string) === "ENROLL" ? "ENROLL" : "VERIFY"); setStatus("mfa"); return;
      }
      const cached = e instanceof ApiError && e.status === 0 ? await getJSON<Me>("me") : null;
      if (cached) { if (cached.market) setMarket(cached.market); setMe(cached); setStatus("signedIn"); return; }   // offline: saved tickets still open
      setStatus("signedOut"); setMe(null);
    }
  }, [setMarket]);

  useEffect(() => {
    void refresh();
    session.onSignedOut = () => { void wipe(CACHE_KEYS); setStatus("signedOut"); setMe(null); };
  }, [refresh]);

  const value = useMemo<Auth>(() => ({
    status, me, refresh, mfaStep,
    signIn: async (identifier, password) => {
      const r = await apiSignIn(identifier, password);
      // a second factor is owed: a code, or the first set-up of a method in the app (owner's decision 2)
      if (r.mfa) { setMfaStep(r.mfa); setStatus("mfa"); return; }
      await refresh();
    },
    verifyMfa: async (code, method) => {
      await api.post("/api/auth/mfa/verify", { code: code.replace(/\s/g, ""), method: method === "TOTP" ? null : method ?? null });
      await refresh();
    },
    signOut: async () => {
      await apiSignOut();
      await wipe(CACHE_KEYS);
      setMe(null); setStatus("signedOut");
    },
  }), [status, me, refresh, mfaStep]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useAuth(): Auth {
  const v = useContext(Ctx);
  if (!v) throw new Error("useAuth outside AuthProvider");
  return v;
}
