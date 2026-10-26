import { useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { useI18n } from "../../i18n";
import { useAuth, homeFor } from "../../auth";
import { ErrorBox, Field, Icon, PasswordInput } from "../../components/ui";

type Door = "individual" | "business";
// Demo accounts are listed only in the test environment build. The demo companies' numbers follow the seeding order.
const DEMO_PEOPLE = ["passenger@masslak.test"];
const DEMO_STAFF: { company: string; label: string; users: string[] }[] = [
  { company: "100101", label: "Demo Carrier A", users: ["owner", "counter", "driver", "driver2"] },
  { company: "100102", label: "Demo Travel Agency", users: ["agency"] },
  { company: "100103", label: "Demo Station Operations", users: ["station", "counter"] },
  { company: "100000", label: "Masslak", users: ["admin", "regulator", "finance", "security"] },
];
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
  const { signIn } = useAuth();
  const nav = useNavigate();
  const [params] = useSearchParams();
  // drivers and roadside officers open their own portal from the business door (?portal=DRIVER|INSPECTOR)
  const portal = (["DRIVER", "INSPECTOR"] as const).find((p) => p === params.get("portal"));
  const [door, setDoor] = useState<Door>(params.get("door") === "business" || (params.get("portal") ?? "PASSENGER") !== "PASSENGER" ? "business" : "individual");
  const [identifier, setIdentifier] = useState("");
  const [companyNo, setCompanyNo] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true); setError(null);
    try {
      const res = await signIn(door === "individual"
        ? { kind: "individual", identifier: identifier.trim(), password }
        : { kind: "business", company_no: companyNo.trim(), username: username.trim().toLowerCase(), password, ...(portal ? { portal } : {}) });
      const next = params.get("next");
      const safeNext = next && next.startsWith("/") && !next.startsWith("//") ? next : null;
      const tail = safeNext ? `next=${encodeURIComponent(safeNext)}` : "";
      if ("passwordStep" in res) {
        nav(`/first-password?${res.mfaStep ? `mode=${res.mfaStep}&` : ""}${tail}`, { replace: true });
        return;
      }
      if ("mfaStep" in res) {
        nav(`/mfa?mode=${res.mfaStep}${tail ? `&${tail}` : ""}`, { replace: true });
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
          <div><h2>{t("auth.loginTitle")}</h2><p className="muted">{t(door === "individual" ? "auth.individualSub" : "auth.businessSub")}</p></div>
          <div className="segmented" role="tablist" aria-label={t("auth.loginTitle")}>
            {(["individual", "business"] as const).map((d) => (
              <button key={d} type="button" role="tab" aria-selected={door === d} className={door === d ? "on" : ""}
                      onClick={() => { setDoor(d); setError(null); }}>
                <Icon name={d === "individual" ? "person" : "apartment"} size={18} />{t(`auth.door.${d}`)}
              </button>
            ))}
          </div>
          {params.get("idle") === "1" && !error && <div className="alert info" role="status">{t("idle.signedOut")}</div>}
          <ErrorBox error={error} />
          {door === "individual" ? (
            <Field label={t("auth.identifier")}>
              <input className="input ltr" autoComplete="username" value={identifier} onChange={(e) => setIdentifier(e.target.value)} required />
            </Field>
          ) : (
            <div className="grid cols-2">
              <Field label={t("auth.companyNo")} hint={t("auth.companyNoHint")}>
                <input className="input ltr" inputMode="numeric" autoComplete="organization" maxLength={8} value={companyNo}
                       onChange={(e) => setCompanyNo(e.target.value.replace(/\D/g, ""))} required pattern="[0-9]{6,8}" />
              </Field>
              <Field label={t("auth.username")}>
                <input className="input ltr" autoComplete="username" autoCapitalize="none" spellCheck={false} maxLength={32} value={username}
                       onChange={(e) => setUsername(e.target.value)} required />
              </Field>
            </div>
          )}
          <Field label={t("common.password")}>
            <PasswordInput autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
          </Field>
          <button className="btn large block" disabled={busy}>{t("auth.loginTitle")}</button>
          {door === "individual"
            ? <>
                <p className="center small">{t("auth.noAccount")} <Link to="/register">{t("nav.register")}</Link></p>
                <p className="center small"><Link to={`/guest${params.get("next") ? `?next=${encodeURIComponent(params.get("next")!)}` : ""}`}>{t("guest.link")}</Link></p>
              </>
            : <p className="center small muted">{t("auth.businessHelp")}</p>}
          {SHOW_DEMO && (
            <div className="alert info small" style={{ flexDirection: "column", gap: 6 }}>
              <strong>{t("common.demoAccounts")}</strong>
              {door === "individual" ? (
                <div className="row" style={{ gap: 6 }}>
                  {DEMO_PEOPLE.map((email) => (
                    <button key={email} type="button" className="chip chip-select ltr" onClick={() => { setIdentifier(email); setPassword("Masslak-Demo-2026"); }}>{email}</button>
                  ))}
                </div>
              ) : DEMO_STAFF.map((c) => (
                <div key={c.company} className="row" style={{ gap: 6, alignItems: "center" }}>
                  <span className="ltr">{c.company}</span><span className="muted">{c.label}</span>
                  {c.users.map((u) => (
                    <button key={u} type="button" className="chip chip-select ltr"
                            onClick={() => { setCompanyNo(c.company); setUsername(u); setPassword("Masslak-Demo-2026"); }}>{u}</button>
                  ))}
                </div>
              ))}
              <span>{t("auth.demoNote", { p: "Masslak-Demo-2026" })}</span>
            </div>
          )}
        </form>
      </div>
    </div>
  );
}
