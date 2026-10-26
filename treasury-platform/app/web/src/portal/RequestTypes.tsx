import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';

// The request types and their workflows as the tenant's administrator defines them (docs/31 row 73): the types by the
// screen they show on, a type of the tenant's own, its names and screen, who may raise it, its workflow drawn from steps
// and published by another user, and its activation. The seeded credit types keep their workflows.

interface Version { id: string; templateKey: string; versionNo: number; stages: number }
interface TypeRow {
  code: string; nameAr: string; nameEn: string; description?: string; category: string; isActive: boolean; sortOrder: number; isCustom: boolean;
  buildable: boolean; roles: string[]; departments: string[]; hasSequence: boolean; current: Version | null; draft: Version | null;
}
interface TemplateVersion { id: string; versionNo: number; status: string; isCurrent: boolean; publishedAt?: string; changeNote?: string; author?: string }
interface Stage { stageKey: string; kind: string; nameAr: string; nameEn: string; assigneeRule?: string; slaHours?: number; claimSlaHours?: number; slots?: string }
interface Role { code: string; nameAr: string; nameEn: string; isActive: boolean }
interface Department { code: string; nameAr: string; nameEn: string; isActive: boolean }
interface Step { subject: string; role: string; slaHours: string }

/** The screens a type shows on, in the order of the menu. */
export const SCREENS: { category: string; label: string }[] = [
  { category: 'PURCHASE', label: 'Import letters of credit' },
  { category: 'SALES', label: 'Export letters of credit' },
  { category: 'GENERAL', label: 'General requests' },
  { category: 'TREASURY', label: 'Other requests' },
  { category: 'CHILD', label: 'Requests on an issued letter of credit' },
];
const PICKABLE = SCREENS.filter(s => s.category !== 'CHILD');

function useTypes() {
  const [rows, setRows] = useState<TypeRow[]>([]);
  const load = useCallback(async () => setRows((await api<{ items: TypeRow[] }>('GET', '/request-type-definitions')).items), []);
  useEffect(() => { void load(); }, [load]);
  return { rows, load };
}

export function RequestTypes() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const { rows } = useTypes();
  const [draft, setDraft] = useState({ code: '', nameAr: '', nameEn: '', description: '', category: 'GENERAL', numberPrefix: '' });
  return (
    <>
      <section className="card">
        <h1>{t('Request types and workflows')}</h1>
        <p className="muted">{t('Each type shows on the screen of its category. A new workflow version is published by another user, and requests already submitted stay on their version.')}</p>
      </section>
      {SCREENS.map(s => {
        const list = rows.filter(r => r.category === s.category);
        if (list.length === 0) return null;
        return (
          <section className="card" key={s.category}>
            <h2>{t(s.label)}</h2>
            <Table rows={list} columns={[
              { header: 'Code', cell: r => <Link to={`/request-types/${r.code}`}>{r.code}</Link> },
              { header: 'Name', cell: r => lang === 'ar' ? r.nameAr : r.nameEn },
              { header: 'Status', cell: r => t(r.isActive ? 'Active' : 'Inactive') },
              { header: 'Workflow', cell: r => r.current ? `${t('Version')} ${r.current.versionNo} · ${r.current.stages} ${t('stages')}` : t('None') },
              { header: 'Draft', cell: r => r.draft ? `${t('Version')} ${r.draft.versionNo}` : '—' },
              { header: 'Who may raise it', cell: r => [...r.roles, ...r.departments].join(' · ') || '—' },
              { header: 'Source', cell: r => t(r.isCustom ? 'This account' : 'System') },
            ]} />
          </section>
        );
      })}
      <Form title="New request type" submit="Create the type" onSubmit={async () => {
        await api('POST', '/request-type-definitions', draft);
        nav(`/request-types/${draft.code.trim().toUpperCase()}`);
      }}>
        <Field label="Code" value={draft.code} onChange={v => setDraft({ ...draft, code: v })} hint="Capital letters, digits and underscores, e.g. BANK_GUARANTEE." />
        <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
        <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <Field label="Description" value={draft.description} onChange={v => setDraft({ ...draft, description: v })} required={false} />
        <Select label="Screen" value={draft.category} onChange={v => setDraft({ ...draft, category: v })} options={PICKABLE.map(s => ({ value: s.category, label: s.label }))} />
        <Field label="Number prefix" value={draft.numberPrefix} onChange={v => setDraft({ ...draft, numberPrefix: v })} hint="2 to 6 capital letters; the numbers read PREFIX-26-0001." />
      </Form>
    </>
  );
}

const SUBJECTS = [
  { value: 'REQUESTER_MANAGER', label: "The requester's manager" },
  { value: 'DEPARTMENT_HEAD', label: "The head of the requester's department" },
  { value: 'ROLE', label: 'A role' },
];

export function RequestTypeDetail() {
  const { code } = useParams();
  const { t, lang } = useI18n();
  const { rows, load } = useTypes();
  const type = rows.find(r => r.code === code);
  const [roles, setRoles] = useState<Role[]>([]);
  const [departments, setDepartments] = useState<Department[]>([]);
  const [versions, setVersions] = useState<TemplateVersion[]>([]);
  const [stages, setStages] = useState<Stage[]>([]);
  const [names, setNames] = useState({ nameAr: '', nameEn: '', description: '', category: '', sortOrder: '' });
  const [audience, setAudience] = useState<{ roles: string[]; departments: string[] }>({ roles: [], departments: [] });
  const [steps, setSteps] = useState<Step[]>([]);
  const [queue, setQueue] = useState({ treasuryRole: '', claimSlaHours: '4', executionSlaHours: '24', changeNote: '' });
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  useEffect(() => {
    api<{ items: Role[] }>('GET', '/roles').then(r => setRoles(r.items.filter(x => x.isActive))).catch(() => setRoles([]));
    api<{ items: Department[] }>('GET', '/departments').then(r => setDepartments(r.items.filter(x => x.isActive))).catch(() => setDepartments([]));
  }, []);
  const loadVersions = useCallback(async () => {
    if (!code) return;
    const d = await api<{ versions: TemplateVersion[] }>('GET', `/request-type-definitions/${code}`);
    setVersions(d.versions);
  }, [code]);
  useEffect(() => { void loadVersions(); }, [loadVersions]);
  useEffect(() => {
    if (!type) return;
    setNames({ nameAr: type.nameAr, nameEn: type.nameEn, description: type.description ?? '', category: type.category, sortOrder: String(type.sortOrder) });
    setAudience({ roles: type.roles, departments: type.departments });
    const shown = type.draft ?? type.current;
    if (shown) api<{ stages: Stage[] }>('GET', `/templates/${shown.id}`).then(g => setStages(g.stages)).catch(() => setStages([]));
    else setStages([]);
  }, [type]);
  if (!type) return null;

  const name = (x: { nameAr: string; nameEn: string }) => lang === 'ar' ? x.nameAr : x.nameEn;
  const reload = async (note: string) => { await load(); await loadVersions(); setOk(note); };
  const act = async (f: () => Promise<unknown>, note: string) => {
    setError(null); setOk(null);
    try { await f(); await reload(note); } catch (e) { setError(message(e)); }
  };
  const toggle = (list: string[], v: string, on: boolean) => on ? [...list, v] : list.filter(x => x !== v);

  return (
    <>
      <section className="card">
        <h1>{type.code} · {name(type)}</h1>
        <p>{t(SCREENS.find(s => s.category === type.category)?.label ?? type.category)} · {t(type.isActive ? 'Active' : 'Inactive')}
          {!type.hasSequence && <> · <span className="error">{t('No active number sequence')}</span></>}</p>
        <Notice error={error} ok={ok} />
        {type.isActive
          ? <button type="button" onClick={() => act(() => api('POST', `/request-type-definitions/${code}/actions/deactivate`, {}), 'The type is inactive.')}>{t('Deactivate')}</button>
          : <button type="button" onClick={() => act(() => api('POST', `/request-type-definitions/${code}/actions/activate`, {}), 'The type is active.')}>{t('Activate')}</button>}
      </section>

      <Form title="Names and screen" submit="Save" onSubmit={async () => {
        await api('PATCH', `/request-type-definitions/${code}`, {
          nameAr: names.nameAr, nameEn: names.nameEn, description: names.description || null,
          category: names.category === type.category ? null : names.category, sortOrder: Number(names.sortOrder) || null,
        });
        await reload('Saved.');
      }}>
        <Field label="Name (English)" value={names.nameEn} onChange={v => setNames({ ...names, nameEn: v })} />
        <Field label="Name (Arabic)" value={names.nameAr} onChange={v => setNames({ ...names, nameAr: v })} />
        <Field label="Description" value={names.description} onChange={v => setNames({ ...names, description: v })} required={false} />
        {type.category !== 'CHILD' && (type.isCustom || !['PURCHASE', 'SALES'].includes(type.category)) &&
          <Select label="Screen" value={names.category} onChange={v => setNames({ ...names, category: v })} options={PICKABLE.map(s => ({ value: s.category, label: s.label }))} />}
        <Field label="Order" type="number" value={names.sortOrder} onChange={v => setNames({ ...names, sortOrder: v })} />
      </Form>

      <Form title="Who may raise it" submit="Save the audience" onSubmit={async () => {
        await api('PUT', `/request-type-definitions/${code}/audience`, audience);
        await reload('Saved.');
      }}>
        <div className="grid">
          <fieldset>
            <legend>{t('Roles')}</legend>
            {roles.map(r => (
              <label key={r.code} className="check">
                <input type="checkbox" checked={audience.roles.includes(r.code)} onChange={e => setAudience({ ...audience, roles: toggle(audience.roles, r.code, e.target.checked) })} />
                {name(r)} <small className="muted">{r.code}</small>
              </label>
            ))}
          </fieldset>
          <fieldset>
            <legend>{t('Departments')}</legend>
            {departments.length === 0 && <p className="muted">{t('Nothing here yet.')}</p>}
            {departments.map(d => (
              <label key={d.code} className="check">
                <input type="checkbox" checked={audience.departments.includes(d.code)}
                  onChange={e => setAudience({ ...audience, departments: toggle(audience.departments, d.code, e.target.checked) })} />
                {name(d)} <small className="muted">{d.code}</small>
              </label>
            ))}
          </fieldset>
        </div>
      </Form>

      <section className="card">
        <h2>{t(type.draft ? 'The draft workflow' : 'The current workflow')}</h2>
        {stages.length === 0 ? <p className="muted">{t('No workflow yet.')}</p> : (
          <ol className="workflow-chain">
            {stages.filter(s => s.kind !== 'TERMINAL' || s.stageKey === 'COMPLETED').map(s => (
              <li key={s.stageKey}>
                <strong>{name(s)}</strong>
                <small className="muted"> · {t(s.kind)}{s.slaHours ? ` · ${s.slaHours} ${t('hours')}` : ''}{s.claimSlaHours ? ` · ${t('claim within')} ${s.claimSlaHours} ${t('hours')}` : ''}</small>
              </li>
            ))}
          </ol>
        )}
        <Table rows={versions} columns={[
          { header: 'Version', cell: v => v.versionNo },
          { header: 'Status', cell: v => t(v.status) + (v.isCurrent ? ` · ${t('current')}` : '') },
          { header: 'Note', cell: v => v.changeNote ?? '—' },
          { header: 'Written by', cell: v => v.author ?? '—' },
          { header: '', cell: v => v.status === 'DRAFT'
            ? <button type="button" onClick={() => act(() => api('POST', `/templates/${v.id}/actions/publish`, {}), 'Published.')}>{t('Publish')}</button> : null },
        ]} />
      </section>

      {type.buildable ? (
        <Form title="A new workflow version" submit="Save as a draft" onSubmit={async () => {
          await api('POST', `/request-type-definitions/${code}/workflow`, {
            approvals: steps.map(s => ({ subject: s.subject, role: s.subject === 'ROLE' ? s.role : null, slaHours: Number(s.slaHours) || null })),
            treasuryRole: queue.treasuryRole || null, claimSlaHours: Number(queue.claimSlaHours) || null,
            executionSlaHours: Number(queue.executionSlaHours) || null, changeNote: queue.changeNote || null,
          });
          setSteps([]);
          await reload('The draft is saved. Another user publishes it.');
        }}>
          <p className="muted">{t('The request goes through the approvals in order, then to the treasury queue, then to execution by the person who claims it. A return goes back to the requester and then to the same approval.')}</p>
          {steps.map((s, i) => (
            <fieldset key={i}>
              <legend>{t('Approval')} {i + 1}</legend>
              <Select label="Approved by" value={s.subject} onChange={v => setSteps(steps.map((x, j) => j === i ? { ...x, subject: v } : x))} options={SUBJECTS} />
              {s.subject === 'ROLE' &&
                <Select label="Role" value={s.role} onChange={v => setSteps(steps.map((x, j) => j === i ? { ...x, role: v } : x))}
                  options={[{ value: '', label: '—' }, ...roles.map(r => ({ value: r.code, label: `${name(r)} (${r.code})` }))]} />}
              <Field label="Hours to approve" type="number" value={s.slaHours} onChange={v => setSteps(steps.map((x, j) => j === i ? { ...x, slaHours: v } : x))} />
              <button type="button" className="secondary" onClick={() => setSteps(steps.filter((_, j) => j !== i))}>{t('Remove')}</button>
            </fieldset>
          ))}
          {steps.length < 5 && <button type="button" className="secondary" onClick={() => setSteps([...steps, { subject: 'REQUESTER_MANAGER', role: '', slaHours: '8' }])}>{t('Add an approval')}</button>}
          <Select label="Treasury people of this type" value={queue.treasuryRole} onChange={v => setQueue({ ...queue, treasuryRole: v })}
            options={[{ value: '', label: 'Everyone who may claim requests' }, ...roles.map(r => ({ value: r.code, label: `${name(r)} (${r.code})` }))]} />
          <Field label="Hours to claim" type="number" value={queue.claimSlaHours} onChange={v => setQueue({ ...queue, claimSlaHours: v })} />
          <Field label="Hours to execute" type="number" value={queue.executionSlaHours} onChange={v => setQueue({ ...queue, executionSlaHours: v })} />
          <Field label="Note of the change" value={queue.changeNote} onChange={v => setQueue({ ...queue, changeNote: v })} required={false} />
        </Form>
      ) : (
        <section className="card"><p className="muted">{t('This type keeps its seeded workflow: its stages act on the letters of credit.')}</p></section>
      )}
    </>
  );
}
