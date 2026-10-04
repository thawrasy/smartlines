import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { saveBooking } from "../../../platform/tickets";
import { Button, Card, ErrorText, Field, Loading, Screen, Title, s } from "../../../ui/kit";
import { SeatMap, type SeatMapData } from "../../../ui/SeatMap";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Detail {
  seat_map: SeatMapData; price: number; from_seq: number; to_seq: number; seats: { seat_no: number; free: boolean }[];
  trip: { trip_no: string; carrier_name: string; currency: string; hold_min: number };
  stops: { seq: number; station_name: string; sched_dep: string | null; sched_arr: string | null }[];
}
interface Names { syrian: boolean; country: string; first_name: string; father_name: string; grandfather_name: string; last_name: string }
const blank: Names = { syrian: true, country: "", first_name: "", father_name: "", grandfather_name: "", last_name: "" };

export default function Trip() {
  const { t, money, time } = useI18n();
  const p = useLocalSearchParams<{ uid: string; from_seq: string; to_seq: string; passengers: string }>();
  const max = Number(p.passengers) || 1;
  const detail = useLoad(() => api.get<Detail>(`/api/trips/${p.uid}?from_seq=${p.from_seq}&to_seq=${p.to_seq}`), [p.uid, p.from_seq, p.to_seq]);
  const wallet = useLoad(() => api.get<{ balance: number }>("/api/wallet"));
  const ref = useLoad(() => api.get<{ countries: string[] }>("/api/ref"));
  const [selected, setSelected] = useState<number[]>([]);
  const [hold, setHold] = useState<{ hold_token: string; expires_at: string } | null>(null);
  const [names, setNames] = useState<Record<number, Names>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const idem = useRef(randomUUID());
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(id); }, []);

  const free = useMemo(() => new Map((detail.data?.seats ?? []).map((x) => [x.seat_no, x.free])), [detail.data]);
  const label = (n: number) => detail.data?.seat_map.seats.find((x) => x.n === n)?.label ?? String(n);
  const left = hold ? Math.max(0, Math.round((new Date(hold.expires_at).getTime() - now) / 1000)) : 0;
  const countries = new Set(ref.data?.countries ?? []);
  const complete = (x?: Names) => !!x && !!x.first_name.trim() && !!x.last_name.trim()
    && (x.syrian ? !!x.father_name.trim() && !!x.grandfather_name.trim() : countries.has(x.country) && x.country !== "SY");

  const doHold = async () => {
    setBusy(true); setError(null);
    try {
      setHold(await api.post("/api/holds", { trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), seat_nos: selected }));
      setNames(Object.fromEntries(selected.map((n) => [n, names[n] ?? blank])));
    } catch (e) { setError(e); detail.reload(); } finally { setBusy(false); }
  };
  const pay = async () => {
    if (!hold) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ booking_ref: string }>("/api/bookings", {
        hold_token: hold.hold_token, trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), idempotency_key: idem.current,
        passengers: selected.map((n) => {
          const x = names[n];
          return { seat_no: n, nationality: x.syrian ? "SY" : x.country, first_name: x.first_name.trim(), last_name: x.last_name.trim(),
                   father_name: x.father_name.trim() || null, grandfather_name: x.grandfather_name.trim() || null };
        }),
      });
      await saveBooking(out.booking_ref).catch(() => {});
      router.replace({ pathname: "/booking/[ref]", params: { ref: out.booking_ref } });
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (detail.loading) return <Screen><Loading /></Screen>;
  if (!detail.data) return <Screen><ErrorText error={detail.error} /><Button kind="text" label={t("common.back")} onPress={() => router.back()} /></Screen>;
  const d = detail.data;
  const from = d.stops.find((x) => x.seq === d.from_seq), to = d.stops.find((x) => x.seq === d.to_seq);
  const total = d.price * selected.length;
  return (
    <Screen>
      <Title sub={`${d.trip.carrier_name} · ${t("extra.trip", { no: d.trip.trip_no })}`}>
        {from?.station_name} → {to?.station_name}
      </Title>
      <Text style={s.muted}>{from?.sched_dep ? time(from.sched_dep) : ""} → {to?.sched_arr ? time(to.sched_arr) : ""} · {money(d.price)}</Text>
      <ErrorText error={error} />
      {!hold ? (
        <>
          <Text style={s.h2}>{t("trip.seats")}</Text>
          <Text style={s.small}>{t("extra.seatsChosen", { n: selected.length, max })}</Text>
          <SeatMap map={d.seat_map} free={free} selected={selected} max={max}
                   onToggle={(n) => setSelected((cur) => (cur.includes(n) ? cur.filter((x) => x !== n) : [...cur, n]))} />
          <Button label={t("trip.hold")} busy={busy} disabled={selected.length !== max} onPress={doHold} />
        </>
      ) : (
        <>
          <Text style={[s.small, { color: left < 60 ? color.error : color.muted }]}>
            {t("trip.held", { t: `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}` })}
          </Text>
          <Text style={s.small}>{t("trip.namesHint")}</Text>
          {selected.map((n, i) => {
            const x = names[n] ?? blank;
            const set = (patch: Partial<Names>) => setNames({ ...names, [n]: { ...x, ...patch } });
            return (
              <Card key={n}>
                <Text style={s.h2}>{t("trip.passenger", { n: i + 1 })} · {t("common.seat")} {label(n)}</Text>
                <View style={s.row}>
                  {[true, false].map((sy) => (
                    <Pressable key={String(sy)} onPress={() => set({ syrian: sy })} accessibilityRole="radio" accessibilityState={{ checked: x.syrian === sy }}
                               style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                                        borderColor: x.syrian === sy ? color.primary : color.outline, backgroundColor: x.syrian === sy ? color.primarySoft : color.surface }}>
                      <Text>{t(sy ? "trip.syrian" : "trip.otherNationality")}</Text>
                    </Pressable>
                  ))}
                </View>
                {!x.syrian ? <Field label={t("trip.nationality")} value={x.country} placeholder="LB" maxLength={2} autoCapitalize="characters"
                                    onChangeText={(v) => set({ country: v.toUpperCase().replace(/[^A-Z]/g, "") })} /> : null}
                <Field label={t("trip.first")} value={x.first_name} onChangeText={(v) => set({ first_name: v })} autoComplete="off" />
                {x.syrian ? <Field label={t("trip.father")} value={x.father_name} onChangeText={(v) => set({ father_name: v })} autoComplete="off" /> : null}
                {x.syrian ? <Field label={t("trip.grandfather")} value={x.grandfather_name} onChangeText={(v) => set({ grandfather_name: v })} autoComplete="off" /> : null}
                <Field label={t("trip.last")} value={x.last_name} onChangeText={(v) => set({ last_name: v })} autoComplete="off" />
              </Card>
            );
          })}
          <View style={s.between}><Text style={s.h2}>{t("common.total")}</Text><Text style={s.h2}>{money(total)}</Text></View>
          {wallet.data ? <Text style={s.small}>{t("trip.balance", { amount: money(wallet.data.balance) })}</Text> : null}
          <Button label={t("trip.pay", { amount: money(total) })} busy={busy} disabled={left === 0 || !selected.every((n) => complete(names[n]))} onPress={pay} />
        </>
      )}
    </Screen>
  );
}
