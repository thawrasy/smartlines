import { Redirect, Tabs } from "expo-router";
import { Text, type ColorValue } from "react-native";
import { useI18n } from "../../i18n";
import { useAuth } from "../../platform/auth";
import { VARIANT } from "../../platform/config";
import { Loading } from "../../ui/kit";
import { color } from "../../ui/theme";

const glyph = (g: string) => ({ color: c }: { color: ColorValue }) => <Text style={{ color: c, fontSize: 18 }}>{g}</Text>;

/** The operator app: carrier staff run their day (trips, manifests) and every module their company uses. */
export default function OperatorLayout() {
  const { t } = useI18n();
  const { status } = useAuth();
  if (VARIANT === "operator" && status === "loading") return <Loading />;   // keep the deep link while the session loads
  if (VARIANT !== "operator" || status !== "signedIn") return <Redirect href="/" />;
  return (
    <Tabs screenOptions={{ headerShown: false, tabBarActiveTintColor: color.primary, tabBarInactiveTintColor: color.muted }}>
      <Tabs.Screen name="index" options={{ title: t("op.tabs.today"), tabBarIcon: glyph("◷") }} />
      <Tabs.Screen name="trips" options={{ title: t("op.tabs.trips"), tabBarIcon: glyph("▤") }} />
      <Tabs.Screen name="modules" options={{ title: t("op.tabs.modules"), tabBarIcon: glyph("▦") }} />
      <Tabs.Screen name="account" options={{ title: t("tabs.account"), tabBarIcon: glyph("◉") }} />
      <Tabs.Screen name="trip/[uid]" options={{ href: null }} />
      <Tabs.Screen name="module/[key]" options={{ href: null }} />
      <Tabs.Screen name="res/[key]" options={{ href: null }} />
      <Tabs.Screen name="row" options={{ href: null }} />
    </Tabs>
  );
}
