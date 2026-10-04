import { useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import type { Portal } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth, homeFor } from "../../auth";
import { ErrorBox, Field, Icon } from "../../components/ui";

const PORTALS: Portal[] = ["PASSENGER", "OPERATOR", "DRIVER", "AGENCY", "PLATFORM"];
// Demo accounts are listed only in the test environment build
const DEMO: Record<Portal, string[]> = {
  PASSENGER: ["passenger@masslak.test"], OPERATOR: ["owner@carrier.test"], DRIVER: ["driver@carrier.test", "driver2@carrier.test", "driver3@carrier.test"],
  AGENCY: ["agency@agency.test"], PLATFORM: ["admin@masslak.test", "regulator@masslak.test"],
};
const SHOW_DEMO = import.meta.env.VITE_SHOW_DEMO !== "false";

export function AuthSide() {
  const { t } = useI18n();
  return (
    <div className="auth-side">
      <span className="eyebrow" style={{ alignSelf: "flex-start" }}><Icon name="shield" size={18} />{t("app.name")}</span>
      <h1>{t("auth.sideTitle")}</h1>
      <p className="muted" style={{ fontSize: 17, maxWidth: 460 }}>{t("auth.sideText")}</p>
      <div className="stack" style={{ maxWidth: 460, marginTop: 12 }}>
        {([["verified", "home.f1t"], ["shield", "home.f2t"], ["qr_code_2", "home.f3t"]] as const).map(([icon, key]) => (
          <div key={key} className="feature" style={{ alignItems: "center" }}>
            <span className="badge-ic"><Icon name={icon} /></span><strong>{t(key)}</strong>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function Login() {
  const { t } = useI18n();
  const { login } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  const [portal, setPortal] = useState<Portal>((params.get("portal") as Portal) || "PASSENGER");
  const [identifier, setIdentifier] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      const res = await login(identifier.trim(), password, portal);
      const next = params.get("next");
      const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : null;
      if ("mfaStep" in res) {
        nav(`/mfa?mode=${res.mfaStep}${safeNext ? `&next=${encodeURIComponent(safeNext)}` : ""}`, { replace: true });
        return;
      }
      nav(safeNext ?? homeFor(res), { replace: true });
    } catch (err) { setError(err); } finally { setBusy(false); }
  };

  return (
    <div className="auth-wrap">
      <AuthSide />
      <div className="auth-form">
        <form className="card hero stack" onSubmit={submit}>
          <div><h2>{t("auth.loginTitle")}</h2><p className="muted">{t("auth.loginSub")}</p></div>
          <div className="field"><span>{t("auth.portalLabel")}</span>
            <div className="segmented" role="tablist">
              {PORTALS.map((p) => (
                <button key={p} type="button" role="tab" aria-selected={portal === p} className={portal === p ? "on" : ""} onClick={() => setPortal(p)}>
                  {t(`auth.portals.${p}`)}
                </button>
              ))}
            </div>
          </div>
          <ErrorBox error={error} />
          <Field label={t("auth.identifier")}>
            <input className="input ltr" autoComplete="username" value={identifier} onChange={(e) => setIdentifier(e.target.value)} required />
          </Field>
          <Field label={t("common.password")}>
            <input className="input ltr" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          </Field>
          <button className="btn large block" disabled={busy}>{t("auth.loginTitle")}</button>
          {portal === "PASSENGER" && <p className="center small">{t("auth.noAccount")} <Link to="/register">{t("nav.register")}</Link></p>}
          {SHOW_DEMO && (
            <div className="alert info small" style={{ flexDirection: "column", gap: 6 }}>
              <strong>{t("common.demoAccounts")}</strong>
              <div className="row" style={{ gap: 6 }}>
                {DEMO[portal].map((email) => (
                  <button key={email} type="button" className="chip chip-select ltr" onClick={() => { setIdentifier(email); setPassword("Masslak-Demo-2026"); }}>{email}</button>
                ))}
              </div>
              <span>{t("auth.demoNote", { p: "Masslak-Demo-2026" })}</span>
            </div>
          )}
        </form>
      </div>
    </div>
  );
}
