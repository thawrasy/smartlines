import { useEffect, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Chip, ErrorText, Field, Loading, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

export interface Col { name: string; type: string; required: boolean; choices: string[] | null; ref: string | null; money: boolean }
export interface Spec { key: string; module: string; group: string; pk: string[]; list: Col[]; form: Col[]; actions: { name: string; when: Record<string, (string | boolean | null)[]> }[] }
export type Row = Record<string, unknown> & { _key: string };

/** A readable value: reference labels, money, dates, and translated status values. */
export function useCell() {
  const { money, dateTime, t } = useI18n();
  const labels = useLabels();
  return (col: Col, row: Row): string => {
    const v = row[col.name];
    if (v === null || v === undefined || v === "") return "—";
    if (col.ref && row[`${col.name}__label`]) return String(row[`${col.name}__label`]);
    if (typeof v === "boolean") return v ? t("op.yes") : t("op.no");
    if (col.money && typeof v === "number") return money(v);
    if (col.choices) return labels.value(String(v));
    if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}T/.test(v)) return dateTime(v);
    if (Array.isArray(v)) return v.join(", ");
    if (typeof v === "object") return JSON.stringify(v);
    return String(v);
  };
}

/** Records of one resource, newest first, with search; a tile can open it already filtered. */
export default function OperatorResource() {
  const params = useLocalSearchParams<Record<string, string>>();
  const key = params.key;
  const filters = Object.fromEntries(Object.entries(params).filter(([k]) => k.startsWith("f_")));
  const { t } = useI18n();
  const labels = useLabels();
  const cell = useCell();
  const [q, setQ] = useState("");
  const [query, setQuery] = useState("");
  const [limit, setLimit] = useState(30);
  useEffect(() => { const id = setTimeout(() => setQuery(q.trim()), 400); return () => clearTimeout(id); }, [q]);
  const spec = useLoad(() => api.get<Spec>(`/api/r/${key}/_spec`), [key]);
  const list = useLoad(() => api.get<{ rows: Row[]; total: number }>(`/api/r/${key}`, { q: query || undefined, limit, ...filters }),
                       [key, query, limit, JSON.stringify(filters)]);
  const cols = spec.data?.list ?? [];
  const statusCol = cols.find((c) => c.choices && /status|state/.test(c.name));
  const head = cols.filter((c) => c !== statusCol).slice(0, 4);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={list.data ? t("op.total", { n: list.data.total }) : undefined}>{labels.res(key)}</Title>
      {Object.keys(filters).length ? (
        <View style={s.row}>{Object.entries(filters).map(([k, v]) => <Chip key={k} tone="blue" label={`${labels.field(k.slice(2))}: ${labels.value(v)}`} />)}</View>
      ) : null}
      <Field label={t("op.search")} value={q} onChangeText={setQ} autoCorrect={false} />
      {(spec.loading || list.loading) && !list.data ? <Loading /> : <ErrorText error={spec.error ?? list.error} />}
      {list.data && list.data.rows.length === 0 ? <Text style={s.muted}>{t("op.empty")}</Text> : null}
      {list.data?.rows.map((r) => (
        <Pressable key={r._key} accessibilityRole="button" onPress={() => router.push({ pathname: "/operator/row", params: { res: key, key: r._key } })}
                   style={({ pressed }) => [{ backgroundColor: color.surface, borderRadius: 14, borderWidth: 1, borderColor: color.outline, padding: 14, gap: 4, opacity: pressed ? 0.8 : 1 }]}>
          <View style={s.between}>
            <Text style={[s.label, { flex: 1 }]} numberOfLines={1}>{head[0] ? cell(head[0], r) : r._key}</Text>
            {statusCol && r[statusCol.name] ? <Chip label={labels.value(String(r[statusCol.name]))} tone={tone(String(r[statusCol.name]))} /> : null}
          </View>
          {head.slice(1).map((c) => (
            <Text key={c.name} style={s.small} numberOfLines={1}>{labels.field(c.name)}: {cell(c, r)}</Text>
          ))}
        </Pressable>
      ))}
      {list.data && list.data.rows.length < list.data.total ? <Button kind="tonal" label={t("op.more")} onPress={() => setLimit(limit + 30)} /> : null}
    </Screen>
  );
}
