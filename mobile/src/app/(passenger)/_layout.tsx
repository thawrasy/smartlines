import { Redirect, Tabs } from "expo-router";
import { Text, type ColorValue } from "react-native";
import { useI18n } from "../../i18n";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";
import { Loading } from "../../ui/kit";
import { color } from "../../ui/theme";

const glyph = (g: string) => ({ color: c }: { color: ColorValue }) => <Text style={{ color: c, fontSize: 18 }}>{g}</Text>;

export default function PassengerLayout() {
  const { t } = useI18n();
  const { status } = useAuth();
  if (VARIANT === "passenger" && status === "loading") return <Loading />;   // keep the deep link while the session loads
  if (VARIANT !== "passenger" || status !== "signedIn") return <Redirect href="/" />;
  return (
    <Tabs screenOptions={{ headerShown: false, tabBarActiveTintColor: color.primary, tabBarInactiveTintColor: color.muted }}>
      <Tabs.Screen name="book" options={{ title: t("tabs.search"), tabBarIcon: glyph("⌕") }} />
      <Tabs.Screen name="trips" options={{ title: t("tabs.trips"), tabBarIcon: glyph("▤") }} />
      <Tabs.Screen name="services" options={{ title: t("tabs.services"), tabBarIcon: glyph("▦") }} />
      <Tabs.Screen name="wallet" options={{ title: t("tabs.wallet"), tabBarIcon: glyph("◈") }} />
      <Tabs.Screen name="account" options={{ title: t("tabs.account"), tabBarIcon: glyph("◉") }} />
      <Tabs.Screen name="results" options={{ href: null }} />
      <Tabs.Screen name="trip/[uid]" options={{ href: null }} />
      <Tabs.Screen name="booking/[ref]" options={{ href: null }} />
      <Tabs.Screen name="ticket/[uid]" options={{ href: null }} />
      <Tabs.Screen name="svc/passes" options={{ href: null }} />
      <Tabs.Screen name="svc/parcels" options={{ href: null }} />
      <Tabs.Screen name="svc/taxi" options={{ href: null }} />
      <Tabs.Screen name="svc/rental" options={{ href: null }} />
      <Tabs.Screen name="svc/track" options={{ href: null }} />
    </Tabs>
  );
}
