import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Market } from "../api";
import en, { type Messages } from "./en";
import ar from "./ar";

// Locales the interface ships with. Adding a language (Turkish, French, Spanish…) means adding a messages
// file with the same keys and one entry here; the code itself never contains interface text.
export const LOCALES = {
  ar: { messages: ar, dir: "rtl", intl: "ar-SY-u-nu-latn" },
  en: { messages: en, dir: "ltr", intl: "en-GB" },
} as const;
export type Locale = keyof typeof LOCALES;
// English is the default; building with VITE_DEFAULT_LOCALE=ar makes the Arabic interface the default
export const DEFAULT_LOCALE: Locale = import.meta.env.VITE_DEFAULT_LOCALE === "ar" ? "ar" : "en";
// Until the server names the market (GET /api/markets, the user's own on sign-in), times and money follow the
// platform's first market; every other market's screens switch as soon as it is known (1061)
// The new Syrian pound (1 January 2026, two zeros removed): amounts count ten-thousandths of a pound, shown with two decimals (1176)
const FIRST_MARKET: Market = { country: "SY", time_zone: "Asia/Damascus", currency: "SYP", locale: "ar", minor_unit: 4, decimals: 2 };
let currentZone = FIRST_MARKET.time_zone;
let currentScale: [number, number] = [FIRST_MARKET.minor_unit, FIRST_MARKET.decimals ?? 2];
/** An amount people typed in whole units of the market's currency ("290.50") as the minor units it travels in (1176). */
export const toMinor = (value: string | number) => Math.round(Number(value || 0) * 10 ** currentScale[0]);
/** Minor units of the market's currency as the whole-unit number a form field shows, rounded to the decimals people pay in. */
export const fromMinor = (minor: number) => Math.round(minor / 10 ** (currentScale[0] - currentScale[1])) / 10 ** currentScale[1];
/** The time zone of the market on screen, for code outside React (calendar dates in dates.ts). */
export const zone = () => currentZone;

type Vars = Record<string, string | number>;

// The names of the cities of the network as the server knows them (GET /api/geo/cities, 1125): a city opened for routes
// from the administrative geography is named in both languages at once, without a message key of its own
let cityNames: Record<string, { en: string; ar: string }> = {};
function cityName(messages: Messages, locale: string, code: string) {
  const known = cityNames[code];
  return lookup(messages, `city.${code}`) ?? (known ? (locale === "ar" ? known.ar : known.en) : undefined) ?? code;
}

function lookup(messages: Messages, key: string): string | undefined {
  let node: unknown = messages;
  for (const part of key.split(".")) {
    if (node && typeof node === "object" && part in (node as Record<string, unknown>)) node = (node as Record<string, unknown>)[part];
    else return undefined;
  }
  return typeof node === "string" ? node : undefined;
}

function format(template: string, vars?: Vars) {
  return vars ? template.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? String(vars[k]) : `{${k}}`)) : template;
}

/** A station name from its code in a language's words: central and numbered city stations (class C) are named from the
 * city code, any other (a border crossing, class X) keeps its own name rather than being called a city station. */
function stationName(messages: Messages, code: string | null | undefined, fallback: string) {
  const m = code ? /^SY-([A-Z]{3})-C(\d{3})$/.exec(code) : null;
  if (!m) return fallback;
  const n = Number(m[2]);
  const city = cityName(messages, messages === ar ? "ar" : "en", m[1]);
  const key = n === 1 ? "station.central" : "station.numbered";
  return format(lookup(messages, key) ?? lookup(en, key) ?? key, { city, n });
}

/** The words of one language, whatever the interface shows: the departure board shows its languages in turn (1115). */
export function translator(l: Locale) {
  const cfg = LOCALES[l];
  return {
    locale: l, dir: cfg.dir, intl: cfg.intl,
    t: (key: string, vars?: Vars) => format(lookup(cfg.messages, key) ?? lookup(en, key) ?? key, vars),
    has: (key: string) => lookup(cfg.messages, key) !== undefined,
    city: (code: string) => cityName(cfg.messages, l, code),
    station: (code: string | null | undefined, fallback: string) => stationName(cfg.messages, code, fallback),
  };
}

interface I18n {
  locale: Locale;
  dir: "rtl" | "ltr";
  /** The Intl locale of the interface (Latin digits in Arabic), for formats the helpers below do not cover. */
  intl: string;
  setLocale: (l: Locale) => void;
  t: (key: string, vars?: Vars) => string;
  has: (key: string) => boolean;
  /** Minor units as money of the market on screen, or of the currency given (a booking's own). */
  money: (minor: number, withCurrency?: boolean, currency?: string) => string;
  /** An amount people typed, in whole units ("290.50"), as the minor units it travels in; empty stays empty. */
  toMinor: (value: string | number, currency?: string) => number;
  /** Minor units as the whole-unit number a form field shows ("290.5"). */
  fromMinor: (minor: number, currency?: string) => number;
  /** The market on screen and how to change it (sign-in sets the user's). */
  /** The name of a currency (the market's when none is given). */
  currency: (code?: string) => string;
  market: Market;
  setMarket: (m: Market) => void;
  num: (n: number) => string;
  date: (iso: string | Date, opts?: Intl.DateTimeFormatOptions) => string;
  time: (iso: string | Date) => string;
  dateTime: (iso: string | Date) => string;
  city: (code: string) => string;
  station: (code: string | null | undefined, fallback: string) => string;
  duration: (minutes: number) => string;
}

const Ctx = createContext<I18n | null>(null);

function initialLocale(): Locale {
  // a link from the landing pages carries the visitor's language (?lang=ar|en)
  try {
    const wanted = new URLSearchParams(window.location.search).get("lang");
    if (wanted && wanted in LOCALES) {
      localStorage.setItem("masslak.locale", wanted);
      return wanted as Locale;
    }
  } catch { /* storage unavailable */ }
  try {
    const saved = localStorage.getItem("masslak.locale");
    if (saved && saved in LOCALES) return saved as Locale;
  } catch { /* storage unavailable */ }
  return DEFAULT_LOCALE;
}

/** Whether the visitor has chosen a language (a link's ?lang or a saved choice); without one the server's language for
 * the visitor's country applies (1141: Arabic in Syria, English elsewhere, set per country by the platform). */
function hasChoice(): boolean {
  try {
    const wanted = new URLSearchParams(window.location.search).get("lang");
    const saved = localStorage.getItem("masslak.locale");
    return Boolean((wanted && wanted in LOCALES) || (saved && saved in LOCALES));
  } catch { return false; }
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(initialLocale);
  const [market, setMarketState] = useState<Market>(FIRST_MARKET);
  const [known, setKnown] = useState<Record<string, [number, number]>>({ [FIRST_MARKET.currency]: [FIRST_MARKET.minor_unit, FIRST_MARKET.decimals ?? 2] });
  const [namesVersion, setNamesVersion] = useState(0);
  const userMarket = useRef(false);                 // the signed-in user's market wins over the default
  const chosen = useRef(hasChoice());               // the visitor's own language wins over their country's
  const cfg = LOCALES[locale];
  const apply = useCallback((m: Market) => {
    currentZone = m.time_zone;
    currentScale = [m.minor_unit, m.decimals ?? Math.min(m.minor_unit, 3)];
    setMarketState(m);
    setKnown((k) => ({ ...k, [m.currency]: [m.minor_unit, m.decimals ?? Math.min(m.minor_unit, 3)] }));
  }, []);
  const setMarket = useCallback((m: Market) => { userMarket.current = true; apply(m); }, [apply]);
  // the default market and the minor units of every open market's currency, for visitors and for amounts in another currency
  useEffect(() => {
    let live = true;
    fetch("/api/markets", { headers: { "X-Masslak-Client": "web" } }).then((r) => (r.ok ? r.json() : null)).then((d) => {
      if (!live || !d) return;
      setKnown((k) => ({ ...k, ...Object.fromEntries((d.markets as Market[]).map((x) => [x.currency, [x.minor_unit, x.decimals ?? Math.min(x.minor_unit, 3)]])) }));
      if (!userMarket.current) apply(d.default as Market);
      const first = d.visitor?.locale as string | undefined;
      if (!chosen.current && first && first in LOCALES) setLocaleState(first as Locale);
    }).catch(() => {});
    return () => { live = false; };
  }, [apply]);

  useEffect(() => {
    let live = true;
    fetch("/api/geo/cities", { headers: { "X-Masslak-Client": "web" } }).then((r) => (r.ok ? r.json() : null)).then((d) => {
      if (!live || !d) return;
      cityNames = Object.fromEntries((d.cities as { code: string; name_en: string; name_ar: string }[]).map((c) => [c.code, { en: c.name_en, ar: c.name_ar }]));
      setNamesVersion((v) => v + 1);
    }).catch(() => {});
    return () => { live = false; };
  }, []);

  useEffect(() => {
    document.documentElement.lang = locale;
    document.documentElement.dir = cfg.dir;
    document.title = cfg.messages.app.name;
  }, [locale, cfg]);

  const setLocale = useCallback((l: Locale) => {
    chosen.current = true;
    setLocaleState(l);
    try { localStorage.setItem("masslak.locale", l); } catch { /* storage unavailable */ }
  }, []);

  const value = useMemo<I18n>(() => {
    const t = (key: string, vars?: Vars) => format(lookup(cfg.messages, key) ?? lookup(en, key) ?? key, vars);
    const nf = new Intl.NumberFormat(cfg.intl, { maximumFractionDigits: 0 });
    const toDate = (v: string | Date) => (typeof v === "string" ? new Date(v) : v);
    const city = (code: string) => cityName(cfg.messages, locale, code);
    return {
      locale, dir: cfg.dir, intl: cfg.intl, setLocale, t,
      has: (key) => lookup(cfg.messages, key) !== undefined,
      // Amounts travel in minor units (10,000 to the new pound, 1,000 to the dinar); they show rounded to the decimals
      // people pay in, and whole amounts show none
      money: (minor, withCurrency = true, currency) => {
        const code = currency ?? market.currency;
        const [scale, places] = known[code] ?? [2, 2];
        const amount = Math.round(minor / 10 ** (scale - places)) / 10 ** places;
        const shown = Number.isInteger(amount) ? nf.format(amount)
          : new Intl.NumberFormat(cfg.intl, { minimumFractionDigits: places, maximumFractionDigits: places }).format(amount);
        return shown + (withCurrency ? ` ${lookup(cfg.messages, `currencies.${code}`) ?? code}` : "");
      },
      toMinor: (value, currency) => {
        const [scale] = known[currency ?? market.currency] ?? [2, 2];
        return Math.round(Number(value || 0) * 10 ** scale);
      },
      fromMinor: (minor, currency) => {
        const [scale, places] = known[currency ?? market.currency] ?? [2, 2];
        return Math.round(minor / 10 ** (scale - places)) / 10 ** places;
      },
      currency: (code) => lookup(cfg.messages, `currencies.${code ?? market.currency}`) ?? code ?? market.currency,
      market, setMarket,
      num: (n) => nf.format(n),
      date: (v, opts) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, weekday: "short", day: "numeric", month: "short", ...opts }).format(toDate(v)),
      time: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
      dateTime: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
      city,
      // Station names are stored in English and rendered from their codes where they can be (stationName above)
      station: (code, fallback) => stationName(cfg.messages, code, fallback),
      duration: (minutes) => t("common.duration", { h: Math.floor(minutes / 60), m: minutes % 60 }),
    };
  }, [locale, cfg, setLocale, market, known, setMarket, namesVersion]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
