import { useEffect, useMemo, useRef, useState } from "react";
import { Pressable, Text, View } from "react-native";
import { router, useLocalSearchParams } from "expo-router";
import { randomUUID } from "expo-crypto";
import { useI18n } from "../../../i18n";
import { api } from "../../../platform/api";
import { bookingOptions, openPayment, usable as offered, type BookingOption, type PayWith } from "../../../platform/payments";
import { saveBooking } from "../../../platform/tickets";
import { Button, Card, Choice, ErrorText, Field, Loading, Notice, Screen, Title, s } from "../../../ui/kit";
import { SeatMap, type SeatMapData } from "../../../ui/SeatMap";
import { color } from "../../../ui/theme";
import { useLoad } from "../../../ui/useLoad";

interface Detail {
  seat_map: SeatMapData | null; price: number; from_seq: number; to_seq: number; seats: { seat_no: number; free: boolean }[];
  trip: { trip_no: string; carrier_name: string; currency: string; hold_min: number; departs_at?: string; trip_type?: string };
  categories?: Band[]; family_offers?: { code: string; name: string; min_members: number; discount_type: string; discount_value: number }[];
  stops: { seq: number; station_name: string; sched_dep: string | null; sched_arr: string | null }[];
}
type Category = "ADULT" | "CHILD" | "INFANT";
interface Band { category: Category; min_age: number; max_age: number | null; seat_required: boolean; needs_adult: boolean; fare: number }
interface Member { uid: string; relation: string; first_name: string; father_name: string | null; grandfather_name: string | null;
                   last_name: string; full_name: string; nationality: string; birth_date: string; id_type: string | null; id_last4: string | null }
interface Fam { role: "HEAD" | "MEMBER" | null; members?: Member[]; me?: Member; account?: { balance: number } }
interface Quote { total: number; lines: { passenger: number; category: Category; seat: boolean; fare: number }[];
                  family_offer?: { name: string; discount: number } }
interface Names {
  birth_date: string; member_uid: string | null;
  syrian: boolean; country: string; first_name: string; father_name: string; grandfather_name: string; last_name: string;
  id_type: string; id_no: string; passport_expiry: string;           // international trips
}
const blank: Names = { birth_date: "", member_uid: null, syrian: true, country: "", first_name: "", father_name: "", grandfather_name: "", last_name: "",
                       id_type: "PASSPORT", id_no: "", passport_expiry: "" };
// What a nationality needs on this segment: a passport on international trips unless an approved exception applies
interface Docs { international: boolean; docs: string[]; passport_min_days: number; exception: boolean; notes: string[]; departs: string }
const minExpiry = (d: Docs) => { const x = new Date(`${d.departs}T12:00:00Z`); x.setUTCDate(x.getUTCDate() + d.passport_min_days); return x.toISOString().slice(0, 10); };
const docOk = (x: Names, d?: Docs) => !d?.international || (d.docs.includes(x.id_type) && /^[0-9A-Za-z \-/]{4,24}$/.test(x.id_no.trim())
  && (x.id_type !== "PASSPORT" || (/^\d{4}-\d{2}-\d{2}$/.test(x.passport_expiry) && x.passport_expiry >= minExpiry(d))));

const ageOn = (birth: string, on: Date) => {
  const b = new Date(`${birth}T12:00:00Z`);
  let a = on.getUTCFullYear() - b.getUTCFullYear();
  if (on.getUTCMonth() < b.getUTCMonth() || (on.getUTCMonth() === b.getUTCMonth() && on.getUTCDate() < b.getUTCDate())) a -= 1;
  return a;
};
/** The fare category a date of birth gives on the travel day, by the carrier's age bands (4.19). */
const categoryOf = (bands: Band[], birth: string, on: Date): Category | null => {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(birth) || Number.isNaN(Date.parse(birth))) return null;
  const a = ageOn(birth, on);
  if (a < 0) return null;
  return bands.find((b) => a >= b.min_age && (b.max_age == null || a < b.max_age))?.category ?? "ADULT";
};
const fromMember = (m: Member): Names => ({
  ...blank, member_uid: m.uid, birth_date: m.birth_date, syrian: m.nationality === "SY", country: m.nationality === "SY" ? "" : m.nationality,
  first_name: m.first_name, father_name: m.father_name ?? "", grandfather_name: m.grandfather_name ?? "", last_name: m.last_name,
});

export default function Trip() {
  const { t, money, time } = useI18n();
  const p = useLocalSearchParams<{ uid: string; from_seq: string; to_seq: string; passengers: string }>();
  const max = Number(p.passengers) || 1;
  const detail = useLoad(() => api.get<Detail>(`/api/trips/${p.uid}?from_seq=${p.from_seq}&to_seq=${p.to_seq}`), [p.uid, p.from_seq, p.to_seq]);
  const wallet = useLoad(() => api.get<{ balance: number }>("/api/wallet"));
  const opts = useLoad(bookingOptions);
  const [payWith, setPayWith] = useState<PayWith | null>(null);
  const ref = useLoad(() => api.get<{ countries: string[] }>("/api/ref"));
  const [selected, setSelected] = useState<number[]>([]);
  const [hold, setHold] = useState<{ hold_token: string; expires_at: string } | null>(null);
  const [names, setNames] = useState<Record<string, Names>>({});
  const [laps, setLaps] = useState(0);                 // infants on an adult's lap: no seat
  const [payFrom, setPayFrom] = useState<"WALLET" | "FAMILY_ACCOUNT">("WALLET");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoteError, setQuoteError] = useState<unknown>(null);
  const fam = useLoad(() => api.get<Fam>("/api/family").catch(() => ({ role: null }) as Fam));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const idem = useRef(randomUUID());
  const [docs, setDocs] = useState<Record<string, Docs>>({});
  const nat = (x?: Names) => (!x || x.syrian ? "SY" : x.country);
  const nats = [...new Set(["SY", ...Object.values(names).map(nat)])].filter((c) => /^[A-Z]{2}$/.test(c));
  useEffect(() => {
    nats.filter((c) => !(c in docs)).forEach((c) => {
      api.get<Docs>(`/api/trips/${p.uid}/documents?from_seq=${p.from_seq}&to_seq=${p.to_seq}&nationality=${c}`)
        .then((r) => setDocs((cur) => ({ ...cur, [c]: r }))).catch(() => {});
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nats.join(","), p.uid]);
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const id = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(id); }, []);

  const free = useMemo(() => new Map((detail.data?.seats ?? []).map((x) => [x.seat_no, x.free])), [detail.data]);
  // Trips created before seat layouts existed have no map: draw a plain 2+2 coach from the seat numbers, as the website does
  const seatMap = useMemo<SeatMapData | null>(() => {
    const d = detail.data;
    if (!d) return null;
    if (d.seat_map) return d.seat_map;
    const rows = Math.ceil(d.seats.length / 4);
    return { decks: [Array.from({ length: rows }, () => "SS_SS")],
             seats: d.seats.map((x, i) => ({ n: x.seat_no, label: String(x.seat_no), deck: 1, row: Math.floor(i / 4) + 1, col: [1, 2, 4, 5][i % 4], cabin: "STANDARD" })) };
  }, [detail.data]);
  const label = (n: number) => seatMap?.seats.find((x) => x.n === n)?.label ?? String(n);
  const left = hold ? Math.max(0, Math.round((new Date(hold.expires_at).getTime() - now) / 1000)) : 0;
  const countries = new Set(ref.data?.countries ?? []);
  const complete = (x?: Names) => !!x && !!x.first_name.trim() && !!x.last_name.trim()
    && (x.syrian ? !!x.father_name.trim() && !!x.grandfather_name.trim() : countries.has(x.country) && x.country !== "SY")
    && (!!x.member_uid || docOk(x, docs[nat(x)]));            // a family member's stored document is used when none is typed

  const bands = detail.data?.categories ?? [];
  const lapAllowed = bands.some((b) => b.category === "INFANT" && !b.seat_required);
  const travel = new Date(detail.data?.stops.find((x) => x.seq === detail.data?.from_seq)?.sched_dep ?? Date.now());
  const keys = [...selected.map((n) => `s${n}`), ...Array.from({ length: laps }, (_, i) => `l${i}`)];
  const register = fam.data?.role === "HEAD" ? fam.data.members ?? [] : fam.data?.me ? [fam.data.me] : [];
  const body = (x: Names, seat: number | null) => {
    const d = docs[nat(x)];
    return { seat_no: seat, nationality: x.syrian ? "SY" : x.country, first_name: x.first_name.trim(), last_name: x.last_name.trim(),
             father_name: x.father_name.trim() || null, grandfather_name: x.grandfather_name.trim() || null,
             birth_date: x.birth_date || null, family_member_uid: x.member_uid,
             ...(d?.international && x.id_no.trim() ? { id_type: x.id_type, id_no: x.id_no.trim(), passport_expiry: x.id_type === "PASSPORT" ? x.passport_expiry : null } : {}) };
  };
  const travellers = () => keys.map((k) => body(names[k] ?? blank, k.startsWith("s") ? Number(k.slice(1)) : null));
  const quoteKey = hold ? JSON.stringify([keys.map((k) => [k, names[k]?.birth_date, names[k]?.member_uid]), payFrom]) : "";
  useEffect(() => {
    if (!hold) return;
    const id = setTimeout(() => {
      const ps = keys.map((k) => { const x = names[k] ?? blank;
        return { seat_no: k.startsWith("s") ? Number(k.slice(1)) : null, nationality: x.syrian ? "SY" : x.country || "SY", birth_date: x.birth_date || null, family_member_uid: x.member_uid }; });
      api.post<Quote>("/api/bookings/quote", { trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), passengers: ps, pay_from: payFrom })
        .then((q) => { setQuote(q); setQuoteError(null); }).catch((e) => { setQuote(null); setQuoteError(e); });
    }, 400);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [quoteKey]);

  const doHold = async () => {
    setBusy(true); setError(null);
    try {
      setHold(await api.post("/api/holds", { trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), seat_nos: selected }));
      setNames(Object.fromEntries(selected.map((n) => [`s${n}`, names[`s${n}`] ?? blank])));
    } catch (e) { setError(e); detail.reload(); } finally { setBusy(false); }
  };
  const pay = async () => {
    if (!hold) return;
    setBusy(true); setError(null);
    try {
      const out = await api.post<{ booking_ref: string; status: string }>("/api/bookings", {
        hold_token: hold.hold_token, trip_uid: p.uid, from_seq: Number(p.from_seq), to_seq: Number(p.to_seq), idempotency_key: idem.current,
        passengers: travellers(), pay_from: payFrom, pay_with: payFrom === "FAMILY_ACCOUNT" ? "WALLET" : chosen?.code ?? "WALLET",
      });
      if (out.status === "PENDING_PAYMENT") {
        // card, instalments and financing: the seats are reserved and the passenger goes on to the provider's page;
        // pay later: the booking screen says where and until when to pay
        const provider = chosen?.providers?.[0];
        if (provider) await openPayment(out.booking_ref, provider.code, randomUUID()).catch(() => {});
      } else {
        await saveBooking(out.booking_ref).catch(() => {});
      }
      router.replace({ pathname: "/booking/[ref]", params: { ref: out.booking_ref } });
    } catch (e) { setError(e); } finally { setBusy(false); }
  };

  if (detail.loading) return <Screen><Loading /></Screen>;
  if (!detail.data) return <Screen><ErrorText error={detail.error} /><Button kind="text" label={t("common.back")} onPress={() => router.back()} /></Screen>;
  const d = detail.data;
  const from = d.stops.find((x) => x.seq === d.from_seq), to = d.stops.find((x) => x.seq === d.to_seq);
  const total = quote?.total ?? d.price * selected.length;
  const usable = (o: BookingOption) => offered(o, total, d.trip.trip_type);
  const options = opts.data ?? [];
  const chosen = options.find((o) => o.code === payWith && usable(o)) ?? options.find(usable) ?? null;
  // the family account pays at once, so only the wallet option goes with it
  const familyPays = payFrom === "FAMILY_ACCOUNT";
  const hint = (o: BookingOption) => !usable(o) ? (total < o.min_amount ? t("opt.from", { amount: money(o.min_amount) }) : "")
    : t(`opt.hint.${o.code}`, { h: o.hold_hours ?? 24, m: o.cutoff_minutes ?? 120, provider: o.providers?.[0]?.name ?? "" });
  const payLabel = !chosen || chosen.code === "WALLET" ? t("trip.pay", { amount: money(total) })
    : chosen.code === "PAY_LATER" ? t("opt.reserve") : t("opt.continue", { amount: money(total) });
  const catLabel = (c: Category) => { const b = bands.find((x) => x.category === c);
    return b ? `${t(`pax.cat.${c}`)} · ${t("pax.ages", { from: b.min_age, to: b.max_age ?? "+" })} · ${money(b.fare)}` : t(`pax.cat.${c}`); };
  return (
    <Screen>
      <Title sub={`${d.trip.carrier_name} · ${t("extra.trip", { no: d.trip.trip_no })}`}>
        {from?.station_name} → {to?.station_name}
      </Title>
      <Text style={s.muted}>{from?.sched_dep ? time(from.sched_dep) : ""} → {to?.sched_arr ? time(to.sched_arr) : ""} · {money(d.price)}</Text>
      {bands.length ? <Text style={s.small}>{bands.map((b) => catLabel(b.category)).join("\n")}</Text> : null}
      {(d.family_offers ?? []).map((o) => <Notice key={o.code} tone="green" text={`${o.name} · ${t("pax.familyOfferHint", { n: o.min_members })}`} />)}
      <ErrorText error={error} />
      {!hold ? (
        <>
          <Text style={s.h2}>{t("trip.seats")}</Text>
          <Text style={s.small}>{t("extra.seatsChosen", { n: selected.length, max })}</Text>
          <SeatMap map={seatMap!} free={free} selected={selected} max={max}
                   onToggle={(n) => setSelected((cur) => (cur.includes(n) ? cur.filter((x) => x !== n) : [...cur, n]))} />
          <Button label={t("trip.hold")} busy={busy} disabled={selected.length !== max} onPress={doHold} />
        </>
      ) : (
        <>
          <Text style={[s.small, { color: left < 60 ? color.error : color.muted }]}>
            {t("trip.held", { t: `${Math.floor(left / 60)}:${String(left % 60).padStart(2, "0")}` })}
          </Text>
          <Text style={s.small}>{t("trip.namesHint")}</Text>
          {keys.map((k, i) => {
            const x = names[k] ?? blank;
            const set = (patch: Partial<Names>) => setNames({ ...names, [k]: { ...x, ...patch } });
            const lap = k.startsWith("l");
            const cat = categoryOf(bands, x.birth_date, travel);
            const taken = new Set(keys.filter((o) => o !== k).map((o) => names[o]?.member_uid).filter(Boolean));
            const locked = !!x.member_uid;
            return (
              <Card key={k}>
                <View style={s.between}>
                  <Text style={s.h2}>{t("trip.passenger", { n: i + 1 })} · {lap ? t("pax.lapInfant") : `${t("common.seat")} ${label(Number(k.slice(1)))}`}</Text>
                  {lap && i === keys.length - 1 ? <Button kind="text" label={t("common.remove")} onPress={() => setLaps(laps - 1)} /> : null}
                </View>
                {register.length ? (
                  <Choice label={t("family.pickMember")} value={x.member_uid ?? ""}
                          options={[{ value: "", label: "—" }, ...register.filter((m) => !taken.has(m.uid)).map((m) => ({ value: m.uid, label: m.full_name }))]}
                          onChange={(uid) => { const m = register.find((r) => r.uid === uid); set(m ? fromMember(m) : { ...blank }); }} />
                ) : null}
                {locked ? <Notice text={t("family.fromRegister")} /> : null}
                <Field label={`${t("pax.birthDate")} (${t("pax.birthHint")})`} value={x.birth_date} placeholder="YYYY-MM-DD" maxLength={10} editable={!locked}
                       onChangeText={(v) => set({ birth_date: v.trim() })} />
                <Text style={s.small}>{t("pax.category")}: {cat ? t(`pax.cat.${cat}`) : t("pax.categoryUnknown")}{quote?.lines[i] ? ` · ${money(quote.lines[i].fare)}` : ""}</Text>
                <View style={s.row}>
                  {[true, false].map((sy) => (
                    <Pressable key={String(sy)} onPress={() => set({ syrian: sy })} accessibilityRole="radio" accessibilityState={{ checked: x.syrian === sy }}
                               style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                                        borderColor: x.syrian === sy ? color.primary : color.outline, backgroundColor: x.syrian === sy ? color.primarySoft : color.surface }}>
                      <Text>{t(sy ? "trip.syrian" : "trip.otherNationality")}</Text>
                    </Pressable>
                  ))}
                </View>
                {!x.syrian ? <Field label={t("trip.nationality")} value={x.country} placeholder="LB" maxLength={2} autoCapitalize="characters"
                                    onChangeText={(v) => set({ country: v.toUpperCase().replace(/[^A-Z]/g, "") })} /> : null}
                <Field label={t("trip.first")} value={x.first_name} onChangeText={(v) => set({ first_name: v })} autoComplete="off" editable={!locked} />
                {x.syrian ? <Field label={t("trip.father")} value={x.father_name} onChangeText={(v) => set({ father_name: v })} autoComplete="off" editable={!locked} /> : null}
                {x.syrian ? <Field label={t("trip.grandfather")} value={x.grandfather_name} onChangeText={(v) => set({ grandfather_name: v })} autoComplete="off" editable={!locked} /> : null}
                <Field label={t("trip.last")} value={x.last_name} onChangeText={(v) => set({ last_name: v })} autoComplete="off" editable={!locked} />
                {docs[nat(x)]?.international ? (() => {
                  const d = docs[nat(x)];
                  const type = d.docs.includes(x.id_type) ? x.id_type : d.docs[0];
                  return (
                    <View style={{ gap: 8 }}>
                      <Text style={s.small}>{d.exception ? t("trip.docException", { docs: d.docs.map((k) => t(`trip.docTypes.${k}`)).join(" / ") })
                                                         : t("trip.passportNeeded", { days: d.passport_min_days })}{d.notes.length ? ` ${d.notes.join(" ")}` : ""}</Text>
                      {d.docs.length > 1 ? (
                        <View style={s.row}>{d.docs.map((k) => (
                          <Pressable key={k} onPress={() => set({ id_type: k })} accessibilityRole="radio" accessibilityState={{ checked: type === k }}
                                     style={{ paddingHorizontal: 12, paddingVertical: 8, borderRadius: 999, borderWidth: 1,
                                              borderColor: type === k ? color.primary : color.outline, backgroundColor: type === k ? color.primarySoft : color.surface }}>
                            <Text>{t(`trip.docTypes.${k}`)}</Text>
                          </Pressable>
                        ))}</View>
                      ) : null}
                      <Field label={t("trip.docNumber")} value={x.id_no} onChangeText={(v) => set({ id_no: v, id_type: type })} autoComplete="off" autoCapitalize="characters" />
                      {type === "PASSPORT" ? <Field label={t("trip.passportExpiry", { date: minExpiry(d) })} value={x.passport_expiry} placeholder="YYYY-MM-DD"
                                                    onChangeText={(v) => set({ passport_expiry: v.trim(), id_type: type })} maxLength={10} /> : null}
                    </View>
                  );
                })() : null}
              </Card>
            );
          })}
          {lapAllowed && laps < selected.length ? <Button kind="tonal" label={t("pax.addLapInfant")} onPress={() => setLaps(laps + 1)} /> : null}
          {fam.data?.role === "HEAD" && fam.data.account ? (
            <Choice label={t("family.payFrom")} value={payFrom} onChange={setPayFrom}
                    options={[{ value: "WALLET", label: t("family.funding.OWN") },
                              { value: "FAMILY_ACCOUNT", label: `${t("family.funding.FAMILY_ACCOUNT")} · ${money(fam.data.account.balance)}` }]} />
          ) : null}
          {fam.data?.role === "MEMBER" ? <Notice text={t("family.paidByHead")} /> : null}
          {quote?.family_offer ? <Notice tone="green" text={`${quote.family_offer.name} −${money(quote.family_offer.discount)}`} /> : null}
          <ErrorText error={quoteError} />
          <View style={s.between}><Text style={s.h2}>{t("common.total")}</Text><Text style={s.h2}>{money(total)}</Text></View>
          {opts.data && options.length === 0 ? <Notice tone="amber" text={t("opt.noneOpen")} /> : null}
          {!familyPays && options.length > 1 ? (
            <View style={{ gap: 8 }} accessibilityRole="radiogroup" accessibilityLabel={t("opt.title")}>
              <Text style={s.h2}>{t("opt.title")}</Text>
              {options.map((o) => {
                const on = chosen?.code === o.code, ok = usable(o);
                return (
                  <Pressable key={o.code} disabled={!ok} onPress={() => setPayWith(o.code)} accessibilityRole="radio"
                             accessibilityState={{ checked: on, disabled: !ok }}
                             style={{ padding: 12, borderRadius: 12, borderWidth: 1, opacity: ok ? 1 : 0.55, gap: 4,
                                      borderColor: on ? color.primary : color.outline, backgroundColor: on ? color.primarySoft : color.surface }}>
                    <Text style={s.h2}>{t(`opt.name.${o.code}`)}</Text>
                    {hint(o) ? <Text style={s.small}>{hint(o)}</Text> : null}
                  </Pressable>
                );
              })}
            </View>
          ) : null}
          {wallet.data && payFrom === "WALLET" && (familyPays || (chosen?.code ?? "WALLET") === "WALLET")
            ? <Text style={s.small}>{t("trip.balance", { amount: money(wallet.data.balance) })}</Text> : null}
          <Button label={familyPays ? t("trip.pay", { amount: money(total) }) : payLabel} busy={busy}
                  disabled={left === 0 || !quote || !keys.every((k) => complete(names[k])) || (!!opts.data && !chosen)} onPress={pay} />
        </>
      )}
    </Screen>
  );
}
