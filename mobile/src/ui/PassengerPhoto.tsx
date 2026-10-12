// The passenger's boarding photo, shown to the driver after a scan that boarded (1086). It is loaded from the API with
// the driver's own token, and only for the trip the driver is assigned to; the API answers the rest with an error.
import { useEffect, useState } from "react";
import { Image, Text, View } from "react-native";
import { useI18n } from "../i18n";
import { authHeaders } from "../platform/api";
import { API_URL } from "../platform/config";
import { s } from "./kit";

type PhotoState = "loading" | "ok" | "hidden" | "notBoarding" | "failed";

export function PassengerPhoto({ tripUid, ticketUid }: { tripUid: string; ticketUid: string }) {
  const { t } = useI18n();
  const [headers, setHeaders] = useState<Record<string, string> | null>(null);
  const [state, setState] = useState<PhotoState>("loading");
  const url = `${API_URL}/api/driver/trips/${tripUid}/tickets/${ticketUid}/photo`;
  useEffect(() => {
    let cancelled = false;
    setState("loading");
    // the answer says why there is no photo: not in use (hidden), not boarding yet, or none on file (failed)
    void authHeaders().then(async (h) => {
      if (cancelled) return;
      setHeaders(h);
      const r = await fetch(url, { headers: h });
      if (cancelled) return;
      if (r.ok) return setState("ok");
      const body = await r.json().catch(() => null) as { error?: { code?: string } } | null;
      const code = body?.error?.code;
      setState(code === "PHOTO_DISABLED" ? "hidden" : code === "NOT_BOARDING" ? "notBoarding" : "failed");
    });
    return () => { cancelled = true; };
  }, [url]);
  if (state === "hidden") return null;
  if (state === "notBoarding") return <Text style={s.small}>{t("driver.photoAtBoarding")}</Text>;
  if (state === "failed") return <Text style={s.small}>{t("driver.noPhoto")}</Text>;
  if (state === "loading" || !headers) return null;
  return (
    <View style={{ gap: 6, alignItems: "center" }}>
      <Text style={s.label}>{t("driver.passengerPhoto")}</Text>
      <Image accessibilityLabel={t("driver.passengerPhoto")} resizeMode="cover" onError={() => setState("failed")}
             source={{ uri: url, headers }}
             style={{ width: 160, height: 200, borderRadius: 12 }} />
    </View>
  );
}
