import { useState } from "react";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";
import { Approvals, FeeRules } from "./Approvals";

interface Provider {
  code: string; name: string; kind: string; adapter: string; status: string; min_amount: number; max_amount: number; fee_pct: number;
  fee_borne_by: string; config: Record<string, string | number>; secret_configured: boolean; simulated: boolean;
}
interface Line { id: number; value_date: string; amount: number; currency: string; reference: string | null; payer: string | null; bank_ref: string; status: string; note: string | null; virtual_ref: string | null; account_label: string }
interface Awaiting { virtual_ref: string; amount: number; created_at: string; expires_at: string | null; payer: string | null }
interface Pay { uid: string; created_at: string; method: string; status: string; amount: number; refunded_amount: number; provider: string; provider_ref: string | null; card_last4: string | null; payer_mobile_mask: string | null; payer: string | null }

/** Finance: payment methods, bank statements matched to transfer references, and refunds to the card or e-wallet. */
export function PaymentsDesk() {
  const { t } = useI18n();
  const { can } = useAuth();
  type Tab = "providers" | "bank" | "payments" | "options" | "cash" | "approvals" | "fees";
  const [tab, setTab] = useState<Tab>(can("ledger.reconcile") ? "bank" : can("payment.methods") ? "options" : "providers");
  const tabs: Tab[] = ["bank", "approvals", "payments", "providers", "fees", "options", "cash"];
  return (
    <div className="stack">
      <PageHead title={t("pay.desk")} sub={t("pay.deskSub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start", flexWrap: "wrap" }}>
        {tabs.map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`pay.tab.${v}`)}</button>
        ))}
      </div>
      {tab === "providers" && <Providers />}
      {tab === "bank" && <BankStatements />}
      {tab === "payments" && <RecentPayments />}
      {tab === "options" && <PaymentOptions />}
      {tab === "cash" && <CounterCash />}
      {tab === "approvals" && <Approvals />}
      {tab === "fees" && <FeeRules />}
    </div>
  );
}

function Providers() {
  const { t, money } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ providers: Provider[]; sandbox: boolean }>("/api/admin/payments/providers"));
  const [edit, setEdit] = useState<Provider | null>(null);
  return (
    <div className="card stack">
      <Loaded state={state}>{(d) => (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("pay.method")}</th><th>{t("pay.limitsCol")}</th><th>{t("pay.fee")}</th><th>{t("pay.connection")}</th><th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{d.providers.map((p) => (
            <tr key={p.code}>
              <td><strong>{t(`pay.provider.${p.code}`)}</strong><div className="small muted">{t(`pay.hint.${p.adapter}`)}</div></td>
              <td className="small" style={{ whiteSpace: "nowrap" }}>{money(p.min_amount)} – {money(p.max_amount)}</td>
              <td className="small">{p.fee_pct}% · {t(`pay.borne.${p.fee_borne_by}`)}</td>
              <td className="small">{p.adapter === "CASH_AGENT" ? t("pay.conn.agencies") : p.adapter === "BANK_TRANSFER" ? (p.config.iban ? <span className="mono ltr">{String(p.config.iban)}</span> : t("pay.conn.noIban"))
                  : p.simulated || p.adapter === "SANDBOX" ? <span className="chip wheat">{t("pay.conn.simulator")}</span> : p.secret_configured ? <span className="chip green">{t("pay.conn.connected")}</span> : <span className="chip red">{t("pay.conn.missing")}</span>}</td>
              <td><Status value={p.status} /></td>
              <td className="num"><button className="btn text small" onClick={() => setEdit(p)}><Icon name="edit" />{t("common.edit")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      <p className="small muted">{t("pay.secretsNote")}</p>
      {edit && <ProviderModal p={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); state.reload(); toast(t("pay.saved")); }} />}
    </div>
  );
}

function ProviderModal({ p, onClose, onDone }: { p: Provider; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [f, setF] = useState({ status: p.status, min: p.min_amount / 100, max: p.max_amount / 100, fee: p.fee_pct, borne: p.fee_borne_by });
  const fields = p.adapter === "BANK_TRANSFER" ? ["bank_name", "account_name", "iban", "valid_days"]
    : ["HOSTED_CARD", "INSTALLMENT", "FINANCING"].includes(p.adapter) ? ["base_url", "merchant_id"]
    : p.adapter === "PARTNER_WALLET" ? ["base_url", "merchant_code"] : [];
  const [cfg, setCfg] = useState<Record<string, string>>(Object.fromEntries(fields.map((k) => [k, String(p.config[k] ?? "")])));
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try {
      const config = Object.fromEntries(Object.entries(cfg).map(([k, v]) => [k, k === "valid_days" ? Number(v || 3) : v]));
      await api.put(`/api/admin/payments/providers/${p.code}`, { status: f.status, min_amount: Math.round(f.min * 100), max_amount: Math.round(f.max * 100),
        fee_pct: f.fee, fee_borne_by: f.borne, config });
      onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t(`pay.provider.${p.code}`)} onClose={onClose} wide actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" onClick={save}>{t("common.save")}</button></>}>
      <div className="grid cols-3">
        <Field label={t("common.status")}><select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })}><option value="ACTIVE">{t("pay.active")}</option><option value="INACTIVE">{t("pay.inactive")}</option></select></Field>
        <Field label={t("pay.min")}><input className="input ltr" type="number" value={f.min} onChange={(e) => setF({ ...f, min: Number(e.target.value) })} /></Field>
        <Field label={t("pay.max")}><input className="input ltr" type="number" value={f.max} onChange={(e) => setF({ ...f, max: Number(e.target.value) })} /></Field>
        <Field label={t("pay.feePct")}><input className="input ltr" type="number" step={0.1} min={0} max={10} value={f.fee} onChange={(e) => setF({ ...f, fee: Number(e.target.value) })} /></Field>
        <Field label={t("pay.feeBorne")}><select value={f.borne} onChange={(e) => setF({ ...f, borne: e.target.value })}><option value="PLATFORM">{t("pay.borne.PLATFORM")}</option><option value="PAYER">{t("pay.borne.PAYER")}</option></select></Field>
      </div>
      {fields.length > 0 && <div className="grid cols-2">{fields.map((k) => (
        <Field key={k} label={t(`pay.cfg.${k}`)}><input className={`input${["base_url", "iban", "merchant_id", "merchant_code"].includes(k) ? " ltr" : ""}`} value={cfg[k]} onChange={(e) => setCfg({ ...cfg, [k]: e.target.value })} /></Field>
      ))}</div>}
      <ErrorBox error={error} />
    </Modal>
  );
}

function BankStatements() {
  const { t, money, date, dateTime } = useI18n();
  const toast = useToast();
  const [status, setStatus] = useState("UNMATCHED");
  const state = useLoad(() => api.get<{ lines: Line[]; awaiting: Awaiting[] }>("/api/admin/payments/statement-lines", { status }), [status]);
  const [file, setFile] = useState<File | null>(null);
  const [label, setLabel] = useState(t("pay.mainAccount"));
  const [mark, setMark] = useState(".");
  const [error, setError] = useState<unknown>(null);
  const [matching, setMatching] = useState<Line | null>(null);
  const upload = async () => {
    if (!file) return;
    setError(null);
    const form = new FormData(); form.append("file", file); form.append("account_label", label); form.append("decimal_mark", mark);
    try {
      const r = await api.upload<{ lines: number; matched: number; awaiting_approval: number; unmatched: number }>("/api/admin/payments/statements", form);
      toast(t("pay.importedApproval", { lines: r.lines, matched: r.matched, awaiting: r.awaiting_approval })); setFile(null); state.reload();
    } catch (e) { setError(e); }
  };
  const ignore = async (l: Line) => {
    const note = window.prompt(t("pay.ignoreWhy"));
    if (!note || note.length < 5) return;
    try { await api.post(`/api/admin/payments/statement-lines/${l.id}/ignore`, { note }); state.reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("pay.importTitle")}</h3>
        <p className="small muted" style={{ margin: 0 }}>{t("pay.importHint")}</p>
        <div className="row" style={{ gap: 10, flexWrap: "wrap", alignItems: "flex-end" }}>
          <Field label={t("pay.account")}><input className="input" value={label} onChange={(e) => setLabel(e.target.value)} /></Field>
          <Field label={t("pay.decimalMark")}><select className="input" value={mark} onChange={(e) => setMark(e.target.value)}>
            <option value=".">{t("pay.decimalDot")}</option><option value=",">{t("pay.decimalComma")}</option>
          </select></Field>
          <Field label={t("pay.file")}><input type="file" accept=".csv,text/csv" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></Field>
          <button className="btn" disabled={!file} onClick={upload}><Icon name="download" />{t("pay.import")}</button>
        </div>
        <ErrorBox error={error} />
      </div>
      <div className="card stack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3 style={{ margin: 0 }}>{t("pay.lines")}</h3>
          <div className="segmented" role="tablist">
            {["UNMATCHED", "PROPOSED", "MATCHED", "IGNORED"].map((s) => <button key={s} role="tab" aria-selected={status === s} className={status === s ? "on" : ""} onClick={() => setStatus(s)}>{t(`pay.line.${s}`)}</button>)}
          </div>
        </div>
        <Loaded state={state}>{(d) => d.lines.length === 0 ? <Empty icon="account_balance" title={t("pay.noLines")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("pay.date")}</th><th className="num">{t("pay.amount")}</th><th>{t("pay.description")}</th><th>{t("pay.payer")}</th><th>{t("pay.bankRef")}</th><th>{t("pay.result")}</th><th /></tr></thead>
            <tbody>{d.lines.map((l) => (
              <tr key={l.id}>
                <td className="small">{date(`${l.value_date}T12:00:00Z`)}</td>
                <td className="num mono">{money(l.amount)}</td>
                <td className="small">{l.reference}</td>
                <td className="small">{l.payer}</td>
                <td className="small mono">{l.bank_ref}</td>
                <td className="small">{l.virtual_ref ? <span className="mono ltr">{l.virtual_ref}</span> : l.note ? t(`pay.note.${l.note}`) : ""}</td>
                <td className="num">{l.status === "UNMATCHED" && <div className="row nowrap" style={{ justifyContent: "flex-end" }}>
                  <button className="btn small" onClick={() => setMatching(l)}>{t("pay.match")}</button>
                  <button className="btn text small" onClick={() => ignore(l)}>{t("pay.ignore")}</button>
                </div>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      <Loaded state={state}>{(d) => (
        <div className="card stack">
          <h3 style={{ margin: 0 }}>{t("pay.awaiting", { n: d.awaiting.length })}</h3>
          {d.awaiting.length === 0 ? <Empty icon="schedule" title={t("pay.noAwaiting")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("pay.reference")}</th><th className="num">{t("pay.amount")}</th><th>{t("pay.payer")}</th><th>{t("pay.validUntil")}</th></tr></thead>
              <tbody>{d.awaiting.map((a) => <tr key={a.virtual_ref}><td className="mono ltr">{a.virtual_ref}</td><td className="num mono">{money(a.amount)}</td><td>{a.payer}</td><td className="small">{a.expires_at ? dateTime(a.expires_at) : ""}</td></tr>)}</tbody>
            </table></div>
          )}
        </div>
      )}</Loaded>
      {matching && <MatchModal line={matching} onClose={() => setMatching(null)} onDone={() => { setMatching(null); state.reload(); toast(t("pay.matched")); }} />}
    </div>
  );
}

function MatchModal({ line, onClose, onDone }: { line: Line; onClose: () => void; onDone: () => void }) {
  const { t, money } = useI18n();
  const [reference, setReference] = useState("");
  const [credit, setCredit] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try { await api.post(`/api/admin/payments/statement-lines/${line.id}/match`, { reference, credit_received: credit }); onDone(); } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("pay.matchTitle")} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn" disabled={reference.length < 5} onClick={save}>{t("pay.match")}</button></>}>
      <p>{money(line.amount)} · <span className="small muted">{line.reference}</span></p>
      <Field label={t("pay.reference")}><input className="input ltr mono" value={reference} placeholder="MSL…" onChange={(e) => setReference(e.target.value.toUpperCase())} /></Field>
      <label className="row small" style={{ gap: 8 }}><input type="checkbox" checked={credit} onChange={(e) => setCredit(e.target.checked)} />{t("pay.creditReceived")}</label>
      <ErrorBox error={error} />
    </Modal>
  );
}

function RecentPayments() {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ payments: Pay[] }>("/api/admin/payments/recent"));
  const [refunding, setRefunding] = useState<Pay | null>(null);
  return (
    <div className="card stack">
      <Loaded state={state}>{(d) => d.payments.length === 0 ? <Empty icon="payments" title={t("common.noData")} /> : (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("common.when")}</th><th>{t("pay.payer")}</th><th>{t("pay.method")}</th><th className="num">{t("pay.amount")}</th><th>{t("common.status")}</th><th>{t("pay.providerRef")}</th><th /></tr></thead>
          <tbody>{d.payments.map((p) => (
            <tr key={p.uid}>
              <td className="small">{dateTime(p.created_at)}</td>
              <td>{p.payer}<div className="small muted ltr" style={{ display: "block" }}>{p.payer_mobile_mask ?? (p.card_last4 ? `•••• ${p.card_last4}` : "")}</div></td>
              <td>{t(`pay.provider.${p.provider}`)}</td>
              <td className="num mono">{money(p.amount)}{p.refunded_amount > 0 && <div className="small muted">−{money(p.refunded_amount)}</div>}</td>
              <td><Status value={p.status} /></td>
              <td className="small mono">{p.provider_ref}</td>
              <td className="num">{p.status === "SUCCESS" && (p.method === "CARD" || p.method === "E_WALLET") && p.provider !== "SANDBOX" && <button className="btn text small" onClick={() => setRefunding(p)}>{t("pay.refund")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {refunding && <RefundModal p={refunding} onClose={() => setRefunding(null)} onDone={(stage) => { setRefunding(null); state.reload(); toast(t(`pay.refundStage.${stage}`)); }} />}
    </div>
  );
}

function RefundModal({ p, onClose, onDone }: { p: Pay; onClose: () => void; onDone: (stage: string) => void }) {
  const { t, money } = useI18n();
  const left = p.amount - p.refunded_amount;
  const [amount, setAmount] = useState(left / 100);
  const [reason, setReason] = useState("");
  const [key] = useState(newKey);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try {
      const r = await api.post<{ status: string; stage: string }>(`/api/admin/payments/${p.uid}/refund`, { amount: Math.round(amount * 100), reason, idempotency_key: key });
      onDone(r.stage);
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t("pay.refundTitle")} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button><button className="btn danger" disabled={reason.length < 5 || amount <= 0} onClick={save}>{t("pay.refund")}</button></>}>
      <p className="small muted">{t("pay.refundHint", { left: money(left) })}</p>
      <Field label={t("pay.amount")}><input className="input ltr" type="number" max={left / 100} value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></Field>
      <Field label={t("pay.reason")}><input className="input" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} /></Field>
      <ErrorBox error={error} />
    </Modal>
  );
}

/** Agency counter: cash received from a passenger credited to their wallet from the agency's prepaid balance. */
export function AgencyTopup() {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const list = useLoad(() => api.get<{ topups: { uid: string; amount: number; receipt: string; mobile: string; created_at: string }[] }>("/api/agency/wallet-topups"));
  const [mobile, setMobile] = useState("");
  const [amount, setAmount] = useState(100000);
  const [key, setKey] = useState(newKey);
  const [error, setError] = useState<unknown>(null);
  const [last, setLast] = useState<{ receipt: string; passenger: string; amount: number } | null>(null);
  const save = async () => {
    setError(null);
    try {
      const r = await api.post<{ receipt: string; passenger: string; amount: number }>("/api/agency/wallet-topups", { mobile, amount: amount * 100, idempotency_key: key });
      setLast(r); setMobile(""); setKey(newKey()); toast(t("pay.agencyDone")); list.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <PageHead title={t("pay.agencyTitle")} sub={t("pay.agencySub")} />
      <div className="card stack" style={{ maxWidth: 560 }}>
        <Field label={t("pay.mobile")} hint={t("pay.agencyMobileHint")}><input className="input ltr" inputMode="tel" placeholder="+9639…" value={mobile} onChange={(e) => setMobile(e.target.value.trim())} /></Field>
        <Field label={t("wallet.amount")}><input className="input ltr" type="number" step={1000} value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></Field>
        <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!/^\+?\d{8,15}$/.test(mobile) || amount <= 0} onClick={save}><Icon name="add" />{t("pay.agencyCredit", { amount: money(amount * 100) })}</button>
        <ErrorBox error={error} />
        {last && <div className="alert ok"><Icon name="check_circle" />{t("pay.agencyReceipt", { receipt: last.receipt, name: last.passenger, amount: money(last.amount) })}</div>}
      </div>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("pay.agencyRecent")}</h3>
        <Loaded state={list}>{(d) => d.topups.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("pay.receipt")}</th><th>{t("pay.mobile")}</th><th className="num">{t("pay.amount")}</th></tr></thead>
            <tbody>{d.topups.map((x) => <tr key={x.uid}><td className="small">{dateTime(x.created_at)}</td><td className="mono">{x.receipt}</td><td className="ltr small">{x.mobile}</td><td className="num mono">{money(x.amount)}</td></tr>)}</tbody>
          </table></div>
        )}</Loaded>
      </div>
    </div>
  );
}


// ------------------------------------------------------------------ ways of paying a booking (1056)
interface Method {
  code: string; enabled: boolean; channels: string[]; min_amount: number; max_amount: number | null; provider_adapter: string | null;
  config: Record<string, number | string[]>; reason: string | null; updated_at: string; allowed_channels: string[]; settings: string[];
  providers: { code: string; name: string; adapter: string; status: string }[];
}

function PaymentOptions() {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ methods: Method[]; trip_types: { code: string; name: string }[]; can_change: boolean }>("/api/admin/payment-methods"));
  const [edit, setEdit] = useState<Method | null>(null);
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}><Icon name="shield" size={16} /> {t("cashdesk.methodsHint")}</p>
      <Loaded state={state}>{(d) => (
        <div className="table-wrap" tabIndex={0}><table className="table">
          <thead><tr><th>{t("cashdesk.methods")}</th><th>{t("cashdesk.channels")}</th><th>{t("pay.limitsCol")}</th><th>{t("cashdesk.providers")}</th>
            <th>{t("common.status")}</th><th /></tr></thead>
          <tbody>{d.methods.map((m) => (
            <tr key={m.code}>
              <td><strong>{t(`opt.name.${m.code}`)}</strong>
                {m.reason && <div className="small muted">{m.reason} · {dateTime(m.updated_at)}</div>}</td>
              <td className="small">{m.channels.map((c) => t(`cashdesk.channel.${c}`)).join(" · ")}</td>
              <td className="small" style={{ whiteSpace: "nowrap" }}>{money(m.min_amount)} – {m.max_amount != null ? money(m.max_amount) : "∞"}</td>
              <td className="small">{m.provider_adapter == null ? "—" : m.providers.length === 0 ? t("cashdesk.noProvider")
                : m.providers.map((p) => <div key={p.code}>{t(`pay.provider.${p.code}`)} <Status value={p.status} /></div>)}</td>
              <td>{m.enabled ? <span className="chip green">{t("cashdesk.open")}</span> : <span className="chip outline">{t("cashdesk.closed")}</span>}</td>
              <td className="num">{d.can_change && <button className="btn text small" onClick={() => setEdit(m)}><Icon name="edit" />{t("cashdesk.edit")}</button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {edit && state.data && <MethodModal m={edit} tripTypes={state.data.trip_types} onClose={() => setEdit(null)}
                                          onDone={() => { setEdit(null); toast(t("cashdesk.saved")); state.reload(); }} />}
    </div>
  );
}

function MethodModal({ m, tripTypes, onClose, onDone }: { m: Method; tripTypes: { code: string; name: string }[]; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [enabled, setEnabled] = useState(m.enabled);
  const [channels, setChannels] = useState<string[]>(m.channels);
  const [min, setMin] = useState(m.min_amount / 100);
  const [max, setMax] = useState(m.max_amount != null ? String(m.max_amount / 100) : "");
  const [cfg, setCfg] = useState<Record<string, number | string[]>>(Object.fromEntries(m.settings.map((k) => [k, m.config[k] ?? (k === "trip_types" ? [] : 0)])));
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const money = (k: string) => k === "default_credit_limit";
  const save = async () => {
    try {
      const config = Object.fromEntries(Object.entries(cfg).map(([k, v]) => [k, Array.isArray(v) ? v : money(k) ? Math.round(Number(v) * 100) : Number(v)]));
      await api.put(`/api/admin/payment-methods/${m.code}`, { enabled, channels, min_amount: Math.round(min * 100),
        max_amount: max.trim() ? Math.round(Number(max) * 100) : null, config, reason: reason.trim() });
      onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={t(`opt.name.${m.code}`)} onClose={onClose} wide actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={reason.trim().length < 5 || channels.length === 0} onClick={save}>{t("common.save")}</button></>}>
      <label className="check"><input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />{t("cashdesk.open")}</label>
      <Field label={t("cashdesk.channels")}>
        <div className="row">{m.allowed_channels.map((c) => (
          <label key={c} className="check small"><input type="checkbox" checked={channels.includes(c)}
            onChange={(e) => setChannels((x) => e.target.checked ? [...x, c] : x.filter((y) => y !== c))} />{t(`cashdesk.channel.${c}`)}</label>
        ))}</div>
      </Field>
      <div className="grid cols-2">
        <Field label={t("cashdesk.minAmount")}><input className="input ltr" type="number" min={0} value={min} onChange={(e) => setMin(Number(e.target.value))} /></Field>
        <Field label={t("cashdesk.maxAmount")}><input className="input ltr" type="number" min={0} value={max} onChange={(e) => setMax(e.target.value)} /></Field>
        {m.settings.filter((k) => k !== "trip_types").map((k) => (
          <Field key={k} label={t(`cashdesk.set.${k}`)}>
            <input className="input ltr" type="number" min={0} value={money(k) ? Number(cfg[k]) / 100 : Number(cfg[k])}
                   onChange={(e) => setCfg({ ...cfg, [k]: money(k) ? Number(e.target.value) * 100 : Number(e.target.value) })} />
          </Field>
        ))}
      </div>
      {m.settings.includes("trip_types") && (
        <Field label={t("cashdesk.set.trip_types")}>
          <div className="row">{tripTypes.map((k) => {
            const list = (cfg.trip_types as string[]) ?? [];
            return (
              <label key={k.code} className="check small"><input type="checkbox" checked={list.includes(k.code)}
                onChange={(e) => setCfg({ ...cfg, trip_types: e.target.checked ? [...list, k.code] : list.filter((x) => x !== k.code) })} />{t(`tripType.${k.code}`)}</label>
            );
          })}</div>
        </Field>
      )}
      <Field label={t("cashdesk.reason")}><input className="input" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} /></Field>
      <ErrorBox error={error} />
    </Modal>
  );
}

// ------------------------------------------------------------------ cash held by carriers, limits and remittances (6.5)
interface Position {
  company_id: number; name: string; owed: number; limit_amount: number; own_limit: boolean; pending: number; last_remitted_at: string | null;
  days_0_7: number; days_8_30: number; days_31_60: number; days_61_90: number; days_over_90: number; overdue: number; oldest_unpaid_at: string | null;
}
interface Remittance {
  id: number; company_id: number; carrier: string; amount: number; method: string; ref: string | null; status: string; note: string | null;
  created_at: string; confirmed_at: string | null; recorded_by_name: string | null; confirmed_by_name: string | null; mine: boolean;
}

function CounterCash() {
  const { t, money, dateTime } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const pos = useLoad(() => api.get<{ positions: Position[] }>("/api/admin/cash/positions"));
  const rem = useLoad(() => api.get<{ remittances: Remittance[] }>("/api/admin/cash/remittances"));
  const [limitFor, setLimitFor] = useState<Position | null>(null);
  const [remitFor, setRemitFor] = useState<Position | null>(null);
  const [error, setError] = useState<unknown>(null);
  const reload = () => { pos.reload(); rem.reload(); };
  const decide = async (r: Remittance, approve: boolean) => {
    setError(null);
    try { await api.post(`/api/admin/cash/remittances/${r.id}/decide`, { approve }); toast(t("cashdesk.saved")); reload(); } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="card stack">
        <h3>{t("cashdesk.positions")}</h3>
        <Loaded state={pos}>{({ positions }) => (
          <>
            <div className="grid cols-4">
              <Stat icon="account_balance" label={t("cashdesk.owed")} value={money(positions.reduce((a, p) => a + p.owed, 0))} tone="wheat" />
              <Stat icon="schedule" label={t("cashdesk.overdue")} value={money(positions.reduce((a, p) => a + p.overdue, 0))} tone="red" />
              <Stat icon="hourglass_top" label={t("cashdesk.pending")} value={money(positions.reduce((a, p) => a + p.pending, 0))} tone="blue" />
              <Stat icon="warning" label={t("cashdesk.atLimit")} value={positions.filter((p) => p.owed >= p.limit_amount && p.limit_amount > 0).length} tone="red" />
            </div>
            {positions.length === 0 ? <Empty icon="point_of_sale" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
                <thead><tr><th>{t("cashdesk.carrier")}</th><th className="num">{t("cashdesk.owed")}</th>
                  <th className="num">{t("cashdesk.overdue")}</th><th>{t("cashdesk.oldest")}</th><th className="num">{t("cashdesk.limit")}</th>
                  <th className="num">{t("cashdesk.pending")}</th><th>{t("cashdesk.lastRemitted")}</th><th /></tr></thead>
                <tbody>{positions.map((p) => (
                  <tr key={p.company_id}>
                    <td>{p.name}</td>
                    <td className="num" style={{ color: p.limit_amount > 0 && p.owed >= p.limit_amount ? "var(--error)" : undefined }}>{money(p.owed)}</td>
                    <td className="num" style={{ color: p.overdue > 0 ? "var(--error)" : undefined }}>
                      {p.overdue ? money(p.overdue) : "—"}
                      {p.days_over_90 > 0 && <div className="small muted">{t("cashdesk.over90")}: {money(p.days_over_90)}</div>}
                    </td>
                    <td className="small">{p.oldest_unpaid_at ? dateTime(p.oldest_unpaid_at) : "—"}</td>
                    <td className="num">{money(p.limit_amount)}<div className="small muted">{t(p.own_limit ? "cashdesk.ownLimit" : "cashdesk.defaultLimit")}</div></td>
                    <td className="num">{p.pending ? money(p.pending) : "—"}</td>
                    <td className="small">{p.last_remitted_at ? dateTime(p.last_remitted_at) : "—"}</td>
                    <td className="num" style={{ whiteSpace: "nowrap" }}>
                      {can("cash.credit_limit") && <button className="btn text small" onClick={() => setLimitFor(p)}><Icon name="price_check" />{t("cashdesk.setLimit")}</button>}
                      {can("cash.remittance") && p.owed > p.pending && <button className="btn text small" onClick={() => setRemitFor(p)}><Icon name="savings" />{t("cashdesk.record")}</button>}
                    </td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3>{t("cashdesk.remittances")}</h3>
        <Loaded state={rem}>{({ remittances }) => remittances.length === 0 ? <Empty icon="savings" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.date")}</th><th>{t("cashdesk.carrier")}</th><th className="num">{t("cashdesk.amount")}</th><th>{t("cashdesk.how")}</th>
              <th>{t("cashdesk.recordedBy")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{remittances.map((r) => (
              <tr key={r.id}>
                <td className="small">{dateTime(r.created_at)}</td>
                <td>{r.carrier}</td>
                <td className="num">{money(r.amount)}</td>
                <td className="small">{t(`cashdesk.rm.${r.method}`)}{r.ref && <div className="mono small">{r.ref}</div>}</td>
                <td className="small">{r.recorded_by_name ?? "—"}{r.confirmed_by_name && <div className="muted">{t("cashdesk.decidedBy")}: {r.confirmed_by_name}</div>}</td>
                <td><Status value={r.status} /></td>
                <td className="num" style={{ whiteSpace: "nowrap" }}>{r.status === "PENDING" && can("cash.remittance") && (r.mine
                  ? <span className="small muted">{t("cashdesk.yours")}</span>
                  : <><button className="btn small" onClick={() => decide(r, true)}><Icon name="check_circle" />{t("cashdesk.confirm")}</button>{" "}
                      <button className="btn text small danger" onClick={() => decide(r, false)}>{t("cashdesk.reject")}</button></>)}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {limitFor && <LimitModal p={limitFor} onClose={() => setLimitFor(null)} onDone={() => { setLimitFor(null); toast(t("cashdesk.saved")); reload(); }} />}
      {remitFor && <RemitModal p={remitFor} onClose={() => setRemitFor(null)} onDone={() => { setRemitFor(null); toast(t("cashdesk.recorded")); reload(); }} />}
    </div>
  );
}

function LimitModal({ p, onClose, onDone }: { p: Position; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const [amount, setAmount] = useState(p.limit_amount / 100);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try { await api.put(`/api/admin/cash/limits/${p.company_id}`, { limit_amount: Math.round(amount * 100), reason: reason.trim() }); onDone(); }
    catch (e) { setError(e); }
  };
  return (
    <Modal title={`${t("cashdesk.setLimit")} · ${p.name}`} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={reason.trim().length < 5} onClick={save}>{t("common.save")}</button></>}>
      <Field label={t("cashdesk.newLimit")}><input className="input ltr" type="number" min={0} value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></Field>
      <Field label={t("cashdesk.reason")}><input className="input" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} /></Field>
      <ErrorBox error={error} />
    </Modal>
  );
}

function RemitModal({ p, onClose, onDone }: { p: Position; onClose: () => void; onDone: () => void }) {
  const { t, money } = useI18n();
  const [f, setF] = useState({ amount: (p.owed - p.pending) / 100, method: "BANK_DEPOSIT", ref: "", note: "" });
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try {
      await api.post("/api/admin/cash/remittances", { company_id: p.company_id, amount: Math.round(f.amount * 100), method: f.method,
        ref: f.ref.trim() || undefined, note: f.note.trim() || undefined });
      onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={`${t("cashdesk.record")} · ${p.name}`} onClose={onClose} actions={<><button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={f.amount <= 0} onClick={save}>{t("common.save")}</button></>}>
      <p className="small muted">{t("cashdesk.owed")}: {money(p.owed)}</p>
      <div className="grid cols-2">
        <Field label={t("cashdesk.amount")}><input className="input ltr" type="number" min={0} value={f.amount} onChange={(e) => setF({ ...f, amount: Number(e.target.value) })} /></Field>
        <Field label={t("cashdesk.how")}><select value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })}>
          {["BANK_DEPOSIT", "CASH_OFFICE", "EXCHANGE_HOUSE"].map((m) => <option key={m} value={m}>{t(`cashdesk.rm.${m}`)}</option>)}</select></Field>
        <Field label={t("cashdesk.ref")}><input className="input ltr" value={f.ref} maxLength={80} onChange={(e) => setF({ ...f, ref: e.target.value })} /></Field>
        <Field label={t("cashdesk.note")}><input className="input" value={f.note} maxLength={300} onChange={(e) => setF({ ...f, note: e.target.value })} /></Field>
      </div>
      <ErrorBox error={error} />
    </Modal>
  );
}
