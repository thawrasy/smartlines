import { Redirect, Tabs } from "expo-router";
import type { ColorValue } from "react-native";
import { Icon, type IconName } from "../../ui/brand";
import { useI18n } from "../../i18n";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";
import { Loading } from "../../ui/kit";
import { color, font } from "../../ui/theme";

const glyph = (name: IconName) => ({ color: c }: { color: ColorValue }) => <Icon name={name} size={24} tint={String(c)} />;

export default function PassengerLayout() {
  const { t } = useI18n();
  const { status } = useAuth();
  if (VARIANT === "passenger" && status === "loading") return <Loading />;   // keep the deep link while the session loads
  if (VARIANT !== "passenger" || status !== "signedIn") return <Redirect href="/" />;
  return (
    <Tabs screenOptions={{ headerShown: false, tabBarActiveTintColor: color.primary, tabBarInactiveTintColor: color.muted,
                          tabBarLabelStyle: { fontFamily: font.medium, fontSize: 11.5 },
                          tabBarStyle: { borderTopColor: color.outline, backgroundColor: color.surface, height: 64, paddingTop: 6 } }}>
      <Tabs.Screen name="book" options={{ title: t("tabs.search"), tabBarIcon: glyph("search") }} />
      <Tabs.Screen name="trips" options={{ title: t("tabs.trips"), tabBarIcon: glyph("ticket") }} />
      <Tabs.Screen name="services" options={{ title: t("tabs.services"), tabBarIcon: glyph("grid") }} />
      <Tabs.Screen name="wallet" options={{ title: t("tabs.wallet"), tabBarIcon: glyph("wallet") }} />
      <Tabs.Screen name="account" options={{ title: t("tabs.account"), tabBarIcon: glyph("user") }} />
      <Tabs.Screen name="results" options={{ href: null }} />
      <Tabs.Screen name="journey" options={{ href: null }} />
      <Tabs.Screen name="svc/charter" options={{ href: null }} />
      <Tabs.Screen name="trip/[uid]" options={{ href: null }} />
      <Tabs.Screen name="booking/[ref]" options={{ href: null }} />
      <Tabs.Screen name="ticket/[uid]" options={{ href: null }} />
      <Tabs.Screen name="svc/passes" options={{ href: null }} />
      <Tabs.Screen name="svc/parcels" options={{ href: null }} />
      <Tabs.Screen name="svc/taxi" options={{ href: null }} />
      <Tabs.Screen name="svc/rental" options={{ href: null }} />
      <Tabs.Screen name="svc/track" options={{ href: null }} />
      <Tabs.Screen name="svc/family" options={{ href: null }} />
      <Tabs.Screen name="svc/support" options={{ href: null }} />
    </Tabs>
  );
}
