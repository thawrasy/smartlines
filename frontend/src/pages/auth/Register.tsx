import { useState, type FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { ErrorBox, Field } from "../../components/ui";
import { AuthSide } from "./Login";

export default function Register() {
  const { t, locale } = useI18n();
  const { login } = useAuth();
  const nav = useNavigate();
  const [form, setForm] = useState({ full_name: "", email: "", mobile: "", password: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm({ ...form, [k]: e.target.value });

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      await api.post("/api/auth/register", { ...form, mobile: form.mobile.trim() || null, locale });
      await login(form.email, form.password, "PASSENGER");
      nav("/", { replace: true });
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        <form className="card hero stack" onSubmit={submit}>
          <div><h2>{t("auth.registerTitle")}</h2><p className="muted">{t("auth.registerSub")}</p></div>
          <ErrorBox error={error} />
          <Field label={t("common.name")}><input className="input" value={form.full_name} onChange={set("full_name")} required minLength={3} autoComplete="name" /></Field>
          <Field label={t("common.email")}><input className="input ltr" type="email" value={form.email} onChange={set("email")} required autoComplete="email" /></Field>
          <Field label={`${t("common.mobile")} (${t("common.optional")})`}><input className="input ltr" inputMode="tel" value={form.mobile} onChange={set("mobile")} pattern="\+?[0-9]{8,15}" autoComplete="tel" /></Field>
          <Field label={t("common.password")} hint={t("auth.passwordHint")}>
            <input className="input ltr" type="password" value={form.password} onChange={set("password")} required minLength={12} autoComplete="new-password" />
          </Field>
          <button className="btn large block" disabled={busy}>{t("nav.register")}</button>
          <p className="center small">{t("auth.haveAccount")} <Link to="/login">{t("nav.login")}</Link></p>
        </form>
      </div>
    </div>
  );
}
