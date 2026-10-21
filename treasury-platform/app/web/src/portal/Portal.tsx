import { useEffect, useState } from 'react';
import { Navigate, Route, Routes, useNavigate } from 'react-router-dom';
import { api, ApiError } from '../api';
import { Field, Form, SecretBox } from '../ui';

interface Tenant { code: string; nameEn: string; nameAr: string; status: string }
interface Me {
  user: { email: string; displayNameEn?: string; tenantNameEn: string; tenantStatus: string };
  permissions: string[]; modules: string[];
}
type Next = { nextStep: 'MFA_REQUIRED' | 'MFA_ENROLMENT_REQUIRED' | 'MFA_REENROLMENT_REQUIRED' | 'DONE' | 'LOGIN' };

function route(next: Next['nextStep']): string {
  switch (next) {
    case 'MFA_REQUIRED': return '/mfa';
    case 'MFA_ENROLMENT_REQUIRED': case 'MFA_REENROLMENT_REQUIRED': return '/mfa/enrol';
    case 'LOGIN': return '/login';
    default: return '/';
  }
}

// SCR-PLT-01 sign-in
function Login({ tenant }: { tenant: Tenant }) {
  const nav = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  return (
    <Form title={`Sign in to ${tenant.nameEn}`} submit="Sign in" onSubmit={async () => {
      const r = await api<Next>('POST', '/auth/login', { email, password });
      nav(route(r.nextStep));
    }}>
      <Field label="E-mail" value={email} onChange={setEmail} type="email" autoComplete="username" />
      <Field label="Password" value={password} onChange={setPassword} type="password" autoComplete="current-password" />
    </Form>
  );
}

// SCR-PLT-02 MFA check, with a recovery code instead
function Mfa() {
  const nav = useNavigate();
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  return (
    <Form title="Two-step verification" submit="Verify" onSubmit={async () => {
      await api<Next>('POST', '/auth/mfa', useRecovery ? { recoveryCode: code } : { code });
      nav('/');
    }}>
      <Field label={useRecovery ? 'Recovery code' : 'Code from your authenticator'} value={code} onChange={setCode} autoComplete="one-time-code" />
      <button type="button" className="link" onClick={() => setUseRecovery(!useRecovery)}>
        {useRecovery ? 'Use the authenticator code' : 'Use a recovery code'}
      </button>
    </Form>
  );
}

// SCR-PLT-04 authenticator set-up and the ten recovery codes, shown once
function Enrol() {
  const nav = useNavigate();
  const reenrolment = new URLSearchParams(window.location.hash.slice(1)).get('reenrol') ?? undefined;
  const [setup, setSetup] = useState<{ secret: string; otpauthUri: string } | null>(null);
  const [codes, setCodes] = useState<string[] | null>(null);
  const [code, setCode] = useState('');
  useEffect(() => {
    api<{ secret: string; otpauthUri: string }>('POST', '/auth/mfa/enrolment', { reenrolmentToken: reenrolment })
      .then(setSetup).catch(() => nav('/login'));
  }, [nav, reenrolment]);
  if (codes) {
    return (
      <section className="card">
        <h1>Keep your recovery codes</h1>
        <p>Each code works once if you lose your authenticator. They are not shown again.</p>
        <ol className="codes">{codes.map(c => <li key={c}><code>{c}</code></li>)}</ol>
        <button onClick={() => nav('/')}>I have saved them</button>
      </section>
    );
  }
  return (
    <Form title="Set up your authenticator" submit="Confirm" onSubmit={async () => {
      const r = await api<{ recoveryCodes: string[] }>('POST', '/auth/mfa/enrolment/complete', { code, reenrolmentToken: reenrolment });
      setCodes(r.recoveryCodes);
    }}>
      {setup && <SecretBox secret={setup.secret} uri={setup.otpauthUri} />}
      <Field label="6-digit code" value={code} onChange={setCode} autoComplete="one-time-code" />
    </Form>
  );
}

// SCR-PLT-07 invitation: the token is read from the fragment, which never reaches a server log
function Invitation() {
  const nav = useNavigate();
  const [token] = useState(() => new URLSearchParams(window.location.hash.slice(1)).get('token') ?? '');
  const [password, setPassword] = useState('');
  const [again, setAgain] = useState('');
  useEffect(() => { history.replaceState(null, '', '/invitation'); }, []);
  return (
    <Form title="Set your password" submit="Save password" onSubmit={async () => {
      if (password !== again) throw new ApiError({ status: 422, code: 'MISMATCH', title: 'The two passwords differ.' });
      await api<Next>('POST', '/auth/invitation', { token, password });
      nav('/login');
    }}>
      <p>At least 12 characters. A long phrase is easier to remember than a complex word.</p>
      <Field label="New password" value={password} onChange={setPassword} type="password" autoComplete="new-password" />
      <Field label="Repeat the password" value={again} onChange={setAgain} type="password" autoComplete="new-password" />
    </Form>
  );
}

function Home() {
  const nav = useNavigate();
  const [me, setMe] = useState<Me | null>(null);
  useEffect(() => { api<Me>('GET', '/me').then(setMe).catch(() => nav('/login')); }, [nav]);
  if (!me) return null;
  return (
    <section className="card">
      <h1>{me.user.tenantNameEn}</h1>
      {me.user.tenantStatus !== 'ACTIVE' && <p className="banner">Account status: {me.user.tenantStatus}</p>}
      <p>Signed in as {me.user.displayNameEn ?? me.user.email}</p>
      <p>Modules: {me.modules.join(', ')}</p>
      <button onClick={async () => { await api('POST', '/auth/logout', {}); nav('/login'); }}>Sign out</button>
    </section>
  );
}

export function Portal() {
  const [tenant, setTenant] = useState<Tenant | null | undefined>(undefined);
  useEffect(() => { api<Tenant>('GET', '/tenant').then(setTenant).catch(() => setTenant(null)); }, []);
  if (tenant === undefined) return null;
  if (tenant === null) return <section className="card"><h1>BankFas</h1><p>This address is not available.</p></section>;
  return (
    <Routes>
      <Route path="/login" element={<Login tenant={tenant} />} />
      <Route path="/mfa" element={<Mfa />} />
      <Route path="/mfa/enrol" element={<Enrol />} />
      <Route path="/invitation" element={<Invitation />} />
      <Route path="/" element={<Home />} />
      <Route path="*" element={<Navigate to="/" />} />
    </Routes>
  );
}
