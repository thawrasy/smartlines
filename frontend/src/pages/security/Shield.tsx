import { useEffect, useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// The platform shield (owner's request, October 2026; migration 1142). The security staff watch the traffic, raise or
// lower the shield level, acknowledge the alerts and set the firewall and one-session rules. Read only until the
// account carries the security.console permission (the route and this page are hidden otherwise).
const PORTALS = ["PASSENGER", "PLATFORM", "OPERATOR", "AGENCY", "STATION", "DRIVER", "INSPECTOR"] as const;
type Portal = (typeof PORTALS)[number];
type Level = "NORMAL" | "ELEVATED" | "LOCKDOWN";

interface Policy {
  waf_mode: "OFF" | "DETECT" | "BLOCK"; waf_strikes: number; waf_window_min: number; waf_block_min: number;
  alert_rpm: number; alert_ip_rpm: number; spike_factor: number; spike_min_rpm: number; alert_error_pct: number;
  alert_waf_per_min: number; alert_auth_fail_per_min: number; auto_block_heavy: boolean; auto_elevate: boolean;
  auto_elevate_min: number; elevated_rate_factor: number; lockdown_allow_signed_in: boolean;
}
interface State { level: Level; until: string | null; auto: boolean; reason: string | null; set_at: string | null; set_by: string | null; policy: Policy; session_policy: Record<Portal, "SINGLE" | "MULTI"> }
interface Minute { minute: string; requests: number; err_4xx: number; err_5xx: number; blocked: number; limited: number; waf: number; auth_failures: number }
interface Alert { id: number; alert_key: string; kind: string; severity: string; status: string; opened_at: string; last_seen_at: string; metrics: Record<string, unknown>; ack_at: string | null; resolved_at: string | null; note: string | null }
interface Hit { at: string; ip: string; method: string; path: string; rule: string; location: string; sample: string | null; action: string }
interface Top { ip: string; requests: number; blocked: boolean }
interface Event { at: string; level: Level; previous: Level | null; reason: string | null; auto: boolean; until: string | null; set_by: string | null }
interface View { state: State; minutes: Minute[]; alerts: Alert[]; waf_hits: Hit[]; top_addresses: Top[]; events: Event[] }

const LEVEL_TONE: Record<Level, string> = { NORMAL: "green", ELEVATED: "wheat", LOCKDOWN: "red" };

export default function Shield() {
  const { t, num, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<View>("/api/security/shield"));
  // the watch refreshes on its own every 20 seconds, so an abnormal load shows without anyone pressing a button
  useEffect(() => { const id = setInterval(() => state.reload(), 20_000); return () => clearInterval(id); }, [state]);

  const [levelForm, setLevelForm] = useState<Level | null>(null);
  const [policyOpen, setPolicyOpen] = useState(false);

  const act = async (fn: () => Promise<unknown>, done: string) => {
    try { await fn(); toast(done); state.reload(); } catch (e) { throw e; }
  };

  return (
    <div className="stack">
      <PageHead title={t("shield.title")} sub={t("shield.sub")}>
        <button className="btn outlined" onClick={state.reload}><Icon name="refresh" />{t("common.refresh")}</button>
      </PageHead>
      <Loaded state={state}>{(v) => (
        <div className="stack">
          <LevelCard s={v.state} onChange={setLevelForm} onPolicy={() => setPolicyOpen(true)} />
          <TrafficCard minutes={v.minutes} />
          <div className="grid cols-2">
            <AlertsCard alerts={v.alerts} onStep={(id, step, note) => act(() => api.post(`/api/security/shield/alerts/${id}/${step}`, { note }), t("common.saved"))} />
            <TopCard top={v.top_addresses} />
          </div>
          <HitsCard hits={v.waf_hits} />
          <EventsCard events={v.events} />
        </div>
      )}</Loaded>

      {levelForm && state.data && (
        <LevelModal level={levelForm} onClose={() => setLevelForm(null)}
          onSave={async (body) => { await act(() => api.put("/api/security/shield/level", body), t("shield.levelSet")); setLevelForm(null); }} />
      )}
      {policyOpen && state.data && (
        <PolicyModal policy={state.data.state.policy} sessions={state.data.state.session_policy} onClose={() => setPolicyOpen(false)}
          onSave={async (body) => { await act(() => api.put("/api/security/shield/policy", body), t("common.saved")); setPolicyOpen(false); }} />
      )}
    </div>
  );

  function LevelCard({ s, onChange, onPolicy }: { s: State; onChange: (l: Level) => void; onPolicy: () => void }) {
    return (
      <div className="card stack">
        <div className="row between wrap" style={{ gap: 12 }}>
          <div className="row" style={{ gap: 12, alignItems: "center" }}>
            <Icon name="shield" size={28} />
            <div>
              <div className="row" style={{ gap: 8, alignItems: "center" }}>
                <span className={`chip ${LEVEL_TONE[s.level]}`} style={{ fontWeight: 700 }}>{t(`shield.levels.${s.level}`)}</span>
                {s.auto && <span className="chip outline small">{t("shield.auto")}</span>}
              </div>
              <p className="small muted" style={{ margin: "6px 0 0" }}>{t(`shield.levelHint.${s.level}`)}</p>
            </div>
          </div>
          <div className="row" style={{ gap: 8 }}>
            {(["NORMAL", "ELEVATED", "LOCKDOWN"] as Level[]).map((l) => (
              <button key={l} className={`btn ${l === s.level ? "" : "outlined"} ${l === "LOCKDOWN" ? "danger" : ""}`} disabled={l === s.level} onClick={() => onChange(l)}>
                {t(`shield.levels.${l}`)}
              </button>
            ))}
          </div>
        </div>
        <div className="small muted">
          {s.reason && <span>{t("common.reason")}: {s.reason} · </span>}
          {s.set_by && <span>{t("shield.setBy")}: {s.set_by} · </span>}
          {s.set_at && <span>{dateTime(s.set_at)}</span>}
          {s.until && <span> · {t("shield.until")}: {dateTime(s.until)}</span>}
        </div>
        <div className="row between wrap" style={{ gap: 8 }}>
          <span className="small">{t("shield.waf")}: <b>{t(`shield.wafModes.${s.policy.waf_mode}`)}</b> · {t("shield.oneSession")}: <b>{num(Object.values(s.session_policy).filter((x) => x === "SINGLE").length)}/{PORTALS.length}</b></span>
          <button className="btn text" onClick={onPolicy}><Icon name="tune" />{t("shield.editPolicy")}</button>
        </div>
      </div>
    );
  }

  function TrafficCard({ minutes }: { minutes: Minute[] }) {
    const maxReq = Math.max(1, ...minutes.map((m) => m.requests));
    const abnormal = (m: Minute) => m.blocked + m.limited + m.waf;
    return (
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("shield.traffic")}</h3>
        {minutes.length === 0 ? <Empty icon="monitoring" title={t("shield.noTraffic")} /> : (
          <>
            <div className="usage-bars" role="img" aria-label={t("shield.traffic")} style={{ height: 140 }}>
              {minutes.map((m) => (
                <div key={m.minute} className="usage-bar" title={`${dateTime(m.minute)}: ${m.requests} · ${t("shield.abnormal")} ${abnormal(m)}`}>
                  <span style={{ height: `${(m.requests / maxReq) * 100}%` }} />
                  {abnormal(m) > 0 && <i style={{ height: `${(abnormal(m) / maxReq) * 100}%` }} />}
                </div>
              ))}
            </div>
            <p className="small muted" style={{ margin: 0 }}>{t("shield.trafficHint")}</p>
          </>
        )}
      </div>
    );
  }

  function AlertsCard({ alerts, onStep }: { alerts: Alert[]; onStep: (id: number, step: "acknowledge" | "resolve", note?: string) => Promise<void> }) {
    const live = alerts.filter((a) => a.status !== "RESOLVED");
    return (
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("shield.alerts")} {live.length > 0 && <span className="chip red small">{num(live.length)}</span>}</h3>
        {alerts.length === 0 ? <Empty icon="check_circle" title={t("shield.noAlerts")} /> : (
          <div className="stack" style={{ gap: 10 }}>
            {alerts.map((a) => (
              <div key={a.id} className="row between wrap" style={{ gap: 8, opacity: a.status === "RESOLVED" ? .55 : 1, borderTop: "1px solid var(--outline-variant)", paddingTop: 8 }}>
                <div>
                  <div className="row" style={{ gap: 6, alignItems: "center" }}>
                    <span className={`chip small ${a.severity === "CRITICAL" ? "red" : "wheat"}`}>{t(`shield.sev.${a.severity}`)}</span>
                    <b className="small">{t(`shield.kind.${a.kind}`)}</b>
                  </div>
                  <div className="small muted">{Object.entries(a.metrics).map(([k, val]) => `${k.replace(/_/g, " ")}: ${val}`).join(" · ")}</div>
                  <div className="small muted">{dateTime(a.opened_at)}{a.note ? ` · ${a.note}` : ""}</div>
                </div>
                <div className="row" style={{ gap: 6 }}>
                  {a.status === "OPEN" && <button className="btn text small" onClick={() => onStep(a.id, "acknowledge")}>{t("shield.acknowledge")}</button>}
                  {a.status !== "RESOLVED" ? <button className="btn text small" onClick={() => onStep(a.id, "resolve")}>{t("shield.resolve")}</button> : <Status value="RESOLVED" />}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    );
  }

  function TopCard({ top }: { top: Top[] }) {
    return (
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("shield.topAddresses")}</h3>
        {top.length === 0 ? <Empty icon="public" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.ip")}</th><th className="num">{t("shield.requests10")}</th><th>{t("common.status")}</th></tr></thead>
            <tbody>{top.map((a) => (
              <tr key={a.ip}><td className="mono small ltr">{a.ip}</td><td className="num">{num(a.requests)}</td>
                <td>{a.blocked ? <span className="chip red small">{t("security.actions.BLOCK")}</span> : <span className="chip small">{t("shield.allowed")}</span>}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </div>
    );
  }

  function HitsCard({ hits }: { hits: Hit[] }) {
    return (
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("shield.wafHits")}</h3>
        {hits.length === 0 ? <Empty icon="shield" title={t("shield.noHits")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("common.ip")}</th><th>{t("security.endpoint")}</th><th>{t("shield.rule")}</th><th>{t("shield.where")}</th><th>{t("security.action")}</th></tr></thead>
            <tbody>{hits.map((h, i) => (
              <tr key={i}><td className="small">{dateTime(h.at)}</td><td className="mono small ltr">{h.ip}</td>
                <td className="mono small ltr">{h.method} {h.path}</td><td><span className="chip small wheat">{t(`shield.rules.${h.rule}`)}</span></td>
                <td className="small">{t(`shield.loc.${h.location}`)}</td>
                <td className="small">{t(`shield.hitAction.${h.action}`)}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </div>
    );
  }

  function EventsCard({ events }: { events: Event[] }) {
    if (events.length === 0) return null;
    return (
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("shield.history")}</h3>
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.when")}</th><th>{t("shield.level")}</th><th>{t("common.reason")}</th><th>{t("shield.setBy")}</th></tr></thead>
          <tbody>{events.map((e, i) => (
            <tr key={i}><td className="small">{dateTime(e.at)}</td>
              <td><span className={`chip small ${LEVEL_TONE[e.level]}`}>{t(`shield.levels.${e.level}`)}</span>{e.auto && <span className="chip outline small" style={{ marginInlineStart: 6 }}>{t("shield.auto")}</span>}</td>
              <td className="small">{e.reason}</td><td className="small">{e.set_by ?? (e.auto ? t("shield.theShield") : "—")}</td></tr>
          ))}</tbody>
        </table></div>
      </div>
    );
  }
}

function LevelModal({ level, onClose, onSave }: { level: Level; onClose: () => void; onSave: (body: { level: Level; reason: string; minutes: number | null }) => Promise<void> }) {
  const { t } = useI18n();
  const [reason, setReason] = useState("");
  const [minutes, setMinutes] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const raised = level !== "NORMAL";
  const save = async () => {
    setBusy(true); setError(null);
    try { await onSave({ level, reason: reason.trim(), minutes: raised && minutes ? Number(minutes) : null }); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={`${t("shield.setLevel")} · ${t(`shield.levels.${level}`)}`} onClose={onClose}
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
        <button className={`btn ${level === "LOCKDOWN" ? "danger" : ""}`} disabled={busy || reason.trim().length < 3} onClick={save}>{t("common.confirm")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        {level === "LOCKDOWN" && <div className="alert warn"><Icon name="warning" /> <span>{t("shield.lockdownWarn")}</span></div>}
        <Field label={t("common.reason")} hint={t("shield.reasonHint")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        {raised && <Field label={t("shield.autoEndAfter")} optional hint={t("shield.autoEndHint")}>
          <input className="input ltr" type="number" min={5} max={10080} value={minutes} onChange={(e) => setMinutes(e.target.value)} /></Field>}
      </div>
    </Modal>
  );
}

function PolicyModal({ policy, sessions, onClose, onSave }: {
  policy: Policy; sessions: Record<Portal, "SINGLE" | "MULTI">;
  onClose: () => void; onSave: (body: Policy & { session_policy: Record<string, "SINGLE" | "MULTI"> }) => Promise<void>;
}) {
  const { t } = useI18n();
  const [p, setP] = useState<Policy>(policy);
  const [s, setS] = useState(sessions);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const n = (k: keyof Policy) => (e: React.ChangeEvent<HTMLInputElement>) => setP({ ...p, [k]: Number(e.target.value) });
  const b = (k: keyof Policy) => (e: React.ChangeEvent<HTMLInputElement>) => setP({ ...p, [k]: e.target.checked });
  const save = async () => {
    setBusy(true); setError(null);
    try { await onSave({ ...p, session_policy: s }); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const Num = ({ k, min, max, step }: { k: keyof Policy; min: number; max: number; step?: number }) => (
    <Field label={t(`shield.policy.${k}`)}><input className="input ltr" type="number" min={min} max={max} step={step} value={String(p[k])} onChange={n(k)} /></Field>
  );
  return (
    <Modal title={t("shield.editPolicy")} onClose={onClose} wide
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" disabled={busy} onClick={save}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <h4 style={{ margin: 0 }}>{t("shield.firewall")}</h4>
        <Field label={t("shield.policy.waf_mode")} hint={t("shield.wafModeHint")}>
          <select className="input" value={p.waf_mode} onChange={(e) => setP({ ...p, waf_mode: e.target.value as Policy["waf_mode"] })}>
            {(["OFF", "DETECT", "BLOCK"] as const).map((m) => <option key={m} value={m}>{t(`shield.wafModes.${m}`)}</option>)}
          </select>
        </Field>
        <div className="grid cols-3">
          <Num k="waf_strikes" min={1} max={100} /><Num k="waf_window_min" min={1} max={1440} /><Num k="waf_block_min" min={1} max={43200} />
        </div>
        <h4 style={{ margin: 0 }}>{t("shield.thresholds")}</h4>
        <div className="grid cols-3">
          <Num k="alert_rpm" min={100} max={10000000} /><Num k="alert_ip_rpm" min={30} max={1000000} />
          <Num k="spike_factor" min={1.5} max={100} step={0.1} /><Num k="spike_min_rpm" min={10} max={10000000} />
          <Num k="alert_error_pct" min={1} max={100} step={0.5} /><Num k="alert_waf_per_min" min={1} max={1000000} />
          <Num k="alert_auth_fail_per_min" min={1} max={1000000} />
        </div>
        <h4 style={{ margin: 0 }}>{t("shield.autoActions")}</h4>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={p.auto_block_heavy} onChange={b("auto_block_heavy")} /><span className="small">{t("shield.policy.auto_block_heavy")}</span></label>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={p.auto_elevate} onChange={b("auto_elevate")} /><span className="small">{t("shield.policy.auto_elevate")}</span></label>
        <div className="grid cols-2">
          <Num k="auto_elevate_min" min={5} max={1440} /><Num k="elevated_rate_factor" min={0.1} max={1} step={0.1} />
        </div>
        <label className="row" style={{ gap: 8 }}><input type="checkbox" checked={p.lockdown_allow_signed_in} onChange={b("lockdown_allow_signed_in")} /><span className="small">{t("shield.policy.lockdown_allow_signed_in")}</span></label>
        <h4 style={{ margin: 0 }}>{t("shield.oneSessionTitle")}</h4>
        <p className="small muted" style={{ margin: 0 }}>{t("shield.oneSessionHint")}</p>
        <div className="grid cols-2">
          {PORTALS.map((portal) => (
            <label key={portal} className="row between" style={{ gap: 8, border: "1px solid var(--outline-variant)", borderRadius: 10, padding: "8px 12px" }}>
              <span className="small">{t(`security.mfa.portal.${portal}`)}</span>
              <select className="input" style={{ maxWidth: 140 }} value={s[portal]} onChange={(e) => setS({ ...s, [portal]: e.target.value as "SINGLE" | "MULTI" })}>
                <option value="SINGLE">{t("shield.session.SINGLE")}</option><option value="MULTI">{t("shield.session.MULTI")}</option>
              </select>
            </label>
          ))}
        </div>
      </div>
    </Modal>
  );
}
