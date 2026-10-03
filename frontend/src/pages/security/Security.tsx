import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";

interface Summary { logins_24h: number; failed_24h: number; actions_24h: number; blocked_24h: number; auto_blocks_active: number; last_seal: string | null }
interface Rule { id: number; rule_type: string; cidr: string | null; country_code: string | null; asn: number | null; action: string; scope: string; priority: number; reason: string; source: string; hit_count: number; created_at: string; expires_at: string | null; revoked_at: string | null }
interface AuthEvent { ts: string; event: string; result: string; portal: string | null; ip: string; reason: string | null; user_agent: string; user_email: string | null }
interface Activity { ts: string; action: string; result: string; portal: string | null; ip: string; http_method: string; endpoint: string; http_status: number; latency_ms: number; user_email: string | null }

export function SecurityOverview() {
  const { t, num, dateTime } = useI18n();
  const state = useLoad(() => api.get<Summary>("/api/security/summary"));
  return (
    <div className="stack">
      <PageHead title={t("security.title")} sub={t("security.readOnlyNote")} />
      <Loaded state={state}>{(s) => (
        <div className="grid cols-3">
          <Stat icon="person" label={t("security.logins24")} value={num(s.logins_24h)} />
          <Stat icon="warning" label={t("security.failed24")} value={num(s.failed_24h)} tone="red" />
          <Stat icon="monitoring" label={t("security.actions24")} value={num(s.actions_24h)} tone="blue" />
          <Stat icon="block" label={t("security.blocked24")} value={num(s.blocked_24h)} tone="red" />
          <Stat icon="shield" label={t("security.autoBlocks")} value={num(s.auto_blocks_active)} tone="wheat" />
          <Stat icon="lock" label={t("security.lastSeal")} value={<span style={{ fontSize: 18 }}>{s.last_seal ? dateTime(s.last_seal) : "—"}</span>} />
        </div>
      )}</Loaded>
    </div>
  );
}

export function SecurityRules() {
  const { t, dateTime, num } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ rules: Rule[] }>("/api/security/ip-rules"));
  const [open, setOpen] = useState(false);
  const blank = { target: "", action: "BLOCK", scope: "ALL", priority: "100", reason: "", expires_hours: "" };
  const [f, setF] = useState(blank);
  const [revoke, setRevoke] = useState<Rule | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof blank) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...f, [k]: e.target.value });

  const create = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/security/ip-rules", { ...f, target: f.target.trim(), priority: Number(f.priority), expires_hours: f.expires_hours ? Number(f.expires_hours) : null });
      setOpen(false); setF(blank); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const doRevoke = async () => {
    if (!revoke) return;
    setBusy(true); setError(null);
    try {
      await api.post(`/api/security/ip-rules/${revoke.id}/revoke`, { reason });
      setRevoke(null); setReason(""); toast(t("common.saved")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const target = (r: Rule) => r.cidr ?? r.country_code ?? (r.asn ? `AS${r.asn}` : "—");
  const active = (r: Rule) => !r.revoked_at && (!r.expires_at || new Date(r.expires_at) > new Date());

  return (
    <div className="stack">
      <PageHead title={t("security.rules")}>
        {can("security.ip_rules") && <button className="btn" onClick={() => setOpen(true)}><Icon name="add" />{t("security.newRule")}</button>}
      </PageHead>
      <Loaded state={state}>{({ rules }) => rules.length === 0 ? <div className="card"><Empty icon="shield" title={t("common.noData")} /></div> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("security.target_")}</th><th>{t("security.action")}</th><th>{t("security.scope")}</th><th>{t("common.reason")}</th><th>{t("security.source")}</th><th>{t("security.hits")}</th><th>{t("security.expires")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{rules.map((r) => (
            <tr key={r.id} style={{ opacity: active(r) ? 1 : .55 }}>
              <td className="mono ltr">{target(r)}</td>
              <td><span className={`chip ${r.action === "BLOCK" ? "red" : r.action === "ALLOW" ? "green" : "wheat"}`}>{t(`security.actions.${r.action}`)}</span></td>
              <td className="small">{t(`security.scopes.${r.scope}`)}</td><td className="small">{r.reason}</td>
              <td className="small mono">{r.source}</td><td className="num">{num(r.hit_count)}</td>
              <td className="small">{r.expires_at ? dateTime(r.expires_at) : t("security.never")}</td>
              <td>{r.revoked_at ? <Status value="CANCELLED" /> : active(r) ? <Status value="ACTIVE" /> : <Status value="EXPIRED" />}</td>
              <td>{active(r) && can("security.ip_rules") && <button className="btn text small" onClick={() => setRevoke(r)}>{t("security.revoke")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {open && (
        <Modal title={t("security.newRule")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button><button className="btn" disabled={busy || !f.target || f.reason.length < 3} onClick={create}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("security.target")} hint={t("security.targetHint")}><input className="input ltr mono" value={f.target} onChange={set("target")} /></Field>
            <div className="grid cols-2">
              <Field label={t("security.action")}><select className="input" value={f.action} onChange={set("action")}>{["BLOCK", "ALLOW", "THROTTLE", "CHALLENGE"].map((k) => <option key={k} value={k}>{t(`security.actions.${k}`)}</option>)}</select></Field>
              <Field label={t("security.scope")}><select className="input" value={f.scope} onChange={set("scope")}>{["ALL", "PASSENGER", "OPERATOR", "AGENCY", "ADMIN", "API", "PAYMENT_WEBHOOK", "DRIVER"].map((k) => <option key={k} value={k}>{t(`security.scopes.${k}`)}</option>)}</select></Field>
              <Field label={t("security.priority")}><input className="input ltr" type="number" min={0} max={1000} value={f.priority} onChange={set("priority")} /></Field>
              <Field label={`${t("security.expires")} (${t("common.optional")})`}><input className="input ltr" type="number" min={1} value={f.expires_hours} onChange={set("expires_hours")} /></Field>
            </div>
            <Field label={t("common.reason")}><input className="input" value={f.reason} onChange={set("reason")} /></Field>
          </div>
        </Modal>
      )}
      {revoke && (
        <Modal title={`${t("security.revoke")} · ${target(revoke)}`} onClose={() => setRevoke(null)}
               actions={<><button className="btn text" onClick={() => setRevoke(null)}>{t("common.cancel")}</button><button className="btn" disabled={busy || reason.length < 3} onClick={doRevoke}>{t("common.confirm")}</button></>}>
          <div className="stack"><ErrorBox error={error} /><Field label={t("security.revokeReason")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
        </Modal>
      )}
    </div>
  );
}

export function SecurityAuthLog() {
  const { t, dateTime, has } = useI18n();
  const state = useLoad(() => api.get<{ events: AuthEvent[] }>("/api/security/auth-events"));
  return (
    <div className="stack">
      <PageHead title={t("security.authEvents")}><button className="btn outlined" onClick={state.reload}><Icon name="refresh" />{t("common.refresh")}</button></PageHead>
      <Loaded state={state}>{({ events }) => (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("common.when")}</th><th>{t("security.event")}</th><th>{t("common.result")}</th><th>{t("common.user")}</th><th>{t("common.portal")}</th><th>{t("common.ip")}</th><th>{t("common.reason")}</th></tr></thead>
          <tbody>{events.map((e, i) => (
            <tr key={i}><td className="small">{dateTime(e.ts)}</td><td className="mono small">{e.event}</td><td><Status value={e.result} /></td>
              <td className="ltr small">{e.user_email ?? "—"}</td><td className="small">{e.portal && has(`auth.portals.${e.portal}`) ? t(`auth.portals.${e.portal}`) : e.portal}</td>
              <td className="mono small ltr">{e.ip}</td><td className="small mono">{e.reason}</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}

export function SecurityActivity() {
  const { t, dateTime } = useI18n();
  const state = useLoad(() => api.get<{ activity: Activity[] }>("/api/security/activity"));
  return (
    <div className="stack">
      <PageHead title={t("security.activity")}><button className="btn outlined" onClick={state.reload}><Icon name="refresh" />{t("common.refresh")}</button></PageHead>
      <ErrorBox error={state.error} />
      <Loaded state={state}>{({ activity }) => (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("common.when")}</th><th>{t("common.actions")}</th><th>{t("security.endpoint")}</th><th>{t("common.result")}</th><th>{t("common.user")}</th><th>{t("common.ip")}</th><th className="num">{t("security.latency")}</th></tr></thead>
          <tbody>{activity.map((a, i) => (
            <tr key={i}><td className="small">{dateTime(a.ts)}</td><td className="mono small">{a.action}</td>
              <td className="mono small ltr">{a.http_method} {a.endpoint} · {a.http_status}</td><td><Status value={a.result} /></td>
              <td className="ltr small">{a.user_email ?? "—"}</td><td className="mono small ltr">{a.ip}</td><td className="num small">{a.latency_ms} ms</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}
