import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-COL-01: the register of collateral by type and status, the editor of each typed part (guarantee with its
// guarantor's badge, note, insurance, cash margin, property and its valuation schedule), approval by another user,
// release with its date, reason and document, and new versions. The facility tab links collateral through the
// facility's draft revision and shows the coverage matrix (R-COL-01, no single total). The party panel checks a
// person against a bank's completeness profile and prints the guarantor pack, masked unless the user may see the
// full numbers.

interface Named { id: string; code?: string; nameAr?: string | null; nameEn?: string | null }
const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 2 });
const num = (v: string) => v === '' ? undefined : Number(v);

interface Collateral {
  id: string; root: string; type: { code: string; nameAr: string; nameEn?: string; structure: string }; titleAr: string; owner?: Named | null; status: string;
  approvalState: string; grantedOn?: string; releasedOn?: string; releaseReason?: string; supersedes: boolean; attributes?: Record<string, unknown> | null;
}

const types = ['PERSONAL_GUARANTEE', 'CORPORATE_GUARANTEE', 'PROMISSORY_NOTE', 'INSURANCE_ASSIGNMENT', 'CASH_MARGIN', 'REAL_ESTATE', 'SET_OFF', 'NEGATIVE_PLEDGE', 'OTHER'];

export function Collaterals() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const me = useMe();
  const [rows, setRows] = useState<Collateral[]>([]);
  const [filter, setFilter] = useState({ type: '', status: '' });
  const [parties, setParties] = useState<Named[]>([]);
  const [banks, setBanks] = useState<Named[]>([]);
  const [d, setD] = useState({
    collateralType: 'PERSONAL_GUARANTEE', titleAr: '', owner: '', noSourceReason: '', guarantor: '', amountMode: 'SPECIFIED', amount: '', currency: 'SAR', noteAmount: '',
    issuedOn: '', renewalCycle: 'ANNUAL', lastRenewedOn: '', policyNo: '', insurer: '', assignedTo: '', coverageBasis: 'FULL_LIMITS', coveragePct: '', coverageAmount: '',
    sumInsured: '', policyExpiry: '', marginPct: '', marginAmount: '', deedNo: '',
  });
  const load = useCallback(async () => {
    const q = new URLSearchParams(Object.entries(filter).filter(([, v]) => v));
    setRows((await api<{ items: Collateral[] }>('GET', `/collaterals${q.size ? '?' + q : ''}`)).items);
  }, [filter]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    void api<{ items: Named[] }>('GET', '/parties').then(r => setParties(r.items)).catch(() => setParties([]));
    void api<{ items: Named[] }>('GET', '/institutions').then(r => setBanks(r.items)).catch(() => setBanks([]));
  }, []);
  const structure = (code: string) => code.endsWith('GUARANTEE') ? 'GUARANTEE' : code === 'OTHER' ? 'GENERIC' : code;
  const s = structure(d.collateralType);
  return (
    <>
      <section className="card">
        <h1>{t('Collateral')}</h1>
        <div className="row">
          <Select label="Type" value={filter.type} onChange={v => setFilter({ ...filter, type: v })} options={['', ...types].map(c => ({ value: c, label: c || 'All' }))} />
          <Select label="Status" value={filter.status} onChange={v => setFilter({ ...filter, status: v })}
            options={['', 'DRAFT', 'ACTIVE', 'RELEASED', 'EXPIRED'].map(c => ({ value: c, label: c || 'All' }))} />
        </div>
        <Table rows={rows} columns={[
          { header: 'Collateral', cell: r => <Link to={`/collaterals/${r.id}`}>{r.titleAr}</Link> },
          { header: 'Type', cell: r => name(lang, r.type) },
          { header: 'Owner', cell: r => name(lang, r.owner) },
          { header: 'Status', cell: r => <><Chip s={r.status} />{r.status === 'DRAFT' && r.supersedes && <small className="muted"> ({t('New version')})</small>}</> },
        ]} />
      </section>
      {can(me, 'col.manage') && <Form title="Register a collateral" submit="Create" onSubmit={async () => {
        const body: Record<string, unknown> = { collateralType: d.collateralType, titleAr: d.titleAr, owner: d.owner || undefined, noSourceReason: d.noSourceReason };
        if (s === 'GUARANTEE') body.guarantee = { guarantor: d.guarantor, amountMode: d.amountMode, amount: d.amountMode === 'SPECIFIED' ? num(d.amount) : undefined, currency: d.amountMode === 'SPECIFIED' ? d.currency : undefined };
        if (s === 'PROMISSORY_NOTE') body.note = { amount: num(d.noteAmount), currency: d.currency, issuedOn: d.issuedOn, renewalCycle: d.renewalCycle, lastRenewedOn: d.lastRenewedOn || undefined };
        if (s === 'INSURANCE_ASSIGNMENT') body.insurance = {
          policyNo: d.policyNo, insurerName: d.insurer, assignedTo: d.assignedTo, coverageBasis: d.coverageBasis, coveragePct: d.coverageBasis === 'PCT_OF_LIMIT' ? num(d.coveragePct) : undefined,
          coverageAmount: d.coverageBasis === 'FIXED_AMOUNT' ? num(d.coverageAmount) : undefined, sumInsured: num(d.sumInsured), currency: d.currency, policyExpiry: d.policyExpiry,
        };
        if (s === 'CASH_MARGIN') body.cashMargin = { pct: num(d.marginPct), amount: num(d.marginAmount) };
        if (s === 'REAL_ESTATE') body.attributes = { DEED_NO: d.deedNo };
        const r = await api<{ id: string }>('POST', '/collaterals', body);
        nav(`/collaterals/${r.id}`);
      }}>
        <Select label="Type" value={d.collateralType} onChange={v => setD({ ...d, collateralType: v })} options={types.map(c => ({ value: c, label: c }))} />
        <Field label="Title" value={d.titleAr} onChange={v => setD({ ...d, titleAr: v })} />
        <Select label="Owner" value={d.owner} onChange={v => setD({ ...d, owner: v })} options={[{ value: '', label: '' }, ...parties.map(p => ({ value: p.id, label: name(lang, p) }))]} />
        {s === 'GUARANTEE' && <>
          <Select label="Guarantor" value={d.guarantor} onChange={v => setD({ ...d, guarantor: v })} options={[{ value: '', label: '' }, ...parties.map(p => ({ value: p.id, label: name(lang, p) }))]} />
          <Select label="Amount" value={d.amountMode} onChange={v => setD({ ...d, amountMode: v })} options={['SPECIFIED', 'UNSPECIFIED'].map(m => ({ value: m, label: m }))} />
          {d.amountMode === 'SPECIFIED' && <Field label="Guaranteed amount" value={d.amount} onChange={v => setD({ ...d, amount: v })} type="number" />}
        </>}
        {s === 'PROMISSORY_NOTE' && <>
          <Field label="Note amount" value={d.noteAmount} onChange={v => setD({ ...d, noteAmount: v })} type="number" />
          <Field label="Issue date" value={d.issuedOn} onChange={v => setD({ ...d, issuedOn: v })} type="date" />
          <Select label="Renewal" value={d.renewalCycle} onChange={v => setD({ ...d, renewalCycle: v })} options={['ANNUAL', 'NONE'].map(m => ({ value: m, label: m }))} />
          <Field label="Last renewal" value={d.lastRenewedOn} onChange={v => setD({ ...d, lastRenewedOn: v })} type="date" required={false} />
        </>}
        {s === 'INSURANCE_ASSIGNMENT' && <>
          <Field label="Policy number" value={d.policyNo} onChange={v => setD({ ...d, policyNo: v })} />
          <Field label="Insurer" value={d.insurer} onChange={v => setD({ ...d, insurer: v })} />
          <Select label="Bank" value={d.assignedTo} onChange={v => setD({ ...d, assignedTo: v })} options={[{ value: '', label: '' }, ...banks.map(b => ({ value: b.id, label: `${b.code} ${name(lang, b)}` }))]} />
          <Select label="Coverage" value={d.coverageBasis} onChange={v => setD({ ...d, coverageBasis: v })} options={['FULL_LIMITS', 'PCT_OF_LIMIT', 'FIXED_AMOUNT'].map(m => ({ value: m, label: m }))} />
          {d.coverageBasis === 'PCT_OF_LIMIT' && <Field label="Percent of the limit" value={d.coveragePct} onChange={v => setD({ ...d, coveragePct: v })} type="number" />}
          {d.coverageBasis === 'FIXED_AMOUNT' && <Field label="Amount to cover" value={d.coverageAmount} onChange={v => setD({ ...d, coverageAmount: v })} type="number" />}
          <Field label="Sum insured" value={d.sumInsured} onChange={v => setD({ ...d, sumInsured: v })} type="number" />
          <Field label="Policy expiry" value={d.policyExpiry} onChange={v => setD({ ...d, policyExpiry: v })} type="date" />
        </>}
        {s === 'CASH_MARGIN' && <>
          <Field label="Margin %" value={d.marginPct} onChange={v => setD({ ...d, marginPct: v })} type="number" required={false} />
          <Field label="Margin amount" value={d.marginAmount} onChange={v => setD({ ...d, marginAmount: v })} type="number" required={false} />
        </>}
        {s === 'REAL_ESTATE' && <Field label="Title deed number" value={d.deedNo} onChange={v => setD({ ...d, deedNo: v })} />}
        {['GUARANTEE', 'PROMISSORY_NOTE', 'INSURANCE_ASSIGNMENT', 'CASH_MARGIN'].includes(s) && <Field label="Currency" value={d.currency} onChange={v => setD({ ...d, currency: v })} />}
        <Field label="Source (or why there is none)" value={d.noSourceReason} onChange={v => setD({ ...d, noSourceReason: v })} />
      </Form>}
    </>
  );
}

interface Detail {
  collateral: Collateral;
  guarantee?: { guarantor: Named & { kind: string }; amountMode: string; amount?: number; currency?: string; identity?: string; identityExpiry?: string } | null;
  note?: { amount: number; currency: string; issuedOn: string; renewalCycle: string; lastRenewedOn?: string; nextRenewalDue?: string; signers: Named[] } | null;
  insurance?: { policyNo: string; insurer: string; bank: string; coverageBasis: string; sumInsured: number; currency: string; policyExpiry: string } | null;
  valuations: { phaseNo: number; fromYear: number; toYear?: number; requiredValuerCount: number; frequencyMonths: number; lastValuationOn?: string; lastValuationAmount?: number }[];
  nextValuations: { date: string; phaseNo: number; valuers: number }[];
  versions: { id: string; status: string; approvalState: string }[];
  facilities: { id: string; facilityNo: string; linkedOn: string; unlinkedOn?: string }[];
}

export function CollateralDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [d, setD] = useState<Detail | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [release, setRelease] = useState({ releasedOn: '', reason: '', document: '' });
  const [renewedOn, setRenewedOn] = useState('');
  const load = useCallback(async () => setD(await api<Detail>('GET', `/collaterals/${id}`)), [id]);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const k = d.collateral;
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{k.titleAr} <small className="muted">{name(lang, k.type)} · {t(k.status)}</small></h1>
        <Notice {...notice} />
        {k.owner && <p>{t('Owner')}: <Link to={`/parties/${k.owner.id}`}>{name(lang, k.owner)}</Link></p>}
        {d.guarantee && <dl className="grid">
          <dt>{t('Guarantor')}</dt><dd><Link to={`/parties/${d.guarantee.guarantor.id}`}>{name(lang, d.guarantee.guarantor)}</Link> <small className="muted">{t(d.guarantee.guarantor.kind)}</small></dd>
          <dt>{t('Amount')}</dt><dd dir="ltr">{d.guarantee.amountMode === 'SPECIFIED' ? `${amount(d.guarantee.amount)} ${d.guarantee.currency}` : t('UNSPECIFIED')}</dd>
          {d.guarantee.identity && <><dt>{t('Identity document')}</dt><dd dir="ltr">{d.guarantee.identity} {d.guarantee.identityExpiry}</dd></>}
        </dl>}
        {d.note && <dl className="grid">
          <dt>{t('Note amount')}</dt><dd dir="ltr">{amount(d.note.amount)} {d.note.currency}</dd>
          <dt>{t('Next renewal')}</dt><dd dir="ltr">{d.note.nextRenewalDue ?? t(d.note.renewalCycle)}</dd>
          <dt>{t('Signers')}</dt><dd>{d.note.signers.map(s => name(lang, s)).join('، ')}</dd>
        </dl>}
        {d.insurance && <dl className="grid">
          <dt>{t('Policy number')}</dt><dd dir="ltr">{d.insurance.policyNo}</dd>
          <dt>{t('Insurer')}</dt><dd>{d.insurance.insurer}</dd>
          <dt>{t('Coverage')}</dt><dd>{t(d.insurance.coverageBasis)}</dd>
          <dt>{t('Sum insured')}</dt><dd dir="ltr">{amount(d.insurance.sumInsured)} {d.insurance.currency}</dd>
          <dt>{t('Policy expiry')}</dt><dd dir="ltr">{d.insurance.policyExpiry}</dd>
        </dl>}
        {d.nextValuations.length > 0 && <p>{t('Next valuations')}: {d.nextValuations.map(v => <span key={v.date} dir="ltr">{v.date} ({v.valuers}) </span>)}</p>}
        <div className="actions">
          {k.status === 'DRAFT' && can(me, 'col.approve') && <button onClick={() => void act(() => api('POST', `/collaterals/${k.id}/actions/approve`, {}))}>{t('Approve')}</button>}
          {k.status === 'DRAFT' && can(me, 'col.manage') && <button className="secondary" onClick={() => void act(() => api('POST', `/collaterals/${k.id}/actions/discard`, {}))}>{t('Discard')}</button>}
          {k.status === 'ACTIVE' && d.note?.renewalCycle === 'ANNUAL' && can(me, 'col.manage') && <>
            <input type="date" value={renewedOn} onChange={e => setRenewedOn(e.target.value)} aria-label={t('Renewal date')} />
            <button className="secondary" onClick={() => void act(() => api('POST', `/collaterals/${k.id}/actions/record-renewal`, { renewedOn }))}>{t('Record the renewal')}</button>
          </>}
        </div>
      </section>
      <section className="card">
        <h2>{t('Versions')}</h2>
        <Table rows={d.versions} columns={[
          { header: 'Version', cell: v => v.id === k.id ? <b>{t('This version')}</b> : <Link to={`/collaterals/${v.id}`}>{t('Open')}</Link> },
          { header: 'Status', cell: v => <Chip s={v.status} /> },
        ]} />
        <h2>{t('Facilities')}</h2>
        <Table rows={d.facilities} columns={[
          { header: 'Facility', cell: x => <Link to={`/facilities/${x.id}`} dir="ltr">{x.facilityNo}</Link> },
          { header: 'Linked', cell: x => <span dir="ltr">{x.linkedOn}{x.unlinkedOn && ` → ${x.unlinkedOn}`}</span> },
        ]} />
      </section>
      {k.status === 'ACTIVE' && can(me, 'col.manage') && <Form title="Release" submit="Release" onSubmit={() => act(() => api('POST', `/collaterals/${k.id}/actions/release`, release))}>
        <Field label="Release date" value={release.releasedOn} onChange={v => setRelease({ ...release, releasedOn: v })} type="date" />
        <Field label="Reason" value={release.reason} onChange={v => setRelease({ ...release, reason: v })} />
        <Field label="Release document (its id)" value={release.document} onChange={v => setRelease({ ...release, document: v })} />
      </Form>}
    </>
  );
}

interface CollLink { id: string; collateral: string; titleAr: string; type: string; limitCode?: string; linkedOn: string; unlinkedOn?: string; fromRevision: number }
interface Coverage {
  currency: string; asOf: string;
  guarantees: {
    specified: { currency: string; total: number; count: number }[]; unspecifiedCount: number; individualCount: number;
    items: { collateral: string; guarantor: Named & { kind: string }; amountMode: string; amount?: number; currency?: string; inForce: boolean; identity?: string; documents: string }[];
  };
  notes: { collateral: string; amount: number; currency: string; pctOfLimit: number; nextRenewalDue?: string; limit?: string }[];
  insurance: { collateral: string; policyNo: string; required: number; sumInsured: number; coveragePct: number; shortfall: number; expiry: string; expired: boolean }[];
  cashMargins: { collateral: string; titleAr: string; pct?: number; amount?: number; account?: string }[];
  properties: { collateral: string; titleAr: string; lastValuationOn?: string; lastValuationAmount?: number; currency?: string }[];
  flags: { setOff: boolean; negativePledge: boolean };
  released: { collateral: string; titleAr: string; releasedOn: string }[];
}

/** The collateral tab of the facility card: the links of the approved revision or of the draft, and the coverage (R-COL-01). */
export function FacilityCollateral({ id, draft, edit }: { id: string; draft: boolean; edit: boolean }) {
  const { t, lang } = useI18n();
  const [view, setView] = useState<'approved' | 'draft'>('approved');
  const [links, setLinks] = useState<CollLink[]>([]);
  const [cov, setCov] = useState<Coverage | null>(null);
  const [asOf, setAsOf] = useState('');
  const [all, setAll] = useState<Collateral[]>([]);
  const [add, setAdd] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    setLinks((await api<{ items: CollLink[] }>('GET', `/facilities/${id}/collateral-links${view === 'draft' ? '?view=draft' : ''}`)).items);
    try { setCov(await api<Coverage>('GET', `/facilities/${id}/coverage${asOf ? '?asOf=' + asOf : ''}`)); } catch { setCov(null); }
  }, [id, view, asOf]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (!draft) setView('approved'); }, [draft]);
  useEffect(() => { if (draft && edit) void api<{ items: Collateral[] }>('GET', '/collaterals').then(r => setAll(r.items.filter(c => c.status === 'ACTIVE'))); }, [draft, edit]);
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h2>{t('Collateral')}</h2>
        {draft && <div className="row">
          <button className={view === 'approved' ? '' : 'link'} onClick={() => setView('approved')}>{t('Approved')}</button>
          <button className={view === 'draft' ? '' : 'link'} onClick={() => setView('draft')}>{t('Draft')}</button>
        </div>}
        <Notice {...notice} />
        <Table rows={links} columns={[
          { header: 'Collateral', cell: l => <Link to={`/collaterals/${l.collateral}`}>{l.titleAr}</Link> },
          { header: 'Type', cell: l => t(l.type) },
          { header: 'Limit', cell: l => <span dir="ltr">{l.limitCode}</span> },
          { header: 'Linked', cell: l => <span dir="ltr">{l.linkedOn}{l.unlinkedOn && ` → ${l.unlinkedOn}`}</span> },
          { header: '', cell: l => view === 'draft' && edit && !l.unlinkedOn ? <button className="link" onClick={() => {
            const on = window.prompt(t('Unlink date (YYYY-MM-DD)')) ?? '';
            if (on) void act(() => api('POST', `/facilities/${id}/collateral-links/${l.id}/actions/unlink`, { unlinkedOn: on }));
          }}>{t('Unlink')}</button> : null },
        ]} />
        {view === 'draft' && edit && <div className="row">
          <Select label="Collateral" value={add} onChange={setAdd} options={[{ value: '', label: '' }, ...all.map(c => ({ value: c.id, label: `${c.titleAr} (${name(lang, c.type)})` }))]} />
          <button disabled={!add} onClick={() => void act(() => api('POST', `/facilities/${id}/collateral-links`, { collateral: add }))}>{t('Link')}</button>
        </div>}
      </section>
      {cov && <section className="card">
        <h2>{t('Collateral coverage')}</h2>
        <label><span>{t('As of')}</span><input type="date" value={asOf} onChange={e => setAsOf(e.target.value)} /></label>
        <p className="muted">{t('Each type is shown on its own; collateral of different types is not added up.')}</p>
        <h3>{t('Guarantees')}</h3>
        <p dir="ltr">{cov.guarantees.specified.map(s => `${amount(s.total)} ${s.currency} (${s.count})`).join(' · ')}{cov.guarantees.unspecifiedCount > 0 && <> · <span dir="auto">{t('Unspecified')}: {cov.guarantees.unspecifiedCount}</span></>}</p>
        <Table rows={cov.guarantees.items} columns={[
          { header: 'Guarantor', cell: g => <Link to={`/parties/${g.guarantor.id}`}>{name(lang, g.guarantor)}</Link> },
          { header: 'Amount', cell: g => g.amountMode === 'SPECIFIED' ? <span dir="ltr">{amount(g.amount)} {g.currency}</span> : t('UNSPECIFIED') },
          { header: 'Identity document', cell: g => <><span dir="ltr">{g.identity}</span> <span className={`badge ${g.documents === 'VALID' ? '' : g.documents === 'EXPIRING' ? 'warn' : 'error'}`}>{t(g.documents)}</span></> },
        ]} />
        <h3>{t('Promissory notes')}</h3>
        <Table rows={cov.notes} columns={[
          { header: 'Amount', cell: n => <span dir="ltr">{amount(n.amount)} {n.currency}</span> },
          { header: 'Of the limit', cell: n => <span dir="ltr">{amount(n.pctOfLimit)}%</span> },
          { header: 'Next renewal', cell: n => <span dir="ltr">{n.nextRenewalDue}</span> },
        ]} />
        <h3>{t('Insurance')}</h3>
        <Table rows={cov.insurance} columns={[
          { header: 'Policy number', cell: i => <span dir="ltr">{i.policyNo}</span> },
          { header: 'Required', cell: i => <span dir="ltr">{amount(i.required)}</span> },
          { header: 'Sum insured', cell: i => <span dir="ltr">{amount(i.sumInsured)}</span> },
          { header: 'Coverage', cell: i => <span dir="ltr" className={i.shortfall > 0 ? 'warn' : ''}>{amount(i.coveragePct)}%</span> },
          { header: 'Shortfall', cell: i => <span dir="ltr">{amount(i.shortfall)}</span> },
          { header: 'Policy expiry', cell: i => <span dir="ltr" className={i.expired ? 'error' : ''}>{i.expiry}</span> },
        ]} />
        {cov.cashMargins.length > 0 && <><h3>{t('Cash margin')}</h3>
          <Table rows={cov.cashMargins} columns={[
            { header: 'Collateral', cell: c => c.titleAr },
            { header: 'Margin', cell: c => <span dir="ltr">{c.pct != null ? `${c.pct}%` : amount(c.amount)}</span> },
            { header: 'Account', cell: c => <span dir="ltr">{c.account}</span> },
          ]} /></>}
        {cov.properties.length > 0 && <><h3>{t('Real estate')}</h3>
          <Table rows={cov.properties} columns={[
            { header: 'Collateral', cell: p => p.titleAr },
            { header: 'Last valuation', cell: p => <span dir="ltr">{amount(p.lastValuationAmount)} {p.currency} {p.lastValuationOn}</span> },
          ]} /></>}
        <p>{t('Right of set-off')}: {cov.flags.setOff ? '✔' : '—'} · {t('Negative pledge')}: {cov.flags.negativePledge ? '✔' : '—'}</p>
        {cov.released.length > 0 && <p className="muted">{t('Released')}: {cov.released.map(r => `${r.titleAr} (${r.releasedOn})`).join('، ')}</p>}
      </section>}
    </>
  );
}

interface Completeness {
  profile: { id: string; nameAr: string; nameEn: string; version: number; baseline: boolean }; applicable: number; done: number; pct: number; ready: boolean;
  nearestExpiry?: string; items: { kind: string; refCode: string; mandatory: boolean; status: string; reason?: string; expiryDate?: string }[];
}
interface Pack {
  kind: string; watermark?: string | null; generatedAt: string;
  party: { code: string; nameAr?: string; nameEn?: string; nationalityAr?: string; nationalityEn?: string; birthDate?: string; birthPlace?: string; maritalStatus?: string };
  identityDocuments: { docKind: string; issuingCountry: string; number: string; issueDate?: string; expiryDate?: string; isPrimary: boolean }[];
  addresses: { type: string; city?: string; district?: string; street?: string; building?: string; postalCode?: string }[];
  contacts: { kind: string; value: string }[]; customFields: { key: string; labelAr: string; labelEn: string; value?: string }[];
}

/** FR-PTY-024 and 026 on the party card: the completeness against a bank's profile, and the guarantor pack to print. */
export function PartyCompleteness({ id }: { id: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [banks, setBanks] = useState<Named[]>([]);
  const [bank, setBank] = useState('');
  const [c, setC] = useState<Completeness | null>(null);
  const [pack, setPack] = useState<{ pack: Pack; fingerprint: string } | null>(null);
  const [error, setError] = useState<string | undefined>();
  useEffect(() => { void api<{ items: Named[] }>('GET', '/institutions').then(r => setBanks(r.items)).catch(() => setBanks([])); }, []);
  useEffect(() => {
    void api<Completeness>('GET', `/parties/${id}/completeness${bank ? '?bank=' + bank : ''}`).then(setC).catch(e => { setC(null); setError(message(e)); });
  }, [id, bank]);
  const mayPack = can(me, 'party.pack.draft') || can(me, 'party.pack.export');
  return (
    <section className="card">
      <h2>{t('Completeness')}</h2>
      <Notice error={error} />
      <Select label="Bank" value={bank} onChange={setBank} options={[{ value: '', label: 'Baseline profile' }, ...banks.map(b => ({ value: b.id, label: `${b.code} ${name(lang, b)}` }))]} />
      {c && <>
        <p><b dir="ltr">{c.pct}%</b> ({c.done}/{c.applicable}) · {c.ready ? <span className="ok">{t('Ready to submit')}</span> : <span className="warn">{t('Not ready')}</span>}
          {' · '}{name(lang, c.profile)} v{c.profile.version}</p>
        <Table rows={c.items} columns={[
          { header: 'Item', cell: i => <>{t(i.kind)} <span dir="ltr">{i.refCode}</span></> },
          { header: 'Status', cell: i => <span className={i.status === 'COMPLETE' ? '' : i.status === 'EXPIRING_SOON' || i.status === 'NOT_APPLICABLE' ? 'warn' : 'error'}>{t(i.status)}</span> },
          { header: 'Expiry date', cell: i => <span dir="ltr">{i.expiryDate}</span> },
        ]} />
      </>}
      {mayPack && <div className="actions no-print">
        <button onClick={() => void api<{ pack: Pack; fingerprint: string }>('POST', `/parties/${id}/pack`, { bank: bank || undefined, full: can(me, 'party.pack.export') })
          .then(setPack).catch(e => setError(message(e)))}>{t('Guarantor pack')}</button>
        {pack && <button className="secondary" onClick={() => window.print()}>{t('Print')}</button>}
      </div>}
      {pack && <article className="pack" dir="rtl" lang="ar">
        {pack.pack.watermark && <div className="watermark">{t('Draft — masked numbers')}</div>}
        <h3>{t('Guarantor pack')}: {pack.pack.party.nameAr ?? pack.pack.party.nameEn}</h3>
        <dl className="grid">
          <dt>{t('Nationality')}</dt><dd>{pack.pack.party.nationalityAr}</dd>
          <dt>{t('Birth date')}</dt><dd dir="ltr">{pack.pack.party.birthDate}</dd>
          <dt>{t('Birth place')}</dt><dd>{pack.pack.party.birthPlace}</dd>
        </dl>
        <Table rows={pack.pack.identityDocuments} columns={[
          { header: 'Document', cell: x => t(x.docKind) },
          { header: 'Number', cell: x => <span dir="ltr">{x.number}</span> },
          { header: 'Expiry date', cell: x => <span dir="ltr">{x.expiryDate}</span> },
        ]} />
        <Table rows={pack.pack.addresses} columns={[
          { header: 'Address', cell: a => `${t(a.type)}: ${[a.city, a.district, a.street, a.building, a.postalCode].filter(Boolean).join('، ')}` },
        ]} />
        <Table rows={pack.pack.contacts} columns={[{ header: 'Contact', cell: x => <>{t(x.kind)} <span dir="ltr">{x.value}</span></> }]} />
        <Table rows={pack.pack.customFields} columns={[{ header: 'Field', cell: x => `${lang === 'ar' ? x.labelAr : x.labelEn}: ${x.value ?? ''}` }]} />
        <p className="muted" dir="ltr">{pack.pack.generatedAt} · SHA-256 {pack.fingerprint.slice(0, 16)}…</p>
      </article>}
    </section>
  );
}
