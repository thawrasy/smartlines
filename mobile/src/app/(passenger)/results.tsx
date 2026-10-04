import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";

interface Result {
  uid: string; trip_no: string; carrier_name: string; departs_at: string; arrives_at: string; from_station: string; to_station: string;
  from_seq: number; to_seq: number; price: number; seats_left: number; stops_between: number; bookable: boolean;
}

export default function Results() {
  const { t, money, time, date } = useI18n();
  const p = useLocalSearchParams<{ origin: string; destination: string; on: string; passengers: string }>();
  const q = `origin=${p.origin}&destination=${p.destination}&on=${p.on}&passengers=${p.passengers}`;
  const res = useLoad(() => api.get<{ trips: Result[] }>(`/api/trips/search?${q}`), [q]);
  return (
    <Screen>
      <Title sub={`${date(`${p.on}T12:00:00Z`)} · ${p.passengers} × ${t("common.passengers")}`}>
        {t(`city.${p.origin}`)} → {t(`city.${p.destination}`)}
      </Title>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      {res.loading ? <Loading /> : <ErrorText error={res.error} />}
      {res.data && res.data.trips.length === 0 ? <Text style={s.muted}>{t("search.none")}</Text> : null}
      {res.data?.trips.map((x) => (
        <Pressable key={`${x.uid}:${x.from_seq}`} disabled={!x.bookable} accessibilityRole="button"
                   onPress={() => router.push({ pathname: "/trip/[uid]", params: { uid: x.uid, from_seq: String(x.from_seq), to_seq: String(x.to_seq), passengers: p.passengers } })}>
          <Card style={{ opacity: x.bookable ? 1 : 0.5 }}>
            <View style={s.between}>
              <Text style={s.h2}>{time(x.departs_at)} → {time(x.arrives_at)}</Text>
              <Text style={[s.h2, { color: "#0A5BD3" }]}>{money(x.price)}</Text>
            </View>
            <Text style={s.muted}>{x.from_station} → {x.to_station}</Text>
            <View style={s.row}>
              <Chip label={x.carrier_name} />
              <Chip tone={x.stops_between ? "neutral" : "green"} label={x.stops_between ? t("extra.stops", { n: x.stops_between }) : t("extra.direct")} />
              <Chip tone={x.seats_left < 6 ? "amber" : "blue"} label={t("search.seatsLeft", { n: x.seats_left })} />
            </View>
          </Card>
        </Pressable>
      ))}
    </Screen>
  );
}
