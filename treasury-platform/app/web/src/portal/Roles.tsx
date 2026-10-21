import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Table } from '../ui';

interface RoleRow { id: string; code: string; nameEn: string; nameAr: string; isSystem: boolean; isActive: boolean; users: number; permissions: number }
interface Permission { code: string; module: string; nameEn: string; nameAr: string; isSensitive: boolean; lockedToRoleCodes?: string | null }
interface Role { id: string; code: string; nameEn: string; nameAr: string; description?: string; isSystem: boolean; isActive: boolean; permissions: string[] }

function usePermissions() {
  const [items, setItems] = useState<Permission[]>([]);
  useEffect(() => { api<{ items: Permission[] }>('GET', '/permissions').then(r => setItems(r.items)).catch(() => setItems([])); }, []);
  return items;
}

/** The permission catalogue by module; a permission locked to other roles cannot be ticked (BR-PLT-019). */
function PermissionGrid({ all, value, onChange, roleCode, isSystem }: { all: Permission[]; value: string[]; onChange: (v: string[]) => void; roleCode: string; isSystem: boolean }) {
  const { lang, t } = useI18n();
  const byModule = useMemo(() => Object.entries(all.reduce<Record<string, Permission[]>>((acc, p) => { (acc[p.module] ??= []).push(p); return acc; }, {})), [all]);
  return (
    <div className="grid">
      {byModule.map(([module, perms]) => (
        <fieldset key={module}>
          <legend>{module}</legend>
          {perms.map(p => {
            const locked = p.lockedToRoleCodes ? !(isSystem && (JSON.parse(p.lockedToRoleCodes) as string[]).includes(roleCode)) : false;
            return (
              <label key={p.code} className="check" title={locked ? t('Locked by the platform to TM and FO') : p.code}>
                <input type="checkbox" disabled={locked} checked={value.includes(p.code)}
                  onChange={e => onChange(e.target.checked ? [...value, p.code] : value.filter(x => x !== p.code))} />
                {lang === 'ar' ? p.nameAr : p.nameEn}{p.isSensitive && <small className="muted"> · {t('sensitive')}</small>}
              </label>
            );
          })}
        </fieldset>
      ))}
    </div>
  );
}

export function Roles() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const all = usePermissions();
  const [rows, setRows] = useState<RoleRow[]>([]);
  const [draft, setDraft] = useState({ code: '', nameEn: '', nameAr: '', permissions: [] as string[] });
  const load = useCallback(async () => setRows((await api<{ items: RoleRow[] }>('GET', '/roles')).items), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Roles')}</h1>
        <Table rows={rows} columns={[
          { header: 'Code', cell: r => <Link to={`/roles/${r.id}`}>{r.code}</Link> },
          { header: 'Name', cell: r => lang === 'ar' ? r.nameAr : r.nameEn },
          { header: 'Type', cell: r => t(r.isSystem ? 'System' : 'Account') },
          { header: 'Users', cell: r => r.users },
          { header: 'Permissions', cell: r => r.permissions },
        ]} />
      </section>
      <Form title="New role" submit="Create the role" onSubmit={async () => {
        const r = await api<{ id: string }>('POST', '/roles', draft);
        nav(`/roles/${r.id}`);
      }}>
        <Field label="Code" value={draft.code} onChange={v => setDraft({ ...draft, code: v })} />
        <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
        <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <PermissionGrid all={all} value={draft.permissions} onChange={v => setDraft({ ...draft, permissions: v })} roleCode={draft.code.toUpperCase()} isSystem={false} />
      </Form>
    </>
  );
}

export function RoleDetail() {
  const { id } = useParams();
  const { t } = useI18n();
  const nav = useNavigate();
  const all = usePermissions();
  const [role, setRole] = useState<Role | null>(null);
  const [etag, setEtag] = useState('');
  const [picked, setPicked] = useState<string[]>([]);
  const [names, setNames] = useState({ nameEn: '', nameAr: '' });
  const [copy, setCopy] = useState({ code: '', nameEn: '', nameAr: '' });
  const load = useCallback(async () => {
    const { data, etag: tag } = await apiWithETag<Role>(`/roles/${id}`);
    setRole(data);
    setEtag(tag);
    setPicked(data.permissions);
    setNames({ nameEn: data.nameEn, nameAr: data.nameAr });
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!role) return null;
  return (
    <>
      <Form title={`${role.code}`} submit="Save" onSubmit={async () => { await api('PATCH', `/roles/${id}`, names, etag); await load(); }}>
        <p className="muted">{t(role.isSystem ? 'A system role: its code is fixed and it stays active.' : 'A role of this account.')}</p>
        <Field label="Name (English)" value={names.nameEn} onChange={v => setNames({ ...names, nameEn: v })} />
        <Field label="Name (Arabic)" value={names.nameAr} onChange={v => setNames({ ...names, nameAr: v })} />
      </Form>
      <Form title="Permissions" submit="Save permissions" onSubmit={async () => { await api('PUT', `/roles/${id}/permissions`, { permissions: picked }, etag); await load(); }}>
        <PermissionGrid all={all} value={picked} onChange={setPicked} roleCode={role.code} isSystem={role.isSystem} />
      </Form>
      <Form title="Copy this role" submit="Copy" onSubmit={async () => { const r = await api<{ id: string }>('POST', `/roles/${id}/actions/copy`, copy); nav(`/roles/${r.id}`); }}>
        <Field label="Code" value={copy.code} onChange={v => setCopy({ ...copy, code: v })} />
        <Field label="Name (English)" value={copy.nameEn} onChange={v => setCopy({ ...copy, nameEn: v })} />
        <Field label="Name (Arabic)" value={copy.nameAr} onChange={v => setCopy({ ...copy, nameAr: v })} />
      </Form>
    </>
  );
}
