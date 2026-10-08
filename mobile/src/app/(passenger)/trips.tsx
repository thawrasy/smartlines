import { useEffect } from "react";
import { Pressable, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { getJSON, putJSON } from "../../platform/secure";
import { saveBooking } from "../../platform/tickets";
import { Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../ui/kit";
import { useLoad } from "../../ui/useLoad";

interface Booking { booking_ref: string; status: string; total_amount: number; carrier_name: string; trip_no: string;
  journey: { from_city: string; to_city: string; from_station: string; to_station: string; departs_at: string } | null }

/** Online: the server's list (also kept for offline use). Offline: the last list seen on this phone. */
async function load(): Promise<{ bookings: Booking[]; offline: boolean }> {
  try {
    const r = await api.get<{ bookings: Booking[] }>("/api/bookings");
    await putJSON("bookings", r.bookings);
    return { bookings: r.bookings, offline: false };
  } catch (e) {
    const cached = await getJSON<Booking[]>("bookings");
    if (cached) return { bookings: cached, offline: true };
    throw e;
  }
}

export default function Trips() {
  const { t, money, time, date } = useI18n();
  const list = useLoad(load);
  const now = Date.now();
  const upcoming = (list.data?.bookings ?? []).filter((b) => b.journey && new Date(b.journey.departs_at).getTime() > now - 6 * 3600000);
  const past = (list.data?.bookings ?? []).filter((b) => !upcoming.includes(b));
  useEffect(() => {
    // Save upcoming tickets for offline use while there is a connection.
    if (list.data && !list.data.offline) for (const b of upcoming) if (b.status === "CONFIRMED") void saveBooking(b.booking_ref).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [list.data]);
  const row = (b: Booking) => (
    <Pressable key={b.booking_ref} accessibilityRole="button" onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: b.booking_ref } })}>
      <Card>
        <View style={s.between}>
          <Text style={s.h2}>{b.journey ? `${t(`city.${b.journey.from_city}`)} → ${t(`city.${b.journey.to_city}`)}` : b.trip_no}</Text>
          <Chip tone={b.status === "CONFIRMED" ? "green" : b.status === "PENDING_PAYMENT" ? "amber" : "neutral"} label={b.booking_ref} />
        </View>
        {b.status !== "CONFIRMED" ? <Text style={s.small}>{t(`status.${b.status}`)}</Text> : null}
        {b.journey ? <Text style={s.muted}>{date(b.journey.departs_at)} · {time(b.journey.departs_at)} · {b.journey.from_station}</Text> : null}
        <Text style={s.small}>{b.carrier_name} · {money(b.total_amount)}</Text>
      </Card>
    </Pressable>
  );
  return (
    <Screen>
      <Title>{t("tabs.trips")}</Title>
      {list.data?.offline ? <Chip tone="amber" label={t("common.offline")} /> : null}
      {list.loading && !list.data ? <Loading /> : <ErrorText error={list.error} />}
      {list.data && list.data.bookings.length === 0 ? <Text style={s.muted}>{t("trips.none")}</Text> : null}
      {upcoming.length ? <Text style={s.h2}>{t("trips.upcoming")}</Text> : null}
      {upcoming.map(row)}
      {past.length ? <Text style={s.h2}>{t("trips.past")}</Text> : null}
      {past.map(row)}
    </Screen>
  );
}
