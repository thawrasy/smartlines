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
const FIRST_MARKET: Market = { country: "SY", time_zone: "Asia/Damascus", currency: "SYP", locale: "ar", minor_unit: 2 };
let currentZone = FIRST_MARKET.time_zone;
/** The time zone of the market on screen, for code outside React (calendar dates in dates.ts). */
export const zone = () => currentZone;

type Vars = Record<string, string | number>;

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

interface I18n {
  locale: Locale;
  dir: "rtl" | "ltr";
  setLocale: (l: Locale) => void;
  t: (key: string, vars?: Vars) => string;
  has: (key: string) => boolean;
  /** Minor units as money of the market on screen, or of the currency given (a booking's own). */
  money: (minor: number, withCurrency?: boolean, currency?: string) => string;
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

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(initialLocale);
  const [market, setMarketState] = useState<Market>(FIRST_MARKET);
  const [known, setKnown] = useState<Record<string, number>>({ [FIRST_MARKET.currency]: FIRST_MARKET.minor_unit });
  const userMarket = useRef(false);                 // the signed-in user's market wins over the default
  const cfg = LOCALES[locale];
  const apply = useCallback((m: Market) => {
    currentZone = m.time_zone;
    setMarketState(m);
    setKnown((k) => ({ ...k, [m.currency]: m.minor_unit }));
  }, []);
  const setMarket = useCallback((m: Market) => { userMarket.current = true; apply(m); }, [apply]);
  // the default market and the minor units of every open market's currency, for visitors and for amounts in another currency
  useEffect(() => {
    let live = true;
    fetch("/api/markets", { headers: { "X-Masslak-Client": "web" } }).then((r) => (r.ok ? r.json() : null)).then((d) => {
      if (!live || !d) return;
      setKnown((k) => ({ ...k, ...Object.fromEntries((d.markets as Market[]).map((x) => [x.currency, x.minor_unit])) }));
      if (!userMarket.current) apply(d.default as Market);
    }).catch(() => {});
    return () => { live = false; };
  }, [apply]);

  useEffect(() => {
    document.documentElement.lang = locale;
    document.documentElement.dir = cfg.dir;
    document.title = cfg.messages.app.name;
  }, [locale, cfg]);

  const setLocale = useCallback((l: Locale) => {
    setLocaleState(l);
    try { localStorage.setItem("masslak.locale", l); } catch { /* storage unavailable */ }
  }, []);

  const value = useMemo<I18n>(() => {
    const t = (key: string, vars?: Vars) => format(lookup(cfg.messages, key) ?? lookup(en, key) ?? key, vars);
    const nf = new Intl.NumberFormat(cfg.intl, { maximumFractionDigits: 0 });
    const toDate = (v: string | Date) => (typeof v === "string" ? new Date(v) : v);
    const city = (code: string) => lookup(cfg.messages, `city.${code}`) ?? code;
    return {
      locale, dir: cfg.dir, setLocale, t,
      has: (key) => lookup(cfg.messages, key) !== undefined,
      // Amounts travel in minor units (100 to the pound, 1,000 to the dinar); whole amounts show no decimals
      money: (minor, withCurrency = true, currency) => {
        const code = currency ?? market.currency;
        const unit = 10 ** (known[code] ?? 2);
        const amount = minor / unit;
        const shown = Number.isInteger(amount) ? nf.format(amount)
          : new Intl.NumberFormat(cfg.intl, { maximumFractionDigits: Math.log10(unit) }).format(amount);
        return shown + (withCurrency ? ` ${lookup(cfg.messages, `currencies.${code}`) ?? code}` : "");
      },
      currency: (code) => lookup(cfg.messages, `currencies.${code ?? market.currency}`) ?? code ?? market.currency,
      market, setMarket,
      num: (n) => nf.format(n),
      date: (v, opts) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, weekday: "short", day: "numeric", month: "short", ...opts }).format(toDate(v)),
      time: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
      dateTime: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: market.time_zone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
      city,
      // Station names are stored in English; central and numbered stations are rendered from the city code
      station: (code, fallback) => {
        const m = code ? /^SY-([A-Z]{3})-([A-Z])(\d{3})$/.exec(code) : null;
        if (!m) return fallback;
        const n = Number(m[3]);
        return m[2] === "C" && n === 1 ? t("station.central", { city: city(m[1]) }) : t("station.numbered", { city: city(m[1]), n });
      },
      duration: (minutes) => t("common.duration", { h: Math.floor(minutes / 60), m: minutes % 60 }),
    };
  }, [locale, cfg, setLocale, market, known, setMarket]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
