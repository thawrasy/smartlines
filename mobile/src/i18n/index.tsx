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
  t: (key: string, vars?: Vars) => string; money: (minor: number) => string; time: (iso: string) => string; date: (iso: string) => string;
}

const Ctx = createContext<I18n | null>(null);

export function I18nProvider({ children }: { children: ReactNode }) {
  const [locale, setLoc] = useState<Locale>("en");
  useEffect(() => { void get("locale").then((v) => { if (v === "ar" || v === "en") setLoc(v); }); }, []);
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
    return {
      locale, rtl: LOCALES[locale].rtl, setLocale, t,
      money: (minor) => `${Math.round(minor / 100).toLocaleString("en-US")} ${t("common.currency")}`,
      time: (iso) => new Intl.DateTimeFormat(intl, { hour: "2-digit", minute: "2-digit", hour12: false, timeZone: "Asia/Damascus" }).format(new Date(iso)),
      date: (iso) => new Intl.DateTimeFormat(intl, { weekday: "short", day: "numeric", month: "short", timeZone: "Asia/Damascus" }).format(new Date(iso)),
    };
  }, [locale, setLocale]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useI18n(): I18n {
  const v = useContext(Ctx);
  if (!v) throw new Error("useI18n outside I18nProvider");
  return v;
}
