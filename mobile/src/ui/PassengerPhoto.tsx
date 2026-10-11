// The passenger's boarding photo, shown to the driver after a scan that boarded (1086). It is loaded from the API with
// the driver's own token, and only for the trip the driver is assigned to; the API answers the rest with an error.
import { useEffect, useState } from "react";
import { Image, Text, View } from "react-native";
import { useI18n } from "../i18n";
import { authHeaders } from "../platform/api";
import { API_URL } from "../platform/config";
import { s } from "./kit";

export function PassengerPhoto({ tripUid, ticketUid }: { tripUid: string; ticketUid: string }) {
  const { t } = useI18n();
  const [headers, setHeaders] = useState<Record<string, string> | null>(null);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    setFailed(false);
    void authHeaders().then(setHeaders);
  }, [ticketUid]);
  if (failed) return <Text style={s.small}>{t("driver.noPhoto")}</Text>;
  if (!headers) return null;
  return (
    <View style={{ gap: 6, alignItems: "center" }}>
      <Text style={s.label}>{t("driver.passengerPhoto")}</Text>
      <Image accessibilityLabel={t("driver.passengerPhoto")} resizeMode="cover" onError={() => setFailed(true)}
             source={{ uri: `${API_URL}/api/driver/trips/${tripUid}/tickets/${ticketUid}/photo`, headers }}
             style={{ width: 160, height: 200, borderRadius: 12 }} />
    </View>
  );
}
