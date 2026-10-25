import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, downloadGet, message, upload } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { useMe } from './Portal';
import { GovernancePanel, GrantsPanel, OwnershipPanel, seesStructure } from './Structure';

// Screens 13, 14 and 18 of spec 10: the companies as a tree, the company screen with its tabs (general, finance and
// tax, addresses and contacts, documents), and the register of company documents across companies (FR-ORG-011).

interface Company {
  id: string; companyCode: string; nameAr: string; nameEn: string; partyCode: string; legalForm: { code: string; nameAr?: string; nameEn?: string };
  isHolding: boolean; parent?: string; country: string; industry?: string; status: string; establishedOn?: string; crNumber?: string; crDate?: string;
  crDateHijri?: string; erpCompanyCode?: string; refCode?: string | null; fiscalYearEndMonth: number; fiscalYearEndDay?: number; baseCurrency?: string; ownershipStatus: string; etag: string;
}
interface Doc {
  id: string; type: { code: string; nameAr: string; nameEn?: string }; title: string; documentNumber?: string; expiryDate?: string; validity: string;
  daysLeft?: number; company?: { id: string; nameAr: string; nameEn: string }; version?: number; fileName?: string; scanStatus?: string; sensitivity: string;
}
interface Option { code: string; nameAr: string; nameEn?: string }

const name = (lang: string, x: { nameAr?: string; nameEn?: string }) => (lang === 'ar' ? x.nameAr : x.nameEn) ?? x.nameAr ?? x.nameEn ?? '';

function useOptions(path: string) {
  const [items, setItems] = useState<Option[]>([]);
  useEffect(() => { api<{ items: Option[] }>('GET', path).then(r => setItems(r.items)).catch(() => setItems([])); }, [path]);
  return items;
}

// ---------- the list as a tree ----------

export function Companies() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const [items, setItems] = useState<Company[]>([]);
  const [q, setQ] = useState('');
  const [archived, setArchived] = useState(false);
  const forms = useOptions('/catalogs/legal-entity-types');
  const [draft, setDraft] = useState({ companyCode: '', refCode: '', nameAr: '', nameEn: '', legalForm: 'LLC', country: 'SA', parent: '', crNumber: '', fiscalYearEndMonth: '12' });
  const load = useCallback(async () => {
    const params = new URLSearchParams();
    if (q) params.set('q', q);
    if (archived) params.set('includeArchived', 'true');
    setItems((await api<{ items: Company[] }>('GET', `/companies${params.size ? '?' + params : ''}`)).items);
  }, [q, archived]);
  useEffect(() => { void load(); }, [load]);
  // Depth first, children under their parent; a company whose parent is outside the list starts a branch.
  const ids = new Set(items.map(c => c.id));
  const rows: { c: Company; depth: number }[] = [];
  const walk = (parent: string | undefined, depth: number) =>
    items.filter(c => (parent ? c.parent === parent : !c.parent || !ids.has(c.parent))).forEach(c => { rows.push({ c, depth }); walk(c.id, depth + 1); });
  walk(undefined, 0);
  return (
    <>
      <section className="card">
        <h1>{t('Companies')}</h1>
        <div className="actions">
          <input placeholder={t('Search by name, code, registration or ERP code')} value={q} onChange={e => setQ(e.target.value)} />
          <label><input type="checkbox" checked={archived} onChange={e => setArchived(e.target.checked)} /> {t('Show archived')}</label>
        </div>
        <Table rows={rows} columns={[
          { header: 'Code', cell: r => <span style={{ paddingInlineStart: `${r.depth * 1.5}rem` }}><Link to={`/companies/${r.c.id}`} dir="ltr">{r.c.companyCode}</Link></span> },
          { header: 'Name', cell: r => name(lang, r.c) },
          { header: 'Legal form', cell: r => name(lang, r.c.legalForm) },
          { header: 'Status', cell: r => <Chip s={r.c.status} /> },
          { header: 'Holding', cell: r => r.c.isHolding ? t('Yes') : '' },
          { header: 'Ownership', cell: r => t(r.c.ownershipStatus) },
        ]} />
      </section>
      <Form title="New company" submit="Create" onSubmit={async () => {
        const r = await api<{ id: string }>('POST', '/companies', {
          ...draft, parent: draft.parent || undefined, crNumber: draft.crNumber || undefined, refCode: draft.refCode || undefined, fiscalYearEndMonth: Number(draft.fiscalYearEndMonth),
        });
        nav(`/companies/${r.id}`);
      }}>
        <Field label="Company code" value={draft.companyCode} onChange={v => setDraft({ ...draft, companyCode: v.toUpperCase() })} hint="Capital letters, digits, - and _; it cannot change later." />
        <Field label="Reference code" value={draft.refCode} onChange={v => setDraft({ ...draft, refCode: v.toUpperCase() })} required={false}
          hint="Two or three characters in the facility references (IMP-SNB-CAP-26); left empty, the company code when it has that shape." />
        <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
        <Select label="Legal form" value={draft.legalForm} onChange={v => setDraft({ ...draft, legalForm: v })} options={forms.map(f => ({ value: f.code, label: name(lang, f) }))} />
        <Field label="Country" value={draft.country} onChange={v => setDraft({ ...draft, country: v.toUpperCase() })} />
        <Select label="Parent company" value={draft.parent} onChange={v => setDraft({ ...draft, parent: v })}
          options={[{ value: '', label: '—' }, ...items.filter(c => c.status !== 'ARCHIVED').map(c => ({ value: c.id, label: `${c.companyCode} · ${name(lang, c)}` }))]} />
        <Field label="Commercial registration" value={draft.crNumber} onChange={v => setDraft({ ...draft, crNumber: v })} required={false} />
        <Field label="Fiscal year ends in month (1 to 12)" value={draft.fiscalYearEndMonth} onChange={v => setDraft({ ...draft, fiscalYearEndMonth: v })} />
      </Form>
    </>
  );
}

// ---------- the company screen ----------

export function CompanyDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [tab, setTab] = useState<'general' | 'finance' | 'contacts' | 'documents' | 'ownership' | 'governance' | 'grants'>('general');
  const [c, setC] = useState<Company | null>(null);
  const [etag, setEtag] = useState('');
  const load = useCallback(async () => {
    const r = await apiWithETag<{ company: Company }>(`/companies/${id}`);
    setC(r.data.company);
    setEtag(r.etag);
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!c) return null;
  return (
    <>
      <section className="card">
        <h1>{name(lang, c)} <small dir="ltr">({c.companyCode})</small></h1>
        <p className="muted">{t('Status')}: {t(c.status)} · {t('Party code')}: <span dir="ltr">{c.partyCode}</span></p>
        <div className="actions" role="tablist">
          {(['general', 'finance', 'contacts', 'documents', ...(seesStructure(me) ? ['ownership', 'governance', 'grants'] as const : [])] as const).map(k => (
            <button key={k} role="tab" aria-selected={tab === k} className={tab === k ? '' : 'secondary'} onClick={() => setTab(k)}>
              {t({ general: 'General', finance: 'Finance and tax', contacts: 'Addresses and contacts', documents: 'Documents', ownership: 'Ownership', governance: 'Governance', grants: 'Authorities' }[k])}
            </button>
          ))}
        </div>
      </section>
      {tab === 'general' && <General c={c} etag={etag} onSaved={load} />}
      {tab === 'finance' && <Finance c={c} etag={etag} onSaved={load} />}
      {tab === 'contacts' && <Contacts c={c} />}
      {tab === 'documents' && <DocumentPanel company={c} />}
      {tab === 'ownership' && <OwnershipPanel company={c.id} />}
      {tab === 'governance' && <GovernancePanel company={c.id} />}
      {tab === 'grants' && <GrantsPanel company={c.id} />}
    </>
  );
}

function General({ c, etag, onSaved }: { c: Company; etag: string; onSaved: () => Promise<void> }) {
  const { t } = useI18n();
  const [d, setD] = useState({ nameAr: c.nameAr, nameEn: c.nameEn, crNumber: c.crNumber ?? '', crDate: c.crDate ?? '', crDateHijri: c.crDateHijri ?? '', erpCompanyCode: c.erpCompanyCode ?? '', refCode: c.refCode ?? '', establishedOn: c.establishedOn ?? '', status: c.status });
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  return (
    <>
      <Form title="General" submit="Save changes" onSubmit={async () => {
        setNotice({});
        await api('PATCH', `/companies/${c.id}`, { ...d, crDate: d.crDate || undefined, establishedOn: d.establishedOn || undefined, crDateHijri: d.crDateHijri || undefined, status: d.status === c.status ? undefined : d.status }, etag);
        await onSaved();
        setNotice({ ok: 'Saved.' });
      }}>
        <Field label="Name (Arabic)" value={d.nameAr} onChange={v => setD({ ...d, nameAr: v })} />
        <Field label="Name (English)" value={d.nameEn} onChange={v => setD({ ...d, nameEn: v })} />
        <Field label="Commercial registration" value={d.crNumber} onChange={v => setD({ ...d, crNumber: v })} required={false} />
        <Field label="Registration date" type="date" value={d.crDate} onChange={v => setD({ ...d, crDate: v })} required={false} />
        <Field label="Registration date (Hijri, as written)" value={d.crDateHijri} onChange={v => setD({ ...d, crDateHijri: v })} required={false} />
        <Field label="ERP company code" value={d.erpCompanyCode} onChange={v => setD({ ...d, erpCompanyCode: v })} required={false} />
        <Field label="Reference code" value={d.refCode} onChange={v => setD({ ...d, refCode: v.toUpperCase() })} required={false}
          hint="Two or three characters in the facility references; a reference already written does not change." />
        <Field label="Established on" type="date" value={d.establishedOn} onChange={v => setD({ ...d, establishedOn: v })} required={false} />
        <Select label="Status" value={d.status} onChange={v => setD({ ...d, status: v })}
          options={['ACTIVE', 'DORMANT', 'LIQUIDATED'].map(s => ({ value: s, label: s })).concat(c.status === 'ARCHIVED' ? [{ value: 'ARCHIVED', label: 'ARCHIVED' }] : [])} />
        <Notice ok={notice.ok} />
      </Form>
      {c.status !== 'ARCHIVED' && (
        <Form title="Archive" submit="Archive the company" onSubmit={async () => {
          await api('POST', `/companies/${c.id}/actions/archive`, { reason: (document.getElementById('archive-reason') as HTMLInputElement).value });
          await onSaved();
        }}>
          <p className="muted">{t('A company in use (companies under it, users whose scope it is) stays.')}</p>
          <label><span>{t('Reason')}</span><input id="archive-reason" required /></label>
        </Form>
      )}
    </>
  );
}

function Finance({ c, etag, onSaved }: { c: Company; etag: string; onSaved: () => Promise<void> }) {
  const { t } = useI18n();
  const [fy, setFy] = useState({ month: String(c.fiscalYearEndMonth), day: c.fiscalYearEndDay ? String(c.fiscalYearEndDay) : '', currency: c.baseCurrency ?? '' });
  const [periods, setPeriods] = useState<{ from: string; to: string; months: { from: string; to: string }[] } | null>(null);
  const [rates, setRates] = useState<{ taxCode: string; ratePercent: number; effectiveFrom: string; effectiveTo?: string }[]>([]);
  const [rate, setRate] = useState({ taxCode: 'VAT', ratePercent: '15', effectiveFrom: '' });
  const year = new Date().getFullYear();
  const load = useCallback(async () => {
    setPeriods(await api('GET', `/companies/${c.id}/fiscal-periods?year=${year}`));
    setRates((await api<{ items: typeof rates }>('GET', `/companies/${c.id}/tax-rates`)).items);
  }, [c.id, year]);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <Form title="Fiscal year" submit="Save changes" onSubmit={async () => {
        await api('PATCH', `/companies/${c.id}`, {
          fiscalYearEndMonth: Number(fy.month), fiscalYearEndDay: fy.day ? Number(fy.day) : undefined, fiscalYearEndOfMonth: fy.day ? undefined : true,
          baseCurrency: fy.currency || undefined,
        }, etag);
        await onSaved();
        await load();
      }}>
        <Field label="Year-end month (1 to 12)" value={fy.month} onChange={v => setFy({ ...fy, month: v })} />
        <Field label="Year-end day (empty: the last day of the month)" value={fy.day} onChange={v => setFy({ ...fy, day: v })} required={false} />
        <Field label="Base currency" value={fy.currency} onChange={v => setFy({ ...fy, currency: v.toUpperCase() })} required={false} />
        {periods && <p className="muted">{t('Fiscal year {y}: {from} to {to}', { y: year, from: periods.from, to: periods.to })}</p>}
      </Form>
      <section className="card">
        <h2>{t('Tax rates')}</h2>
        <Table rows={rates} columns={[
          { header: 'Tax', cell: r => r.taxCode }, { header: 'Rate', cell: r => `${r.ratePercent}%` },
          { header: 'From', cell: r => r.effectiveFrom }, { header: 'To', cell: r => r.effectiveTo ?? '' },
        ]} />
      </section>
      <Form title="New tax rate" submit="Add" onSubmit={async () => {
        await api('POST', `/companies/${c.id}/tax-rates`, { taxCode: rate.taxCode, ratePercent: Number(rate.ratePercent), effectiveFrom: rate.effectiveFrom });
        await load();
      }}>
        <Field label="Tax code" value={rate.taxCode} onChange={v => setRate({ ...rate, taxCode: v.toUpperCase() })} />
        <Field label="Rate (%)" value={rate.ratePercent} onChange={v => setRate({ ...rate, ratePercent: v })} />
        <Field label="Effective from" type="date" value={rate.effectiveFrom} onChange={v => setRate({ ...rate, effectiveFrom: v })} hint="The current rate closes the day before." />
      </Form>
    </>
  );
}

function Contacts({ c }: { c: Company }) {
  const { t } = useI18n();
  const [data, setData] = useState<{ addresses: Record<string, string & unknown>[]; contactMethods: { id: string; kind: string; value: string; normalizedValue: string; label?: string; isPrimary: boolean }[] } | null>(null);
  const [addr, setAddr] = useState({ addressType: 'NATIONAL', country: c.country, city: '', district: '', street: '', buildingNumber: '', postalCode: '', additionalNumber: '' });
  const [method, setMethod] = useState({ kind: 'MOBILE', value: '', label: '' });
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => setData(await api('GET', `/companies/${c.id}/contacts`)), [c.id]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return null;
  return (
    <>
      <section className="card">
        <h2>{t('Addresses')}</h2>
        <Notice error={error} />
        <Table rows={data.addresses} columns={[
          { header: 'Type', cell: a => t(String(a.addressType)) },
          { header: 'Address', cell: a => [a.buildingNumber, a.street, a.district, a.city, a.postalCode, a.country].filter(Boolean).join('، ') },
          { header: 'Status', cell: a => a.isCurrent ? (a.isPrimary ? t('Primary') : t('Current')) : t('Previous') },
          { header: '', cell: a => a.isCurrent ? <button className="link" onClick={async () => {
            setError(null);
            try { await api('POST', `/companies/${c.id}/addresses/${a.id}/actions/retire`, {}); await load(); } catch (e) { setError(message(e)); }
          }}>{t('No longer current')}</button> : null },
        ]} />
      </section>
      <Form title="New address" submit="Add" onSubmit={async () => {
        await api('POST', `/companies/${c.id}/addresses`, { ...addr, isPrimary: true });
        await load();
      }}>
        <Select label="Type" value={addr.addressType} onChange={v => setAddr({ ...addr, addressType: v })}
          options={['NATIONAL', 'REGISTERED', 'WORK', 'PO_BOX', 'OTHER'].map(x => ({ value: x, label: x }))} />
        <Field label="Country" value={addr.country} onChange={v => setAddr({ ...addr, country: v.toUpperCase() })} />
        <Field label="City" value={addr.city} onChange={v => setAddr({ ...addr, city: v })} required={false} />
        <Field label="District" value={addr.district} onChange={v => setAddr({ ...addr, district: v })} required={false} />
        <Field label="Street" value={addr.street} onChange={v => setAddr({ ...addr, street: v })} required={false} />
        <Field label="Building number" value={addr.buildingNumber} onChange={v => setAddr({ ...addr, buildingNumber: v })} required={false} />
        <Field label="Postal code" value={addr.postalCode} onChange={v => setAddr({ ...addr, postalCode: v })} required={false} />
        <Field label="Additional number" value={addr.additionalNumber} onChange={v => setAddr({ ...addr, additionalNumber: v })} required={false} />
      </Form>
      <section className="card">
        <h2>{t('Contact methods')}</h2>
        <Table rows={data.contactMethods} columns={[
          { header: 'Type', cell: m => t(m.kind) }, { header: 'Value', cell: m => <span dir="ltr">{m.value}</span> },
          { header: 'Label', cell: m => m.label ?? '' }, { header: '', cell: m => m.isPrimary ? t('Primary') : '' },
          { header: '', cell: m => <button className="link" onClick={async () => { await api('DELETE', `/companies/${c.id}/contact-methods/${m.id}`); await load(); }}>{t('Remove')}</button> },
        ]} />
      </section>
      <Form title="New contact method" submit="Add" onSubmit={async () => { await api('POST', `/companies/${c.id}/contact-methods`, method); setMethod({ ...method, value: '', label: '' }); await load(); }}>
        <Select label="Type" value={method.kind} onChange={v => setMethod({ ...method, kind: v })} options={['MOBILE', 'PHONE', 'EMAIL', 'FAX', 'WEBSITE'].map(x => ({ value: x, label: x }))} />
        <Field label="Value" value={method.value} onChange={v => setMethod({ ...method, value: v })} />
        <Field label="Label" value={method.label} onChange={v => setMethod({ ...method, label: v })} required={false} />
      </Form>
    </>
  );
}

// ---------- documents: the company tab and the register (one store, FR-ORG-011) ----------

export function DocumentPanel({ company }: { company?: Company }) {
  const { t, lang } = useI18n();
  const fmt = useFormat();
  const types = useOptions('/catalogs/document-types');
  const [docs, setDocs] = useState<Doc[]>([]);
  const [filter, setFilter] = useState({ type: '', validity: '' });
  const [draft, setDraft] = useState({ documentType: 'COMMERCIAL_REGISTRATION', title: '', documentNumber: '', issueDate: '', expiryDate: '' });
  const [file, setFile] = useState<File | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const params = new URLSearchParams();
    if (company) params.set('company', company.id);
    if (filter.type) params.set('type', filter.type);
    if (filter.validity) params.set('validity', filter.validity);
    setDocs((await api<{ items: Doc[] }>('GET', `/documents${params.size ? '?' + params : ''}`)).items);
  }, [company, filter]);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h2>{company ? t('Documents') : t('Company documents')}</h2>
        <div className="actions">
          <Select label="Type" value={filter.type} onChange={v => setFilter({ ...filter, type: v })} options={[{ value: '', label: 'All' }, ...types.map(x => ({ value: x.code, label: name(lang, x) }))]} />
          <Select label="Validity" value={filter.validity} onChange={v => setFilter({ ...filter, validity: v })}
            options={[{ value: '', label: 'All' }, { value: 'VALID', label: 'VALID' }, { value: 'EXPIRING', label: 'EXPIRING' }, { value: 'EXPIRED', label: 'EXPIRED' }]} />
        </div>
        <Notice ok={notice.ok} error={notice.error} />
        <Table rows={docs} columns={[
          { header: 'Type', cell: d => name(lang, d.type) },
          { header: 'Title', cell: d => d.title },
          ...(company ? [] : [{ header: 'Company', cell: (d: Doc) => d.company ? <Link to={`/companies/${d.company.id}`}>{name(lang, d.company)}</Link> : '' }]),
          { header: 'Expiry', cell: d => d.expiryDate ? `${fmt.date(d.expiryDate)}${d.daysLeft !== undefined && d.daysLeft !== null ? ` (${t('{n} days', { n: d.daysLeft })})` : ''}` : '' },
          { header: 'Validity', cell: d => <span className={`badge ${d.validity.toLowerCase()}`}>{t(d.validity)}</span> },
          { header: 'Version', cell: d => d.version ?? '' },
          { header: '', cell: d => d.scanStatus === 'CLEAN'
            ? <button className="link" onClick={async () => { try { await downloadGet(`/documents/${d.id}/content`, d.fileName ?? 'document'); } catch (e) { setNotice({ error: message(e) }); } }}>{t('Download')}</button>
            : <span className="muted">{t(d.scanStatus ?? '')}</span> },
        ]} />
      </section>
      <Form title="Upload a document" submit="Upload" onSubmit={async () => {
        setNotice({});
        if (!file) throw new Error('Choose a file.');
        const form = new FormData();
        Object.entries(draft).forEach(([k, v]) => { if (v) form.append(k, v); });
        if (company) form.append('company', company.id);
        form.append('file', file);
        const r = await upload<{ scanStatus: string; duplicateOf?: string }>('/documents', form);
        setNotice({ ok: r.scanStatus === 'CLEAN' ? (r.duplicateOf ? 'Uploaded. The same file is already in another document.' : 'Uploaded.') : 'The file is held in quarantine.' });
        await load();
      }}>
        <Select label="Document type" value={draft.documentType} onChange={v => setDraft({ ...draft, documentType: v })} options={types.map(x => ({ value: x.code, label: name(lang, x) }))} />
        <Field label="Title" value={draft.title} onChange={v => setDraft({ ...draft, title: v })} />
        <Field label="Document number" value={draft.documentNumber} onChange={v => setDraft({ ...draft, documentNumber: v })} required={false} />
        <Field label="Issue date" type="date" value={draft.issueDate} onChange={v => setDraft({ ...draft, issueDate: v })} required={false} />
        <Field label="Expiry date" type="date" value={draft.expiryDate} onChange={v => setDraft({ ...draft, expiryDate: v })} required={false} />
        <label><span>{t('File')}</span><input type="file" onChange={e => setFile(e.target.files?.[0] ?? null)} required /></label>
      </Form>
    </>
  );
}

export function DocumentRegister() {
  return <DocumentPanel />;
}

// ---------- departments ----------

export function Departments() {
  const { t, lang } = useI18n();
  const [items, setItems] = useState<{ id: string; code: string; nameAr: string; nameEn: string; function: string; isTreasury: boolean; isActive: boolean; users: number; etag: string }[]>([]);
  const [warning, setWarning] = useState<string | null>(null);
  const [draft, setDraft] = useState({ code: '', nameAr: '', nameEn: '', function: 'TREASURY' });
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    const r = await api<{ items: typeof items; warning?: string }>('GET', '/departments');
    setItems(r.items);
    setWarning(r.warning ?? null);
  }, []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Departments')}</h1>
        {warning && <p className="notice">{t('No active treasury department: one is recommended.')}</p>}
        <Notice error={error} />
        <Table rows={items} columns={[
          { header: 'Code', cell: d => <span dir="ltr">{d.code}</span> }, { header: 'Name', cell: d => name(lang, d) },
          { header: 'Function', cell: d => t(d.function) }, { header: 'Users', cell: d => d.users },
          { header: 'Status', cell: d => <Chip s={d.isActive ? 'ACTIVE' : 'DISABLED'} /> },
          { header: '', cell: d => <button className="link" onClick={async () => {
            setError(null);
            try { await api('PATCH', `/departments/${d.id}`, { isActive: !d.isActive }, d.etag); await load(); } catch (e) { setError(message(e)); }
          }}>{t(d.isActive ? 'Deactivate' : 'Activate')}</button> },
        ]} />
      </section>
      <Form title="New department" submit="Add" onSubmit={async () => { await api('POST', '/departments', draft); setDraft({ ...draft, code: '', nameAr: '', nameEn: '' }); await load(); }}>
        <Field label="Code" value={draft.code} onChange={v => setDraft({ ...draft, code: v.toUpperCase() })} />
        <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
        <Select label="Function" value={draft.function} onChange={v => setDraft({ ...draft, function: v })} options={['TREASURY', 'FINANCE', 'PROCUREMENT', 'SALES', 'OTHER'].map(x => ({ value: x, label: x }))} />
      </Form>
    </>
  );
}
