import { Pressable, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { color, space } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

// service -> the module that must be switched on, and the screen
const SERVICES = [
  { key: "passes", module: "shuttle_subscriptions", glyph: "▣", href: "/svc/passes" },
  { key: "parcels", module: "cargo", glyph: "▢", href: "/svc/parcels" },
  { key: "taxi", module: "taxi", glyph: "◆", href: "/svc/taxi" },
  { key: "rental", module: "car_rental", glyph: "◇", href: "/svc/rental" },
  { key: "track", module: "cargo", glyph: "⌖", href: "/svc/track" },
  { key: "family", module: "family_accounts", glyph: "◎", href: "/svc/family" },
] as const;

/** Everything beyond intercity trips, shown only when the platform has the module switched on. */
export default function Services() {
  const { t } = useI18n();
  const features = useLoad(() => api.get<{ enabled: string[] }>("/api/features"));
  const on = new Set(features.data?.enabled ?? []);
  const shown = SERVICES.filter((x) => on.has(x.module));
  return (
    <Screen>
      <Title sub={t("svc.sub")}>{t("tabs.services")}</Title>
      {features.loading && !features.data ? <Loading /> : <ErrorText error={features.error} />}
      {features.data && shown.length === 0 ? <Text style={s.muted}>{t("svc.none")}</Text> : null}
      <View style={{ flexDirection: "row", flexWrap: "wrap", gap: space(3) }}>
        {shown.map((x) => (
          <Pressable key={x.key} accessibilityRole="button" onPress={() => router.push(x.href)}
                     style={({ pressed }) => [{ flexBasis: "47%", flexGrow: 1, minHeight: 120, backgroundColor: color.surface, borderRadius: 18, borderWidth: 1,
                                                borderColor: color.outline, padding: space(4), gap: 6, opacity: pressed ? 0.8 : 1 }]}>
            <Text style={{ fontSize: 26, color: color.primary }}>{x.glyph}</Text>
            <Text style={s.h2}>{t(`svc.${x.key}.title`)}</Text>
            <Text style={s.small} numberOfLines={2}>{t(`svc.${x.key}.hint`)}</Text>
          </Pressable>
        ))}
      </View>
    </Screen>
  );
}
