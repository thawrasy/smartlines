import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, Choice, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { useLoad } from "../../../ui/useLoad";

interface Branch { id: number; station: string; station_code: string; city: string; brand: string; branch_type: string }
interface Offer { rate_id: number; class_name: string; unit: string; price: number; total: number; days: number; deposit: number; km_per_day: number | null; available: number }
interface Booking { uid: string; class_name: string; starts_at: string; ends_at: string; quoted_total: number; status: string; brand: string; pickup: string; pickup_code: string }

function at(daysAhead: number): Date {
  const d = new Date();
  d.setDate(d.getDate() + daysAhead);
  d.setHours(10, 0, 0, 0);
  return d;
}

/** Car rental: a branch, a start day and a length; prices per class with availability; the rental company confirms. */
export default function Rental() {
  const { t, money, station, city, date } = useI18n();
  const labels = useLabels();
  const [branch, setBranch] = useState<number | null>(null);
  const [start, setStart] = useState(1);
  const [days, setDays] = useState(3);
  const startAt = at(start), endAt = at(start + days);
  const data = useLoad(() => api.get<{ branches: Branch[]; offers: Offer[] }>("/api/w/rental/offers", branch
    ? { branch_id: branch, starts_at: startAt.toISOString(), ends_at: endAt.toISOString() } : undefined), [branch, start, days]);
  const mine = useLoad(() => api.get<{ bookings: Booking[] }>("/api/w/rental/bookings/mine"));
  const [busy, setBusy] = useState<number | null>(null);
  const [error, setError] = useState<unknown>(null);
  const book = (o: Offer) => Alert.alert(o.class_name, t("svc.rental.bookQ", { total: money(o.total), deposit: money(o.deposit) }), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("svc.rental.book"), onPress: async () => {
      setBusy(o.rate_id); setError(null);
      try {
        await api.post("/api/w/rental/bookings", { rate_id: o.rate_id, pickup_branch_id: branch, starts_at: startAt.toISOString(), ends_at: endAt.toISOString() });
        mine.reload(); data.reload();
      } catch (e) { setError(e); } finally { setBusy(null); }
    } },
  ]);
  const cancel = (b: Booking) => Alert.alert(t("svc.rental.cancelQ"), "", [
    { text: t("common.back"), style: "cancel" },
    { text: t("svc.cancel"), style: "destructive", onPress: async () => {
      try { await api.post(`/api/w/rental/bookings/${b.uid}/cancel`); mine.reload(); } catch (e) { setError(e); }
    } },
  ]);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={t("svc.rental.hint")}>{t("svc.rental.title")}</Title>
      <Card>
        {data.data ? <Choice label={t("svc.rental.branch")} value={branch} onChange={setBranch}
                             options={data.data.branches.map((b) => ({ value: b.id, label: `${b.brand} · ${station(b.station_code, b.station) || city(b.city)}` }))} />
          : data.loading ? <Loading /> : null}
        <Choice label={t("svc.rental.start")} value={start} onChange={setStart}
                options={[0, 1, 2, 3, 7].map((n) => ({ value: n, label: n === 0 ? t("svc.rental.today") : n === 1 ? t("svc.rental.tomorrow") : date(at(n).toISOString()) }))} />
        <Choice label={t("svc.rental.length")} value={days} onChange={setDays}
                options={[1, 3, 7, 14, 30].map((n) => ({ value: n, label: t("svc.rental.days", { n }) }))} />
      </Card>
      <ErrorText error={error ?? data.error} />
      {branch && data.data && data.data.offers.length === 0 && !data.loading ? <Text style={s.muted}>{t("svc.rental.noOffers")}</Text> : null}
      {data.data?.offers.map((o) => (
        <Card key={o.rate_id}>
          <View style={s.between}>
            <Text style={[s.h2, { flex: 1 }]}>{o.class_name}</Text>
            <Text style={s.h2}>{money(o.total)}</Text>
          </View>
          <Text style={s.small}>{t("svc.rental.rate", { price: money(o.price), unit: t(`svc.rental.unit.${o.unit}`) })} · {t("svc.rental.deposit", { amount: money(o.deposit) })}</Text>
          {o.km_per_day ? <Text style={s.small}>{t("svc.rental.km", { n: o.km_per_day })}</Text> : null}
          <Text style={s.small}>{o.available > 0 ? t("svc.rental.available", { n: o.available }) : t("svc.rental.onRequest")}</Text>
          <Button label={t("svc.rental.book")} busy={busy === o.rate_id} disabled={busy !== null} onPress={() => book(o)} />
        </Card>
      ))}
      <Text style={s.h2}>{t("svc.rental.mine")}</Text>
      {mine.data && mine.data.bookings.length === 0 ? <Text style={s.muted}>{t("svc.rental.none")}</Text> : null}
      {mine.data?.bookings.map((b) => (
        <Card key={b.uid}>
          <View style={s.between}>
            <Text style={[s.label, { flex: 1 }]}>{b.class_name} · {b.brand}</Text>
            <Chip label={labels.value(b.status)} tone={tone(b.status)} />
          </View>
          <Text style={s.small}>{station(b.pickup_code, b.pickup)} · {date(b.starts_at)} → {date(b.ends_at)} · {money(b.quoted_total)}</Text>
          {["PENDING", "CONFIRMED"].includes(b.status) ? <Button kind="danger" label={t("svc.cancel")} onPress={() => cancel(b)} /> : null}
        </Card>
      ))}
    </Screen>
  );
}
