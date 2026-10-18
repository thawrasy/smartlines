import { Pressable, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { color, radius, space } from "../../ui/theme";
import { Icon } from "../../ui/brand";
import { useLoad } from "../../ui/useLoad";

// service -> the module that must be switched on, and the screen
const SERVICES = [
  { key: "passes", module: "shuttle_subscriptions", icon: "pass", href: "/svc/passes" },
  { key: "parcels", module: "cargo", icon: "parcel", href: "/svc/parcels" },
  { key: "taxi", module: "taxi", icon: "car", href: "/svc/taxi" },
  { key: "rental", module: "car_rental", icon: "key", href: "/svc/rental" },
  { key: "track", module: "cargo", icon: "pin", href: "/svc/track" },
  { key: "family", module: "family_accounts", icon: "people", href: "/svc/family" },
  { key: "support", module: "support_cases", icon: "chat", href: "/svc/support" },
  { key: "charter", module: null, icon: "bus", href: "/svc/charter" },          // hiring a bus or a trip (1123): always offered
] as const;

/** Everything beyond intercity trips, shown only when the platform has the module switched on. */
export default function Services() {
  const { t } = useI18n();
  const features = useLoad(() => api.get<{ enabled: string[] }>("/api/features"));
  const on = new Set(features.data?.enabled ?? []);
  const shown = SERVICES.filter((x) => x.module === null || on.has(x.module));
  return (
    <Screen>
      <Title sub={t("svc.sub")}>{t("tabs.services")}</Title>
      {features.loading && !features.data ? <Loading /> : <ErrorText error={features.error} />}
      {features.data && shown.length === 0 ? <Text style={s.muted}>{t("svc.none")}</Text> : null}
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: space(3) }}>
        {shown.map((x) => (
          <Pressable key={x.key} accessibilityRole="button" onPress={() => router.push(x.href)}
                     style={({ pressed }) => [{ flexBasis: "47%", flexGrow: 1, minHeight: 132, backgroundColor: color.surface, borderRadius: radius.md,
                                                padding: space(4), gap: 8, opacity: pressed ? 0.8 : 1, shadowColor: "#0F1B2D", shadowOpacity: 0.06,
                                                shadowRadius: 10, shadowOffset: { width: 0, height: 3 }, elevation: 1 }]}>
            <View style={{ width: 44, height: 44, borderRadius: 22, backgroundColor: color.primarySoft, alignItems: "center", justifyContent: "center" }}>
              <Icon name={x.icon} size={24} tint={color.primary} />
            </View>
            <Text style={s.h2}>{t(`svc.${x.key}.title`)}</Text>
            <Text style={s.small} numberOfLines={2}>{t(`svc.${x.key}.hint`)}</Text>
          </Pressable>
        ))}
      </View>
    </Screen>
  );
}
