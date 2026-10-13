import { useState } from "react";
import { Alert, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { getJSON, putJSON } from "../../platform/secure";
import { downloadPack, loadPack, loadScans } from "../../platform/boarding";
import { AccountBody } from "../(passenger)/account";
import { Button, Card, Chip, ErrorText, Loading, Notice, Screen, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";

interface DriverTrip { uid: string; trip_no: string; trip_code?: string | null; status: string; departure_at: string; plate_no: string | null; booked: number; boarded: number;
  stops: { seq: number; station_name: string; city_code: string }[] }
interface Row extends DriverTrip { packTickets: number | null; pending: number }

async function load(): Promise<{ trips: Row[]; offline: boolean }> {
  let trips: DriverTrip[], offline = false;
  try {
    trips = (await api.get<{ trips: DriverTrip[] }>("/api/driver/trips")).trips;
    await putJSON("driver.trips", trips);
  } catch (e) {
    const cached = await getJSON<DriverTrip[]>("driver.trips");
    if (!cached) throw e;
    trips = cached; offline = true;
  }
  const rows: Row[] = [];
  for (const t of trips) {
    const pack = await loadPack(t.uid);
    rows.push({ ...t, packTickets: pack ? pack.tickets.length : null, pending: (await loadScans(t.uid)).filter((x) => !x.synced).length });
  }
  return { trips: rows, offline };
}

export default function DriverHome() {
  const { t, time, date } = useI18n();
  const list = useLoad(load);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [showAccount, setShowAccount] = useState(false);
  const [sosSent, setSosSent] = useState<{ uid: string; repeated: boolean } | null>(null);
  const download = async (uid: string) => {
    setBusy(uid); setError(null);
    try { await downloadPack(uid); list.reload(); } catch (e) { setError(e); } finally { setBusy(null); }
  };
  // the SOS asks once, so a pocket press does not raise the alarm (1101)
  const sos = (uid: string) => Alert.alert(t("sos.confirm"), t("sos.confirmHint"), [
    { text: t("common.cancel"), style: "cancel" },
    { text: t("sos.send"), style: "destructive", onPress: async () => {
      setError(null);
      try {
        const r = await api.post<{ repeated: boolean }>("/api/driver/sos", { trip_uid: uid });
        setSosSent({ uid, repeated: r.repeated });
      } catch (e) { setError(e); }
    } },
  ]);
  if (showAccount) return <Screen><AccountBody /><Button kind="text" label={t("common.back")} onPress={() => setShowAccount(false)} /></Screen>;
  return (
    <Screen>
      <View style={s.between}>
        <Title>{t("driver.today")}</Title>
        <Button kind="text" label={t("tabs.account")} onPress={() => setShowAccount(true)} />
      </View>
      {list.data?.offline ? <Chip tone="amber" label={t("common.offline")} /> : null}
      {list.loading && !list.data ? <Loading /> : <ErrorText error={list.error ?? error} />}
      {list.data && list.data.trips.length === 0 ? <Text style={s.muted}>{t("extra.noTickets")}</Text> : null}
      {list.data?.trips.map((x) => {
        const first = x.stops[0], last = x.stops[x.stops.length - 1];
        return (
          <Card key={x.uid}>
            <View style={s.between}>
              <Text style={s.h2}>{first ? t(`city.${first.city_code}`) : ""} → {last ? t(`city.${last.city_code}`) : ""}</Text>
              <Chip tone="blue" label={x.trip_code ?? x.trip_no} />
            </View>
            <Text style={s.muted}>{date(x.departure_at)} · {time(x.departure_at)} · {x.plate_no ?? ""}</Text>
            <Text style={s.small}>{t("driver.boardedCount", { n: x.boarded, total: x.booked })}</Text>
            {x.packTickets !== null ? <Chip tone="green" label={t("driver.downloaded", { n: x.packTickets })} /> : null}
            {x.pending ? <Chip tone="amber" label={t("driver.pending", { n: x.pending })} /> : null}
            <Button kind="tonal" label={t("driver.download")} busy={busy === x.uid} onPress={() => download(x.uid)} />
            <Button label={t("driver.board")} onPress={() => router.push({ pathname: "/driver/board/[uid]", params: { uid: x.uid } })} />
            {x.status === "BOARDING" || x.status === "DEPARTED" || x.status === "PUBLISHED" ? (
              <>
                <Button kind="tonal" label={t("incident.button")}
                        onPress={() => router.push({ pathname: "/driver/incident/[uid]", params: { uid: x.uid, trip_no: x.trip_no } })} />
                <Button kind="danger" label={t("sos.button")} onPress={() => sos(x.uid)} />
                {sosSent?.uid === x.uid ? <Notice tone="amber" text={t(sosSent.repeated ? "sos.again" : "sos.sent")} /> : null}
              </>
            ) : null}
          </Card>
        );
      })}
    </Screen>
  );
}
