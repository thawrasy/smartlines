import { Pressable, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { useLabels } from "../../ui/labels";
import { color, space } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

export interface ModuleInfo { key: string; phase: number; icon: string; resources: { key: string; group: string }[] }

/** Every module switched on for the platform that this person's role can work in. */
export default function OperatorModules() {
  const { t } = useI18n();
  const labels = useLabels();
  const mods = useLoad(() => api.get<{ modules: ModuleInfo[] }>("/api/modules"));
  const mine = (mods.data?.modules ?? []).filter((m) => m.resources.length > 0);
  return (
    <Screen>
      <Title sub={t("op.modulesSub")}>{t("op.tabs.modules")}</Title>
      {mods.loading && !mods.data ? <Loading /> : <ErrorText error={mods.error} />}
      {mods.data && mine.length === 0 ? <Text style={s.muted}>{t("op.noModules")}</Text> : null}
      <View style={{ gap: space(3) }}>
        {mine.map((m) => (
          <Pressable key={m.key} accessibilityRole="button" onPress={() => router.push(`/operator/module/${m.key}`)}
                     style={({ pressed }) => [{ backgroundColor: color.surface, borderRadius: 16, borderWidth: 1, borderColor: color.outline,
                                                padding: space(4), gap: 4, opacity: pressed ? 0.8 : 1 }]}>
            <View style={s.between}>
              <Text style={s.h2}>{labels.module(m.key)}</Text>
              <Text style={s.small}>{t("op.records", { n: m.resources.length })}</Text>
            </View>
            {labels.moduleDesc(m.key) ? <Text style={s.small} numberOfLines={2}>{labels.moduleDesc(m.key)}</Text> : null}
          </Pressable>
        ))}
      </View>
    </Screen>
  );
}
