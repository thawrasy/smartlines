import { useEffect, useState } from "react";
import { StyleSheet, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, ErrorText, Field, Loading, Screen, SvcHeader, s } from "../../../ui/kit";
import { TripLine } from "../../../ui/brand";
import { tone, useLabels } from "../../../ui/labels";
import { color, font } from "../../../ui/theme";

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
      <SvcHeader icon="pin" title={t("svc.track.title")} sub={t("svc.track.hint")} onBack={() => router.back()} />
      <Field label={t("svc.track.number")} value={no} onChangeText={setNo} autoCapitalize="characters" autoCorrect={false} onSubmitEditing={() => find()} />
      <Button label={t("svc.track.find")} busy={busy} disabled={no.trim().length < 6} onPress={() => find()} />
      {busy ? <Loading /> : <ErrorText error={error} />}
      {data ? (
        <Card>
          <View style={s.between}>
            <Text style={[s.mono, { fontSize: 18, color: color.navy, letterSpacing: 1.5 }]}>{data.tracking_no}</Text>
            <Chip label={labels.value(data.status)} tone={tone(data.status)} />
          </View>
          <View style={[s.between, { paddingVertical: 4 }]}>
            <Text style={ts.end} numberOfLines={2}>{station(data.origin_code, data.origin)}</Text>
            <TripLine width={80} height={16} />
            <Text style={ts.end} numberOfLines={2}>{station(data.destination_code, data.destination)}</Text>
          </View>
          <Text style={s.small}>{data.service}</Text>
          <View style={{ paddingTop: 6 }}>
            {data.events.map((e, i) => {
              const last = i === data.events.length - 1, done = e.milestone === "DELIVERED";
              return (
                <View key={i} style={{ flexDirection: "row", gap: 12 }}>
                  <View style={{ alignItems: "center", width: 16 }}>
                    <View style={[ts.dot, i === 0 && { backgroundColor: done ? color.arrival : color.route, borderColor: done ? color.arrival : color.route }]} />
                    {!last ? <View style={ts.line} /> : null}
                  </View>
                  <View style={{ flex: 1, paddingBottom: last ? 0 : 14 }}>
                    <Text style={[s.label, i === 0 && { fontFamily: font.semibold, color: color.navy }]}>{labels.value(e.milestone)}</Text>
                    <Text style={s.small}>{dateTime(e.ts)}{e.place ? ` · ${station(e.place_code, e.place)}` : ""}</Text>
                  </View>
                </View>
              );
            })}
          </View>
        </Card>
      ) : null}
    </Screen>
  );
}

const ts = StyleSheet.create({
  end: { flex: 1, fontFamily: font.display, fontSize: 15, color: color.navy, textAlign: "center" },
  dot: { width: 14, height: 14, borderRadius: 7, borderWidth: 2, borderColor: color.outline, backgroundColor: color.surface, marginTop: 3 },
  line: { flex: 1, width: 2, backgroundColor: color.outline, marginVertical: 2 },
});
