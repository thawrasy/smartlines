import { useState } from "react";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, useLoad, useToast } from "../../components/ui";

interface WalletData {
  currency: string; balance: number; sandbox: boolean;
  entries: { direction: "DR" | "CR"; amount: number; balance_after: number; created_at: string; txn_type: string; memo: string | null }[];
}

export default function Wallet() {
  const { t, money, dateTime, has } = useI18n();
  const toast = useToast();
  const state = useLoad(() => api.get<WalletData>("/api/wallet"));
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState(100000);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const topup = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/wallet/topup", { amount: amount * 100, idempotency_key: newKey() });
      setOpen(false); toast(t("wallet.topupDone")); state.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  return (
    <div className="page stack">
      <PageHead title={t("wallet.title")} sub={t("wallet.subtitle")} />
      <Loaded state={state}>{(w) => (
        <>
          <div className="card hero row between" style={{ background: "linear-gradient(135deg, #E3F3EA 0%, #FFFFFF 60%, #FFF8E6 100%)" }}>
            <div>
              <div className="muted">{t("wallet.balance")}</div>
              <div style={{ fontSize: 40, fontWeight: 700 }} className="mono">{money(w.balance)}</div>
            </div>
            <div className="stack tight" style={{ alignItems: "flex-end" }}>
              {w.sandbox && <span className="sandbox-tag">{t("app.sandbox")}</span>}
              <button className="btn large" onClick={() => setOpen(true)} disabled={!w.sandbox}><Icon name="add" />{t("wallet.topup")}</button>
              {!w.sandbox && <span className="small muted">{t("wallet.noLive")}</span>}
            </div>
          </div>
          <div className="card">
            <div className="card-title"><h3>{t("wallet.statement")}</h3></div>
            {w.entries.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
              <div className="table-wrap"><table className="table">
                <thead><tr><th>{t("common.when")}</th><th>{t("common.type")}</th><th>{t("common.details")}</th><th className="num">{t("common.amount")}</th><th className="num">{t("common.balance")}</th></tr></thead>
                <tbody>{w.entries.map((e, i) => (
                  <tr key={i}>
                    <td>{dateTime(e.created_at)}</td>
                    <td>{has(`txn.${e.txn_type}`) ? t(`txn.${e.txn_type}`) : e.txn_type}</td>
                    <td className="mono small muted">{e.memo}</td>
                    <td className="num" style={{ color: e.direction === "CR" ? "var(--primary)" : "var(--on-surface)", fontWeight: 600 }}>
                      <span className="ltr">{e.direction === "CR" ? "+" : "−"}{money(e.amount, false)}</span>
                    </td>
                    <td className="num">{money(e.balance_after, false)}</td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </div>
        </>
      )}</Loaded>
      {open && (
        <Modal title={t("wallet.topupTitle")} onClose={() => setOpen(false)}
               actions={<><button className="btn text" onClick={() => setOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || amount <= 0} onClick={topup}>{t("wallet.topup")}</button></>}>
          <div className="stack">
            <div className="alert warn"><Icon name="warning" />{t("wallet.sandboxNote")}</div>
            <ErrorBox error={error} />
            <Field label={t("wallet.amount")}>
              <input className="input ltr" type="number" min={1000} step={1000} value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
            </Field>
            <div className="row">{[50000, 100000, 250000, 500000].map((v) => (
              <button key={v} type="button" className={`chip chip-select${amount === v ? " on" : ""}`} onClick={() => setAmount(v)}>{money(v * 100)}</button>
            ))}</div>
          </div>
        </Modal>
      )}
    </div>
  );
}
