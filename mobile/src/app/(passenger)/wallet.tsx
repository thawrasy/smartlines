import { useEffect, useRef, useState } from "react";
import { AppState, Linking, Text, View } from "react-native";
import { usePreventScreenCapture } from "expo-screen-capture";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { API_URL } from "../../platform/config";
import { Button, Card, Choice, ErrorText, Field, Loading, Notice, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

interface Wallet { balance: number; sandbox: boolean; entries: { direction: "DR" | "CR"; amount: number; created_at: string; txn_type: string }[] }
interface Method { code: string; adapter: string; min_amount: number; max_amount: number; fee_pct: number; fee_borne_by: string }
interface Started { uid: string; status: string; action?: string; url?: string | null; test_code?: string; reference?: string; expires_at?: string | null;
                    bank?: { bank_name: string; account_name: string; iban: string }; amount: number }

const AMOUNTS = [50_000, 100_000, 250_000, 500_000];   // pounds

/** Wallet: balance, history and top-up by card (bank page), e-wallet (code), bank transfer (reference) or cash at an agency. */
export default function WalletScreen() {
  usePreventScreenCapture();
  const { t, money, date, time } = useI18n();
  const w = useLoad(() => api.get<Wallet>("/api/wallet"));
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
      {done ? <Notice tone="green" text={done} /> : null}

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

function Kv({ label, value, mono, big }: { label: string; value?: string | null; mono?: boolean; big?: boolean }) {
  return (
    <View style={{ gap: 2 }}>
      <Text style={s.small}>{label}</Text>
      <Text selectable style={[s.label, mono && { fontFamily: "monospace", writingDirection: "ltr" }, big && { fontSize: 22, fontWeight: "700", color: color.navy }]}>{value || "—"}</Text>
    </View>
  );
}
