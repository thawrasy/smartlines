import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { ar } from './ar';

// Languages of the interface (FR-PLT-032, NFR-I18N-01): English is the base and the key; Arabic is a dictionary over
// the English text. Choosing Arabic also turns the page right-to-left; the CSS uses logical properties only.
export type Lang = 'en' | 'ar';

interface I18n { lang: Lang; setLang: (l: Lang) => void; t: (text: string, params?: Record<string, string | number>) => string }

const Ctx = createContext<I18n>({ lang: 'en', setLang: () => undefined, t: s => s });

function initial(): Lang {
  try {
    const saved = localStorage.getItem('bf.lang');
    if (saved === 'ar' || saved === 'en') return saved;
  } catch { /* storage may be unavailable */ }
  return navigator.language.startsWith('ar') ? 'ar' : 'en';
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
    let s = lang === 'ar' ? (ar[text] ?? text) : text;
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
