// Interface language. English is the default; Arabic switches the layout to right-to-left (applied by the
// platform on the next start). Code and data stay English; wording lives only in the locale files.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { I18nManager } from "react-native";
import en, { type Messages } from "./en";
import ar from "./ar";
import { get, put } from "../platform/secure";

export const LOCALES = { en: { messages: en, rtl: false, intl: "en-GB" }, ar: { messages: ar, rtl: true, intl: "ar-SY-u-nu-latn" } } as const;
export type Locale = keyof typeof LOCALES;

type Vars = Record<string, string | number>;

// The market whose time and money the screens show (1061): the user's, from GET /api/auth/me; until then the
// platform's first market. Kept on the phone so offline screens show the same.
export interface Market { country: string; time_zone: string; currency: string; locale: string; minor_unit: number }
const FIRST_MARKET: Market = { country: "SY", time_zone: "Asia/Damascus", currency: "SYP", locale: "ar", minor_unit: 2 };
let currentZone = FIRST_MARKET.time_zone;
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
  useEffect(() => { void get("locale").then((v) => { if (v === "ar" || v === "en") setLoc(v); }); }, []);
  useEffect(() => {
    void get("market").then((v) => {
      try { if (v) { const m = JSON.parse(v) as Market; currentZone = m.time_zone; setMarketState(m); } } catch { /* ignore a bad copy */ }
    });
  }, []);
  const setMarket = useCallback((m: Market) => {
    currentZone = m.time_zone;
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
    const t = (key: string, vars?: Vars) => {
      const s = lookup(m, key) ?? lookup(en, key) ?? key;
      return vars ? s.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? String(vars[k]) : `{${k}}`)) : s;
    };
    const has = (key: string) => lookup(m, key) !== undefined || lookup(en, key) !== undefined;
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
      // amounts travel in minor units (100 to the pound, 1,000 to the dinar); another currency than the market's is
      // shown with its own code and two decimals at most
      money: (minor, currency) => {
        const code = currency ?? market.currency;
        const unit = 10 ** (code === market.currency ? market.minor_unit : 2);
        const amount = minor / unit;
        const shown = Number.isInteger(amount) ? amount.toLocaleString("en-US") : amount.toLocaleString("en-US", { maximumFractionDigits: Math.log10(unit) });
        return `${shown} ${has(`currencies.${code}`) ? t(`currencies.${code}`) : code}`;
      },
      time: (iso) => new Intl.DateTimeFormat(intl, { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: market.time_zone }).format(new Date(iso)),
      date: (iso) => new Intl.DateTimeFormat(intl, { weekday: "short", day: "numeric", month: "short", timeZone: market.time_zone }).format(new Date(iso)),
    };
  }, [locale, setLocale, market, setMarket]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n(): I18n {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
