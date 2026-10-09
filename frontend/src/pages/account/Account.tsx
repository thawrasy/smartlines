import { useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

interface Security {
  sessions: { id: number; portal: string; ip: string; user_agent: string | null; issued_at: string; last_seen_at: string; current: boolean }[];
  password_changed_at: string | null; mfa: { enrolled: boolean; required: boolean };
  events: { event: string; result: string; portal: string | null; ip: string | null; ts: string }[];
}
interface Consent { purpose: string; granted: boolean; updated_at: string | null }
interface PrivacyRequest { uid: string; kind: string; status: string; due_at: string; created_at: string; handled_at: string | null; reason?: string | null; legal_name?: string; email?: string }

const device = (ua: string | null) => {
  if (!ua) return "—";
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "";
  const br = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : ua.split(" ")[0];
  return [br, os].filter(Boolean).join(" · ");
};

export function AccountPage() {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const toast = useToast();
  const sec = useLoad(() => api.get<Security>("/api/account/security"));
  const cons = useLoad(() => api.get<{ consents: Consent[] }>("/api/account/consents"));
  const reqs = useLoad(() => api.get<{ requests: PrivacyRequest[] }>("/api/account/requests"));
  const [pw, setPw] = useState({ current_password: "", new_password: "", repeat: "" });
  const [erase, setErase] = useState(false);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, done: string, after?: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); toast(done); after?.(); sec.reload(); cons.reload(); reqs.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const download = async () => {
    setError(null);
    try {
      const data = await api.get<unknown>("/api/account/export");
      const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: "application/json" }));
      const a = document.createElement("a");
      a.href = url; a.download = "masslak-my-data.json"; a.click();
      URL.revokeObjectURL(url);
      reqs.reload();
    } catch (e) { setError(e); }
  };
  const openErasure = (reqs.data?.requests ?? []).some((r) => r.kind === "ERASE" && (r.status === "RECEIVED" || r.status === "IN_PROGRESS"));
  return (
    <div className="page stack" style={{ maxWidth: 980 }}>
      <PageHead title={t("account.title")} sub={me?.email ?? undefined} />
      <ErrorBox error={!erase ? error : null} />
      <Loaded state={sec}>{(s) => (
        <>
          <div className="grid cols-2" style={{ alignItems: "start" }}>
            <div className="card stack">
              <div className="row between"><h3>{t("account.twoStep")}</h3>
                {s.mfa.enrolled ? <span className="chip green"><Icon name="verified" size={16} />{t("account.on")}</span> : <span className="chip">{t("account.off")}</span>}</div>
              <p className="small muted">{t(s.mfa.enrolled ? "account.twoStepOn" : "account.twoStepOff")}</p>
              {!s.mfa.enrolled && <Link className="btn tonal" to="/mfa?mode=ENROLL&next=/account"><Icon name="key" />{t("account.enable")}</Link>}
            </div>
            <div className="card stack">
              <h3>{t("account.password")}</h3>
              {s.password_changed_at && <p className="small muted">{t("account.changedAt", { when: dateTime(s.password_changed_at) })}</p>}
              <Field label={t("account.current")}><input className="input ltr" type="password" autoComplete="current-password" value={pw.current_password} onChange={(e) => setPw({ ...pw, current_password: e.target.value })} /></Field>
              <Field label={t("account.new")} hint={t("auth.passwordHint")}><input className="input ltr" type="password" autoComplete="new-password" value={pw.new_password} onChange={(e) => setPw({ ...pw, new_password: e.target.value })} /></Field>
              <Field label={t("account.repeat")}><input className="input ltr" type="password" autoComplete="new-password" value={pw.repeat} onChange={(e) => setPw({ ...pw, repeat: e.target.value })} /></Field>
              <button className="btn" disabled={busy || !pw.current_password || pw.new_password.length < 12 || pw.new_password !== pw.repeat}
                      onClick={() => run(() => api.post("/api/account/password", { current_password: pw.current_password, new_password: pw.new_password }),
                        t("account.passwordChanged"), () => setPw({ current_password: "", new_password: "", repeat: "" }))}>
                {t("account.changePassword")}
              </button>
            </div>
          </div>
          <div className="card">
            <div className="card-title"><h3>{t("account.sessions")}</h3>
              {s.sessions.length > 1 && <button className="btn tonal small" disabled={busy} onClick={() => run(() => api.post("/api/account/sessions/revoke-others"), t("account.signedOut"))}>{t("account.signOutOthers")}</button>}</div>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("account.device")}</th><th>{t("common.portal")}</th><th>{t("common.ip")}</th><th>{t("account.lastSeen")}</th><th /></tr></thead>
              <tbody>{s.sessions.map((x) => (
                <tr key={x.id}><td>{device(x.user_agent)}{x.current && <span className="chip green" style={{ marginInlineStart: 8 }}>{t("account.thisDevice")}</span>}</td>
                  <td>{t(`auth.portals.${x.portal}`)}</td><td className="ltr mono small">{x.ip}</td><td className="small">{dateTime(x.last_seen_at)}</td>
                  <td>{!x.current && <button className="btn text small" disabled={busy} onClick={() => run(() => api.post(`/api/account/sessions/${x.id}/revoke`), t("account.signedOut"))}>{t("account.signOut")}</button>}</td></tr>
              ))}</tbody>
            </table></div>
          </div>
          <div className="card">
            <h3>{t("account.history")}</h3>
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("common.when")}</th><th>{t("common.type")}</th><th>{t("common.ip")}</th><th>{t("common.result")}</th></tr></thead>
              <tbody>{s.events.map((e, i) => (
                <tr key={i}><td className="small">{dateTime(e.ts)}</td><td>{t(`account.events.${e.event}`)}</td><td className="ltr mono small">{e.ip ?? "—"}</td><td><Status value={e.result} /></td></tr>
              ))}</tbody>
            </table></div>
          </div>
        </>
      )}</Loaded>
      <div className="card stack">
        <h3>{t("account.privacy")}</h3>
        <p className="small muted">{t("account.privacySub")}</p>
        <Loaded state={cons}>{({ consents }) => (
          <div className="stack tight">{consents.map((c) => (
            <label key={c.purpose} className="check">
              <input type="checkbox" checked={c.granted} disabled={busy}
                     onChange={(e) => run(() => api.post("/api/account/consents", { purpose: c.purpose, granted: e.target.checked }), t("common.saved"))} />
              <span><strong>{t(`account.consents.${c.purpose}.title`)}</strong><div className="small muted">{t(`account.consents.${c.purpose}.body`)}</div></span>
            </label>
          ))}</div>
        )}</Loaded>
        <div className="row" style={{ gap: 8 }}>
          <button className="btn outlined" onClick={download}><Icon name="download" />{t("account.export")}</button>
          {me?.portal === "PASSENGER" && <button className="btn danger" disabled={openErasure} onClick={() => { setErase(true); setReason(""); setError(null); }}>
            <Icon name="delete" />{t(openErasure ? "account.erasurePending" : "account.erase")}</button>}
        </div>
        <Loaded state={reqs}>{({ requests }) => requests.length === 0 ? null : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.type")}</th><th>{t("common.when")}</th><th>{t("account.due")}</th><th>{t("common.status")}</th></tr></thead>
            <tbody>{requests.map((r) => (
              <tr key={r.uid}><td>{t(`account.kinds.${r.kind}`)}</td><td className="small">{dateTime(r.created_at)}</td><td className="small">{dateTime(r.due_at)}</td><td><Status value={r.status} /></td></tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {erase && (
        <Modal title={t("account.erase")} onClose={() => setErase(false)}
               actions={<><button className="btn text" onClick={() => setErase(false)}>{t("common.cancel")}</button>
                 <button className="btn danger" disabled={busy} onClick={() => run(() => api.post("/api/account/erasure", { reason: reason || null }), t("account.erasureSent"), () => setErase(false))}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="alert warn"><Icon name="warning" /><span>{t("account.eraseNote")}</span></div>
            <Field label={`${t("common.reason")} (${t("common.optional")})`}><textarea className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}

export function AdminPrivacy() {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ requests: PrivacyRequest[] }>("/api/admin/privacy/requests"));
  const [error, setError] = useState<unknown>(null);
  const complete = async (r: PrivacyRequest) => {
    if (!confirm(t("account.completeConfirm", { name: r.legal_name ?? "" }))) return;
    setError(null);
    try { await api.post(`/api/admin/privacy/requests/${r.uid}/complete`); toast(t("common.saved")); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <PageHead title={t("account.privacyRequests")} sub={t("account.privacyRequestsSub")} />
      <ErrorBox error={error} />
      <Loaded state={state}>{({ requests }) => requests.length === 0 ? <div className="card"><Empty icon="privacy_tip" title={t("common.noData")} /></div> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("common.type")}</th><th>{t("common.reason")}</th><th>{t("account.due")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{requests.map((r) => (
            <tr key={r.uid}><td>{r.legal_name}<div className="small muted ltr">{r.email}</div></td><td>{t(`account.kinds.${r.kind}`)}</td>
              <td className="small">{r.reason ?? "—"}</td><td className="small">{dateTime(r.due_at)}</td><td><Status value={r.status} /></td>
              <td>{r.kind === "ERASE" && <button className="btn danger small" onClick={() => complete(r)}>{t("account.anonymise")}</button>}</td></tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}
