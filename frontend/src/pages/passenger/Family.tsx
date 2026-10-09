import { useState } from "react";
import { api, newKey, type FamilyMember, type FamilyRule, type FamilyView } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// Family accounts (study 4.20): the head registers the family, pays for it, approves the accounts members open on their
// own devices, and limits when and where each member travels on the family's money.

const RELATIONS = ["SPOUSE", "SON", "DAUGHTER", "FATHER", "MOTHER", "BROTHER", "SISTER", "GRANDCHILD", "GRANDPARENT", "OTHER"];
const FUNDING = ["OWN", "HEAD_WALLET", "FAMILY_ACCOUNT"] as const;
const DAYS = [1, 2, 3, 4, 5, 6, 7];

interface City { code: string; country_code: string }
interface Spend { source: string; amount: number; ref_type: string; created_at: string; member_uid: string; first_name: string; last_name: string }

export default function Family() {
  const { t } = useI18n();
  const state = useLoad(() => api.get<FamilyView>("/api/family"));
  return (
    <div className="page stack">
      <PageHead title={t("family.title")} sub={t("family.subtitle")} />
      <Loaded state={state}>{(f) => f.role === null ? <Start onDone={state.reload} />
        : f.role === "MEMBER" ? <MemberView f={f} onDone={state.reload} /> : <HeadView f={f} reload={state.reload} />}</Loaded>
    </div>
  );
}

function Start({ onDone }: { onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState<unknown>(null);
  const create = async () => {
    setError(null);
    try { await api.post("/api/family", { name: name.trim() }); onDone(); } catch (e) { setError(e); }
  };
  const join = async () => {
    setError(null);
    try {
      const device = navigator.userAgent.match(/\(([^)]+)\)/)?.[1]?.slice(0, 100) ?? "Browser";
      await api.post("/api/family/join", { code: code.trim().toUpperCase(), device_label: device, device_id: localDeviceId() });
      toast(t("family.joinSent")); onDone();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="grid cols-2" style={{ alignItems: "start" }}>
        <div className="card stack">
          <div className="row"><Icon name="family_restroom" size={28} /><h3>{t("family.createTitle")}</h3></div>
          <p className="muted">{t("family.createHint")}</p>
          <Field label={t("family.name")}><input className="input" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} /></Field>
          <button className="btn" disabled={name.trim().length < 2} onClick={create}><Icon name="add" />{t("family.create")}</button>
        </div>
        <div className="card stack">
          <div className="row"><Icon name="link" size={28} /><h3>{t("family.joinTitle")}</h3></div>
          <p className="muted">{t("family.joinHint")}</p>
          <Field label={t("family.code")}>
            <input className="input ltr mono" value={code} maxLength={8} placeholder="ABCD2345" onChange={(e) => setCode(e.target.value)} />
          </Field>
          <button className="btn outline" disabled={!/^[A-Za-z0-9]{8}$/.test(code.trim())} onClick={join}><Icon name="how_to_reg" />{t("family.join")}</button>
        </div>
      </div>
    </div>
  );
}

/** A random id kept in this browser, so the head sees a request from a device they can recognise later. */
function localDeviceId() {
  try {
    let id = localStorage.getItem("masslak.device");
    if (!id) { id = crypto.randomUUID(); localStorage.setItem("masslak.device", id); }
    return id;
  } catch { return crypto.randomUUID(); }
}

function MemberView({ f, onDone }: { f: FamilyView; onDone: () => void }) {
  const { t, money } = useI18n();
  const me = f.me!;
  const leave = async () => { if (confirm(t("family.leaveConfirm"))) { await api.post("/api/family/leave"); onDone(); } };
  return (
    <div className="stack">
      <div className="card hero row between">
        <div><div className="muted">{t("family.memberOf")}</div><h2>{f.family!.name}</h2></div>
        <Icon name="diversity_3" size={40} />
      </div>
      <div className="card stack">
        <h3>{t("family.howYouPay")}</h3>
        <p>{t(`family.funding.${me.funding}`)}</p>
        <div className="row">
          {me.per_trip_limit && <span className="chip outline">{t("family.perTrip")}: {money(me.per_trip_limit)}</span>}
          {me.daily_limit && <span className="chip outline">{t("family.daily")}: {money(me.daily_limit)}</span>}
          {me.monthly_limit && <span className="chip outline">{t("family.monthly")}: {money(me.monthly_limit)}</span>}
        </div>
      </div>
      <div className="card stack">
        <h3>{t("family.rulesTitle")}</h3>
        {(f.rules ?? []).length === 0 ? <p className="muted">{t("family.noRules")}</p> : <RuleList rules={f.rules!} />}
      </div>
      <button className="btn text" style={{ alignSelf: "start", color: "var(--error)" }} onClick={leave}><Icon name="logout" />{t("family.leave")}</button>
    </div>
  );
}

function RuleList({ rules, onDelete }: { rules: FamilyRule[]; onDelete?: (r: FamilyRule) => void }) {
  const { t, city } = useI18n();
  return (
    <div className="stack tight">
      {rules.map((r) => (
        <div key={r.uid} className="row between">
          <span>
            <Icon name={r.rule_type === "TIME_WINDOW" ? "schedule" : r.rule_type === "LINE" ? "directions_bus" : "route"} size={18} />{" "}
            {r.rule_type === "TIME_WINDOW"
              ? `${(r.days ?? DAYS).map((d) => t(`family.day.${d}`)).join(t("common.listSep"))} · ${r.start_time}–${r.end_time}`
              : r.rule_type === "ROUTE" ? `${city(r.from_city ?? "")} ${r.both_ways ? "⇄" : "→"} ${city(r.to_city ?? "")}`
              : `${t("family.ruleLine")}: ${r.line ?? `#${r.line_id}`}`}
          </span>
          {onDelete && <button className="btn text" onClick={() => onDelete(r)}><Icon name="delete" /></button>}
        </div>
      ))}
    </div>
  );
}

function HeadView({ f, reload }: { f: FamilyView; reload: () => void }) {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<FamilyMember | null>(null);
  const [rulesOf, setRulesOf] = useState<FamilyMember | null>(null);
  const [code, setCode] = useState<{ member: string; code: string; expires_at: string } | null>(null);
  const [amount, setAmount] = useState("");
  const [error, setError] = useState<unknown>(null);
  const spend = useLoad(() => api.get<{ spend: Spend[] }>("/api/family/spend"));
  const run = async (fn: () => Promise<unknown>, ok?: string) => {
    setError(null);
    try { await fn(); if (ok) toast(ok); reload(); spend.reload(); } catch (e) { setError(e); }
  };
  const move = (to: boolean) => run(() => api.post(`/api/family/account/${to ? "topup" : "withdraw"}`,
    { amount: Math.round(Number(amount) * 100), idempotency_key: newKey() }), t("family.moved"));
  const invite = async (m: FamilyMember) => {
    setError(null);
    try { const r = await api.post<{ code: string; expires_at: string }>(`/api/family/members/${m.uid}/invite`); setCode({ member: m.full_name, ...r }); reload(); }
    catch (e) { setError(e); }
  };

  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="card hero row between">
        <div>
          <div className="muted">{t("family.account")}</div>
          <div className="price" style={{ fontSize: 32 }}>{money(f.account!.balance)}</div>
          <div className="small muted">{f.family!.name}</div>
        </div>
        <div className="row">
          <input className="input ltr" style={{ width: 140 }} inputMode="decimal" placeholder={t("family.amount")} value={amount}
                 onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
          <button className="btn" disabled={!(Number(amount) > 0)} onClick={() => move(true)}><Icon name="savings" />{t("family.topup")}</button>
          <button className="btn outline" disabled={!(Number(amount) > 0)} onClick={() => move(false)}>{t("family.withdraw")}</button>
        </div>
      </div>

      {(f.requests ?? []).filter((r) => r.status === "PENDING").map((r) => (
        <div key={r.uid} className="card stack" style={{ borderColor: "var(--secondary)" }}>
          <div className="row"><Icon name="devices" size={24} /><h3>{t("family.requestTitle", { name: r.member })}</h3></div>
          <p className="muted">{t("family.requestHint", { device: r.device_label ?? "—" })}</p>
          <ApproveRow onApprove={(funding) => run(() => api.post(`/api/family/requests/${r.uid}/approve`, { funding }), t("family.linked"))}
                      onReject={() => run(() => api.post(`/api/family/requests/${r.uid}/reject`))} />
        </div>
      ))}

      <div className="card stack">
        <div className="card-title"><h3>{t("family.members")}</h3>
          <button className="btn" onClick={() => setAdding(true)}><Icon name="group_add" />{t("family.addMember")}</button></div>
        <div className="table-wrap" tabIndex={0}>
          <table className="table">
            <thead><tr><th>{t("family.member")}</th><th>{t("family.relation")}</th><th>{t("family.age")}</th><th>{t("family.accountCol")}</th>
              <th>{t("family.fundingCol")}</th><th /></tr></thead>
            <tbody>
              {f.members!.map((m) => (
                <tr key={m.uid}>
                  <td><strong>{m.full_name}</strong>{m.id_last4 && <div className="small muted mono">{t(`checkout.idTypes.${m.id_type}`)} •••• {m.id_last4}</div>}</td>
                  <td>{t(`family.rel.${m.relation}`)}</td>
                  <td>{m.age}</td>
                  <td>{m.relation === "SELF" ? "—" : <Status value={m.account_status} />}</td>
                  <td className="small">{m.relation === "SELF" ? t("family.funding.OWN") : t(`family.funding.${m.funding}`)}
                    {m.per_trip_limit && <div className="muted">{t("family.perTrip")}: {money(m.per_trip_limit)}</div>}</td>
                  <td>
                    {m.relation !== "SELF" && (
                      <div className="row" style={{ justifyContent: "flex-end" }}>
                        <button className="btn text" onClick={() => setEditing(m)} title={t("common.edit")}><Icon name="edit" /></button>
                        <button className="btn text" onClick={() => setRulesOf(m)} title={t("family.rulesTitle")}><Icon name="rule" /></button>
                        {m.account_status !== "LINKED" && <button className="btn text" onClick={() => invite(m)} title={t("family.invite")}><Icon name="link" /></button>}
                        <button className="btn text" style={{ color: "var(--error)" }} title={t("common.remove")}
                                onClick={() => confirm(t("family.removeConfirm", { name: m.full_name })) && run(() => api.del(`/api/family/members/${m.uid}`))}>
                          <Icon name="delete" /></button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <FamilyPasses members={f.members!} account={f.account!.balance} onDone={() => { reload(); spend.reload(); }} />

      <div className="card stack">
        <h3>{t("family.spendTitle")}</h3>
        {(spend.data?.spend ?? []).length === 0 ? <p className="muted">{t("family.noSpend")}</p> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.date")}</th><th>{t("family.member")}</th><th>{t("family.paidFrom")}</th><th>{t("family.for")}</th><th>{t("common.amount")}</th></tr></thead>
            <tbody>{spend.data!.spend.map((s, i) => (
              <tr key={i}><td className="small">{dateTime(s.created_at)}</td><td>{s.first_name} {s.last_name}</td>
                <td>{t(`family.funding.${s.source}`)}</td><td>{t(`family.ref.${s.ref_type}`)}</td>
                <td style={{ color: s.ref_type === "refund" ? "var(--success)" : undefined }}>{s.ref_type === "refund" ? "+" : "−"}{money(s.amount)}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </div>

      {adding && <MemberForm onClose={() => setAdding(false)} onSaved={() => { setAdding(false); reload(); }} />}
      {editing && <MemberForm member={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload(); }} />}
      {rulesOf && <RulesModal member={rulesOf} onClose={() => setRulesOf(null)} />}
      {code && (
        <Modal title={t("family.inviteTitle")} onClose={() => setCode(null)}>
          <div className="stack" style={{ alignItems: "center", textAlign: "center" }}>
            <p>{t("family.inviteHint", { name: code.member })}</p>
            <div className="mono" style={{ fontSize: 34, letterSpacing: 6, fontWeight: 700 }}>{code.code}</div>
            <p className="small muted">{t("family.inviteExpires", { at: dateTime(code.expires_at) })}</p>
            <button className="btn outline" onClick={() => { void navigator.clipboard?.writeText(code.code); toast(t("common.copied")); }}>
              <Icon name="content_copy" />{t("common.copy")}</button>
          </div>
        </Modal>
      )}
    </div>
  );
}

function ApproveRow({ onApprove, onReject }: { onApprove: (funding: string) => void; onReject: () => void }) {
  const { t } = useI18n();
  const [funding, setFunding] = useState<string>("HEAD_WALLET");
  return (
    <div className="row">
      <select className="input" style={{ width: "auto" }} value={funding} onChange={(e) => setFunding(e.target.value)}>
        {FUNDING.map((k) => <option key={k} value={k}>{t(`family.funding.${k}`)}</option>)}
      </select>
      <button className="btn" onClick={() => onApprove(funding)}><Icon name="how_to_reg" />{t("family.approve")}</button>
      <button className="btn text" onClick={onReject}>{t("family.reject")}</button>
    </div>
  );
}

function MemberForm({ member, onClose, onSaved }: { member?: FamilyMember; onClose: () => void; onSaved: () => void }) {
  const { t } = useI18n();
  const edit = !!member;
  const [v, setV] = useState({
    relation: "SON", first_name: "", father_name: "", grandfather_name: "", last_name: "", nationality: "SY", birth_date: "",
    gender: "", id_type: member?.id_type ?? "NATIONAL_ID", id_no: "", passport_expiry: member?.passport_expiry ?? "", mobile: "",
    funding: member?.funding ?? "HEAD_WALLET", per_trip_limit: member?.per_trip_limit ? String(member.per_trip_limit / 100) : "",
    daily_limit: member?.daily_limit ? String(member.daily_limit / 100) : "", monthly_limit: member?.monthly_limit ? String(member.monthly_limit / 100) : "",
  });
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof v, val: string) => setV((x) => ({ ...x, [k]: val }));
  const minor = (s: string) => (s.trim() ? Math.round(Number(s) * 100) : null);
  const save = async () => {
    setError(null);
    const limits = { funding: v.funding, per_trip_limit: minor(v.per_trip_limit), daily_limit: minor(v.daily_limit), monthly_limit: minor(v.monthly_limit) };
    try {
      if (edit) {
        await api.patch(`/api/family/members/${member!.uid}`, { ...limits, per_trip_limit: limits.per_trip_limit ?? 0, daily_limit: limits.daily_limit ?? 0,
          monthly_limit: limits.monthly_limit ?? 0, ...(v.mobile.trim() ? { mobile: v.mobile.trim() } : {}), ...(v.id_no.trim() ? { id_type: v.id_type, id_no: v.id_no.trim() } : {}),
          ...(v.passport_expiry ? { passport_expiry: v.passport_expiry } : {}) });
      } else {
        await api.post("/api/family/members", { ...limits, relation: v.relation, first_name: v.first_name.trim(), father_name: v.father_name.trim() || null,
          grandfather_name: v.grandfather_name.trim() || null, last_name: v.last_name.trim(), nationality: v.nationality, birth_date: v.birth_date,
          gender: v.gender || null, mobile: v.mobile.trim() || null, ...(v.id_no.trim() ? { id_type: v.id_type, id_no: v.id_no.trim() } : {}),
          ...(v.passport_expiry ? { passport_expiry: v.passport_expiry } : {}) });
      }
      onSaved();
    } catch (e) { setError(e); }
  };
  const text = (k: keyof typeof v, label: string, extra = {}) => (
    <Field label={label}><input className="input" value={v[k]} onChange={(e) => set(k, e.target.value)} {...extra} /></Field>
  );
  return (
    <Modal wide title={edit ? member!.full_name : t("family.addMember")} onClose={onClose}
           actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" onClick={save}><Icon name="save" />{t("common.save")}</button></>}>
      <div className="stack">
        <ErrorBox error={error} />
        {!edit && (
          <>
            <div className="grid cols-3">
              <Field label={t("family.relation")}>
                <select className="input" value={v.relation} onChange={(e) => set("relation", e.target.value)}>
                  {RELATIONS.map((r) => <option key={r} value={r}>{t(`family.rel.${r}`)}</option>)}
                </select>
              </Field>
              <Field label={t("pax.birthDate")}><input className="input ltr" type="date" value={v.birth_date} max={new Date().toISOString().slice(0, 10)} onChange={(e) => set("birth_date", e.target.value)} /></Field>
              <Field label={t("family.gender")}>
                <select className="input" value={v.gender} onChange={(e) => set("gender", e.target.value)}>
                  <option value="">—</option><option value="M">{t("family.male")}</option><option value="F">{t("family.female")}</option>
                </select>
              </Field>
            </div>
            <div className="grid cols-4">
              {text("first_name", t("checkout.firstName"))}{text("father_name", t("checkout.fatherName"))}
              {text("grandfather_name", t("checkout.grandfatherName"))}{text("last_name", t("checkout.lastName"))}
            </div>
          </>
        )}
        <div className="grid cols-3">
          <Field label={t("checkout.idType")}>
            <select className="input" value={v.id_type} onChange={(e) => set("id_type", e.target.value)}>
              {["NATIONAL_ID", "PASSPORT", "RESIDENCE", "OTHER"].map((k) => <option key={k} value={k}>{t(`checkout.idTypes.${k}`)}</option>)}
            </select>
          </Field>
          {text("id_no", edit && member!.id_last4 ? `${t("checkout.docNumber")} (•••• ${member!.id_last4})` : t("checkout.docNumber"), { className: "input ltr", maxLength: 24 })}
          {text("mobile", `${t("family.mobile")} (${t("common.optional")})`, { className: "input ltr", inputMode: "tel",
            placeholder: member?.mobile ?? "" })}
        </div>
        <p className="small muted"><Icon name="lock" size={16} /> {t("family.docPrivacy")}</p>
        <div className="divider" />
        <h4>{t("family.moneyTitle")}</h4>
        <div className="grid cols-4">
          <Field label={t("family.fundingCol")}>
            <select className="input" value={v.funding} onChange={(e) => set("funding", e.target.value)}>
              {FUNDING.map((k) => <option key={k} value={k}>{t(`family.funding.${k}`)}</option>)}
            </select>
          </Field>
          {text("per_trip_limit", t("family.perTrip"), { className: "input ltr", inputMode: "decimal" })}
          {text("daily_limit", t("family.daily"), { className: "input ltr", inputMode: "decimal" })}
          {text("monthly_limit", t("family.monthly"), { className: "input ltr", inputMode: "decimal" })}
        </div>
      </div>
    </Modal>
  );
}

function RulesModal({ member, onClose }: { member: FamilyMember; onClose: () => void }) {
  const { t, city } = useI18n();
  const rules = useLoad(() => api.get<{ rules: FamilyRule[] }>(`/api/family/members/${member.uid}/rules`));
  const ref = useLoad(() => api.get<{ cities: City[] }>("/api/ref"));
  const lines = useLoad(() => api.get<{ lines: Line[] }>("/api/family/lines"));
  const [type, setType] = useState<"TIME_WINDOW" | "ROUTE" | "LINE">("TIME_WINDOW");
  const [line, setLine] = useState("");
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5]);
  const [from, setFrom] = useState("07:00"), [to, setTo] = useState("15:00");
  const [a, setA] = useState(""), [b, setB] = useState("");
  const [error, setError] = useState<unknown>(null);
  const add = async () => {
    setError(null);
    try {
      await api.post(`/api/family/members/${member.uid}/rules`, type === "TIME_WINDOW"
        ? { rule_type: type, days, start_time: from, end_time: to }
        : type === "LINE" ? { rule_type: type, line_id: Number(line) } : { rule_type: type, from_city: a, to_city: b, both_ways: true });
      rules.reload();
    } catch (e) { setError(e); }
  };
  const del = async (r: FamilyRule) => { await api.del(`/api/family/rules/${r.uid}`); rules.reload(); };
  return (
    <Modal wide title={`${t("family.rulesTitle")} · ${member.full_name}`} onClose={onClose}>
      <div className="stack">
        <p className="muted">{t("family.rulesHint")}</p>
        <ErrorBox error={error} />
        <Loaded state={rules}>{(r) => r.rules.length === 0 ? <Empty icon="rule" title={t("family.noRules")} /> : <RuleList rules={r.rules} onDelete={del} />}</Loaded>
        <div className="divider" />
        <div className="row">
          <label className="check"><input type="radio" checked={type === "TIME_WINDOW"} onChange={() => setType("TIME_WINDOW")} />{t("family.ruleTime")}</label>
          <label className="check"><input type="radio" checked={type === "ROUTE"} onChange={() => setType("ROUTE")} />{t("family.ruleRoute")}</label>
          <label className="check"><input type="radio" checked={type === "LINE"} onChange={() => setType("LINE")} />{t("family.ruleLine")}</label>
        </div>
        {type === "TIME_WINDOW" ? (
          <div className="stack tight">
            <div className="row">{DAYS.map((d) => (
              <label key={d} className="check small"><input type="checkbox" checked={days.includes(d)}
                onChange={(e) => setDays((x) => (e.target.checked ? [...x, d].sort() : x.filter((y) => y !== d)))} />{t(`family.day.${d}`)}</label>
            ))}</div>
            <div className="grid cols-3">
              <Field label={t("family.from")}><input className="input ltr" type="time" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
              <Field label={t("family.to")}><input className="input ltr" type="time" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
            </div>
          </div>
        ) : type === "LINE" ? (
          <div className="stack tight">
            <Field label={t("family.line")}>
              <select className="input" value={line} onChange={(e) => setLine(e.target.value)}>
                <option value="">—</option>
                {(lines.data?.lines ?? []).map((l) => <option key={l.id} value={l.id}>{l.code} · {l.name}{l.city ? ` · ${city(l.city)}` : ""}</option>)}
              </select>
            </Field>
            <p className="small muted">{t("family.lineHint")}</p>
          </div>
        ) : (
          <div className="grid cols-3">
            {[[a, setA, t("family.fromCity")], [b, setB, t("family.toCity")]].map(([val, fn, label], i) => (
              <Field key={i} label={label as string}>
                <select className="input" value={val as string} onChange={(e) => (fn as (s: string) => void)(e.target.value)}>
                  <option value="">—</option>
                  {(ref.data?.cities ?? []).map((c) => <option key={c.code} value={c.code}>{city(c.code)}</option>)}
                </select>
              </Field>
            ))}
          </div>
        )}
        <button className="btn" style={{ alignSelf: "start" }} onClick={add}
                disabled={type === "TIME_WINDOW" ? days.length === 0 || from >= to : type === "LINE" ? !line : !a || !b || a === b}><Icon name="add" />{t("family.addRule")}</button>
      </div>
    </Modal>
  );
}

interface Line { id: number; code: string; name: string; kind: string; city: string | null }

interface Plan { id: number; name: string; operator: string; price: number; period_days: number; passenger_category: string }

function FamilyPasses({ members, account, onDone }: { members: FamilyMember[]; account: number; onDone: () => void }) {
  const { t, money } = useI18n();
  const toast = useToast();
  // passes exist only where the platform runs shuttle subscriptions; ask before calling so the page stays quiet otherwise
  const plans = useLoad(async () => (await api.get<{ enabled: string[] }>("/api/features")).enabled.includes("shuttle_subscriptions")
    ? api.get<{ plans: Plan[] }>("/api/w/subscriptions/plans").catch(() => ({ plans: [] as Plan[] })) : { plans: [] as Plan[] });
  const [plan, setPlan] = useState<number | "">("");
  const [chosen, setChosen] = useState<string[]>([]);
  const [payFrom, setPayFrom] = useState<"HEAD_WALLET" | "FAMILY_ACCOUNT">("HEAD_WALLET");
  const [error, setError] = useState<unknown>(null);
  if (!plans.data || plans.data.plans.length === 0) return null;
  const buy = async () => {
    setError(null);
    try {
      const r = await api.post<{ total: number; discount: number }>("/api/family/passes", { plan_id: plan, member_uids: chosen, pay_from: payFrom, idempotency_key: newKey() });
      toast(t("family.passesBought", { amount: money(r.total) })); setChosen([]); onDone();
    } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <div className="row"><Icon name="card_membership" size={24} /><h3>{t("family.passesTitle")}</h3></div>
      <p className="muted">{t("family.passesHint")}</p>
      <ErrorBox error={error} />
      <div className="grid cols-2">
        <Field label={t("family.plan")}>
          <select className="input" value={plan} onChange={(e) => setPlan(e.target.value ? Number(e.target.value) : "")}>
            <option value="">—</option>
            {plans.data.plans.map((p) => <option key={p.id} value={p.id}>{p.name} · {p.operator} · {money(p.price)}</option>)}
          </select>
        </Field>
        <Field label={t("family.payFrom")}>
          <select className="input" value={payFrom} onChange={(e) => setPayFrom(e.target.value as typeof payFrom)}>
            <option value="HEAD_WALLET">{t("family.funding.HEAD_WALLET")}</option>
            <option value="FAMILY_ACCOUNT">{t("family.account")} ({money(account)})</option>
          </select>
        </Field>
      </div>
      <div className="row">{members.map((m) => (
        <label key={m.uid} className="check small"><input type="checkbox" checked={chosen.includes(m.uid)}
          onChange={(e) => setChosen((x) => (e.target.checked ? [...x, m.uid] : x.filter((y) => y !== m.uid)))} />{m.full_name}</label>
      ))}</div>
      <button className="btn" style={{ alignSelf: "start" }} disabled={!plan || chosen.length === 0} onClick={buy}><Icon name="sell" />{t("family.buyPasses")}</button>
    </div>
  );
}
