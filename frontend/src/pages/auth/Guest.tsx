import { useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { homeFor, useAuth } from "../../auth";
import { ErrorBox, Field } from "../../components/ui";
import { AuthSide } from "./Login";

/** Booking without an account (N18, 1153): the guest proves an e-mail address with a code and books; afterwards the
 *  account page offers to keep the bookings by choosing a password. An e-mail that has an account is sent to sign in. */
export default function Guest() {
  const { t, locale } = useI18n();
  const { guest } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const next = params.get("next");
  const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : null;
  const [email, setEmail] = useState("");
  const [code, setCode] = useState("");
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const exists = error instanceof Error && "code" in error && (error as { code: string }).code === "ACCOUNT_EXISTS";

  const send = async (e?: FormEvent) => {
    e?.preventDefault();
    setBusy(true); setError(null);
    try { await api.post("/api/auth/guest/start", { email: email.trim(), locale }); setSent(true); setCode(""); }
    catch (err) { setError(err); } finally { setBusy(false); }
  };
  const verify = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      const res = await guest(email.trim(), code);
      if ("mfaStep" in res) { nav(`/mfa?mode=${res.mfaStep}${safeNext ? `&next=${encodeURIComponent(safeNext)}` : ""}`, { replace: true }); return; }
      nav(safeNext ?? homeFor(res), { replace: true });
    } catch (err) { setError(err); } finally { setBusy(false); }
  };
  const login = `/login${safeNext ? `?next=${encodeURIComponent(safeNext)}` : ""}`;

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        <form className="card hero stack" onSubmit={sent ? verify : send}>
          <div><h2>{t("guest.title")}</h2><p className="muted">{t(sent ? "guest.codeSub" : "guest.sub", { email: email.trim() })}</p></div>
          <ErrorBox error={error} />
          {exists && <p className="small"><Link to={login}>{t("guest.signInInstead")}</Link></p>}
          {!sent ? (
            <Field label={t("common.email")}>
              <input className="input ltr" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
            </Field>
          ) : (
            <Field label={t("names.code")}>
              <input className="input ltr" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code} required pattern="[0-9]{6}"
                     onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} />
            </Field>
          )}
          <button className="btn large block" disabled={busy || (sent && code.length !== 6)}>{t(sent ? "guest.continue" : "guest.send")}</button>
          {sent && (
            <div className="row between small">
              <button type="button" className="btn text" disabled={busy} onClick={() => { setSent(false); setError(null); }}>{t("guest.changeEmail")}</button>
              <button type="button" className="btn text" disabled={busy} onClick={() => void send()}>{t("names.resend")}</button>
            </div>
          )}
          <p className="small muted">{t("guest.note")}</p>
          <p className="center small">{t("guest.haveAccount")} <Link to={login}>{t("nav.login")}</Link></p>
        </form>
      </div>
    </div>
  );
}
