import { useMemo, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { Card, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { TripRow, type OpTrip } from "./index";

const FILTERS = ["upcoming", "today", "past"] as const;

export default function OperatorTrips() {
  const { t, date } = useI18n();
  const list = useLoad(() => api.get<{ trips: OpTrip[] }>("/api/carrier/trips"));
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("upcoming");
  const groups = useMemo(() => {
    const now = Date.now();
    const today = new Date().toDateString();
    const rows = (list.data?.trips ?? []).filter((x) => {
      const at = new Date(x.departure_at);
      if (filter === "today") return at.toDateString() === today;
      if (filter === "past") return at.getTime() < now - 6 * 3600e3;
      return at.getTime() >= now - 6 * 3600e3;
    });
    const out: { day: string; trips: OpTrip[] }[] = [];
    for (const x of filter === "past" ? [...rows].reverse() : rows) {
      const day = date(x.departure_at);
      if (!out.length || out[out.length - 1].day !== day) out.push({ day, trips: [] });
      out[out.length - 1].trips.push(x);
    }
    return out;
  }, [list.data, filter, date]);
  return (
    <Screen>
      <Title>{t("op.tabs.trips")}</Title>
      <View style={[s.row, { flexWrap: "wrap" }]}>
        {FILTERS.map((f) => (
          <Pressable key={f} accessibilityRole="button" accessibilityState={{ selected: filter === f }} onPress={() => setFilter(f)}
                     style={{ paddingHorizontal: 14, paddingVertical: 8, borderRadius: 999, backgroundColor: filter === f ? color.primary : color.primarySoft }}>
            <Text style={{ color: filter === f ? "#fff" : color.primary, fontWeight: "600" }}>{t(`op.filter.${f}`)}</Text>
          </Pressable>
        ))}
      </View>
      {list.loading && !list.data ? <Loading /> : <ErrorText error={list.error} />}
      {list.data && groups.length === 0 ? <Text style={s.muted}>{t("op.noTrips")}</Text> : null}
      {groups.map((g) => (
        <Card key={g.day}>
          <Text style={s.h2}>{g.day}</Text>
          {g.trips.map((x) => <TripRow key={x.uid} trip={x} />)}
        </Card>
      ))}
    </Screen>
  );
}
