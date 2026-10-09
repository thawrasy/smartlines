import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { api, newKey } from "../../api";
import { useI18n } from "../../i18n";
import { PageHead } from "../../components/layout";
import { Empty, ErrorBox, Field, Icon, Loaded, Modal, Spinner, useLoad, useToast } from "../../components/ui";
import type { IconName } from "../../components/icons";

interface WalletData {
  currency: string; balance: number; sandbox: boolean;
  entries: { direction: "DR" | "CR"; amount: number; balance_after: number; created_at: string; txn_type: string; memo: string | null }[];
}
interface Method { code: string; name: string; kind: string; adapter: string; min_amount: number; max_amount: number; fee_pct: number; fee_fixed: number; fee_borne_by: string; fee_label: string | null }
interface Quote { amount: number; fee: number; total: number; fee_label: string | null; fee_borne_by: string; fee_absorbed: number }
interface Started {
  uid: string; status: string; stage: string; amount: number; action: "REDIRECT" | "OTP" | "TRANSFER" | "DONE"; url?: string | null;
  reference?: string; expires_at?: string | null; test_code?: string; bank?: { bank_name: string; account_name: string; iban: string };
}
interface Mine { uid: string; status: string; stage: string; amount: number; method: string; provider: string; created_at: string; expires_at: string | null; reference: string | null; failure_code: string | null }

const ICON: Record<string, IconName> = { HOSTED_CARD: "payments", PARTNER_WALLET: "account_balance_wallet", BANK_TRANSFER: "account_balance", CASH_AGENT: "store", SANDBOX: "verified" };

export default function Wallet() {
  const { t, money, dateTime, has } = useI18n();
  const toast = useToast();
  const [params, setParams] = useSearchParams();
  const state = useLoad(() => api.get<WalletData>("/api/wallet"));
  const mine = useLoad(() => api.get<{ payments: Mine[] }>("/api/payments/mine"));
  const [open, setOpen] = useState(false);

  // back from a payment page: follow the payment until the provider's answer arrives
  const returning = params.get("payment");
  useEffect(() => {
    if (!returning) return;
    let tries = 0;
    const id = setInterval(async () => {
      tries += 1;
      try {
        const p = await api.get<{ status: string; failure_code: string | null }>(`/api/payments/${returning}`);
        if (p.status !== "PENDING" || tries > 20) {
          clearInterval(id);
          if (p.status === "SUCCESS") toast(t("pay.credited"));
          else if (p.status === "FAILED") toast(t("pay.failed"));
          setParams({}, { replace: true }); state.reload(); mine.reload();
        }
      } catch { clearInterval(id); }
    }, 1500);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [returning]);

  const pending = (mine.data?.payments ?? []).filter((p) => p.status === "PENDING");
  const cancel = async (p: Mine) => { await api.post(`/api/payments/${p.uid}/cancel`).catch(() => {}); mine.reload(); };
  return (
    <div className="page stack">
      <PageHead title={t("wallet.title")} sub={t("wallet.subtitle")} />
      <Loaded state={state}>{(w) => (
        <>
          <div className="card hero row between">
            <div>
              <div className="muted">{t("wallet.balance")}</div>
              <div style={{ fontSize: 40, fontWeight: 700 }} className="mono">{money(w.balance)}</div>
            </div>
            <div className="stack tight" style={{ alignItems: "flex-end" }}>
              {w.sandbox && <span className="sandbox-tag">{t("app.sandbox")}</span>}
              <button className="btn large" onClick={() => setOpen(true)}><Icon name="add" />{t("wallet.topup")}</button>
            </div>
          </div>
          {returning && <div className="alert info"><Spinner /> {t("pay.waiting")}</div>}
          {pending.length > 0 && (
            <div className="card stack">
              <h3 style={{ margin: 0 }}>{t("pay.pending")}</h3>
              {pending.map((p) => (
                <div key={p.uid} className="row between" style={{ gap: 12, flexWrap: "wrap", borderTop: "1px solid var(--divider)", paddingTop: 10 }}>
                  <div>
                    <strong>{money(p.amount)}</strong> · {t(`pay.provider.${p.provider}`)}
                    {p.reference && <div className="small">{t("pay.reference")}: <span className="mono ltr">{p.reference}</span></div>}
                    {p.expires_at && <div className="small muted">{t("pay.until", { when: dateTime(p.expires_at) })}</div>}
                  </div>
                  <button className="btn text small" onClick={() => cancel(p)}>{t("common.cancel")}</button>
                </div>
              ))}
            </div>
          )}
          <div className="card">
            <div className="card-title"><h3>{t("wallet.statement")}</h3></div>
            {w.entries.length === 0 ? <Empty icon="receipt_long" title={t("common.noData")} /> : (
              <div className="table-wrap" tabIndex={0}><table className="table">
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
      {open && <TopupModal onClose={() => setOpen(false)} onDone={() => { setOpen(false); state.reload(); mine.reload(); }} />}
    </div>
  );
}

function TopupModal({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const { t, money, dateTime } = useI18n();
  const toast = useToast();
  const navigate = useNavigate();
  const methods = useLoad(() => api.get<{ methods: Method[] }>("/api/payments/methods"));
  const [method, setMethod] = useState<Method | null>(null);
  const [amount, setAmount] = useState(100000);
  const [mobile, setMobile] = useState("");
  const [started, setStarted] = useState<Started | null>(null);
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [key] = useState(newKey);
  const minor = amount * 100;
  const inRange = method ? minor >= method.min_amount && minor <= method.max_amount : false;
  // what the payer will be asked for, the platform's fee included, before paying (owner's decision 4)
  const priced = method && inRange && !["BANK_TRANSFER", "CASH_AGENT", "SANDBOX"].includes(method.adapter);
  const quote = useLoad<Quote | null>(() => (priced ? api.get<Quote>("/api/payments/quote", { method: method.code, amount: minor }) : Promise.resolve(null)),
    [method?.code, minor, priced]);

  const start = async () => {
    if (!method) return;
    setBusy(true); setError(null);
    try {
      if (method.adapter === "BANK_TRANSFER") {
        setStarted(await api.post<Started>("/api/payments/bank-transfers", { amount: minor, idempotency_key: key }));
      } else {
        const s = await api.post<Started>("/api/payments/topups", { method: method.code, amount: minor, idempotency_key: key, mobile: mobile || undefined });
        if (s.action === "REDIRECT" && s.url) {
          if (s.url.startsWith("/")) navigate(s.url); else window.location.assign(s.url);
          return;
        }
        if (s.action === "DONE") { toast(t("pay.credited")); onDone(); return; }
        setStarted(s);
      }
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const confirm = async () => {
    if (!started) return;
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ status: string }>(`/api/payments/${started.uid}/code`, { code });
      if (r.status === "SUCCESS") { toast(t("pay.credited")); onDone(); } else setError(new Error("pending"));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const copy = (v: string) => { navigator.clipboard?.writeText(v).then(() => toast(t("pay.copied"))).catch(() => {}); };

  let body;
  if (started?.action === "TRANSFER") {
    body = (
      <div className="stack">
        <div className="alert info"><Icon name="account_balance" />{t("pay.transferHow")}</div>
        <dl className="kv">
          <dt>{t("pay.bank")}</dt><dd>{started.bank?.bank_name}</dd>
          <dt>{t("pay.accountName")}</dt><dd>{started.bank?.account_name}</dd>
          <dt>IBAN</dt><dd className="mono ltr">{started.bank?.iban} <button className="btn text small" onClick={() => copy(started.bank?.iban ?? "")}><Icon name="content_copy" /></button></dd>
          <dt>{t("pay.amount")}</dt><dd className="mono">{money(started.amount)}</dd>
          <dt>{t("pay.reference")}</dt><dd><strong className="mono ltr" style={{ fontSize: 20 }}>{started.reference}</strong> <button className="btn text small" onClick={() => copy(started.reference ?? "")}><Icon name="content_copy" /></button></dd>
          {started.expires_at && <><dt>{t("pay.validUntil")}</dt><dd>{dateTime(started.expires_at)}</dd></>}
        </dl>
        <p className="small muted">{t("pay.transferNote")}</p>
      </div>
    );
  } else if (started?.action === "OTP") {
    body = (
      <div className="stack">
        <div className="alert info"><Icon name="account_balance_wallet" />{t("pay.codeSent")}</div>
        {started.test_code && <div className="alert warn"><Icon name="warning" />{t("pay.testCode", { code: started.test_code })}</div>}
        <Field label={t("pay.code")}><input className="input ltr mono" inputMode="numeric" maxLength={8} value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))} autoFocus /></Field>
      </div>
    );
  } else {
    body = (
      <div className="stack">
        <Loaded state={methods}>{(m) => (
          <div className="grid cols-2" style={{ gap: 10 }}>
            {m.methods.map((x) => (
              <button key={x.code} type="button" className={`card method-card${method?.code === x.code ? " on" : ""}`} onClick={() => setMethod(x)}
                      style={{ textAlign: "start", cursor: "pointer", padding: 14 }}>
                <div className="row" style={{ gap: 8 }}><Icon name={ICON[x.adapter] ?? "payments"} /><strong style={{ whiteSpace: "nowrap" }}>{t(`pay.provider.${x.code}`)}</strong></div>
                <div className="small muted" style={{ marginTop: 4 }}>{t(`pay.hint.${x.adapter}`)}</div>
              </button>
            ))}
          </div>
        )}</Loaded>
        {method && method.adapter === "CASH_AGENT" ? (
          <div className="alert info"><Icon name="store" />{t("pay.agentHow")}</div>
        ) : method && (
          <>
            <Field label={t("wallet.amount")} hint={t("pay.limits", { min: money(method.min_amount), max: money(method.max_amount) })}>
              <input className="input ltr" type="number" min={method.min_amount / 100} step={1000} value={amount} onChange={(e) => setAmount(Number(e.target.value))} />
            </Field>
            <div className="row">{[50000, 100000, 250000, 500000].map((v) => (
              <button key={v} type="button" className={`chip chip-select${amount === v ? " on" : ""}`} onClick={() => setAmount(v)}>{money(v * 100)}</button>
            ))}</div>
            {method.adapter === "PARTNER_WALLET" && (
              <Field label={t("pay.mobile")} hint={t("pay.mobileHint")}><input className="input ltr" inputMode="tel" placeholder="+9639…" value={mobile} onChange={(e) => setMobile(e.target.value.trim())} /></Field>
            )}
            {quote.data && (quote.data.fee > 0
              ? <p className="small">{t("pay.feeLine", { fee: money(quote.data.fee), total: money(quote.data.total) })}{quote.data.fee_label ? ` · ${quote.data.fee_label}` : ""}</p>
              : <p className="small muted">{quote.data.fee_absorbed > 0 ? t("pay.feeOnUs") : t("pay.noFee")}</p>)}
          </>
        )}
      </div>
    );
  }
  const action = started?.action === "TRANSFER"
    ? <button className="btn" onClick={onDone}>{t("pay.done")}</button>
    : started?.action === "OTP"
      ? <button className="btn" disabled={busy || code.length < 4} onClick={confirm}>{busy ? <Spinner /> : <Icon name="check_circle" />}{t("pay.confirm")}</button>
      : <button className="btn" disabled={busy || !method || method.adapter === "CASH_AGENT" || !inRange || (method.adapter === "PARTNER_WALLET" && !/^\+?\d{8,15}$/.test(mobile))} onClick={start}>
          {busy ? <Spinner /> : <Icon name="arrow_forward" />}{method?.adapter === "BANK_TRANSFER" ? t("pay.getReference") : t("pay.continue", { amount: money(quote.data?.total ?? minor) })}
        </button>;
  return (
    <Modal title={t("wallet.topupTitle")} onClose={onClose} wide actions={<><button className="btn text" onClick={onClose}>{t("common.close")}</button>{action}</>}>
      {body}
      <ErrorBox error={error} />
    </Modal>
  );
}

/** The built-in test gateway (sandbox only): stands in for a bank's hosted payment page. */
export function TestGateway({ uid }: { uid: string }) {
  const { t, money } = useI18n();
  const navigate = useNavigate();
  const state = useLoad(() => api.get<{ amount: number; status: string; provider: string; code: string }>(`/api/payments/test/${uid}`), [uid]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const decide = async (approve: boolean) => {
    setBusy(true);
    try {
      const r = await api.post<{ return_to: string }>(`/api/payments/test/${uid}`, { approve });
      navigate(r.return_to);
    } catch (e) { setError(e); setBusy(false); }
  };
  return (
    <div className="page" style={{ maxWidth: 480 }}>
      <div className="card stack">
        <div className="alert warn"><Icon name="warning" />{t("pay.testGateway")}</div>
        <Loaded state={state}>{(p) => (
          <>
            <h2 style={{ margin: 0 }}>{money(p.amount)}</h2>
            <p className="muted" style={{ margin: 0 }}>{t(`pay.provider.${p.code}`)}</p>
            <Field label={t("pay.cardNumber")}><input className="input ltr mono" defaultValue="4242 4242 4242 4242" readOnly /></Field>
            <div className="grid cols-2">
              <Field label={t("pay.expiry")}><input className="input ltr mono" defaultValue="12/29" readOnly /></Field>
              <Field label="CVC"><input className="input ltr mono" defaultValue="123" readOnly /></Field>
            </div>
            {p.status !== "PENDING" ? <div className="alert info">{t("pay.alreadyDone")}</div> : (
              <div className="row" style={{ gap: 8 }}>
                <button className="btn" disabled={busy} onClick={() => decide(true)}><Icon name="check_circle" />{t("pay.approve")}</button>
                <button className="btn danger" disabled={busy} onClick={() => decide(false)}><Icon name="cancel" />{t("pay.decline")}</button>
              </div>
            )}
          </>
        )}</Loaded>
        <ErrorBox error={error} />
      </div>
    </div>
  );
}
