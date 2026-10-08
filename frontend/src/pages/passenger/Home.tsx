import { useMemo, useState, type FormEvent } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "../../api";
import { useI18n } from "../../i18n";
import { localDate } from "../../dates";
import { Field, Icon, useLoad } from "../../components/ui";
import type { IconName } from "../../components/icons";
import { useChannel } from "../../channel";

interface Ref { cities: { code: string; country_code: string }[] }

export function useCities() {
  const { city, locale } = useI18n();
  const ref = useLoad(() => api.get<Ref>("/api/ref"));
  return useMemo(() => (ref.data?.cities ?? [])
    .filter((c) => c.country_code === "SY")
    .map((c) => ({ code: c.code, name: city(c.code) }))
    .sort((a, b) => a.name.localeCompare(b.name, locale)), [ref.data, city, locale]);
}

export function SearchForm({ initial }: { initial?: { from: string; to: string; on: string; pax: number } }) {
  const { t } = useI18n();
  const nav = useNavigate();
  const ch = useChannel();
  const cities = useCities();
  const [from, setFrom] = useState(initial?.from ?? "DAM");
  const [to, setTo] = useState(initial?.to ?? "ALP");
  const [on, setOn] = useState(initial?.on ?? localDate(1));
  const [pax, setPax] = useState(initial?.pax ?? 1);
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (from && to && from !== to) nav(ch.link(`/search?from=${from}&to=${to}&on=${on}&pax=${pax}`));
  };
  const select = (value: string, set: (v: string) => void) => (
    <select className="input" value={value} onChange={(e) => set(e.target.value)} required>
      <option value="" disabled>{t("home.selectCity")}</option>
      {cities.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}
    </select>
  );
  return (
    <form className="search-grid" onSubmit={submit}>
      <Field label={t("home.origin")}>{select(from, setFrom)}</Field>
      <button type="button" className="swap" title={t("home.swap")} onClick={() => { setFrom(to); setTo(from); }}>
        <Icon name="swap_horiz" />
      </button>
      <Field label={t("home.destination")}>{select(to, setTo)}</Field>
      <Field label={t("home.date")}>
        <input className="input" type="date" value={on} min={localDate(0)} max={localDate(60)} onChange={(e) => setOn(e.target.value)} required />
      </Field>
      <Field label={t("home.passengers")}>
        <select className="input" value={pax} onChange={(e) => setPax(Number(e.target.value))}>
          {[1, 2, 3, 4].map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      </Field>
      <button className="btn large" type="submit" disabled={from === to}><Icon name="search" />{t("home.searchBtn")}</button>
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
