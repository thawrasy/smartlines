import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { api, type Me, type MfaStep, type Portal } from "./api";
import { useI18n, LOCALES, type Locale } from "./i18n";

interface Auth {
  me: Me | null;
  ready: boolean;
  /** The signed-in user, or the step the session still owes: its own password in place of a temporary one, then the
   *  second factor (Me also has an "mfa" field). */
  login: (identifier: string, password: string, portal: Portal) => Promise<SignedIn>;
  /** The two sign-in doors (N16): individuals by e-mail or mobile, businesses by company number and username. */
  signIn: (door: Door) => Promise<SignedIn>;
  /** Booking without an account (N18): the code sent to the e-mail opens a guest passenger session. */
  guest: (email: string, code: string) => Promise<SignedIn>;
  logout: () => Promise<void>;
  refresh: () => Promise<void>;
  can: (...perms: string[]) => boolean;
}

export type Door =
  | { kind: "individual"; identifier: string; password: string }
  | { kind: "business"; company_no: string; username: string; password: string; portal?: "DRIVER" | "INSPECTOR" };
export type SignedIn = Me | { mfaStep: MfaStep } | { passwordStep: true; mfaStep: MfaStep | null };
interface LoginOut { mfa: MfaStep | null; password_change_required?: boolean }

const Ctx = createContext<Auth | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [ready, setReady] = useState(false);
  const { setLocale, setMarket } = useI18n();

  const refresh = useCallback(async () => {
    try {
      const m = await api.get<Me>("/api/auth/me");
      if (m.market) setMarket(m.market);                     // times and money of the user's market (1061)
      setMe(m);
    } catch {
      setMe(null);
    } finally {
      setReady(true);
    }
  }, [setMarket]);

  useEffect(() => { void refresh(); }, [refresh]);

  const finish = useCallback(async (res: LoginOut): Promise<SignedIn> => {
    if (res.password_change_required) return { passwordStep: true, mfaStep: res.mfa };
    if (res.mfa) return { mfaStep: res.mfa };
    const m = await api.get<Me>("/api/auth/me");
    if (m.market) setMarket(m.market);
    setMe(m);
    if (m.locale in LOCALES) setLocale(m.locale as Locale);
    return m;
  }, [setLocale, setMarket]);

  const login = useCallback(async (identifier: string, password: string, portal: Portal) =>
    finish(await api.post<LoginOut>("/api/auth/login", { identifier, password, portal })), [finish]);

  const signIn = useCallback(async (door: Door) => {
    const { kind, ...body } = door;
    return finish(await api.post<LoginOut>(`/api/auth/login/${kind}`, body));
  }, [finish]);

  const guest = useCallback(async (email: string, code: string) =>
    finish(await api.post<LoginOut>("/api/auth/guest/verify", { email, code })), [finish]);

  const logout = useCallback(async () => {
    try { await api.post("/api/auth/logout"); } finally { setMe(null); }
  }, []);

  const can = useCallback((...perms: string[]) => !!me && perms.some((p) => me.permissions.includes(p)), [me]);

  return <Ctx.Provider value={{ me, ready, login, signIn, guest, logout, refresh, can }}>{children}</Ctx.Provider>;
}

export function useAuth() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useAuth outside AuthProvider");
  return v;
}

// Where each portal lands after signing in
export function homeFor(me: Me): string {
  switch (me.portal) {
    case "OPERATOR":   // counter staff (cash sales only) start at the counter
      return me.permissions.includes("sale.cash") && !me.permissions.includes("trip.publish") ? "/carrier/counter" : "/carrier";
    case "DRIVER": return "/driver";
    case "AGENCY": return "/agency";
    case "STATION": return "/station";
    case "PLATFORM":
      if (me.permissions.includes("company.approve")) return "/admin";
      if (me.permissions.includes("security.ip_rules") || me.permissions.includes("audit.view")) return "/security";
      return "/regulator";
    default: return "/";
  }
}
