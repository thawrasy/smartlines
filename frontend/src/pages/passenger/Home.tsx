import { useMemo, useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { localDate } from "../../dates";
import { Field, Icon, useLoad } from "../../components/ui";
import type { IconName } from "../../components/icons";
import { useChannel } from "../../channel";
import { useAuth } from "../../auth";
import { MAX_LEGS, legsParam, type JourneyKind, type JourneyLeg } from "./journeyLinks";

interface GeoCity {
  code: string; country_code: string; city_class: "MAIN" | "SECONDARY";
  governorate: string | null; governorate_en: string | null; governorate_ar: string | null;
}

// The cities of the network with their governorate and class (1160, N37): the lists show them by governorate, the main
// cities of each first, so a long list is read from the governorate down
export function useCities() {
  const { city, locale } = useI18n();
  const ref = useLoad(() => api.get<{ cities: GeoCity[] }>("/api/geo/cities"));
  return useMemo(() => (ref.data?.cities ?? [])
    .filter((c) => c.country_code === "SY")
    .map((c) => ({ code: c.code, name: city(c.code), main: c.city_class === "MAIN", governorate: c.governorate ?? "",
                   governorateName: (locale === "ar" ? c.governorate_ar : c.governorate_en) ?? "" }))
    .sort((a, b) => (a.governorate || "~").localeCompare(b.governorate || "~") || Number(b.main) - Number(a.main) || a.name.localeCompare(b.name, locale)),
  [ref.data, city, locale]);
}

/** The options of a city list, grouped by governorate (cities without one last, ungrouped). */
export function CityOptions({ cities }: { cities: ReturnType<typeof useCities> }) {
  const groups = cities.reduce<{ key: string; label: string; items: typeof cities }[]>((acc, c) => {
    const last = acc[acc.length - 1];
    if (last && last.key === c.governorate) last.items.push(c);
    else acc.push({ key: c.governorate, label: c.governorateName, items: [c] });
    return acc;
  }, []);
  return <>{groups.map((g) => g.key
    ? <optgroup key={g.key} label={g.label}>{g.items.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</optgroup>
    : g.items.map((c) => <option key={c.code} value={c.code}>{c.name}</option>))}</>;
}

// The seats one booking holds and the travellers the form takes (1122): the platform's number (four unless it decides
// otherwise, as a regulator may require), the passenger's own when they head a larger family, an agency's group
export function useSeatLimits() {
  const ch = useChannel();
  const { me } = useAuth();
  const passenger = !ch.staff && me?.portal === "PASSENGER";
  const base = useLoad(() => api.get<{ booking?: { max_seats: number; max_adults?: number; max_children?: number } }>("/api/ref")
    .then((r) => r.booking ?? { max_seats: 9 }));
  const own = useLoad(() => (ch.agency ? api.get<{ max_passengers: number }>("/api/agency/journeys/options").then((r) => r.max_passengers)
    : passenger ? api.get<{ max_seats: number }>("/api/bookings/limits").then((r) => r.max_seats) : Promise.resolve(null)), [ch.agency, passenger]);
  const perBooking = base.data?.max_seats ?? 9;
  return { perBooking, maxPax: Math.max(own.data ?? perBooking, 1),
           maxAdults: base.data?.max_adults ?? 4, maxChildren: base.data?.max_children ?? 6 };
}

// Travellers by type and the class (N34): adults, children, infants on a lap (no seat, at most one per adult) and infants
// with a seat; the seats are everyone but the lap infants. The server applies the same platform limits.
export type Cabin = "ANY" | "ECONOMY" | "BUSINESS" | "VIP" | "ACCESSIBLE";
export interface Mix { adults: number; children: number; lap: number; seat: number; cabin: Cabin }
export const mixSeats = (m: Mix) => m.adults + m.children + m.seat;
export function mixParams(m: Mix): string {
  return `&ad=${m.adults}&chd=${m.children}&lap=${m.lap}&inf=${m.seat}${m.cabin !== "ANY" ? `&cab=${m.cabin}` : ""}`;
}
export function mixFrom(params: URLSearchParams, pax: number): Mix {
  const n = (k: string, d: number) => Math.max(0, Number(params.get(k) ?? d) || 0);
  const cabin = (params.get("cab") ?? "ANY") as Cabin;
  return params.has("ad") ? { adults: Math.max(1, n("ad", 1)), children: n("chd", 0), lap: n("lap", 0), seat: n("inf", 0), cabin }
                          : { adults: Math.max(1, pax), children: 0, lap: 0, seat: 0, cabin };
}

function TravellersPicker({ mix, setMix, limits }: { mix: Mix; setMix: (m: Mix) => void;
                                                     limits: { maxSeats: number; maxAdults: number; maxChildren: number } }) {
  const { t } = useI18n();
  const [open, setOpen] = useState(false);
  const seats = mixSeats(mix);
  const max: Record<"adults" | "children" | "lap" | "seat", number> = {
    adults: Math.min(limits.maxAdults, mix.adults + limits.maxSeats - seats),
    children: Math.min(limits.maxChildren, mix.children + limits.maxSeats - seats),
    lap: mix.adults, seat: mix.seat + limits.maxSeats - seats,
  };
  const min = { adults: Math.max(1, mix.lap), children: 0, lap: 0, seat: 0 };
  const kinds: [keyof typeof max, string][] = [["adults", "ADULT"], ["children", "CHILD"], ["lap", "LAP"], ["seat", "SEAT"]];
  const total = mix.adults + mix.children + mix.lap + mix.seat;
  return (
    <Field label={t("home.travellers")}>
      <div className="pax-picker">
        <button type="button" className="input pax-summary" aria-expanded={open} onClick={() => setOpen(!open)}>
          <Icon name="group" size={18} />
          <span>{t("home.travellersOf", { n: total })} · {t(`home.cabin.${mix.cabin}`)}</span>
        </button>
        {open && (
          <div className="pax-panel card" role="group" aria-label={t("home.travellers")}>
            {kinds.map(([key, kind]) => (
              <div key={key} className="pax-row">
                <div><strong>{t(`home.pax.${kind}`)}</strong><div className="small muted">{t(`home.pax.${kind}_AGE`)}</div></div>
                <div className="pax-count">
                  <button type="button" className="btn outlined small" disabled={mix[key] <= min[key]}
                          aria-label={t("home.pax.less", { kind: t(`home.pax.${kind}`) })}
                          onClick={() => setMix({ ...mix, [key]: mix[key] - 1 })}><Icon name="remove" size={18} /></button>
                  <output aria-live="polite">{mix[key]}</output>
                  <button type="button" className="btn outlined small" disabled={mix[key] >= max[key]}
                          aria-label={t("home.pax.more", { kind: t(`home.pax.${kind}`) })}
                          onClick={() => setMix({ ...mix, [key]: mix[key] + 1 })}><Icon name="add" size={18} /></button>
                </div>
              </div>
            ))}
            <label className="stack" style={{ gap: 4 }}>
              <span className="small">{t("home.cabin.label")}</span>
              <select className="input" value={mix.cabin} onChange={(e) => setMix({ ...mix, cabin: e.target.value as Cabin })}>
                {(["ANY", "ECONOMY", "BUSINESS", "VIP", "ACCESSIBLE"] as Cabin[]).map((c) => <option key={c} value={c}>{t(`home.cabin.${c}`)}</option>)}
              </select>
            </label>
            <p className="small muted">{t("home.pax.limits", { adults: limits.maxAdults, children: limits.maxChildren, seats: limits.maxSeats })}</p>
            <button type="button" className="btn small" onClick={() => setOpen(false)}>{t("home.done")}</button>
          </div>
        )}
      </div>
    </Field>
  );
}

export interface SearchInitial { from: string; to: string; on: string; pax: number; kind?: JourneyKind; legs?: JourneyLeg[]; mix?: Mix }

// One way, a round trip, or several places one after the other (owner's request, October 2026; 1121). Passengers book
// up to the platform's seat limit (useSeatLimits); an agency books a group (its setting, 50 by default) and every trip
// of the journey for all of them.
// A carrier's or a station's counter sells single trips.
export function SearchForm({ initial }: { initial?: SearchInitial }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const ch = useChannel();
  const cities = useCities();
  const journeys = !ch.counter;
  const { maxPax, perBooking, maxAdults, maxChildren } = useSeatLimits();
  const [kind, setKind] = useState<JourneyKind>(journeys ? initial?.kind ?? "ONE_WAY" : "ONE_WAY");
  const [from, setFrom] = useState(initial?.from ?? "DAM");
  const [to, setTo] = useState(initial?.to ?? "ALP");
  const [on, setOn] = useState(initial?.on ?? localDate(1));
  const [back, setBack] = useState(initial?.kind === "ROUND_TRIP" && initial.legs?.[1] ? initial.legs[1].on : localDate(3));
  const [legs, setLegs] = useState<JourneyLeg[]>(initial?.kind === "MULTI_CITY" && initial.legs?.length ? initial.legs
    : [{ from: initial?.from ?? "DAM", to: initial?.to ?? "ALP", on: initial?.on ?? localDate(1) }, { from: initial?.to ?? "ALP", to: "", on: localDate(3) }]);
  const [pax, setPax] = useState(initial?.pax ?? 1);
  const [mix, setMix] = useState<Mix>(initial?.mix ?? { adults: Math.max(1, Math.min(initial?.pax ?? 1, maxAdults)), children: 0, lap: 0, seat: 0, cabin: "ANY" });
  // a group (an agency's, or a family head's larger limit) gives a number; a traveller counts by type (N34)
  const byType = !ch.agency && maxPax <= perBooking;
  const seatsWanted = byType ? mixSeats(mix) : pax;
  const extra = byType ? mixParams(mix) : "";
  const multiOk = legs.every((l, i) => l.from && l.to && l.from !== l.to && (i === 0 || l.on >= legs[i - 1].on));
  const ok = kind === "MULTI_CITY" ? multiOk : !!from && !!to && from !== to && (kind !== "ROUND_TRIP" || back >= on);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!ok) return;
    if (kind === "ONE_WAY") nav(ch.link(`/search?from=${from}&to=${to}&on=${on}&pax=${seatsWanted}${extra}`));
    else {
      const chosen = kind === "ROUND_TRIP" ? [{ from, to, on }, { from: to, to: from, on: back }] : legs;
      nav(ch.link(`/search?kind=${kind}&legs=${legsParam(chosen)}&pax=${seatsWanted}${extra}`));
    }
  };
  const select = (value: string, set: (v: string) => void, label?: string) => (
    <select className="input" value={value} onChange={(e) => set(e.target.value)} required aria-label={label}>
      <option value="" disabled>{t("home.selectCity")}</option>
      <CityOptions cities={cities} />
    </select>
  );
  const setLeg = (i: number, patch: Partial<JourneyLeg>) => setLegs((all) => all.map((l, j) => {
    if (j === i) return { ...l, ...patch };
    if (j === i + 1 && patch.to !== undefined && (!l.from || l.from === all[i].to)) return { ...l, from: patch.to };   // the next trip leaves from here
    return l;
  }));
  const passengers = byType ? <TravellersPicker mix={mix} setMix={setMix} limits={{ maxSeats: perBooking, maxAdults, maxChildren }} /> : (
    <Field label={t("home.passengers")}>
      {maxPax > 8 ? (
        <input className="input" type="number" min={1} max={maxPax} value={pax} onChange={(e) => setPax(Math.min(maxPax, Math.max(1, Number(e.target.value) || 1)))} />
      ) : (
        <select className="input" value={pax} onChange={(e) => setPax(Number(e.target.value))}>
          {Array.from({ length: maxPax }, (_, i) => i + 1).map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      )}
    </Field>
  );
  return (
    <form className="stack" onSubmit={submit}>
      {journeys && (
        <div className="segmented search-modes" role="tablist" aria-label={t("home.mode.label")}>
          {(["ONE_WAY", "ROUND_TRIP", "MULTI_CITY"] as JourneyKind[]).map((k) => (
            <button key={k} type="button" role="tab" aria-selected={kind === k} className={kind === k ? "on" : ""} onClick={() => setKind(k)}>
              <Icon name={k === "ONE_WAY" ? "arrow_forward" : k === "ROUND_TRIP" ? "swap_horiz" : "multiple_stop"} size={18} flip={k === "ONE_WAY"} />{t(`home.mode.${k}`)}
            </button>
          ))}
        </div>
      )}
      {kind !== "MULTI_CITY" ? (
        <div className={`search-grid${kind === "ROUND_TRIP" ? " round" : ""}`}>
          <Field label={t("home.origin")}>{select(from, setFrom)}</Field>
          <button type="button" className="swap" title={t("home.swap")} onClick={() => { setFrom(to); setTo(from); }}>
            <Icon name="swap_horiz" />
          </button>
          <Field label={t("home.destination")}>{select(to, setTo)}</Field>
          <Field label={t("home.date")}>
            <input className="input" type="date" value={on} min={localDate(0)} max={localDate(60)} onChange={(e) => { setOn(e.target.value); if (back < e.target.value) setBack(e.target.value); }} required />
          </Field>
          {kind === "ROUND_TRIP" && (
            <Field label={t("home.return")}>
              <input className="input" type="date" value={back} min={on} max={localDate(60)} onChange={(e) => setBack(e.target.value)} required />
            </Field>
          )}
          {passengers}
          <button className="btn large" type="submit" disabled={!ok}><Icon name="search" />{t("home.searchBtn")}</button>
        </div>
      ) : (
        <div className="stack">
          {legs.map((l, i) => (
            <div key={i} className="journey-row">
              <span className="chip blue">{t("jrn.legN", { n: i + 1 })}</span>
              <Field label={t("home.origin")}>{select(l.from, (v) => setLeg(i, { from: v }))}</Field>
              <Field label={t("home.destination")}>{select(l.to, (v) => setLeg(i, { to: v }))}</Field>
              <Field label={t("home.date")}>
                <input className="input" type="date" value={l.on} min={i ? legs[i - 1].on : localDate(0)} max={localDate(60)}
                       onChange={(e) => setLeg(i, { on: e.target.value })} required />
              </Field>
              <button type="button" className="btn text small" disabled={legs.length <= 2} aria-label={t("home.removeLeg", { n: i + 1 })}
                      onClick={() => setLegs((all) => all.filter((_, j) => j !== i))}><Icon name="close" /></button>
            </div>
          ))}
          <div className="row between" style={{ gap: 12, flexWrap: "wrap", alignItems: "flex-end" }}>
            <button type="button" className="btn outlined" disabled={legs.length >= MAX_LEGS}
                    onClick={() => setLegs((all) => [...all, { from: all[all.length - 1].to, to: "", on: all[all.length - 1].on }])}>
              <Icon name="add" />{t("home.addLeg")}</button>
            <div className="row" style={{ gap: 12, alignItems: "flex-end" }}>
              {passengers}
              <button className="btn large" type="submit" disabled={!ok}><Icon name="search" />{t("home.searchBtn")}</button>
            </div>
          </div>
          <p className="small muted" style={{ margin: 0 }}>{t("home.multiHint")}</p>
        </div>
      )}
    </form>
  );
}

export default function Home() {
  const { t } = useI18n();
  const features: [IconName, string, string][] = [["verified", "home.f1t", "home.f1d"], ["shield", "home.f2t", "home.f2d"], ["qr_code_2", "home.f3t", "home.f3d"]];
  // a service shows as available once its module is switched on (sys.setting "features"); intercity travel always is
  const on = useLoad(() => api.get<{ enabled: string[] }>("/api/features"));
  const enabled = new Set(on.data?.enabled ?? []);
  const partners: [IconName, string, boolean][] = [
    ["directions_bus", "home.p1", true], ["local_shipping", "home.p2", enabled.has("cargo") || enabled.has("trip_parcels")],
    ["local_gas_station", "home.p3", enabled.has("service_partners")], ["restaurant", "home.p4", enabled.has("service_partners")],
    ["loyalty", "home.p5", enabled.has("loyalty")], ["support_agent", "home.p6", enabled.has("support_cases")],
  ];
  return (
    <>
      <section className="hero-band">
        <div className="hero-inner stack" style={{ gap: 28 }}>
          <div className="stack" style={{ gap: 14, maxWidth: 720 }}>
            <span className="eyebrow"><Icon name="verified" size={18} />{t("home.eyebrow")}</span>
            <h1 style={{ fontSize: "clamp(30px, 4.4vw, 48px)" }}>{t("home.title")}</h1>
            <p className="muted" style={{ fontSize: 18 }}>{t("home.subtitle")}</p>
          </div>
          <div className="card hero"><SearchForm /></div>
        </div>
      </section>
      <div className="page stack" style={{ gap: 48 }}>
        <div className="grid cols-3">
          {features.map(([icon, title, desc]) => (
            <div key={title} className="feature">
              <span className="badge-ic"><Icon name={icon} /></span>
              <div><h3>{t(title)}</h3><p className="muted" style={{ marginTop: 4 }}>{t(desc)}</p></div>
            </div>
          ))}
        </div>
        <section className="stack">
          <div><h2>{t("home.partnersTitle")}</h2><p className="muted" style={{ marginTop: 4 }}>{t("home.partnersSub")}</p></div>
          <div className="grid cols-3">
            {partners.map(([icon, label, live]) => (
              <div key={label} className="card flat row nowrap" style={{ padding: 18 }}>
                <span className="badge-ic" style={{ width: 44, height: 44, borderRadius: 14, display: "inline-flex", alignItems: "center", justifyContent: "center",
                  background: live ? "var(--primary-container)" : "var(--secondary-soft)", color: live ? "var(--on-primary-container)" : "var(--secondary)" }}>
                  <Icon name={icon} />
                </span>
                <span className="grow" style={{ fontWeight: 500 }}>{t(label)}</span>
                {!live && <span className="chip wheat">{t("home.soon")}</span>}
              </div>
            ))}
          </div>
        </section>
      </div>
    </>
  );
}
