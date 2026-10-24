// The driver reports an incident on the trip's vehicle (1101). A severe one takes the vehicle out of service at once;
// the carrier and, for a severe incident or injuries, the platform are told.
import { useState } from "react";
import { Text } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Choice, ErrorText, Field, Notice, Screen, Title, s } from "../../../ui/kit";

const TYPES = ["COLLISION", "BREAKDOWN", "FIRE", "SECURITY", "SEIZURE", "MEDICAL", "OTHER"] as const;
const SEVERITIES = ["MINOR", "MAJOR", "SEVERE"] as const;

export default function ReportIncident() {
  const { t } = useI18n();
  const { uid, trip_no } = useLocalSearchParams<{ uid: string; trip_no?: string }>();
  const [type, setType] = useState<(typeof TYPES)[number] | null>(null);
  const [severity, setSeverity] = useState<(typeof SEVERITIES)[number] | null>(null);
  const [injuries, setInjuries] = useState<"yes" | "no">("no");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [done, setDone] = useState<{ vehicle_out_of_service: boolean } | null>(null);
  const send = async () => {
    if (!type || !severity) return;
    setBusy(true); setError(null);
    try {
      setDone(await api.post<{ vehicle_out_of_service: boolean }>("/api/driver/incidents", {
        trip_uid: uid, type, severity, injuries: injuries === "yes", description: description.trim() || null }));
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Screen>
      <Title sub={trip_no ? t("extra.trip", { no: trip_no }) : undefined}>{t("incident.title")}</Title>
      {done ? (
        <Card>
          <Notice tone="green" text={t("incident.sent")} />
          {done.vehicle_out_of_service ? <Notice tone="amber" text={t("incident.outOfService")} /> : null}
        </Card>
      ) : (
        <Card>
          <Choice label={t("incident.type")} options={TYPES.map((v) => ({ value: v, label: t(`incident.types.${v}`) }))} value={type} onChange={setType} />
          <Choice label={t("incident.severity")} options={SEVERITIES.map((v) => ({ value: v, label: t(`incident.severities.${v}`) }))}
                  value={severity} onChange={setSeverity} />
          <Choice label={t("incident.injuries")} options={[{ value: "no", label: t("common.no") }, { value: "yes", label: t("common.yes") }]}
                  value={injuries} onChange={setInjuries} />
          <Field label={t("incident.description")} value={description} onChangeText={setDescription} multiline maxLength={2000} />
          <Text style={s.small}>{t("incident.hint")}</Text>
          <ErrorText error={error} />
          <Button label={t("incident.send")} busy={busy} disabled={!type || !severity} onPress={send} />
        </Card>
      )}
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
    </Screen>
  );
}
