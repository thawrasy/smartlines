import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { api, type Me, type MfaStep, type Portal } from "./api";
import { useI18n, LOCALES, type Locale } from "./i18n";

interface Auth {
  me: Me | null;
  ready: boolean;
  /** Resolves with the account, or with the second-factor step a staff sign-in still needs. */
  /** The signed-in user, or the second-factor step the session still owes (Me also has an "mfa" field). */
  login: (identifier: string, password: string, portal: Portal) => Promise<Me | { mfaStep: MfaStep }>;
  logout: () => Promise<void>;
  refresh: () => Promise<void>;
  can: (...perms: string[]) => boolean;
}

const Ctx = createContext<Auth | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [ready, setReady] = useState(false);
  const { setLocale } = useI18n();

  const refresh = useCallback(async () => {
    try {
      setMe(await api.get<Me>("/api/auth/me"));
    } catch {
      setMe(null);
    } finally {
      setReady(true);
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  const login = useCallback(async (identifier: string, password: string, portal: Portal) => {
    const res = await api.post<{ mfa: MfaStep | null }>("/api/auth/login", { identifier, password, portal });
    if (res.mfa) return { mfaStep: res.mfa };
    const m = await api.get<Me>("/api/auth/me");
    setMe(m);
    if (m.locale in LOCALES) setLocale(m.locale as Locale);
    return m;
  }, [setLocale]);

  const logout = useCallback(async () => {
    try { await api.post("/api/auth/logout"); } finally { setMe(null); }
  }, []);

  const can = useCallback((...perms: string[]) => !!me && perms.some((p) => me.permissions.includes(p)), [me]);

  return <Ctx.Provider value={{ me, ready, login, logout, refresh, can }}>{children}</Ctx.Provider>;
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
    case "PLATFORM":
      if (me.permissions.includes("company.approve")) return "/admin";
      if (me.permissions.includes("security.ip_rules") || me.permissions.includes("audit.view")) return "/security";
      return "/regulator";
    default: return "/";
  }
}
