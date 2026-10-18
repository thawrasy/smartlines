import { useEffect, useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { router } from "expo-router";
import { useI18n } from "../../i18n";
import { api } from "../../platform/api";
import { getJSON, putJSON } from "../../platform/secure";
import { saveBooking } from "../../platform/tickets";
import { Card, CarrierName, Chip, ErrorText, Loading, Screen, Tabs, Title, s } from "../../ui/kit";
import { TripLine } from "../../ui/brand";
import { color, font } from "../../ui/theme";
import { useLoad } from "../../ui/useLoad";

interface Booking { booking_ref: string; status: string; total_amount: number; carrier_name: string; carrier_uid?: string | null; carrier_logo?: string | null; trip_no: string; trip_code?: string | null;
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
  const { t, money, time, date, city } = useI18n();
  const list = useLoad(load);
  const [tab, setTab] = useState<"upcoming" | "past">("upcoming");
  const now = Date.now();
  const upcoming = (list.data?.bookings ?? []).filter((b) => b.journey && new Date(b.journey.departs_at).getTime() > now - 6 * 3600000);
  const past = (list.data?.bookings ?? []).filter((b) => !upcoming.includes(b));
  useEffect(() => {
    // Save upcoming tickets for offline use while there is a connection.
    if (list.data && !list.data.offline) for (const b of upcoming) if (b.status === "CONFIRMED") void saveBooking(b.booking_ref).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [list.data]);
  // each trip as a small pass: the date and status, the two cities joined by the trip line, the carrier and the reference
  const row = (b: Booking) => (
    <Pressable key={b.booking_ref} accessibilityRole="button" onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: b.booking_ref } })}>
      <Card>
        <View style={s.between}>
          <Text style={s.small}>{b.journey ? `${date(b.journey.departs_at)} · ${time(b.journey.departs_at)}` : ""}</Text>
          <Chip tone={b.status === "CONFIRMED" ? "green" : b.status === "PENDING_PAYMENT" ? "amber" : "neutral"} label={t(`status.${b.status}`)} />
        </View>
        {b.journey ? (
          <View style={s.between}>
            <Text style={ts.city} numberOfLines={1}>{city(b.journey.from_city)}</Text>
            <TripLine width={90} height={16} />
            <Text style={ts.city} numberOfLines={1}>{city(b.journey.to_city)}</Text>
          </View>
        ) : <Text style={ts.city}>{b.trip_code ?? b.trip_no}</Text>}
        <View style={[s.between, ts.foot]}>
          <CarrierName name={b.carrier_name} uid={b.carrier_uid} logo={b.carrier_logo} />
          <Text style={ts.ref}>{b.booking_ref}</Text>
        </View>
        <View style={s.between}>
          <Text style={s.small}>{b.journey?.from_station ?? ""}</Text>
          <Text style={ts.price}>{money(b.total_amount)}</Text>
        </View>
      </Card>
    </Pressable>
  );
  return (
    <Screen>
      <Title>{t("tabs.trips")}</Title>
      {list.data?.offline ? <Chip tone="amber" label={t("common.offline")} /> : null}
      {list.loading && !list.data ? <Loading /> : <ErrorText error={list.error} />}
      {list.data && list.data.bookings.length === 0 ? <Text style={s.muted}>{t("trips.none")}</Text> : null}
      <Tabs items={[{ key: "upcoming", label: t("trips.upcoming") }, { key: "past", label: t("trips.past") }]} value={tab} onChange={setTab} />
      {(tab === "upcoming" ? upcoming : past).map(row)}
      {list.data && list.data.bookings.length > 0 && (tab === "upcoming" ? upcoming : past).length === 0 ? <Text style={s.muted}>{t("trips.none")}</Text> : null}
    </Screen>
  );
}

const ts = StyleSheet.create({
  city: { fontFamily: font.displayBold, fontSize: 22, color: color.navy, flexShrink: 1 },
  foot: { borderTopWidth: 1, borderColor: color.outline, paddingTop: 10 },
  ref: { fontFamily: font.mono, fontSize: 14, color: color.muted, letterSpacing: 1 },
  price: { fontFamily: font.display, fontSize: 16, color: color.primary },
});
