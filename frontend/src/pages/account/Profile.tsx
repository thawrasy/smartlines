import { useEffect, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { ErrorBox, Field, Icon, Loaded, useLoad, useToast } from "../../components/ui";
import { NameFields, blankName, nameBody, nameValid, type NameDraft, type NameRules } from "../../components/NameFields";

interface Profile {
  name: Partial<Record<keyof NameDraft, string | null>>; names_complete: boolean; verification_status: string;
  email: string | null; email_verified: boolean; rules: NameRules;
}

/** The person's name in parts (N4) and the e-mail's confirmation (N35), at the top of the account page. */
export function ProfileCard() {
  const { t } = useI18n();
  const { refresh } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<Profile>("/api/account/profile"));
  const [name, setName] = useState<NameDraft>(blankName());
  const [code, setCode] = useState("");
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    if (!state.data) return;
    const n = blankName();
    for (const k of Object.keys(n) as (keyof NameDraft)[]) n[k] = state.data.name[k] ?? (k === "nationality" ? "SY" : "");
    setName(n);
  }, [state.data]);
  const act = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true); setError(null);
    try { await fn(); toast(done); state.reload(); await refresh?.(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Loaded state={state}>{(p) => {
      const locked = p.verification_status === "VERIFIED";
      return (
        <div className="stack">
          {!p.email_verified && p.email && (
            <div className="card stack" aria-labelledby="verify-email">
              <h3 id="verify-email">{t("names.verifyEmailTitle")}</h3>
              <p className="small muted">{t("names.verifyEmailSub", { email: p.email })}</p>
              <div className="row" style={{ alignItems: "flex-end", flexWrap: "wrap" }}>
                <Field label={t("names.code")}>
                  <input className="input ltr" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code}
                         onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} />
                </Field>
                <button className="btn" disabled={busy || code.length !== 6} onClick={() => act(() => api.post("/api/account/email/verify", { code }), t("names.emailVerified"))}>
                  {t("names.confirm")}</button>
                <button className="btn text" disabled={busy} onClick={() => act(() => api.post("/api/account/email/send"), t("names.codeSent"))}>{t("names.resend")}</button>
              </div>
            </div>
          )}
          <div className="card stack" aria-labelledby="my-name">
            <div className="row between"><h3 id="my-name">{t("names.title")}</h3>
              <span className={`chip ${p.verification_status === "VERIFIED" ? "green" : ""}`}>
                {p.verification_status === "VERIFIED" && <Icon name="verified" size={16} />}{t(`names.status.${p.verification_status}`)}</span></div>
            {!p.names_complete && <div className="alert warn small"><Icon name="badge" size={20} /><span>{t("names.complete")}</span></div>}
            <p className="small muted">{locked ? t("names.locked") : t("names.sub")}</p>
            <ErrorBox error={error} />
            <NameFields value={name} onChange={setName} rules={p.rules} disabled={locked} />
            {!locked && <div className="row"><button className="btn" disabled={busy || !nameValid(name, p.rules)}
                                                       onClick={() => act(() => api.put("/api/account/names", nameBody(name)), t("common.saved"))}>{t("common.save")}</button></div>}
          </div>
        </div>
      );
    }}</Loaded>
  );
}
