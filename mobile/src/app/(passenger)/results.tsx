import { useState } from "react";
import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, CarrierName, Chip, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { Connections } from "../../ui/connections";
import { canFollow, parseLegs, parsePicked, pickedParam, rememberTrip, rememberedTrip, type JourneyKind } from "../../core/journey";

interface Result {
  uid: string; trip_no: string; trip_code?: string | null; carrier_name: string; carrier_uid?: string; carrier_logo?: string | null; departs_at: string; arrives_at: string; from_station: string; to_station: string;
  from_seq: number; to_seq: number; price: number; seats_left: number; stops_between: number; bookable: boolean;
  returns_as?: { trip_code: string | null; departs_at: string; same_vehicle: boolean | null } | null;   // the return on the same vehicle (1119)
}
type Stops = "all" | "direct" | "stops";

// The trips between two cities on a day, or, for a journey (1121), the trips of one of its legs at a time: a trip that
// leaves before the one chosen before it arrives cannot be chosen. Every list shows all trips, direct ones or ones with stops;
// below them the connections through a city on the way (1130), at once where no trip runs, on request otherwise.
export default function Results() {
  const { t, money, time, date } = useI18n();
  const p = useLocalSearchParams<{ origin?: string; destination?: string; on?: string; passengers: string; kind?: string; legs?: string; picked?: string }>();
  const legs = parseLegs(p.legs);
  const journey = legs.length > 0;
  const kind = (p.kind ?? "MULTI_CITY") as JourneyKind;
  const picked = journey ? parsePicked(p.picked).slice(0, legs.length - 1) : [];
  const leg = journey ? legs[picked.length] : null;
  const origin = leg?.from ?? p.origin ?? "DAM", destination = leg?.to ?? p.destination ?? "ALP", on = leg?.on ?? p.on ?? "";
  const [stops, setStops] = useState<Stops>("all");
  const [showConn, setShowConn] = useState(false);
  const q = `origin=${origin}&destination=${destination}&on=${on}&passengers=${p.passengers}${stops === "all" ? "" : `&stops=${stops}`}`;
  const res = useLoad(() => api.get<{ trips: Result[] }>(`/api/trips/search?${q}`), [q]);
  const previous = picked.length ? rememberedTrip(picked[picked.length - 1].uid) : undefined;
  const choose = (x: Result) => {
    if (!journey) {
      router.push({ pathname: "/trip/[uid]", params: { uid: x.uid, from_seq: String(x.from_seq), to_seq: String(x.to_seq), passengers: p.passengers } });
      return;
    }
    rememberTrip({ uid: x.uid, code: x.trip_code ?? x.trip_no, departs_at: x.departs_at, arrives_at: x.arrives_at });
    const next = [...picked, { uid: x.uid, from: x.from_seq, to: x.to_seq }];
    if (next.length >= legs.length) {
      router.push({ pathname: "/journey", params: { kind, legs: p.legs!, picked: pickedParam(next), passengers: p.passengers } });
    } else {
      router.setParams({ picked: pickedParam(next) });
    }
  };
  return (
    <Screen>
      <Title sub={`${date(`${on}T12:00:00Z`)} · ${p.passengers} × ${t("common.passengers")}`}>
        {t(`city.${origin}`)} → {t(`city.${destination}`)}
      </Title>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      {journey ? (
        <Card>
          <Text style={s.h2}>{t(`jrn.mode.${kind}`)} · {t("jrn.legOf", { n: picked.length + 1, of: legs.length })}</Text>
          {legs.map((l, i) => {
            const done = i < picked.length ? rememberedTrip(picked[i].uid) : undefined;
            return (
              <View key={i} style={s.between}>
                <Text style={[s.small, i === picked.length ? { color: color.primary, fontWeight: "600" } : null]}>
                  {t("jrn.legN", { n: i + 1 })} · {t(`city.${l.from}`)} → {t(`city.${l.to}`)} · {date(`${l.on}T12:00:00Z`)}
                  {done ? ` · ${done.code} ${time(done.departs_at)}` : ""}
                </Text>
                {i < picked.length ? <Button kind="text" label={t("jrn.change")} onPress={() => router.setParams({ picked: pickedParam(picked.slice(0, i)) })} /> : null}
              </View>
            );
          })}
        </Card>
      ) : null}
      <View style={s.row} accessibilityRole="radiogroup">
        {(["all", "direct", "stops"] as Stops[]).map((k) => (
          <Pressable key={k} onPress={() => setStops(k)} accessibilityRole="radio" accessibilityState={{ checked: stops === k }}
                     style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                              borderColor: stops === k ? color.primary : color.outline, backgroundColor: stops === k ? color.primarySoft : color.surface }}>
            <Text>{t(`jrn.filter.${k}`)}</Text>
          </Pressable>
        ))}
      </View>
      {res.loading ? <Loading /> : <ErrorText error={res.error} />}
      {res.data && res.data.trips.length === 0 ? <Text style={s.muted}>{t("search.none")}</Text> : null}
      {res.data?.trips.map((x) => {
        const follows = canFollow(previous?.arrives_at, x.departs_at);
        const can = x.bookable && follows;
        return (
          <Pressable key={`${x.uid}:${x.from_seq}`} disabled={!can} accessibilityRole="button" onPress={() => choose(x)}>
            <Card style={{ opacity: can ? 1 : 0.5 }}>
              <View style={s.between}>
                <Text style={s.h2}>{time(x.departs_at)} → {time(x.arrives_at)}</Text>
                <Text style={[s.h2, { color: "#0A5BD3" }]}>{money(x.price)}</Text>
              </View>
              <Text style={s.muted}>{x.from_station} → {x.to_station}</Text>
              <View style={s.row}>
                <CarrierName name={x.carrier_name} uid={x.carrier_uid} logo={x.carrier_logo} />
                <Chip tone="blue" label={x.trip_code ?? x.trip_no} />
                <Chip tone={x.stops_between ? "neutral" : "green"} label={x.stops_between ? t("extra.stops", { n: x.stops_between }) : t("extra.direct")} />
                <Chip tone={x.seats_left < 6 ? "amber" : "blue"} label={t("search.seatsLeft", { n: x.seats_left })} />
              </View>
              {x.returns_as ? <Text style={s.small}>↩ {t("ret.returnsAs", { code: x.returns_as.trip_code ?? "", time: time(x.returns_as.departs_at) })}</Text> : null}
              {!follows ? <Text style={[s.small, { color: color.error }]}>{t("jrn.tooEarly")}</Text> : null}
              {journey && can ? <Text style={[s.small, { color: color.primary }]}>{t(picked.length + 1 < legs.length ? "jrn.chooseNext" : "jrn.chooseLast")}</Text> : null}
            </Card>
          </Pressable>
        );
      })}
      {!journey && res.data ? (res.data.trips.length === 0 || showConn
        ? <Connections origin={origin} destination={destination} on={on} passengers={p.passengers} />
        : <Button kind="tonal" label={t("conn.show")} onPress={() => setShowConn(true)} />) : null}
    </Screen>
  );
}
