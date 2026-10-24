import { createContext, useCallback, useContext, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import QRCode from 'qrcode';
import { ApiError, message, SESSION_ENDED } from './api';
import { useI18n } from './i18n';

// Shared pieces of both surfaces: a form that shows the API's problem title, fields, a table, the authenticator
// set-up box with its QR code, and the step-up dialog for a fresh code before a sensitive action (DOC-S04 section 9).

export function Form({ title, submit, onSubmit, children, className }: {
  title?: string; submit: string; onSubmit: () => Promise<void>; children: ReactNode; className?: string;
}) {
  const { t } = useI18n();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function handle(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try { await onSubmit(); } catch (err) { setError(t(message(err))); } finally { setBusy(false); }
  }
  return (
    <form className={className ?? 'card'} onSubmit={handle}>
      {title && <h1>{t(title)}</h1>}
      {children}
      {error && <p role="alert" className="error">{error}</p>}
      <button type="submit" disabled={busy}>{t(submit)}</button>
    </form>
  );
}

export function Field({ label, value, onChange, type = 'text', autoComplete, required = true, hint }: {
  label: string; value: string; onChange: (v: string) => void; type?: string; autoComplete?: string; required?: boolean; hint?: string;
}) {
  const { t } = useI18n();
  return (
    <label>
      <span>{t(label)}</span>
      <input type={type} value={value} autoComplete={autoComplete} onChange={e => onChange(e.target.value)} required={required} dir="auto" />
      {hint && <small>{t(hint)}</small>}
    </label>
  );
}

export function Select({ label, value, onChange, options }: {
  label: string; value: string; onChange: (v: string) => void; options: { value: string; label: string }[];
}) {
  const { t } = useI18n();
  return (
    <label>
      <span>{t(label)}</span>
      <select value={value} onChange={e => onChange(e.target.value)}>
        {options.map(o => <option key={o.value} value={o.value}>{t(o.label)}</option>)}
      </select>
    </label>
  );
}

export function Table<T>({ rows, columns, empty = 'Nothing here yet.' }: {
  rows: T[]; columns: { header: string; cell: (r: T) => ReactNode }[]; empty?: string;
}) {
  const { t } = useI18n();
  if (rows.length === 0) return <p className="muted">{t(empty)}</p>;
  return (
    <table>
      <thead><tr>{columns.map(c => <th key={c.header}>{t(c.header)}</th>)}</tr></thead>
      <tbody>{rows.map((r, i) => <tr key={i}>{columns.map(c => <td key={c.header}>{c.cell(r)}</td>)}</tr>)}</tbody>
    </table>
  );
}

export function Notice({ error, ok }: { error?: string | null; ok?: string | null }) {
  const { t } = useI18n();
  if (error) return <p role="alert" className="error">{t(error)}</p>;
  if (ok) return <p role="status" className="ok">{t(ok)}</p>;
  return null;
}

/** The secret of an authenticator set-up: a QR code of the otpauth URI, the key to type, and the link for this device. */
export function SecretBox({ secret, uri }: { secret: string; uri: string }) {
  const { t } = useI18n();
  const [qr, setQr] = useState<string | null>(null);
  useEffect(() => { QRCode.toDataURL(uri, { margin: 1, width: 192 }).then(setQr).catch(() => setQr(null)); }, [uri]);
  return (
    <div className="secret">
      <p>{t('Scan the code with your authenticator app, or type the key, then enter the 6-digit code it shows.')}</p>
      {qr && <img src={qr} width={192} height={192} alt={t('QR code for the authenticator app')} />}
      <code dir="ltr">{secret.replace(/(.{4})/g, '$1 ').trim()}</code>
      <p><a href={uri}>{t('Open in authenticator app')}</a></p>
    </div>
  );
}

// ---------- step-up ----------

type AskCode = (reason: string) => Promise<string | null>;
const StepUpCtx = createContext<AskCode>(async () => null);

/** Provides useStepUp(): opens a dialog asking for a fresh authenticator code. */
/** password: the user has no authenticator and the account does not require one, so the step-up takes the password (ADR 0048). */
export function StepUpProvider({ children, password = false }: { children: ReactNode; password?: boolean }) {
  const { t } = useI18n();
  const [ask, setAsk] = useState<{ reason: string; resolve: (c: string | null) => void } | null>(null);
  const [code, setCode] = useState('');
  const ref = useRef<HTMLDialogElement>(null);
  const open = useCallback<AskCode>(reason => new Promise(resolve => { setCode(''); setAsk({ reason, resolve }); }), []);
  useEffect(() => { if (ask) ref.current?.showModal(); else ref.current?.close(); }, [ask]);
  const done = (value: string | null) => { ask?.resolve(value); setAsk(null); };
  return (
    <StepUpCtx.Provider value={open}>
      {children}
      <dialog ref={ref} onCancel={() => done(null)}>
        <form method="dialog" onSubmit={e => { e.preventDefault(); done(code); }}>
          <h2>{t(password ? 'Confirm with your password' : 'Confirm with your authenticator')}</h2>
          <p>{ask ? t(ask.reason) : ''}</p>
          {password
            ? <Field label="Password" value={code} onChange={setCode} type="password" autoComplete="current-password" />
            : <Field label="6-digit code" value={code} onChange={setCode} autoComplete="one-time-code" />}
          <div className="actions">
            <button type="submit">{t('Confirm')}</button>
            <button type="button" className="secondary" onClick={() => done(null)}>{t('Cancel')}</button>
          </div>
        </form>
      </dialog>
    </StepUpCtx.Provider>
  );
}

export const useStepUp = () => useContext(StepUpCtx);

/** Runs an action that may need a fresh code: asks for one and tries again when the API answers REAUTH_REQUIRED or STEP_UP_REQUIRED. */
export function useWithStepUp() {
  const ask = useStepUp();
  return useCallback(async <T,>(reason: string, action: (code?: string) => Promise<T>): Promise<T | null> => {
    try {
      return await action();
    } catch (e) {
      if (!(e instanceof ApiError) || !['REAUTH_REQUIRED', 'STEP_UP_REQUIRED'].includes(e.problem.code)) throw e;
      const code = await ask(reason);
      if (!code) return null;
      return await action(code);
    }
  }, [ask]);
}

/**
 * Signs an idle user out (FR-PLT-014): after `minutes` without a key, a click, a scroll or a touch, a warning gives a
 * minute to stay, then `onExpire` runs. Activity also keeps the server session alive (at most every 5 minutes), so
 * reading a page without requests does not let the server end it first. A session ended by the server (401) leaves too.
 */
export function IdleGuard({ minutes, keepAlive, onExpire }: { minutes: number; keepAlive: () => Promise<unknown>; onExpire: () => void }) {
  const { t } = useI18n();
  const last = useRef(Date.now());
  const touched = useRef(Date.now());
  const [warn, setWarn] = useState(false);
  useEffect(() => {
    const active = () => {
      last.current = Date.now();
      if (Date.now() - touched.current > 5 * 60_000) { touched.current = Date.now(); void keepAlive().catch(() => undefined); }
    };
    const events = ['mousedown', 'keydown', 'scroll', 'touchstart', 'wheel'] as const;
    events.forEach(e => window.addEventListener(e, active, { passive: true }));
    const ended = () => onExpire();
    window.addEventListener(SESSION_ENDED, ended);
    const timer = window.setInterval(() => {
      const idle = Date.now() - last.current;
      if (idle >= minutes * 60_000) { window.clearInterval(timer); onExpire(); }
      else setWarn(idle >= (minutes - 1) * 60_000);
    }, 5_000);
    return () => {
      events.forEach(e => window.removeEventListener(e, active));
      window.removeEventListener(SESSION_ENDED, ended);
      window.clearInterval(timer);
    };
  }, [minutes, keepAlive, onExpire]);
  if (!warn) return null;
  return (
    <div className="banner" role="alert">
      {t('You will be signed out in a minute because there has been no activity.')}{' '}
      <button className="link" onClick={() => { last.current = Date.now(); touched.current = Date.now(); setWarn(false); void keepAlive().catch(() => undefined); }}>
        {t('Stay signed in')}
      </button>
    </div>
  );
}
