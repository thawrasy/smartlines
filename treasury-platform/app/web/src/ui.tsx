import { useState, type FormEvent, type ReactNode } from 'react';
import { message } from './api';

// Small shared pieces: a form that shows the API's problem title, and a labelled input.
export function Form({ title, submit, onSubmit, children }: {
  title: string; submit: string; onSubmit: () => Promise<void>; children: ReactNode;
}) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function handle(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try { await onSubmit(); } catch (err) { setError(message(err)); } finally { setBusy(false); }
  }
  return (
    <form className="card" onSubmit={handle}>
      <h1>{title}</h1>
      {children}
      {error && <p role="alert" className="error">{error}</p>}
      <button type="submit" disabled={busy}>{submit}</button>
    </form>
  );
}

export function Field({ label, value, onChange, type = 'text', autoComplete }: {
  label: string; value: string; onChange: (v: string) => void; type?: string; autoComplete?: string;
}) {
  return (
    <label>
      <span>{label}</span>
      <input type={type} value={value} autoComplete={autoComplete} onChange={e => onChange(e.target.value)} required />
    </label>
  );
}

/** The secret and otpauth URI of an authenticator set-up (a QR code comes with the design system, docs/42). */
export function SecretBox({ secret, uri }: { secret: string; uri: string }) {
  return (
    <div className="secret">
      <p>Add this key to your authenticator app, then enter the 6-digit code it shows.</p>
      <code>{secret.replace(/(.{4})/g, '$1 ').trim()}</code>
      <p><a href={uri}>Open in authenticator app</a></p>
    </div>
  );
}
