import { StyleSheet, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Card, Chip, ErrorText, Loading, Notice, Screen, SvcHeader, s } from "../../../ui/kit";
import { tone, useLabels } from "../../../ui/labels";
import { color, font } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Journey { tracking_no: string; status: string; recipient_name: string; station: string | null; delivery_mode: "PICKUP" | "ADDRESS";
  delivery_address: string | null; secure: boolean; exception_kind: string | null; exception_note: string | null; pickup_code: string | null;
  id_check: { kind: string; last4: string; holder: string } | null;
  hops: { seq: number; location: string; received_at: string; dispatched_at: string | null }[];
  events: { milestone: string; reason_code: string | null; ts: string; place: string | null }[] }

/** A parcel the sender booked on a trip (1182, 1183): each step and location passed, how it is handed over, and the
 *  pickup code while it is valid, to pass on to the recipient. */
export default function ParcelJourney() {
  const { no } = useLocalSearchParams<{ no: string }>();
  const { t, has, dateTime } = useI18n();
  const labels = useLabels();
  const j = useLoad(() => api.get<Journey>(`/api/parcels/${encodeURIComponent(no ?? "")}/journey`), [no]);
  const step = (m: string) => (has(`svc.journey.milestone.${m}`) ? t(`svc.journey.milestone.${m}`) : labels.value(m));
  const where = (e: Journey["events"][number]) => e.place ?? (e.milestone === "RECEIVED_AT_HUB" || e.milestone === "DEPARTED" ? e.reason_code : null);
  return (
    <Screen>
      <SvcHeader icon="parcel" title={t("svc.journey.title", { no: no ?? "" })} sub={t("svc.journey.hint")} onBack={() => router.back()} />
      {j.loading && !j.data ? <Loading /> : <ErrorText error={j.error} />}
      {j.data ? (
        <>
          <Card>
            <View style={s.between}>
              <Text style={[s.mono, { fontSize: 18, color: color.navy, letterSpacing: 1.5 }]}>{j.data.tracking_no}</Text>
              <Chip label={labels.value(j.data.status)} tone={tone(j.data.status)} />
            </View>
            <View style={[s.between, { flexWrap: "wrap", gap: 6 }]}>
              <Chip label={t(`svc.journey.mode.${j.data.delivery_mode}`)} tone="blue" />
              {j.data.secure ? <Chip label={t("svc.journey.important")} tone="red" /> : null}
            </View>
            {j.data.delivery_address ? <Text style={s.small}>{j.data.delivery_address}</Text> : null}
            {j.data.id_check ? <Text style={s.small}>{t("svc.journey.idDone", { doc: t(`svc.journey.doc.${j.data.id_check.kind}`),
              last4: j.data.id_check.last4, holder: j.data.id_check.holder })}</Text> : null}
          </Card>
          {j.data.pickup_code ? (
            <Card>
              <Text style={s.label}>{j.data.delivery_mode === "ADDRESS" ? t("svc.journey.codeForCourier", { name: j.data.recipient_name })
                : t("svc.journey.codeFor", { name: j.data.recipient_name, station: j.data.station ?? "" })}</Text>
              <Text style={js.code} selectable>{j.data.pickup_code}</Text>
              <Text style={s.small}>{t("svc.journey.codeHint")}</Text>
            </Card>
          ) : null}
          {j.data.exception_kind ? <Notice tone="amber" text={`${t(`svc.journey.kind.${j.data.exception_kind}`)}${j.data.exception_note ? `: ${j.data.exception_note}` : ""}`} /> : null}
          {j.data.hops.length > 0 ? (
            <Card><Text style={s.label}>{t("svc.journey.route")}</Text><Text style={s.small}>{j.data.hops.map((h) => h.location).join(" · ")}</Text></Card>
          ) : null}
          <Card>
            {j.data.events.length === 0 ? <Text style={s.small}>{t("svc.journey.noSteps")}</Text> : j.data.events.map((e, i) => (
              <View key={i} style={{ paddingVertical: 4 }}>
                <Text style={[s.label, i === j.data!.events.length - 1 && { fontFamily: font.semibold, color: color.navy }]}>{step(e.milestone)}</Text>
                <Text style={s.small}>{dateTime(e.ts)}{where(e) ? ` · ${where(e)}` : ""}</Text>
              </View>
            ))}
          </Card>
        </>
      ) : null}
    </Screen>
  );
}

const js = StyleSheet.create({ code: { fontFamily: font.displayBold, fontSize: 34, letterSpacing: 6, color: color.navy, textAlign: "center", paddingVertical: 8 } });
