// Interface language. English is the default; Arabic switches the layout to right-to-left (applied by the
// platform on the next start). Code and data stay English; wording lives only in the locale files.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { I18nManager } from "react-native";
import { getLocales } from "expo-localization";
import en, { type Messages } from "./en";
import ar from "./ar";
import { get, put } from "../platform/secure";
import { api } from "../platform/api";

export const LOCALES = { en: { messages: en, rtl: false, intl: "en-GB" }, ar: { messages: ar, rtl: true, intl: "ar-SY-u-nu-latn" } } as const;
export type Locale = keyof typeof LOCALES;

type Vars = Record<string, string | number>;

// The market whose time and money the screens show (1061): the user's, from GET /api/auth/me; until then the
// platform's first market. Kept on the phone so offline screens show the same.
// minor_unit: the scale amounts travel in; decimals: the places people see and pay in. The new Syrian pound (1 January 2026,
// two zeros removed) counts ten-thousandths of a pound and shows two decimals (1176).
export interface Market { country: string; time_zone: string; currency: string; locale: string; minor_unit: number; decimals?: number }
const FIRST_MARKET: Market = { country: "SY", time_zone: "Asia/Damascus", currency: "SYP", locale: "ar", minor_unit: 4, decimals: 2 };
let currentZone = FIRST_MARKET.time_zone;
let currentScale: [number, number] = [FIRST_MARKET.minor_unit, FIRST_MARKET.decimals ?? 2];
/** An amount people typed in whole units of the market's currency as the minor units it travels in. */
export const toMinor = (value: string | number) => Math.round(Number(value || 0) * 10 ** currentScale[0]);
/** Minor units as the whole-unit number a field shows, rounded to the decimals people pay in. */
export const fromMinor = (minor: number) => Math.round(minor / 10 ** (currentScale[0] - currentScale[1])) / 10 ** currentScale[1];
/** The market's time zone, for code outside React (calendar days of the search). */
export const zone = () => currentZone;

function lookup(m: Messages, key: string): string | undefined {
  let node: unknown = m;
  for (const part of key.split(".")) {
    if (node && typeof node === "object" && part in (node as Record<string, unknown>)) node = (node as Record<string, unknown>)[part];
    else return undefined;
  }
  return typeof node === "string" ? node : undefined;
}

interface I18n {
  locale: Locale; rtl: boolean; setLocale: (l: Locale) => Promise<boolean>;
  t: (key: string, vars?: Vars) => string; has: (key: string) => boolean; time: (iso: string) => string;
  /** Minor units as money of the user's market, or of the currency given (a booking's own). */
  money: (minor: number, currency?: string) => string;
  market: Market; setMarket: (m: Market) => void;
  date: (iso: string) => string; dateTime: (iso: string) => string; city: (code: string) => string;
  /** Station names are stored in English; central and numbered stations are rendered from the city code. */
  station: (code: string | null | undefined, fallback?: string | null) => string;
}

const Ctx = createContext<I18n | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLoc] = useState<Locale>("en");
  const [market, setMarketState] = useState<Market>(FIRST_MARKET);
  // the cities of the network as the server names them (GET /api/geo/cities, 1125): a city opened for routes from the
  // administrative geography is named in both languages without a message of its own
  const [cityNames, setCityNames] = useState<Record<string, { en: string; ar: string }>>({});
  // the visitor's own choice, else the language of the country they are in (1141: Arabic in Syria, English elsewhere,
  // set per country by the platform), else the phone's; only a choice is stored, so the default follows the country
  useEffect(() => {
    void get("locale").then(async (v) => {
      if (v === "ar" || v === "en") { setLoc(v); return; }
      const first = await api.get<{ visitor?: { locale?: string } }>("/api/markets").then((d) => d.visitor?.locale).catch(() => undefined);
      const phone = getLocales()[0]?.languageCode;
      const l: Locale = first === "ar" || first === "en" ? first : phone === "ar" ? "ar" : "en";
      setLoc(l);
      I18nManager.allowRTL(LOCALES[l].rtl);
      I18nManager.forceRTL(LOCALES[l].rtl);   // the layout direction follows on the next start
    });
  }, []);
  useEffect(() => {
    api.get<{ cities: { code: string; name_en: string; name_ar: string }[] }>("/api/geo/cities")
      .then((d) => setCityNames(Object.fromEntries(d.cities.map((c) => [c.code, { en: c.name_en, ar: c.name_ar }]))))
      .catch(() => { /* offline: the codes stay */ });
  }, []);
  useEffect(() => {
    void get("market").then((v) => {
      try { if (v) { const m = JSON.parse(v) as Market; currentZone = m.time_zone; currentScale = [m.minor_unit, m.decimals ?? Math.min(m.minor_unit, 3)]; setMarketState(m); } } catch { /* ignore a bad copy */ }
    });
  }, []);
  const setMarket = useCallback((m: Market) => {
    currentZone = m.time_zone;
    currentScale = [m.minor_unit, m.decimals ?? Math.min(m.minor_unit, 3)];
    setMarketState(m);
    void put("market", JSON.stringify(m));
  }, []);
  const setLocale = useCallback(async (l: Locale) => {
    setLoc(l);
    await put("locale", l);
    const needsRestart = I18nManager.isRTL !== LOCALES[l].rtl;
    I18nManager.allowRTL(LOCALES[l].rtl);
    I18nManager.forceRTL(LOCALES[l].rtl);
    return needsRestart;
  }, []);
  const value = useMemo<I18n>(() => {
    const m = LOCALES[locale].messages;
    const intl = LOCALES[locale].intl;
    const served = (key: string) => {
      const c = key.startsWith("city.") ? cityNames[key.slice(5)] : undefined;
      return c ? (locale === "ar" ? c.ar : c.en) : undefined;
    };
    const t = (key: string, vars?: Vars) => {
      const s = lookup(m, key) ?? lookup(en, key) ?? served(key) ?? key;
      return vars ? s.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? String(vars[k]) : `{${k}}`)) : s;
    };
    const has = (key: string) => lookup(m, key) !== undefined || lookup(en, key) !== undefined || served(key) !== undefined;
    const city = (code: string) => (has(`city.${code}`) ? t(`city.${code}`) : code);
    return {
      locale, rtl: LOCALES[locale].rtl, setLocale, t, has, city, market, setMarket,
      station: (code, fallback) => {
        const x = code ? /^SY-([A-Z]{3})-([A-Z])(\d{3})$/.exec(code) : null;
        if (!x) return fallback ?? code ?? "";
        const n = Number(x[3]);
        return x[2] === "C" && n === 1 ? t("station.central", { city: city(x[1]) }) : t("station.numbered", { city: city(x[1]), n });
      },
      dateTime: (iso) => new Intl.DateTimeFormat(intl, { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false,
                                                         timeZone: market.time_zone }).format(new Date(iso)),
      // amounts travel in minor units (10,000 to the new pound, 1,000 to the dinar) and show rounded to the decimals people
      // pay in; another currency than the market's is shown with its own code and two decimals
      money: (minor, currency) => {
        const code = currency ?? market.currency;
        const [scale, places] = code === market.currency ? [market.minor_unit, market.decimals ?? Math.min(market.minor_unit, 3)] : [2, 2];
        const amount = Math.round(minor / 10 ** (scale - places)) / 10 ** places;
        const shown = Number.isInteger(amount) ? amount.toLocaleString("en-US")
          : amount.toLocaleString("en-US", { minimumFractionDigits: places, maximumFractionDigits: places });
        return `${shown} ${has(`currencies.${code}`) ? t(`currencies.${code}`) : code}`;
      },
      time: (iso) => new Intl.DateTimeFormat(intl, { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: market.time_zone }).format(new Date(iso)),
      date: (iso) => new Intl.DateTimeFormat(intl, { weekday: "short", day: "numeric", month: "short", timeZone: market.time_zone }).format(new Date(iso)),
    };
  }, [locale, setLocale, market, setMarket, cityNames]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n(): I18n {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
