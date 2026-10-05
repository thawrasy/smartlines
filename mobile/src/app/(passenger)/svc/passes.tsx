import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { randomUUID } from "expo-crypto";
import QRCode from "react-native-qrcode-svg";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { useLoad } from "../../../ui/useLoad";

interface Plan { id: number; name: string; period_days: number; rides_limit: number | null; price: number; operator: string; line: string | null; zone: string | null }
interface Sub { uid: string; plan: string; operator: string; starts_on: string; ends_on: string; rides_used: number; rides_limit: number | null; status: string; pass_no: string | null }

/** Shuttle passes: buy a plan from the wallet; the pass is a QR code shown to the driver. */
export default function Passes() {
  const { t, money, date } = useI18n();
  const labels = useLabels();
  const plans = useLoad(() => api.get<{ plans: Plan[] }>("/api/w/subscriptions/plans"));
  const mine = useLoad(() => api.get<{ subscriptions: Sub[] }>("/api/w/subscriptions/mine"));
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [open, setOpen] = useState<string | null>(null);
  const buy = (p: Plan) => Alert.alert(p.name, t("svc.passes.buyQ", { amount: money(p.price) }), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("svc.pay"), onPress: async () => {
      setBusy(p.id); setError(null);
      try { await api.post("/api/w/subscriptions", { plan_id: p.id, idempotency_key: randomUUID() }); mine.reload(); }
      catch (e) { setError(e); } finally { setBusy(null); }
    } },
  ]);
  const active = (mine.data?.subscriptions ?? []).filter((x) => x.status === "ACTIVE");
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={t("svc.passes.hint")}>{t("svc.passes.title")}</Title>
      <ErrorText error={error ?? plans.error ?? mine.error} />
      {active.map((x) => (
        <Card key={x.uid}>
          <View style={s.between}>
            <Text style={s.h2}>{x.plan}</Text>
            <Chip label={labels.value(x.status)} tone={tone(x.status)} />
          </View>
          <Text style={s.small}>{x.operator} · {t("svc.passes.until", { date: date(x.ends_on) })}</Text>
          {x.rides_limit ? <Text style={s.small}>{t("svc.passes.rides", { n: x.rides_used, max: x.rides_limit })}</Text> : null}
          {x.pass_no ? (open === x.uid ? (
            <View style={{ alignItems: "center", gap: 8, paddingVertical: 8 }}>
              <QRCode value={x.pass_no} size={200} />
              <Text style={[s.label, { letterSpacing: 2 }]}>{x.pass_no}</Text>
              <Text style={s.small}>{t("svc.passes.show")}</Text>
            </View>
          ) : <Button kind="tonal" label={t("svc.passes.open")} onPress={() => setOpen(x.uid)} />) : null}
        </Card>
      ))}
      <Text style={s.h2}>{t("svc.passes.plans")}</Text>
      {plans.loading && !plans.data ? <Loading /> : null}
      {plans.data && plans.data.plans.length === 0 ? <Text style={s.muted}>{t("svc.passes.noPlans")}</Text> : null}
      {plans.data?.plans.map((p) => (
        <Card key={p.id}>
          <View style={s.between}>
            <Text style={[s.h2, { flex: 1 }]}>{p.name}</Text>
            <Text style={[s.h2]}>{money(p.price)}</Text>
          </View>
          <Text style={s.small}>{p.operator}{p.line ? ` · ${p.line}` : ""}{p.zone ? ` · ${p.zone}` : ""}</Text>
          <Text style={s.small}>{t("svc.passes.period", { days: p.period_days })}{p.rides_limit ? ` · ${t("svc.passes.limit", { n: p.rides_limit })}` : ` · ${t("svc.passes.unlimited")}`}</Text>
          <Button label={t("svc.passes.buy")} busy={busy === p.id} disabled={busy !== null} onPress={() => buy(p)} />
        </Card>
      ))}
    </Screen>
  );
}
