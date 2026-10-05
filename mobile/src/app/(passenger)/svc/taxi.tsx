import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { PLACES } from "../../../core/places";
import { Button, Card, Chip, Choice, ErrorText, Loading, Notice, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface City { id: number; code: string; lat: number; lng: number }
interface Req { uid: string; pickup_text: string; dropoff_text: string; seats: number; fare_estimate: number; status: string; created_at: string; city: string; fare: number | null; ride_status: string | null }

/** A taxi at the city's approved meter tariff: choose pickup and drop-off, see the estimate, request. */
export default function Taxi() {
  const { t, money, city, dateTime } = useI18n();
  const labels = useLabels();
  const cities = useLoad(() => api.get<{ cities: City[] }>("/api/w/taxi/cities"));
  const mine = useLoad(() => api.get<{ requests: Req[] }>("/api/w/taxi/requests/mine"));
  const [c, setC] = useState<string | null>(null);
  const [from, setFrom] = useState<string | null>(null);
  const [to, setTo] = useState<string | null>(null);
  const [seats, setSeats] = useState(1);
  const [est, setEst] = useState<{ km: number; minutes: number; fare: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const cityRow = cities.data?.cities.find((x) => x.code === c);
  const places = (c && PLACES[c]) || [];
  const place = (k: string | null) => places.find((p) => p.key === k);
  const placeName = (k: string) => t(`fw.place.${c}.${k}`) === `fw.place.${c}.${k}` ? k : t(`fw.place.${c}.${k}`);
  const body = () => {
    const a = place(from)!, b = place(to)!;
    return { city_id: cityRow!.id, pickup_lat: a.lat, pickup_lng: a.lng, dropoff_lat: b.lat, dropoff_lng: b.lng };
  };
  const estimate = async () => {
    setBusy(true); setError(null);
    try { setEst(await api.post("/api/w/taxi/estimate", body())); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const request = async () => {
    setBusy(true); setError(null);
    try {
      await api.post("/api/w/taxi/requests", { ...body(), pickup_text: placeName(from!), dropoff_text: placeName(to!), seats, kind: "INSTANT" });
      setEst(null); setFrom(null); setTo(null); mine.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const cancel = (r: Req) => Alert.alert(t("svc.taxi.cancelQ"), "", [
    { text: t("common.back"), style: "cancel" },
    { text: t("svc.cancel"), style: "destructive", onPress: async () => {
      try { await api.post(`/api/w/taxi/requests/${r.uid}/cancel`); mine.reload(); } catch (e) { setError(e); }
    } },
  ]);
  const reset = (fn: () => void) => { fn(); setEst(null); };
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={t("svc.taxi.hint")}>{t("svc.taxi.title")}</Title>
      {cities.loading && !cities.data ? <Loading /> : null}
      {cities.data ? (
        <Card>
          <Choice label={t("svc.taxi.city")} value={c} onChange={(v) => reset(() => { setC(v); setFrom(null); setTo(null); })}
                  options={cities.data.cities.map((x) => ({ value: x.code, label: city(x.code) }))} />
          {c && places.length === 0 ? <Notice tone="amber" text={t("svc.taxi.noPlaces")} /> : null}
          {places.length ? <Choice label={t("svc.taxi.pickup")} value={from} onChange={(v) => reset(() => setFrom(v))}
                                   options={places.map((p) => ({ value: p.key, label: placeName(p.key) }))} /> : null}
          {from ? <Choice label={t("svc.taxi.dropoff")} value={to} onChange={(v) => reset(() => setTo(v))}
                          options={places.filter((p) => p.key !== from).map((p) => ({ value: p.key, label: placeName(p.key) }))} /> : null}
          {to ? <Choice label={t("svc.taxi.seats")} value={seats} onChange={setSeats} options={[1, 2, 3, 4].map((n) => ({ value: n, label: String(n) }))} /> : null}
          {est ? (
            <>
              <Notice tone="green" text={t("svc.taxi.estimate", { fare: money(est.fare), km: est.km.toFixed(1), min: est.minutes })} />
              <Button label={t("svc.taxi.request")} busy={busy} onPress={request} />
            </>
          ) : <Button label={t("svc.taxi.getEstimate")} busy={busy} disabled={!from || !to} onPress={estimate} />}
          <ErrorText error={error} />
        </Card>
      ) : <ErrorText error={cities.error} />}
      <Text style={s.h2}>{t("svc.taxi.mine")}</Text>
      {mine.data && mine.data.requests.length === 0 ? <Text style={s.muted}>{t("svc.taxi.none")}</Text> : null}
      {mine.data?.requests.map((r) => (
        <Card key={r.uid}>
          <View style={s.between}>
            <Text style={[s.label, { flex: 1 }]}>{r.pickup_text} → {r.dropoff_text}</Text>
            <Chip label={labels.value(r.ride_status ?? r.status)} tone={tone(r.ride_status ?? r.status)} />
          </View>
          <Text style={s.small}>{city(r.city)} · {dateTime(r.created_at)} · {money(r.fare ?? r.fare_estimate)}</Text>
          {["SEARCHING", "ASSIGNED"].includes(r.status) ? <Button kind="danger" label={t("svc.cancel")} onPress={() => cancel(r)} /> : null}
        </Card>
      ))}
      <Text style={[s.small, { color: color.muted }]}>{t("svc.taxi.note")}</Text>
    </Screen>
  );
}
