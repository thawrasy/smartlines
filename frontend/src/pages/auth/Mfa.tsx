import { useEffect, useState, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import QRCode from "qrcode";
import { api, type Me, type MfaStep } from "../../api";
import { useI18n } from "../../i18n";
import { homeFor, useAuth } from "../../auth";
import { ErrorBox, Field, Icon, Spinner } from "../../components/ui";
import { AuthSide } from "./Login";

interface Enrolment { secret: string; uri: string }

/** Second step of a staff sign-in: a code from the authenticator app, a recovery code, or first-time enrolment. */
export default function Mfa() {
  const { t } = useI18n();
  const { refresh } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const mode = (params.get("mode") as MfaStep) || "VERIFY";
  const next = params.get("next");
  const [code, setCode] = useState("");
  const [useRecovery, setUseRecovery] = useState(false);
  const [enrolment, setEnrolment] = useState<Enrolment | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [recovery, setRecovery] = useState<string[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  useEffect(() => {
    if (mode !== "ENROLL") return;
    api.post<Enrolment>("/api/auth/mfa/enroll")
      .then(async (e) => { setEnrolment(e); setQr(await QRCode.toDataURL(e.uri, { margin: 1, width: 220 })); })
      .catch(setError);
  }, [mode]);

  const finish = async () => {
    await refresh();
    const me = await api.get<Me>("/api/auth/me");
    nav(next && next.startsWith("/") && !next.startsWith("//") ? next : homeFor(me), { replace: true });
  };

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      if (mode === "ENROLL") {
        const r = await api.post<{ recovery_codes: string[] }>("/api/auth/mfa/confirm", { code: code.trim() });
        setRecovery(r.recovery_codes);
      } else {
        await api.post("/api/auth/mfa/verify", { code: code.trim() });
        await finish();
      }
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  const copy = async () => {
    try { await navigator.clipboard.writeText(recovery!.join("\n")); } catch { /* the codes stay visible to copy by hand */ }
  };

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
              <p className="muted">{t(mode === "ENROLL" ? "auth.mfa.enrollText" : useRecovery ? "auth.mfa.recoveryText" : "auth.mfa.verifyText")}</p>
            </div>
            {mode === "ENROLL" && (enrolment ? (
              <div className="stack tight center">
                {qr && <img src={qr} alt={t("auth.mfa.qrAlt")} width={220} height={220} style={{ margin: "0 auto", borderRadius: 12 }} />}
                <span className="small muted">{t("auth.mfa.manual")}</span>
                <code className="mono ltr" style={{ wordBreak: "break-all" }}>{enrolment.secret.match(/.{1,4}/g)?.join(" ")}</code>
              </div>
            ) : !error && <Spinner />)}
            <ErrorBox error={error} />
            <Field label={t(useRecovery ? "auth.mfa.recoveryLabel" : "auth.mfa.codeLabel")}>
              <input className="input ltr center mono" value={code} onChange={(e) => setCode(e.target.value)} required autoFocus
                     inputMode={useRecovery ? "text" : "numeric"} autoComplete="one-time-code" maxLength={useRecovery ? 12 : 6}
                     placeholder={useRecovery ? "XXXX-XXXX" : "000000"} />
            </Field>
            <button className="btn large block" disabled={busy || (mode === "ENROLL" && !enrolment)}>{t("auth.mfa.submit")}</button>
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
