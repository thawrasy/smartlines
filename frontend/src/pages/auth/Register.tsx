import { useState, type ClipboardEvent, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { ErrorBox, Field, PasswordInput } from "../../components/ui";
import { NameFields, blankName, nameBody, nameValid, type NameDraft } from "../../components/NameFields";
import { AuthSide } from "./Login";

// The two confirmation fields are typed, not pasted (owner, N35): a mistake copied twice locks people out of their account.
// The first e-mail and password fields accept a paste, so a password manager can fill them.
const noPaste = (e: ClipboardEvent<HTMLInputElement>) => e.preventDefault();

export default function Register() {
  const { t, locale } = useI18n();
  const { signIn } = useAuth();
  const nav = useNavigate();
  const [name, setName] = useState<NameDraft>(blankName());
  const [form, setForm] = useState({ email: "", email_confirm: "", mobile: "", password: "", password_confirm: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm({ ...form, [k]: e.target.value });
  const emailDiffers = form.email_confirm !== "" && form.email_confirm.trim().toLowerCase() !== form.email.trim().toLowerCase();
  const passwordDiffers = form.password_confirm !== "" && form.password_confirm !== form.password;
  const ready = nameValid(name) && form.email && form.email_confirm && !emailDiffers && form.password && form.password_confirm && !passwordDiffers;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!ready) return;
    setBusy(true); setError(null);
    try {
      await api.post("/api/auth/register", { name: nameBody(name), email: form.email.trim(), email_confirm: form.email_confirm.trim(),
        mobile: form.mobile.trim() || null, password: form.password, password_confirm: form.password_confirm, locale });
      await signIn({ kind: "individual", identifier: form.email.trim(), password: form.password });
      nav("/account?verify=email", { replace: true });
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        <form className="card hero stack" onSubmit={submit}>
          <div><h2>{t("auth.registerTitle")}</h2><p className="muted">{t("auth.registerSub")}</p></div>
          <ErrorBox error={error} />
          <NameFields value={name} onChange={setName} />
          <div className="grid cols-2">
            <Field label={t("common.email")}><input className="input ltr" type="email" value={form.email} onChange={set("email")} required autoComplete="email" /></Field>
            <Field label={t("auth.emailConfirm")}>
              <input className="input ltr" type="email" value={form.email_confirm} onChange={set("email_confirm")} onPaste={noPaste} required
                     autoComplete="off" aria-invalid={emailDiffers} />
            </Field>
          </div>
          {emailDiffers && <p className="small" role="alert" style={{ color: "var(--error)" }}>{t("auth.emailMismatch")}</p>}
          <Field label={t("common.mobile")} optional><input className="input ltr" inputMode="tel" value={form.mobile} onChange={set("mobile")} pattern="\+?[0-9]{8,15}" autoComplete="tel" /></Field>
          <div className="grid cols-2">
            <Field label={t("common.password")} hint={t("auth.passwordHint")}>
              <PasswordInput value={form.password} onChange={set("password")} required minLength={12} autoComplete="new-password" />
            </Field>
            <Field label={t("auth.passwordConfirm")}>
              <PasswordInput value={form.password_confirm} onChange={set("password_confirm")} onPaste={noPaste} required minLength={12}
                             autoComplete="new-password" aria-invalid={passwordDiffers} />
            </Field>
          </div>
          {passwordDiffers && <p className="small" role="alert" style={{ color: "var(--error)" }}>{t("auth.passwordMismatch")}</p>}
          <p className="small muted">{t("auth.unverifiedNote")}</p>
          <button className="btn large block" disabled={busy || !ready}>{t("nav.register")}</button>
          <p className="center small">{t("auth.haveAccount")} <Link to="/login">{t("nav.login")}</Link></p>
        </form>
      </div>
    </div>
  );
}
