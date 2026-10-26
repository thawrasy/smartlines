import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { AttachForm, DownloadButton, PdfButton, useDocTypes } from './Attach';
import { can, useMe } from './Portal';

// SCR-REQ-01 to 05 (spec 13 section 7): my requests, waiting for me and all requests; a new request; the request with
// its form generated from the template's fields, its visible phase, comments, attachments and timeline; and the
// actions the server says this user may take now. The requester's screen comes from the requester view, so it never
// shows the treasury's stage, assignee or internal notes (BR-WFL-024).

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 16).replace('T', ' ');
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

/** The screens of the request categories (docs/31 row 73): each shows the request types of its category only. */
export const CATEGORY_SCREENS: Record<string, string> = {
  PURCHASE: 'Import letters of credit', SALES: 'Export letters of credit', GENERAL: 'General requests', TREASURY: 'Other requests',
};

export function RequestList() {
  const { t, lang } = useI18n();
  const me = useMe();
  const { category = '' } = useParams();
  const [view, setView] = useState('mine');
  const [mineOnly, setMineOnly] = useState(false);
  const [q, setQ] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const query = `/requests?view=${view}${category ? `&category=${category}` : ''}${view === 'execution' && mineOnly ? '&assignee=me' : ''}${q ? `&q=${encodeURIComponent(q)}` : ''}`;
  const load = useCallback(async () => setRows((await api<{ items: Row[] }>('GET', query)).items), [query]);
  useEffect(() => { void load(); }, [load]);
  const views = [{ value: 'mine', label: t('My requests') }, { value: 'tasks', label: t('Waiting for me') }];
  if (can(me, 'req.view.all') && can(me, 'req.view.internal')) {
    // The treasury's screens: before the treasury, arrived and not taken, and in execution (the manager sees all, staff may keep theirs).
    views.push({ value: 'pending', label: t('Awaiting approval') }, { value: 'incoming', label: t('Incoming to the treasury') },
      { value: 'execution', label: t('In execution') }, { value: 'all', label: t('All requests') });
  }
  const title = category ? CATEGORY_SCREENS[category] ?? 'Requests' : 'Requests';
  return (
    <section className="card">
      <h1>{t(title)} {can(me, 'req.create') && <small><Link to={category ? `/requests/new?category=${category}` : '/requests/new'}>{t('New request')}</Link></small>}</h1>
      <div className="row">
        <Select label="View" value={view} onChange={setView} options={views} />
        <Field label="Search" value={q} onChange={setQ} required={false} />
        {view === 'execution' && (
          <label className="check"><input type="checkbox" checked={mineOnly} onChange={e => setMineOnly(e.target.checked)} />{t('Only the ones I hold')}</label>
        )}
      </div>
      <p><a href={`/api/v1${query}&format=csv`} download>{t('Export as CSV')}</a></p>
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
  const [params] = useSearchParams();
  const category = params.get('category') ?? '';
  const [types, setTypes] = useState<Row[]>([]);
  const [companies, setCompanies] = useState<Row[]>([]);
  const [type, setType] = useState('');
  const [company, setCompany] = useState('');
  const [title, setTitle] = useState('');
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/request-types').then(r => {
      const list = category ? r.items.filter(x => x.category === category) : r.items;
      setTypes(list);
      if (list[0]) setType(str(list[0].code));
    });
    void api<{ items: Row[] }>('GET', '/companies').then(r => { setCompanies(r.items); if (r.items[0]) setCompany(str(r.items[0].id)); });
  }, [category]);
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

interface FieldDef { key: string; labelAr: string; labelEn: string; type: string; required: boolean; editable: boolean; config?: { options?: string[]; component?: string } }
interface Detail {
  view: 'REQUESTER' | 'STAFF';
  request: {
    id: string; draftRef: string; requestNo?: string; status: string; title?: string; amount?: number; currency?: string; head: Row; form: Record<string, unknown>;
    comments: Row[]; attachments: Row[]; slots?: Row[]; canAttach?: boolean; timeline: Row[]; actions: string[]; fields: FieldDef[];
    references?: Row[]; canAddReference?: boolean;
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
  const me = useMe();
  const nav = useNavigate();
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
  // Module forms (the terms, the proforma and its issue) have their own screens, linked above.
  const fields = rq.fields.filter(f => f.type !== 'MODULE_FORM');
  const editable = fields.some(f => f.editable);
  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const act = (action: string) => run(() => api('POST', `/requests/${id}/actions/${action}`, { comment: comment || undefined }, etag), 'Done.');
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{rq.requestNo ?? rq.draftRef}</span> {pick(lang, rq.head, 'typeName')}</h1>
        {rq.fields.some(f => f.type === 'MODULE_FORM' && f.config?.component === 'lc.proforma') && (
          <p><Link to={`/requests/${id}/proforma`}>{t('The proforma')}</Link></p>
        )}
        {rq.fields.some(f => f.type === 'MODULE_FORM' && f.config?.component === 'lc.terms') && (
          <p><Link to={`/requests/${id}/terms`}>{t('Letter of credit terms')}</Link></p>
        )}
        <p>
          <strong>{pick(lang, rq.head, 'phaseName')}</strong>
          {rq.head.awaitingYou ? <> · <span className="warn">{t('Awaiting your action')}</span></> : null}
          {' · '}{pick(lang, rq.head, 'companyName')}
          {rq.amount != null && <> · <span dir="ltr">{str(rq.amount)} {str(rq.currency)}</span></>}
        </p>
        {rq.head.outcomeReason ? <p>{t('Reason')}: {str(rq.head.outcomeReason)}</p> : null}
        {can(me, 'req.create') && !rq.head.parentEntityType && (
          <p><button type="button" className="secondary" onClick={() => run(async () => {
            const r = await api<{ id: string }>('POST', `/requests/${id}/copy`);
            nav(`/requests/${r.id}`);
          }, 'Done.')}>{t('Copy into a new request')}</button></p>
        )}
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
        {fields.map(f => f.editable
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
      <References id={id ?? ''} rows={rq.references ?? []} canAdd={!!rq.canAddReference} onDone={load} />
      <section className="card">
        <h2>{t('Attachments')}</h2>
        <Table rows={rq.attachments} empty="No attachment." columns={[
          { header: 'Document', cell: r => str(r.title) },
          { header: 'Type', cell: r => t(str(r.documentType)) },
          { header: 'Slot', cell: r => t(str(r.slot)) },
          { header: 'When', cell: r => <span dir="ltr">{day(r.at)}</span> },
          { header: '', cell: r => r.scanStatus === 'CLEAN' ? <DownloadButton id={str(r.document)} name={str(r.fileName)} /> : <span className="muted">{t(str(r.scanStatus))}</span> },
        ]} />
        {(rq.slots ?? []).length > 0 && (
          <Table rows={rq.slots ?? []} columns={[
            { header: 'Slot', cell: r => pick(lang, r, 'label') || str(r.slot) },
            { header: 'Type', cell: r => t(str(r.documentType)) },
            { header: 'Attached', cell: r => `${str(r.count)}${r.maxCount ? ' / ' + str(r.maxCount) : ''}` },
            { header: 'Required', cell: r => Number(r.minCount) > 0 ? <span className={Number(r.count) < Number(r.minCount) ? 'warn' : ''}>{t('Before')} {str(r.requiredBefore)}</span> : '' },
          ]} />
        )}
        {rq.canAttach && <RequestUpload id={id} slots={rq.slots ?? []} onDone={load} />}
        <div className="row">
          <a href={`/api/v1/requests/${id}/print?lang=${lang}`} target="_blank" rel="noreferrer">{t('Print the request')}</a>
          <PdfButton path={`/requests/${id}/print?lang=${lang}`} name={`request-${rq.requestNo ?? rq.draftRef}.pdf`} />
          {rq.canAttach && <button type="button" className="secondary" onClick={() => run(() => api('POST', `/requests/${id}/print/save`), 'The PDF is saved with the request.')}>{t('Save the PDF with the request')}</button>}
        </div>
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

const REQUEST_TYPES = ['AUTHORITY_APPROVAL', 'SIGNED_REQUEST_ORIGINAL', 'SUPPLIER_PROFORMA', 'PURCHASE_ORDER_COPY', 'SALES_ORDER_COPY', 'LC_COPY', 'LC_SWIFT_COPY',
  'LC_AMENDMENT_COPY', 'LC_AMENDMENT_ADVICE', 'BANK_ACKNOWLEDGEMENT', 'COLLECTION_DOCS_PACKAGE', 'OTHER'];

/** FR-REQ-006 and docs/31 row 52: a file into one of the template's slots, or as an extra attachment of a chosen type. */
function RequestUpload({ id, slots, onDone }: { id: string; slots: Row[]; onDone: () => Promise<void> }) {
  const { t, lang } = useI18n();
  const [slot, setSlot] = useState('');
  const types = useDocTypes(REQUEST_TYPES);
  const s = slots.find(x => str(x.slot) === slot);
  return (
    <>
      <Select label="Where" value={slot} onChange={setSlot} options={[{ value: '', label: t('An extra attachment') },
        ...slots.map(x => ({ value: str(x.slot), label: pick(lang, x, 'label') || str(x.slot) }))]} />
      <AttachForm path={`/requests/${id}/attachments/upload`} types={s ? undefined : types} fixedType={s ? str(s.documentType) : undefined}
        extra={slot ? { slot } : undefined} onDone={onDone} />
    </>
  );
}

/** The reference kinds of a request (docs/31 row 72): the system that issued it and what it is; "other" takes both as typed. */
const REFERENCE_KINDS: { value: string; label: string; system: string; kind: string }[] = [
  { value: 'ERP', label: 'ERP reference', system: 'ERP', kind: 'ERP_REFERENCE' },
  { value: 'LC_NUMBER', label: "The bank's letter of credit number", system: 'BANK', kind: 'LC_NUMBER' },
  { value: 'BANK_REFERENCE', label: "The bank's reference", system: 'BANK', kind: 'BANK_REFERENCE' },
  { value: 'BENEFICIARY_BANK', label: "The beneficiary bank's reference", system: 'BENEFICIARY_BANK', kind: 'BANK_REFERENCE' },
  { value: 'OTHER', label: 'Another reference', system: '', kind: '' },
];

/** The request's reference registry: the current reference of each kind, the earlier ones kept as history, and a new one. */
function References({ id, rows, canAdd, onDone }: { id: string; rows: Row[]; canAdd: boolean; onDone: () => Promise<void> }) {
  const { t, lang } = useI18n();
  const [kind, setKind] = useState('ERP');
  const [system, setSystem] = useState('');
  const [other, setOther] = useState('');
  const [value, setValue] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const label = (r: Row) => {
    const k = REFERENCE_KINDS.find(x => x.system === r.system && x.kind === r.kind);
    return k ? t(k.label) : `${str(r.system)} · ${str(r.kind)}`;
  };
  return (
    <section className="card">
      <h2>{t('References')}</h2>
      <Table rows={rows} empty="No reference yet." columns={[
        { header: 'Reference', cell: r => label(r) },
        { header: 'Value', cell: r => <span dir="ltr" className={r.isCurrent ? '' : 'muted'}>{str(r.value)}</span> },
        { header: 'Status', cell: r => t(r.isCurrent ? 'Current' : 'Replaced') },
        { header: 'By', cell: r => pick(lang, r, 'by') },
        { header: 'When', cell: r => <span dir="ltr">{day(r.at)}</span> },
      ]} />
      {canAdd && (
        <div className="row">
          <Select label="Reference" value={kind} onChange={setKind} options={REFERENCE_KINDS.map(k => ({ value: k.value, label: k.label }))} />
          {kind === 'OTHER' && <Field label="Issued by" value={system} onChange={setSystem} />}
          {kind === 'OTHER' && <Field label="Kind" value={other} onChange={setOther} />}
          <Field label="Value" value={value} onChange={setValue} />
          <button type="button" disabled={!value} onClick={async () => {
            setNotice({});
            const k = REFERENCE_KINDS.find(x => x.value === kind)!;
            try {
              const r = await api<{ warning?: string }>('POST', `/requests/${id}/external-refs`,
                { systemCode: k.value === 'OTHER' ? system : k.system, refType: k.value === 'OTHER' ? other : k.kind, value });
              setValue('');
              await onDone();
              setNotice({ ok: r.warning ? 'Saved. The same reference is on another open request.' : 'Saved.' });
            } catch (e) { setNotice({ error: message(e) }); }
          }}>{t('Add the reference')}</button>
        </div>
      )}
      <Notice ok={notice.ok} error={notice.error} />
    </section>
  );
}
