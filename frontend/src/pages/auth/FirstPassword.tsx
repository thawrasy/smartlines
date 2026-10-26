import { useState, type ClipboardEvent, type FormEvent } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { api, type Me } from "../../api";
import { useI18n } from "../../i18n";
import { homeFor, useAuth } from "../../auth";
import { ErrorBox, Field, Icon, PasswordInput } from "../../components/ui";
import { AuthSide } from "./Login";

const noPaste = (e: ClipboardEvent<HTMLInputElement>) => e.preventDefault();

/** The first sign-in with a password an administrator set (N16, 1150): the employee chooses their own before anything
 *  else, then goes on to the second factor when the session owes one. */
export default function FirstPassword() {
  const { t } = useI18n();
  const { refresh } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const [form, setForm] = useState({ current: "", next: "", confirm: "" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm({ ...form, [k]: e.target.value });
  const differs = form.confirm !== "" && form.confirm !== form.next;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (differs) return;
    setBusy(true); setError(null);
    try {
      await api.post("/api/account/password/first", { current_password: form.current, new_password: form.next });
      const mode = params.get("mode");
      const next = params.get("next");
      const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : null;
      if (mode) {
        nav(`/mfa?mode=${mode}${safeNext ? `&next=${encodeURIComponent(safeNext)}` : ""}`, { replace: true });
        return;
      }
      await refresh();
      const me = await api.get<Me>("/api/auth/me");
      nav(safeNext ?? homeFor(me), { replace: true });
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        <form className="card hero stack" onSubmit={submit}>
          <div><h2>{t("auth.firstPasswordTitle")}</h2><p className="muted">{t("auth.firstPasswordSub")}</p></div>
          <div className="alert info small"><Icon name="password" size={20} /><span>{t("auth.firstPasswordNote")}</span></div>
          <ErrorBox error={error} />
          <Field label={t("auth.temporaryPassword")}>
            <PasswordInput autoComplete="current-password" value={form.current} onChange={set("current")} required />
          </Field>
          <Field label={t("auth.newPassword")} hint={t("auth.passwordHint")}>
            <PasswordInput autoComplete="new-password" value={form.next} onChange={set("next")} required minLength={12} />
          </Field>
          <Field label={t("auth.passwordConfirm")}>
            <PasswordInput autoComplete="new-password" value={form.confirm} onChange={set("confirm")} onPaste={noPaste} required minLength={12}
                           aria-invalid={differs} />
          </Field>
          {differs && <p className="small" role="alert" style={{ color: "var(--error)" }}>{t("auth.passwordMismatch")}</p>}
          <button className="btn large block" disabled={busy || differs || !form.current || !form.next || !form.confirm}>{t("auth.firstPasswordSave")}</button>
        </form>
      </div>
    </div>
  );
}
