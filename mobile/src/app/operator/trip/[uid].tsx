import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";
import type { OpTrip } from "../index";

interface Passenger { ticket_no: string; seat_no: number | null; status: string; full_name: string; nationality: string; id_type: string; id_no_last4: string | null; booking_ref: string; from_code: string; to_code: string; boarded_at: string | null }

/** One trip: who is on board (the manifest), and the steps the carrier takes: publish, then complete after arrival. */
export default function OperatorTrip() {
  const { uid } = useLocalSearchParams<{ uid: string }>();
  const { t, station, time, date } = useI18n();
  const labels = useLabels();
  const trips = useLoad(() => api.get<{ trips: OpTrip[] }>("/api/carrier/trips"), [uid]);
  const manifest = useLoad(() => api.get<{ trip_no: string; passengers: Passenger[] }>(`/api/carrier/trips/${uid}/manifest`), [uid]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const trip = trips.data?.trips.find((x) => x.uid === uid);
  const step = (path: "publish" | "complete", question: string) => Alert.alert(question, "", [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("op.confirm"), onPress: async () => {
      setBusy(true); setError(null);
      try { await api.post(`/api/carrier/trips/${uid}/${path}`); trips.reload(); manifest.reload(); }
      catch (e) { setError(e); } finally { setBusy(false); }
    } },
  ]);
  const boarded = manifest.data?.passengers.filter((p) => p.boarded_at || p.status === "BOARDED").length ?? 0;
  return (
    <Screen>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      {trip ? (
        <>
          <Title sub={`${date(trip.departure_at)} · ${time(trip.departure_at)} · ${trip.trip_no}`}>
            {station(trip.origin_code, trip.origin)} → {station(trip.dest_code, trip.destination)}
          </Title>
          <View style={s.row}>
            <Chip label={labels.value(trip.status)} tone={tone(trip.status)} />
            {trip.plate_no ? <Chip label={trip.plate_no} /> : null}
            {trip.driver_name ? <Chip label={trip.driver_name} tone="blue" /> : null}
          </View>
          <ErrorText error={error} />
          {trip.status === "DRAFT" ? <Button label={t("op.publish")} busy={busy} onPress={() => step("publish", t("op.publishQ"))} /> : null}
          {["PUBLISHED", "BOARDING", "DEPARTED"].includes(trip.status) && new Date(trip.departure_at).getTime() < Date.now()
            ? <Button kind="tonal" label={t("op.complete")} busy={busy} onPress={() => step("complete", t("op.completeQ"))} /> : null}
        </>
      ) : trips.loading ? <Loading /> : <ErrorText error={trips.error} />}
      <Card>
        <View style={s.between}>
          <Text style={s.h2}>{t("op.manifest")}</Text>
          {manifest.data ? <Text style={s.small}>{t("op.boarded", { n: boarded, total: manifest.data.passengers.length })}</Text> : null}
        </View>
        {manifest.loading && !manifest.data ? <Loading /> : <ErrorText error={manifest.error} />}
        {manifest.data && manifest.data.passengers.length === 0 ? <Text style={s.muted}>{t("op.noPassengers")}</Text> : null}
        {manifest.data?.passengers.map((p) => (
          <View key={p.ticket_no} style={[s.between, { paddingVertical: 10, borderBottomWidth: 1, borderColor: color.outline }]}>
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={s.label}>{p.full_name}</Text>
              <Text style={s.small}>{station(p.from_code)} → {station(p.to_code)} · {p.booking_ref}</Text>
              <Text style={s.small}>{[p.id_type ? t(`trip.docTypes.${p.id_type}`) : null, p.id_no_last4 ? `···${p.id_no_last4}` : null, p.nationality].filter(Boolean).join(" · ")}</Text>
            </View>
            <View style={{ alignItems: "flex-end", gap: 4 }}>
              <Text style={{ fontSize: 18, fontWeight: "700", color: color.navy }}>{p.seat_no ?? "—"}</Text>
              <Chip label={labels.value(p.boarded_at ? "BOARDED" : p.status)} tone={p.boarded_at ? "green" : tone(p.status)} />
            </View>
          </View>
        ))}
      </Card>
    </Screen>
  );
}
