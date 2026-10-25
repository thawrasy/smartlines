import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table, useWithStepUp } from '../ui';
import { Chip } from '../brand';

interface UserRow {
  id: string; email: string; displayNameEn?: string; displayNameAr?: string; status: string; mfaEnabled: boolean; lastLoginAt?: string; roles: string[];
  companyScopeMode: string; employeeCode?: string; mobile?: string; productScopeMode: string; mustChangePassword: boolean;
}
const PRODUCTS = ['INSTITUTIONS', 'FACILITIES', 'COVENANTS', 'WORKFLOW', 'LC_PURCHASE', 'LC_SALES', 'REQUESTS', 'REPORTS'];

/** A temporary password, shown once to the administrator to hand over outside the platform (ADR 0048). */
function TemporaryPassword({ value }: { value: string }) {
  const { t } = useI18n();
  return (
    <section className="card">
      <h2>{t('Temporary password')}</h2>
      <p>{t('Hand it to the user yourself; it is not shown again. The user chooses their own at the first sign-in.')}</p>
      <p dir="ltr"><code className="secret">{value}</code></p>
    </section>
  );
}
interface RoleRow { id: string; code: string; nameEn: string; nameAr: string; isSystem: boolean; isActive: boolean }
interface Session { id: string; createdAt: string; lastSeenAt: string; ipAddress?: string; userAgent?: string; mfaVerified: boolean }

export function useRoles() {
  const [roles, setRoles] = useState<RoleRow[]>([]);
  useEffect(() => { api<{ items: RoleRow[] }>('GET', '/roles').then(r => setRoles(r.items)).catch(() => setRoles([])); }, []);
  return roles;
}

function RolePicker({ roles, value, onChange }: { roles: RoleRow[]; value: string[]; onChange: (v: string[]) => void }) {
  const { lang, t } = useI18n();
  return (
    <fieldset>
      <legend>{t('Roles')}</legend>
      {roles.filter(r => r.isActive).map(r => (
        <label key={r.id} className="check">
          <input type="checkbox" checked={value.includes(r.id)} onChange={e => onChange(e.target.checked ? [...value, r.id] : value.filter(x => x !== r.id))} />
          {r.code} · {lang === 'ar' ? r.nameAr : r.nameEn}
          {['TM', 'FO'].includes(r.code) && <small className="muted"> {t('(needs a fresh code)')}</small>}
        </label>
      ))}
    </fieldset>
  );
}

// SCR-PLT-07
export function Users() {
  const { t } = useI18n();
  const fmt = useFormat();
  const roles = useRoles();
  const withStepUp = useWithStepUp();
  const [rows, setRows] = useState<UserRow[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [invite, setInvite] = useState({ email: '', displayNameEn: '', displayNameAr: '', roleIds: [] as string[], employeeCode: '', mobile: '', method: 'INVITATION' });
  const [notice, setNotice] = useState<string | null>(null);
  const [temporary, setTemporary] = useState<string | null>(null);
  const load = useCallback(async (more?: string) => {
    const params = new URLSearchParams({ limit: '50' });
    if (q) params.set('q', q);
    if (status) params.set('status', status);
    if (more) params.set('cursor', more);
    const r = await api<{ items: UserRow[]; nextCursor: string | null }>('GET', '/users?' + params.toString());
    setRows(prev => more ? [...prev, ...r.items] : r.items);
    setCursor(r.nextCursor);
  }, [q, status]);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Users')}</h1>
        <div className="filters">
          <Field label="Search" value={q} onChange={setQ} required={false} />
          <Select label="Status" value={status} onChange={setStatus} options={[{ value: '', label: 'All' }, ...['ACTIVE', 'INVITED', 'LOCKED', 'DISABLED', 'ARCHIVED'].map(s => ({ value: s, label: s }))]} />
        </div>
        <Table rows={rows} columns={[
          { header: 'Name', cell: u => <Link to={`/users/${u.id}`}>{u.displayNameEn ?? u.email}</Link> },
          { header: 'E-mail', cell: u => <span dir="ltr">{u.email}</span> },
          { header: 'Employee code', cell: u => <span dir="ltr">{u.employeeCode ?? ''}</span> },
          { header: 'Status', cell: u => <Chip s={u.status} /> },
          { header: 'Roles', cell: u => u.roles.join(', ') },
          { header: 'Last sign-in', cell: u => fmt.dateTime(u.lastLoginAt) },
        ]} />
        {cursor && <button className="secondary" onClick={() => void load(cursor)}>{t('Show more')}</button>}
      </section>
      {temporary && <TemporaryPassword value={temporary} />}
      <Form title="Invite a user" submit={invite.method === 'TEMP_PASSWORD' ? 'Create with a temporary password' : 'Send the invitation'} onSubmit={async () => {
        setTemporary(null);
        const r = await withStepUp(invite.method === 'TEMP_PASSWORD' ? 'A temporary password needs a fresh confirmation.' : 'Giving the TM or FO role needs a fresh code.', code =>
          api<{ invitationSent: boolean; temporaryPassword?: string }>('POST', '/users', {
            ...invite, employeeCode: invite.employeeCode || undefined, mobile: invite.mobile || undefined, stepUpCode: code,
          }));
        if (!r) return;
        if (r.temporaryPassword) { setTemporary(r.temporaryPassword); setNotice('The user can sign in with the temporary password.'); }
        else setNotice(r.invitationSent ? 'The invitation is on its way.' : 'The user is created but the e-mail failed; send it again from the user.');
        setInvite({ email: '', displayNameEn: '', displayNameAr: '', roleIds: [], employeeCode: '', mobile: '', method: invite.method });
        await load();
      }}>
        <Select label="How the user gets in" value={invite.method} onChange={v => setInvite({ ...invite, method: v })}
          options={[{ value: 'INVITATION', label: t('An invitation link by e-mail') }, { value: 'TEMP_PASSWORD', label: t('A temporary password I hand over') }]} />
        <Field label="E-mail" value={invite.email} onChange={v => setInvite({ ...invite, email: v })} type="email" />
        <Field label="Name (English)" value={invite.displayNameEn} onChange={v => setInvite({ ...invite, displayNameEn: v })} />
        <Field label="Name (Arabic)" value={invite.displayNameAr} onChange={v => setInvite({ ...invite, displayNameAr: v })} required={false} />
        <Field label="Employee code" value={invite.employeeCode} onChange={v => setInvite({ ...invite, employeeCode: v })} required={false}
          hint="A sign-in name if the account allows it: 2 to 30 Latin letters, digits, dots, hyphens or underscores." />
        <Field label="Mobile" value={invite.mobile} onChange={v => setInvite({ ...invite, mobile: v })} required={false} hint="In international form, such as +966 5…" />
        <RolePicker roles={roles} value={invite.roleIds} onChange={v => setInvite({ ...invite, roleIds: v })} />
        <Notice ok={notice} />
      </Form>
    </>
  );
}

// SCR-PLT-08 and SCR-PLT-10
export function UserDetail() {
  const { id } = useParams();
  const { t } = useI18n();
  const fmt = useFormat();
  const roles = useRoles();
  const withStepUp = useWithStepUp();
  const [user, setUser] = useState<UserRow | null>(null);
  const [etag, setEtag] = useState('');
  const [names, setNames] = useState({ en: '', ar: '', employeeCode: '', mobile: '' });
  const [products, setProducts] = useState<string[]>([]);
  const [productMode, setProductMode] = useState('ALL');
  const [temporary, setTemporary] = useState<string | null>(null);
  const [picked, setPicked] = useState<string[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [reason, setReason] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const { data, etag: tag } = await apiWithETag<{ user: UserRow; products: string[] }>(`/users/${id}`);
    setUser(data.user);
    setEtag(tag);
    setNames({ en: data.user.displayNameEn ?? '', ar: data.user.displayNameAr ?? '', employeeCode: data.user.employeeCode ?? '', mobile: data.user.mobile ?? '' });
    setProducts(data.products.filter(p => p !== 'CORE'));
    setProductMode(data.user.productScopeMode);
    setSessions((await api<{ items: Session[] }>('GET', `/users/${id}/sessions`)).items);
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (user && roles.length) setPicked(roles.filter(r => user.roles.includes(r.code)).map(r => r.id)); }, [user, roles]);
  if (!user) return null;
  const act = async (action: string, needsCode = false) => {
    setNotice({});
    setTemporary(null);
    try {
      const run = (code?: string) => api<{ temporaryPassword?: string }>('POST', `/users/${id}/actions/${action}`, { reason: reason || undefined, stepUpCode: code });
      const r = needsCode ? await withStepUp(action === 'temporary-password' ? 'A temporary password needs a fresh confirmation.' : 'Resetting the authenticator needs a fresh code.', run) : await run();
      if (r?.temporaryPassword) setTemporary(r.temporaryPassword);
      setNotice({ ok: 'Done.' });
      await load();
    } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{user.displayNameEn ?? user.email}</h1>
        <p><span dir="ltr">{user.email}</span> · {t(user.status)} · {t(user.mfaEnabled ? 'Authenticator set up' : 'No authenticator yet')}
          {user.mustChangePassword && <> · {t('Temporary password, not changed yet')}</>}</p>
        <Field label="Reason (for disable, authenticator reset and temporary password)" value={reason} onChange={setReason} required={false} />
        <div className="actions">
          {user.status === 'ACTIVE' && <button className="secondary" onClick={() => void act('disable')}>{t('Disable')}</button>}
          {user.status === 'DISABLED' && <button className="secondary" onClick={() => void act('enable')}>{t('Enable')}</button>}
          {['INVITED', 'DISABLED'].includes(user.status) && <button className="secondary" onClick={() => void act('archive')}>{t('Archive')}</button>}
          {user.status === 'LOCKED' && <button className="secondary" onClick={() => void act('unlock')}>{t('Unlock')}</button>}
          {user.mfaEnabled && <button className="secondary" onClick={() => void act('reset-mfa', true)}>{t('Reset authenticator')}</button>}
          {user.status === 'INVITED' && <button className="secondary" onClick={() => void act('resend-invitation')}>{t('Send the invitation again')}</button>}
          {user.status === 'ACTIVE' && <button className="secondary" onClick={() => void act('send-password-reset')}>{t('Send a password reset link')}</button>}
          {['INVITED', 'ACTIVE', 'LOCKED'].includes(user.status) && <button className="secondary" onClick={() => void act('temporary-password', true)}>{t('Give a temporary password')}</button>}
        </div>
        <Notice ok={notice.ok} error={notice.error} />
      </section>
      {temporary && <TemporaryPassword value={temporary} />}
      <Form title="Details" submit="Save" onSubmit={async () => {
        await api('PATCH', `/users/${id}`, { displayNameEn: names.en, displayNameAr: names.ar, employeeCode: names.employeeCode, mobile: names.mobile }, etag);
        await load();
      }}>
        <Field label="Name (English)" value={names.en} onChange={v => setNames({ ...names, en: v })} />
        <Field label="Name (Arabic)" value={names.ar} onChange={v => setNames({ ...names, ar: v })} required={false} />
        <Field label="Employee code" value={names.employeeCode} onChange={v => setNames({ ...names, employeeCode: v })} required={false} />
        <Field label="Mobile" value={names.mobile} onChange={v => setNames({ ...names, mobile: v })} required={false} hint="In international form, such as +966 5…" />
      </Form>
      <Form title="Roles" submit="Save roles" onSubmit={async () => {
        await withStepUp('Giving the TM or FO role needs a fresh code.', code => api('PUT', `/users/${id}/roles`, { roleIds: picked, stepUpCode: code }, etag));
        await load();
      }}>
        <RolePicker roles={roles} value={picked} onChange={setPicked} />
      </Form>
      <Form title="Company scope" submit="Save scope" onSubmit={async () => {
        await api('PUT', `/users/${id}/company-scope`, { mode: user.companyScopeMode === 'ALL' ? 'SELECTED' : 'ALL', companies: [] }, etag);
        await load();
      }}>
        <p>{t(user.companyScopeMode === 'ALL' ? 'Sees every company.' : 'Sees only the companies chosen for them.')}</p>
        <p className="muted">{t('Companies are added in the companies module (S1).')}</p>
      </Form>
      <Form title="Products" submit="Save products" onSubmit={async () => {
        await api('PUT', `/users/${id}/product-scope`, { mode: productMode, modules: productMode === 'ALL' ? [] : products }, etag);
        await load();
      }}>
        <Select label="Products the user may use" value={productMode} onChange={setProductMode}
          options={[{ value: 'ALL', label: t('Every product of the account') }, { value: 'SELECTED', label: t('Only the products chosen below') }]} />
        {productMode === 'SELECTED' && PRODUCTS.map(p => (
          <label key={p} className="check">
            <input type="checkbox" checked={products.includes(p)} onChange={e => setProducts(e.target.checked ? [...products, p] : products.filter(x => x !== p))} />
            {t(p)}
          </label>
        ))}
        <p className="muted">{t('It narrows what the roles allow; the platform basics stay available.')}</p>
      </Form>
      <section className="card">
        <h2>{t('Sessions')}</h2>
        <Table rows={sessions} empty="No open session." columns={[
          { header: 'Started', cell: s => fmt.dateTime(s.createdAt) },
          { header: 'Last seen', cell: s => fmt.dateTime(s.lastSeenAt) },
          { header: 'Address', cell: s => <span dir="ltr">{s.ipAddress}</span> },
          { header: '', cell: s => <button className="link" onClick={async () => { await api('DELETE', `/users/${id}/sessions/${s.id}`); await load(); }}>{t('End')}</button> },
        ]} />
      </section>
    </>
  );
}
