import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';
import { SignatoriesPanel } from './Signatories';
import { CrossSale, ProductBusiness } from './BankBusiness';

// The screens of spec 11 in S1: institutions (SCR-INS-01/02), the relationship with its coverage, products and
// channels (SCR-INS-05), the bank set-up wizard (SCR-INS-06, FR-INS-014), bank accounts masked with the audited reveal
// (SCR-ACC-01), and base rates with their values on a date (FR-CAT-015/016).

interface Institution { id: string; code: string; refCode?: string | null; nameAr: string; nameEn?: string; type: string; country: string; locality: string; swiftBic?: string; status: string; etag: string }
interface Warning { code: string; count?: number; institution?: string; company?: string; name?: string }
interface Named { id: string; companyCode?: string; code?: string; nameAr?: string; nameEn?: string }

const name = (lang: string, x: { nameAr?: string; nameEn?: string }) => (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '';

/** The warnings of the API, by code, in words. */
const WARNINGS: Record<string, string> = {
  'W-INS-NO-DEFAULT-CONTACT': 'Products without a default contact',
  'W-INS-NO-RM': 'A relationship without a relationship manager:',
  'W-INS-NO-MANAGER': 'Contacts left without a manager',
  'V-INS-02-BIC': 'The BIC is used by another institution:',
  'V-INS-02-NAME': 'A similar name to another institution:',
  'V-INS-05-CUSTOMER-NO': 'The customer number is used for another company:',
};

function Warnings({ items }: { items: Warning[] }) {
  const { t } = useI18n();
  if (items.length === 0) return null;
  return (
    <ul className="notice">
      {items.map((w, i) => <li key={i}>{t(WARNINGS[w.code] ?? w.code)}{w.count !== undefined ? ` (${w.count})` : ''}{w.institution ? ` ${w.institution}` : ''}{w.company ? ` ${w.company}` : ''}</li>)}
    </ul>
  );
}

export function Institutions() {
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const [items, setItems] = useState<Institution[]>([]);
  const [q, setQ] = useState('');
  const [draft, setDraft] = useState({ code: '', refCode: '', nameAr: '', nameEn: '', type: 'BANK', country: 'SA', swiftBic: '' });
  const find = useCallback(async () => setItems((await api<{ items: Institution[] }>('GET', `/institutions${q ? '?q=' + encodeURIComponent(q) : ''}`)).items), [q]);
  useEffect(() => { void find(); }, []);   // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <>
      <section className="card">
        <h1>{t('Banks and lenders')}</h1>
        <form className="actions" onSubmit={e => { e.preventDefault(); void find(); }}>
          <input placeholder={t('Code, name, BIC or customer number')} value={q} onChange={e => setQ(e.target.value)} />
          <button type="submit">{t('Search')}</button>
          {can(me, 'ins.wizard.run') && <Link to="/bank-setup">{t('Bank set-up wizard')}</Link>}
        </form>
        <Table rows={items} columns={[
          { header: 'Code', cell: i => <Link to={`/institutions/${i.id}`} dir="ltr">{i.code}</Link> },
          { header: 'Name', cell: i => name(lang, i) },
          { header: 'Type', cell: i => t(i.type) },
          { header: 'Locality', cell: i => t(i.locality) },
          { header: 'BIC', cell: i => <span dir="ltr">{i.swiftBic ?? ''}</span> },
          { header: 'Status', cell: i => <Chip s={i.status} /> },
        ]} />
      </section>
      {can(me, 'ins.manage') && (
        <Form title="New institution" submit="Create" onSubmit={async () => {
          const r = await api<{ id: string }>('POST', '/institutions', { ...draft, swiftBic: draft.swiftBic || undefined, refCode: draft.refCode || undefined });
          nav(`/institutions/${r.id}`);
        }}>
          <Field label="Code" value={draft.code} onChange={v => setDraft({ ...draft, code: v.toUpperCase() })} />
          <Field label="Bank code" value={draft.refCode} onChange={v => setDraft({ ...draft, refCode: v.toUpperCase() })}
            hint="The three capital letters of the bank in the facility references, such as ANB in CAP-SA05-ANB-26." />
          <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
          <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
          <Select label="Type" value={draft.type} onChange={v => setDraft({ ...draft, type: v })}
            options={['BANK', 'FINANCE_CO', 'INVESTMENT_CO', 'FINANCIAL_CO'].map(x => ({ value: x, label: x }))} />
          <Field label="Country" value={draft.country} onChange={v => setDraft({ ...draft, country: v.toUpperCase() })} />
          <Field label="BIC" value={draft.swiftBic} onChange={v => setDraft({ ...draft, swiftBic: v.toUpperCase() })} required={false} hint="8 or 11 characters" />
        </Form>
      )}
    </>
  );
}

interface InstitutionDetailData {
  institution: Institution;
  units: { id: string; parent?: string; unitType: string; nameAr: string; isActive: boolean }[];
  contacts: { id: string; fullNameAr: string; fullNameEn?: string; jobTitleAr?: string; status: string; partyCode?: string; contactMethods: { kind: string; value: string }[] }[];
  relationships: { id: string; companyName: string; customerNo?: string; status: string }[];
}

export function InstitutionDetail() {
  const { id } = useParams();
  const { t } = useI18n();
  const me = useMe();
  const [d, setD] = useState<InstitutionDetailData | null>(null);
  const [contact, setContact] = useState({ fullNameAr: '', fullNameEn: '', jobTitleAr: '', kind: 'MOBILE', value: '' });
  const [unit, setUnit] = useState({ unitType: 'BRANCH', nameAr: '', parent: '' });
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => setD((await apiWithETag<InstitutionDetailData>(`/institutions/${id}`)).data), [id]);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const i = d.institution;
  const act = async (path: string) => {
    try { await api('POST', path, {}); setNotice({ ok: 'Saved.' }); await load(); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{i.code}</span> {i.nameAr}</h1>
        <p>{t(i.type)} · {i.country} · {t(i.locality)} · {t(i.status)} {i.swiftBic && <span dir="ltr">· {i.swiftBic}</span>}
          {' · '}{t('Bank code')}: <span dir="ltr">{i.refCode ?? '—'}</span></p>
        {can(me, 'ins.manage') && i.status !== 'INACTIVE' && (
          <form className="row" onSubmit={e => {
            e.preventDefault();
            const v = (new FormData(e.currentTarget).get('refCode') as string).trim().toUpperCase();
            void (async () => {
              try { await api('PATCH', `/institutions/${id}`, { refCode: v }, i.etag); setNotice({ ok: t('Saved.') }); await load(); }
              catch (x) { setNotice({ error: message(x) }); }
            })();
          }}>
            <label><span>{t('Bank code')}</span><input name="refCode" defaultValue={i.refCode ?? ''} maxLength={3} dir="ltr" /></label>
            <button type="submit">{t('Save')}</button>
          </form>
        )}
        <Notice error={notice.error} ok={notice.ok} />
        {can(me, 'ins.deactivate') && i.status === 'ACTIVE' && <button onClick={() => void act(`/institutions/${id}/actions/deactivate`)}>{t('Deactivate')}</button>}
        {can(me, 'ins.manage') && i.status !== 'ACTIVE' && <button onClick={() => void act(`/institutions/${id}/actions/activate`)}>{t('Activate')}</button>}
      </section>
      <section className="card">
        <h2>{t('Relationships')}</h2>
        <Table rows={d.relationships} columns={[
          { header: 'Company', cell: r => <Link to={`/relationships/${r.id}`}>{r.companyName}</Link> },
          { header: 'Customer number', cell: r => <span dir="ltr">{r.customerNo ?? ''}</span> },
          { header: 'Status', cell: r => <Chip s={r.status} /> },
        ]} />
      </section>
      <CrossSale url={`/institutions/${id}/business`} showCompany />
      <section className="card">
        <h2>{t('Contacts')}</h2>
        <Table rows={d.contacts} columns={[
          { header: 'Name', cell: k => k.fullNameAr },
          { header: 'Job title', cell: k => k.jobTitleAr ?? '' },
          { header: 'Contact', cell: k => <span dir="ltr">{k.contactMethods.map(m => m.value).join(' · ')}</span> },
          { header: 'Party', cell: k => <span dir="ltr">{k.partyCode ?? ''}</span> },
          { header: 'Status', cell: k => <Chip s={k.status} /> },
        ]} />
      </section>
      {can(me, 'ins.contacts.manage') && (
        <Form title="New contact" submit="Add" onSubmit={async () => {
          await api('POST', `/institutions/${id}/contacts`, {
            fullNameAr: contact.fullNameAr, fullNameEn: contact.fullNameEn || undefined, jobTitleAr: contact.jobTitleAr || undefined,
            contactMethods: [{ kind: contact.kind, value: contact.value }],
          });
          setContact({ fullNameAr: '', fullNameEn: '', jobTitleAr: '', kind: 'MOBILE', value: '' });
          await load();
        }}>
          <Field label="Name (Arabic)" value={contact.fullNameAr} onChange={v => setContact({ ...contact, fullNameAr: v })} />
          <Field label="Name (English)" value={contact.fullNameEn} onChange={v => setContact({ ...contact, fullNameEn: v })} required={false} />
          <Field label="Job title" value={contact.jobTitleAr} onChange={v => setContact({ ...contact, jobTitleAr: v })} required={false} />
          <Select label="Contact method" value={contact.kind} onChange={v => setContact({ ...contact, kind: v })}
            options={['MOBILE', 'PHONE', 'EMAIL'].map(x => ({ value: x, label: x }))} />
          <Field label="Value" value={contact.value} onChange={v => setContact({ ...contact, value: v })} />
        </Form>
      )}
      <section className="card">
        <h2>{t('Units')}</h2>
        <Table rows={d.units} columns={[
          { header: 'Name', cell: n => n.nameAr },
          { header: 'Type', cell: n => t(n.unitType) },
          { header: 'Under', cell: n => d.units.find(p => p.id === n.parent)?.nameAr ?? '' },
        ]} />
      </section>
      {can(me, 'ins.manage') && (
        <Form title="New unit" submit="Add" onSubmit={async () => {
          await api('POST', `/institutions/${id}/units`, { unitType: unit.unitType, nameAr: unit.nameAr, parent: unit.parent || undefined });
          setUnit({ ...unit, nameAr: '' });
          await load();
        }}>
          <Select label="Type" value={unit.unitType} onChange={v => setUnit({ ...unit, unitType: v })}
            options={['BRANCH', 'DEPARTMENT', 'SECTION'].map(x => ({ value: x, label: x }))} />
          <Field label="Name (Arabic)" value={unit.nameAr} onChange={v => setUnit({ ...unit, nameAr: v })} />
          <Select label="Under" value={unit.parent} onChange={v => setUnit({ ...unit, parent: v })}
            options={[{ value: '', label: 'The institution itself' }, ...d.units.map(n => ({ value: n.id, label: n.nameAr }))]} />
        </Form>
      )}
    </>
  );
}

interface RelationshipData {
  relationship: { id: string; companyName: string; institutionCode: string; institutionName: string; customerNo?: string; status: string; startedOn?: string; closedOn?: string; etag: string };
  coverage: { id: string; contactName: string; role: string; roleName: string; rank: number; isPrimary: boolean; validFrom: string; validTo?: string }[];
  products: { id: string; product: string; productName: string; defaultContactName?: string; channel: string; isActive: boolean }[];
  openAccounts: number;
}

export function RelationshipDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [d, setD] = useState<RelationshipData | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [reason, setReason] = useState('');
  const [sheet, setSheet] = useState<{ rank: number; role: string; name: string; contactMethods?: string }[] | null>(null);
  const [selected, setSelected] = useState('');
  const [catalog, setCatalog] = useState<Named[]>([]);
  const [adding, setAdding] = useState('');
  const load = useCallback(async () => setD((await apiWithETag<RelationshipData>(`/relationships/${id}`)).data), [id]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/catalogs/products').then(r => setCatalog(r.items)).catch(() => setCatalog([])); }, []);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const r = d.relationship;
  return (
    <>
      <section className="card">
        <h1>{r.companyName} · <span dir="ltr">{r.institutionCode}</span></h1>
        <p>{t('Customer number')}: <span dir="ltr">{r.customerNo ?? '—'}</span> · {t(r.status)} · {t('Open accounts')}: {d.openAccounts}</p>
        <Notice error={notice.error} ok={notice.ok} />
        {can(me, 'ins.export') && <button onClick={async () => setSheet((await api<{ levels: typeof sheet }>('GET', `/relationships/${id}/escalation`)).levels)}>{t('Escalation sheet')}</button>}
        {sheet && <ol>{sheet.map(l => <li key={l.rank}>{l.role}: {l.name} <span dir="ltr">{l.contactMethods}</span></li>)}</ol>}
      </section>
      <section className="card">
        <h2>{t('Coverage')}</h2>
        <Table rows={d.coverage} columns={[
          { header: 'Rank', cell: c => c.rank },
          { header: 'Role', cell: c => c.roleName },
          { header: 'Contact', cell: c => c.contactName },
          { header: 'From', cell: c => c.validFrom },
          { header: 'To', cell: c => c.validTo ?? '' },
        ]} />
      </section>
      <section className="card">
        <h2>{t('Products and channels')}</h2>
        <Table rows={d.products} columns={[
          { header: 'Product', cell: p => <button type="button" className="link" onClick={() => setSelected(p.product)}>{p.productName}</button> },
          { header: 'Default contact', cell: p => p.defaultContactName ?? t('The relationship manager') },
          { header: 'Channel', cell: p => t(p.channel) },
          { header: 'Status', cell: p => <Chip s={p.isActive ? 'ACTIVE' : 'DISABLED'} /> },
        ]} />
      </section>
      {can(me, 'ins.relationship.manage') && r.status !== 'CLOSED' && (
        <Form title="Add a product dealt in with the bank" submit="Add" onSubmit={async () => {
          await api('PUT', `/relationships/${id}/products/${adding}`, {});
          setSelected(adding); setAdding(''); await load();
        }}>
          <Select label="Product" value={adding} onChange={setAdding}
            options={[{ value: '', label: '—' }, ...catalog.filter(c => !d.products.some(p => p.product === c.code)).map(c => ({ value: c.code ?? '', label: name(lang, c) }))]} />
        </Form>
      )}
      {selected && <ProductBusiness key={selected} relationship={id!} product={selected} productName={d.products.find(p => p.product === selected)?.productName ?? selected}
        canEdit={can(me, 'ins.relationship.manage') && r.status !== 'CLOSED'} />}
      <CrossSale url={`/relationships/${id}/business`} />
      {can(me, 'ins.deactivate') && r.status !== 'CLOSED' && (
        <Form title="Close the relationship" submit="Close" onSubmit={async () => {
          await api('POST', `/relationships/${id}/actions/close`, { reason });
          setNotice({ ok: 'Saved.' });
          await load();
        }}>
          <Field label="Reason" value={reason} onChange={setReason} />
        </Form>
      )}
      <SignatoriesPanel relationship={id!} />
    </>
  );
}

interface WizardContact { key: string; fullNameAr: string; mobile: string }

/** FR-INS-014: institution, companies, products and channels, contacts and coverage, review; one transaction. */
export function BankSetup() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const [step, setStep] = useState(1);
  const [institution, setInstitution] = useState({ code: '', refCode: '', nameAr: '', nameEn: '', type: 'BANK', country: 'SA', swiftBic: '' });
  const [companies, setCompanies] = useState<Named[]>([]);
  const [products, setProducts] = useState<Named[]>([]);
  const [chosen, setChosen] = useState<Record<string, { customerNo: string; rm: string }>>({});
  const [matrix, setMatrix] = useState<Record<string, { channel: string; contact: string }>>({});
  const [contacts, setContacts] = useState<WizardContact[]>([]);
  const [contact, setContact] = useState({ fullNameAr: '', mobile: '' });
  const [review, setReview] = useState<{ summary: Record<string, number>; warnings: Warning[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(1);
  useEffect(() => {
    void api<{ items: Named[] }>('GET', '/companies').then(r => setCompanies(r.items));
    void api<{ items: Named[] }>('GET', '/catalogs/products').then(r => setProducts(r.items));
  }, []);
  const body = (dryRun: boolean) => ({
    dryRun,
    institution: { ...institution, swiftBic: institution.swiftBic || undefined, refCode: institution.refCode || undefined },
    contacts: contacts.map(c => ({ key: c.key, fullNameAr: c.fullNameAr, contactMethods: [{ kind: 'MOBILE', value: c.mobile }] })),
    companies: Object.entries(chosen).map(([company, c]) => ({
      company, customerNo: c.customerNo || undefined, coverage: c.rm ? [{ contactKey: c.rm, role: 'RM' }] : [],
    })),
    products: Object.entries(matrix).map(([cell, m]) => {
      const [company, product] = cell.split('|');
      return { company, product, channel: m.channel, defaultContactKey: m.contact || undefined };
    }),
  });
  const run = async (dryRun: boolean) => {
    setError(null);
    try {
      const r = await api<{ id?: string; summary: Record<string, number>; warnings: Warning[] }>('POST', '/bank-setup', body(dryRun));
      if (dryRun) { setReview(r); setStep(5); } else nav(`/institutions/${r.id}`);
    } catch (e) { setError(message(e)); }
  };
  const companyIds = Object.keys(chosen);
  return (
    <section className="card">
      <h1>{t('Bank set-up wizard')}</h1>
      <p className="muted">{t('Step {n} of 5', { n: String(step) })}</p>
      {step === 1 && <>
        <Field label="Code" value={institution.code} onChange={v => setInstitution({ ...institution, code: v.toUpperCase() })} />
        <Field label="Bank code" value={institution.refCode} onChange={v => setInstitution({ ...institution, refCode: v.toUpperCase() })}
          hint="Three capital letters in the facility references." />
        <Field label="Name (Arabic)" value={institution.nameAr} onChange={v => setInstitution({ ...institution, nameAr: v })} />
        <Field label="Name (English)" value={institution.nameEn} onChange={v => setInstitution({ ...institution, nameEn: v })} />
        <Field label="Country" value={institution.country} onChange={v => setInstitution({ ...institution, country: v.toUpperCase() })} />
        <Field label="BIC" value={institution.swiftBic} onChange={v => setInstitution({ ...institution, swiftBic: v.toUpperCase() })} required={false} />
      </>}
      {step === 2 && companies.map(c => (
        <label key={c.id} className="row">
          <input type="checkbox" checked={c.id in chosen} onChange={e => {
            const next = { ...chosen };
            if (e.target.checked) next[c.id] = { customerNo: '', rm: '' }; else delete next[c.id];
            setChosen(next);
          }} />
          <span>{name(lang, c)}</span>
          {chosen[c.id] && <input placeholder={t('Customer number')} dir="ltr" value={chosen[c.id]!.customerNo}
            onChange={e => setChosen({ ...chosen, [c.id]: { ...chosen[c.id]!, customerNo: e.target.value } })} />}
        </label>
      ))}
      {step === 3 && <>
        <div className="actions">
          <input placeholder={t('Name (Arabic)')} value={contact.fullNameAr} onChange={e => setContact({ ...contact, fullNameAr: e.target.value })} />
          <input placeholder={t('Mobile')} dir="ltr" value={contact.mobile} onChange={e => setContact({ ...contact, mobile: e.target.value })} />
          <button type="button" onClick={() => {
            if (!contact.fullNameAr || !contact.mobile) return;
            setContacts([...contacts, { key: 'k' + seq.current++, ...contact }]);
            setContact({ fullNameAr: '', mobile: '' });
          }}>{t('Add')}</button>
        </div>
        <ul>{contacts.map(c => <li key={c.key}>{c.fullNameAr} <span dir="ltr">{c.mobile}</span></li>)}</ul>
        {companyIds.map(cid => (
          <label key={cid}>
            <span>{t('Relationship manager')}: {name(lang, companies.find(c => c.id === cid) ?? {})}</span>
            <select value={chosen[cid]!.rm} onChange={e => setChosen({ ...chosen, [cid]: { ...chosen[cid]!, rm: e.target.value } })}>
              <option value="">—</option>{contacts.map(c => <option key={c.key} value={c.key}>{c.fullNameAr}</option>)}
            </select>
          </label>
        ))}
      </>}
      {step === 4 && (
        <table>
          <thead><tr><th>{t('Product')}</th>{companyIds.map(cid => <th key={cid}>{name(lang, companies.find(c => c.id === cid) ?? {})}</th>)}</tr></thead>
          <tbody>{products.map(p => (
            <tr key={p.code}>
              <td>{name(lang, p)}</td>
              {companyIds.map(cid => {
                const cell = `${cid}|${p.code}`;
                const m = matrix[cell];
                return (
                  <td key={cid}>
                    <input type="checkbox" checked={!!m} aria-label={`${name(lang, p)} · ${name(lang, companies.find(c => c.id === cid) ?? {})}`} onChange={e => {
                      const next = { ...matrix };
                      if (e.target.checked) next[cell] = { channel: 'MANUAL_FORM', contact: '' }; else delete next[cell];
                      setMatrix(next);
                    }} />
                    {m && <>
                      <select aria-label={t('Channel')} value={m.channel} onChange={e => setMatrix({ ...matrix, [cell]: { ...m, channel: e.target.value } })}>
                        <option value="MANUAL_FORM">{t('MANUAL_FORM')}</option><option value="BANK_PORTAL">{t('BANK_PORTAL')}</option>
                      </select>
                      <select aria-label={t('Default contact')} value={m.contact} onChange={e => setMatrix({ ...matrix, [cell]: { ...m, contact: e.target.value } })}>
                        <option value="">{t('The relationship manager')}</option>{contacts.map(c => <option key={c.key} value={c.key}>{c.fullNameAr}</option>)}
                      </select>
                    </>}
                  </td>
                );
              })}
            </tr>
          ))}</tbody>
        </table>
      )}
      {step === 5 && review && <>
        <ul>{Object.entries(review.summary).map(([k, v]) => <li key={k}>{t(k)}: {v}</li>)}</ul>
        <Warnings items={review.warnings} />
      </>}
      <Notice error={error} />
      <div className="actions">
        {step > 1 && <button type="button" onClick={() => setStep(step - 1)}>{t('Back')}</button>}
        {step < 4 && <button type="button" onClick={() => setStep(step + 1)}>{t('Next')}</button>}
        {step === 4 && <button type="button" onClick={() => void run(true)}>{t('Review')}</button>}
        {step === 5 && <button type="button" onClick={() => void run(false)}>{t('Create')}</button>}
      </div>
    </section>
  );
}

interface Account {
  id: string; companyName: string; institutionCode: string; type: string; currency: string; nickname?: string; accountNumber: string; iban?: string; status: string;
  isVirtual: boolean;
}

export function Accounts() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [items, setItems] = useState<Account[]>([]);
  const [revealed, setRevealed] = useState<Record<string, { accountNumber: string; iban?: string }>>({});
  const [companies, setCompanies] = useState<Named[]>([]);
  const [banks, setBanks] = useState<Institution[]>([]);
  const [draft, setDraft] = useState({ company: '', institution: '', type: 'CURRENT', currency: 'SAR', accountNumber: '', iban: '', nickname: '' });
  const [needsRelationship, setNeedsRelationship] = useState(false);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const timers = useRef<number[]>([]);
  const load = useCallback(async () => setItems((await api<{ items: Account[] }>('GET', '/accounts')).items), []);
  useEffect(() => {
    void load();
    void api<{ items: Named[] }>('GET', '/companies').then(r => setCompanies(r.items));
    void api<{ items: Institution[] }>('GET', '/institutions?status=ACTIVE').then(r => setBanks(r.items));
    const pending = timers.current;
    return () => pending.forEach(x => window.clearTimeout(x));
  }, [load]);
  const reveal = async (id: string) => {
    try {
      const r = await api<{ accountNumber: string; iban?: string; remaskSeconds: number }>('POST', `/accounts/${id}/actions/reveal`, {});
      setRevealed(v => ({ ...v, [id]: r }));
      timers.current.push(window.setTimeout(() => setRevealed(v => { const n = { ...v }; delete n[id]; return n; }), r.remaskSeconds * 1000));
    } catch (e) { setNotice({ error: message(e) }); }
  };
  const create = async (createRelationship: boolean) => {
    try {
      await api('POST', '/accounts', { ...draft, iban: draft.iban || undefined, nickname: draft.nickname || undefined, createRelationship: createRelationship || undefined });
      setNeedsRelationship(false);
      setNotice({ ok: 'Saved.' });
      await load();
    } catch (e) {
      if ((e as { problem?: { code: string } }).problem?.code === 'V-ACC-RELATIONSHIP-REQUIRED') setNeedsRelationship(true);
      else throw e;
    }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Bank accounts')}</h1>
        <Notice error={notice.error} ok={notice.ok} />
        <Table rows={items} columns={[
          { header: 'Company', cell: a => a.companyName },
          { header: 'Bank', cell: a => <span dir="ltr">{a.institutionCode}</span> },
          { header: 'Type', cell: a => t(a.type) },
          { header: 'Currency', cell: a => a.currency },
          { header: 'Account number', cell: a => <code dir="ltr">{revealed[a.id]?.accountNumber ?? a.accountNumber}</code> },
          { header: 'IBAN', cell: a => <code dir="ltr">{revealed[a.id]?.iban ?? a.iban ?? ''}</code> },
          { header: 'Status', cell: a => <Chip s={a.status} /> },
          { header: '', cell: a => can(me, 'acc.reveal') && !revealed[a.id] ? <button className="link" onClick={() => void reveal(a.id)}>{t('Reveal')}</button> : null },
        ]} />
      </section>
      {can(me, 'acc.manage') && (
        <Form title="New bank account" submit="Create" onSubmit={() => create(false)}>
          <Select label="Company" value={draft.company} onChange={v => setDraft({ ...draft, company: v })}
            options={[{ value: '', label: '—' }, ...companies.map(c => ({ value: c.id, label: name(lang, c) }))]} />
          <Select label="Bank" value={draft.institution} onChange={v => setDraft({ ...draft, institution: v })}
            options={[{ value: '', label: '—' }, ...banks.map(b => ({ value: b.id, label: `${b.code} ${b.nameAr}` }))]} />
          <Select label="Type" value={draft.type} onChange={v => setDraft({ ...draft, type: v })}
            options={['CURRENT', 'PAYROLL', 'POS', 'LOAN', 'LC_COLLECTION', 'MARGIN', 'DEPOSIT'].map(x => ({ value: x, label: x }))} />
          <Field label="Currency" value={draft.currency} onChange={v => setDraft({ ...draft, currency: v.toUpperCase() })} />
          <Field label="Account number" value={draft.accountNumber} onChange={v => setDraft({ ...draft, accountNumber: v })} />
          <Field label="IBAN" value={draft.iban} onChange={v => setDraft({ ...draft, iban: v.toUpperCase() })} required={false} />
          <Field label="Nickname" value={draft.nickname} onChange={v => setDraft({ ...draft, nickname: v })} required={false} />
          {needsRelationship && (
            <div className="notice">
              <p>{t('The company has no relationship with this institution: confirm to create it.')}</p>
              <button type="button" onClick={() => void create(true)}>{t('Create the relationship and the account')}</button>
            </div>
          )}
        </Form>
      )}
    </>
  );
}

interface Rate { code: string; nameAr: string; nameEn?: string; kind: string; institutionCode?: string; familyCode: string; tenor: string; currency: string; aliases: string[] }

export function BaseRates() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [items, setItems] = useState<Rate[]>([]);
  const [q, setQ] = useState('');
  const [selected, setSelected] = useState<string | null>(null);
  const [values, setValues] = useState<{ id: string; effectiveDate: string; valuePct: number; status: string; sourceNote?: string }[]>([]);
  const [entry, setEntry] = useState({ effectiveDate: '', valuePct: '' });
  const [asOf, setAsOf] = useState('');
  const [answer, setAnswer] = useState<string | null>(null);
  const find = useCallback(async () => setItems((await api<{ items: Rate[] }>('GET', `/base-rates${q ? '?q=' + encodeURIComponent(q) : ''}`)).items), [q]);
  useEffect(() => { void find(); }, []);   // eslint-disable-line react-hooks/exhaustive-deps
  const open = async (code: string) => {
    setSelected(code);
    setValues((await api<{ values: typeof values }>('GET', `/base-rates/${code}`)).values);
  };
  return (
    <>
      <section className="card">
        <h1>{t('Base rates')}</h1>
        <form className="actions" onSubmit={e => { e.preventDefault(); void find(); }}>
          <input placeholder={t('Code, family or alias')} value={q} onChange={e => setQ(e.target.value)} />
          <button type="submit">{t('Search')}</button>
        </form>
        <Table rows={items} columns={[
          { header: 'Code', cell: r => <button className="link" dir="ltr" onClick={() => void open(r.code)}>{r.code}</button> },
          { header: 'Name', cell: r => name(lang, r) },
          { header: 'Kind', cell: r => t(r.kind) + (r.institutionCode ? ` · ${r.institutionCode}` : '') },
          { header: 'Tenor', cell: r => r.tenor },
          { header: 'Currency', cell: r => r.currency },
          { header: 'Aliases', cell: r => r.aliases.join(', ') },
        ]} />
      </section>
      {selected && (
        <section className="card">
          <h2 dir="ltr">{selected}</h2>
          <Table rows={values} columns={[
            { header: 'Effective date', cell: v => v.effectiveDate },
            { header: 'Value (%)', cell: v => <span dir="ltr">{v.valuePct}</span> },
            { header: 'Status', cell: v => <Chip s={v.status} /> },
            { header: 'Note', cell: v => v.sourceNote ?? '' },
          ]} />
          <form className="actions" onSubmit={async e => {
            e.preventDefault();
            const r = await api<{ status: string; valuePct?: number; effectiveDate?: string }>('GET', `/services/base-rate?rate=${selected}${asOf ? '&asOf=' + asOf : ''}`);
            setAnswer(r.status === 'VALUE' ? `${r.valuePct} (${r.effectiveDate})` : t('NO_VALUE'));
          }}>
            <input type="date" value={asOf} onChange={e => setAsOf(e.target.value)} />
            <button type="submit">{t('Value on this date')}</button>
            {answer && <strong dir="ltr">{answer}</strong>}
          </form>
          {can(me, 'cat.baserate.enter') && (
            <Form title="Enter a value" submit="Save" onSubmit={async () => {
              await api('POST', `/base-rates/${selected}/values`, { effectiveDate: entry.effectiveDate, valuePct: Number(entry.valuePct) });
              setEntry({ effectiveDate: '', valuePct: '' });
              await open(selected);
            }}>
              <Field label="Effective date" type="date" value={entry.effectiveDate} onChange={v => setEntry({ ...entry, effectiveDate: v })} />
              <Field label="Value (%)" value={entry.valuePct} onChange={v => setEntry({ ...entry, valuePct: v })} />
            </Form>
          )}
        </section>
      )}
    </>
  );
}
