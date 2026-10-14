import { useState } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n, zone } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, Loading, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { MAX_LEGS, journeyLegs, legsParam, type JourneyKind, type JourneyLeg } from "../../core/journey";

/** Calendar date in Damascus, n days from today, as YYYY-MM-DD. */
const dayIso = (n: number) => new Date(Date.now() + n * 86400000).toLocaleDateString("en-CA", { timeZone: zone() });   // the market's day (1061)

function Pills({ items, value, onChange }: { items: { key: string; label: string }[]; value: string; onChange: (k: string) => void }) {
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
      {items.map((i) => (
        <Pressable key={i.key} onPress={() => onChange(i.key)} accessibilityRole="button" accessibilityState={{ selected: value === i.key }}
                   style={{ paddingHorizontal: 14, paddingVertical: 10, borderRadius: 999, borderWidth: 1,
                            borderColor: value === i.key ? color.primary : color.outline, backgroundColor: value === i.key ? color.primarySoft : color.surface }}>
          <Text style={{ color: value === i.key ? color.primary : color.text, fontWeight: "500" }}>{i.label}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

// One way, a round trip, or several places one after the other (owner's request, October 2026; 1121). A traveller books
// as many seats at once as the platform allows (four unless it decides otherwise, more for a family head; 1122).
export default function Book() {
  const { t, date } = useI18n();
  const ref = useLoad(() => api.get<{ cities: { code: string }[] }>("/api/ref"));
  const limits = useLoad(() => api.get<{ max_seats: number }>("/api/bookings/limits").then((r) => r.max_seats).catch(() => 4));
  const [kind, setKind] = useState<JourneyKind>("ONE_WAY");
  const [origin, setOrigin] = useState("DAM");
  const [destination, setDestination] = useState("ALP");
  const [on, setOn] = useState(dayIso(0));
  const [back, setBack] = useState(dayIso(2));
  const [more, setMore] = useState<JourneyLeg[]>([{ from: "ALP", to: "", on: dayIso(2) }]);
  const [passengers, setPassengers] = useState(1);
  const max = limits.data ?? 4;
  const cities = (ref.data?.cities ?? []).map((c) => ({ key: c.code, label: t(`city.${c.code}`) }));
  const days = (from: string) => Array.from({ length: 21 }, (_, n) => dayIso(n)).filter((d) => d >= from).slice(0, 14)
    .map((d) => ({ key: d, label: date(`${d}T12:00:00Z`) }));
  const first = { from: origin, to: destination, on };
  // the next place leaves from where the one before arrives
  const chain = more.map((l, i) => ({ ...l, from: i === 0 ? destination : more[i - 1].to }));
  const legs = journeyLegs(kind, first, back, chain);
  const go = () => {
    if (!legs) return;
    if (kind === "ONE_WAY") router.push({ pathname: "/results", params: { origin, destination, on, passengers: String(passengers) } });
    else router.push({ pathname: "/results", params: { kind, legs: legsParam(legs), passengers: String(passengers) } });
  };
  const setLeg = (i: number, patch: Partial<JourneyLeg>) => setMore((all) => all.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  return (
    <Screen>
      <Title>{t("search.title")}</Title>
      {ref.loading ? <Loading /> : (
        <Card>
          <Pills items={(["ONE_WAY", "ROUND_TRIP", "MULTI_CITY"] as JourneyKind[]).map((k) => ({ key: k, label: t(`jrn.mode.${k}`) }))}
                 value={kind} onChange={(k) => setKind(k as JourneyKind)} />
          <Text style={s.label}>{t("search.origin")}</Text>
          <Pills items={cities} value={origin} onChange={setOrigin} />
          <Text style={s.label}>{t("search.destination")}</Text>
          <Pills items={cities.filter((c) => c.key !== origin)} value={destination} onChange={setDestination} />
          <Text style={s.label}>{t("search.date")}</Text>
          <Pills items={days(dayIso(0))} value={on} onChange={(d) => { setOn(d); if (back < d) setBack(d); }} />
          {kind === "ROUND_TRIP" ? (
            <>
              <Text style={s.label}>{t("jrn.returnDate")}</Text>
              <Pills items={days(on)} value={back} onChange={setBack} />
            </>
          ) : null}
          {kind === "MULTI_CITY" ? chain.map((l, i) => (
            <View key={i} style={{ gap: 8, borderTopWidth: 1, borderColor: color.outline, paddingTop: 8 }}>
              <View style={s.between}>
                <Text style={s.h2}>{t("jrn.legN", { n: i + 2 })} · {t(`city.${l.from}`)} →</Text>
                {i === chain.length - 1 && chain.length > 1 ? <Button kind="text" label={t("common.remove")} onPress={() => setMore(more.slice(0, -1))} /> : null}
              </View>
              <Pills items={cities.filter((c) => c.key !== l.from)} value={l.to} onChange={(v) => setLeg(i, { to: v })} />
              <Pills items={days(i === 0 ? on : chain[i - 1].on)} value={l.on} onChange={(v) => setLeg(i, { on: v })} />
            </View>
          )) : null}
          {kind === "MULTI_CITY" && chain.length + 1 < MAX_LEGS ? (
            <Button kind="tonal" label={t("jrn.addPlace")} onPress={() => setMore([...more, { from: "", to: "", on: chain[chain.length - 1].on }])} />
          ) : null}
          <View style={s.between}>
            <Text style={s.label}>{t("common.passengers")}</Text>
            <View style={s.row}>
              <Button kind="tonal" label="−" onPress={() => setPassengers(Math.max(1, passengers - 1))} />
              <Text style={[s.h2, { minWidth: 28, textAlign: "center" }]}>{passengers}</Text>
              <Button kind="tonal" label="+" onPress={() => setPassengers(Math.min(max, passengers + 1))} />
            </View>
          </View>
          {passengers === max ? <Text style={s.small}>{t("jrn.seatLimit", { n: max })}</Text> : null}
          <Button label={t("search.find")} disabled={!legs} onPress={go} />
        </Card>
      )}
    </Screen>
  );
}
