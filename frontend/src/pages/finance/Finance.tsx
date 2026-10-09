import { useState } from "react";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { useAuth } from "../../auth";
import { ClaimsToPay } from "../support/StaffDesk";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Stat, Status, useLoad, useToast } from "../../components/ui";

interface Balance { currency: string; balance: number; held: number; available: number }
interface BankAccount { uid: string; bank_name: string; holder_name: string; iban_last4: string; verified: boolean; status: string; company_name?: string; created_at: string }
interface Withdrawal {
  uid: string; amount: number; currency: string; status: string; needs_second: boolean; created_at: string; paid_at: string | null;
  bank_ref: string | null; reject_reason: string | null; bank_name: string; iban_last4: string; bank_account_uid: string;
  company_name: string; requested_by_name: string; approved_by?: number | null; second_approver?: number | null;
}
interface Settlement { uid: string; period_from: string; period_to: string; gross: number; commission: number; refunds: number; net: number; status: string; trips: number; company_name: string }
interface SettlementDetail { uid: string; status: string; from: string; to: string; gross: number; commission: number; refunds: number; net: number; lines: { trip_no: string; gross: number; commission: number; refunds: number; net: number }[] }

const toMinor = (v: string) => Math.round(Number(v || 0) * 100);

function SettlementView({ uid, base, onClose }: { uid: string; base: string; onClose: () => void }) {
  const { t, money, date } = useI18n();
  const state = useLoad(() => api.get<SettlementDetail>(`${base}/settlements/${uid}`), [uid]);
  return (
    <Modal title={t("finance.statement")} onClose={onClose} wide actions={<>
      <button className="btn outlined" onClick={() => print()}><Icon name="download" />{t("common.print")}</button>
      <button className="btn" onClick={onClose}>{t("common.close")}</button></>}>
      <Loaded state={state}>{(s) => (
        <div className="stack">
          <div className="row between"><span>{date(`${s.from}T12:00:00Z`)} – {date(`${s.to}T12:00:00Z`)}</span><Status value={s.status} /></div>
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("finance.trip")}</th><th className="num">{t("finance.gross")}</th><th className="num">{t("finance.commission")}</th><th className="num">{t("finance.refunds")}</th><th className="num">{t("finance.net")}</th></tr></thead>
            <tbody>{s.lines.map((l) => (
              <tr key={l.trip_no}><td className="mono small">{l.trip_no}</td><td className="num">{money(l.gross)}</td><td className="num">{money(l.commission)}</td><td className="num">{money(l.refunds)}</td><td className="num">{money(l.net)}</td></tr>
            ))}</tbody>
            <tfoot><tr><th>{t("common.total")}</th><th className="num">{money(s.gross)}</th><th className="num">{money(s.commission)}</th><th className="num">{money(s.refunds)}</th><th className="num">{money(s.net)}</th></tr></tfoot>
          </table></div>
        </div>
      )}</Loaded>
    </Modal>
  );
}

// ------------------------------------------------------------------ carrier and agency owners
export function CompanyFinance() {
  const { t, money, dateTime, date } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const bal = useLoad(() => api.get<Balance>("/api/finance/balance"));
  const accounts = useLoad(() => api.get<{ accounts: BankAccount[] }>("/api/finance/bank-accounts"));
  const wds = useLoad(() => api.get<{ withdrawals: Withdrawal[] }>("/api/finance/withdrawals"));
  const sts = useLoad(() => api.get<{ settlements: Settlement[] }>("/api/finance/settlements"));
  const [mode, setMode] = useState<null | "account" | "withdraw">(null);
  const [acct, setAcct] = useState({ bank_name: "", holder_name: "", iban: "" });
  const [wd, setWd] = useState({ account: "", amount: "", key: newKey() });
  const [view, setView] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const manage = can("company.payout_schedule");
  const reload = () => { bal.reload(); accounts.reload(); wds.reload(); };
  const run = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true); setError(null);
    try { await fn(); setMode(null); toast(done); reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const verified = (accounts.data?.accounts ?? []).filter((a) => a.verified && a.status === "ACTIVE");
  return (
    <div className="stack">
      <PageHead title={t("finance.title")} sub={t("finance.sub")}>
        {manage && <button className="btn outlined" onClick={() => { setError(null); setMode("account"); }}><Icon name="add" />{t("finance.addAccount")}</button>}
        {manage && <button className="btn" disabled={!verified.length} onClick={() => { setError(null); setWd({ account: verified[0]?.uid ?? "", amount: "", key: newKey() }); setMode("withdraw"); }}>
          <Icon name="payments" />{t("finance.withdraw")}</button>}
      </PageHead>
      <Loaded state={bal}>{(b) => (
        <div className="grid cols-3">
          <Stat icon="account_balance_wallet" label={t("finance.available")} value={money(b.available)} />
          <Stat icon="schedule" label={t("finance.held")} value={money(b.held)} tone="wheat" />
          <Stat icon="payments" label={t("finance.balance")} value={money(b.balance)} tone="blue" />
        </div>
      )}</Loaded>
      <div className="grid split" style={{ alignItems: "start" }}>
        <div className="card">
          <div className="card-title"><h3>{t("finance.withdrawals")}</h3></div>
          <Loaded state={wds}>{({ withdrawals }) => withdrawals.length === 0 ? <Empty icon="payments" title={t("common.noData")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("common.when")}</th><th className="num">{t("common.amount")}</th><th>{t("finance.account")}</th><th>{t("finance.bankRef")}</th><th>{t("common.status")}</th></tr></thead>
              <tbody>{withdrawals.map((w) => (
                <tr key={w.uid}><td className="small">{dateTime(w.created_at)}</td><td className="num">{money(w.amount)}</td>
                  <td className="small">{w.bank_name} ···· <span className="ltr mono">{w.iban_last4}</span></td>
                  <td className="mono small">{w.bank_ref ?? w.reject_reason ?? "—"}</td><td><Status value={w.status} /></td></tr>
              ))}</tbody>
            </table></div>
          )}</Loaded>
        </div>
        <div className="card">
          <div className="card-title"><h3>{t("finance.accounts")}</h3></div>
          <Loaded state={accounts}>{({ accounts: list }) => list.length === 0 ? <Empty icon="account_balance_wallet" title={t("finance.noAccount")} /> : (
            <div className="stack tight">{list.map((a) => (
              <div key={a.uid} className="row between"><span>{a.bank_name}<div className="small muted">{a.holder_name} · ···· <span className="ltr mono">{a.iban_last4}</span></div></span>
                {a.verified ? <span className="chip green"><Icon name="verified" size={16} />{t("finance.verified")}</span> : <span className="chip wheat">{t("finance.pending")}</span>}</div>
            ))}</div>
          )}</Loaded>
        </div>
      </div>
      <div className="card">
        <div className="card-title"><h3>{t("finance.statements")}</h3></div>
        <Loaded state={sts}>{({ settlements }) => settlements.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("finance.period")}</th><th className="num">{t("finance.trips")}</th><th className="num">{t("finance.gross")}</th><th className="num">{t("finance.net")}</th><th>{t("common.status")}</th><th /></tr></thead>
            <tbody>{settlements.map((s) => (
              <tr key={s.uid}><td>{date(`${s.period_from}T12:00:00Z`)} – {date(`${s.period_to}T12:00:00Z`)}</td><td className="num">{s.trips}</td>
                <td className="num">{money(s.gross)}</td><td className="num">{money(s.net)}</td><td><Status value={s.status} /></td>
                <td><button className="btn tonal small" onClick={() => setView(s.uid)}>{t("common.view")}</button></td></tr>
            ))}</tbody>
          </table></div>
        )}</Loaded>
      </div>
      <p className="small muted"><Icon name="shield" size={16} /> {t("finance.securityNote")}</p>
      {mode === "account" && (
        <Modal title={t("finance.addAccount")} onClose={() => setMode(null)}
               actions={<><button className="btn text" onClick={() => setMode(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy} onClick={() => run(() => api.post("/api/finance/bank-accounts", acct), t("finance.accountAdded"))}>{t("common.save")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("finance.bankName")}><input className="input" value={acct.bank_name} onChange={(e) => setAcct({ ...acct, bank_name: e.target.value })} /></Field>
            <Field label={t("finance.holder")}><input className="input" value={acct.holder_name} onChange={(e) => setAcct({ ...acct, holder_name: e.target.value })} /></Field>
            <Field label="IBAN" hint={t("finance.ibanHint")}><input className="input ltr mono" autoComplete="off" value={acct.iban} onChange={(e) => setAcct({ ...acct, iban: e.target.value.toUpperCase() })} /></Field>
          </div>
        </Modal>
      )}
      {mode === "withdraw" && (
        <Modal title={t("finance.withdraw")} onClose={() => setMode(null)}
               actions={<><button className="btn text" onClick={() => setMode(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !(Number(wd.amount) > 0)} onClick={() => run(() => api.post("/api/finance/withdrawals",
                   { bank_account_uid: wd.account, amount: toMinor(wd.amount), idempotency_key: wd.key }), t("finance.requested"))}>{t("common.confirm")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("finance.account")}>
              <select className="input" value={wd.account} onChange={(e) => setWd({ ...wd, account: e.target.value })}>
                {verified.map((a) => <option key={a.uid} value={a.uid}>{a.bank_name} ···· {a.iban_last4}</option>)}
              </select>
            </Field>
            <Field label={t("finance.amountSyp")} hint={bal.data ? `${t("finance.available")}: ${money(bal.data.available)}` : undefined}>
              <input className="input ltr" type="number" min={1} value={wd.amount} onChange={(e) => setWd({ ...wd, amount: e.target.value })} />
            </Field>
            <div className="alert info"><Icon name="lock" /><span>{t("finance.holdNote")}</span></div>
          </div>
        </Modal>
      )}
      {view && <SettlementView uid={view} base="/api/finance" onClose={() => setView(null)} />}
    </div>
  );
}

// ------------------------------------------------------------------ platform finance desk
export function AdminFinance() {
  const { t, money, dateTime, date } = useI18n();
  const { can } = useAuth();
  const toast = useToast();
  const [status, setStatus] = useState("REQUESTED");
  const wds = useLoad(() => api.get<{ withdrawals: Withdrawal[] }>("/api/admin/finance/withdrawals", { status: status || undefined }), [status]);
  const accounts = useLoad(() => api.get<{ accounts: BankAccount[] }>("/api/admin/finance/bank-accounts"));
  const sts = useLoad(() => api.get<{ settlements: Settlement[] }>("/api/admin/finance/settlements"));
  const companies = useLoad(() => api.get<{ companies: { uid: string; legal_name: string; company_type: string }[] }>("/api/admin/companies"));
  const [reject, setReject] = useState<Withdrawal | null>(null);
  const [reason, setReason] = useState("");
  const [pay, setPay] = useState<{ w: Withdrawal; details: { iban: string; holder: string; bank: string; amount: number } | null; ref: string } | null>(null);
  const [runOpen, setRunOpen] = useState(false);
  const [runF, setRunF] = useState({ company: "", from: "", to: "" });
  const [view, setView] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const act = async (fn: () => Promise<unknown>, done: string, after?: () => void) => {
    setBusy(true); setError(null);
    try { await fn(); toast(done); after?.(); wds.reload(); accounts.reload(); sts.reload(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const openPay = async (w: Withdrawal) => {
    setError(null);
    try {
      const details = await api.get<{ iban: string; holder: string; bank: string; amount: number }>(`/api/admin/finance/withdrawals/${w.uid}/transfer`);
      setPay({ w, details, ref: "" });
    } catch (e) { setError(e); }
  };
  return (
    <div className="stack">
      <PageHead title={t("finance.desk")} sub={t("finance.deskSub")} />
      <ErrorBox error={!reject && !pay && !runOpen ? error : null} />
      <div className="card">
        <div className="card-title"><h3>{t("finance.withdrawals")}</h3>
          <select className="input" style={{ width: 200 }} aria-label={t("common.status")} value={status} onChange={(e) => setStatus(e.target.value)}>
            {["REQUESTED", "APPROVED", "PAID", "REJECTED", ""].map((s) => <option key={s} value={s}>{s ? t(`status.${s}`) : t("common.all")}</option>)}
          </select>
        </div>
        <Loaded state={wds}>{({ withdrawals }) => withdrawals.length === 0 ? <Empty icon="payments" title={t("common.noData")} /> : (
          <div className="table-wrap" tabIndex={0}><table className="table">
            <thead><tr><th>{t("common.when")}</th><th>{t("finance.company")}</th><th className="num">{t("common.amount")}</th><th>{t("finance.account")}</th><th>{t("finance.approvals")}</th><th>{t("common.status")}</th><th>{t("common.actions")}</th></tr></thead>
            <tbody>{withdrawals.map((w) => {
              const waitingSecond = w.status === "APPROVED" && w.needs_second && !w.second_approver;
              return (
                <tr key={w.uid}>
                  <td className="small">{dateTime(w.created_at)}<div className="muted">{w.requested_by_name}</div></td>
                  <td>{w.company_name}</td><td className="num">{money(w.amount)}</td>
                  <td className="small">{w.bank_name} ···· <span className="ltr mono">{w.iban_last4}</span></td>
                  <td className="small">{w.needs_second ? t("finance.twoNeeded") : t("finance.oneNeeded")}{waitingSecond && <div className="chip wheat">{t("finance.waitingSecond")}</div>}</td>
                  <td><Status value={w.status} /></td>
                  <td><div className="row nowrap" style={{ gap: 4 }}>
                    {(w.status === "REQUESTED" || waitingSecond) && <button className="btn tonal small" disabled={busy}
                      onClick={() => act(() => api.post(`/api/admin/finance/withdrawals/${w.uid}/approve`), t("finance.approved"))}>{t("admin.approve")}</button>}
                    {w.status === "APPROVED" && !waitingSecond && <button className="btn small" onClick={() => openPay(w)}>{t("finance.recordTransfer")}</button>}
                    {(w.status === "REQUESTED" || w.status === "APPROVED") && <button className="btn text small" onClick={() => { setReject(w); setReason(""); setError(null); }}>{t("admin.reject")}</button>}
                  </div></td>
                </tr>
              );
            })}</tbody>
          </table></div>
        )}</Loaded>
        <p className="small muted">{t("finance.fourEyes")}</p>
      </div>
      <div className="grid split" style={{ alignItems: "start" }}>
        <div className="card">
          <div className="card-title"><h3>{t("finance.statements")}</h3><button className="btn tonal small" onClick={() => { setRunOpen(true); setError(null); }}><Icon name="add" />{t("finance.draft")}</button></div>
          <Loaded state={sts}>{({ settlements }) => settlements.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
            <div className="table-wrap" tabIndex={0}><table className="table">
              <thead><tr><th>{t("finance.company")}</th><th>{t("finance.period")}</th><th className="num">{t("finance.net")}</th><th>{t("common.status")}</th><th /></tr></thead>
              <tbody>{settlements.map((s) => (
                <tr key={s.uid}><td>{s.company_name}</td><td className="small">{date(`${s.period_from}T12:00:00Z`)} – {date(`${s.period_to}T12:00:00Z`)}</td>
                  <td className="num">{money(s.net)}</td><td><Status value={s.status} /></td>
                  <td><div className="row nowrap" style={{ gap: 4 }}>
                    <button className="btn text small" onClick={() => setView(s.uid)}>{t("common.view")}</button>
                    {s.status === "DRAFT" && <button className="btn tonal small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/finance/settlements/${s.uid}/approve`), t("finance.approved"))}>{t("admin.approve")}</button>}
                  </div></td></tr>
              ))}</tbody>
            </table></div>
          )}</Loaded>
        </div>
        <div className="card">
          <div className="card-title"><h3>{t("finance.accountsToVerify")}</h3></div>
          <Loaded state={accounts}>{({ accounts: list }) => list.length === 0 ? <Empty icon="verified" title={t("common.noData")} /> : (
            <div className="stack tight">{list.map((a) => (
              <div key={a.uid} className="row between"><span>{a.company_name}<div className="small muted">{a.bank_name} · {a.holder_name} · ···· <span className="ltr mono">{a.iban_last4}</span></div></span>
                <button className="btn tonal small" disabled={busy} onClick={() => act(() => api.post(`/api/admin/finance/bank-accounts/${a.uid}/verify`), t("finance.verified"))}>{t("finance.verify")}</button></div>
            ))}</div>
          )}</Loaded>
        </div>
      </div>
      {reject && (
        <Modal title={`${t("admin.reject")} · ${money(reject.amount)}`} onClose={() => setReject(null)}
               actions={<><button className="btn text" onClick={() => setReject(null)}>{t("common.cancel")}</button>
                 <button className="btn danger" disabled={busy || reason.trim().length < 3} onClick={() => act(() => api.post(`/api/admin/finance/withdrawals/${reject.uid}/reject`, { reason }), t("common.saved"), () => setReject(null))}>{t("common.confirm")}</button></>}>
          <div className="stack"><ErrorBox error={error} /><Field label={t("common.reason")}><textarea className="input" value={reason} onChange={(e) => setReason(e.target.value)} /></Field></div>
        </Modal>
      )}
      {pay && (
        <Modal title={t("finance.recordTransfer")} onClose={() => setPay(null)}
               actions={<><button className="btn text" onClick={() => setPay(null)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || pay.ref.trim().length < 3} onClick={() => act(() => api.post(`/api/admin/finance/withdrawals/${pay.w.uid}/paid`, { bank_ref: pay.ref.trim() }), t("finance.paid"), () => setPay(null))}>{t("finance.markPaid")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            {pay.details && (
              <dl className="kv">
                <dt>{t("finance.holder")}</dt><dd>{pay.details.holder}</dd>
                <dt>{t("finance.bankName")}</dt><dd>{pay.details.bank}</dd>
                <dt>IBAN</dt><dd className="ltr mono">{pay.details.iban}</dd>
                <dt>{t("common.amount")}</dt><dd>{money(pay.details.amount)}</dd>
              </dl>
            )}
            <div className="alert warn"><Icon name="shield" /><span>{t("finance.revealLogged")}</span></div>
            <Field label={t("finance.bankRef")}><input className="input ltr mono" value={pay.ref} onChange={(e) => setPay({ ...pay, ref: e.target.value.replace(/[^0-9A-Za-z\-/]/g, "") })} /></Field>
          </div>
        </Modal>
      )}
      {runOpen && (
        <Modal title={t("finance.draft")} onClose={() => setRunOpen(false)}
               actions={<><button className="btn text" onClick={() => setRunOpen(false)}>{t("common.cancel")}</button>
                 <button className="btn" disabled={busy || !runF.company || !runF.from || !runF.to} onClick={() => act(() => api.post("/api/admin/finance/settlements",
                   { company_uid: runF.company, period_from: runF.from, period_to: runF.to }), t("common.saved"), () => setRunOpen(false))}>{t("common.create")}</button></>}>
          <div className="stack">
            <ErrorBox error={error} />
            <Field label={t("finance.company")}>
              <select className="input" value={runF.company} onChange={(e) => setRunF({ ...runF, company: e.target.value })}>
                <option value="" disabled>—</option>
                {(companies.data?.companies ?? []).filter((c) => c.company_type !== "AGENCY").map((c) => <option key={c.uid} value={c.uid}>{c.legal_name}</option>)}
              </select>
            </Field>
            <div className="grid cols-2">
              <Field label={t("common.from")}><input className="input ltr" type="date" value={runF.from} onChange={(e) => setRunF({ ...runF, from: e.target.value })} /></Field>
              <Field label={t("common.to")}><input className="input ltr" type="date" value={runF.to} onChange={(e) => setRunF({ ...runF, to: e.target.value })} /></Field>
            </div>
            <p className="small muted">{t("finance.draftNote")}</p>
          </div>
        </Modal>
      )}
      {view && <SettlementView uid={view} base="/api/admin/finance" onClose={() => setView(null)} />}
      {can("compensation.pay") && <ClaimsToPay />}
    </div>
  );
}
