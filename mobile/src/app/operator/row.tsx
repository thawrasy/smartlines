import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { Button, Card, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { useLabels } from "../../ui/labels";
import { color } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";
import { useCell, type Col, type Row, type Spec } from "./res/[key]";

/** One record: every field, and the actions its current state allows (approve, dispatch, close…). */
export default function OperatorRow() {
  const { res, key } = useLocalSearchParams<{ res: string; key: string }>();
  const { t } = useI18n();
  const labels = useLabels();
  const cell = useCell();
  const spec = useLoad(() => api.get<Spec>(`/api/r/${res}/_spec`), [res]);
  const row = useLoad(() => api.get<Row>(`/api/r/${res}/${encodeURIComponent(key)}`), [res, key]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const r = row.data;
  const allowed = (spec.data?.actions ?? []).filter((a) => r && Object.entries(a.when).every(([c, vals]) => vals.includes(r[c] as string | boolean | null)));
  const fields: Col[] = r ? Object.keys(r).filter((k) => k !== "_key" && !k.endsWith("__label")).map((name) => (
    [...(spec.data?.list ?? []), ...(spec.data?.form ?? [])].find((c) => c.name === name)
      ?? { name, type: "text", required: false, choices: null, ref: r[`${name}__label`] !== undefined ? "ref" : null, money: false })) : [];
  const run = (action: string) => Alert.alert(labels.action(action), t("op.actionQ"), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("op.confirm"), onPress: async () => {
      setBusy(action); setError(null);
      try { await api.post(`/api/r/${res}/${encodeURIComponent(key)}/do/${action}`); row.reload(); }
      catch (e) { setError(e); } finally { setBusy(null); }
    } },
  ]);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={labels.res(res)}>{r && spec.data?.list[0] ? cell(spec.data.list[0], r) : key}</Title>
      {row.loading && !r ? <Loading /> : <ErrorText error={row.error ?? spec.error ?? error} />}
      {allowed.length > 0 ? (
        <View style={{ gap: 8 }}>
          {allowed.map((a) => <Button key={a.name} kind={/reject|cancel|suspend|block|close|retire/.test(a.name) ? "danger" : "primary"}
                                      label={labels.action(a.name)} busy={busy === a.name} disabled={!!busy && busy !== a.name} onPress={() => run(a.name)} />)}
        </View>
      ) : null}
      {r ? (
        <Card>
          {fields.filter((c) => !/^(id|uid)$/.test(c.name) && !c.name.endsWith("_enc") && !c.name.endsWith("_bidx")).map((c) => (
            <View key={c.name} style={{ paddingVertical: 8, borderBottomWidth: 1, borderColor: color.outline, gap: 2 }}>
              <Text style={s.small}>{labels.field(c.name)}</Text>
              <Text style={s.label} selectable>{cell(c, r)}</Text>
            </View>
          ))}
        </Card>
      ) : null}
    </Screen>
  );
}
