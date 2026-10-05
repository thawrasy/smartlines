import { useState } from "react";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

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
  const [tab, setTab] = useState<"providers" | "bank" | "payments">(can("ledger.reconcile") ? "bank" : "providers");
  return (
    <div className="stack">
      <PageHead title={t("pay.desk")} sub={t("pay.deskSub")} />
      <div className="segmented" role="tablist" style={{ alignSelf: "flex-start" }}>
        {(["bank", "payments", "providers"] as const).map((v) => (
          <button key={v} role="tab" aria-selected={tab === v} className={tab === v ? "on" : ""} onClick={() => setTab(v)}>{t(`pay.tab.${v}`)}</button>
        ))}
      </div>
      {tab === "providers" && <Providers />}
      {tab === "bank" && <BankStatements />}
      {tab === "payments" && <RecentPayments />}
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
        <div className="table-wrap"><table className="table">
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
  const fields = p.adapter === "BANK_TRANSFER" ? ["bank_name", "account_name", "iban", "valid_days"] : p.adapter === "HOSTED_CARD" ? ["base_url", "merchant_id"]
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
  const [error, setError] = useState<unknown>(null);
  const [matching, setMatching] = useState<Line | null>(null);
  const upload = async () => {
    if (!file) return;
    setError(null);
    const form = new FormData(); form.append("file", file); form.append("account_label", label);
    try {
      const r = await api.upload<{ lines: number; matched: number; unmatched: number }>("/api/admin/payments/statements", form);
      toast(t("pay.imported", { lines: r.lines, matched: r.matched })); setFile(null); state.reload();
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
          <Field label={t("pay.file")}><input type="file" accept=".csv,text/csv" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></Field>
          <button className="btn" disabled={!file} onClick={upload}><Icon name="download" />{t("pay.import")}</button>
        </div>
        <ErrorBox error={error} />
      </div>
      <div className="card stack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3 style={{ margin: 0 }}>{t("pay.lines")}</h3>
          <div className="segmented" role="tablist">
            {["UNMATCHED", "MATCHED", "IGNORED"].map((s) => <button key={s} role="tab" aria-selected={status === s} className={status === s ? "on" : ""} onClick={() => setStatus(s)}>{t(`pay.line.${s}`)}</button>)}
          </div>
        </div>
        <Loaded state={state}>{(d) => d.lines.length === 0 ? <Empty icon="account_balance" title={t("pay.noLines")} /> : (
          <div className="table-wrap"><table className="table">
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
            <div className="table-wrap"><table className="table">
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
        <div className="table-wrap"><table className="table">
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
      {refunding && <RefundModal p={refunding} onClose={() => setRefunding(null)} onDone={() => { setRefunding(null); state.reload(); toast(t("pay.refunded")); }} />}
    </div>
  );
}

function RefundModal({ p, onClose, onDone }: { p: Pay; onClose: () => void; onDone: () => void }) {
  const { t, money } = useI18n();
  const left = p.amount - p.refunded_amount;
  const [amount, setAmount] = useState(left / 100);
  const [reason, setReason] = useState("");
  const [key] = useState(newKey);
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    try { await api.post(`/api/admin/payments/${p.uid}/refund`, { amount: Math.round(amount * 100), reason, idempotency_key: key }); onDone(); } catch (e) { setError(e); }
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
          <div className="table-wrap"><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("pay.receipt")}</th><th>{t("pay.mobile")}</th><th className="num">{t("pay.amount")}</th></tr></thead>
            <tbody>{d.topups.map((x) => <tr key={x.uid}><td className="small">{dateTime(x.created_at)}</td><td className="mono">{x.receipt}</td><td className="ltr small">{x.mobile}</td><td className="num mono">{money(x.amount)}</td></tr>)}</tbody>
          </table></div>
        )}</Loaded>
      </div>
    </div>
  );
}
