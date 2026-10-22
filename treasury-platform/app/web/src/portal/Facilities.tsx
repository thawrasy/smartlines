import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';

// SCR-FAC-01 (the list) and SCR-FAC-02 (the facility card: header, lenders, documents, revisions, renewal chain and
// accounts). A facility is changed through its open revision; the approved card and the draft are shown side by side.

interface Named { id: string; code?: string; companyCode?: string; nameAr?: string; nameEn?: string }
const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 2 });

interface Row {
  id: string; facilityNo: string; borrower: Named; type: string; currency: string; totalAmount: number; status: string; validity?: string;
  effectiveFrom: string; expiryDate: string; bankReferenceNo?: string; lenders: { code: string; nameAr: string; nameEn?: string; sharePct: number }[];
}

function Validity({ v }: { v?: string | null }) {
  const { t } = useI18n();
  if (!v) return null;
  return <span className={`badge ${v === 'NOT_CONFIRMED' ? 'error' : v === 'EXPIRING' ? 'warn' : ''}`}>{t(v)}</span>;
}

export function Facilities() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const [rows, setRows] = useState<Row[]>([]);
  const [filter, setFilter] = useState({ status: '', validity: '' });
  const [companies, setCompanies] = useState<Named[]>([]);
  const [draft, setDraft] = useState({ borrower: '', facilityType: 'CREDIT_FACILITIES', currency: 'SAR', totalAmount: '', isSyndicated: 'false', effectiveFrom: '', expiryDate: '', bankReferenceNo: '' });
  const load = useCallback(async () => {
    const q = new URLSearchParams(Object.entries(filter).filter(([, v]) => v));
    setRows((await api<{ items: Row[] }>('GET', `/facilities${q.size ? '?' + q : ''}`)).items);
  }, [filter]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/companies').then(r => { setCompanies(r.items); setDraft(d => ({ ...d, borrower: d.borrower || r.items[0]?.id || '' })); }); }, []);
  return (
    <>
      <section className="card">
        <h1>{t('Facilities')}</h1>
        <div className="row">
          <Select label="Status" value={filter.status} onChange={v => setFilter({ ...filter, status: v })}
            options={['', 'DRAFT', 'ACTIVE', 'SUSPENDED', 'EXPIRED', 'TERMINATED', 'SUPERSEDED'].map(s => ({ value: s, label: s || 'All' }))} />
          <Select label="Validity" value={filter.validity} onChange={v => setFilter({ ...filter, validity: v })}
            options={['', 'SCHEDULED', 'VALID', 'EXPIRING', 'NOT_CONFIRMED'].map(s => ({ value: s, label: s || 'All' }))} />
        </div>
        <Table rows={rows} columns={[
          { header: 'Facility', cell: r => <Link to={`/facilities/${r.id}`} dir="ltr">{r.facilityNo}</Link> },
          { header: 'Borrower', cell: r => name(lang, r.borrower) },
          { header: 'Banks', cell: r => r.lenders.map(l => l.code).join(', ') },
          { header: 'Total', cell: r => <span dir="ltr">{amount(r.totalAmount)} {r.currency}</span> },
          { header: 'Expiry date', cell: r => <span dir="ltr">{r.expiryDate}</span> },
          { header: 'Status', cell: r => <>{t(r.status)} <Validity v={r.validity} /></> },
        ]} />
      </section>
      <Form title="New facility" submit="Create" onSubmit={async () => {
        const r = await api<{ id: string }>('POST', '/facilities', {
          ...draft, totalAmount: Number(draft.totalAmount), isSyndicated: draft.isSyndicated === 'true', bankReferenceNo: draft.bankReferenceNo || undefined,
        });
        nav(`/facilities/${r.id}`);
      }}>
        <Select label="Borrower" value={draft.borrower} onChange={v => setDraft({ ...draft, borrower: v })} options={companies.map(c => ({ value: c.id, label: name(lang, c) }))} />
        <Select label="Facility type" value={draft.facilityType} onChange={v => setDraft({ ...draft, facilityType: v })}
          options={[{ value: 'CREDIT_FACILITIES', label: 'Credit facilities' }, { value: 'ISLAMIC_FINANCING', label: 'Islamic financing' }]} />
        <Field label="Currency" value={draft.currency} onChange={v => setDraft({ ...draft, currency: v })} />
        <Field label="Total" value={draft.totalAmount} onChange={v => setDraft({ ...draft, totalAmount: v })} type="number" />
        <Select label="Syndicated" value={draft.isSyndicated} onChange={v => setDraft({ ...draft, isSyndicated: v })} options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]} />
        <Field label="Start date" value={draft.effectiveFrom} onChange={v => setDraft({ ...draft, effectiveFrom: v })} type="date" />
        <Field label="Expiry date" value={draft.expiryDate} onChange={v => setDraft({ ...draft, expiryDate: v })} type="date" />
        <Field label="Bank reference" value={draft.bankReferenceNo} onChange={v => setDraft({ ...draft, bankReferenceNo: v })} required={false} />
      </Form>
    </>
  );
}

interface Header {
  totalAmount: number; isSyndicated: boolean; precedenceLanguage: string; bankReferenceNo?: string; bankStructureNo?: string; agreementDate?: string;
  effectiveFrom: string; effectiveFromHijri?: string; expiryDate: string; expiryDateHijri?: string; hijriAdjusted: boolean; noticeDays?: number;
  bankUnilateralRights: string[]; alertLeadDays: number[];
}
interface Lender { id: string; institution: Named; roles: string[]; sharePct: number; fromRevision: number }
interface Doc { id: string; document: string; title: string; documentType: string; documentDate?: string; language: string; precedenceRank: number; amends?: string; fromRevision: number }
interface Revision { id: string; revisionNo: number; reasonKind: string; status: string; effectiveOn: string; changeSummary?: string; rejectionReason?: string; approvedOn?: string }
interface Card {
  id: string; facilityNo: string; borrower: Named; type: string; currency: string; status: string; statusReason?: string; validity?: string; daysToExpiry: number;
  approvedRevision: number; header: Header; previous?: string; successor?: { id: string; facilityNo: string; status: string };
  lenders: Lender[]; documents: Doc[]; revisions: Revision[];
  draft?: { revision: string; revisionNo: number; header: Header; lenders: Lender[]; documents: Doc[] } | null;
  permissions: { edit: boolean; approve: boolean; lifecycle: boolean; suspend: boolean };
}
interface Finding { code: string; message: string }

function HeaderView({ h, currency }: { h: Header; currency: string }) {
  const { t } = useI18n();
  return (
    <dl className="grid">
      <dt>{t('Total')}</dt><dd dir="ltr">{amount(h.totalAmount)} {currency}</dd>
      <dt>{t('Start date')}</dt><dd dir="ltr">{h.effectiveFrom} {h.effectiveFromHijri && <small className="muted">({h.effectiveFromHijri} {t('AH')})</small>}</dd>
      <dt>{t('Expiry date')}</dt><dd dir="ltr">{h.expiryDate} {h.expiryDateHijri && <small className="muted">({h.expiryDateHijri} {t('AH')})</small>}</dd>
      <dt>{t('Bank reference')}</dt><dd dir="ltr">{h.bankReferenceNo}</dd>
      <dt>{t('Syndicated')}</dt><dd>{t(h.isSyndicated ? 'Yes' : 'No')}</dd>
      <dt>{t('Prevailing language')}</dt><dd>{t(h.precedenceLanguage)}</dd>
      <dt>{t('Bank rights')}</dt><dd>{h.bankUnilateralRights.map(r => t(r)).join(', ')}{h.noticeDays != null && ` · ${h.noticeDays} ${t('days notice')}`}</dd>
    </dl>
  );
}

export function FacilityDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const [card, setCard] = useState<Card | null>(null);
  const [etag, setEtag] = useState('');
  const [banks, setBanks] = useState<Named[]>([]);
  const [docs, setDocs] = useState<{ id: string; title: string; type: { code: string } }[]>([]);
  const [check, setCheck] = useState<{ errors: Finding[]; warnings: Finding[] } | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [lender, setLender] = useState({ institution: '', sharePct: '', roles: 'SOLE' });
  const [doc, setDoc] = useState({ document: '', precedenceRank: '1', language: 'AR' });
  const [header, setHeader] = useState({ totalAmount: '', expiryDate: '', bankReferenceNo: '' });
  const [revision, setRevision] = useState({ reasonKind: 'AMENDMENT', changeSummary: '', expiryDate: '' });
  const [reason, setReason] = useState('');
  const load = useCallback(async () => {
    const r = await apiWithETag<Card>(`/facilities/${id}`);
    setCard(r.data);
    setEtag(r.etag);
    setCheck(r.data.draft ? await api('GET', `/facilities/${id}/revisions/${r.data.draft.revision}/check`) : null);
    const d = r.data.draft?.header;
    if (d) setHeader({ totalAmount: String(d.totalAmount), expiryDate: d.expiryDate, bankReferenceNo: d.bankReferenceNo ?? '' });
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/institutions?status=ACTIVE').then(r => setBanks(r.items)); }, []);
  useEffect(() => {
    if (card) void api<{ items: { id: string; title: string; type: { code: string } }[] }>('GET', `/documents?company=${card.borrower.id}`).then(r => setDocs(r.items));
  }, [card]);
  if (!card) return null;
  const draft = card.draft;
  const open = card.revisions.find(r => ['DRAFT', 'SUBMITTED', 'REJECTED'].includes(r.status));
  const act = async (action: string, body: object = {}) => {
    setNotice({});
    try {
      await api('POST', `/facilities/${id}/revisions/${open!.id}/actions/${action}`, body);
      await load();
    } catch (e) { setNotice({ error: message(e) }); }
  };
  const lifecycle = async (action: string) => {
    setNotice({});
    try { await api('POST', `/facilities/${id}/actions/${action}`, { reason }); setReason(''); await load(); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{card.facilityNo}</span> · {name(lang, card.borrower)}</h1>
        <p>{t(card.status)} <Validity v={card.validity} /> {card.validity && <small className="muted">{card.daysToExpiry} {t('days to expiry')}</small>}
          {card.statusReason && <small className="muted"> · {card.statusReason}</small>}</p>
        {card.previous && <p><Link to={`/facilities/${card.previous}`}>{t('Previous facility')}</Link></p>}
        {card.successor && <p><Link to={`/facilities/${card.successor.id}`}>{t('Renewed by')} <span dir="ltr">{card.successor.facilityNo}</span></Link> ({t(card.successor.status)})</p>}
        {card.approvedRevision > 0 ? <HeaderView h={card.header} currency={card.currency} /> : <p className="muted">{t('Not approved yet.')}</p>}
        <h2>{t('Lenders')}</h2>
        <Table rows={card.lenders} columns={[
          { header: 'Bank', cell: l => name(lang, l.institution) },
          { header: 'Roles', cell: l => l.roles.map(r => t(r)).join(', ') },
          { header: 'Share', cell: l => <span dir="ltr">{l.sharePct}%</span> },
        ]} />
        <h2>{t('Documents')}</h2>
        <Table rows={card.documents} columns={[
          { header: 'Rank', cell: d => d.precedenceRank },
          { header: 'Document', cell: d => d.title },
          { header: 'Type', cell: d => t(d.documentType) },
          { header: 'Language', cell: d => t(d.language) },
        ]} />
        <Notice error={notice.error} ok={notice.ok} />
        {(card.permissions.lifecycle || card.permissions.suspend) && card.approvedRevision > 0 && (
          <div className="row">
            <Field label="Reason" value={reason} onChange={setReason} required={false} />
            {card.permissions.suspend && card.status === 'ACTIVE' && <button onClick={() => void lifecycle('suspend')}>{t('Suspend')}</button>}
            {card.permissions.suspend && card.status === 'SUSPENDED' && <button onClick={() => void lifecycle('resume')}>{t('Resume')}</button>}
            {card.permissions.lifecycle && ['ACTIVE', 'SUSPENDED'].includes(card.status) && <>
              <button onClick={() => void lifecycle('expire')}>{t('Record the expiry')}</button>
              <button onClick={() => void lifecycle('terminate')}>{t('Terminate')}</button>
            </>}
            {card.permissions.edit && !card.successor && !['TERMINATED', 'SUPERSEDED'].includes(card.status) &&
              <button onClick={async () => { const r = await api<{ id: string }>('POST', `/facilities/${id}/actions/renew`, {}); nav(`/facilities/${r.id}`); }}>{t('Renew')}</button>}
          </div>
        )}
      </section>

      {draft && open && (
        <section className="card">
          <h2>{t('Revision')} {draft.revisionNo} · {t(open.reasonKind)} · {t(open.status)}</h2>
          {open.rejectionReason && <p className="error">{open.rejectionReason}</p>}
          <HeaderView h={draft.header} currency={card.currency} />
          {check && <>
            {check.errors.map((e, i) => <p key={i} className="error">{e.code}: {t(e.message)}</p>)}
            {check.warnings.map((w, i) => <p key={i} className="warn">{w.code}: {t(w.message)}</p>)}
          </>}
          <Table rows={draft.lenders} columns={[
            { header: 'Bank', cell: l => name(lang, l.institution) },
            { header: 'Roles', cell: l => l.roles.map(r => t(r)).join(', ') },
            { header: 'Share', cell: l => <span dir="ltr">{l.sharePct}%</span> },
            { header: '', cell: l => open.status === 'DRAFT' && card.permissions.edit
              ? <button className="link" onClick={async () => { await api('DELETE', `/facilities/${id}/lenders/${l.id}`); await load(); }}>{t('Remove')}</button> : null },
          ]} />
          <Table rows={draft.documents} columns={[
            { header: 'Rank', cell: d => d.precedenceRank },
            { header: 'Document', cell: d => d.title },
            { header: 'Type', cell: d => t(d.documentType) },
            { header: '', cell: d => open.status === 'DRAFT' && card.permissions.edit
              ? <button className="link" onClick={async () => { await api('DELETE', `/facilities/${id}/documents/${d.id}`); await load(); }}>{t('Remove')}</button> : null },
          ]} />
          <div className="row">
            {open.status === 'DRAFT' && card.permissions.edit && <button onClick={() => void act('submit')}>{t('Submit for approval')}</button>}
            {open.status === 'SUBMITTED' && card.permissions.edit && <button onClick={() => void act('withdraw')}>{t('Withdraw')}</button>}
            {open.status === 'SUBMITTED' && card.permissions.approve && <>
              <button onClick={() => void act('approve', { acknowledge: check?.warnings.map(w => w.code) ?? [] })}>{t('Approve')}{check?.warnings.length ? ` (${t('acknowledging the warnings')})` : ''}</button>
              <button onClick={() => void act('reject', { reason })}>{t('Reject')}</button>
            </>}
            {open.status === 'REJECTED' && card.permissions.edit && <button onClick={() => void act('reopen')}>{t('Reopen')}</button>}
            {['DRAFT', 'REJECTED'].includes(open.status) && card.approvedRevision > 0 && card.permissions.edit && <button onClick={() => void act('discard')}>{t('Discard')}</button>}
          </div>
        </section>
      )}

      {draft && open?.status === 'DRAFT' && card.permissions.edit && (
        <>
          <Form title="Change the header" submit="Save changes" onSubmit={async () => {
            await api('PATCH', `/facilities/${id}`, { totalAmount: Number(header.totalAmount), expiryDate: header.expiryDate, bankReferenceNo: header.bankReferenceNo }, etag);
            await load();
          }}>
            <Field label="Total" value={header.totalAmount} onChange={v => setHeader({ ...header, totalAmount: v })} type="number" />
            <Field label="Expiry date" value={header.expiryDate} onChange={v => setHeader({ ...header, expiryDate: v })} type="date" />
            <Field label="Bank reference" value={header.bankReferenceNo} onChange={v => setHeader({ ...header, bankReferenceNo: v })} required={false} />
          </Form>
          <Form title="Add a lender" submit="Add" onSubmit={async () => {
            await api('POST', `/facilities/${id}/lenders`, { institution: lender.institution, sharePct: Number(lender.sharePct), roles: lender.roles.split(',') });
            setLender({ ...lender, sharePct: '' });
            await load();
          }}>
            <Select label="Bank" value={lender.institution} onChange={v => setLender({ ...lender, institution: v })}
              options={[{ value: '', label: '' }, ...banks.map(b => ({ value: b.id, label: name(lang, b) }))]} />
            <Field label="Share (%)" value={lender.sharePct} onChange={v => setLender({ ...lender, sharePct: v })} type="number" />
            <Select label="Roles" value={lender.roles} onChange={v => setLender({ ...lender, roles: v })}
              options={['SOLE', 'LEAD,AGENT', 'LEAD', 'AGENT', 'ARRANGER', 'PARTICIPANT'].map(r => ({ value: r, label: r }))} />
          </Form>
          <Form title="Add a document" submit="Add" onSubmit={async () => {
            await api('POST', `/facilities/${id}/documents`, { document: doc.document, precedenceRank: Number(doc.precedenceRank), language: doc.language });
            await load();
          }}>
            <Select label="Document" value={doc.document} onChange={v => setDoc({ ...doc, document: v })}
              options={[{ value: '', label: '' }, ...docs.map(d => ({ value: d.id, label: `${d.title} (${t(d.type.code)})` }))]} />
            <Field label="Rank" value={doc.precedenceRank} onChange={v => setDoc({ ...doc, precedenceRank: v })} type="number" />
            <Select label="Language" value={doc.language} onChange={v => setDoc({ ...doc, language: v })} options={['AR', 'EN', 'BILINGUAL'].map(l => ({ value: l, label: l }))} />
          </Form>
        </>
      )}

      {!open && card.permissions.edit && card.approvedRevision > 0 && !['TERMINATED', 'SUPERSEDED'].includes(card.status) && (
        <Form title="Open a revision" submit="Open" onSubmit={async () => {
          await api('POST', `/facilities/${id}/revisions`, { ...revision, expiryDate: revision.reasonKind === 'EXTENSION' ? revision.expiryDate : undefined });
          await load();
        }}>
          <Select label="Kind" value={revision.reasonKind} onChange={v => setRevision({ ...revision, reasonKind: v })}
            options={['AMENDMENT', 'EXTENSION', 'CORRECTION'].map(k => ({ value: k, label: k }))} />
          {revision.reasonKind === 'EXTENSION' && <Field label="New expiry date" value={revision.expiryDate} onChange={v => setRevision({ ...revision, expiryDate: v })} type="date" />}
          <Field label="Summary of the change" value={revision.changeSummary} onChange={v => setRevision({ ...revision, changeSummary: v })} required={false} />
        </Form>
      )}

      <section className="card">
        <h2>{t('Revisions')}</h2>
        <Table rows={card.revisions} columns={[
          { header: 'No.', cell: r => r.revisionNo },
          { header: 'Kind', cell: r => t(r.reasonKind) },
          { header: 'Status', cell: r => t(r.status) },
          { header: 'Date', cell: r => <span dir="ltr">{r.effectiveOn}</span> },
          { header: 'Summary', cell: r => r.changeSummary },
        ]} />
      </section>
      <FacilityAccounts id={id!} company={card.borrower.id} edit={card.permissions.edit} />
    </>
  );
}

interface FacilityAccount { id: string; account: string; nickname?: string; accountNoMask: string; currency: string; purpose: string; purposeAr?: string; purposeEn?: string; isDefault: boolean; open: boolean; institution: string }

function FacilityAccounts({ id, company, edit }: { id: string; company: string; edit: boolean }) {
  const { t, lang } = useI18n();
  const [rows, setRows] = useState<FacilityAccount[]>([]);
  const [accounts, setAccounts] = useState<{ id: string; nickname?: string; accountNumber: string; currency: string; institutionCode: string }[]>([]);
  const [draft, setDraft] = useState({ account: '', purpose: 'FACILITY', isDefault: 'true' });
  const load = useCallback(async () => setRows((await api<{ items: FacilityAccount[] }>('GET', `/facilities/${id}/accounts`)).items), [id]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: typeof accounts }>('GET', `/accounts?company=${company}&status=ACTIVE`).then(r => setAccounts(r.items)); }, [company]);
  return (
    <>
      <section className="card">
        <h2>{t('Facility accounts')}</h2>
        <Table rows={rows} columns={[
          { header: 'Account', cell: a => <span dir="ltr">{a.institution} {a.accountNoMask}</span> },
          { header: 'Purpose', cell: a => name(lang, { nameAr: a.purposeAr, nameEn: a.purposeEn }) },
          { header: 'Currency', cell: a => a.currency },
          { header: 'Default', cell: a => a.isDefault ? t('Yes') : '' },
          { header: '', cell: a => a.open && edit
            ? <button className="link" onClick={async () => { await api('POST', `/facilities/${id}/accounts/${a.id}/actions/end`, {}); await load(); }}>{t('End')}</button> : t('Ended') },
        ]} />
      </section>
      {edit && (
        <Form title="Link an account" submit="Link" onSubmit={async () => {
          await api('POST', `/facilities/${id}/accounts`, { account: draft.account, purpose: draft.purpose, isDefault: draft.isDefault === 'true' });
          await load();
        }}>
          <Select label="Account" value={draft.account} onChange={v => setDraft({ ...draft, account: v })}
            options={[{ value: '', label: '' }, ...accounts.map(a => ({ value: a.id, label: `${a.institutionCode} ${a.accountNumber} ${a.currency}` }))]} />
          <Select label="Purpose" value={draft.purpose} onChange={v => setDraft({ ...draft, purpose: v })}
            options={['FACILITY', 'MARGIN_SETTLEMENT', 'BANK_CHARGES', 'REPAYMENT', 'LC_PROCEEDS_COLLECTION'].map(p => ({ value: p, label: p }))} />
          <Select label="Default" value={draft.isDefault} onChange={v => setDraft({ ...draft, isDefault: v })} options={[{ value: 'true', label: 'Yes' }, { value: 'false', label: 'No' }]} />
        </Form>
      )}
    </>
  );
}
