import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-REQ-01 to 05 (spec 13 section 7): my requests, waiting for me and all requests; a new request; the request with
// its form generated from the template's fields, its visible phase, comments, attachments and timeline; and the
// actions the server says this user may take now. The requester's screen comes from the requester view, so it never
// shows the treasury's stage, assignee or internal notes (BR-WFL-024).

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 16).replace('T', ' ');
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

export function RequestList() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [view, setView] = useState('mine');
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const load = useCallback(async () => {
    const r = await api<{ items: Row[] }>('GET', `/requests?view=${view}${q ? `&q=${encodeURIComponent(q)}` : ''}`);
    setRows(r.items);
  }, [view, q]);
  useEffect(() => { void load(); }, [load]);
  const views = [{ value: 'mine', label: t('My requests') }, { value: 'tasks', label: t('Waiting for me') }];
  if (can(me, 'req.view.all') && can(me, 'req.view.internal')) views.push({ value: 'all', label: t('All requests') });
  return (
    <section className="card">
      <h1>{t('Requests')} {can(me, 'req.create') && <small><Link to="/requests/new">{t('New request')}</Link></small>}</h1>
      <div className="row">
        <Select label="View" value={view} onChange={setView} options={views} />
        <Field label="Search" value={q} onChange={setQ} required={false} />
      </div>
      <Table rows={rows} empty="No request here." columns={[
        { header: 'Number', cell: r => <Link to={`/requests/${str(r.id)}`} dir="ltr">{str(r.requestNo ?? r.draftRef)}</Link> },
        { header: 'Type', cell: r => pick(lang, r, 'typeName') },
        { header: 'Title', cell: r => str(r.title) },
        { header: 'Company', cell: r => pick(lang, r, 'companyName') },
        { header: 'Amount', cell: r => r.amount == null ? '' : <span dir="ltr">{str(r.amount)} {str(r.currency)}</span> },
        { header: 'Phase', cell: r => pick(lang, r, 'phaseName') },
        { header: 'Stage', cell: r => str(r.stage) },
        { header: 'Updated', cell: r => <span dir="ltr">{day(r.updatedAt ?? r.createdAt)}</span> },
      ]} />
    </section>
  );
}

export function NewRequest() {
  const { lang } = useI18n();
  const nav = useNavigate();
  const [types, setTypes] = useState<Row[]>([]);
  const [companies, setCompanies] = useState<Row[]>([]);
  const [type, setType] = useState('');
  const [company, setCompany] = useState('');
  const [title, setTitle] = useState('');
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/request-types').then(r => { setTypes(r.items); if (r.items[0]) setType(str(r.items[0].code)); });
    void api<{ items: Row[] }>('GET', '/companies').then(r => { setCompanies(r.items); if (r.items[0]) setCompany(str(r.items[0].id)); });
  }, []);
  return (
    <Form title="New request" submit="Create the draft" onSubmit={async () => {
      const r = await api<{ id: string }>('POST', '/requests', { type, company, data: title ? { title } : {} });
      nav(`/requests/${r.id}`);
    }}>
      <Select label="Request type" value={type} onChange={setType} options={types.map(x => ({ value: str(x.code), label: pick(lang, x, 'name') }))} />
      <Select label="Company" value={company} onChange={setCompany} options={companies.map(c => ({ value: str(c.id), label: pick(lang, c, 'name') }))} />
      <Field label="Title" value={title} onChange={setTitle} required={false} />
    </Form>
  );
}

interface FieldDef { key: string; labelAr: string; labelEn: string; type: string; required: boolean; editable: boolean; config?: { options?: string[] } }
interface Detail {
  view: 'REQUESTER' | 'STAFF';
  request: {
    id: string; draftRef: string; requestNo?: string; status: string; title?: string; amount?: number; currency?: string; head: Row; form: Record<string, unknown>;
    comments: Row[]; attachments: Row[]; timeline: Row[]; actions: string[]; fields: FieldDef[];
  };
  staff?: Row;
}

/** One input per field of the template (FR-REQ-002): text, long text, dates, numbers, lists and amounts with their currency. */
function FieldInput({ f, value, onChange }: { f: FieldDef; value: unknown; onChange: (v: unknown) => void }) {
  const { t, lang } = useI18n();
  const label = lang === 'ar' ? f.labelAr : f.labelEn;
  if (f.type === 'AMOUNT') {
    const a = (value ?? {}) as { value?: number; currency?: string };
    return (
      <div className="row">
        <Field label={label} type="number" value={a.value == null ? '' : String(a.value)} required={f.required}
          onChange={v => onChange({ ...a, value: v === '' ? undefined : Number(v), currency: a.currency ?? 'SAR' })} />
        <Field label="Currency" value={a.currency ?? 'SAR'} onChange={v => onChange({ ...a, currency: v.toUpperCase() })} />
      </div>
    );
  }
  if (f.type === 'LIST' && f.config?.options)
    return <Select label={label} value={str(value)} onChange={onChange} options={[{ value: '', label: t('Choose') }, ...f.config.options.map(o => ({ value: o, label: t(o) }))]} />;
  if (f.type === 'LONGTEXT')
    return <label>{label}<textarea value={str(value)} onChange={e => onChange(e.target.value)} rows={4} /></label>;
  const type = f.type === 'DATE' ? 'date' : f.type === 'DECIMAL' || f.type === 'INTEGER' || f.type === 'PERCENT' ? 'number' : 'text';
  return <Field label={label} type={type} value={str(value)} required={f.required}
    onChange={v => onChange(type === 'number' ? (v === '' ? undefined : Number(v)) : v)} />;
}

const actionLabels: Record<string, string> = {
  submit: 'Submit', resubmit: 'Resubmit', approve: 'Approve', return: 'Return', reject: 'Reject', claim: 'Claim', release: 'Release',
  complete: 'Complete', cancel: 'Cancel the request', close: 'Close the request',
};

export function RequestDetail() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [etag, setEtag] = useState('');
  const [form, setForm] = useState<Record<string, unknown>>({});
  const [comment, setComment] = useState('');
  const [note, setNote] = useState('');
  const [internal, setInternal] = useState(false);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const r = await apiWithETag<Detail>(`/requests/${id}`);
    setDetail(r.data);
    setEtag(r.etag);
    setForm(r.data.request.form);
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!detail) return null;
  const rq = detail.request;
  const editable = rq.fields.some(f => f.editable);
  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const act = (action: string) => run(() => api('POST', `/requests/${id}/actions/${action}`, { comment: comment || undefined }, etag), 'Done.');
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{rq.requestNo ?? rq.draftRef}</span> {pick(lang, rq.head, 'typeName')}</h1>
        <p>
          <strong>{pick(lang, rq.head, 'phaseName')}</strong>
          {rq.head.awaitingYou ? <> · <span className="warn">{t('Awaiting your action')}</span></> : null}
          {' · '}{pick(lang, rq.head, 'companyName')}
          {rq.amount != null && <> · <span dir="ltr">{str(rq.amount)} {str(rq.currency)}</span></>}
        </p>
        {rq.head.outcomeReason ? <p>{t('Reason')}: {str(rq.head.outcomeReason)}</p> : null}
        {detail.staff && (
          <p className="muted">
            {t('Stage')}: {pick(lang, detail.staff, 'stageName')} {detail.staff.subStatus ? `· ${t(str(detail.staff.subStatus))}` : ''}
            {detail.staff.assignee ? ` · ${t('Assigned to')} ${pick(lang, detail.staff, 'assigneeName')}` : ''}
            {detail.staff.dueAt ? <> · {t('Due')} <span dir="ltr">{day(detail.staff.dueAt)}</span></> : null}
          </p>
        )}
        <Notice {...notice} />
      </section>
      <section className="card">
        <h2>{t('The request')}</h2>
        {rq.fields.map(f => f.editable
          ? <FieldInput key={f.key} f={f} value={form[f.key]} onChange={v => setForm({ ...form, [f.key]: v })} />
          : form[f.key] != null && <p key={f.key}><strong>{lang === 'ar' ? f.labelAr : f.labelEn}</strong>: <span>{
              typeof form[f.key] === 'object' ? `${str((form[f.key] as Row).value)} ${str((form[f.key] as Row).currency)}` : str(form[f.key])}</span></p>)}
        {editable && <button type="button" onClick={() => run(async () => {
          await api('PATCH', `/requests/${id}`, { data: form }, etag);
        }, 'Saved.')}>{t('Save')}</button>}
      </section>
      {rq.actions.length > 0 && (
        <section className="card">
          <h2>{t('Actions')}</h2>
          <Field label="Reason or note" value={comment} onChange={setComment} required={false} />
          <div className="row">
            {rq.actions.map(a => <button key={a} type="button" className={a === 'reject' || a === 'cancel' ? 'danger' : ''} onClick={() => act(a)}>{t(actionLabels[a] ?? a)}</button>)}
          </div>
        </section>
      )}
      <section className="card">
        <h2>{t('Comments')}</h2>
        <Table rows={rq.comments} empty="No comment yet." columns={[
          { header: 'When', cell: r => <span dir="ltr">{day(r.at)}</span> },
          { header: 'By', cell: r => pick(lang, r, 'author') },
          { header: 'Comment', cell: r => r.retracted ? t('Withdrawn') : str(r.body) },
          ...(detail.view === 'STAFF' ? [{ header: 'Visibility', cell: (r: Row) => t(str(r.visibility)) }] : []),
        ]} />
        <Field label="New comment" value={note} onChange={setNote} required={false} />
        {detail.view === 'STAFF' && <label><input type="checkbox" checked={internal} onChange={e => setInternal(e.target.checked)} /> {t('Internal (not shown to the requester)')}</label>}
        <button type="button" disabled={!note} onClick={() => run(async () => {
          await api('POST', `/requests/${id}/comments`, { body: note, visibility: internal ? 'INTERNAL' : 'REQUESTER_VISIBLE' });
          setNote('');
        }, 'Saved.')}>{t('Add the comment')}</button>
      </section>
      <section className="card">
        <h2>{t('Attachments')}</h2>
        <Table rows={rq.attachments} empty="No attachment." columns={[
          { header: 'Document', cell: r => str(r.title) },
          { header: 'Slot', cell: r => t(str(r.slot)) },
          { header: 'When', cell: r => <span dir="ltr">{day(r.at)}</span> },
        ]} />
      </section>
      <section className="card">
        <h2>{t('Timeline')}</h2>
        <Table rows={rq.timeline} columns={[
          { header: 'When', cell: r => <span dir="ltr">{day(r.at)}</span> },
          { header: 'Event', cell: r => t(str(r.action)) },
          ...(detail.view === 'STAFF' ? [{ header: 'Stage', cell: (r: Row) => str(r.toStage ?? r.fromStage) }, { header: 'By', cell: (r: Row) => pick(lang, r, 'actor') }] : []),
          { header: 'Note', cell: r => str(r.comment) },
        ]} />
      </section>
    </>
  );
}
