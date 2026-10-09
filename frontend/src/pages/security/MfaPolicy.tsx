import { useEffect, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { ErrorBox, Field, Icon, Loaded, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";

type Method = "TOTP" | "SMS" | "WHATSAPP";
type Portal = "PLATFORM" | "INSPECTOR" | "OPERATOR" | "DRIVER" | "AGENCY" | "PASSENGER";
interface Policy { methods: Method[]; required_portals: Portal[]; enforce_in_sandbox: boolean; code_minutes: number; resend_seconds: number; sends_per_hour: number }
interface View {
  policy: Policy; available: Method[]; delivery: Record<Method, boolean>; always_required: Portal[]; sandbox: boolean;
  enrolled: Partial<Record<Method, number>>; staff_without_factor: Partial<Record<Portal, number>>;
}

const METHODS: Method[] = ["TOTP", "SMS", "WHATSAPP"];
const PORTALS: Portal[] = ["PLATFORM", "INSPECTOR", "OPERATOR", "DRIVER", "AGENCY", "PASSENGER"];
const ICON: Record<Method, IconName> = { TOTP: "password", SMS: "sms", WHATSAPP: "chat" };

/** The platform's two-factor sign-in policy (owner's decision 2): methods open, portals that must use one. */
export default function MfaPolicy() {
  const { t, num } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<View>("/api/security/mfa-policy"));
  const [p, setP] = useState<Policy | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  useEffect(() => { if (state.data) setP(state.data.policy); }, [state.data]);

  const toggle = <T extends string>(list: T[], v: T) => (list.includes(v) ? list.filter((x) => x !== v) : [...list, v]);
  const save = async () => {
    if (!p) return;
    setBusy(true); setError(null);
    try { await api.put("/api/security/mfa-policy", p); toast(t("security.mfa.saved")); state.reload(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className="stack">
      <PageHead title={t("security.mfa.title")} sub={t("security.mfa.sub")} />
      <Loaded state={state}>{(v) => p && (
        <>
          <div className="grid cols-2">
            <section className="card stack" aria-labelledby="mfa-methods">
              <h3 id="mfa-methods">{t("security.mfa.methods")}</h3>
              {METHODS.map((m) => (
                <label key={m} className="check-row">
                  <input type="checkbox" checked={p.methods.includes(m)} onChange={() => setP({ ...p, methods: toggle(p.methods, m) })} />
                  <Icon name={ICON[m]} size={18} />
                  <span className="grow" style={{ display: "flex", flexDirection: "column" }}>
                    {t(`security.mfa.method.${m}`)}
                    <span className="small" style={{ color: v.delivery[m] ? "var(--on-surface-variant)" : "var(--error)" }}>
                      {m === "TOTP" ? t("security.mfa.enrolled", { n: num(v.enrolled.TOTP ?? 0) })
                        : `${t("security.mfa.delivery")}: ${t(v.delivery[m] ? "security.mfa.deliveryOn" : "security.mfa.deliveryOff")} · ${t("security.mfa.enrolled", { n: num(v.enrolled[m] ?? 0) })}`}
                    </span>
                  </span>
                </label>
              ))}
              {p.methods.length === 0 && <p className="small" style={{ color: "var(--error)" }}>{t("security.mfa.oneMethod")}</p>}
            </section>
            <section className="card stack" aria-labelledby="mfa-portals">
              <h3 id="mfa-portals">{t("security.mfa.portals")}</h3>
              {PORTALS.map((portal) => {
                const locked = v.always_required.includes(portal) && !v.sandbox;
                return (
                  <label key={portal} className="check-row">
                    <input type="checkbox" checked={locked || p.required_portals.includes(portal)} disabled={locked}
                           onChange={() => setP({ ...p, required_portals: toggle(p.required_portals, portal) })} />
                    <span className="grow" style={{ display: "flex", flexDirection: "column" }}>{t(`security.mfa.portal.${portal}`)}
                      {v.always_required.includes(portal) && <span className="small muted" style={{ display: "block" }}>{t("security.mfa.always")}</span>}
                    </span>
                  </label>
                );
              })}
              {v.sandbox && (
                <label className="check-row"><input type="checkbox" checked={p.enforce_in_sandbox}
                       onChange={(e) => setP({ ...p, enforce_in_sandbox: e.target.checked })} />{t("security.mfa.sandbox")}</label>
              )}
            </section>
          </div>
          <section className="card stack">
            <div className="grid cols-3">
              <Field label={t("security.mfa.codeMinutes")}>
                <input className="input" type="number" min={2} max={10} value={p.code_minutes} onChange={(e) => setP({ ...p, code_minutes: Number(e.target.value) })} />
              </Field>
              <Field label={t("security.mfa.resendSeconds")}>
                <input className="input" type="number" min={30} max={300} value={p.resend_seconds} onChange={(e) => setP({ ...p, resend_seconds: Number(e.target.value) })} />
              </Field>
              <Field label={t("security.mfa.sendsPerHour")}>
                <input className="input" type="number" min={3} max={20} value={p.sends_per_hour} onChange={(e) => setP({ ...p, sends_per_hour: Number(e.target.value) })} />
              </Field>
            </div>
            <ErrorBox error={error} />
            <div className="row"><button className="btn" onClick={() => void save()} disabled={busy || p.methods.length === 0}><Icon name="save" />{t("common.save")}</button></div>
          </section>
          <section className="card stack" aria-labelledby="mfa-without">
            <h3 id="mfa-without">{t("security.mfa.without")}</h3>
            {Object.keys(v.staff_without_factor).length === 0 ? <p className="muted">{t("security.mfa.withoutNone")}</p> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <tbody>{(Object.entries(v.staff_without_factor) as [Portal, number][]).map(([portal, n]) => (
                  <tr key={portal}><td>{t(`security.mfa.portal.${portal}`)}</td><td className="num">{num(n)}</td></tr>
                ))}</tbody>
              </table></div>
            )}
          </section>
        </>
      )}</Loaded>
    </div>
  );
}
