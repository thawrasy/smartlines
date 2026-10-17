import { useEffect, useRef, useState } from "react";
import { AppState, Linking, Text, View } from "react-native";
import { usePreventScreenCapture } from "expo-screen-capture";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../i18n";
import { api, ApiError } from "../../platform/api";
import { API_URL } from "../../platform/config";
import { getJSON, putJSON } from "../../platform/secure";
import { Button, Card, Choice, ErrorText, Field, Loading, Notice, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

interface Wallet { balance: number; sandbox: boolean; entries: { direction: "DR" | "CR"; amount: number; created_at: string; txn_type: string }[] }
interface WalletView extends Wallet { checkedAt: string; offline: boolean }
interface Method { code: string; adapter: string; min_amount: number; max_amount: number; fee_pct: number; fee_borne_by: string }
interface Started { uid: string; status: string; action?: string; url?: string | null; test_code?: string; reference?: string; expires_at?: string | null;
                    bank?: { bank_name: string; account_name: string; iban: string }; amount: number }

const AMOUNTS = [50_000, 100_000, 250_000, 500_000];   // pounds

/** Wallet: balance, history and top-up by card (bank page), e-wallet (code), bank transfer (reference) or cash at an agency. */
export default function WalletScreen() {
  usePreventScreenCapture();
  const { t, money, date, time } = useI18n();
  // the last balance stays on the device (keystore, cleared at sign-out): without a connection it is shown read-only
  const w = useLoad<WalletView>(async () => {
    try {
      const view: WalletView = { ...(await api.get<Wallet>("/api/wallet")), checkedAt: new Date().toISOString(), offline: false };
      try { await putJSON("wallet", view); } catch { /* no copy when the device store is unavailable */ }
      return view;
    } catch (e) {
      const last = e instanceof ApiError && e.status === 0 ? await getJSON<WalletView>("wallet").catch(() => null) : null;
      if (last) return { ...last, offline: true };
      throw e;
    }
  });
  const methods = useLoad(() => api.get<{ methods: Method[] }>("/api/payments/methods"));
  const [method, setMethod] = useState<string | null>(null);
  const [amount, setAmount] = useState(100_000);
  const [mobile, setMobile] = useState("");
  const [code, setCode] = useState("");
  const [started, setStarted] = useState<Started | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [done, setDone] = useState<string | null>(null);
  const waiting = useRef<string | null>(null);
  const m = methods.data?.methods.find((x) => x.code === method);

  const finished = (status: string) => {
    setDone(status === "SUCCESS" ? t("pay.credited") : t("pay.failed"));
    setStarted(null); setMethod(null); setCode(""); w.reload();
  };
  // back from the bank's page: follow the payment until the provider's answer arrives
  useEffect(() => {
    const sub = AppState.addEventListener("change", (state) => {
      const uid = waiting.current;
      if (state !== "active" || !uid) return;
      let tries = 0;
      const id = setInterval(async () => {
        tries += 1;
        try {
          const p = await api.get<{ status: string }>(`/api/payments/${uid}`);
          if (p.status !== "PENDING" || tries > 15) { clearInterval(id); waiting.current = null; if (p.status !== "PENDING") finished(p.status); }
        } catch { clearInterval(id); }
      }, 2000);
    });
    return () => sub.remove();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const run = async (fn: () => Promise<void>) => {
    setBusy(true); setError(null); setDone(null);
    try { await fn(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const start = () => run(async () => {
    if (!m) return;
    const minor = amount * 100;
    if (m.adapter === "BANK_TRANSFER") {
      setStarted(await api.post<Started>("/api/payments/bank-transfers", { amount: minor, idempotency_key: randomUUID() }));
      return;
    }
    const r = await api.post<Started>("/api/payments/topups", { method: m.code, amount: minor, idempotency_key: randomUUID(),
                                                                 mobile: m.adapter === "PARTNER_WALLET" ? mobile.trim() : undefined });
    if (r.action === "DONE" || r.status === "SUCCESS") { finished("SUCCESS"); return; }
    setStarted(r);
    if (r.action === "REDIRECT" && r.url && !r.url.startsWith("/pay/test/")) {
      waiting.current = r.uid;
      await Linking.openURL(r.url.startsWith("/") ? `${API_URL}${r.url}` : r.url);
    }
  });
  const confirm = () => run(async () => {
    const r = await api.post<{ status: string }>(`/api/payments/${started!.uid}/code`, { code: code.trim() });
    finished(r.status);
  });
  const testDecide = (approve: boolean) => run(async () => {
    await api.post(`/api/payments/test/${started!.uid}`, { approve });
    const p = await api.get<{ status: string }>(`/api/payments/${started!.uid}`);
    finished(p.status);
  });
  const valid = m && amount * 100 >= m.min_amount && amount * 100 <= m.max_amount && (m.adapter !== "PARTNER_WALLET" || /^\+?\d{8,15}$/.test(mobile.trim()));

  return (
    <Screen>
      <Title>{t("tabs.wallet")}</Title>
      {w.loading && !w.data ? <Loading /> : <ErrorText error={w.error} />}
      {w.data ? (
        <Card style={{ backgroundColor: color.navy, borderColor: color.navy }}>
          <Text style={{ color: "#C9D6EA" }}>{t("wallet.balance")}</Text>
          <Text style={{ color: "#fff", fontSize: 32, fontWeight: "700" }}>{money(w.data.balance)}</Text>
        </Card>
      ) : null}
      {w.data?.offline ? <Notice tone="amber" text={t("wallet.offline", { time: `${date(w.data.checkedAt)} · ${time(w.data.checkedAt)}` })} /> : null}
      {done ? <Notice tone="green" text={done} /> : null}
      {w.data?.offline ? null : <Points onRedeemed={(text) => { setDone(text); w.reload(); }} />}

      {w.data?.offline ? null : (
        <Card>
          <Text style={s.h2}>{t("pay.topup")}</Text>
          {!started ? (
            <>
              {(methods.data?.methods ?? []).filter((x) => x.adapter !== "SANDBOX" || w.data?.sandbox).map((x) => (
                <Button key={x.code} kind={method === x.code ? "primary" : "tonal"} label={t(`pay.provider.${x.code}`)} onPress={() => { setMethod(x.code); setError(null); }} />
              ))}
              {m ? <Text style={s.small}>{t(`pay.hint.${m.adapter}`)}</Text> : null}
              {m && m.adapter === "CASH_AGENT" ? <Notice text={t("pay.agentHow")} /> : null}
              {m && m.adapter !== "CASH_AGENT" ? (
                <>
                  <Choice label={t("pay.amount")} value={amount} onChange={setAmount} options={AMOUNTS.map((a) => ({ value: a, label: money(a * 100) }))} />
                  <Text style={s.small}>{t("pay.limits", { min: money(m.min_amount), max: money(m.max_amount) })}</Text>
                  {m.adapter === "PARTNER_WALLET" ? <Field label={t("pay.mobile")} hint={t("pay.mobileHint")} value={mobile} onChangeText={setMobile} keyboardType="phone-pad" /> : null}
                  {m.fee_pct > 0 && m.fee_borne_by === "PLATFORM" ? <Text style={s.small}>{t("pay.noFee")}</Text> : null}
                  <Button label={m.adapter === "BANK_TRANSFER" ? t("pay.getReference") : t("pay.continue", { amount: money(amount * 100) })}
                          busy={busy} disabled={!valid} onPress={start} />
                </>
              ) : null}
            </>
          ) : started.reference ? (
            <>
              <Notice text={t("pay.transferHow")} />
              <Kv label={t("pay.bank")} value={started.bank?.bank_name} />
              <Kv label={t("pay.accountName")} value={started.bank?.account_name} />
              <Kv label="IBAN" value={started.bank?.iban} mono />
              <Kv label={t("pay.amount")} value={money(started.amount)} />
              <Kv label={t("pay.reference")} value={started.reference} mono big />
              {started.expires_at ? <Kv label={t("pay.validUntil")} value={`${date(started.expires_at)} · ${time(started.expires_at)}`} /> : null}
              <Text style={s.small}>{t("pay.transferNote")}</Text>
              <Button kind="tonal" label={t("pay.done")} onPress={() => { setStarted(null); setMethod(null); }} />
            </>
          ) : started.action === "OTP" ? (
            <>
              <Notice text={t("pay.codeSent")} />
              {started.test_code ? <Notice tone="amber" text={t("pay.testCode", { code: started.test_code })} /> : null}
              <Field label={t("pay.code")} value={code} onChangeText={setCode} keyboardType="number-pad" maxLength={8} />
              <Button label={t("pay.confirm")} busy={busy} disabled={code.trim().length < 4} onPress={confirm} />
            </>
          ) : started.url?.startsWith("/pay/test/") ? (
            <>
              <Notice tone="amber" text={t("pay.testGateway")} />
              <Kv label={t("pay.amount")} value={money(started.amount)} big />
              <Button label={t("pay.approve")} busy={busy} onPress={() => testDecide(true)} />
              <Button kind="danger" label={t("pay.decline")} disabled={busy} onPress={() => testDecide(false)} />
            </>
          ) : (
            <>
              <Notice text={t("pay.waiting")} />
              <Button kind="tonal" label={t("pay.openAgain")} onPress={() => started.url && Linking.openURL(started.url.startsWith("/") ? `${API_URL}${started.url}` : started.url)} />
            </>
          )}
          <ErrorText error={error ?? methods.error} />
        </Card>
      )}

      {w.data ? (
        <>
          <Text style={s.h2}>{t("wallet.history")}</Text>
          {w.data.entries.map((e, i) => (
            <View key={i} style={[s.between, { paddingVertical: 8, borderBottomWidth: 1, borderColor: color.outline }]}>
              <View><Text style={s.label}>{t(`txn.${e.txn_type}`) === `txn.${e.txn_type}` ? e.txn_type : t(`txn.${e.txn_type}`)}</Text><Text style={s.small}>{date(e.created_at)} · {time(e.created_at)}</Text></View>
              <Text style={{ fontWeight: "600", color: e.direction === "CR" ? color.green : color.text }}>
                {e.direction === "CR" ? "+" : "−"}{money(e.amount)}
              </Text>
            </View>
          ))}
        </>
      ) : null}
    </Screen>
  );
}

interface PartnerOffer { agreement: string; partner: string; points: number; amount: number; min_points: number; step_points: number; voucher_days: number }
interface Voucher { voucher: string; partner: string | null; value: number; status: string; code: string | null; expires_at: string | null }
interface PointsView {
  program: { name: string; point_value: number; expiry_months: number; redeem: { min_points: number; step: number } | null } | null;
  account: { balance: number; value: number; tier_name: string | null } | null;
  offers?: PartnerOffer[];
  vouchers?: Voucher[];
}

/** Loyalty points (1103): earned after each trip, turned into wallet credit at the programme's point value. */
function Points({ onRedeemed }: { onRedeemed: (text: string) => void }) {
  const { t, money } = useI18n();
  const v = useLoad(() => api.get<PointsView>("/api/loyalty").catch(() => ({ program: null, account: null }) as PointsView));
  const [points, setPoints] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const p = v.data?.program, a = v.data?.account;
  if (!p) return null;
  const n = Number(points);
  const ok = !!p.redeem && !!a && Number.isInteger(n) && n >= p.redeem.min_points && n % p.redeem.step === 0 && n <= a.balance;
  const redeem = async () => {
    setBusy(true); setError(null);
    try {
      const r = await api.post<{ value: number }>("/api/loyalty/redeem", { points: n, idempotency_key: randomUUID() });
      setPoints(""); v.reload(); onRedeemed(t("points.redeemed", { amount: money(r.value) }));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Card>
      <View style={s.between}><Text style={s.h2}>{p.name}</Text>{a?.tier_name ? <Text style={s.small}>{a.tier_name}</Text> : null}</View>
      <Text style={{ fontSize: 26, fontWeight: "700", color: color.text }}>{a?.balance ?? 0} · {t("points.balance")}</Text>
      <Text style={s.muted}>{t("points.worth", { amount: money(a?.value ?? 0) })}</Text>
      <Text style={s.small}>{t("points.how", { months: p.expiry_months })}</Text>
      {p.redeem && a && a.balance >= p.redeem.min_points ? (
        <>
          <Field label={t("points.amount", { min: p.redeem.min_points, step: p.redeem.step })} value={points}
                 onChangeText={(x) => setPoints(x.replace(/\D/g, ""))} keyboardType="number-pad" />
          <Button kind="tonal" label={t("points.redeem")} busy={busy} disabled={!ok} onPress={redeem} />
        </>
      ) : null}
      <ErrorText error={error} />
      {a && (v.data?.offers?.length ?? 0) > 0 ? <PartnerVoucher offers={v.data!.offers!} balance={a.balance} onDone={v.reload} /> : null}
      {(v.data?.vouchers ?? []).filter((x) => x.status === "ISSUED").map((x) => (
        <View key={x.voucher} style={{ gap: 2, paddingTop: 8, borderTopWidth: 1, borderColor: color.outline }}>
          <Text style={s.label}>{x.partner} · {money(x.value)}</Text>
          <Text selectable style={{ fontFamily: "monospace", fontSize: 18, fontWeight: "700", color: color.navy, writingDirection: "ltr" }}>{x.code}</Text>
          {x.expires_at ? <Text style={s.small}>{t("points.until", { date: x.expires_at.slice(0, 10) })}</Text> : null}
        </View>
      ))}
    </Card>
  );
}

/** Points for a voucher at a partner, at the rate it agreed with the platform (1107). */
function PartnerVoucher({ offers, balance, onDone }: { offers: PartnerOffer[]; balance: number; onDone: () => void }) {
  const { t, money } = useI18n();
  const [pick, setPick] = useState(offers[0].agreement);
  const [points, setPoints] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const o = offers.find((x) => x.agreement === pick) ?? offers[0];
  const n = Number(points);
  const ok = Number.isInteger(n) && n >= o.min_points && n % o.step_points === 0 && n <= balance;
  const submit = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/loyalty/vouchers", { agreement: o.agreement, points: n, idempotency_key: randomUUID() });
      setPoints(""); onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <View style={{ gap: 8, paddingTop: 8, borderTopWidth: 1, borderColor: color.outline }}>
      <Text style={s.h2}>{t("points.partners")}</Text>
      <Choice options={offers.map((x) => ({ value: x.agreement, label: x.partner }))} value={o.agreement} onChange={setPick} />
      <Text style={s.small}>{t("points.rate", { points: o.points, amount: money(o.amount), days: o.voucher_days })}</Text>
      <Field label={t("points.amount", { min: o.min_points, step: o.step_points })} value={points}
             onChangeText={(x) => setPoints(x.replace(/\D/g, ""))} keyboardType="number-pad" />
      <Button kind="tonal" label={t("points.getVoucher")} busy={busy} disabled={!ok} onPress={submit} />
      <ErrorText error={error} />
    </View>
  );
}

function Kv({ label, value, mono, big }: { label: string; value?: string | null; mono?: boolean; big?: boolean }) {
  return (
    <View style={{ gap: 2 }}>
      <Text style={s.small}>{label}</Text>
      <Text selectable style={[s.label, mono && { fontFamily: "monospace", writingDirection: "ltr" }, big && { fontSize: 22, fontWeight: "700", color: color.navy }]}>{value || "—"}</Text>
    </View>
  );
}
