import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { ICONS, type IconName } from "./icons";
import { useI18n } from "../i18n";
import { ApiError } from "../api";

export function Icon({ name, size, flip, className }: { name: IconName; size?: number; flip?: boolean; className?: string }) {
  return (
    <span className={`icon${flip ? " flip" : ""}${className ? " " + className : ""}`} style={size ? { width: size, height: size } : undefined}
          aria-hidden="true" dangerouslySetInnerHTML={{ __html: ICONS[name] }} />
  );
}

const ROUTE = "M15.5 43.5 C20.5 32.5 24.5 22 32.5 22 C39.5 22 41.5 32.5 48.5 34.5";

/** Masslak mark: one arc from a light-blue origin stop to a green destination stop on a navy square. */
export function Logo({ size = 36 }: { size?: number }) {
  return (
    <svg className="brand-mark" width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <rect width="64" height="64" rx="16" fill="#0B1F3F" />
      <path d={ROUTE} fill="none" stroke="#2F7BFF" strokeWidth="6" strokeLinecap="round" />
      <circle cx="15.5" cy="43.5" r="5" fill="#7FB0FF" />
      <circle cx="48.5" cy="34.5" r="5" fill="#12A06A" />
    </svg>
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
  DELIVERED: "blue", RETURNED: "", EXCEPTION: "red", SEARCHING: "wheat", ASSIGNED: "blue", ARRIVING: "wheat", ON_TRIP: "blue",
  OPEN: "green", AWARDED: "blue", CONTRACTED: "blue", SUBMITTED: "wheat", ACCEPTED: "green", WITHDRAWN: "", CREATED: "wheat",
  PICKED_UP: "blue", IN_NETWORK: "blue", OUT_FOR_DELIVERY: "wheat", LIVE: "green", PAUSED: "wheat",
  CANCELLED: "red", BLOCKED: "red", SUSPENDED: "red", REJECTED: "red", FAILURE: "red", FAILED: "red", DENIED: "red", EXPIRED: "red", LOCKED: "red",
};

export function Status({ value }: { value: string }) {
  const { t, has } = useI18n();
  const label = has(`status.${value}`) ? t(`status.${value}`) : has(`val.${value}`) ? t(`val.${value}`) : value;
  return <span className={`chip ${STATUS_TONE[value] ?? ""}`}>{label}</span>;
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
      if (error.code === "TIMEOUT") return t("errors.timeout");
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

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** A modal dialog (review of 1.47.0, R-37): focus moves into it on opening, Tab and Shift+Tab stay inside it, Escape
 *  or the close button closes it, and focus returns to what opened it. */
export function Modal({ title, onClose, children, actions, wide }: { title: string; onClose: () => void; children: ReactNode; actions?: ReactNode; wide?: boolean }) {
  const { t } = useI18n();
  const box = useRef<HTMLDivElement>(null);
  const titleId = useId();
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    const first = box.current?.querySelector<HTMLElement>(`.modal-body ${FOCUSABLE}`) ?? box.current;
    first?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.preventDefault(); close.current(); return; }
      if (e.key !== "Tab" || !box.current) return;
      const items = Array.from(box.current.querySelectorAll<HTMLElement>(FOCUSABLE)).filter((el) => el.offsetParent !== null);
      if (items.length === 0) { e.preventDefault(); box.current.focus(); return; }
      const [head, tail] = [items[0], items[items.length - 1]];
      if (e.shiftKey && (document.activeElement === head || document.activeElement === box.current)) { e.preventDefault(); tail.focus(); }
      else if (!e.shiftKey && document.activeElement === tail) { e.preventDefault(); head.focus(); }
      else if (!box.current.contains(document.activeElement)) { e.preventDefault(); head.focus(); }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      if (opener && document.contains(opener)) opener.focus();
    };
  }, []);
  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby={titleId} ref={box} tabIndex={-1}
           style={wide ? { maxWidth: 860 } : undefined}>
        <div className="row between" style={{ marginBottom: 20 }}>
          <h2 id={titleId} style={{ margin: 0 }}>{title}</h2>
          <button type="button" className="icon-btn" onClick={onClose} aria-label={t("common.close")}><Icon name="close" /></button>
        </div>
        <div className="modal-body">{children}</div>
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
/** Loads data for a screen. The loader receives a signal that is aborted when the screen closes or reloads, so a
 *  loader that passes it on (api.get(path, params, { signal })) stops its request instead of finishing it unseen. */
export function useLoad<T>(loader: (signal: AbortSignal) => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    const stop = new AbortController();
    setLoading(true);
    loader(stop.signal).then((d) => { if (live) { setData(d); setError(null); } })
      .catch((e) => { if (live) setError(e); })
      .finally(() => { if (live) setLoading(false); });
    return () => { live = false; stop.abort(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, loading, reload: () => setTick((x) => x + 1), setData };
}

export function Loaded<T>({ state, children }: { state: { data: T | null; error: unknown; loading: boolean }; children: (d: T) => ReactNode }) {
  if (state.error && !state.data) return <ErrorBox error={state.error} />;
  if (!state.data) return <Spinner />;
  return <>{children(state.data)}</>;
}
