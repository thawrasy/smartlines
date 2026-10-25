import { useMemo, useState, type ReactElement } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, PasswordInput, Status, useLoad, useToast } from "../../components/ui";
import { useSignInSlip, type SignIn } from "../../components/SignInSlip";

interface Perm { code: string; module: string; description: string; sensitive: boolean; grantable: boolean }
interface Role { uid: string; code: string; name: string; description: string | null; status: string; ready: boolean; editable: boolean; permissions: string[]; holders: number }
interface Person { uid: string; full_name: string; email: string | null; username: string | null; status: string; last_login_at: string | null;
                   is_owner: boolean; mfa_enrolled: boolean; roles: string[]; role_names: string[] }
interface Exc { uid: string; user_uid: string; user_name: string; permission_code: string; effect: "GRANT" | "DENY"; reason: string;
                valid_from: string; valid_to: string; status: string; ended: boolean; requested_by_name: string; decided_by_name: string | null;
                decision_note: string | null; created_at: string }

type Tab = "users" | "roles" | "exceptions";

/** Users and roles (owner's request N1, 1154): the same section in the platform, carrier, agency and station portals.
 *  Ready roles come from the platform; an administrator defines more from the permissions they hold, gives roles, and
 *  asks for time-limited exceptions that a second administrator approves. */
export function PeoplePage() {
  const { t } = useI18n();
  const [tab, setTab] = useState<Tab>("users");
  const cat = useLoad(() => api.get<{ kind: string; permissions: Perm[] }>("/api/people/catalog"));
  const roles = useLoad(() => api.get<{ roles: Role[] }>("/api/people/roles").then((r) => r.roles));
  return (
    <div className="stack">
      <PageHead title={t("people.title")} sub={t("people.sub")} />
      <div className="segmented" role="tablist" aria-label={t("people.title")} style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {(["users", "roles", "exceptions"] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={tab === k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>
            <Icon name={k === "users" ? "group" : k === "roles" ? "badge" : "rule"} size={18} />{t(`people.tab.${k}`)}
          </button>
        ))}
      </div>
      <Loaded state={cat}>{(c) => (
        <Loaded state={roles}>{(rs) => (
          tab === "users" ? <Users perms={c.permissions} roles={rs} single={c.kind !== "PLATFORM"} />
            : tab === "roles" ? <Roles perms={c.permissions} roles={rs} reload={roles.reload} />
            : <Exceptions perms={c.permissions} />
        )}</Loaded>
      )}</Loaded>
    </div>
  );
}

/** A permission's name in the interface's language, else the catalog's description. */
function usePermName() {
  const { t, has } = useI18n();
  return (p: Perm | string, perms?: Perm[]) => {
    const code = typeof p === "string" ? p : p.code;
    const found = typeof p === "string" ? perms?.find((x) => x.code === p) : p;
    return has(`perm.${code}`) ? t(`perm.${code}`) : found?.description ?? code;
  };
}

// ------------------------------------------------------------------ users
function Users({ perms, roles, single }: { perms: Perm[]; roles: Role[]; single: boolean }) {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const toast = useToast();
  const state = useLoad(() => api.get<{ users: Person[] }>("/api/people/users").then((r) => r.users));
  const slip = useSignInSlip();
  const givable = roles.filter((r) => r.status === "ACTIVE" && r.permissions.every((p) => perms.find((x) => x.code === p)?.grantable ?? true));
  const blank = { full_name: "", email: "", mobile: "", password: "", roles: [] as string[] };
  const [f, setF] = useState(blank);
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<Person | null>(null);
  const [exc, setExc] = useState<Person | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const run = async (fn: () => Promise<unknown>, after?: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); toast(t("common.saved")); after?.(); state.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const roleSelect = (value: string[], onChange: (v: string[]) => void) => single ? (
    <Field label={t("people.role")}>
      <select className="input" value={value[0] ?? ""} onChange={(e) => onChange(e.target.value ? [e.target.value] : [])}>
        <option value="">—</option>
        {givable.map((r) => <option key={r.uid} value={r.uid}>{r.name}</option>)}
      </select>
    </Field>
  ) : (
    <fieldset className="stack tight" style={{ border: 0, padding: 0, margin: 0 }}>
      <legend className="small muted">{t("people.roles")}</legend>
      {givable.map((r) => (
        <label key={r.uid} className="check small">
          <input type="checkbox" checked={value.includes(r.uid)} onChange={(e) => onChange(e.target.checked ? [...value, r.uid] : value.filter((x) => x !== r.uid))} />
          <span><strong>{r.name}</strong>{r.description ? <span className="muted"> · {r.description}</span> : null}</span>
        </label>
      ))}
    </fieldset>
  );
  return (
    <div className="stack">
      {slip.element}
      <div className="row between">
        <p className="small muted" style={{ margin: 0 }}>{t("people.usersHint")}</p>
        <button className="btn" onClick={() => { setError(null); setF(blank); setAdding(true); }}><Icon name="person_add" />{t("people.addUser")}</button>
      </div>
      {!adding && !editing && !exc && <ErrorBox error={error} />}
      <Loaded state={state}>{(list) => list.length === 0 ? <Empty icon="group" title={t("people.noUsers")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("auth.username")}</th><th>{t("people.roles")}</th><th>{t("agency.twoStep")}</th>
            <th>{t("agency.lastLogin")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{list.map((u) => (
            <tr key={u.uid}>
              <td style={{ fontWeight: 500 }}>{u.full_name}<div className="small muted ltr">{u.email}</div></td>
              <td className="ltr small">{u.username ?? "—"}</td>
              <td>{u.is_owner ? <span className="chip green">{t("agency.owner")}</span> : u.role_names.join(t("people.and")) || "—"}</td>
              <td>{u.mfa_enrolled ? <span className="chip green"><Icon name="verified" size={16} />{t("common.yes")}</span> : <span className="chip">{t("common.no")}</span>}</td>
              <td className="small">{u.last_login_at ? dateTime(u.last_login_at) : "—"}</td>
              <td><Status value={u.status} /></td>
              <td>{!u.is_owner && u.uid !== me?.uid && (
                <span className="row">
                  <button className="btn text small" onClick={() => { setError(null); setEditing(u); }}>{t("common.edit")}</button>
                  <button className="btn text small" onClick={() => { setError(null); setExc(u); }}>{t("people.exception")}</button>
                </span>
              )}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {adding && (
        <Modal title={t("people.addUser")} onClose={() => setAdding(false)}
               actions={<><button className="btn text" onClick={() => setAdding(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || f.roles.length === 0 || f.password.length < 12 || f.full_name.trim().length < 3}
                         onClick={() => run(async () => { const r = await api.post<{ sign_in?: SignIn }>("/api/people/users", { ...f, mobile: f.mobile || null }); slip.show(r.sign_in); },
                                            () => setAdding(false))}>{t("common.create")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("common.name")}><input className="input" value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
            <div className="grid cols-2">
              <Field label={t("common.email")}><input className="input ltr" type="email" value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></Field>
              <Field label={`${t("common.mobile")} (${t("common.optional")})`}><input className="input ltr" inputMode="tel" value={f.mobile} onChange={(e) => setF({ ...f, mobile: e.target.value })} /></Field>
            </div>
            {roleSelect(f.roles, (roles) => setF({ ...f, roles }))}
            <Field label={t("people.tempPassword")} hint={t("auth.passwordHint")}>
              <PasswordInput autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
            </Field>
            <p className="small muted"><Icon name="shield" size={16} /> {t("people.mfaNote")}</p>
          </div>
        </Modal>
      )}
      {editing && <EditUser person={editing} roleSelect={roleSelect} busy={busy} error={error} onClose={() => setEditing(null)}
                            onSave={(body) => run(() => api.put(`/api/people/users/${editing.uid}`, body), () => setEditing(null))} />}
      {exc && <ExceptionForm person={exc} perms={perms} busy={busy} error={error} onClose={() => setExc(null)}
                             onSave={(body) => run(() => api.post(`/api/people/users/${exc.uid}/exceptions`, body), () => setExc(null))} />}
    </div>
  );
}

function EditUser({ person, roleSelect, busy, error, onClose, onSave }: {
  person: Person; roleSelect: (v: string[], on: (v: string[]) => void) => ReactElement; busy: boolean; error: unknown;
  onClose: () => void; onSave: (body: { roles: string[]; status: string }) => void;
}) {
  const { t } = useI18n();
  const [roles, setRoles] = useState(person.roles);
  const [status, setStatus] = useState(person.status === "DISABLED" ? "DISABLED" : "ACTIVE");
  return (
    <Modal title={person.full_name} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || roles.length === 0} onClick={() => onSave({ roles, status })}>{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        {roleSelect(roles, setRoles)}
        <Field label={t("common.status")}>
          <select className="input" value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="ACTIVE">{t("people.active")}</option><option value="DISABLED">{t("people.disabled")}</option>
          </select>
        </Field>
        {status === "DISABLED" && <div className="alert warn small"><Icon name="warning" size={20} /><span>{t("people.disableNote")}</span></div>}
      </div>
    </Modal>
  );
}

const inDays = (n: number) => { const d = new Date(); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };

function ExceptionForm({ person, perms, busy, error, onClose, onSave }: {
  person: Person; perms: Perm[]; busy: boolean; error: unknown; onClose: () => void;
  onSave: (body: { permission: string; effect: string; valid_to: string; reason: string }) => void;
}) {
  const { t } = useI18n();
  const name = usePermName();
  const [effect, setEffect] = useState<"GRANT" | "DENY">("GRANT");
  const [permission, setPermission] = useState("");
  const [until, setUntil] = useState(inDays(30));
  const [reason, setReason] = useState("");
  const options = perms.filter((p) => effect === "DENY" || p.grantable);
  const ok = !!permission && reason.trim().length >= 5 && until > inDays(0) && until <= inDays(365);
  return (
    <Modal title={`${t("people.exception")} · ${person.full_name}`} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
             <button className="btn" disabled={busy || !ok}
                     onClick={() => onSave({ permission, effect, valid_to: new Date(`${until}T23:59:59`).toISOString(), reason: reason.trim() })}>{t("people.askApproval")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        <div className="segmented" role="tablist" aria-label={t("people.effect")} style={{ alignSelf: "flex-start" }}>
          {(["GRANT", "DENY"] as const).map((k) => (
            <button key={k} type="button" role="tab" aria-selected={effect === k} className={effect === k ? "on" : ""} onClick={() => { setEffect(k); setPermission(""); }}>
              {t(`people.effects.${k}`)}
            </button>
          ))}
        </div>
        <Field label={t("people.permission")}>
          <select className="input" value={permission} onChange={(e) => setPermission(e.target.value)}>
            <option value="">—</option>
            {options.map((p) => <option key={p.code} value={p.code}>{name(p)}</option>)}
          </select>
        </Field>
        <Field label={t("people.until")} hint={t("people.untilHint")}>
          <input className="input ltr" type="date" min={inDays(1)} max={inDays(365)} value={until} onChange={(e) => setUntil(e.target.value)} />
        </Field>
        <Field label={t("common.reason")}><textarea className="input" maxLength={500} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <p className="small muted"><Icon name="rule" size={16} /> {t("people.fourEyes")}</p>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ roles
function Roles({ perms, roles, reload }: { perms: Perm[]; roles: Role[]; reload: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const name = usePermName();
  const [edit, setEdit] = useState<{ uid: string | null; name: string; description: string; permissions: string[]; status: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const modules = useMemo(() => [...new Set(perms.map((p) => p.module))], [perms]);
  const save = async () => {
    if (!edit) return;
    setBusy(true); setError(null);
    const body = { name: edit.name.trim(), description: edit.description.trim() || null, permissions: edit.permissions, status: edit.status };
    try {
      await (edit.uid ? api.put(`/api/people/roles/${edit.uid}`, body) : api.post("/api/people/roles", body));
      toast(t("common.saved")); setEdit(null); reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const copyOf = (r: Role) => ({ uid: null, name: `${r.name} (${t("people.copy")})`, description: r.description ?? "",
                                  permissions: r.permissions.filter((p) => perms.find((x) => x.code === p)?.grantable), status: "ACTIVE" });
  return (
    <div className="stack">
      <div className="row between">
        <p className="small muted" style={{ margin: 0 }}>{t("people.rolesHint")}</p>
        <button className="btn" onClick={() => { setError(null); setEdit({ uid: null, name: "", description: "", permissions: [], status: "ACTIVE" }); }}>
          <Icon name="add" />{t("people.addRole")}</button>
      </div>
      <div className="grid cols-2" style={{ alignItems: "start" }}>
        {roles.map((r) => (
          <div key={r.uid} className="card stack tight">
            <div className="row between">
              <h3 style={{ margin: 0 }}>{r.name}</h3>
              <span className="row">{r.ready ? <span className="chip">{t("people.ready")}</span> : <span className="chip green">{t("people.own")}</span>}
                {r.status !== "ACTIVE" && <Status value={r.status} />}</span>
            </div>
            {r.description && <p className="small muted" style={{ margin: 0 }}>{r.description}</p>}
            <p className="small" style={{ margin: 0 }}>{t("people.holders", { n: r.holders })} · {t("people.permCount", { n: r.permissions.length })}</p>
            <details><summary className="small">{t("people.showPerms")}</summary>
              <ul className="small">{r.permissions.map((p) => <li key={p}>{name(p, perms)}</li>)}</ul></details>
            <div className="row">
              {r.editable && <button className="btn text small" onClick={() => { setError(null); setEdit({ uid: r.uid, name: r.name, description: r.description ?? "", permissions: r.permissions, status: r.status }); }}>{t("common.edit")}</button>}
              <button className="btn text small" onClick={() => { setError(null); setEdit(copyOf(r)); }}>{t("people.copyRole")}</button>
            </div>
          </div>
        ))}
      </div>
      {edit && (
        <Modal wide title={edit.uid ? t("people.editRole") : t("people.addRole")} onClose={() => setEdit(null)}
               actions={<><button className="btn text" onClick={() => setEdit(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || edit.name.trim().length < 2 || edit.permissions.length === 0} onClick={save}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <div className="grid cols-2">
              <Field label={t("common.name")}><input className="input" maxLength={80} value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></Field>
              {edit.uid && (
                <Field label={t("common.status")}>
                  <select className="input" value={edit.status} onChange={(e) => setEdit({ ...edit, status: e.target.value })}>
                    <option value="ACTIVE">{t("people.active")}</option><option value="RETIRED">{t("people.retired")}</option>
                  </select>
                </Field>
              )}
            </div>
            <Field label={`${t("people.description")} (${t("common.optional")})`}><input className="input" maxLength={300} value={edit.description} onChange={(e) => setEdit({ ...edit, description: e.target.value })} /></Field>
            <p className="small muted">{t("people.notHeld")}</p>
            {modules.map((m) => (
              <fieldset key={m} className="stack tight" style={{ border: "1px solid var(--outline-variant)", borderRadius: 12, padding: 12 }}>
                <legend className="small" style={{ fontWeight: 600 }}>{t(`people.modules.${m}`)}</legend>
                <div className="grid cols-2">
                  {perms.filter((p) => p.module === m).map((p) => {
                    const on = edit.permissions.includes(p.code);
                    return (
                      <label key={p.code} className="check small" style={{ opacity: p.grantable || on ? 1 : 0.55 }}>
                        <input type="checkbox" checked={on} disabled={!p.grantable && !on}
                               onChange={(e) => setEdit({ ...edit, permissions: e.target.checked ? [...edit.permissions, p.code] : edit.permissions.filter((x) => x !== p.code) })} />
                        <span>{name(p)}{p.sensitive && <Icon name="shield" size={14} />}</span>
                      </label>
                    );
                  })}
                </div>
              </fieldset>
            ))}
          </div>
        </Modal>
      )}
    </div>
  );
}

// ------------------------------------------------------------------ exceptions
function Exceptions({ perms }: { perms: Perm[] }) {
  const { t, dateTime } = useI18n();
  const { me } = useAuth();
  const toast = useToast();
  const name = usePermName();
  const state = useLoad(() => api.get<{ exceptions: Exc[] }>("/api/people/exceptions").then((r) => r.exceptions));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const act = async (e: Exc, action: "approve" | "reject" | "revoke") => {
    setBusy(true); setError(null);
    try { await api.post(`/api/people/exceptions/${e.uid}/${action}`, {}); toast(t("common.saved")); state.reload(); }
    catch (err) { setError(err); } finally { setBusy(false); }
  };
  return (
    <div className="stack">
      <p className="small muted" style={{ margin: 0 }}>{t("people.excHint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{(list) => list.length === 0 ? <Empty icon="rule" title={t("people.noExc")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.name")}</th><th>{t("people.permission")}</th><th>{t("people.effect")}</th><th>{t("people.until")}</th>
            <th>{t("common.reason")}</th><th>{t("people.askedBy")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{list.map((e) => (
            <tr key={e.uid}>
              <td style={{ fontWeight: 500 }}>{e.user_name}</td>
              <td>{name(e.permission_code, perms)}</td>
              <td><span className={`chip ${e.effect === "GRANT" ? "green" : ""}`}>{t(`people.effects.${e.effect}`)}</span></td>
              <td className="small">{dateTime(e.valid_to)}</td>
              <td className="small">{e.reason}</td>
              <td className="small">{e.requested_by_name}{e.decided_by_name ? <div className="muted">{t("people.decidedBy", { name: e.decided_by_name })}</div> : null}</td>
              <td>{e.ended ? <span className="chip">{t("people.ended")}</span> : <Status value={e.status} />}</td>
              <td>{e.status === "PENDING" && e.user_uid !== me?.uid ? (
                <span className="row">
                  <button className="btn text small" disabled={busy} onClick={() => act(e, "approve")}>{t("people.approve")}</button>
                  <button className="btn text small" disabled={busy} onClick={() => act(e, "reject")}>{t("people.reject")}</button>
                </span>
              ) : e.status === "ACTIVE" && !e.ended ? (
                <button className="btn text small" disabled={busy} onClick={() => act(e, "revoke")}>{t("people.revoke")}</button>
              ) : null}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
    </div>
  );
}
