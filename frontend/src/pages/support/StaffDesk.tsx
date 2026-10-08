import { useState } from "react";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

interface Claim {
  uid: string; ref: string; subject: string; claim_amount: number; approved_amount: number; liable: string; updated_at: string;
  booking_ref: string | null; carrier_name: string | null; customer_name: string | null;
}

/** Finance: approved claims waiting for payment. The payer must not be the person who approved the claim. */
export function ClaimsToPay() {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<{ claims: Claim[] }>("/api/admin/support/claims"));
  const [confirm, setConfirm] = useState<Claim | null>(null);
  const [error, setError] = useState<unknown>(null);
  const pay = async (c: Claim) => {
    setError(null);
    try { await api.post(`/api/admin/support/cases/${c.uid}/pay`); toast(t("support.claimPaid", { ref: c.ref })); setConfirm(null); state.reload(); }
    catch (e) { setError(e); }
  };
  return (
    <section className="card stack">
      <h3 style={{ margin: 0 }}><Icon name="support_agent" /> {t("support.claimsTitle")}</h3>
      <Loaded state={state}>{({ claims }) => claims.length === 0 ? <Empty icon="check_circle" title={t("support.noClaims")} /> : (
        <div className="table-wrap"><table className="table">
          <thead><tr><th>{t("support.ref")}</th><th>{t("support.subject")}</th><th>{t("support.customer")}</th><th>{t("support.liable")}</th><th className="num">{t("support.approved")}</th><th>{t("support.updated")}</th><th /></tr></thead>
          <tbody>{claims.map((c) => (
            <tr key={c.uid}>
              <td className="mono ltr">{c.ref}</td><td>{c.subject}{c.booking_ref && <div className="small muted mono ltr">{c.booking_ref}</div>}</td>
              <td>{c.customer_name}</td><td>{t(`support.liableParty.${c.liable}`)}{c.liable === "CARRIER" && c.carrier_name ? ` · ${c.carrier_name}` : ""}</td>
              <td className="num mono">{money(c.approved_amount)}</td><td className="small">{dateTime(c.updated_at)}</td>
              <td><button className="btn tonal small" onClick={() => setConfirm(c)}>{t("support.pay")}</button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}</Loaded>
      {confirm && (
        <Modal title={t("support.pay")} onClose={() => setConfirm(null)}
               actions={<><button className="btn text" onClick={() => setConfirm(null)}>{t("common.cancel")}</button>
                          <button className="btn" onClick={() => pay(confirm)}>{t("support.pay")}</button></>}>
          <p>{t("support.payConfirm", { amount: money(confirm.approved_amount), ref: confirm.ref })}</p>
          <ErrorBox error={error} />
        </Modal>
      )}
    </section>
  );
}

/** Security: add a phone, e-mail, device or other value to the blocklist; the server stores only its digest. */
export function BlocklistCard() {
  const { t } = useI18n();
  const toast = useToast();
  const blank = { entry_type: "PHONE", value: "", reason: "", expires_at: "" };
  const [f, setF] = useState(blank);
  const [error, setError] = useState<unknown>(null);
  const add = async () => {
    setError(null);
    try {
      await api.post("/api/admin/support/blocklist", { ...f, expires_at: f.expires_at ? new Date(f.expires_at).toISOString() : null });
      toast(t("security.blocked")); setF(blank);
    } catch (e) { setError(e); }
  };
  return (
    <section className="card stack">
      <h3 style={{ margin: 0 }}><Icon name="block" /> {t("security.blocklist")}</h3>
      <p className="small muted" style={{ margin: 0 }}>{t("security.blocklistHint")}</p>
      <div className="grid cols-2">
        <Field label={t("security.entryType")}>
          <select className="input" value={f.entry_type} onChange={(e) => setF({ ...f, entry_type: e.target.value })}>
            {["PHONE", "EMAIL", "DEVICE", "IBAN", "ID_DOC", "CARD_BIN"].map((x) => <option key={x} value={x}>{t(`security.entry.${x}`)}</option>)}
          </select>
        </Field>
        <Field label={t("security.blockValue")}><input className="input ltr" maxLength={200} value={f.value} onChange={(e) => setF({ ...f, value: e.target.value })} /></Field>
        <Field label={t("security.blockReason")}><input className="input" maxLength={300} value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
        <Field label={t("security.blockExpires")}><input className="input" type="datetime-local" value={f.expires_at} onChange={(e) => setF({ ...f, expires_at: e.target.value })} /></Field>
      </div>
      <div className="row"><button className="btn" disabled={f.value.length < 3 || f.reason.length < 5} onClick={add}><Icon name="block" />{t("security.addBlock")}</button></div>
      <ErrorBox error={error} />
    </section>
  );
}
