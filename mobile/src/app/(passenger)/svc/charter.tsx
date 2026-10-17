import { useRef, useState } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import { router } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n, zone } from "../../../i18n";
import { api } from "../../../platform/api";
import { Button, Card, CarrierName, Chip, ErrorText, Field, Loading, Notice, Screen, Title, s } from "../../../ui/kit";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

// Hiring a bus or a whole trip by special request (owner's request, October 2026; 1123): the carriers' offers open to
// travellers, a request under one of them, the carrier's price, and paying for it from the wallet once accepted.

interface Offer {
  uid: string; kind: "VEHICLE" | "WHOLE_TRIP"; title: string; vehicle_type: string | null; seats: number | null; vehicles: number;
  partial_seats: boolean; min_seats: number | null; price_basis: string; price: number | null; notice_hours: number;
  cancel_before_hours: number; cancel_refund_pct: number; policy: string; carrier_name: string; carrier_uid: string; carrier_logo: string | null;
  deposit_pct?: number; balance_hours?: number;
}
interface Request {
  uid: string; ref: string; kind: string; status: string; price: number | null; estimate: number | null; valid_until: string | null;
  carrier_name: string; from_city: string | null; to_city: string | null; starts_at: string | null; trip_code: string | null;
  trip_no: string | null; trip_departs_at: string | null; seats: number | null; whole: boolean | null; quote_note: string | null;
  terms: { cancel_before_hours: number; cancel_refund_pct: number; deposit_pct?: number };
  balance_due?: number; balance_due_at?: string | null; vehicle_plates?: string[];
}
interface Trip { uid: string; trip_no: string; trip_code?: string | null; carrier_uid?: string; departs_at: string; from_seq: number; to_seq: number; seats_left: number }

const dayIso = (n: number) => new Date(Date.now() + n * 86400000).toLocaleDateString("en-CA", { timeZone: zone() });
const HOURS = ["06", "08", "10", "12", "14", "16", "18", "20"];

function Pills({ items, value, onChange }: { items: { key: string; label: string }[]; value: string; onChange: (k: string) => void }) {
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={{ gap: 8 }}>
      {items.map((i) => (
        <Pressable key={i.key} onPress={() => onChange(i.key)} accessibilityRole="button" accessibilityState={{ selected: value === i.key }}
                   style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                            borderColor: value === i.key ? color.primary : color.outline, backgroundColor: value === i.key ? color.primarySoft : color.surface }}>
          <Text style={{ color: value === i.key ? color.primary : color.text }}>{i.label}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

export default function Charter() {
  const { t, money, date, time } = useI18n();
  const offers = useLoad(() => api.get<{ offers: Offer[] }>("/api/charter/offers").then((r) => r.offers));
  const mine = useLoad(() => api.get<{ requests: Request[] }>("/api/charter/requests").then((r) => r.requests));
  const ref = useLoad(() => api.get<{ cities: { code: string }[] }>("/api/ref"));
  const [asking, setAsking] = useState<Offer | null>(null);
  const [naming, setNaming] = useState<Request | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const act = async (r: Request, what: "accept" | "withdraw" | "cancel" | "balance") => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/charter/requests/${r.uid}/${what}`, what === "cancel" ? { reason: "Cancelled by the traveller" } : undefined);
      mine.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  if (naming) return <Travellers r={naming} onDone={() => setNaming(null)} />;
  if (asking) return <Ask offer={asking} cities={(ref.data?.cities ?? []).map((c) => c.code)} onDone={() => { setAsking(null); mine.reload(); }} />;
  return (
    <Screen>
      <Title sub={t("chr.sub")}>{t("chr.title")}</Title>
      <Button kind="text" label={t("common.back")} onPress={() => router.back()} />
      <ErrorText error={error} />
      <Text style={s.h2}>{t("chr.mine")}</Text>
      {mine.loading && !mine.data ? <Loading /> : null}
      {mine.data && mine.data.length === 0 ? <Text style={s.muted}>{t("chr.noRequests")}</Text> : null}
      {mine.data?.map((r) => (
        <Card key={r.uid}>
          <View style={s.between}><Text style={s.h2}>{r.ref}</Text><Chip tone={r.status === "CONFIRMED" ? "green" : r.status === "QUOTED" ? "blue" : "neutral"} label={t(`chr.status.${r.status}`)} /></View>
          <Text style={s.muted}>{r.carrier_name}</Text>
          <Text style={s.small}>{r.kind === "VEHICLE" ? `${t(`city.${r.from_city}`)} → ${t(`city.${r.to_city}`)} · ${r.starts_at ? `${date(r.starts_at)} ${time(r.starts_at)}` : ""}`
            : `${r.trip_code ?? r.trip_no} · ${r.trip_departs_at ? `${date(r.trip_departs_at)} ${time(r.trip_departs_at)}` : ""} · ${r.whole ? t("chr.wholeTrip") : t("chr.seatsN", { n: r.seats ?? 0 })}`}</Text>
          <Text style={s.h2}>{r.price != null ? money(r.price) : r.estimate != null ? `≈ ${money(r.estimate)}` : t("chr.onRequest")}</Text>
          {r.quote_note ? <Text style={s.small}>{r.quote_note}</Text> : null}
          {r.status === "QUOTED" && r.valid_until ? <Text style={s.small}>{t("chr.validUntil", { at: `${date(r.valid_until)} ${time(r.valid_until)}` })}</Text> : null}
          {r.status === "QUOTED" && r.price != null && (r.terms.deposit_pct ?? 0) > 0
            ? <Text style={s.small}>{t("chr.depositNow", { amount: money(Math.floor(r.price * (r.terms.deposit_pct ?? 0) / 100)), pct: r.terms.deposit_pct ?? 0 })}</Text> : null}
          {r.status === "QUOTED" ? <Button label={t((r.terms.deposit_pct ?? 0) > 0 ? "chr.acceptDeposit" : "chr.acceptPay")} busy={busy} onPress={() => act(r, "accept")} /> : null}
          {r.status === "CONFIRMED" && (r.balance_due ?? 0) > 0 && r.balance_due_at ? (
            <>
              <Text style={s.small}>{t("chr.balanceDue", { amount: money(r.balance_due ?? 0), at: `${date(r.balance_due_at)} ${time(r.balance_due_at)}` })}</Text>
              <Button label={t("chr.payBalance")} busy={busy} onPress={() => act(r, "balance")} />
            </>
          ) : null}
          {r.vehicle_plates && r.vehicle_plates.length > 0 ? <Text style={s.small}>{t("chr.vehiclesNamed", { plates: r.vehicle_plates.join(" · ") })}</Text> : null}
          {["REQUESTED", "QUOTED"].includes(r.status) ? <Button kind="text" label={t("chr.withdraw")} onPress={() => act(r, "withdraw")} /> : null}
          {r.status === "CONFIRMED" ? (
            <>
              <Text style={s.small}>{t("chr.refundRule", { pct: r.terms.cancel_refund_pct, h: r.terms.cancel_before_hours })}</Text>
              {r.kind === "WHOLE_TRIP" ? <Button kind="tonal" label={t("chr.travellers")} onPress={() => setNaming(r)} /> : null}
              <Button kind="danger" label={t("common.cancel")} busy={busy} onPress={() => act(r, "cancel")} />
            </>
          ) : null}
        </Card>
      ))}
      <Text style={s.h2}>{t("chr.offers")}</Text>
      {offers.loading && !offers.data ? <Loading /> : <ErrorText error={offers.error} />}
      {offers.data && offers.data.length === 0 ? <Text style={s.muted}>{t("chr.noOffers")}</Text> : null}
      {offers.data?.map((o) => (
        <Card key={o.uid}>
          <CarrierName name={o.carrier_name} uid={o.carrier_uid} logo={o.carrier_logo} />
          <Text style={s.h2}>{o.title}</Text>
          <View style={s.row}>
            <Chip tone="blue" label={t(`chr.kind.${o.kind}`)} />
            {o.vehicle_type ? <Chip label={`${t(`chr.vehicle.${o.vehicle_type}`)} · ${t("chr.seatsN", { n: o.seats ?? 0 })}`} /> : null}
          </View>
          <Text style={s.small}>{o.price != null ? `${money(o.price)} ${t(`chr.per.${o.price_basis}`)}` : t("chr.onRequest")}</Text>
          <Text style={s.small}>{t("chr.refundRule", { pct: o.cancel_refund_pct, h: o.cancel_before_hours })}</Text>
          {o.deposit_pct ? <Text style={s.small}>{t("chr.depositRule", { pct: o.deposit_pct, h: o.balance_hours ?? 48 })}</Text> : null}
          <Text style={s.small}>{o.policy}</Text>
          <Button kind="tonal" label={t("chr.ask")} onPress={() => setAsking(o)} />
        </Card>
      ))}
    </Screen>
  );
}

function Ask({ offer, cities, onDone }: { offer: Offer; cities: string[]; onDone: () => void }) {
  const { t, money, time } = useI18n();
  const key = useRef(randomUUID().replace(/-/g, ""));
  const first = Math.max(1, Math.ceil(offer.notice_hours / 24));
  const days = Array.from({ length: 21 }, (_, n) => dayIso(n + first)).map((d) => ({ key: d, label: d.slice(5) }));
  const [f, setF] = useState({ from: "DAM", to: "", day: days[0].key, hour: "08", endDay: days[0].key, endHour: "20", passengers: "1",
                               name: "", mobile: "", seats: String(offer.min_seats ?? 1), whole: !offer.partial_seats });
  const [trips, setTrips] = useState<Trip[] | null>(null);
  const [trip, setTrip] = useState<Trip | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const set = (patch: Partial<typeof f>) => setF((x) => ({ ...x, ...patch }));
  const cityPills = cities.map((c) => ({ key: c, label: t(`city.${c}`) }));
  const vehicle = offer.kind === "VEHICLE";
  const starts = new Date(`${f.day}T${f.hour}:00:00`), ends = new Date(`${f.endDay}T${f.endHour}:00:00`);
  const ok = f.name.trim().length >= 2 && /^\+?[0-9]{8,15}$/.test(f.mobile.trim()) && (vehicle
    ? !!f.to && f.from !== f.to && ends > starts && Number(f.passengers) >= 1 : !!trip && (f.whole || Number(f.seats) >= (offer.min_seats ?? 1)));
  const find = async () => {
    setError(null); setTrip(null);
    try {
      const r = await api.get<{ trips: Trip[] }>(`/api/trips/search?origin=${f.from}&destination=${f.to}&on=${f.day}`);
      setTrips(r.trips.filter((x) => x.carrier_uid === offer.carrier_uid));
    } catch (e) { setError(e); }
  };
  const send = async () => {
    setBusy(true); setError(null);
    try {
      const common = { offer_uid: offer.uid, contact_name: f.name.trim(), contact_mobile: f.mobile.trim(), idempotency_key: key.current };
      await api.post("/api/charter/requests", vehicle
        ? { ...common, from_city: f.from, to_city: f.to, starts_at: starts.toISOString(), ends_at: ends.toISOString(), passengers: Number(f.passengers) }
        : { ...common, trip_uid: trip!.uid, from_seq: trip!.from_seq, to_seq: trip!.to_seq, whole: f.whole, seats: f.whole ? undefined : Number(f.seats) });
      onDone();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  return (
    <Screen>
      <Title sub={offer.carrier_name}>{offer.title}</Title>
      <Button kind="text" label={t("common.back")} onPress={onDone} />
      <Card>
        <Text style={s.label}>{t("common.from")}</Text>
        <Pills items={cityPills} value={f.from} onChange={(v) => set({ from: v })} />
        <Text style={s.label}>{t("common.to")}</Text>
        <Pills items={cityPills.filter((c) => c.key !== f.from)} value={f.to} onChange={(v) => set({ to: v })} />
        <Text style={s.label}>{vehicle ? t("chr.starts") : t("common.date")}</Text>
        <Pills items={days} value={f.day} onChange={(v) => set({ day: v, endDay: v > f.endDay ? v : f.endDay })} />
        {vehicle ? (
          <>
            <Pills items={HOURS.map((h) => ({ key: h, label: `${h}:00` }))} value={f.hour} onChange={(v) => set({ hour: v })} />
            <Text style={s.label}>{t("chr.ends")}</Text>
            <Pills items={days.filter((d) => d.key >= f.day)} value={f.endDay} onChange={(v) => set({ endDay: v })} />
            <Pills items={HOURS.map((h) => ({ key: h, label: `${h}:00` }))} value={f.endHour} onChange={(v) => set({ endHour: v })} />
            <Field label={t("common.passengers")} value={f.passengers} keyboardType="number-pad" onChangeText={(v) => set({ passengers: v.replace(/\D/g, "") })} />
          </>
        ) : (
          <>
            <Button kind="tonal" label={t("chr.findTrips")} disabled={!f.to || f.from === f.to} onPress={find} />
            {trips && trips.length === 0 ? <Text style={s.muted}>{t("chr.noTrips")}</Text> : null}
            {trips?.map((x) => (
              <Pressable key={x.uid} onPress={() => setTrip(x)} accessibilityRole="radio" accessibilityState={{ checked: trip?.uid === x.uid }}
                         style={{ padding: 10, borderRadius: 12, borderWidth: 1, borderColor: trip?.uid === x.uid ? color.primary : color.outline }}>
                <Text>{x.trip_code ?? x.trip_no} · {time(x.departs_at)} · {t("chr.seatsN", { n: x.seats_left })}</Text>
              </Pressable>
            ))}
            {trip && offer.partial_seats ? (
              <Pills items={[{ key: "block", label: t("chr.block") }, { key: "whole", label: t("chr.wholeTrip") }]} value={f.whole ? "whole" : "block"}
                     onChange={(v) => set({ whole: v === "whole" })} />
            ) : null}
            {trip && !f.whole ? <Field label={t("chr.seatsAsked", { n: offer.min_seats ?? 1 })} value={f.seats} keyboardType="number-pad"
                                       onChangeText={(v) => set({ seats: v.replace(/\D/g, "") })} /> : null}
          </>
        )}
        <Field label={t("chr.contactName")} value={f.name} onChangeText={(v) => set({ name: v })} />
        <Field label={t("chr.contactMobile")} value={f.mobile} keyboardType="phone-pad" onChangeText={(v) => set({ mobile: v })} />
        {offer.price != null ? <Notice text={`${money(offer.price)} ${t(`chr.per.${offer.price_basis}`)} · ${t("chr.carrierPrices")}`} /> : <Notice text={t("chr.carrierPrices")} />}
        <ErrorText error={error} />
        <Button label={t("chr.send")} busy={busy} disabled={!ok} onPress={send} />
      </Card>
    </Screen>
  );
}


// The travellers on the seats of a trip charter (1126): each name is a ticket of the trip, on its manifest
interface Seat { seat_no: number; ticket_no: string | null; ticket_status: string | null; full_name: string | null }
function Travellers({ r, onDone }: { r: Request; onDone: () => void }) {
  const { t } = useI18n();
  const list = useLoad(() => api.get<{ seats: Seat[]; named: number; booking_ref: string | null }>(`/api/charter/requests/${r.uid}/travellers`));
  const blank = { first_name: "", father_name: "", grandfather_name: "", last_name: "" };
  const [p, setP] = useState(blank);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const add = async () => {
    setBusy(true); setError(null);
    try {
      await api.post(`/api/charter/requests/${r.uid}/travellers`, { travellers: [{ nationality: "SY", ...p }] });
      setP(blank); list.reload();
    } catch (e) { setError(e); } finally { setBusy(false); }
  };
  const remove = async (ticket: string) => {
    setError(null);
    try { await api.del(`/api/charter/requests/${r.uid}/travellers/${ticket}`); list.reload(); } catch (e) { setError(e); }
  };
  const seats = list.data?.seats ?? [];
  return (
    <Screen>
      <Title sub={t("chr.travellersHint")}>{t("chr.travellersOf", { ref: r.ref })}</Title>
      <Button kind="text" label={t("common.back")} onPress={onDone} />
      <ErrorText error={error ?? list.error} />
      {list.loading && !list.data ? <Loading /> : null}
      {list.data ? <Text style={s.muted}>{t("chr.namedOf", { n: list.data.named, of: seats.length })}</Text> : null}
      {seats.map((x) => (
        <Card key={x.seat_no}>
          <View style={s.between}>
            <Text style={s.h2}>{t("chr.seat")} {x.seat_no}</Text>
            {x.ticket_no ? <Text style={s.small}>{x.ticket_no}</Text> : null}
          </View>
          <Text style={x.full_name ? s.h2 : s.muted}>{x.full_name ?? t("chr.unnamed")}</Text>
          {x.ticket_no && x.ticket_status === "ISSUED" ? <Button kind="text" label={t("chr.takeOff")} onPress={() => remove(x.ticket_no!)} /> : null}
        </Card>
      ))}
      {list.data && list.data.named < seats.length ? (
        <Card>
          <Text style={s.h2}>{t("chr.addTraveller")}</Text>
          <Field label={t("chr.firstName")} value={p.first_name} onChangeText={(v) => setP({ ...p, first_name: v })} />
          <Field label={t("chr.fatherName")} value={p.father_name} onChangeText={(v) => setP({ ...p, father_name: v })} />
          <Field label={t("chr.grandfatherName")} value={p.grandfather_name} onChangeText={(v) => setP({ ...p, grandfather_name: v })} />
          <Field label={t("chr.lastName")} value={p.last_name} onChangeText={(v) => setP({ ...p, last_name: v })} />
          <Button label={t("chr.addTraveller")} busy={busy} disabled={!p.first_name.trim() || !p.father_name.trim() || !p.grandfather_name.trim() || !p.last_name.trim()} onPress={add} />
        </Card>
      ) : null}
    </Screen>
  );
}

