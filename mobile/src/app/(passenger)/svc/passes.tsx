import { useState } from "react";
import { Alert, Pressable, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { randomUUID } from "expo-crypto";
import QRCode from "react-native-qrcode-svg";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, Empty, ErrorText, Loading, Screen, SvcHeader, s } from "../../../ui/kit";
import { Lockup } from "../../../ui/brand";
import { color, font, radius } from "../../../ui/theme";
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
      <SvcHeader icon="pass" title={t("svc.passes.title")} sub={t("svc.passes.hint")} onBack={() => router.back()} />
      <ErrorText error={error ?? plans.error ?? mine.error} />
      {active.map((x) => (
        <View key={x.uid} style={ps.pass}>
          <View style={s.between}>
            <Lockup height={22} white />
            <Chip label={labels.value(x.status)} tone={tone(x.status)} />
          </View>
          <Text style={ps.plan}>{x.plan}</Text>
          <Text style={ps.meta}>{x.operator} · {t("svc.passes.until", { date: date(x.ends_on) })}</Text>
          {x.rides_limit ? (
            <View style={{ gap: 6 }}>
              <Text style={ps.meta}>{t("svc.passes.rides", { n: x.rides_used, max: x.rides_limit })}</Text>
              <View style={ps.track}><View style={[ps.fill, { width: `${Math.min(100, (100 * x.rides_used) / x.rides_limit)}%` }]} /></View>
            </View>
          ) : null}
          {x.pass_no ? (open === x.uid ? (
            <View style={{ alignItems: "center", gap: 8, paddingTop: 8 }}>
              <View style={ps.qr}><QRCode value={x.pass_no} size={190} color={color.navy} backgroundColor="#fff" /></View>
              <Text style={ps.no}>{x.pass_no}</Text>
              <Text style={ps.meta}>{t("svc.passes.show")}</Text>
            </View>
          ) : (
            <Pressable onPress={() => setOpen(x.uid)} accessibilityRole="button" style={({ pressed }) => [ps.open, pressed && { opacity: 0.85 }]}>
              <Text style={ps.openText}>{t("svc.passes.open")}</Text>
            </Pressable>
          )) : null}
        </View>
      ))}
      <Text style={s.section}>{t("svc.passes.plans")}</Text>
      {plans.loading && !plans.data ? <Loading /> : null}
      {plans.data && plans.data.plans.length === 0 ? <Empty icon="pass" text={t("svc.passes.noPlans")} /> : null}
      {plans.data?.plans.map((p) => (
        <Card key={p.id}>
          <View style={s.between}>
            <Text style={[s.h2, { flex: 1 }]}>{p.name}</Text>
            <Text style={s.price}>{money(p.price)}</Text>
          </View>
          <Text style={s.small}>{p.operator}{p.line ? ` · ${p.line}` : ""}{p.zone ? ` · ${p.zone}` : ""}</Text>
          <Text style={s.small}>{t("svc.passes.period", { days: p.period_days })}{p.rides_limit ? ` · ${t("svc.passes.limit", { n: p.rides_limit })}` : ` · ${t("svc.passes.unlimited")}`}</Text>
          <Button label={t("svc.passes.buy")} busy={busy === p.id} disabled={busy !== null} onPress={() => buy(p)} />
        </Card>
      ))}
    </Screen>
  );
}

const ps = StyleSheet.create({
  pass: { backgroundColor: color.navy, borderRadius: radius.lg, padding: 18, gap: 8 },
  plan: { fontFamily: font.displayBold, fontSize: 22, color: "#fff" },
  meta: { fontFamily: font.body, fontSize: 13, color: "#B8C2CF" },
  track: { height: 6, borderRadius: 3, backgroundColor: "#24385A", overflow: "hidden" },
  fill: { height: 6, borderRadius: 3, backgroundColor: color.arrival },
  qr: { padding: 12, backgroundColor: "#fff", borderRadius: radius.md },
  no: { fontFamily: font.mono, fontSize: 16, color: "#fff", letterSpacing: 2 },
  open: { marginTop: 6, minHeight: 46, borderRadius: radius.sm, backgroundColor: "#fff", alignItems: "center", justifyContent: "center" },
  openText: { fontFamily: font.display, fontSize: 16, color: color.navy },
});
