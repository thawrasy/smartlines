import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, Chip, ErrorText, Loading, Screen, Title, s } from "../../../ui/kit";
import { useLoad } from "../../../ui/useLoad";

interface Ticket { uid: string; ticket_no: string; seat_label: string | null; seat_no: number; status: string; ticket_name: string;
  from_station: string; to_station: string; departs_at: string }

export default function Booking() {
  const { t, money, time, date } = useI18n();
  const { ref } = useLocalSearchParams<{ ref: string }>();
  const b = useLoad(() => api.get<{ booking: { booking_ref: string; total_amount: number; carrier_name: string; trip_no: string }; tickets: Ticket[] }>(`/api/bookings/${ref}`), [ref]);
  if (b.loading) return <Screen><Loading /></Screen>;
  if (!b.data) return <Screen><ErrorText error={b.error} /></Screen>;
  const { booking, tickets } = b.data;
  return (
    <Screen>
      <Title sub={`${booking.carrier_name} · ${money(booking.total_amount)}`}>{t("extra.booked", { ref: booking.booking_ref })}</Title>
      {tickets.map((k) => (
        <Pressable key={k.uid} accessibilityRole="button" onPress={() => router.push({ pathname: "/ticket/[uid]", params: { uid: k.uid } })}>
          <Card>
            <View style={s.between}><Text style={s.h2}>{k.ticket_name}</Text>
              <Chip tone={k.status === "ISSUED" ? "green" : k.status === "BOARDED" ? "blue" : "red"} label={t(`extra.ticketStatus.${k.status}`)} /></View>
            <Text style={s.muted}>{k.from_station} → {k.to_station}</Text>
            <Text style={s.small}>{date(k.departs_at)} · {time(k.departs_at)} · {t("common.seat")} {k.seat_label ?? k.seat_no}</Text>
            <Text style={[s.small, { color: "#0A5BD3" }]}>{t("extra.openTicket")} ›</Text>
          </Card>
        </Pressable>
      ))}
      <Button kind="text" label={t("tabs.trips")} onPress={() => router.replace("/trips")} />
    </Screen>
  );
}
