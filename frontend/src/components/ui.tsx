import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { ICONS, type IconName } from "./icons";
import { useI18n } from "../i18n";
import { ApiError } from "../api";

export function Icon({ name, size, flip, className }: { name: IconName; size?: number; flip?: boolean; className?: string }) {
  return (
    <span className={`icon${flip ? " flip" : ""}${className ? " " + className : ""}`} style={size ? { width: size, height: size } : undefined}
          aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[name] }} />
  );
}

export function Logo({ size = 36 }: { size?: number }) {
  return (
    <span className="brand-mark" style={{ width: size, height: size, borderRadius: size * 0.3 }}>
      <svg viewBox="0 0 64 64" width={size * 0.72} height={size * 0.72} aria-hidden="true">
        <path d="M12 44c8-15 17-22 40-24" stroke="#F6E7BF" strokeWidth="6" fill="none" strokeLinecap="round" />
        <circle cx="14" cy="44" r="5.5" fill="#fff" /><circle cx="50" cy="20" r="5.5" fill="#fff" />
      </svg>
    </span>
  );
}

export function Spinner() { return <div className="spinner" role="status" />; }

export function Empty({ icon = "travel_explore", title, hint, children }: { icon?: IconName; title: string; hint?: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <Icon name={icon} />
      <h3 style={{ color: "var(--on-surface)" }}>{title}</h3>
      {hint && <p className="small" style={{ marginTop: 6 }}>{hint}</p>}
      {children && <div style={{ marginTop: 16 }}>{children}</div>}
    </div>
  );
}

const STATUS_TONE: Record<string, string> = {
  PUBLISHED: "green", CONFIRMED: "green", ISSUED: "green", ACTIVE: "green", APPROVED: "green", SUCCESS: "green", COMPLETED: "blue",
  BOARDED: "blue", BOARDING: "wheat", DEPARTED: "wheat", PENDING: "wheat", PENDING_PAYMENT: "wheat", DRAFT: "", MAINTENANCE: "wheat",
  CANCELLED: "red", BLOCKED: "red", SUSPENDED: "red", REJECTED: "red", FAILURE: "red", FAILED: "red", DENIED: "red", EXPIRED: "red", LOCKED: "red",
};

export function Status({ value }: { value: string }) {
  const { t, has } = useI18n();
  return <span className={`chip ${STATUS_TONE[value] ?? ""}`}>{has(`status.${value}`) ? t(`status.${value}`) : value}</span>;
}

export function ErrorBox({ error }: { error: unknown }) {
  const msg = useErrorText()(error);
  if (!error) return null;
  return <div className="alert error" role="alert"><Icon name="error" /> <span>{msg}</span></div>;
}

export function useErrorText() {
  const { t, has } = useI18n();
  return useCallback((error: unknown) => {
    if (!error) return "";
    if (error instanceof ApiError) {
      if (error.code === "NETWORK") return t("errors.network");
      if (has(`errors.${error.code}`)) return t(`errors.${error.code}`);
    }
    return t("errors.generic");
  }, [t, has]);
}

export function Field({ label, hint, children }: { label: string; hint?: string; children: ReactNode }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
      {hint && <small className="hint">{hint}</small>}
    </label>
  );
}

export function Modal({ title, onClose, children, actions, wide }: { title: string; onClose: () => void; children: ReactNode; actions?: ReactNode; wide?: boolean }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-label={title} style={wide ? { maxWidth: 860 } : undefined}>
        <div className="row between" style={{ marginBottom: 20 }}>
          <h2 style={{ margin: 0 }}>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="close"><Icon name="close" /></button>
        </div>
        {children}
        {actions && <div className="modal-actions">{actions}</div>}
      </div>
    </div>
  );
}

export function Stat({ icon, label, value, tone }: { icon: IconName; label: string; value: ReactNode; tone?: "wheat" | "blue" | "red" }) {
  return (
    <div className={`stat ${tone ?? ""}`}>
      <div className="label"><span className="badge-ic"><Icon name={icon} size={20} /></span>{label}</div>
      <div className="value">{value}</div>
    </div>
  );
}

// ---------- Toasts ----------
const ToastCtx = createContext<(msg: string) => void>(() => {});
export function ToastProvider({ children }: { children: ReactNode }) {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    if (!msg) return;
    const id = setTimeout(() => setMsg(null), 4000);
    return () => clearTimeout(id);
  }, [msg]);
  return (
    <ToastCtx.Provider value={setMsg}>
      {children}
      {msg && <div className="toast" role="status">{msg}</div>}
    </ToastCtx.Provider>
  );
}
export const useToast = () => useContext(ToastCtx);

// ---------- Data loading ----------
export function useLoad<T>(loader: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    setLoading(true);
    loader().then((d) => { if (live) { setData(d); setError(null); } })
      .catch((e) => { if (live) setError(e); })
      .finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, loading, reload: () => setTick((x) => x + 1), setData };
}

export function Loaded<T>({ state, children }: { state: { data: T | null; error: unknown; loading: boolean }; children: (d: T) => ReactNode }) {
  if (state.error && !state.data) return <ErrorBox error={state.error} />;
  if (!state.data) return <Spinner />;
  return <>{children(state.data)}</>;
}
