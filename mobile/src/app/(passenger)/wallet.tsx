import { useState } from "react";
import { Text, View } from "react-native";
import { usePreventScreenCapture } from "expo-screen-capture";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

interface Wallet { balance: number; sandbox: boolean; entries: { direction: "DR" | "CR"; amount: number; created_at: string; txn_type: string }[] }

export default function WalletScreen() {
  usePreventScreenCapture();
  const { t, money, date, time } = useI18n();
  const w = useLoad(() => api.get<Wallet>("/api/wallet"));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const topup = async () => {
    setBusy(true); setError(null);
    try { await api.post("/api/wallet/topup", { amount: 50_000_00, idempotency_key: randomUUID() }); w.reload(); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Screen>
      <Title>{t("tabs.wallet")}</Title>
      {w.loading && !w.data ? <Loading /> : <ErrorText error={w.error ?? error} />}
      {w.data ? (
        <>
          <Card style={{ backgroundColor: color.navy, borderColor: color.navy }}>
            <Text style={{ color: "#C9D6EA" }}>{t("wallet.balance")}</Text>
            <Text style={{ color: "#fff", fontSize: 32, fontWeight: "700" }}>{money(w.data.balance)}</Text>
          </Card>
          {w.data.sandbox ? <Button kind="tonal" label={t("wallet.topup")} busy={busy} onPress={topup} /> : null}
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
