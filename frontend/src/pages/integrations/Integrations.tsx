import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";

// ---------------------------------------------------------------- types
interface Client {
  uid: string; name: string; kind: string; environment: string; status: string; scopes: string[]; rate_limit_per_min: number;
  ip_allowlist: string[]; require_mtls: boolean; description: string | null; contact_email: string | null; status_reason: string | null;
  company: string | null; acting_user: string | null; provider: string | null; authority: string | null; created_at: string;
  created_by: string | null; approved_by: string | null; active_keys: number | null; requests_today: number | null;
}
interface Key { id: number; key_prefix: string; status: string; expires_at: string; last_used_at: string | null; last_used_ip: string | null; created_at: string; created_by: string | null; revoke_reason: string | null }
interface Hook { uid: string; url: string; events: string[]; include_pii: boolean; status: string; last_success_at: string | null; pending: number; dead: number }
interface Delivery { delivery_uid: string; event_type: string; status: string; attempts: number; http_status: number | null; last_error: string | null; created_at: string; url: string }
interface Detail { client: Client; keys: Key[]; webhooks: Hook[]; usage: { day: string; requests: number; errors: number }[]; deliveries: Delivery[]; events: string[]; allowed_scopes: string[] }
interface Meta {
  scopes: Record<string, string>; kinds: Record<string, string[]>; events: Record<string, string[]>; platform: boolean;
  companies?: { uid: string; name: string; company_type: string }[]; providers?: { code: string; name: string }[];
  authorities?: { code: string; name: string; authority_type: string }[];
}

const KIND_ICON: Record<string, IconName> = {
  CARRIER: "directions_bus", CHANNEL: "storefront", PARTNER: "account_balance", AUTHORITY: "shield", INTEGRATION: "hub", INTERNAL: "api",
};

function copy(text: string, done: () => void) {
  navigator.clipboard?.writeText(text).then(done, () => undefined);
}

/** API clients: keys, scopes, allowed addresses and webhooks. Platform security sees and approves all; a company owner manages its own. */
export function IntegrationsPage() {
  const { t } = useI18n();
  const meta = useLoad(() => api.get<Meta>("/api/integrations/meta"));
  const list = useLoad(() => api.get<{ clients: Client[] }>("/api/integrations/clients"));
  const [open, setOpen] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  if (open) return <ClientView uid={open} meta={meta.data} onBack={() => { setOpen(null); list.reload(); }} />;
  return (
    <div className="stack">
      <PageHead title={t("api.title")} sub={t("api.sub")}>
        <button className="btn" onClick={() => setCreating(true)} disabled={!meta.data}><Icon name="add" />{t("api.new")}</button>
      </PageHead>
      <DocsCard />
      <div className="card stack">
        <Loaded state={list}>{(d) => d.clients.length === 0 ? (
          <Empty icon="api" title={t("api.none")} hint={t("api.noneHint")} />
        ) : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("api.client")}</th><th>{t("api.kind")}</th><th>{t("api.scopesCol")}</th><th>{t("api.keysCol")}</th><th>{t("api.today")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{d.clients.map((c) => (
              <tr key={c.uid} className="clickable" onClick={() => setOpen(c.uid)}>
                <td><strong>{c.name}</strong><div className="small muted">{c.company ?? c.authority ?? c.provider ?? ""}</div></td>
                <td><span className="row" style={{ gap: 6 }}><Icon name={KIND_ICON[c.kind] ?? "api"} />{t(`api.kinds.${c.kind}`)}</span>
                  <div className="small muted">{t(`api.env.${c.environment}`)}</div></td>
                <td className="small">{c.scopes.length}</td>
                <td className="small">{c.active_keys ?? 0}</td>
                <td className="small">{c.requests_today ?? 0}</td>
                <td><Status value={c.status} /></td>
                <td className="num"><Icon name="arrow_back" flip /></td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {creating && meta.data && <CreateModal meta={meta.data} onClose={() => setCreating(false)}
                                             onDone={(uid) => { setCreating(false); list.reload(); setOpen(uid); }} />}
    </div>
  );
}

function DocsCard() {
  const { t } = useI18n();
  const base = `${window.location.origin}/api/v1`;
  return (
    <div className="card stack" style={{ gap: 8 }}>
      <div className="row" style={{ gap: 8 }}><Icon name="code" /><strong>{t("api.docsTitle")}</strong></div>
      <p className="small muted" style={{ margin: 0 }}>{t("api.docsHint")}</p>
      <pre className="code-block ltr">{`curl -H "X-Api-Key: msk_test_…" ${base}/me`}</pre>
      <div className="row" style={{ gap: 12 }}>
        <a className="btn text small" href="/api/v1/openapi.json" target="_blank" rel="noreferrer"><Icon name="description" />{t("api.openapi")}</a>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- create
function CreateModal({ meta, onClose, onDone }: { meta: Meta; onClose: () => void; onDone: (uid: string) => void }) {
  const { t } = useI18n();
  const { me } = useAuth();
  const kinds = meta.platform ? Object.keys(meta.kinds) : [me?.portal === "AGENCY" ? "CHANNEL" : "CARRIER", "INTEGRATION"];
  const [f, setF] = useState({ name: "", kind: kinds[0], scopes: [] as string[], environment: "SANDBOX", description: "", contact_email: "",
    ips: "", company_uid: "", acting_email: "", provider_code: "PARTNER_API", authority_code: "", rate: 600 });
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const allowed = meta.kinds[f.kind] ?? [];
  const set = (k: string, v: unknown) => setF((x) => ({ ...x, [k]: v }));
  const toggle = (s: string) => set("scopes", f.scopes.includes(s) ? f.scopes.filter((x) => x !== s) : [...f.scopes, s]);
  const save = async () => {
    setBusy(true); setError(null);
    try {
      const body: Record<string, unknown> = { name: f.name, kind: f.kind, scopes: f.scopes, environment: f.environment,
        description: f.description || null, contact_email: f.contact_email || null,
        ip_allowlist: f.ips.split(/[\s,]+/).filter(Boolean) };
      if (meta.platform) {
        Object.assign(body, { company_uid: f.company_uid || null, acting_email: f.acting_email || null, rate_limit_per_min: f.rate,
          provider_code: f.kind === "PARTNER" ? f.provider_code : null, authority_code: f.kind === "AUTHORITY" ? f.authority_code || null : null });
      }
      const r = await api.post<Client>("/api/integrations/clients", body);
      onDone(r.uid);
    } catch (e) { setError(e); setBusy(false); }
  };
  return (
    <Modal wide title={t("api.new")} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={busy || f.name.length < 3 || f.scopes.length === 0} onClick={save}>{t("api.create")}</button></>}>
      <div className="stack">
        <p className="small muted" style={{ margin: 0 }}>{t(meta.platform ? "api.createHintPlatform" : "api.createHint")}</p>
        <div className="grid cols-2">
          <Field label={t("api.name")}><input className="input" value={f.name} onChange={(e) => set("name", e.target.value)} /></Field>
          <Field label={t("api.kind")}>
            <select className="input" value={f.kind} onChange={(e) => setF((x) => ({ ...x, kind: e.target.value, scopes: [] }))}>
              {kinds.map((k) => <option key={k} value={k}>{t(`api.kinds.${k}`)}</option>)}
            </select>
          </Field>
        </div>
        <Field label={t("api.scopesCol")}>
          <div className="stack" style={{ gap: 6 }}>{allowed.map((s) => (
            <label key={s} className="check-row"><input type="checkbox" checked={f.scopes.includes(s)} onChange={() => toggle(s)} />
              <span><span className="mono ltr">{s}</span> <span className="small muted">{t(`api.scope.${s.replace(":", "_")}`)}</span></span></label>
          ))}</div>
        </Field>
        <div className="grid cols-2">
          <Field label={t("api.environment")}>
            <select className="input" value={f.environment} onChange={(e) => set("environment", e.target.value)}>
              {["SANDBOX", "PRODUCTION"].map((e) => <option key={e} value={e}>{t(`api.env.${e}`)}</option>)}
            </select>
          </Field>
          <Field label={t("api.contact")}><input className="input ltr" type="email" value={f.contact_email} onChange={(e) => set("contact_email", e.target.value)} /></Field>
        </div>
        <Field label={t("api.ips")} hint={t("api.ipsHint")}><input className="input ltr" placeholder="203.0.113.0/24" value={f.ips} onChange={(e) => set("ips", e.target.value)} /></Field>
        <Field label={t("api.description")}><input className="input" value={f.description} onChange={(e) => set("description", e.target.value)} /></Field>
        {meta.platform && (
          <div className="grid cols-2">
            {["CARRIER", "CHANNEL", "INTEGRATION"].includes(f.kind) && (
              <Field label={t("api.company")}>
                <select className="input" value={f.company_uid} onChange={(e) => set("company_uid", e.target.value)}>
                  <option value="">—</option>
                  {(meta.companies ?? []).map((c) => <option key={c.uid} value={c.uid}>{c.name}</option>)}
                </select>
              </Field>
            )}
            {f.kind === "PARTNER" && (
              <Field label={t("api.provider")}>
                <select className="input" value={f.provider_code} onChange={(e) => set("provider_code", e.target.value)}>
                  {(meta.providers ?? []).map((p) => <option key={p.code} value={p.code}>{t(`pay.provider.${p.code}`) === `pay.provider.${p.code}` ? p.name : t(`pay.provider.${p.code}`)}</option>)}
                </select>
              </Field>
            )}
            {f.kind === "AUTHORITY" && (
              <Field label={t("api.authority")}>
                <select className="input" value={f.authority_code} onChange={(e) => set("authority_code", e.target.value)}>
                  <option value="">—</option>
                  {(meta.authorities ?? []).map((a) => <option key={a.code} value={a.code}>{a.name}</option>)}
                </select>
              </Field>
            )}
            <Field label={t("api.acting")} hint={t("api.actingHint")}><input className="input ltr" type="email" value={f.acting_email} onChange={(e) => set("acting_email", e.target.value)} /></Field>
            <Field label={t("api.rate")}><input className="input ltr" type="number" min={10} max={6000} value={f.rate} onChange={(e) => set("rate", Number(e.target.value))} /></Field>
          </div>
        )}
        {error ? <ErrorBox error={error} /> : null}
      </div>
    </Modal>
  );
}

// ---------------------------------------------------------------- one client
function ClientView({ uid, meta, onBack }: { uid: string; meta: Meta | null; onBack: () => void }) {
  const { t, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Detail>(`/api/integrations/clients/${uid}`), [uid]);
  const [secret, setSecret] = useState<{ title: string; value: string; hint: string } | null>(null);
  const [deciding, setDeciding] = useState<string | null>(null);
  const [revoking, setRevoking] = useState<Key | null>(null);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const act = async (fn: () => Promise<unknown>, done?: string) => {
    setError(null);
    try { await fn(); if (done) toast(done); state.reload(); } catch (e) { setError(e); }
  };
  const issue = () => act(async () => {
    const k = await api.post<{ key: string }>(`/api/integrations/clients/${uid}/keys`);
    setSecret({ title: t("api.keyIssued"), value: k.key, hint: t("api.keyOnce") });
  });
  return (
    <div className="stack">
      <button className="btn text small" style={{ alignSelf: "flex-start" }} onClick={onBack}><Icon name="arrow_forward" flip />{t("api.back")}</button>
      <Loaded state={state}>{(d) => {
        const c = d.client;
        const maxReq = Math.max(1, ...d.usage.map((u) => u.requests));
        return (
          <>
            <PageHead title={c.name} sub={`${t(`api.kinds.${c.kind}`)} · ${t(`api.env.${c.environment}`)}`}>
                      <div className="row" style={{ gap: 8 }}>
                        <Status value={c.status} />
                        {meta?.platform && c.status === "PENDING" && <button className="btn" onClick={() => act(() => api.post(`/api/integrations/clients/${uid}/approve`, {}), t("api.approved"))}><Icon name="check_circle" />{t("api.approve")}</button>}
                        {meta?.platform && c.status === "ACTIVE" && <button className="btn tonal" onClick={() => setDeciding("suspend")}><Icon name="pause" />{t("api.suspend")}</button>}
                        {meta?.platform && c.status === "SUSPENDED" && <button className="btn" onClick={() => act(() => api.post(`/api/integrations/clients/${uid}/reactivate`, {}))}><Icon name="play_arrow" />{t("api.reactivate")}</button>}
                        {meta?.platform && c.status !== "REVOKED" && <button className="btn danger" onClick={() => setDeciding("revoke")}><Icon name="block" />{t("api.revoke")}</button>}
                      </div>
            </PageHead>
            {c.status === "PENDING" && <div className="alert warn"><Icon name="schedule" />{t(meta?.platform ? "api.pendingPlatform" : "api.pending")}</div>}
            {c.status_reason && c.status !== "ACTIVE" && <div className="alert error"><Icon name="warning" />{c.status_reason}</div>}
            {error ? <ErrorBox error={error} /> : null}
            <div className="grid cols-2">
              <div className="card stack">
                <h3 style={{ margin: 0 }}>{t("api.settings")}</h3>
                <dl className="kv">
                  {c.company && <><dt>{t("api.company")}</dt><dd>{c.company}</dd></>}
                  {c.authority && <><dt>{t("api.authority")}</dt><dd>{c.authority}</dd></>}
                  {c.provider && <><dt>{t("api.provider")}</dt><dd>{c.provider}</dd></>}
                  <dt>{t("api.acting")}</dt><dd className="ltr">{c.acting_user ?? "—"}</dd>
                  <dt>{t("api.rate")}</dt><dd>{c.rate_limit_per_min}</dd>
                  <dt>{t("api.ips")}</dt><dd className="ltr">{c.ip_allowlist.length ? c.ip_allowlist.join(", ") : t("api.anyAddress")}</dd>
                  <dt>{t("api.createdBy")}</dt><dd className="ltr">{c.created_by ?? "—"}</dd>
                  <dt>{t("api.approvedBy")}</dt><dd className="ltr">{c.approved_by ?? "—"}</dd>
                </dl>
                <div className="row" style={{ gap: 6 }}>{c.scopes.map((s) => <span key={s} className="chip mono ltr" title={t(`api.scope.${s.replace(":", "_")}`)}>{s}</span>)}</div>
              </div>
              <div className="card stack">
                <h3 style={{ margin: 0 }}>{t("api.usage")}</h3>
                {d.usage.length === 0 ? <p className="small muted">{t("api.noUsage")}</p> : (
                  <div className="usage-bars" role="img" aria-label={t("api.usage")}>
                    {d.usage.map((u) => (
                      <div key={u.day} className="usage-bar" title={`${u.day}: ${u.requests} / ${u.errors}`}>
                        <span style={{ height: `${(u.requests / maxReq) * 100}%` }} />
                        {u.errors > 0 && <i style={{ height: `${(u.errors / maxReq) * 100}%` }} />}
                      </div>
                    ))}
                  </div>
                )}
                <p className="small muted" style={{ margin: 0 }}>{t("api.usageHint")}</p>
              </div>
            </div>

            <div className="card stack">
              <div className="row between"><h3 style={{ margin: 0 }}><Icon name="key" /> {t("api.keys")}</h3>
                <button className="btn" disabled={c.status !== "ACTIVE"} onClick={issue}><Icon name="add" />{t("api.issueKey")}</button></div>
              <p className="small muted" style={{ margin: 0 }}>{t("api.keysHint")}</p>
              {d.keys.length === 0 ? <p className="small muted">{t("api.noKeys")}</p> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("api.prefix")}</th><th>{t("common.status")}</th><th>{t("api.expires")}</th><th>{t("api.lastUsed")}</th><th /></tr></thead>
                  <tbody>{d.keys.map((k) => (
                    <tr key={k.id}>
                      <td className="mono ltr">{k.key_prefix}…</td>
                      <td><Status value={k.status} />{k.revoke_reason && <div className="small muted">{k.revoke_reason}</div>}</td>
                      <td className="small">{dateTime(k.expires_at)}</td>
                      <td className="small">{k.last_used_at ? <>{dateTime(k.last_used_at)}<div className="muted ltr" style={{ display: "block" }}>{k.last_used_ip}</div></> : "—"}</td>
                      <td className="num">{k.status === "ACTIVE" && <button className="btn text small" onClick={() => setRevoking(k)}><Icon name="block" />{t("api.revokeKey")}</button>}</td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>

            <div className="card stack">
              <div className="row between"><h3 style={{ margin: 0 }}><Icon name="webhook" /> {t("api.webhooks")}</h3>
                <button className="btn tonal" disabled={c.status === "REVOKED"} onClick={() => setAdding(true)}><Icon name="add" />{t("api.addWebhook")}</button></div>
              <p className="small muted" style={{ margin: 0 }}>{t("api.webhooksHint")}</p>
              {d.webhooks.length === 0 ? <p className="small muted">{t("api.noWebhooks")}</p> : d.webhooks.map((h) => (
                <div key={h.uid} className="hook-row">
                  <div style={{ minWidth: 0 }}>
                    <div className="mono ltr small" style={{ wordBreak: "break-all" }}>{h.url}</div>
                    <div className="row" style={{ gap: 4, marginTop: 4 }}>{h.events.map((e) => <span key={e} className="chip small">{t(`api.event.${e.replace(".", "_")}`)}</span>)}</div>
                    <div className="small muted" style={{ marginTop: 4 }}>
                      {h.last_success_at ? t("api.lastSuccess", { when: dateTime(h.last_success_at) }) : t("api.neverDelivered")}
                      {h.pending > 0 && ` · ${t("api.pendingN", { n: h.pending })}`}{h.dead > 0 && ` · ${t("api.deadN", { n: h.dead })}`}
                      {h.include_pii && ` · ${t("api.withPii")}`}
                    </div>
                  </div>
                  <div className="row" style={{ gap: 4 }}>
                    <button className="btn text small" onClick={() => act(() => api.post(`/api/integrations/clients/${uid}/webhooks/${h.uid}/ping`), t("api.pingQueued"))}><Icon name="send" />{t("api.ping")}</button>
                    <button className="btn text small" onClick={() => act(async () => {
                      const r = await api.post<{ secret: string }>(`/api/integrations/clients/${uid}/webhooks/${h.uid}/rotate`);
                      setSecret({ title: t("api.newSecret"), value: r.secret, hint: t("api.secretOnce") });
                    })}><Icon name="autorenew" />{t("api.rotate")}</button>
                    <button className="btn text small danger" onClick={() => act(() => api.del(`/api/integrations/clients/${uid}/webhooks/${h.uid}`), t("api.removed"))}><Icon name="delete" /></button>
                  </div>
                </div>
              ))}
              {d.deliveries.length > 0 && (
                <>
                  <h4 style={{ margin: "8px 0 0" }}>{t("api.deliveries")}</h4>
                  <div className="table-wrap" tabIndex={0}><table className="table">
                    <thead><tr><th>{t("common.when")}</th><th>{t("api.eventCol")}</th><th>{t("common.status")}</th><th>{t("api.attempts")}</th><th>{t("api.response")}</th><th /></tr></thead>
                    <tbody>{d.deliveries.map((x) => (
                      <tr key={x.delivery_uid}>
                        <td className="small">{dateTime(x.created_at)}</td>
                        <td className="small">{t(`api.event.${x.event_type.replace(".", "_")}`)}</td>
                        <td><Status value={x.status} /></td>
                        <td className="small">{x.attempts}</td>
                        <td className="small ltr">{x.http_status ?? ""} {x.last_error && <span className="muted">{x.last_error.slice(0, 60)}</span>}</td>
                        <td className="num">{(x.status === "DEAD" || x.status === "FAILED") && (
                          <button className="btn text small" onClick={() => act(() => api.post(`/api/integrations/clients/${uid}/deliveries/${x.delivery_uid}/retry`), t("api.retried"))}><Icon name="refresh" /></button>)}</td>
                      </tr>
                    ))}</tbody>
                  </table></div>
                </>
              )}
            </div>

            {adding && <WebhookModal uid={uid} events={d.events} canPii={["CARRIER", "CHANNEL", "INTERNAL"].includes(c.kind)} onClose={() => setAdding(false)}
                                     onDone={(s) => { setAdding(false); state.reload(); setSecret({ title: t("api.webhookAdded"), value: s, hint: t("api.secretOnce") }); }} />}
          </>
        );
      }}</Loaded>
      {secret && <SecretModal {...secret} onClose={() => setSecret(null)} />}
      {deciding && <ReasonModal title={t(`api.${deciding}Title`)} onClose={() => setDeciding(null)}
                                onSave={(reason) => api.post(`/api/integrations/clients/${uid}/${deciding}`, { reason }).then(() => { setDeciding(null); state.reload(); })} />}
      {revoking && <ReasonModal title={t("api.revokeKeyTitle", { prefix: revoking.key_prefix })} onClose={() => setRevoking(null)}
                                onSave={(reason) => api.post(`/api/integrations/clients/${uid}/keys/${revoking.id}/revoke`, { reason }).then(() => { setRevoking(null); state.reload(); toast(t("api.keyRevoked")); })} />}
    </div>
  );
}

function SecretModal({ title, value, hint, onClose }: { title: string; value: string; hint: string; onClose: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  return (
    <Modal title={title} onClose={onClose} actions={<button className="btn" onClick={onClose}>{t("api.savedIt")}</button>}>
      <div className="stack">
        <div className="alert warn"><Icon name="warning" />{hint}</div>
        <div className="secret-box">
          <code className="ltr">{value}</code>
          <button className="btn text small" onClick={() => copy(value, () => toast(t("pay.copied")))}><Icon name="content_copy" />{t("api.copy")}</button>
        </div>
      </div>
    </Modal>
  );
}

function ReasonModal({ title, onClose, onSave }: { title: string; onClose: () => void; onSave: (reason: string) => Promise<unknown> }) {
  const { t } = useI18n();
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  return (
    <Modal title={title} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn danger" disabled={reason.trim().length < 5} onClick={() => onSave(reason.trim()).catch(setError)}>{t("pay.confirm")}</button></>}>
      <div className="stack">
        <Field label={t("pay.reason")}><input className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        {error ? <ErrorBox error={error} /> : null}
      </div>
    </Modal>
  );
}

function WebhookModal({ uid, events, canPii, onClose, onDone }: { uid: string; events: string[]; canPii: boolean; onClose: () => void; onDone: (secret: string) => void }) {
  const { t } = useI18n();
  const [url, setUrl] = useState("https://");
  const [chosen, setChosen] = useState<string[]>([]);
  const [pii, setPii] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setError(null);
    try {
      const r = await api.post<{ secret: string }>(`/api/integrations/clients/${uid}/webhooks`, { url, events: chosen, include_pii: pii });
      onDone(r.secret);
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("api.addWebhook")} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={!url.startsWith("https://") || url.length < 12 || chosen.length === 0} onClick={save}>{t("api.add")}</button></>}>
      <div className="stack">
        <Field label={t("api.url")} hint={t("api.urlHint")}><input className="input ltr" value={url} onChange={(e) => setUrl(e.target.value.trim())} /></Field>
        <Field label={t("api.events")}>
          <div className="stack" style={{ gap: 6 }}>{events.filter((e) => e !== "webhook.ping").map((e) => (
            <label key={e} className="check-row"><input type="checkbox" checked={chosen.includes(e)} onChange={() => setChosen(chosen.includes(e) ? chosen.filter((x) => x !== e) : [...chosen, e])} />
              <span>{t(`api.event.${e.replace(".", "_")}`)} <span className="small muted mono ltr">{e}</span></span></label>
          ))}</div>
        </Field>
        {canPii && <label className="check-row"><input type="checkbox" checked={pii} onChange={(e) => setPii(e.target.checked)} /><span>{t("api.includePii")}<div className="small muted">{t("api.includePiiHint")}</div></span></label>}
        {error ? <ErrorBox error={error} /> : null}
      </div>
    </Modal>
  );
}
