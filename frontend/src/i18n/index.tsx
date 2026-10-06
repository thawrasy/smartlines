import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
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
export const TZ = "Asia/Damascus";

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
  money: (minor: number, withCurrency?: boolean) => string;
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
  const cfg = LOCALES[locale];

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
      // Amounts travel in minor units (1 SYP = 100)
      money: (minor, withCurrency = true) => nf.format(Math.round(minor / 100)) + (withCurrency ? ` ${t("common.currency")}` : ""),
      num: (n) => nf.format(n),
      date: (v, opts) => new Intl.DateTimeFormat(cfg.intl, { timeZone: TZ, weekday: "short", day: "numeric", month: "short", ...opts }).format(toDate(v)),
      time: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
      dateTime: (v) => new Intl.DateTimeFormat(cfg.intl, { timeZone: TZ, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", hour12: false }).format(toDate(v)),
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
  }, [locale, cfg, setLocale]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n() {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
