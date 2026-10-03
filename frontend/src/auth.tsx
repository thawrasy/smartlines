import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { api, type Me, type Portal } from "./api";
import { useI18n, LOCALES, type Locale } from "./i18n";

interface Auth {
  me: Me | null;
  ready: boolean;
  login: (identifier: string, password: string, portal: Portal) => Promise<Me>;
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
    await api.post("/api/auth/login", { identifier, password, portal });
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
    case "OPERATOR": return "/carrier";
    case "DRIVER": return "/driver";
    case "PLATFORM":
      if (me.permissions.includes("company.approve")) return "/admin";
      if (me.permissions.includes("security.ip_rules") || me.permissions.includes("audit.view")) return "/security";
      return "/regulator";
    default: return "/";
  }
}
