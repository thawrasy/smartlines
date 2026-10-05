import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { useLabels } from "../../../ui/labels";
import { color, space } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";
import type { ModuleInfo } from "../modules";

interface Tile { id: string; res: string; value: number; money: boolean; tone: string; filter: Record<string, string> }
interface Breakdown { res: string; column: string; items: { value: string; count: number }[] }

/** A module: its indicators, a breakdown by status, and the records the person can open. */
export default function OperatorModule() {
  const { key } = useLocalSearchParams<{ key: string }>();
  const { t, money } = useI18n();
  const labels = useLabels();
  const mods = useLoad(() => api.get<{ modules: ModuleInfo[] }>("/api/modules"), [key]);
  const dash = useLoad(() => api.get<{ tiles: Tile[]; breakdowns: Breakdown[] }>(`/api/m/${key}/dashboard`), [key]);
  const mod = mods.data?.modules.find((m) => m.key === key);
  const groups = new Map<string, string[]>();
  for (const r of mod?.resources ?? []) groups.set(r.group, [...(groups.get(r.group) ?? []), r.key]);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={labels.moduleDesc(key)}>{labels.module(key)}</Title>
      {dash.loading && !dash.data ? <Loading /> : <ErrorText error={dash.error} />}
      {dash.data && dash.data.tiles.length > 0 ? (
        <View style={{ flexDirection: "row", flexWrap: "wrap", gap: space(3) }}>
          {dash.data.tiles.map((tile) => (
            <Pressable key={tile.id} accessibilityRole="button"
                       onPress={() => router.push({ pathname: "/operator/res/[key]", params: { key: tile.res, ...Object.fromEntries(Object.entries(tile.filter).map(([k, v]) => [`f_${k}`, v])) } })}
                       style={{ flexBasis: "47%", flexGrow: 1, backgroundColor: color.surface, borderRadius: 14, borderWidth: 1, borderColor: color.outline, padding: space(3), gap: 4 }}>
              <Text style={s.small} numberOfLines={2}>{labels.tile(tile.id)}</Text>
              <Text style={{ fontSize: 22, fontWeight: "700", color: tile.tone === "red" ? color.error : tile.tone === "wheat" ? color.amber : color.navy }}>
                {tile.money ? money(tile.value) : tile.value.toLocaleString("en-US")}
              </Text>
            </Pressable>
          ))}
        </View>
      ) : null}
      {dash.data?.breakdowns.slice(0, 2).map((b) => {
        const max = Math.max(1, ...b.items.map((i) => i.count));
        return (
          <Card key={`${b.res}.${b.column}`}>
            <Text style={s.h2}>{t("op.byStatus", { name: labels.res(b.res) })}</Text>
            {b.items.map((i) => (
              <View key={i.value} style={{ gap: 4 }}>
                <View style={s.between}><Text style={s.small}>{labels.value(i.value)}</Text><Text style={s.small}>{i.count}</Text></View>
                <View style={{ height: 6, borderRadius: 3, backgroundColor: color.primarySoft }}>
                  <View style={{ height: 6, borderRadius: 3, width: `${(i.count / max) * 100}%`, backgroundColor: color.primary }} />
                </View>
              </View>
            ))}
          </Card>
        );
      })}
      {[...groups.entries()].map(([group, keys]) => (
        <Card key={group}>
          <Text style={s.h2}>{labels.group(group)}</Text>
          {keys.map((r) => (
            <Pressable key={r} accessibilityRole="button" onPress={() => router.push(`/operator/res/${r}`)}
                       style={({ pressed }) => [s.between, { paddingVertical: 12, borderTopWidth: 1, borderColor: color.outline, opacity: pressed ? 0.7 : 1 }]}>
              <Text style={s.label}>{labels.res(r)}</Text>
              <Text style={s.small}>›</Text>
            </Pressable>
          ))}
        </Card>
      ))}
    </Screen>
  );
}
