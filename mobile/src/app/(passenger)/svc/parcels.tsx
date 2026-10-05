import { useMemo, useState } from "react";
import { Alert, Text } from "react-native";
import { router } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, Choice, ErrorText, Field, Loading, Notice, Row, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { useLoad } from "../../../ui/useLoad";

interface Options { services: { id: number; code: string; name: string; max_weight_kg: number | null }[]; stations: { id: number; code: string; name: string; city: string }[] }
interface Parcel { tracking_no: string; status: string; created_at: string; recipient_name: string; service: string; origin_code: string; destination_code: string; origin: string; destination: string; price: number }

/** Send a parcel between stations: price from the published rate table, paid from the wallet, tracked by number. */
export default function Parcels() {
  const { t, money, station, city, date } = useI18n();
  const labels = useLabels();
  const opts = useLoad(() => api.get<Options>("/api/w/parcels/options"));
  const mine = useLoad(() => api.get<{ parcels: Parcel[] }>("/api/w/parcels/mine"));
  const [f, setF] = useState({ service: null as number | null, fromCity: null as string | null, from: null as number | null,
                               toCity: null as string | null, to: null as number | null, weight: "", value: "", name: "", mobile: "", contents: "" });
  const [quote, setQuote] = useState<{ price: number; zone: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (k: keyof typeof f, v: unknown) => { setF((x) => ({ ...x, [k]: v })); setQuote(null); };
  const cities = useMemo(() => [...new Set((opts.data?.stations ?? []).map((x) => x.city))], [opts.data]);
  const stationsIn = (c: string | null) => (opts.data?.stations ?? []).filter((x) => x.city === c);
  const body = () => ({ service_id: f.service, origin_station_id: f.from, dest_station_id: f.to, weight_kg: Number(f.weight),
                        declared_value: Math.round(Number(f.value || 0) * 100) });
  const ready = f.service && f.from && f.to && f.from !== f.to && Number(f.weight) > 0;
  const getQuote = async () => {
    setBusy(true); setError(null);
    try { setQuote(await api.post("/api/w/parcels/quote", body())); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const send = () => Alert.alert(t("svc.parcels.title"), t("svc.parcels.payQ", { amount: money(quote?.price ?? 0) }), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("svc.pay"), onPress: async () => {
      setBusy(true); setError(null);
      try {
        const r = await api.post<{ tracking_no: string }>("/api/w/parcels", { ...body(), recipient_name: f.name.trim(), recipient_mobile: f.mobile.trim(),
                                                                             contents: f.contents.trim() || null, idempotency_key: randomUUID() });
        setF({ ...f, weight: "", value: "", name: "", mobile: "", contents: "" }); setQuote(null); mine.reload();
        router.push({ pathname: "/svc/track", params: { no: r.tracking_no } });
      } catch (e) { setError(e); } finally { setBusy(false); }
    } },
  ]);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={t("svc.parcels.hint")}>{t("svc.parcels.title")}</Title>
      {opts.loading && !opts.data ? <Loading /> : null}
      {opts.data ? (
        <Card>
          <Choice label={t("svc.parcels.service")} value={f.service} onChange={(v) => set("service", v)}
                  options={opts.data.services.map((x) => ({ value: x.id, label: x.name }))} />
          <Choice label={t("svc.parcels.fromCity")} value={f.fromCity} onChange={(v) => { set("fromCity", v); set("from", stationsIn(v)[0]?.id ?? null); }}
                  options={cities.map((c) => ({ value: c, label: city(c) }))} />
          {stationsIn(f.fromCity).length > 1 ? <Choice value={f.from} onChange={(v) => set("from", v)}
                  options={stationsIn(f.fromCity).map((x) => ({ value: x.id, label: station(x.code, x.name) }))} /> : null}
          <Choice label={t("svc.parcels.toCity")} value={f.toCity} onChange={(v) => { set("toCity", v); set("to", stationsIn(v)[0]?.id ?? null); }}
                  options={cities.map((c) => ({ value: c, label: city(c) }))} />
          {stationsIn(f.toCity).length > 1 ? <Choice value={f.to} onChange={(v) => set("to", v)}
                  options={stationsIn(f.toCity).map((x) => ({ value: x.id, label: station(x.code, x.name) }))} /> : null}
          <Field label={t("svc.parcels.weight")} value={f.weight} onChangeText={(v) => set("weight", v.replace(/[^0-9.]/g, ""))} keyboardType="decimal-pad" />
          <Field label={t("svc.parcels.value")} hint={t("svc.parcels.valueHint")} value={f.value} onChangeText={(v) => set("value", v.replace(/\D/g, ""))} keyboardType="number-pad" />
          {quote ? <Notice tone="green" text={t("svc.parcels.price", { amount: money(quote.price), zone: quote.zone })} /> : null}
          {quote ? (
            <>
              <Field label={t("svc.parcels.recipient")} value={f.name} onChangeText={(v) => setF({ ...f, name: v })} />
              <Field label={t("svc.parcels.recipientMobile")} value={f.mobile} onChangeText={(v) => setF({ ...f, mobile: v })} keyboardType="phone-pad" />
              <Field label={t("svc.parcels.contents")} value={f.contents} onChangeText={(v) => setF({ ...f, contents: v })} />
              <Button label={t("svc.parcels.send", { amount: money(quote.price) })} busy={busy} disabled={f.name.trim().length < 3 || !/^\+?\d{8,15}$/.test(f.mobile.trim())} onPress={send} />
            </>
          ) : <Button label={t("svc.parcels.quote")} busy={busy} disabled={!ready} onPress={getQuote} />}
          <ErrorText error={error} />
        </Card>
      ) : <ErrorText error={opts.error} />}
      <Text style={s.h2}>{t("svc.parcels.mine")}</Text>
      {mine.data && mine.data.parcels.length === 0 ? <Text style={s.muted}>{t("svc.parcels.none")}</Text> : null}
      {mine.data?.parcels.map((x) => (
        <Row key={x.tracking_no} title={`${station(x.origin_code, x.origin)} → ${station(x.destination_code, x.destination)}`}
             sub={`${x.tracking_no} · ${x.recipient_name} · ${date(x.created_at)}`}
             right={<Chip label={labels.value(x.status)} tone={tone(x.status)} />}
             onPress={() => router.push({ pathname: "/svc/track", params: { no: x.tracking_no } })} />
      ))}
    </Screen>
  );
}
