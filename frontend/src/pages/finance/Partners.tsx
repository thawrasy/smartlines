import { useState } from "react";
import { Link } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { useLabels } from "../../modules/labels";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Status, useLoad, useToast } from "../../components/ui";

// Two platform settings that move money, in the payments desk: the penalty on a carrier that cancels a trip, only where
// the regulators impose one (1106), and the statements of loyalty partners paid by the platform under their agreements
// (1107). Statements are approved by another person in the generic screens; the payment is recorded by a third.

interface Penalty {
  enabled: boolean; basis?: "PERCENT_OF_FARES" | "PER_TICKET" | "PER_TRIP"; value?: number; payee?: "PLATFORM" | "PASSENGERS" | "AUTHORITY";
  authority_party_id?: number; within_hours?: number | null; legal_ref?: string;
}
interface Partner {
  id: number; name: string; partner_type: string; status: string; settlement_cycle: string; currency: string; has_api: boolean;
  agreement: string | null; unsettled: number; unsettled_payable: number;
}
interface Settlement {
  uid: string; partner_id: number; partner: string; currency: string; date_from: string; date_to: string; redemptions: number;
  value: number; payable: number; status: string; created_at: string; approved_at: string | null; paid_at: string | null; bank_ref: string | null;
}

export function CancelPenalty() {
  const { t } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<Penalty>("/api/admin/trips/cancel-penalty"));
  const [f, setF] = useState<Penalty | null>(null);
  const [error, setError] = useState<unknown>(null);
  const p = f ?? state.data;
  const set = (patch: Partial<Penalty>) => p && setF({ ...p, ...patch });
  const save = async () => {
    if (!p) return;
    setError(null);
    try {
      const body = p.enabled ? { ...p, authority_party_id: p.payee === "AUTHORITY" ? p.authority_party_id : undefined } : { enabled: false };
      await api.put("/api/admin/trips/cancel-penalty", body); toast(t("common.saved")); setF(null); state.reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="card stack">
      <p className="small muted" style={{ margin: 0 }}>{t("penalty.hint")}</p>
      <ErrorBox error={error} />
      <Loaded state={state}>{() => p && (
        <div className="stack">
          <label className="check-row"><input type="checkbox" checked={p.enabled} onChange={(e) => set({ enabled: e.target.checked })} />{t("penalty.enabled")}</label>
          {p.enabled && (
            <div className="grid cols-3">
              <Field label={t("penalty.basis")}>
                <select className="input" value={p.basis ?? ""} onChange={(e) => set({ basis: (e.target.value || undefined) as Penalty["basis"] })}>
                  <option value="">—</option>
                  {["PERCENT_OF_FARES", "PER_TICKET", "PER_TRIP"].map((b) => <option key={b} value={b}>{t(`penalty.basisOf.${b}`)}</option>)}
                </select>
              </Field>
              <Field label={t("penalty.value")} hint={p.basis === "PERCENT_OF_FARES" ? t("penalty.valuePct") : t("penalty.valueAmount")}>
                <input className="input" type="number" min={0} value={p.value ?? ""} onChange={(e) => set({ value: e.target.value === "" ? undefined : Number(e.target.value) })} />
              </Field>
              <Field label={t("penalty.payee")}>
                <select className="input" value={p.payee ?? ""} onChange={(e) => set({ payee: (e.target.value || undefined) as Penalty["payee"] })}>
                  <option value="">—</option>
                  {["PLATFORM", "PASSENGERS", "AUTHORITY"].map((b) => <option key={b} value={b}>{t(`penalty.payeeOf.${b}`)}</option>)}
                </select>
              </Field>
              {p.payee === "AUTHORITY" && (
                <Field label={t("penalty.authority")}>
                  <input className="input mono ltr" type="number" min={1} value={p.authority_party_id ?? ""} onChange={(e) => set({ authority_party_id: e.target.value === "" ? undefined : Number(e.target.value) })} />
                </Field>
              )}
              <Field label={t("penalty.within")} hint={t("penalty.withinHint")}>
                <input className="input" type="number" min={0} max={720} value={p.within_hours ?? ""} onChange={(e) => set({ within_hours: e.target.value === "" ? null : Number(e.target.value) })} />
              </Field>
              <Field label={t("penalty.legalRef")} hint={t("penalty.legalRefHint")}>
                <input className="input" value={p.legal_ref ?? ""} onChange={(e) => set({ legal_ref: e.target.value })} />
              </Field>
            </div>
          )}
          <div className="alert info small"><Icon name="info" />{t("penalty.refundNote")}</div>
          <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!f} onClick={save}>{t("common.save")}</button>
        </div>
      )}</Loaded>
    </div>
  );
}

export function LoyaltyDesk() {
  const { t, money, date } = useI18n();
  const label = useLabels();
  const { can } = useAuth();
  const toast = useToast();
  const partners = useLoad(() => api.get<{ partners: Partner[] }>("/api/admin/loyalty/partners"));
  const statements = useLoad(() => api.get<{ settlements: Settlement[] }>("/api/admin/loyalty/settlements"));
  const [drawFor, setDrawFor] = useState<Partner | null>(null);
  const [period, setPeriod] = useState({ date_from: "", date_to: "" });
  const [payFor, setPayFor] = useState<Settlement | null>(null);
  const [bankRef, setBankRef] = useState("");
  const [accepting, setAccepting] = useState<Partner | null>(null);
  const [voucher, setVoucher] = useState({ code: "", reference: "" });
  const [error, setError] = useState<unknown>(null);
  const reload = () => { partners.reload(); statements.reload(); };
  const draw = async () => {
    if (!drawFor) return;
    setError(null);
    try {
      await api.post("/api/admin/loyalty/settlements", { partner_id: drawFor.id, ...period });
      toast(t("loyaltyDesk.drawn")); setDrawFor(null); reload();
    } catch (e) { setError(e); }
  };
  const pay = async () => {
    if (!payFor) return;
    setError(null);
    try { await api.post(`/api/admin/loyalty/settlements/${payFor.uid}/pay`, { bank_ref: bankRef }); toast(t("loyaltyDesk.paid")); setPayFor(null); setBankRef(""); reload(); }
    catch (e) { setError(e); }
  };
  const accept = async () => {
    if (!accepting) return;
    setError(null);
    try {
      await api.post("/api/admin/loyalty/vouchers/accept", { partner_id: accepting.id, code: voucher.code.trim(), reference: voucher.reference || undefined });
      toast(t("loyaltyDesk.accepted")); setAccepting(null); setVoucher({ code: "", reference: "" }); reload();
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <ErrorBox error={error} />
      <div className="card stack">
        <div className="row between" style={{ flexWrap: "wrap", gap: 8 }}>
          <h3 style={{ margin: 0 }}>{t("loyaltyDesk.partners")}</h3>
          <Link className="btn text small" to="/admin/m/loyalty_partners"><Icon name="open_in_new" />{t("loyaltyDesk.agreements")}</Link>
        </div>
        <Loaded state={partners}>{({ partners: list }) => list.length === 0 ? <Empty icon="handshake" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.name")}</th><th>{t("common.type")}</th><th>{t("loyaltyDesk.agreement")}</th><th>{t("loyaltyDesk.cycle")}</th>
              <th className="num">{t("loyaltyDesk.unsettled")}</th><th className="num">{t("loyaltyDesk.owed")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{list.map((p) => (
              <tr key={p.id}>
                <td>{p.name}</td><td>{label.value(p.partner_type)}</td><td>{p.agreement ? <Status value="ACTIVE" /> : <span className="small muted">{t("loyaltyDesk.noAgreement")}</span>}</td>
                <td>{label.value(p.settlement_cycle)}</td><td className="num">{p.unsettled}</td><td className="num">{money(p.unsettled_payable, true, p.currency)}</td>
                <td><Status value={p.status} /></td>
                <td className="num" style={{ whiteSpace: "nowrap" }}>
                  {can("loyalty.manage") && !p.has_api && p.agreement && <button className="btn text small" onClick={() => setAccepting(p)}><Icon name="qr_code_scanner" />{t("loyaltyDesk.accept")}</button>}
                  {can("loyalty.manage") && p.unsettled > 0 && <button className="btn text small" onClick={() => setDrawFor(p)}><Icon name="receipt_long" />{t("loyaltyDesk.draw")}</button>}
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      <div className="card stack">
        <h3 style={{ margin: 0 }}>{t("loyaltyDesk.statements")}</h3>
        <p className="small muted" style={{ margin: 0 }}>{t("loyaltyDesk.statementsHint")}</p>
        <Loaded state={statements}>{({ settlements }) => settlements.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("loyaltyDesk.partner")}</th><th>{t("loyaltyDesk.period")}</th><th className="num">{t("loyaltyDesk.vouchers")}</th>
              <th className="num">{t("loyaltyDesk.value")}</th><th className="num">{t("loyaltyDesk.payable")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{settlements.map((s) => (
              <tr key={s.uid}>
                <td>{s.partner}</td><td className="small">{date(s.date_from)} – {date(s.date_to)}</td><td className="num">{s.redemptions}</td>
                <td className="num">{money(s.value, true, s.currency)}</td><td className="num">{money(s.payable, true, s.currency)}</td>
                <td><Status value={s.status} />{s.bank_ref && <div className="small muted mono">{s.bank_ref}</div>}</td>
                <td className="num">{can("payout.run") && s.status === "APPROVED" && <button className="btn text small" onClick={() => setPayFor(s)}><Icon name="account_balance" />{t("loyaltyDesk.pay")}</button>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      {drawFor && (
        <Modal title={`${t("loyaltyDesk.draw")} · ${drawFor.name}`} onClose={() => setDrawFor(null)}
          actions={<><button className="btn text" onClick={() => setDrawFor(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={!period.date_from || !period.date_to} onClick={draw}>{t("common.create")}</button></>}>
          <div className="grid cols-2">
            <Field label={t("common.from")}><input className="input" type="date" value={period.date_from} onChange={(e) => setPeriod({ ...period, date_from: e.target.value })} /></Field>
            <Field label={t("common.to")}><input className="input" type="date" value={period.date_to} onChange={(e) => setPeriod({ ...period, date_to: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
      {payFor && (
        <Modal title={`${t("loyaltyDesk.pay")} · ${payFor.partner}`} onClose={() => setPayFor(null)}
          actions={<><button className="btn text" onClick={() => setPayFor(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={bankRef.trim().length < 3} onClick={pay}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <p style={{ margin: 0 }}>{t("loyaltyDesk.payConfirm", { amount: money(payFor.payable, true, payFor.currency) })}</p>
            <Field label={t("loyaltyDesk.bankRef")}><input className="input mono ltr" value={bankRef} onChange={(e) => setBankRef(e.target.value)} /></Field>
          </div>
        </Modal>
      )}
      {accepting && (
        <Modal title={`${t("loyaltyDesk.accept")} · ${accepting.name}`} onClose={() => setAccepting(null)}
          actions={<><button className="btn text" onClick={() => setAccepting(null)}>{t("common.cancel")}</button>
            <button className="btn" disabled={voucher.code.trim().length < 10} onClick={accept}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <p className="small muted" style={{ margin: 0 }}>{t("loyaltyDesk.acceptHint")}</p>
            <Field label={t("loyaltyDesk.code")}><input className="input mono ltr" value={voucher.code} onChange={(e) => setVoucher({ ...voucher, code: e.target.value })} /></Field>
            <Field label={t("loyaltyDesk.reference")}><input className="input mono ltr" value={voucher.reference} onChange={(e) => setVoucher({ ...voucher, reference: e.target.value })} /></Field>
          </div>
        </Modal>
      )}
    </div>
  );
}
