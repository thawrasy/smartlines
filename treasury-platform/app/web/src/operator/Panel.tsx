import { useCallback, useEffect, useState } from 'react';
import { Link, Navigate, NavLink, Route, Routes, useNavigate, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { LangSwitch, useFormat, useI18n } from '../i18n';
import { Field, Form, IdleGuard, Notice, SecretBox, Select, StepUpProvider, Table, useStepUp } from '../ui';

// The operator session ends after 15 idle minutes (FR-PLT-006); the screen leaves at the same time.
const OPERATOR_IDLE_MINUTES = 15;
const keepAlive = () => api('GET', '/operator/me');
import { Incidents, MFA_LABELS, Security } from './Security';

interface TenantRow { id: string; code: string; nameEn: string; nameAr: string; status: string; trialEndsOn?: string; planCode: string }
interface Me { email: string; displayName?: string; role: string }

// SCR-PLT-51: set-up through the link, then sign-in with the TOTP code
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
    <div className="auth">
      <header className="auth-head"><strong>BankFas</strong><LangSwitch /></header>
      <Form title="Set up your operator account" submit="Finish set-up" onSubmit={async () => {
        await api('POST', '/operator/auth/setup/complete', { token, password, code });
        nav('/login');
      }}>
        <Field label="Password (at least 14 characters)" value={password} onChange={setPassword} type="password" autoComplete="new-password" />
        {setup && <SecretBox secret={setup.secret} uri={setup.otpauthUri} />}
        <Field label="6-digit code" value={code} onChange={setCode} autoComplete="one-time-code" />
      </Form>
    </div>
  );
}

function Login() {
  const nav = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [step, setStep] = useState<'password' | 'mfa'>('password');
  return (
    <div className="auth">
      <header className="auth-head"><strong>BankFas</strong><LangSwitch /></header>
      {step === 'mfa'
        ? <Form title="Two-step verification" submit="Verify" onSubmit={async () => { await api('POST', '/operator/auth/mfa', { code }); nav('/'); }}>
            <Field label="Code from your authenticator" value={code} onChange={setCode} autoComplete="one-time-code" />
          </Form>
        : <Form title="BankFas operator panel" submit="Sign in" onSubmit={async () => { await api('POST', '/operator/auth/login', { email, password }); setStep('mfa'); }}>
            <Field label="E-mail" value={email} onChange={setEmail} type="email" autoComplete="username" />
            <Field label="Password" value={password} onChange={setPassword} type="password" autoComplete="current-password" />
          </Form>}
    </div>
  );
}

// SCR-PLT-52 and 53
function Tenants({ me }: { me: Me }) {
  const { t, lang } = useI18n();
  const fmt = useFormat();
  const ask = useStepUp();
  const [rows, setRows] = useState<TenantRow[]>([]);
  const [countries, setCountries] = useState<{ iso2: string; nameEn: string; nameAr: string }[]>([]);
  const [f, setF] = useState({ code: '', nameEn: '', nameAr: '', homeCountryIso2: 'AE', timeZone: 'Asia/Dubai', defaultLanguage: 'en', adminEmail: '', adminDisplayName: '' });
  const set = (k: keyof typeof f) => (v: string) => setF({ ...f, [k]: v });
  const load = useCallback(async () => setRows((await api<{ items: TenantRow[] }>('GET', '/operator/tenants')).items), []);
  useEffect(() => {
    void load();
    api<{ items: { iso2: string; nameEn: string; nameAr: string }[] }>('GET', '/operator/countries').then(r => setCountries(r.items)).catch(() => setCountries([]));
  }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Tenants')}</h1>
        <Table rows={rows} columns={[
          { header: 'Sub-domain', cell: r => <Link to={`/tenants/${r.id}`} dir="ltr">{r.code}</Link> },
          { header: 'Name', cell: r => lang === 'ar' ? r.nameAr : r.nameEn },
          { header: 'Status', cell: r => t(r.status) },
          { header: 'Trial ends', cell: r => fmt.date(r.trialEndsOn) },
          { header: 'Plan', cell: r => r.planCode },
        ]} />
      </section>
      {me.role === 'OPERATOR_ADMIN' && (
        <Form title="New tenant" submit="Create tenant" onSubmit={async () => {
          const mfaCode = await ask('Creating a tenant needs a fresh code.');
          if (!mfaCode) return;
          await api('POST', '/operator/tenants', { ...f, planCode: 'STANDARD', mfaCode });
          setF({ ...f, code: '', nameEn: '', nameAr: '', adminEmail: '', adminDisplayName: '' });
          await load();
        }}>
          <Field label="Sub-domain" value={f.code} onChange={set('code')} hint="Lower-case letters, digits and hyphens; it cannot change after activation." />
          <Field label="Name (English)" value={f.nameEn} onChange={set('nameEn')} />
          <Field label="Name (Arabic)" value={f.nameAr} onChange={set('nameAr')} />
          <Select label="Home country" value={f.homeCountryIso2} onChange={set('homeCountryIso2')}
            options={countries.map(c => ({ value: c.iso2, label: lang === 'ar' ? c.nameAr : c.nameEn }))} />
          <Field label="Time zone" value={f.timeZone} onChange={set('timeZone')} />
          <Select label="Language" value={f.defaultLanguage} onChange={set('defaultLanguage')} options={[{ value: 'en', label: 'English' }, { value: 'ar', label: 'العربية' }]} />
          <Field label="First administrator's e-mail" value={f.adminEmail} onChange={set('adminEmail')} type="email" />
          <Field label="First administrator's name" value={f.adminDisplayName} onChange={set('adminDisplayName')} />
        </Form>
      )}
    </>
  );
}

const MODULES = ['CORE', 'INSTITUTIONS', 'FACILITIES', 'COVENANTS', 'WORKFLOW', 'LC_PURCHASE', 'LC_SALES', 'REQUESTS', 'REPORTS'];

// SCR-PLT-54: statuses and counters, never business data (FR-PLT-005)
function TenantDetail({ me }: { me: Me }) {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const ask = useStepUp();
  const [d, setD] = useState<{ tenant: Record<string, string>; counters: Record<string, string | number | null>; modules: { module: string; enabled: boolean }[] } | null>(null);
  const [mods, setMods] = useState<string[]>([]);
  const [action, setAction] = useState({ status: 'ACTIVE', reason: '', trialEndsOn: '' });
  const [mfaPolicy, setMfaPolicy] = useState('PLATFORM');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const r = await api<NonNullable<typeof d>>('GET', `/operator/tenants/${id}`);
    setD(r);
    setMods(r.modules.filter(m => m.enabled).map(m => m.module));
    setMfaPolicy(r.tenant.mfaPolicy ?? 'PLATFORM');
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const admin = me.role === 'OPERATOR_ADMIN';
  return (
    <>
      <section className="card">
        <h1>{lang === 'ar' ? d.tenant.nameAr : d.tenant.nameEn} <small dir="ltr">({d.tenant.code})</small></h1>
        <p>{t('Status')}: <strong>{t(d.tenant.status ?? '')}</strong> · {t('Two-step verification')}: <strong>{t(MFA_LABELS[d.tenant.mfaPolicy ?? 'PLATFORM'] ?? '')}</strong></p>
        <Table rows={Object.entries(d.counters)} columns={[{ header: 'Counter', cell: ([k]) => t(k) }, { header: 'Value', cell: ([, v]) => String(v ?? '') }]} />
        {admin && <button className="secondary" onClick={async () => {
          setNotice({});
          try { await api('POST', `/operator/tenants/${id}/actions/resend-invitation`, {}); setNotice({ ok: 'The onboarding job sends a new invitation within a minute.' }); }
          catch (e) { setNotice({ error: message(e) }); }
        }}>{t('Send the first invitation again')}</button>}
        <Notice ok={notice.ok} error={notice.error} />
      </section>
      {admin && (
        <>
          <Form title="Modules" submit="Save modules" onSubmit={async () => { await api('PUT', `/operator/tenants/${id}/modules`, { modules: mods }); await load(); }}>
            {MODULES.map(m => (
              <label key={m} className="check">
                <input type="checkbox" disabled={m === 'CORE'} checked={mods.includes(m)} onChange={e => setMods(e.target.checked ? [...mods, m] : mods.filter(x => x !== m))} />
                {m}
              </label>
            ))}
          </Form>
          <Form title="Two-step verification" submit="Save" onSubmit={async () => {
            const mfaCode = await ask('Changing two-step verification needs a fresh code.');
            if (!mfaCode) return;
            await api('PUT', `/operator/tenants/${id}/mfa-policy`, { policy: mfaPolicy, mfaCode });
            await load();
          }}>
            <Select label="Two-step verification for this tenant" value={mfaPolicy} onChange={setMfaPolicy}
              options={['PLATFORM', 'REQUIRED', 'OFF'].map(p => ({ value: p, label: t(MFA_LABELS[p] ?? p) }))} />
            <p className="muted">{t('A user who set up an authenticator is always asked for it.')}</p>
          </Form>
          <Form title="Change the status" submit="Apply" onSubmit={async () => {
            const mfaCode = await ask('A status change needs a fresh code.');
            if (!mfaCode) return;
            await api('POST', `/operator/tenants/${id}/status`, { status: action.status, reason: action.reason || undefined, trialEndsOn: action.trialEndsOn || undefined, mfaCode });
            await load();
          }}>
            <Select label="New status" value={action.status} onChange={v => setAction({ ...action, status: v })}
              options={['ACTIVE', 'TRIAL', 'SUSPENDED', 'CLOSED'].map(s => ({ value: s, label: s }))} />
            <Field label="Reason (to suspend or close)" value={action.reason} onChange={v => setAction({ ...action, reason: v })} required={false} />
            <Field label="Trial ends on (to extend the trial)" type="date" value={action.trialEndsOn} onChange={v => setAction({ ...action, trialEndsOn: v })} required={false} />
          </Form>
        </>
      )}
    </>
  );
}

// SCR-PLT-56
function Operators() {
  const { t } = useI18n();
  const fmt = useFormat();
  const ask = useStepUp();
  const [rows, setRows] = useState<{ id: string; email: string; displayName?: string; role: string; status: string; lastLoginAt?: string }[]>([]);
  const [f, setF] = useState({ email: '', displayName: '', role: 'OPERATOR_SUPPORT' });
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => setRows((await api<{ items: typeof rows }>('GET', '/operator/operators')).items), []);
  useEffect(() => { void load(); }, [load]);
  const act = async (id: string, action: string) => {
    setError(null);
    const mfaCode = await ask('Changing an operator account needs a fresh code.');
    if (!mfaCode) return;
    try { await api('POST', `/operator/operators/${id}/actions/${action}`, { mfaCode }); await load(); } catch (e) { setError(message(e)); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Operators')}</h1>
        <Notice error={error} />
        <Table rows={rows} columns={[
          { header: 'E-mail', cell: o => <span dir="ltr">{o.email}</span> },
          { header: 'Name', cell: o => o.displayName },
          { header: 'Role', cell: o => t(o.role) },
          { header: 'Status', cell: o => t(o.status) },
          { header: 'Last sign-in', cell: o => fmt.dateTime(o.lastLoginAt) },
          { header: '', cell: o => (
            <span className="actions">
              {o.status === 'ACTIVE' && <button className="link" onClick={() => void act(o.id, 'disable')}>{t('Disable')}</button>}
              {o.status === 'DISABLED' && <button className="link" onClick={() => void act(o.id, 'enable')}>{t('Enable')}</button>}
              {o.status === 'LOCKED' && <button className="link" onClick={() => void act(o.id, 'unlock')}>{t('Unlock')}</button>}
              <button className="link" onClick={() => void act(o.id, 'reset')}>{t('Reset')}</button>
            </span>
          ) },
        ]} />
      </section>
      <Form title="Invite an operator" submit="Send the invitation" onSubmit={async () => {
        const mfaCode = await ask('Inviting an operator needs a fresh code.');
        if (!mfaCode) return;
        await api('POST', '/operator/operators', { ...f, mfaCode });
        setF({ ...f, email: '', displayName: '' });
        await load();
      }}>
        <Field label="E-mail" value={f.email} onChange={v => setF({ ...f, email: v })} type="email" />
        <Field label="Name" value={f.displayName} onChange={v => setF({ ...f, displayName: v })} />
        <Select label="Role" value={f.role} onChange={v => setF({ ...f, role: v })}
          options={[{ value: 'OPERATOR_SUPPORT', label: 'OPERATOR_SUPPORT' }, { value: 'OPERATOR_ADMIN', label: 'OPERATOR_ADMIN' }]} />
      </Form>
    </>
  );
}

// Support: the operator's live grants and the tenant's users through the support connection (AC-PLT-8)
function Support() {
  const { t } = useI18n();
  const fmt = useFormat();
  const [grants, setGrants] = useState<{ id: string; code: string; nameEn: string; endsAt: string; reason: string }[]>([]);
  const [users, setUsers] = useState<{ tenant: string; items: { email: string; displayNameEn?: string; status: string }[] } | null>(null);
  useEffect(() => { api<{ items: typeof grants }>('GET', '/operator/support/grants').then(r => setGrants(r.items)).catch(() => setGrants([])); }, []);
  return (
    <>
      <section className="card">
        <h1>{t('Support access')}</h1>
        <p className="muted">{t("Every page you open is in the tenant's audit log.")}</p>
        <Table rows={grants} empty="No tenant has given you access." columns={[
          { header: 'Tenant', cell: g => <span dir="ltr">{g.code}</span> },
          { header: 'Until', cell: g => fmt.dateTime(g.endsAt) },
          { header: 'Reason', cell: g => g.reason },
          { header: '', cell: g => <button className="link" onClick={async () => setUsers(await api('GET', `/operator/support/${g.id}/users`))}>{t('Users')}</button> },
        ]} />
      </section>
      {users && (
        <section className="card">
          <h2>{t('Users')} · <span dir="ltr">{users.tenant}</span></h2>
          <Table rows={users.items} columns={[
            { header: 'E-mail', cell: u => <span dir="ltr">{u.email}</span> },
            { header: 'Name', cell: u => u.displayNameEn },
            { header: 'Status', cell: u => t(u.status) },
          ]} />
        </section>
      )}
    </>
  );
}

// Platform holidays: the public holidays of a country, counted by every account (FR-PLT-035)
function Holidays({ me }: { me: Me }) {
  const { t } = useI18n();
  const [year, setYear] = useState(String(new Date().getFullYear()));
  const [rows, setRows] = useState<{ country: string; onDate: string; nameAr?: string; nameEn?: string; kind: string }[]>([]);
  const [f, setF] = useState({ country: 'SA', onDate: '', nameAr: '', nameEn: '', kind: 'HOLIDAY' });
  const load = useCallback(async () => setRows((await api<{ items: typeof rows }>('GET', `/operator/non-working-days?year=${encodeURIComponent(year)}`)).items), [year]);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Platform holidays')}</h1>
        <Field label="Year" value={year} onChange={setYear} type="number" />
        <Table rows={rows} columns={[
          { header: 'Date', cell: d => <span dir="ltr">{d.onDate}</span> },
          { header: 'Country', cell: d => d.country },
          { header: 'Name', cell: d => d.nameAr || d.nameEn },
          { header: 'Kind', cell: d => t(d.kind) },
        ]} />
      </section>
      {me.role === 'OPERATOR_ADMIN' && (
        <Form title="Add a holiday" submit="Add" onSubmit={async () => { await api('POST', '/operator/non-working-days', f); setF({ ...f, onDate: '', nameAr: '', nameEn: '' }); await load(); }}>
          <Field label="Country (ISO)" value={f.country} onChange={v => setF({ ...f, country: v })} />
          <Field label="Date" value={f.onDate} onChange={v => setF({ ...f, onDate: v })} type="date" />
          <Field label="Name (Arabic)" value={f.nameAr} onChange={v => setF({ ...f, nameAr: v })} />
          <Field label="Name (English)" value={f.nameEn} onChange={v => setF({ ...f, nameEn: v })} />
          <Select label="Kind" value={f.kind} onChange={v => setF({ ...f, kind: v })}
            options={['HOLIDAY', 'BRIDGE', 'OTHER'].map(k => ({ value: k, label: t(k) }))} />
        </Form>
      )}
    </>
  );
}

function Shell() {
  const nav = useNavigate();
  const { t } = useI18n();
  const [me, setMe] = useState<Me | null>(null);
  useEffect(() => { api<Me>('GET', '/operator/me').then(setMe).catch(() => nav('/login')); }, [nav]);
  if (!me) return null;
  const signOutIdle = () => { void api('POST', '/operator/auth/logout', {}).catch(() => undefined).finally(() => nav('/login')); };
  return (
    <StepUpProvider>
      <div className="shell">
        <IdleGuard minutes={OPERATOR_IDLE_MINUTES} keepAlive={keepAlive} onExpire={signOutIdle} />
        <header className="top">
          <strong>{t('BankFas operator panel')}</strong>
          <span className="grow" />
          <span className="muted" dir="ltr">{me.email}</span>
          <LangSwitch />
          <button className="link" onClick={async () => { await api('POST', '/operator/auth/logout', {}); nav('/login'); }}>{t('Sign out')}</button>
        </header>
        <nav className="side">
          <NavLink to="/" end>{t('Tenants')}</NavLink>
          {me.role === 'OPERATOR_ADMIN' && <NavLink to="/operators">{t('Operators')}</NavLink>}
          <NavLink to="/support">{t('Support access')}</NavLink>
          <NavLink to="/holidays">{t('Platform holidays')}</NavLink>
          <NavLink to="/security">{t('Security')}</NavLink>
          <NavLink to="/incidents">{t('Security incidents')}</NavLink>
        </nav>
        <main className="content">
          <Routes>
            <Route path="/" element={<Tenants me={me} />} />
            <Route path="/tenants/:id" element={<TenantDetail me={me} />} />
            <Route path="/operators" element={<Operators />} />
            <Route path="/support" element={<Support />} />
            <Route path="/holidays" element={<Holidays me={me} />} />
            <Route path="/security" element={<Security admin={me.role === 'OPERATOR_ADMIN'} />} />
            <Route path="/incidents" element={<Incidents admin={me.role === 'OPERATOR_ADMIN'} />} />
            <Route path="*" element={<Navigate to="/" />} />
          </Routes>
        </main>
      </div>
    </StepUpProvider>
  );
}

export function Panel() {
  return (
    <Routes>
      <Route path="/setup" element={<Setup />} />
      <Route path="/login" element={<Login />} />
      <Route path="/*" element={<Shell />} />
    </Routes>
  );
}
