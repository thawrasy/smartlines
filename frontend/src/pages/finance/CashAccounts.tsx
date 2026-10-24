import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { PageHead } from "../../components/layout";
import { CarrierName, Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";

interface Account {
  agency_uid: string; agency_name: string; carrier_uid: string; carrier_name: string; carrier_logo: string | null; currency: string;
  sold: number; received: number; owed: number; last_received_at: string | null;
}
interface Receipt { uid: string; agency_name: string; carrier_name: string; currency: string; amount: number; reference: string; confirmed_at: string }
interface Activation { carrier_uid: string; carrier_name: string; option_code: string; status: string; basis: string; contracted_at: string; activated_at: string | null }

function Receipts({ rows, side }: { rows: Receipt[]; side: "agency" | "carrier" }) {
  const { t, money, dateTime } = useI18n();
  if (rows.length === 0) return <Empty title={t("acash.noReceipts")} />;
  return (
    <div className="table-wrap" tabIndex={0}><table className="table">
      <thead><tr><th>{t("common.when")}</th><th>{side === "agency" ? t("acash.carrier") : t("acash.agency")}</th><th>{t("acash.reference")}</th><th className="num">{t("common.amount")}</th></tr></thead>
      <tbody>{rows.map((r) => (
        <tr key={r.uid}>
          <td className="small">{dateTime(r.confirmed_at)}</td><td>{side === "agency" ? r.carrier_name : r.agency_name}</td>
          <td className="mono small">{r.reference}</td><td className="num">{money(r.amount)}</td>
        </tr>
      ))}</tbody>
    </table></div>
  );
}

function totals(rows: Account[]) {
  return rows.reduce((s, a) => ({ sold: s.sold + a.sold, received: s.received + a.received, owed: s.owed + a.owed }), { sold: 0, received: 0, owed: 0 });
}

/** The agency's account with each carrier for its cash sales in phase one (N13): sold, paid to the carrier, still owed. */
export function AgencyCashAccounts() {
  const { t, money, dateTime } = useI18n();
  const state = useLoad(() => api.get<{ cash_sales: boolean; accounts: Account[]; receipts: Receipt[] }>("/api/agency/cash-accounts"));
  return (
    <div className="stack">
      <PageHead title={t("acash.title")} sub={t("acash.agencySub")} />
      <Loaded state={state}>{(d) => {
        const sum = totals(d.accounts);
        return (
          <>
            {d.cash_sales && <div className="alert info" role="status"><Icon name="info" /> <span>{t("acash.cashNow")}</span></div>}
            <div className="grid cols-3">
              <Stat icon="payments" label={t("acash.sold")} value={money(sum.sold)} />
              <Stat icon="handshake" label={t("acash.received")} value={money(sum.received)} tone="blue" />
              <Stat icon="account_balance" label={t("acash.owed")} value={money(sum.owed)} tone="red" />
            </div>
            <div className="card">
              <h3>{t("acash.byCarrier")}</h3>
              {d.accounts.length === 0 ? <Empty title={t("acash.none")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("acash.carrier")}</th><th className="num">{t("acash.sold")}</th><th className="num">{t("acash.received")}</th><th className="num">{t("acash.owed")}</th><th>{t("acash.lastReceived")}</th></tr></thead>
                  <tbody>{d.accounts.map((a) => (
                    <tr key={`${a.carrier_uid}-${a.currency}`}>
                      <td><CarrierName name={a.carrier_name} uid={a.carrier_uid} logo={a.carrier_logo} /></td>
                      <td className="num">{money(a.sold)}</td><td className="num">{money(a.received)}</td>
                      <td className="num" style={{ fontWeight: 600 }}>{money(a.owed)}</td>
                      <td className="small">{a.last_received_at ? dateTime(a.last_received_at) : "—"}</td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
            <div className="card"><h3>{t("acash.receipts")}</h3><Receipts rows={d.receipts} side="agency" /></div>
          </>
        );
      }}</Loaded>
    </div>
  );
}

/** The carrier's account with each agency that sells its tickets for cash, and the sums it records receiving. */
export function CarrierAgencyCash() {
  const { t, money, dateTime } = useI18n();
  const { can } = useAuth();
  const state = useLoad(() => api.get<{ accounts: Account[]; receipts: Receipt[] }>("/api/carrier/agency-cash"));
  const [receive, setReceive] = useState<Account | null>(null);
  return (
    <div className="stack">
      <PageHead title={t("acash.carrierTitle")} sub={t("acash.carrierSub")} />
      <Loaded state={state}>{(d) => {
        const sum = totals(d.accounts);
        return (
          <>
            <div className="grid cols-3">
              <Stat icon="payments" label={t("acash.sold")} value={money(sum.sold)} />
              <Stat icon="handshake" label={t("acash.received")} value={money(sum.received)} tone="blue" />
              <Stat icon="account_balance" label={t("acash.owedToYou")} value={money(sum.owed)} tone="wheat" />
            </div>
            <div className="card">
              <h3>{t("acash.byAgency")}</h3>
              {d.accounts.length === 0 ? <Empty title={t("acash.none")} /> : (
                <div className="table-wrap" tabIndex={0}><table className="table">
                  <thead><tr><th>{t("acash.agency")}</th><th className="num">{t("acash.sold")}</th><th className="num">{t("acash.received")}</th><th className="num">{t("acash.owedToYou")}</th><th>{t("acash.lastReceived")}</th><th /></tr></thead>
                  <tbody>{d.accounts.map((a) => (
                    <tr key={`${a.agency_uid}-${a.currency}`}>
                      <td style={{ fontWeight: 500 }}>{a.agency_name}</td>
                      <td className="num">{money(a.sold)}</td><td className="num">{money(a.received)}</td>
                      <td className="num" style={{ fontWeight: 600 }}>{money(a.owed)}</td>
                      <td className="small">{a.last_received_at ? dateTime(a.last_received_at) : "—"}</td>
                      <td>{can("company.billing", "sale.cash") && a.owed > 0 &&
                        <button className="btn tonal" onClick={() => setReceive(a)}><Icon name="handshake" />{t("acash.record")}</button>}</td>
                    </tr>
                  ))}</tbody>
                </table></div>
              )}
            </div>
            <div className="card"><h3>{t("acash.receipts")}</h3><Receipts rows={d.receipts} side="carrier" /></div>
          </>
        );
      }}</Loaded>
      {receive && <RecordReceipt account={receive} onClose={() => setReceive(null)} onDone={() => { setReceive(null); state.reload(); }} />}
    </div>
  );
}

function RecordReceipt({ account, onClose, onDone }: { account: Account; onClose: () => void; onDone: () => void }) {
  const { t, money } = useI18n();
  const toast = useToast();
  const [amount, setAmount] = useState(account.owed / 100);
  const [reference, setReference] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const minor = Math.round(amount * 100);
  const save = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/carrier/agency-cash/receipts", { agency_uid: account.agency_uid, currency: account.currency, amount: minor, reference: reference.trim() });
      toast(t("acash.recorded")); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Modal title={t("acash.recordTitle", { agency: account.agency_name })} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={busy || minor <= 0 || minor > account.owed || reference.trim().length < 3} onClick={save}>{t("acash.record")}</button></>}>
      <p className="small muted">{t("acash.recordHint", { owed: money(account.owed) })}</p>
      <Field label={t("common.amount")}><input className="input ltr" type="number" min={0} max={account.owed / 100} value={amount} onChange={(e) => setAmount(Number(e.target.value))} /></Field>
      <Field label={t("acash.reference")} hint={t("acash.referenceHint")}><input className="input ltr mono" maxLength={80} value={reference} onChange={(e) => setReference(e.target.value)} /></Field>
      <ErrorBox error={error} />
    </Modal>
  );
}

/** The platform opens a gateway option carrier by carrier (phase two): the contract, then the activation; each step tells the carrier. */
export function PaymentActivations() {
  const { t, date } = useI18n();
  const { can } = useAuth();
  const state = useLoad(() => api.get<{ options: string[]; activations: Activation[] }>("/api/admin/payment-activations"));
  const [edit, setEdit] = useState<{ carrier_uid: string; carrier_name: string; option_code: string; status: string } | null>(null);
  const [carrierUid, setCarrierUid] = useState("");
  return (
    <div className="card stack">
      <p className="small muted">{t("gw.hint")}</p>
      <Loaded state={state}>{(d) => (
        <>
          {d.activations.length === 0 ? <Empty title={t("gw.none")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("acash.carrier")}</th><th>{t("gw.option")}</th><th>{t("common.status")}</th><th>{t("gw.contracted")}</th><th>{t("gw.activated")}</th><th>{t("gw.basis")}</th><th /></tr></thead>
              <tbody>{d.activations.map((a) => (
                <tr key={`${a.carrier_uid}-${a.option_code}`}>
                  <td style={{ fontWeight: 500 }}>{a.carrier_name}</td><td>{t(`opt.name.${a.option_code}`)}</td><td><Status value={a.status} /></td>
                  <td className="small">{date(a.contracted_at)}</td><td className="small">{a.activated_at ? date(a.activated_at) : "—"}</td>
                  <td className="small">{a.basis}</td>
                  <td>{can("payment.methods") && <button className="btn text" onClick={() => setEdit(a)}><Icon name="edit" />{t("common.edit")}</button>}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
          {can("payment.methods") && (
            <div className="row" style={{ gap: 8, flexWrap: "wrap" }}>
              <input className="input ltr mono" style={{ maxWidth: 360 }} aria-label={t("gw.carrierUid")} placeholder={t("gw.carrierUid")} value={carrierUid} onChange={(e) => setCarrierUid(e.target.value.trim())} />
              <button className="btn tonal" disabled={!/^[0-9a-f-]{36}$/i.test(carrierUid)}
                onClick={() => setEdit({ carrier_uid: carrierUid, carrier_name: carrierUid, option_code: d.options[0], status: "" })}><Icon name="add" />{t("gw.contract")}</button>
            </div>
          )}
        </>
      )}</Loaded>
      {edit && <ActivationEdit row={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); state.reload(); }} />}
    </div>
  );
}

function ActivationEdit({ row, onClose, onDone }: { row: { carrier_uid: string; carrier_name: string; option_code: string; status: string }; onClose: () => void; onDone: () => void }) {
  const { t } = useI18n();
  const toast = useToast();
  const [option, setOption] = useState(row.option_code);
  const [status, setStatus] = useState(row.status || "CONTRACTED");
  const [basis, setBasis] = useState("");
  const [error, setError] = useState<unknown>(null);
  const save = async () => {
    setError(null);
    try {
      await api.put(`/api/admin/payment-activations/${row.carrier_uid}/${option}`, { status, basis: basis.trim() });
      toast(t("common.saved")); onDone();
    } catch (e) { setError(e); }
  };
  return (
    <Modal title={row.carrier_name} onClose={onClose} actions={<>
      <button className="btn text" onClick={onClose}>{t("common.cancel")}</button>
      <button className="btn" disabled={basis.trim().length < 3} onClick={save}>{t("common.save")}</button></>}>
      <p className="small muted">{t("gw.tellsCarrier")}</p>
      <Field label={t("gw.option")}>
        <select value={option} disabled={!!row.status} onChange={(e) => setOption(e.target.value)}>
          {["CARD", "INSTALLMENT", "FINANCING"].map((o) => <option key={o} value={o}>{t(`opt.name.${o}`)}</option>)}
        </select>
      </Field>
      <Field label={t("common.status")}>
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          {["CONTRACTED", "ACTIVE", "SUSPENDED"].map((s) => <option key={s} value={s}>{t(`gw.status.${s}`)}</option>)}
        </select>
      </Field>
      <Field label={t("gw.basis")}><input className="input" maxLength={200} value={basis} onChange={(e) => setBasis(e.target.value)} /></Field>
      <ErrorBox error={error} />
    </Modal>
  );
}
