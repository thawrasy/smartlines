import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { api } from "../api";
import { useAuth } from "../auth";

export interface ModuleRes { key: string; group: string }
export interface ModuleInfo { key: string; phase: string; icon: string; resources: ModuleRes[] }
interface Modules { enabled: Set<string>; modules: ModuleInfo[]; ready: boolean; reload: () => void; on: (key: string) => boolean }

const Ctx = createContext<Modules>({ enabled: new Set(), modules: [], ready: false, reload: () => {}, on: () => false });

/** The modules switched on by the platform, and the resources the signed-in user may open in each. */
export function ModulesProvider({ children }: { children: ReactNode }) {
  const { me, ready: authReady } = useAuth();
  const [state, setState] = useState<{ enabled: Set<string>; modules: ModuleInfo[]; ready: boolean }>({ enabled: new Set(), modules: [], ready: false });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!authReady) return;
    let live = true;
    api.get<{ enabled: string[]; modules: ModuleInfo[] }>("/api/modules")
      .then((d) => { if (live) setState({ enabled: new Set(d.enabled), modules: d.modules, ready: true }); })
      .catch(() => { if (live) setState((s) => ({ ...s, ready: true })); });
    return () => { live = false; };
  }, [me, authReady, tick]);
  const reload = useCallback(() => setTick((x) => x + 1), []);
  const on = useCallback((key: string) => state.enabled.has(key), [state.enabled]);
  return <Ctx.Provider value={{ ...state, reload, on }}>{children}</Ctx.Provider>;
}

export const useModules = () => useContext(Ctx);
