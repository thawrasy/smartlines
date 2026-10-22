import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, downloadGet, message, upload } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// Screens 21 to 23 of spec 10: the search of persons and entities (by name, or by an exact identity number through the
// blind index), the party 360 with its documents masked, the reveal that masks itself again, the renewal and images,
// the custom fields, and the duplicates with the merge.

interface Party {
  id: string; partyCode: string; kind: string; nameAr?: string; nameEn?: string; country?: string; residencyStatus?: string; birthDate?: string;
  isActive: boolean; mergedInto?: string; mirrorOfCompany?: string; etag: string;
}
interface IdDoc {
  id: string; docKind: string; issuingCountry: string; number: string; issueDate?: string; expiryDate?: string; isPrimary: boolean; isSuperseded: boolean;
  verified: boolean; etag: string; images: { document: string; side: string }[] | null; imageCount: number;
}
interface Detail {
  party: Party; identityDocuments: IdDoc[]; roles: { role: string; count: number }[];
  customFields: { key: string; labelAr: string; labelEn: string; restricted: boolean; value?: string }[];
  contacts: { addresses: Record<string, unknown>[]; contactMethods: { id: string; kind: string; value: string; isPrimary: boolean }[] };
}

const pname = (lang: string, p: { nameAr?: string; nameEn?: string }) => (lang === 'ar' ? p.nameAr ?? p.nameEn : p.nameEn ?? p.nameAr) ?? '';
const KINDS = ['NATIONAL_ID', 'RESIDENCE', 'PASSPORT', 'GCC_ID', 'COMMERCIAL_REG', 'OTHER_ORG'];

export function Parties() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const me = useMe();
  const [items, setItems] = useState<Party[]>([]);
  const [search, setSearch] = useState({ q: '', number: '', docKind: '', country: '' });
  const [draft, setDraft] = useState({ kind: 'INDIVIDUAL', nameAr: '', nameEn: '', country: 'SA', residencyStatus: 'CITIZEN', birthDate: '' });
  const [similar, setSimilar] = useState<{ id: string; partyCode: string; nameAr?: string; nameEn?: string }[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const find = useCallback(async () => {
    const params = new URLSearchParams(Object.entries(search).filter(([, v]) => v));
    setItems((await api<{ items: Party[] }>('GET', `/parties${params.size ? '?' + params : ''}`)).items);
  }, [search]);
  useEffect(() => { void find(); }, []);   // eslint-disable-line react-hooks/exhaustive-deps
  const create = async (confirm: boolean) => {
    setError(null);
    try {
      const body = draft.kind === 'INDIVIDUAL' ? { ...draft, birthDate: draft.birthDate || undefined } : { kind: draft.kind, nameAr: draft.nameAr, nameEn: draft.nameEn, country: draft.country };
      const r = await api<{ id: string }>('POST', '/parties', { ...body, confirmDuplicate: confirm || undefined });
      nav(`/parties/${r.id}`);
    } catch (e) {
      const p = (e as { problem?: { code: string } }).problem;
      if (p?.code === 'V-PTY-POSSIBLE-DUPLICATE') {
        // The problem body lists the similar parties.
        const r = await fetch('/api/v1/parties?q=' + encodeURIComponent(draft.nameAr || draft.nameEn), { credentials: 'same-origin' });
        setSimilar(((await r.json()) as { items: Party[] }).items);
      } else setError(message(e));
    }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Persons and entities')}</h1>
        <form className="actions" onSubmit={e => { e.preventDefault(); void find(); }}>
          <input placeholder={t('Name or party code')} value={search.q} onChange={e => setSearch({ ...search, q: e.target.value })} />
          <input placeholder={t('Identity number (exact)')} dir="ltr" value={search.number} onChange={e => setSearch({ ...search, number: e.target.value })} />
          <select value={search.docKind} onChange={e => setSearch({ ...search, docKind: e.target.value })}>
            <option value="">{t('Any document')}</option>{KINDS.map(k => <option key={k} value={k}>{t(k)}</option>)}
          </select>
          <input placeholder={t('Issuing country')} value={search.country} onChange={e => setSearch({ ...search, country: e.target.value.toUpperCase() })} size={4} />
          <button type="submit">{t('Search')}</button>
        </form>
        <Table rows={items} columns={[
          { header: 'Code', cell: p => <Link to={`/parties/${p.id}`} dir="ltr">{p.partyCode}</Link> },
          { header: 'Name', cell: p => pname(lang, p) },
          { header: 'Type', cell: p => t(p.kind) },
          { header: 'Country', cell: p => p.country ?? '' },
          { header: 'Status', cell: p => p.mirrorOfCompany ? t('Company mirror') : t(p.isActive ? 'ACTIVE' : 'DISABLED') },
        ]} />
      </section>
      {can(me, 'party.manage') && (
        <Form title="New person or entity" submit="Create" onSubmit={() => create(false)}>
          <Select label="Type" value={draft.kind} onChange={v => setDraft({ ...draft, kind: v })} options={[{ value: 'INDIVIDUAL', label: 'INDIVIDUAL' }, { value: 'ORGANIZATION', label: 'ORGANIZATION' }]} />
          <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} required={false} />
          <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} required={false} />
          <Field label="Country" value={draft.country} onChange={v => setDraft({ ...draft, country: v.toUpperCase() })} />
          {draft.kind === 'INDIVIDUAL' && <>
            <Select label="Residency" value={draft.residencyStatus} onChange={v => setDraft({ ...draft, residencyStatus: v })}
              options={['CITIZEN', 'RESIDENT', 'NON_RESIDENT', 'UNKNOWN'].map(x => ({ value: x, label: x }))} />
            <Field label="Birth date" type="date" value={draft.birthDate} onChange={v => setDraft({ ...draft, birthDate: v })} required={false} />
          </>}
          <Notice error={error} />
          {similar && (
            <div className="notice">
              <p>{t('A party with this name (and birth date) exists. Confirm to create another.')}</p>
              <ul>{similar.map(s => <li key={s.id}><Link to={`/parties/${s.id}`} dir="ltr">{s.partyCode}</Link> {pname(lang, s)}</li>)}</ul>
              <button type="button" onClick={() => void create(true)}>{t('Create anyway')}</button>
            </div>
          )}
        </Form>
      )}
    </>
  );
}

/** A revealed number, masked again after the tenant's setting (BR-PTY-009). */
function Reveal({ path, onError }: { path: string; onError: (m: string) => void }) {
  const { t } = useI18n();
  const [value, setValue] = useState<string | null>(null);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  if (value) return <code dir="ltr">{value}</code>;
  return <button className="link" onClick={async () => {
    try {
      const r = await api<{ number?: string; value?: string; remaskSeconds?: number }>('POST', path, {});
      setValue(r.number ?? r.value ?? '');
      timer.current = window.setTimeout(() => setValue(null), (r.remaskSeconds ?? 60) * 1000);
    } catch (e) { onError(message(e)); }
  }}>{t('Reveal')}</button>;
}

export function PartyDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const fmt = useFormat();
  const me = useMe();
  const [d, setD] = useState<Detail | null>(null);
  const [etag, setEtag] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [doc, setDoc] = useState({ docKind: 'NATIONAL_ID', issuingCountry: 'SA', number: '', expiryDate: '', isPrimary: false, primaryReason: '' });
  const [renewing, setRenewing] = useState<string | null>(null);
  const [renew, setRenew] = useState({ number: '', expiryDate: '' });
  const [image, setImage] = useState<{ doc: string; side: string; file: File | null }>({ doc: '', side: 'FRONT', file: null });
  const [mergeInto, setMergeInto] = useState('');
  const load = useCallback(async () => {
    const r = await apiWithETag<Detail>(`/parties/${id}`);
    setD(r.data);
    setEtag(r.etag);
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const p = d.party;
  const act = async (fn: () => Promise<unknown>, ok?: string) => {
    setNotice({});
    try { await fn(); await load(); if (ok) setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const writable = can(me, 'party.identity.write') && p.isActive && !p.mirrorOfCompany;
  return (
    <>
      <section className="card">
        <h1>{pname(lang, p)} <small dir="ltr">({p.partyCode})</small></h1>
        <p className="muted">
          {t(p.kind)}{p.country ? ` · ${p.country}` : ''}{p.birthDate ? ` · ${fmt.date(p.birthDate)}` : ''}
          {p.mirrorOfCompany && <> · <Link to={`/companies/${p.mirrorOfCompany}`}>{t('Company mirror')}</Link></>}
          {p.mergedInto && <> · <Link to={`/parties/${p.mergedInto}`}>{t('Merged into another party')}</Link></>}
        </p>
        <p>{t('Roles')}: {d.roles.length === 0 ? t('Not used yet') : d.roles.map(r => `${t(r.role)} (${r.count})`).join('، ')}</p>
        <Notice ok={notice.ok} error={notice.error} />
      </section>
      <section className="card">
        <h2>{t('Identity documents')}</h2>
        <Table rows={d.identityDocuments} columns={[
          { header: 'Type', cell: x => t(x.docKind) }, { header: 'Country', cell: x => x.issuingCountry },
          { header: 'Number', cell: x => <span dir="ltr">{x.number} {!x.isSuperseded && <Reveal path={`/parties/${p.id}/identity-documents/${x.id}/actions/reveal`} onError={m => setNotice({ error: m })} />}</span> },
          { header: 'Expiry', cell: x => x.expiryDate ? fmt.date(x.expiryDate) : '' },
          { header: 'Status', cell: x => [x.isPrimary && t('Primary'), x.isSuperseded && t('Superseded'), x.verified && t('Original verified')].filter(Boolean).join(' · ') },
          { header: 'Images', cell: x => x.images ? x.images.map(i => <button key={i.document} className="link" onClick={() => void downloadGet(`/documents/${i.document}/content`, i.side)}>{t(i.side)}</button>) : x.imageCount ? t('{n} restricted', { n: x.imageCount }) : '' },
          { header: '', cell: x => writable && !x.isSuperseded ? <span className="actions">
            {!x.verified && <button className="link" onClick={() => void act(() => api('POST', `/parties/${p.id}/identity-documents/${x.id}/actions/verify`, {}), 'Saved.')}>{t('Mark original verified')}</button>}
            <button className="link" onClick={() => { setRenewing(x.id); setRenew({ number: '', expiryDate: '' }); }}>{t('Renew')}</button>
            {can(me, 'party.identity.image.view') && <button className="link" onClick={() => setImage({ doc: x.id, side: 'FRONT', file: null })}>{t('Add an image')}</button>}
          </span> : null },
        ]} />
      </section>
      {renewing && (
        <Form title="Renew the document" submit="Renew" onSubmit={() => act(async () => { await api('POST', `/parties/${p.id}/identity-documents/${renewing}/actions/renew`, { ...renew, expiryDate: renew.expiryDate || undefined }); setRenewing(null); }, 'Saved.')}>
          <p className="muted">{t('The old document stays, superseded by the new one.')}</p>
          <Field label="Number" value={renew.number} onChange={v => setRenew({ ...renew, number: v })} />
          <Field label="Expiry date" type="date" value={renew.expiryDate} onChange={v => setRenew({ ...renew, expiryDate: v })} required={false} />
        </Form>
      )}
      {image.doc && (
        <Form title="Add an image" submit="Upload" onSubmit={() => act(async () => {
          if (!image.file) throw new Error('Choose a file.');
          const form = new FormData();
          form.append('side', image.side);
          form.append('file', image.file);
          await upload(`/parties/${p.id}/identity-documents/${image.doc}/images`, form);
          setImage({ doc: '', side: 'FRONT', file: null });
        }, 'Uploaded.')}>
          <Select label="Side" value={image.side} onChange={v => setImage({ ...image, side: v })} options={['FRONT', 'BACK', 'OTHER'].map(x => ({ value: x, label: x }))} />
          <label><span>{t('File')}</span><input type="file" accept="image/png,image/jpeg,application/pdf" onChange={e => setImage({ ...image, file: e.target.files?.[0] ?? null })} required /></label>
        </Form>
      )}
      {writable && (
        <Form title="New identity document" submit="Add" onSubmit={() => act(async () => {
          const r = await api<{ warnings: string[] }>('POST', `/parties/${p.id}/identity-documents`, {
            ...doc, expiryDate: doc.expiryDate || undefined, isPrimary: doc.isPrimary || undefined, primaryReason: doc.primaryReason || undefined,
          });
          setDoc({ ...doc, number: '', expiryDate: '', isPrimary: false, primaryReason: '' });
          if (r.warnings.length) setNotice({ ok: 'Saved. The number does not have the usual format of this document.' });
        })}>
          <Select label="Type" value={doc.docKind} onChange={v => setDoc({ ...doc, docKind: v })} options={KINDS.map(k => ({ value: k, label: k }))} />
          <Field label="Issuing country" value={doc.issuingCountry} onChange={v => setDoc({ ...doc, issuingCountry: v.toUpperCase() })} />
          <Field label="Number" value={doc.number} onChange={v => setDoc({ ...doc, number: v })} />
          <Field label="Expiry date" type="date" value={doc.expiryDate} onChange={v => setDoc({ ...doc, expiryDate: v })} required={false} />
          <label><input type="checkbox" checked={doc.isPrimary} onChange={e => setDoc({ ...doc, isPrimary: e.target.checked })} /> {t('Primary document')}</label>
          {doc.isPrimary && <Field label="Reason for this primary document" value={doc.primaryReason} onChange={v => setDoc({ ...doc, primaryReason: v })} required={false} />}
        </Form>
      )}
      <section className="card">
        <h2>{t('Addresses and contacts')}</h2>
        <Table rows={d.contacts.addresses} columns={[
          { header: 'Type', cell: a => t(String(a.addressType)) },
          { header: 'Address', cell: a => [a.buildingNumber, a.street, a.district, a.city, a.postalCode, a.country].filter(Boolean).join('، ') },
        ]} />
        <Table rows={d.contacts.contactMethods} columns={[{ header: 'Type', cell: m => t(m.kind) }, { header: 'Value', cell: m => <span dir="ltr">{m.value}</span> }]} />
        {p.mirrorOfCompany && <p className="muted">{t('The addresses of a company are edited on the company screen.')}</p>}
      </section>
      <section className="card">
        <h2>{t('Custom fields')}</h2>
        <Table rows={d.customFields} columns={[
          { header: 'Field', cell: c => lang === 'ar' ? c.labelAr : c.labelEn },
          { header: 'Value', cell: c => <span dir="ltr">{c.value} {c.restricted && <Reveal path={`/parties/${p.id}/custom-fields/${c.key}/actions/reveal`} onError={m => setNotice({ error: m })} />}</span> },
        ]} />
      </section>
      {can(me, 'party.merge') && p.isActive && !p.mirrorOfCompany && (
        <Form title="Merge into another party" submit="Merge" onSubmit={() => act(() => api('POST', `/parties/${p.id}/actions/merge`, { into: mergeInto, reason: (document.getElementById('merge-reason') as HTMLInputElement).value }), 'Saved.')}>
          <p className="muted">{t('Every record of this party moves to the party kept; this party becomes inactive for good.')}</p>
          <Field label="Party kept (its id)" value={mergeInto} onChange={setMergeInto} />
          <label><span>{t('Reason')}</span><input id="merge-reason" required /></label>
        </Form>
      )}
      {can(me, 'party.manage') && p.isActive && !p.mirrorOfCompany && (
        <section className="card">
          <button className="secondary" onClick={() => void act(() => api('POST', `/parties/${p.id}/actions/deactivate`, {}), 'Saved.')}>{t('Deactivate')}</button>
          <small className="muted"> {t('A party in use stays active.')} (ETag {etag ? '✓' : ''})</small>
        </section>
      )}
    </>
  );
}

export function PartyDuplicates() {
  const { t } = useI18n();
  const [items, setItems] = useState<{ a: { id: string; partyCode: string; name?: string }; b: { id: string; partyCode: string; name?: string } }[]>([]);
  useEffect(() => { api<{ items: typeof items }>('GET', '/parties/duplicates').then(r => setItems(r.items)).catch(() => setItems([])); }, []);
  return (
    <section className="card">
      <h1>{t('Possible duplicates')}</h1>
      <Table rows={items} columns={[
        { header: 'Party', cell: x => <Link to={`/parties/${x.a.id}`} dir="ltr">{x.a.partyCode}</Link> }, { header: 'Name', cell: x => x.a.name ?? '' },
        { header: 'Party', cell: x => <Link to={`/parties/${x.b.id}`} dir="ltr">{x.b.partyCode}</Link> }, { header: 'Name', cell: x => x.b.name ?? '' },
      ]} />
    </section>
  );
}

export function CustomFieldDefinitions() {
  const { t, lang } = useI18n();
  const [items, setItems] = useState<{ key: string; labelAr: string; labelEn: string; dataType: string; sensitivity: string; isActive: boolean; etag: string }[]>([]);
  const [draft, setDraft] = useState({ fieldKey: '', labelAr: '', labelEn: '', dataType: 'TEXT', sensitivity: 'CONFIDENTIAL', listValues: '' });
  const load = useCallback(async () => setItems((await api<{ items: typeof items }>('GET', '/custom-field-definitions')).items), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Custom fields')}</h1>
        <Table rows={items} columns={[
          { header: 'Key', cell: x => <code dir="ltr">{x.key}</code> }, { header: 'Label', cell: x => lang === 'ar' ? x.labelAr : x.labelEn },
          { header: 'Type', cell: x => t(x.dataType) }, { header: 'Sensitivity', cell: x => t(x.sensitivity) },
          { header: 'Status', cell: x => <button className="link" onClick={async () => { await api('PATCH', `/custom-field-definitions/${x.key}`, { isActive: !x.isActive }, x.etag); await load(); }}>{t(x.isActive ? 'ACTIVE' : 'DISABLED')}</button> },
        ]} />
      </section>
      <Form title="New field" submit="Add" onSubmit={async () => {
        await api('POST', '/custom-field-definitions', { ...draft, listValues: draft.dataType === 'LIST' ? draft.listValues.split(',').map(s => s.trim()).filter(Boolean) : undefined });
        setDraft({ ...draft, fieldKey: '', labelAr: '', labelEn: '', listValues: '' });
        await load();
      }}>
        <Field label="Key" value={draft.fieldKey} onChange={v => setDraft({ ...draft, fieldKey: v.toLowerCase() })} hint="Small letters, digits and _." />
        <Field label="Label (Arabic)" value={draft.labelAr} onChange={v => setDraft({ ...draft, labelAr: v })} />
        <Field label="Label (English)" value={draft.labelEn} onChange={v => setDraft({ ...draft, labelEn: v })} />
        <Select label="Type" value={draft.dataType} onChange={v => setDraft({ ...draft, dataType: v })} options={['TEXT', 'NUMBER', 'DATE', 'LIST', 'BOOLEAN', 'AMOUNT'].map(x => ({ value: x, label: x }))} />
        {draft.dataType === 'LIST' && <Field label="Values" value={draft.listValues} onChange={v => setDraft({ ...draft, listValues: v })} hint="Codes, separated by commas." />}
        <Select label="Sensitivity" value={draft.sensitivity} onChange={v => setDraft({ ...draft, sensitivity: v })} options={[{ value: 'CONFIDENTIAL', label: 'CONFIDENTIAL' }, { value: 'RESTRICTED', label: 'RESTRICTED' }]} />
      </Form>
    </>
  );
}
