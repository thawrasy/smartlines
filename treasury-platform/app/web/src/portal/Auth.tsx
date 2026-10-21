import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { api, ApiError } from '../api';
import { LangSwitch, useI18n } from '../i18n';
import { Field, Form, SecretBox } from '../ui';

export interface Tenant { code: string; nameEn: string; nameAr: string; status: string; defaultLanguage: string }
type Next = { nextStep: 'MFA_REQUIRED' | 'MFA_ENROLMENT_REQUIRED' | 'MFA_REENROLMENT_REQUIRED' | 'DONE' | 'LOGIN' };

export function route(next: Next['nextStep']): string {
  switch (next) {
    case 'MFA_REQUIRED': return '/mfa';
    case 'MFA_ENROLMENT_REQUIRED': case 'MFA_REENROLMENT_REQUIRED': return '/mfa/enrol';
    case 'LOGIN': return '/login';
    default: return '/';
  }
}

/** The token of a link, read from the fragment, which no server or log ever sees; the address bar is then cleaned. */
function useFragmentToken(name: string, path: string): string {
  const [token] = useState(() => new URLSearchParams(window.location.hash.slice(1)).get(name) ?? '');
  useEffect(() => { if (window.location.hash) history.replaceState(null, '', path); }, [path]);
  return token;
}

function AuthCard({ tenant, children }: { tenant: Tenant; children: React.ReactNode }) {
  const { lang } = useI18n();
  return (
    <div className="auth">
      <header className="auth-head"><strong>{lang === 'ar' ? tenant.nameAr : tenant.nameEn}</strong><LangSwitch /></header>
      {children}
    </div>
  );
}

// SCR-PLT-01
export function Login({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const { t } = useI18n();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  return (
    <AuthCard tenant={tenant}>
      <Form title="Sign in" submit="Sign in" onSubmit={async () => nav(route((await api<Next>('POST', '/auth/login', { email, password })).nextStep))}>
        <Field label="E-mail" value={email} onChange={setEmail} type="email" autoComplete="username" />
        <Field label="Password" value={password} onChange={setPassword} type="password" autoComplete="current-password" />
        <p><a href="/forgot-password" onClick={e => { e.preventDefault(); nav('/forgot-password'); }}>{t('Forgot your password?')}</a></p>
      </Form>
    </AuthCard>
  );
}

// SCR-PLT-02
export function Mfa({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const { t } = useI18n();
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [left, setLeft] = useState<number | null>(null);
  if (left !== null) {
    return (
      <AuthCard tenant={tenant}>
        <section className="card">
          <h1>{t('Signed in with a recovery code')}</h1>
          <p>{t('{n} recovery codes are left. Ask your administrator for new ones when they run low.', { n: left })}</p>
          <button onClick={() => nav('/')}>{t('Continue')}</button>
        </section>
      </AuthCard>
    );
  }
  return (
    <AuthCard tenant={tenant}>
      <Form title="Two-step verification" submit="Verify" onSubmit={async () => {
        const r = await api<{ recoveryCodesRemaining?: number }>('POST', '/auth/mfa', useRecovery ? { recoveryCode: code } : { code });
        if (useRecovery && r.recoveryCodesRemaining !== undefined) setLeft(r.recoveryCodesRemaining);
        else nav('/');
      }}>
        <Field label={useRecovery ? 'Recovery code' : 'Code from your authenticator'} value={code} onChange={setCode} autoComplete="one-time-code" />
        <button type="button" className="link" onClick={() => setUseRecovery(!useRecovery)}>
          {t(useRecovery ? 'Use the authenticator code' : 'Use a recovery code')}
        </button>
      </Form>
    </AuthCard>
  );
}

// SCR-PLT-04: the authenticator and the ten recovery codes, shown once
export function Enrol({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const { t } = useI18n();
  const reenrolment = useFragmentToken('reenrol', '/mfa/enrol') || undefined;
  const [setup, setSetup] = useState<{ secret: string; otpauthUri: string } | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const [codes, setCodes] = useState<string[] | null>(null);
  const [code, setCode] = useState('');
  useEffect(() => {
    api<{ secret: string; otpauthUri: string }>('POST', '/auth/mfa/enrolment', { reenrolmentToken: reenrolment })
      .then(setSetup)
      .catch(e => { if (e instanceof ApiError && e.problem.code === 'LINK_REQUIRED') setFailed(e.problem.title); else nav('/login'); });
  }, [nav, reenrolment]);
  if (failed) return <AuthCard tenant={tenant}><section className="card"><h1>{t('Set up your authenticator')}</h1><p>{t(failed)}</p></section></AuthCard>;
  if (codes) {
    return (
      <AuthCard tenant={tenant}>
        <section className="card">
          <h1>{t('Keep your recovery codes')}</h1>
          <p>{t('Each code works once if you lose your authenticator. They are not shown again.')}</p>
          <ol className="codes" dir="ltr">{codes.map(c => <li key={c}><code>{c}</code></li>)}</ol>
          <button onClick={() => nav('/')}>{t('I have saved them')}</button>
        </section>
      </AuthCard>
    );
  }
  return (
    <AuthCard tenant={tenant}>
      <Form title="Set up your authenticator" submit="Confirm" onSubmit={async () => {
        setCodes((await api<{ recoveryCodes: string[] }>('POST', '/auth/mfa/enrolment/complete', { code, reenrolmentToken: reenrolment })).recoveryCodes);
      }}>
        {setup && <SecretBox secret={setup.secret} uri={setup.otpauthUri} />}
        <Field label="6-digit code" value={code} onChange={setCode} autoComplete="one-time-code" />
      </Form>
    </AuthCard>
  );
}

function NewPassword({ tenant, title, submit, send }: { tenant: Tenant; title: string; submit: string; send: (password: string) => Promise<void> }) {
  const { t } = useI18n();
  const [password, setPassword] = useState('');
  const [again, setAgain] = useState('');
  return (
    <AuthCard tenant={tenant}>
      <Form title={title} submit={submit} onSubmit={async () => {
        if (password !== again) throw new ApiError({ status: 422, code: 'MISMATCH', title: 'The two passwords differ.' });
        await send(password);
      }}>
        <p>{t('At least 12 characters. A long phrase is easier to remember than a complex word.')}</p>
        <Field label="New password" value={password} onChange={setPassword} type="password" autoComplete="new-password" />
        <Field label="Repeat the password" value={again} onChange={setAgain} type="password" autoComplete="new-password" />
      </Form>
    </AuthCard>
  );
}

// SCR-PLT-07 (invitee side)
export function Invitation({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const token = useFragmentToken('token', '/invitation');
  return <NewPassword tenant={tenant} title="Set your password" submit="Save password"
    send={async password => { await api('POST', '/auth/invitation', { token, password }); nav('/login'); }} />;
}

// SCR-PLT-03
export function ForgotPassword({ tenant }: { tenant: Tenant }) {
  const { t } = useI18n();
  const [email, setEmail] = useState('');
  const [sent, setSent] = useState(false);
  if (sent) return <AuthCard tenant={tenant}><section className="card"><h1>{t('Check your e-mail')}</h1><p>{t('If the address belongs to an account, a link is on its way.')}</p></section></AuthCard>;
  return (
    <AuthCard tenant={tenant}>
      <Form title="Reset your password" submit="Send the link" onSubmit={async () => { await api('POST', '/auth/password-reset-requests', { email }); setSent(true); }}>
        <Field label="E-mail" value={email} onChange={setEmail} type="email" autoComplete="username" />
      </Form>
    </AuthCard>
  );
}

export function ResetPassword({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const token = useFragmentToken('token', '/reset-password');
  return <NewPassword tenant={tenant} title="Choose a new password" submit="Save password"
    send={async newPassword => { await api('POST', '/auth/password-resets', { token, newPassword }); nav('/login'); }} />;
}
