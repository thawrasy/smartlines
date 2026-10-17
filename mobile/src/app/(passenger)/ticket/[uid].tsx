// The boarding code. It is the signed offline credential, so it scans the same with or without a connection.
// Screenshots and screen recording are blocked here: a copied code is a copied ticket.
import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { usePreventScreenCapture } from "expo-screen-capture";
import QRCode from "react-native-qrcode-svg";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { credentialFor } from "../../../platform/tickets";
import { readClaims } from "../../../core/ticketCredential";
import { Button, Card, Chip, ErrorText, Loading, Notice, Screen, Title, s } from "../../../ui/kit";
import { color } from "../../../ui/theme";
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
    <Screen>
      <Title sub={t("ticket.show")}>{t("ticket.title")}</Title>
      {c.loading ? <Loading /> : null}
      {c.error ? <><ErrorText error={c.error} /><Text style={s.muted}>{t("ticket.notSaved")}</Text></> : null}
      {c.data && claims ? (
        <Card style={{ alignItems: "center" }}>
          <Text style={[s.title, { fontSize: 22 }]}>{claims.n}</Text>
          <Text style={s.h2}>{t("common.seat")} {claims.s} · {t("extra.trip", { no: c.data.cred.trip_code ?? c.data.cred.trip_no })}</Text>
          <View style={{ padding: 16, backgroundColor: "#fff", borderRadius: 16 }}>
            <QRCode value={c.data.cred.credential} size={260} ecl="M" color={color.navy} backgroundColor="#fff" />
          </View>
          <Chip tone="green" label={t("ticket.offlineReady")} />
        </Card>
      ) : null}
      <Button kind="danger" label={t("sos.button")} onPress={raiseSos} />
      {sos ? <Notice tone="amber" text={t(sos.repeated ? "sos.again" : "sos.sent")} /> : null}
      <ErrorText error={sosError} />
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
    </Screen>
  );
}
