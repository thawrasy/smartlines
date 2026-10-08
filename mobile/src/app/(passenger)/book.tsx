import { useState } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n, zone } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, Loading, Screen, Title, s } from "../../ui/kit";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

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

export default function Book() {
  const { t, date } = useI18n();
  const ref = useLoad(() => api.get<{ cities: { code: string }[] }>("/api/ref"));
  const [origin, setOrigin] = useState("DAM");
  const [destination, setDestination] = useState("ALP");
  const [on, setOn] = useState(dayIso(0));
  const [passengers, setPassengers] = useState(1);
  const cities = (ref.data?.cities ?? []).map((c) => ({ key: c.code, label: t(`city.${c.code}`) }));
  const days = Array.from({ length: 14 }, (_, n) => ({ key: dayIso(n), label: date(`${dayIso(n)}T12:00:00Z`) }));
  return (
    <Screen>
      <Title>{t("search.title")}</Title>
      {ref.loading ? <Loading /> : (
        <Card>
          <Text style={s.label}>{t("search.origin")}</Text>
          <Pills items={cities} value={origin} onChange={setOrigin} />
          <Text style={s.label}>{t("search.destination")}</Text>
          <Pills items={cities.filter((c) => c.key !== origin)} value={destination} onChange={setDestination} />
          <Text style={s.label}>{t("search.date")}</Text>
          <Pills items={days} value={on} onChange={setOn} />
          <View style={s.between}>
            <Text style={s.label}>{t("common.passengers")}</Text>
            <View style={s.row}>
              <Button kind="tonal" label="−" onPress={() => setPassengers(Math.max(1, passengers - 1))} />
              <Text style={[s.h2, { minWidth: 28, textAlign: "center" }]}>{passengers}</Text>
              <Button kind="tonal" label="+" onPress={() => setPassengers(Math.min(4, passengers + 1))} />
            </View>
          </View>
          <Button label={t("search.find")} disabled={origin === destination}
                  onPress={() => router.push({ pathname: "/results", params: { origin, destination, on, passengers: String(passengers) } })} />
        </Card>
      )}
    </Screen>
  );
}
