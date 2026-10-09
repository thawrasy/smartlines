import { useEffect, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import QRCode from "qrcode";
import { api, type Me, type MfaStep } from "../../api";
import { useI18n } from "../../i18n";
import { homeFor, useAuth } from "../../auth";
import { ErrorBox, Field, Icon, Spinner } from "../../components/ui";
import type { IconName } from "../../components/icons";
import { AuthSide } from "./Login";

type Method = "TOTP" | "SMS" | "WHATSAPP";
interface Methods { available: Method[]; enrolled: Method[]; usable: Method[]; sent_to: Partial<Record<Method, string>>; account_mobile: string | null; code_minutes: number; resend_seconds: number }
interface Enrolment { secret: string; uri: string }
interface Sent { sent_to: string; resend_in: number }

const ICON: Record<Method, IconName> = { TOTP: "password", SMS: "sms", WHATSAPP: "chat" };

/** Second step of a staff sign-in (owner's decision 2): a code from the authenticator app, a code sent by text or
 *  WhatsApp message, or a recovery code; or the first enrolment of one of the methods the platform opened. */
export default function Mfa() {
  const { t } = useI18n();
  const { refresh } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const mode = (params.get("mode") as MfaStep) || "VERIFY";
  const next = params.get("next");
  const [methods, setMethods] = useState<Methods | null>(null);
  const [method, setMethod] = useState<Method | null>(null);
  const [code, setCode] = useState("");
  const [mobile, setMobile] = useState("");
  const [useRecovery, setUseRecovery] = useState(false);
  const [enrolment, setEnrolment] = useState<Enrolment | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [sent, setSent] = useState<Sent | null>(null);
  const [wait, setWait] = useState(0);
  const [recovery, setRecovery] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    api.get<Methods>("/api/auth/mfa/methods").then((m) => {
      setMethods(m);
      const choices = mode === "ENROLL" ? m.available : m.usable;
      if (choices.length === 1) setMethod(choices[0]);
    }).catch(setError);
  }, [mode]);

  useEffect(() => {
    if (wait <= 0) return;
    const id = window.setTimeout(() => setWait(wait - 1), 1000);
    return () => window.clearTimeout(id);
  }, [wait]);

  // the authenticator app's enrolment starts as soon as it is chosen; a message method waits for the number
  useEffect(() => {
    if (mode !== "ENROLL" || method !== "TOTP" || enrolment) return;
    api.post<Enrolment>("/api/auth/mfa/enroll", { method: "TOTP" })
      .then(async (e) => { setEnrolment(e); setQr(await QRCode.toDataURL(e.uri, { margin: 1, width: 220 })); })
      .catch(setError);
  }, [mode, method, enrolment]);

  const finish = async () => {
    await refresh();
    const me = await api.get<Me>("/api/auth/me");
    nav(next && next.startsWith("/") && !next.startsWith("//") ? next : homeFor(me), { replace: true });
  };

  const sendCode = async () => {
    if (!method || method === "TOTP") return;
    setBusy(true); setError(null);
    try {
      const r = mode === "ENROLL" && !sent
        ? await api.post<Sent>("/api/auth/mfa/enroll", { method, mobile: mobile.trim() || null })
        : await api.post<Sent>("/api/auth/mfa/send", { method });
      setSent(r); setWait(r.resend_in);
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      if (mode === "ENROLL") {
        const r = await api.post<{ recovery_codes: string[] | null }>("/api/auth/mfa/confirm", { code: code.trim(), method });
        if (r.recovery_codes) setRecovery(r.recovery_codes); else await finish();
      } else {
        await api.post("/api/auth/mfa/verify", { code: code.trim(), method: useRecovery || method === "TOTP" ? null : method });
        await finish();
      }
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  const copy = async () => {
    try { await navigator.clipboard.writeText(recovery!.join("\n")); } catch { /* the codes stay visible to copy by hand */ }
  };

  const choices = methods ? (mode === "ENROLL" ? methods.available : methods.usable) : [];
  const message = method === "SMS" || method === "WHATSAPP";
  const ready = useRecovery || method === "TOTP" ? (mode !== "ENROLL" || !!enrolment) : !!sent;

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        {recovery ? (
          <div className="card hero stack">
            <div><h2>{t("auth.mfa.savedTitle")}</h2><p className="muted">{t("auth.mfa.savedText")}</p></div>
            <ul className="recovery-codes ltr">{recovery.map((c) => <li key={c} className="mono">{c}</li>)}</ul>
            <div className="row">
              <button type="button" className="btn outlined" onClick={copy}><Icon name="content_copy" size={18} />{t("common.copy")}</button>
              <button type="button" className="btn grow" onClick={() => void finish()}>{t("auth.mfa.continue")}</button>
            </div>
          </div>
        ) : (
          <form className="card hero stack" onSubmit={submit}>
            <div>
              <h2>{t(mode === "ENROLL" ? "auth.mfa.enrollTitle" : "auth.mfa.verifyTitle")}</h2>
              <p className="muted">{t(useRecovery ? "auth.mfa.recoveryText" : method ? `auth.mfa.text.${mode}.${method}` : "auth.mfa.chooseText")}</p>
            </div>
            {!methods && !error && <Spinner />}
            {methods && !useRecovery && choices.length > 1 && (
              <div className="row wrap" role="radiogroup" aria-label={t("auth.mfa.chooseText")}>
                {choices.map((m) => (
                  <button key={m} type="button" role="radio" aria-checked={method === m}
                          className={`btn ${method === m ? "" : "outlined"}`}
                          onClick={() => { setMethod(m); setSent(null); setCode(""); setError(null); }}>
                    <Icon name={ICON[m]} size={18} />{t(`auth.mfa.method.${m}`)}
                  </button>
                ))}
              </div>
            )}
            {mode === "ENROLL" && method === "TOTP" && (enrolment ? (
              <div className="stack tight center">
                {qr && <img src={qr} alt={t("auth.mfa.qrAlt")} width={220} height={220} style={{ margin: "0 auto", borderRadius: 12 }} />}
                <span className="small muted">{t("auth.mfa.manual")}</span>
                <code className="mono ltr" style={{ wordBreak: "break-all" }}>{enrolment.secret.match(/.{1,4}/g)?.join(" ")}</code>
              </div>
            ) : !error && <Spinner />)}
            {mode === "ENROLL" && message && !sent && (
              <Field label={t("auth.mfa.mobileLabel")} hint={methods?.account_mobile ? t("auth.mfa.mobileHint", { mobile: methods.account_mobile }) : undefined}>
                <input className="input ltr" value={mobile} onChange={(e) => setMobile(e.target.value)} inputMode="tel"
                       autoComplete="tel" placeholder="+9639XXXXXXXX" required={!methods?.account_mobile} />
              </Field>
            )}
            {message && !useRecovery && (
              <div className="row wrap">
                <button type="button" className="btn outlined" onClick={() => void sendCode()} disabled={busy || wait > 0}>
                  <Icon name="send" size={18} />{t(sent ? "auth.mfa.resend" : "auth.mfa.send")}{wait > 0 ? ` (${wait})` : ""}
                </button>
                {(sent || (mode === "VERIFY" && methods?.sent_to[method!])) && (
                  <span className="small muted">{t("auth.mfa.sentTo", { to: sent?.sent_to ?? methods?.sent_to[method!] ?? "" })}</span>
                )}
              </div>
            )}
            <ErrorBox error={error} />
            {(method || useRecovery) && (
              <Field label={t(useRecovery ? "auth.mfa.recoveryLabel" : "auth.mfa.codeLabel")}>
                <input className="input ltr center mono" value={code} onChange={(e) => setCode(e.target.value)} required autoFocus
                       inputMode={useRecovery ? "text" : "numeric"} autoComplete="one-time-code" maxLength={useRecovery ? 12 : 6}
                       placeholder={useRecovery ? "XXXX-XXXX" : "000000"} disabled={!ready} />
              </Field>
            )}
            {(method || useRecovery) && <button className="btn large block" disabled={busy || !ready}>{t("auth.mfa.submit")}</button>}
            {mode === "VERIFY" && (
              <button type="button" className="btn text" onClick={() => { setUseRecovery(!useRecovery); setCode(""); }}>
                {t(useRecovery ? "auth.mfa.useApp" : "auth.mfa.useRecovery")}
              </button>
            )}
          </form>
        )}
      </div>
    </div>
  );
}
