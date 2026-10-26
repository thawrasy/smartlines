import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Select, Table } from '../ui';
import { Chip } from '../brand';

// The facility file of a company with a bank (docs/31 row 75): COMPANY-BANK-NNNN, with every contract of the relation
// by class and renewal, and the correspondence with the bank (letters, e-mails, offers, renewal requests).

interface Named { id: string; nameAr: string; nameEn?: string | null; code?: string | null }
interface FileHead { id: string; fileRef: string; status: string; openedOn: string; contracts: number; company: Named; bank: Named }
interface Contract { facilityClass: string; seq: number; id: string; platformRef?: string | null; status: string; effectiveFrom: string; expiryDate: string; totalAmount: number; currency: string }
interface Entry { entryDate: string; direction: string; kind: string; subject: string; bankRef?: string | null; document?: { id: string; title: string } | null; facilityRef?: string | null }
const name = (lang: string, x: Named) => (lang === 'ar' ? x.nameAr : x.nameEn ?? x.nameAr) ?? '';
const amount = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 2 });

export function FacilityFiles() {
  const { t, lang } = useI18n();
  const [rows, setRows] = useState<FileHead[]>([]);
  const [q, setQ] = useState('');
  useEffect(() => { void api<{ items: FileHead[] }>('GET', `/facility-files${q ? '?q=' + encodeURIComponent(q) : ''}`).then(r => setRows(r.items)); }, [q]);
  return (
    <section className="card">
      <h1>{t('Facility files')}</h1>
      <p className="muted">{t('One file per company and bank; it holds every facility contract of the relation, its renewals and the correspondence.')}</p>
      <Field label="Search" value={q} onChange={setQ} required={false} />
      <Table rows={rows} columns={[
        { header: 'File', cell: r => <Link to={`/facility-files/${r.id}`} dir="ltr">{r.fileRef}</Link> },
        { header: 'Company', cell: r => name(lang, r.company) },
        { header: 'Bank', cell: r => <>{name(lang, r.bank)} <span dir="ltr">({r.bank.code})</span></> },
        { header: 'Contracts', cell: r => r.contracts },
        { header: 'Opened on', cell: r => <span dir="ltr">{r.openedOn}</span> },
        { header: 'Status', cell: r => <Chip s={r.status} /> },
      ]} />
    </section>
  );
}

export function FacilityFileDetail() {
  const { t, lang } = useI18n();
  const { id } = useParams();
  const [data, setData] = useState<{ file: FileHead; contracts: Contract[]; entries: Entry[]; canEdit: boolean } | null>(null);
  const empty = { entryDate: new Date().toISOString().slice(0, 10), direction: 'INCOMING', kind: 'LETTER', subject: '', bankRef: '', facility: '' };
  const [draft, setDraft] = useState(empty);
  const load = useCallback(async () => setData(await api('GET', `/facility-files/${id}`)), [id]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return null;
  const classes = [...new Set(data.contracts.map(c => c.facilityClass))];
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{data.file.fileRef}</span> · {name(lang, data.file.company)}</h1>
        <p>{t('Bank')}: {name(lang, data.file.bank)} <span dir="ltr">({data.file.bank.code})</span> · {t('Opened on')}: <span dir="ltr">{data.file.openedOn}</span> · <Chip s={data.file.status} /></p>
      </section>
      {classes.map(cls => (
        <section className="card" key={cls}>
          <h2 dir="ltr">{cls}</h2>
          <Table rows={data.contracts.filter(c => c.facilityClass === cls)} columns={[
            { header: 'Contract', cell: c => <Link to={`/facilities/${c.id}`} dir="ltr">{c.platformRef}</Link> },
            { header: 'Start date', cell: c => <span dir="ltr">{c.effectiveFrom}</span> },
            { header: 'Expiry date', cell: c => <span dir="ltr">{c.expiryDate}</span> },
            { header: 'Total', cell: c => <span dir="ltr">{amount(c.totalAmount)} {c.currency}</span> },
            { header: 'Status', cell: c => <Chip s={c.status} /> },
          ]} />
        </section>
      ))}
      <section className="card">
        <h2>{t('Correspondence')}</h2>
        <Table rows={data.entries} columns={[
          { header: 'Date', cell: e => <span dir="ltr">{e.entryDate}</span> },
          { header: 'Direction', cell: e => t(e.direction) },
          { header: 'Kind', cell: e => t(e.kind) },
          { header: 'Subject', cell: e => e.subject },
          { header: 'Bank reference', cell: e => <span dir="ltr">{e.bankRef}</span> },
          { header: 'Contract', cell: e => <span dir="ltr">{e.facilityRef}</span> },
          { header: 'Document', cell: e => e.document?.title ?? '' },
        ]} />
      </section>
      {data.canEdit && (
        <Form title="Add correspondence" submit="Add" onSubmit={async () => {
          await api('POST', `/facility-files/${id}/entries`, { ...draft, bankRef: draft.bankRef || undefined, facility: draft.facility || undefined });
          setDraft(empty); await load();
        }}>
          <Field label="Date" value={draft.entryDate} onChange={v => setDraft({ ...draft, entryDate: v })} type="date" />
          <Select label="Direction" value={draft.direction} onChange={v => setDraft({ ...draft, direction: v })}
            options={['INCOMING', 'OUTGOING'].map(v => ({ value: v, label: v }))} />
          <Select label="Kind" value={draft.kind} onChange={v => setDraft({ ...draft, kind: v })}
            options={['LETTER', 'EMAIL', 'OFFER', 'RENEWAL_REQUEST', 'OTHER'].map(v => ({ value: v, label: v }))} />
          <Field label="Subject" value={draft.subject} onChange={v => setDraft({ ...draft, subject: v })} />
          <Field label="Bank reference" value={draft.bankRef} onChange={v => setDraft({ ...draft, bankRef: v })} required={false} />
          <Select label="Contract" value={draft.facility} onChange={v => setDraft({ ...draft, facility: v })}
            options={[{ value: '', label: '—' }, ...data.contracts.map(c => ({ value: c.id, label: c.platformRef ?? '' }))]} />
        </Form>
      )}
    </>
  );
}
