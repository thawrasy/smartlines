import { useCallback, useEffect, useState } from 'react';
import { Navigate, Route, Routes, useNavigate } from 'react-router-dom';
import { api } from '../api';
import { Field, Form, SecretBox } from '../ui';

interface TenantRow { id: string; code: string; nameEn: string; nameAr: string; status: string; trialEndsOn?: string; planCode: string }

// SCR-PLT-51 operator set-up through the link: password and authenticator together
function Setup() {
  const nav = useNavigate();
  const [token] = useState(() => new URLSearchParams(window.location.hash.slice(1)).get('token') ?? '');
  const [setup, setSetup] = useState<{ secret: string; otpauthUri: string } | null>(null);
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  useEffect(() => {
    history.replaceState(null, '', '/setup');
    api<{ secret: string; otpauthUri: string }>('POST', '/operator/auth/setup', { token }).then(setSetup).catch(() => setSetup(null));
  }, [token]);
  return (
    <Form title="Set up your operator account" submit="Finish set-up" onSubmit={async () => {
      await api('POST', '/operator/auth/setup/complete', { token, password, code });
      nav('/login');
    }}>
      <Field label="Password (at least 14 characters)" value={password} onChange={setPassword} type="password" autoComplete="new-password" />
      {setup && <SecretBox secret={setup.secret} uri={setup.otpauthUri} />}
      <Field label="6-digit code" value={code} onChange={setCode} autoComplete="one-time-code" />
    </Form>
  );
}

// SCR-PLT-51 operator sign-in, then the TOTP code
function Login() {
  const nav = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [step, setStep] = useState<'password' | 'mfa'>('password');
  if (step === 'mfa') {
    return (
      <Form title="Two-step verification" submit="Verify" onSubmit={async () => {
        await api('POST', '/operator/auth/mfa', { code });
        nav('/');
      }}>
        <Field label="Code from your authenticator" value={code} onChange={setCode} autoComplete="one-time-code" />
      </Form>
    );
  }
  return (
    <Form title="BankFas operator panel" submit="Sign in" onSubmit={async () => {
      await api('POST', '/operator/auth/login', { email, password });
      setStep('mfa');
    }}>
      <Field label="E-mail" value={email} onChange={setEmail} type="email" autoComplete="username" />
      <Field label="Password" value={password} onChange={setPassword} type="password" autoComplete="current-password" />
    </Form>
  );
}

// SCR-PLT-53 new tenant; the fresh code is the step-up the database requires
function NewTenant({ done }: { done: () => void }) {
  const [f, setF] = useState({ code: '', nameEn: '', nameAr: '', homeCountryIso2: 'AE', timeZone: 'Asia/Dubai', adminEmail: '', adminDisplayName: '', mfaCode: '' });
  const set = (k: keyof typeof f) => (v: string) => setF({ ...f, [k]: v });
  return (
    <Form title="New tenant" submit="Create tenant" onSubmit={async () => {
      await api('POST', '/operator/tenants', { ...f, planCode: 'STANDARD', defaultLanguage: 'en' });
      setF({ ...f, code: '', nameEn: '', nameAr: '', adminEmail: '', adminDisplayName: '', mfaCode: '' });
      done();
    }}>
      <Field label="Sub-domain" value={f.code} onChange={set('code')} />
      <Field label="Name (English)" value={f.nameEn} onChange={set('nameEn')} />
      <Field label="Name (Arabic)" value={f.nameAr} onChange={set('nameAr')} />
      <Field label="Home country (ISO code)" value={f.homeCountryIso2} onChange={set('homeCountryIso2')} />
      <Field label="Time zone" value={f.timeZone} onChange={set('timeZone')} />
      <Field label="First administrator's e-mail" value={f.adminEmail} onChange={set('adminEmail')} type="email" />
      <Field label="First administrator's name" value={f.adminDisplayName} onChange={set('adminDisplayName')} />
      <Field label="Fresh code from your authenticator" value={f.mfaCode} onChange={set('mfaCode')} autoComplete="one-time-code" />
    </Form>
  );
}

// SCR-PLT-52 tenants: statuses only, never business data (FR-PLT-005)
function Tenants() {
  const nav = useNavigate();
  const [rows, setRows] = useState<TenantRow[] | null>(null);
  const load = useCallback(() => {
    api<{ items: TenantRow[] }>('GET', '/operator/tenants').then(r => setRows(r.items)).catch(() => nav('/login'));
  }, [nav]);
  useEffect(load, [load]);
  if (!rows) return null;
  return (
    <section>
      <div className="card">
        <h1>Tenants</h1>
        <table>
          <thead><tr><th>Sub-domain</th><th>Name</th><th>Status</th><th>Trial ends</th></tr></thead>
          <tbody>{rows.map(t => <tr key={t.id}><td>{t.code}</td><td>{t.nameEn}</td><td>{t.status}</td><td>{t.trialEndsOn?.slice(0, 10) ?? ''}</td></tr>)}</tbody>
        </table>
        <button onClick={async () => { await api('POST', '/operator/auth/logout', {}); nav('/login'); }}>Sign out</button>
      </div>
      <NewTenant done={load} />
    </section>
  );
}

export function Panel() {
  return (
    <Routes>
      <Route path="/setup" element={<Setup />} />
      <Route path="/login" element={<Login />} />
      <Route path="/" element={<Tenants />} />
      <Route path="*" element={<Navigate to="/" />} />
    </Routes>
  );
}
