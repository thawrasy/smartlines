import { useMemo, useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { localDate } from "../../dates";
import { Field, Icon, useLoad } from "../../components/ui";
import type { IconName } from "../../components/icons";
import { useChannel } from "../../channel";
import { MAX_LEGS, legsParam, type JourneyKind, type JourneyLeg } from "./journeyLinks";

interface Ref { cities: { code: string; country_code: string }[] }

export function useCities() {
  const { city, locale } = useI18n();
  const ref = useLoad(() => api.get<Ref>("/api/ref"));
  return useMemo(() => (ref.data?.cities ?? [])
    .filter((c) => c.country_code === "SY")
    .map((c) => ({ code: c.code, name: city(c.code) }))
    .sort((a, b) => a.name.localeCompare(b.name, locale)), [ref.data, city, locale]);
}

export interface SearchInitial { from: string; to: string; on: string; pax: number; kind?: JourneyKind; legs?: JourneyLeg[] }

// One way, a round trip, or several places one after the other (owner's request, October 2026; 1121). Passengers book
// up to four seats; an agency books a group (its setting, 50 by default) and every trip of the journey for all of them.
// A carrier's or a station's counter sells single trips.
export function SearchForm({ initial }: { initial?: SearchInitial }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const ch = useChannel();
  const cities = useCities();
  const journeys = !ch.counter;
  const group = useLoad(() => (ch.agency ? api.get<{ max_passengers: number }>("/api/agency/journeys/options").then((r) => r.max_passengers)
    : Promise.resolve(4)), [ch.agency]);
  const maxPax = group.data ?? 4;
  const [kind, setKind] = useState<JourneyKind>(journeys ? initial?.kind ?? "ONE_WAY" : "ONE_WAY");
  const [from, setFrom] = useState(initial?.from ?? "DAM");
  const [to, setTo] = useState(initial?.to ?? "ALP");
  const [on, setOn] = useState(initial?.on ?? localDate(1));
  const [back, setBack] = useState(initial?.kind === "ROUND_TRIP" && initial.legs?.[1] ? initial.legs[1].on : localDate(3));
  const [legs, setLegs] = useState<JourneyLeg[]>(initial?.kind === "MULTI_CITY" && initial.legs?.length ? initial.legs
    : [{ from: initial?.from ?? "DAM", to: initial?.to ?? "ALP", on: initial?.on ?? localDate(1) }, { from: initial?.to ?? "ALP", to: "", on: localDate(3) }]);
  const [pax, setPax] = useState(initial?.pax ?? 1);
  const multiOk = legs.every((l, i) => l.from && l.to && l.from !== l.to && (i === 0 || l.on >= legs[i - 1].on));
  const ok = kind === "MULTI_CITY" ? multiOk : !!from && !!to && from !== to && (kind !== "ROUND_TRIP" || back >= on);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (!ok) return;
    if (kind === "ONE_WAY") nav(ch.link(`/search?from=${from}&to=${to}&on=${on}&pax=${pax}`));
    else {
      const chosen = kind === "ROUND_TRIP" ? [{ from, to, on }, { from: to, to: from, on: back }] : legs;
      nav(ch.link(`/search?kind=${kind}&legs=${legsParam(chosen)}&pax=${pax}`));
    }
  };
  const select = (value: string, set: (v: string) => void, label?: string) => (
    <select className="input" value={value} onChange={(e) => set(e.target.value)} required aria-label={label}>
      <option value="" disabled>{t("home.selectCity")}</option>
      {cities.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
    </select>
  );
  const setLeg = (i: number, patch: Partial<JourneyLeg>) => setLegs((all) => all.map((l, j) => {
    if (j === i) return { ...l, ...patch };
    if (j === i + 1 && patch.to !== undefined && (!l.from || l.from === all[i].to)) return { ...l, from: patch.to };   // the next trip leaves from here
    return l;
  }));
  const passengers = (
    <Field label={t("home.passengers")}>
      {maxPax > 4 ? (
        <input className="input" type="number" min={1} max={maxPax} value={pax} onChange={(e) => setPax(Math.min(maxPax, Math.max(1, Number(e.target.value) || 1)))} />
      ) : (
        <select className="input" value={pax} onChange={(e) => setPax(Number(e.target.value))}>
          {[1, 2, 3, 4].map((n) => <option key={n} value={n}>{n}</option>)}
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
    ["directions_bus", "home.p1", true], ["local_shipping", "home.p2", enabled.has("cargo")],
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
