import { useEffect, useState } from "react";
import { Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, ErrorText, Field, Loading, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { color } from "../../../ui/theme";

interface Tracking { tracking_no: string; status: string; service: string; origin_code: string; destination_code: string; origin: string; destination: string; eta: string | null;
  events: { milestone: string; ts: string; place: string | null; place_code: string | null }[] }

/** Parcel tracking by number: status, places and times (no personal data). */
export default function Track() {
  const params = useLocalSearchParams<{ no?: string }>();
  const { t, station, dateTime } = useI18n();
  const labels = useLabels();
  const [no, setNo] = useState(params.no ?? "");
  const [data, setData] = useState<Tracking | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const find = async (value = no) => {
    setBusy(true); setError(null); setData(null);
    try { setData(await api.get<Tracking>(`/api/track/${encodeURIComponent(value.trim().toUpperCase())}`)); }
    catch (e) { setError(e); } finally { setBusy(false); }
  };
  // opened from "my parcels": look the number up at once
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => { if (params.no) { setNo(params.no); void find(params.no); } }, [params.no]);
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <Title sub={t("svc.track.hint")}>{t("svc.track.title")}</Title>
      <Field label={t("svc.track.number")} value={no} onChangeText={setNo} autoCapitalize="characters" autoCorrect={false} onSubmitEditing={() => find()} />
      <Button label={t("svc.track.find")} busy={busy} disabled={no.trim().length < 6} onPress={() => find()} />
      {busy ? <Loading /> : <ErrorText error={error} />}
      {data ? (
        <Card>
          <View style={s.between}>
            <Text style={s.h2}>{data.tracking_no}</Text>
            <Chip label={labels.value(data.status)} tone={tone(data.status)} />
          </View>
          <Text style={s.small}>{station(data.origin_code, data.origin)} → {station(data.destination_code, data.destination)} · {data.service}</Text>
          {data.events.map((e, i) => (
            <View key={i} style={{ flexDirection: "row", gap: 10, paddingVertical: 6 }}>
              <View style={{ width: 10, height: 10, borderRadius: 5, marginTop: 5, backgroundColor: i === 0 ? color.primary : color.outline }} />
              <View style={{ flex: 1 }}>
                <Text style={s.label}>{labels.value(e.milestone)}</Text>
                <Text style={s.small}>{dateTime(e.ts)}{e.place ? ` · ${station(e.place_code, e.place)}` : ""}</Text>
              </View>
            </View>
          ))}
        </Card>
      ) : null}
    </Screen>
  );
}
