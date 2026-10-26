import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { ar } from './ar';

// Languages of the interface (FR-PLT-032, NFR-I18N-01): English is the base and the key; Arabic is a dictionary over
// the English text. Choosing Arabic also turns the page right-to-left; the CSS uses logical properties only.
export type Lang = 'en' | 'ar';

interface I18n { lang: Lang; setLang: (l: Lang) => void; t: (text: string, params?: Record<string, string | number>) => string }

// In English a code of the server (a status, a type, a list value) shows as a word, not as its code (the owner, docs/31
// row 71): the word of EN_WORDS, or the code in sentence case ("DOCUMENTARY_CREDITS" is "Documentary credits"). A code is
// all capitals with an underscore, or one ar.ts translates; acronyms stay as they are.
const ACRONYMS = new Set(['AH', 'API', 'BIC', 'CF', 'CSV', 'D7', 'D30', 'D90', 'ERP', 'HTTP', 'IBAN', 'ICC', 'ID', 'IS', 'KYC', 'LC', 'MFA', 'MT700', 'OTP',
  'PDF', 'POS', 'QR', 'SAR', 'SLA', 'SMTP', 'SWIFT', 'TOTP', 'UCP', 'URL', 'USD', 'VAT']);
export const EN_WORDS: Record<string, string> = {
  AR: 'Arabic', EN: 'English', BOTH: 'Arabic and English', ABOUT: 'About (±10%)', ABSOLUTE: 'A set date', WITHOUT: 'Without',
  ISSUING_BANK_LOCAL: "Issuing bank's charges", OTHER_OUTSIDE_ISSUING: 'Other charges outside the issuing bank', NOT_REQUIRED_BY_TERMS: 'Not required by the terms',
  DAYS_AFTER_ISSUE: 'Days after issue', MIXED: 'Mixed payment', SOLE: 'Sole lender', LEAD: 'Lead', SHARED_CAP: 'Shared cap', OUTSIDE_TOTAL: 'Outside the total',
};
function englishOf(text: string): string {
  if (!/^[A-Z][A-Z0-9_]*$/.test(text) || ACRONYMS.has(text)) return text;
  if (EN_WORDS[text]) return EN_WORDS[text];
  if (!text.includes('_') && !(text in ar)) return text;
  const words = text.toLowerCase().split('_').filter(Boolean).join(' ');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

const Ctx = createContext<I18n>({ lang: 'en', setLang: () => undefined, t: s => s });

function initial(): Lang {
  try {
    const saved = localStorage.getItem('bf.lang');
    if (saved === 'ar' || saved === 'en') return saved;
  } catch { /* storage may be unavailable */ }
  return 'en';   // English is the default; Arabic is the second choice, kept once chosen (the owner, docs/31 row 69)
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(initial);
  useEffect(() => {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === 'ar' ? 'rtl' : 'ltr';
  }, [lang]);
  const setLang = useCallback((l: Lang) => {
    setLangState(l);
    try { localStorage.setItem('bf.lang', l); } catch { /* ignore */ }
  }, []);
  const t = useCallback((text: string, params?: Record<string, string | number>) => {
    let s = lang === 'ar' ? (ar[text] ?? text) : englishOf(text);
    if (params) for (const [k, v] of Object.entries(params)) s = s.replaceAll(`{${k}}`, String(v));
    return s;
  }, [lang]);
  return <Ctx.Provider value={{ lang, setLang, t }}>{children}</Ctx.Provider>;
}

export const useI18n = () => useContext(Ctx);

export function LangSwitch() {
  const { lang, setLang } = useI18n();
  return (
    <button type="button" className="link lang" onClick={() => setLang(lang === 'ar' ? 'en' : 'ar')}>
      {lang === 'ar' ? 'English' : 'العربية'}
    </button>
  );
}

/** A date and time in the viewer's language; the API sends UTC. */
export function useFormat() {
  const { lang } = useI18n();
  return {
    dateTime: (iso?: string | null) => iso ? new Date(iso.endsWith('Z') ? iso : iso + 'Z').toLocaleString(lang === 'ar' ? 'ar-u-nu-latn' : 'en-GB') : '',
    date: (iso?: string | null) => iso ? iso.slice(0, 10) : '',
  };
}
