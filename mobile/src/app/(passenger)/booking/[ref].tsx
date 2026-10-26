import { useEffect, useRef, useState } from "react";
import { Alert, AppState, Pressable, StyleSheet, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { saveBooking } from "../../../platform/tickets";
import { Button, Card, CarrierName, Chip, ErrorText, Loading, Notice, Screen, s } from "../../../ui/kit";
import { Icon, TripLine } from "../../../ui/brand";
import { color, font, radius } from "../../../ui/theme";
import { bookingOptions, openPayment } from "../../../platform/payments";
import { useLoad } from "../../../ui/useLoad";
import { ChangeTripCard } from "../../../ui/connections";

interface Ticket { uid: string; ticket_no: string; seat_label: string | null; seat_no: number; status: string; ticket_name: string;
  from_station: string; to_station: string; departs_at: string; from_city?: string; to_city?: string; arrives_at?: string | null }
interface Detail {
  booking: { booking_ref: string; status: string; total_amount: number; carrier_name: string; carrier_uid?: string | null; carrier_logo?: string | null; trip_no: string; trip_code?: string | null;
             pay_option?: string | null; pay_by?: string | null; return_trip?: Return | null;
             changed_from?: string | null; changed_to?: string | null };   // a booking changed to another trip (1130)
  tickets: Ticket[];
  // the journey the booking belongs to (1121): this trip's leg and the booker's bookings of every leg
  journey?: { uid: string; kind: string; leg: number; bookings: { booking_ref: string; leg: number; status: string; trip_no: string; trip_code: string | null }[] } | null;
}
// the trip that continues the traveller's on the same vehicle that day, and the way back (1119)
interface Return { uid: string; trip_code: string | null; trip_no: string; from_seq: number; to_seq: number; departs_at: string;
  from_station: string; to_station: string; on_sale: boolean; same_vehicle: boolean | null }

export default function Booking() {
  const { t, money, time, date, city } = useI18n();
  const { ref } = useLocalSearchParams<{ ref: string }>();
  const b = useLoad(() => api.get<Detail>(`/api/bookings/${ref}`), [ref]);
  const opts = useLoad(bookingOptions);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const status = b.data?.booking.status;
  const wasPending = useRef(false);
  // back from the provider's page in the browser: read the booking again to see whether the payment went through
  useEffect(() => {
    const sub = AppState.addEventListener("change", (st) => { if (st === "active" && status === "PENDING_PAYMENT") b.reload(); });
    return () => sub.remove();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status]);
  useEffect(() => {
    if (status === "PENDING_PAYMENT") wasPending.current = true;
    else if (status === "CONFIRMED" && wasPending.current) {
      wasPending.current = false;
      setNotice(t("opt.paymentDone"));
      void saveBooking(String(ref)).catch(() => {});              // the tickets now work offline too
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status]);

  if (b.loading && !b.data) return <Screen><Loading /></Screen>;
  if (!b.data) return <Screen><ErrorText error={b.error} /></Screen>;
  const { booking, tickets } = b.data;
  const reserved = booking.status === "PENDING_PAYMENT";
  const when = booking.pay_by ? `${date(booking.pay_by)} ${time(booking.pay_by)}` : "";
  const atCounter = booking.pay_option === "PAY_LATER";
  const provider = opts.data?.find((o) => o.code === booking.pay_option)?.providers?.[0];

  const run = async (fn: () => Promise<void>) => {
    setBusy(true); setError(null);
    try { await fn(); } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const payNow = () => run(async () => { if (provider) await openPayment(booking.booking_ref, provider.code, randomUUID()); });
  const cancel = () => Alert.alert(t("opt.cancelReservationConfirm"), "", [
    { text: t("common.back"), style: "cancel" },
    { text: t("opt.cancelReservation"), style: "destructive", onPress: () => run(async () => {
      await api.post(`/api/bookings/${booking.booking_ref}/cancel`);
      setNotice(t("opt.reservationCancelled"));
      b.reload();
    }) },
  ]);
  const first = tickets[0];
  const ticketTone = (st: string) => (st === "ISSUED" ? "green" : st === "BOARDED" ? "blue" : st === "HOLD" ? "amber" : "red");

  return (
    <Screen>
      <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel={t("common.back")} hitSlop={12} style={{ alignSelf: "flex-start" }}>
        <Icon name="back" size={26} tint={color.primary} mirror />
      </Pressable>
      {/* the booking at a glance, in the pass's colours: the reference, the route on the trip line, the date and the total */}
      <View style={bs.head}>
        <View style={s.between}>
          <Text style={bs.ref}>{booking.booking_ref}</Text>
          <Chip tone={booking.status === "CONFIRMED" ? "green" : booking.status === "PENDING_PAYMENT" ? "amber" : "neutral"} label={t(`status.${booking.status}`)} />
        </View>
        {first?.from_city && first.to_city ? (
          <View style={s.between}>
            <View style={bs.end}><Text style={bs.city}>{city(first.from_city)}</Text><Text style={bs.time}>{time(first.departs_at)}</Text></View>
            <TripLine width={90} height={18} dark />
            <View style={bs.end}><Text style={bs.city}>{city(first.to_city)}</Text>{first.arrives_at ? <Text style={bs.time}>{time(first.arrives_at)}</Text> : null}</View>
          </View>
        ) : null}
        <View style={[s.between, bs.foot]}>
          <Text style={bs.meta}>{first ? date(first.departs_at) : ""} · {booking.trip_code ?? booking.trip_no}</Text>
          <Text style={bs.total}>{money(booking.total_amount)}</Text>
        </View>
      </View>
      <CarrierName name={booking.carrier_name} uid={booking.carrier_uid} logo={booking.carrier_logo} style={s.muted} />
      {notice ? <Notice tone="green" text={notice} /> : null}
      <ErrorText error={error} />
      {booking.status === "EXPIRED" ? <Notice tone="amber" text={t("opt.expired")} /> : null}
      {booking.changed_from ? <Button kind="text" label={`${t("conn.changedFrom")} ${booking.changed_from}`}
                                      onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: booking.changed_from! } })} /> : null}
      {booking.changed_to ? <Button kind="tonal" label={`${t("conn.changedTo")} ${booking.changed_to}`}
                                    onPress={() => router.replace({ pathname: "/booking/[ref]", params: { ref: booking.changed_to! } })} /> : null}
      {b.data.journey?.kind === "CONNECTION" && booking.status === "CONFIRMED" ? <Notice tone="amber" text={t("conn.bookingNote")} /> : null}
      {reserved ? (
        <Card>
          <Text style={s.h2}>{t("opt.reserved")}</Text>
          <Text style={s.muted}>
            {atCounter ? t("opt.payAtCounter", { amount: money(booking.total_amount), carrier: booking.carrier_name, time: when, ref: booking.booking_ref })
                       : t("opt.payOnline", { time: when })}
          </Text>
          {!atCounter && provider ? <Button label={t("opt.payNow")} busy={busy} onPress={payNow} /> : null}
          <Button kind="danger" label={t("opt.cancelReservation")} disabled={busy} onPress={cancel} />
        </Card>
      ) : null}
      {tickets.map((k) => (
        <Pressable key={k.uid} accessibilityRole="button" disabled={k.status === "HOLD"}
                   onPress={() => router.push({ pathname: "/ticket/[uid]", params: { uid: k.uid } })}>
          <Card style={{ flexDirection: "row", alignItems: "center", gap: 12 }}>
            <View style={bs.seat}><Text style={bs.seatText}>{k.seat_label ?? k.seat_no ?? "—"}</Text></View>
            <View style={{ flex: 1, gap: 2 }}>
              <Text style={s.h2} numberOfLines={1}>{k.ticket_name}</Text>
              <Text style={s.small} numberOfLines={1}>{k.from_station} · {k.to_station}</Text>
              {k.status === "HOLD" ? <Text style={s.small}>{t("opt.notBoardable")}</Text>
                                   : <Text style={[s.small, { color: color.primary, fontFamily: font.semibold }]}>{t("extra.openTicket")}</Text>}
            </View>
            <Chip tone={ticketTone(k.status)} label={t(`extra.ticketStatus.${k.status}`)} />
          </Card>
        </Pressable>
      ))}
      {b.data.journey ? (
        <Card>
          <Text style={s.h2}>{t("jrn.partOf")}</Text>
          <Text style={s.small}>{t("jrn.partOfHint", { leg: b.data.journey.leg })}</Text>
          {b.data.journey.bookings.filter((x) => x.booking_ref !== booking.booking_ref).map((x) => (
            <Button key={x.booking_ref} kind="tonal" label={`${t("jrn.legN", { n: x.leg })} · ${x.trip_code ?? x.trip_no} · ${x.booking_ref}`}
                    onPress={() => router.push({ pathname: "/booking/[ref]", params: { ref: x.booking_ref } })} />
          ))}
        </Card>
      ) : null}
      {booking.return_trip ? (
        <Card>
          <Text style={s.h2}>{t(booking.return_trip.same_vehicle === false ? "ret.other" : "ret.title")}</Text>
          <Text style={s.muted}>{booking.return_trip.trip_code ?? booking.return_trip.trip_no} · {date(booking.return_trip.departs_at)} · {time(booking.return_trip.departs_at)}</Text>
          <Text style={s.muted}>{booking.return_trip.from_station} → {booking.return_trip.to_station}</Text>
          {booking.return_trip.same_vehicle !== false ? <Text style={s.small}>{t("ret.planned")}</Text> : null}
          {booking.return_trip.on_sale ? (
            <Button kind="tonal" label={t("ret.book")} onPress={() => router.push({ pathname: "/trip/[uid]", params: {
              uid: booking.return_trip!.uid, from_seq: String(booking.return_trip!.from_seq), to_seq: String(booking.return_trip!.to_seq),
              passengers: String(Math.max(1, tickets.filter((k) => k.seat_no !== null).length)) } })} />
          ) : null}
        </Card>
      ) : null}
      {booking.status === "CONFIRMED" && tickets.every((k) => k.status === "ISSUED") ? <ChangeTripCard bookingRef={booking.booking_ref} /> : null}
      <Button kind="text" label={t("tabs.trips")} onPress={() => router.replace("/trips")} />
    </Screen>
  );
}

const bs = StyleSheet.create({
  head: { backgroundColor: color.navy, borderRadius: radius.lg, padding: 18, gap: 14 },
  ref: { fontFamily: font.mono, fontSize: 18, color: "#fff", letterSpacing: 1.5 },
  end: { alignItems: "center", flexShrink: 1 },
  city: { fontFamily: font.displayBold, fontSize: 24, color: "#fff" },
  time: { fontFamily: font.display, fontSize: 15, color: "#B8C2CF" },
  foot: { borderTopWidth: 1, borderColor: "#1E3A5F", paddingTop: 12 },
  meta: { fontFamily: font.body, fontSize: 14, color: "#B8C2CF" },
  total: { fontFamily: font.displayBold, fontSize: 20, color: "#fff" },
  seat: { width: 52, height: 52, borderRadius: radius.sm, backgroundColor: color.greenSoft, alignItems: "center", justifyContent: "center" },
  seatText: { fontFamily: font.displayBold, fontSize: 18, color: "#00391F" },
});
