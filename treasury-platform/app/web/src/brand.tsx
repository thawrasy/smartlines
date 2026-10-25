import type { ReactNode } from 'react';
import { LangSwitch, useI18n } from './i18n';
import logo from './brand/logo.svg';
import logoInverse from './brand/logo-inverse.svg';
import symbol from './brand/symbol.svg';

// The BankFas identity on screen (identity guide v2.0, ADR 0055): the logo files, the status chip and the sign-in
// layout. Colours, type and the slant live in styles.css; this file only places them.

/** The horizontal logo: the colour one on light grounds, the inverse one on vault green (guide p.8). */
export function Logo({ inverse = false, height = 28 }: { inverse?: boolean; height?: number }) {
  return <img className="logo" src={inverse ? logoInverse : logo} height={height} alt="BankFas" />;
}

/** The symbol alone, for spaces under 120px (guide p.9). */
export function Mark({ size = 24 }: { size?: number }) {
  return <img className="logo" src={symbol} width={size} height={size} alt="BankFas" />;
}

type Tone = 'draft' | 'review' | 'committee' | 'done' | 'stop';

// Colour, mark and word together (guide p.13): the mark tells the state apart without the colour.
const marks: Record<Tone, string> = { draft: '○', review: '◇', committee: '◆', done: '●', stop: '✕' };

const stop = /REJECT|FAIL|VOID|CANCEL|BREACH|EXPIRED|OVERDUE|LOCKED|SUSPEND|TERMINAT|DECLIN|BLOCK|SHORTFALL|ERROR|DEAD|^RED$|INVALID|LATE|MISSING|REVOKED|WITHDRAWN|DISCREPAN/;
const committee = /COMMITTEE|REFERRED|ESCALAT/;
const review = /PENDING|SUBMIT|REVIEW|RUNNING|QUEUED|EXPIRING|AMBER|WAIT|DUE|PROGRESS|INCOMPLETE|PARTIAL|RETURN|HOLD|TRIAL|INVITED|AWAIT|OPEN|REQUESTED|SCHEDULED|RETRY|BEHIND|PROCESSING|READ_ONLY/;
const done = /ACTIVE|APPROV|CONFIRM|COMPLETE|DONE|SUCCE|ISSUED|PAID|SETTLED|VALID|MET$|CURRENT|ENDORSED|SENT|DELIVERED|ACCEPT|COMPLIANT|^OK$|GREEN|PUBLISHED|READY|SIGNED|AVAILABLE|UTILI[SZ]ED|ENABLED|AMENDED|RECEIVED|PASS/;

/** The tone of a status code; unknown codes read as draft (grey), never as a success. */
export function toneOf(code: string): Tone {
  const c = code.toUpperCase();
  if (/^(INACTIVE|DISABLED|NOT_|UNAPPROVED|UNCONFIRMED|NON_COMPLIANT)/.test(c)) return /NON_COMPLIANT/.test(c) ? 'stop' : 'draft';
  if (stop.test(c)) return 'stop';
  if (committee.test(c)) return 'committee';
  if (review.test(c)) return 'review';
  if (done.test(c)) return 'done';
  return 'draft';
}

/** A status as a chip: the code's tone and mark, and its word in the viewer's language. */
export function Chip({ s, children }: { s: string | null | undefined; children?: ReactNode }) {
  const { t } = useI18n();
  if (!s) return null;
  const tone = toneOf(s);
  const word = t(s);
  // A code without an English text reads as words (PENDING_APPROVAL: Pending approval), not as a constant.
  const shown = word === s && /^[A-Z][A-Z0-9_]+$/.test(s) ? s.charAt(0) + s.slice(1).toLowerCase().replace(/_/g, ' ') : word;
  return <span className={`chip ${tone}`}><span aria-hidden="true">{marks[tone]}</span> {shown}{children}</span>;
}

/** The sign-in pages: the brand panel in vault green with the slant pattern, and the form on ivory (guide p.18, p.27). */
export function AuthLayout({ title, children }: { title?: string; children: ReactNode }) {
  const { t } = useI18n();
  return (
    <div className="auth-page">
      <aside className="auth-brand">
        <Logo inverse height={36} />
        <div className="slants" aria-hidden="true">{Array.from({ length: 24 }, (_, i) => <i key={i} className={i === 8 || i === 19 ? 'lit' : ''} />)}</div>
        <p className="promise">{t('Every facility starts from financial statements that were read, and ends with a decision that was worked out.')}</p>
        <p className="tagline">{t('The platform for bank facilities and financial statement assessment')}</p>
      </aside>
      <div className="auth">
        <header className="auth-head">{title ? <strong>{title}</strong> : <span />}<LangSwitch /></header>
        {children}
      </div>
    </div>
  );
}
