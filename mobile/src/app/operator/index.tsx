import { Pressable, RefreshControl, ScrollView, Text, View } from "react-native";
import { router } from "expo-router";
import { SafeAreaView } from "react-native-safe-area-context";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { useAuth } from "../../platform/auth";
import { Card, Chip, ErrorText, Loading, Title, s } from "../../ui/kit";
import { tone, useLabels } from "../../ui/labels";
import { color, space } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

export interface OpTrip {
  uid: string; trip_no: string; status: string; departure_at: string; seats_total: number; sold: number; plate_no: string | null;
  origin: string; destination: string; origin_code: string; dest_code: string; driver_name?: string | null;
}
interface Dash {
  trips_today: number; sales_today: number; tickets_today: number; released_balance: number; active_vehicles: number; load_factor: number;
  trips: OpTrip[]; alerts: { kind: string; detail: string; at: string; subject: string }[];
}

export function TripRow({ trip }: { trip: OpTrip }) {
  const { t, station, time, date } = useI18n();
  const labels = useLabels();
  return (
    <Pressable accessibilityRole="button" onPress={() => router.push(`/operator/trip/${trip.uid}`)}
               style={({ pressed }) => [{ paddingVertical: 12, borderBottomWidth: 1, borderColor: color.outline, opacity: pressed ? 0.7 : 1, gap: 4 }]}>
      <View style={s.between}>
        <Text style={s.label}>{station(trip.origin_code, trip.origin)} → {station(trip.dest_code, trip.destination)}</Text>
        <Chip label={labels.value(trip.status)} tone={tone(trip.status)} />
      </View>
      <Text style={s.small}>{date(trip.departure_at)} · {time(trip.departure_at)} · {trip.trip_no}{trip.plate_no ? ` · ${trip.plate_no}` : ""}</Text>
      <Text style={s.small}>{t("op.sold", { n: trip.sold, total: trip.seats_total })}{trip.driver_name ? ` · ${trip.driver_name}` : ""}</Text>
    </Pressable>
  );
}

function Kpi({ label, value }: { label: string; value: string | number }) {
  return (
    <View style={{ flexBasis: "47%", flexGrow: 1, backgroundColor: color.surface, borderRadius: 14, borderWidth: 1, borderColor: color.outline, padding: space(3), gap: 4 }}>
      <Text style={s.small}>{label}</Text>
      <Text style={{ fontSize: 22, fontWeight: "700", color: color.navy }}>{value}</Text>
    </View>
  );
}

export default function OperatorToday() {
  const { t, money } = useI18n();
  const { me } = useAuth();
  const d = useLoad(() => api.get<Dash>("/api/carrier/dashboard"));
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      <ScrollView contentContainerStyle={{ padding: space(4), gap: space(4) }}
                  refreshControl={<RefreshControl refreshing={d.loading && !!d.data} onRefresh={d.reload} />}>
        <Title sub={me?.name}>{t("op.today")}</Title>
        {d.loading && !d.data ? <Loading /> : <ErrorText error={d.error} />}
        {d.data ? (
          <>
            <View style={{ flexDirection: "row", flexWrap: "wrap", gap: space(3) }}>
              <Kpi label={t("op.kpi.trips")} value={d.data.trips_today} />
              <Kpi label={t("op.kpi.tickets")} value={d.data.tickets_today} />
              <Kpi label={t("op.kpi.sales")} value={money(d.data.sales_today)} />
              <Kpi label={t("op.kpi.load")} value={`${d.data.load_factor}%`} />
              <Kpi label={t("op.kpi.vehicles")} value={d.data.active_vehicles} />
              <Kpi label={t("op.kpi.balance")} value={money(d.data.released_balance)} />
            </View>
            {d.data.alerts.length > 0 ? (
              <Card style={{ backgroundColor: color.amberSoft, borderColor: color.amberSoft }}>
                <Text style={s.h2}>{t("op.alerts")}</Text>
                {d.data.alerts.map((a, i) => (
                  <Text key={i} style={[s.small, { color: color.amber }]}>{t(`op.alert.${a.kind}`) === `op.alert.${a.kind}` ? a.kind : t(`op.alert.${a.kind}`)} · {a.subject} · {a.detail}</Text>
                ))}
              </Card>
            ) : null}
            <Card>
              <Text style={s.h2}>{t("op.next")}</Text>
              {d.data.trips.length === 0 ? <Text style={s.muted}>{t("op.noTrips")}</Text> : d.data.trips.map((x) => <TripRow key={x.uid} trip={x} />)}
            </Card>
          </>
        ) : null}
      </ScrollView>
    </SafeAreaView>
  );
}
