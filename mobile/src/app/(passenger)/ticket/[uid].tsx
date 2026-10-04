// The boarding code. It is the signed offline credential, so it scans the same with or without a connection.
// Screenshots and screen recording are blocked here: a copied code is a copied ticket.
import { Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { usePreventScreenCapture } from "expo-screen-capture";
import QRCode from "react-native-qrcode-svg";
import { useI18n } from "../../../i18n";
import { credentialFor } from "../../../platform/tickets";
import { readClaims } from "../../../core/ticketCredential";
import { Button, Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

export default function Ticket() {
  usePreventScreenCapture();
  const { t } = useI18n();
  const { uid } = useLocalSearchParams<{ uid: string }>();
  const c = useLoad(() => credentialFor(uid), [uid]);
  const claims = c.data ? readClaims(c.data.cred.credential) : null;
  return (
    <Screen>
      <Title sub={t("ticket.show")}>{t("ticket.title")}</Title>
      {c.loading ? <Loading /> : null}
      {c.error ? <><ErrorText error={c.error} /><Text style={s.muted}>{t("ticket.notSaved")}</Text></> : null}
      {c.data && claims ? (
        <Card style={{ alignItems: "center" }}>
          <Text style={[s.title, { fontSize: 22 }]}>{claims.n}</Text>
          <Text style={s.h2}>{t("common.seat")} {claims.s} · {t("extra.trip", { no: c.data.cred.trip_no })}</Text>
          <View style={{ padding: 16, backgroundColor: "#fff", borderRadius: 16 }}>
            <QRCode value={c.data.cred.credential} size={260} ecl="M" color={color.navy} backgroundColor="#fff" />
          </View>
          <Chip tone="green" label={t("ticket.offlineReady")} />
        </Card>
      ) : null}
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
    </Screen>
  );
}
