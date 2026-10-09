import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

interface Decision { level: number; by: string; decision: "APPROVE" | "REJECT"; note: string | null; at: string }
interface Request {
  uid: string; action: string; amount: number; currency: string; summary: string; status: string; requested_by: string; created_at: string;
  levels: number[]; next_level: number | null; next_level_name: string | null; decisions: Decision[]; can_decide: boolean;
}
interface Level { level?: number; name: string; permission: string; min_amount: number; members: string[] }
interface Policy { action: string; description: string; updated_at: string; levels: Level[] }

const PERMISSIONS = ["ledger.reconcile", "compensation.pay", "payout.run", "payment.fee_policy", "approval.policy"];

/** Money decisions waiting for their approval levels, and the matrix that sets those levels (owner's decision 5). */
export function Approvals() {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const [status, setStatus] = useState("PENDING");
  const state = useLoad(() => api.get<{ requests: Request[] }>("/api/admin/approvals", { status }), [status]);
  const policies = useLoad(() => api.get<{ policies: Policy[]; can_change: boolean }>("/api/admin/approvals/policies"));
  const [editing, setEditing] = useState<Policy | null>(null);
  const [error, setError] = useState<unknown>(null);
  const decide = async (r: Request, approve: boolean) => {
    const note = approve ? null : window.prompt(t("approval.whyReject"));
    if (!approve && (!note || note.trim().length < 3)) return;
    setError(null);
    try {
      const out = await api.post<{ status: string }>(`/api/admin/approvals/${r.uid}/decision`, { decision: approve ? "APPROVE" : "REJECT", note });
      toast(t(`approval.result.${out.status}`));
      state.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <div className="card stack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3 style={{ margin: 0 }}>{t("approval.requests")}</h3>
          <div className="segmented" role="tablist">
            {["PENDING", "APPROVED", "REJECTED", "CANCELLED"].map((s) => (
              <button key={s} role="tab" aria-selected={status === s} className={status === s ? "on" : ""} onClick={() => setStatus(s)}>{t(`approval.status.${s}`)}</button>
            ))}
          </div>
        </div>
        <ErrorBox error={error} />
        <Loaded state={state}>{(d) => d.requests.length === 0 ? <Empty icon="fact_check" title={t("approval.none")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("approval.action")}</th><th>{t("approval.what")}</th><th className="num">{t("pay.amount")}</th>
              <th>{t("approval.asked")}</th><th>{t("approval.progress")}</th><th /></tr></thead>
            <tbody>{d.requests.map((r) => (
              <tr key={r.uid}>
                <td className="small">{dateTime(r.created_at)}</td>
                <td>{t(`approval.kind.${r.action}`)}</td>
                <td className="small">{r.summary}</td>
                <td className="num mono">{money(r.amount)}</td>
                <td className="small">{r.requested_by}</td>
                <td className="small">
                  {r.decisions.map((x) => <div key={x.level}>{t("approval.levelN", { n: x.level })}: {t(`approval.decision.${x.decision}`)} · {x.by}{x.note ? ` · ${x.note}` : ""}</div>)}
                  {r.status === "PENDING" ? <div className="muted">{t("approval.waiting", { level: r.next_level_name ?? "" })}</div> : <Status value={r.status} />}
                </td>
                <td className="num">{r.status === "PENDING" && r.can_decide && <div className="row nowrap" style={{ justifyContent: "flex-end" }}>
                  <button className="btn small" onClick={() => decide(r, true)}><Icon name="check_circle" />{t("approval.approve")}</button>
                  <button className="btn text small" onClick={() => decide(r, false)}>{t("approval.reject")}</button>
                </div>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("approval.matrix")}</h3>
        <p className="small muted" style={{ margin: 0 }}>{t("approval.matrixHint")}</p>
        <Loaded state={policies}>{(d) => (
          <div className="stack">{d.policies.map((p) => (
            <div key={p.action} className="stack" style={{ gap: 4 }}>
              <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
                <strong>{t(`approval.kind.${p.action}`)}</strong>
                {d.can_change && <button className="btn text small" onClick={() => setEditing(p)}><Icon name="edit" />{t("common.edit")}</button>}
              </div>
              {p.levels.length === 0 ? <span className="small muted">{t("approval.noLevels")}</span> : (
                <ol className="small" style={{ margin: 0 }}>{p.levels.map((l) => (
                  <li key={l.level}>{l.name} · <span className="mono ltr">{l.permission}</span>
                    {l.min_amount > 0 && <> · {t("approval.from", { amount: money(l.min_amount) })}</>}
                    {l.members.length > 0 && <> · {t("approval.only", { names: l.members.join(", ") })}</>}</li>
                ))}</ol>
              )}
            </div>
          ))}</div>
        )}</Loaded>
      </div>
      {editing && <PolicyModal p={editing} onClose={() => setEditing(null)} onDone={() => { setEditing(null); policies.reload(); toast(t("pay.saved")); }} />}
    </div>
  );
}

function PolicyModal({ p, onClose, onDone }: { p: Policy; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [levels, setLevels] = useState<Level[]>(p.levels.map((l) => ({ ...l, min_amount: l.min_amount / 100 })));
  const [error, setError] = useState<unknown>(null);
  const set = (i: number, patch: Partial<Level>) => setLevels(levels.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const save = async () => {
    try {
      await api.put(`/api/admin/approvals/policies/${p.action}`, { levels: levels.map((l) => ({
        name: l.name, permission: l.permission, min_amount: Math.round(l.min_amount * 100), members: l.members.filter(Boolean) })) });
      onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t(`approval.kind.${p.action}`)} onClose={onClose} wide
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" onClick={save}>{t("common.save")}</button></>}>
      <p className="small muted">{t("approval.editHint")}</p>
      {levels.map((l, i) => (
        <div key={i} className="grid cols-2" style={{ borderTop: "1px solid var(--line)", paddingTop: 8 }}>
          <Field label={t("approval.levelN", { n: i + 1 })}><input className="input" value={l.name} maxLength={80} onChange={(e) => set(i, { name: e.target.value })} /></Field>
          <Field label={t("approval.permission")}>
            <select value={l.permission} onChange={(e) => set(i, { permission: e.target.value })}>
              {PERMISSIONS.map((x) => <option key={x} value={x}>{t(`approval.perm.${x.replace(".", "_")}`)}</option>)}
            </select>
          </Field>
          <Field label={t("approval.minAmount")}><input className="input ltr" type="number" min={0} value={l.min_amount} onChange={(e) => set(i, { min_amount: Number(e.target.value) })} /></Field>
          <Field label={t("approval.members")} hint={t("approval.membersHint")}>
            <input className="input ltr" value={l.members.join(", ")} onChange={(e) => set(i, { members: e.target.value.split(",").map((x) => x.trim()) })} />
          </Field>
          <div><button className="btn text small" onClick={() => setLevels(levels.filter((_, j) => j !== i))}><Icon name="delete" />{t("approval.removeLevel")}</button></div>
        </div>
      ))}
      {levels.length < 5 && <button className="btn text" onClick={() => setLevels([...levels, { name: "", permission: PERMISSIONS[0], min_amount: 0, members: [] }])}>
        <Icon name="add" />{t("approval.addLevel")}</button>}
      <ErrorBox error={error} />
    </Modal>
  );
}

interface Rule {
  uid: string; label: string; provider: string | null; currency: string | null; customer: string | null; customer_uid: string | null;
  kind: string; pct: number; fixed_amount: number; min_fee: number | null; max_fee: number | null; round_to: number; rounding: string;
  borne_by: string; valid_from: string; valid_to: string | null; status: string;
}
const PROVIDERS = ["CARD", "EWALLET", "INSTALLMENT", "FINANCING"];

/** Payment fees by way of paying, currency, customer and period (owner's decision 4). */
export function FeeRules() {
  const { t, money, date } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ rules: Rule[] }>("/api/admin/payments/fee-rules"));
  const [editing, setEditing] = useState<Rule | "new" | null>(null);
  return (
    <div className="card stack">
      <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
        <h3 style={{ margin: 0 }}>{t("feeRule.title")}</h3>
        <button className="btn small" onClick={() => setEditing("new")}><Icon name="add" />{t("feeRule.add")}</button>
      </div>
      <p className="small muted" style={{ margin: 0 }}>{t("feeRule.hint")}</p>
      <Loaded state={state}>{(d) => d.rules.length === 0 ? <Empty icon="payments" title={t("feeRule.none")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("feeRule.label")}</th><th>{t("pay.method")}</th><th>{t("feeRule.customer")}</th><th>{t("pay.fee")}</th><th>{t("feeRule.period")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{d.rules.map((r) => (
            <tr key={r.uid}>
              <td><strong>{r.label}</strong><div className="small muted">{t(`feeRule.borne.${r.borne_by}`)}</div></td>
              <td className="small">{r.provider ? t(`pay.provider.${r.provider}`) : t("feeRule.any")} · {r.currency ?? t("feeRule.anyCurrency")}</td>
              <td className="small">{r.customer ?? t("feeRule.everyone")}</td>
              <td className="small">{r.kind === "NONE" ? t("feeRule.kind.NONE") : [r.pct > 0 ? `${r.pct}%` : "", r.fixed_amount > 0 ? money(r.fixed_amount) : ""].filter(Boolean).join(" + ")}</td>
              <td className="small">{date(r.valid_from)}{r.valid_to ? ` – ${date(r.valid_to)}` : ""}</td>
              <td><Status value={r.status} /></td>
              <td className="num"><button className="btn text small" onClick={() => setEditing(r)}><Icon name="edit" />{t("common.edit")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {editing && <RuleModal rule={editing === "new" ? null : editing} onClose={() => setEditing(null)}
        onDone={() => { setEditing(null); state.reload(); toast(t("pay.saved")); }} />}
    </div>
  );
}

function RuleModal({ rule, onClose, onDone }: { rule: Rule | null; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({
    label: rule?.label ?? "", provider: rule?.provider ?? "", currency: rule?.currency ?? "SYP", customer_uid: rule?.customer_uid ?? "",
    kind: rule?.kind ?? "PERCENT", pct: rule?.pct ?? 0, fixed: (rule?.fixed_amount ?? 0) / 100, min: rule?.min_fee != null ? rule.min_fee / 100 : "",
    max: rule?.max_fee != null ? rule.max_fee / 100 : "", round_to: (rule?.round_to ?? 1) / 100, rounding: rule?.rounding ?? "HALF_UP",
    borne_by: rule?.borne_by ?? "PAYER", valid_from: rule?.valid_from?.slice(0, 10) ?? "", valid_to: rule?.valid_to?.slice(0, 10) ?? "",
    status: rule?.status ?? "ACTIVE",
  });
  const [error, setError] = useState<unknown>(null);
  const minor = (v: number | string) => (v === "" ? null : Math.round(Number(v) * 100));
  const save = async () => {
    const body = {
      label: f.label, provider: f.provider || null, currency: f.currency || null, customer_uid: f.customer_uid || null, kind: f.kind,
      pct: f.kind === "PERCENT" || f.kind === "PERCENT_PLUS_FIXED" ? f.pct : 0,
      fixed_amount: f.kind === "FIXED" || f.kind === "PERCENT_PLUS_FIXED" ? minor(f.fixed) ?? 0 : 0,
      min_fee: minor(f.min), max_fee: minor(f.max), round_to: Math.max(1, Math.round(Number(f.round_to) * 100)), rounding: f.rounding,
      borne_by: f.borne_by, valid_from: f.valid_from ? `${f.valid_from}T00:00:00Z` : null, valid_to: f.valid_to ? `${f.valid_to}T00:00:00Z` : null,
      status: f.status,
    };
    try {
      if (rule) await api.put(`/api/admin/payments/fee-rules/${rule.uid}`, body);
      else await api.post("/api/admin/payments/fee-rules", body);
      onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={rule ? rule.label : t("feeRule.add")} onClose={onClose} wide
      actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" disabled={f.label.trim().length < 3} onClick={save}>{t("common.save")}</button></>}>
      <div className="grid cols-3">
        <Field label={t("feeRule.label")}><input className="input" value={f.label} maxLength={120} onChange={(e) => setF({ ...f, label: e.target.value })} /></Field>
        <Field label={t("pay.method")}>
          <select value={f.provider} onChange={(e) => setF({ ...f, provider: e.target.value })}>
            <option value="">{t("feeRule.any")}</option>
            {PROVIDERS.map((p) => <option key={p} value={p}>{t(`pay.provider.${p}`)}</option>)}
          </select>
        </Field>
        <Field label={t("feeRule.currency")}><input className="input ltr" value={f.currency} maxLength={3} onChange={(e) => setF({ ...f, currency: e.target.value.toUpperCase() })} /></Field>
        <Field label={t("feeRule.customerUid")} hint={t("feeRule.customerHint")}><input className="input ltr" value={f.customer_uid} onChange={(e) => setF({ ...f, customer_uid: e.target.value.trim() })} /></Field>
        <Field label={t("feeRule.kindLabel")}>
          <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}>
            {["PERCENT", "FIXED", "PERCENT_PLUS_FIXED", "NONE"].map((k) => <option key={k} value={k}>{t(`feeRule.kind.${k}`)}</option>)}
          </select>
        </Field>
        <Field label={t("feeRule.borneBy")}>
          <select value={f.borne_by} onChange={(e) => setF({ ...f, borne_by: e.target.value })}>
            <option value="PAYER">{t("feeRule.borne.PAYER")}</option><option value="PLATFORM">{t("feeRule.borne.PLATFORM")}</option>
          </select>
        </Field>
        {(f.kind === "PERCENT" || f.kind === "PERCENT_PLUS_FIXED") &&
          <Field label={t("pay.feePct")}><input className="input ltr" type="number" step={0.1} min={0} max={20} value={f.pct} onChange={(e) => setF({ ...f, pct: Number(e.target.value) })} /></Field>}
        {(f.kind === "FIXED" || f.kind === "PERCENT_PLUS_FIXED") &&
          <Field label={t("feeRule.fixed")}><input className="input ltr" type="number" min={0} value={f.fixed} onChange={(e) => setF({ ...f, fixed: Number(e.target.value) })} /></Field>}
        <Field label={t("feeRule.min")}><input className="input ltr" type="number" min={0} value={f.min} onChange={(e) => setF({ ...f, min: e.target.value })} /></Field>
        <Field label={t("feeRule.max")}><input className="input ltr" type="number" min={0} value={f.max} onChange={(e) => setF({ ...f, max: e.target.value })} /></Field>
        <Field label={t("feeRule.roundTo")}><input className="input ltr" type="number" min={0.01} step={0.01} value={f.round_to} onChange={(e) => setF({ ...f, round_to: Number(e.target.value) })} /></Field>
        <Field label={t("feeRule.rounding")}>
          <select value={f.rounding} onChange={(e) => setF({ ...f, rounding: e.target.value })}>
            {["HALF_UP", "UP", "DOWN"].map((k) => <option key={k} value={k}>{t(`feeRule.round.${k}`)}</option>)}
          </select>
        </Field>
        <Field label={t("feeRule.from")}><input className="input ltr" type="date" value={f.valid_from} onChange={(e) => setF({ ...f, valid_from: e.target.value })} /></Field>
        <Field label={t("feeRule.to")}><input className="input ltr" type="date" value={f.valid_to} onChange={(e) => setF({ ...f, valid_to: e.target.value })} /></Field>
        <Field label={t("common.status")}>
          <select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}>
            <option value="ACTIVE">{t("pay.active")}</option><option value="INACTIVE">{t("pay.inactive")}</option>
          </select>
        </Field>
      </div>
      <ErrorBox error={error} />
    </Modal>
  );
}
