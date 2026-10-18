// The boarding pass (identity 1.2): navy head with the name and the booking reference, the two cities joined by the trip
// line, the passenger and the trip, the seat, bay and time to be there in large boxes, a cut line, then the boarding
// code. The code is the signed offline credential, so it scans the same with or without a connection; the rest is
// kept with it on the phone. Screenshots and screen recording are blocked here: a copied code is a copied ticket.
import { useState } from "react";
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { router, useLocalSearchParams } from "expo-router";
import { usePreventScreenCapture } from "expo-screen-capture";
import QRCode from "react-native-qrcode-svg";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { credentialFor, type TicketDisplay } from "../../../platform/tickets";
import { readClaims } from "../../../core/ticketCredential";
import { Button, CarrierName, Chip, ErrorText, Loading, Notice, s } from "../../../ui/kit";
import { Icon, Lockup, TripLine } from "../../../ui/brand";
import { color, font, radius } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

export default function Ticket() {
  usePreventScreenCapture();
  const { t } = useI18n();
  const { uid } = useLocalSearchParams<{ uid: string }>();
  const c = useLoad(() => credentialFor(uid), [uid]);
  const claims = c.data ? readClaims(c.data.cred.credential) : null;
  const [sos, setSos] = useState<{ repeated: boolean } | null>(null);
  const [sosError, setSosError] = useState<unknown>(null);
  // a passenger on a trip under way can call for help; the server checks the trip and the ticket (1101)
  const raiseSos = () => Alert.alert(t("sos.confirm"), t("sos.confirmHint"), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("sos.send"), style: "destructive", onPress: async () => {
      setSosError(null);
      try { setSos(await api.post<{ repeated: boolean }>(`/api/tickets/${uid}/sos`, {})); } catch (e) { setSosError(e); }
    } },
  ]);
  return (
    <SafeAreaView style={{ flex: 1, backgroundColor: color.background }} edges={["top", "left", "right"]}>
      <ScrollView contentContainerStyle={st.page}>
        <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel={t("common.back")} hitSlop={12} style={{ alignSelf: "flex-start" }}>
          <Icon name="back" size={26} tint={color.primary} mirror />
        </Pressable>
        {c.loading ? <Loading /> : null}
        {c.error ? <><ErrorText error={c.error} /><Text style={s.muted}>{t("ticket.notSaved")}</Text></> : null}
        {c.data && claims ? (
          <Pass name={claims.n} seat={claims.s} code={c.data.cred.trip_code ?? c.data.cred.trip_no} credential={c.data.cred.credential} shown={c.data.cred.display} />
        ) : null}
        <Button kind="danger" label={t("sos.button")} onPress={raiseSos} />
        {sos ? <Notice tone="amber" text={t(sos.repeated ? "sos.again" : "sos.sent")} /> : null}
        <ErrorText error={sosError} />
      </ScrollView>
    </SafeAreaView>
  );
}

function Pass({ name, seat, code, credential, shown }: { name: string; seat: string; code: string; credential: string; shown?: TicketDisplay }) {
  const { t, city, time, date } = useI18n();
  // a credential saved before the display fields existed still shows the passenger, the seat, the trip and the code
  const arriveBy = shown?.departs_at && shown.lead_min != null
    ? time(new Date(new Date(shown.departs_at).getTime() - shown.lead_min * 60000).toISOString()) : null;
  return (
    <View style={st.pass} accessibilityLabel={t("ticket.board")}>
      <View style={st.head}>
        <Lockup height={26} white />
        <View style={{ alignItems: "flex-end" }}>
          <Text style={st.headLabel}>{t("ticket.board")}</Text>
          {shown ? <Text style={st.headRef}>{shown.booking_ref}</Text> : null}
        </View>
      </View>

      {shown ? (
        <View style={st.route}>
          <View style={st.end}>
            <Text style={st.city} numberOfLines={1} adjustsFontSizeToFit>{city(shown.from_city)}</Text>
            {shown.departs_at ? <Text style={st.time}>{time(shown.departs_at)}</Text> : null}
          </View>
          <View style={{ flex: 1, minWidth: 70, alignItems: "center" }}><TripLine width={90} height={20} /></View>
          <View style={st.end}>
            <Text style={st.city} numberOfLines={1} adjustsFontSizeToFit>{city(shown.to_city)}</Text>
            {shown.arrives_at ? <Text style={st.time}>{time(shown.arrives_at)}</Text> : null}
          </View>
        </View>
      ) : null}

      <View style={st.grid}>
        <Item label={t("ticket.passenger")} value={name} wide />
        {shown?.departs_at ? <Item label={t("ticket.date")} value={date(shown.departs_at)} /> : null}
        {shown ? <Item label={t("ticket.fare")} value={t(`conn.brand.${shown.fare_brand}`)} /> : null}
        {shown ? (
          <View style={st.item}>
            <Text style={st.itemLabel}>{t("ticket.carrier")}</Text>
            <CarrierName name={shown.carrier_name} uid={shown.carrier_uid} logo={shown.carrier_logo} style={st.itemValue} />
          </View>
        ) : null}
        <Item label={t("ticket.trip")} value={code} mono />
      </View>

      <View style={st.boxes}>
        <Box label={t("ticket.seat")} value={shown?.seat ?? seat} seat />
        <Box label={t("ticket.bay")} value={shown?.bay ?? t("ticket.noBay")} />
        {arriveBy ? <Box label={t("ticket.arriveBy")} value={arriveBy} /> : null}
      </View>

      <Cut />

      <View style={st.code}>
        <View style={st.qr}><QRCode value={credential} size={210} ecl="M" color={color.navy} backgroundColor="#fff" /></View>
        <Text style={st.show}>{t("ticket.show")}</Text>
        <View style={{ alignItems: "center" }}><Chip tone="green" label={t("ticket.offlineReady")} /></View>
      </View>
    </View>
  );
}

function Item({ label, value, mono, wide }: { label: string; value: string; mono?: boolean; wide?: boolean }) {
  return (
    <View style={[st.item, wide && { width: "100%" }]}>
      <Text style={st.itemLabel}>{label}</Text>
      <Text style={[st.itemValue, mono && st.mono]} numberOfLines={1}>{value}</Text>
    </View>
  );
}

function Box({ label, value, seat }: { label: string; value: string; seat?: boolean }) {
  return (
    <View style={[st.box, seat && st.seatBox]}>
      <Text style={[st.boxLabel, seat && { color: color.green }]}>{label}</Text>
      <Text style={[st.boxValue, seat && { color: "#00391F" }]}>{value}</Text>
    </View>
  );
}

/** The tear line: a dashed rule between two notches cut out of the pass. */
function Cut() {
  return (
    <View style={st.cut}>
      <View style={[st.notch, { left: -12 }]} />
      <View style={st.dashes}>{Array.from({ length: 22 }, (_, i) => <View key={i} style={st.dash} />)}</View>
      <View style={[st.notch, { right: -12 }]} />
    </View>
  );
}

const st = StyleSheet.create({
  page: { padding: 20, gap: 16, paddingBottom: 32 },
  pass: { backgroundColor: color.surface, borderRadius: radius.lg, overflow: "hidden",
          shadowColor: "#0F1B2D", shadowOpacity: 0.12, shadowRadius: 18, shadowOffset: { width: 0, height: 8 }, elevation: 4 },
  head: { backgroundColor: color.navy, paddingHorizontal: 20, paddingVertical: 16, flexDirection: "row", alignItems: "center", justifyContent: "space-between" },
  headLabel: { fontFamily: font.medium, fontSize: 13, color: "#B8C2CF" },
  headRef: { fontFamily: font.mono, fontSize: 15, color: "#fff", letterSpacing: 1 },
  route: { flexDirection: "row", alignItems: "center", paddingHorizontal: 20, paddingTop: 20, paddingBottom: 8, gap: 8 },
  end: { alignItems: "center", flexShrink: 1, maxWidth: "40%" },
  city: { fontFamily: font.displayBold, fontSize: 26, color: color.navy },
  time: { fontFamily: font.display, fontSize: 16, color: color.muted },
  grid: { flexDirection: "row", flexWrap: "wrap", paddingHorizontal: 20, paddingTop: 8, rowGap: 12 },
  item: { width: "50%", gap: 2 },
  itemLabel: { fontFamily: font.body, fontSize: 12.5, color: color.muted },
  itemValue: { fontFamily: font.semibold, fontSize: 16, color: color.text },
  mono: { fontFamily: font.mono, letterSpacing: 0.5 },
  boxes: { flexDirection: "row", gap: 10, paddingHorizontal: 20, paddingTop: 16, paddingBottom: 18 },
  box: { flex: 1, borderWidth: 1.5, borderColor: color.outline, borderRadius: radius.sm, alignItems: "center", paddingVertical: 8 },
  seatBox: { backgroundColor: color.greenSoft, borderColor: color.greenSoft },
  boxLabel: { fontFamily: font.body, fontSize: 12, color: color.muted },
  boxValue: { fontFamily: font.displayBold, fontSize: 24, color: color.navy },
  cut: { height: 24, justifyContent: "center" },
  notch: { position: "absolute", top: 0, width: 24, height: 24, borderRadius: 12, backgroundColor: color.background },
  dashes: { flexDirection: "row", justifyContent: "space-between", marginHorizontal: 22 },
  dash: { width: 8, height: 2, borderRadius: 1, backgroundColor: color.outline },
  code: { alignItems: "center", gap: 10, paddingTop: 10, paddingBottom: 22 },
  qr: { padding: 12, backgroundColor: "#fff", borderRadius: radius.md, borderWidth: 1, borderColor: color.outline },
  show: { fontFamily: font.display, fontSize: 15, color: color.text },
});
