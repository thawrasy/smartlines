import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';
import { StatementRatios } from './Formulas';

// SCR-FIN-01 (the statements of the companies: versions, the entry grid by section with live totals and the balance,
// paste with a preview of the matches, submit, approve, return and new version) and SCR-FIN-04 (the units of a
// holding's consolidated statement: role, method, ownership against the recorded one, and the unit's own statement).
// The figures are entered in the statement's unit (1, thousands or millions) and stored times the unit (BR-FIN-002).

interface Named { id: string; nameAr?: string; nameEn?: string; isHolding?: boolean }
interface Header {
  id: string; company: Named; periodType: string; periodEnd: string; fiscalYear: number; basis: string; assurance: string; nature: string; currency: string;
  unitScale: number; auditorName?: string; auditOpinion?: string; versionNo: number; versionReason: string; status: string; entryMethod: string; balanceReason?: string;
}
interface Line {
  code: string; nameAr: string; nameEn?: string; section: string; kind: string; parent?: string; isRequired: boolean; isTotal: boolean; totalFormula?: string;
  isMain: boolean; entered?: number | null; computed?: number | null;
}
interface Check {
  totals: { code: string; computed: number; entered?: number | null; variance?: number | null; matches: boolean }[];
  balanceDifference?: number | null; balanced: boolean; missingRequired: string[]; canSubmit: boolean;
}
interface Detail { statement: Header; lines: Line[]; check: Check; versions: { id: string; versionNo: number; versionReason: string; status: string; approvedOn?: string }[]; preparedByMe: boolean }

const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 4 });
const sections = ['BS_ASSET', 'BS_LIABILITY', 'BS_EQUITY', 'IS', 'CF', 'MEMO'];
const units: Record<number, string> = { 1: 'Units', 1000: 'Thousands', 1000000: 'Millions' };

/** The totals from their components, as the server computes them (BR-FIN-001): a component with no value counts 0. */
function totals(lines: Line[], values: Record<string, number | null>): Record<string, number> {
  const byCode = new Map(lines.map(l => [l.code, l]));
  const memo: Record<string, number> = {};
  const value = (code: string, depth = 0): number => {
    const l = byCode.get(code);
    if (l?.totalFormula && depth < 20) {
      if (memo[code] != null) return memo[code];
      let sum = 0, sign = 1;
      for (const token of l.totalFormula.replace(/([+-])/g, ' $1 ').split(/\s+/).filter(Boolean)) {
        if (token === '+') sign = 1;
        else if (token === '-') sign = -1;
        else { sum += sign * value(token, depth + 1); sign = 1; }
      }
      return memo[code] = sum;
    }
    return values[code] ?? 0;
  };
  for (const l of lines) if (l.totalFormula) value(l.code);
  return memo;
}

export function Statements() {
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const [rows, setRows] = useState<Header[]>([]);
  const [companies, setCompanies] = useState<Named[]>([]);
  const [company, setCompany] = useState('');
  const [d, setD] = useState({ company: '', periodType: 'ANNUAL', periodEnd: '', basis: 'STANDALONE', assurance: 'AUDITED', nature: 'ACTUAL', currency: 'SAR', unitScale: '1000' });
  const load = useCallback(async () => setRows((await api<{ items: Header[] }>('GET', `/financial-statements${company ? `?company=${company}` : ''}`)).items), [company]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/companies').then(r => { setCompanies(r.items); setD(x => ({ ...x, company: x.company || r.items[0]?.id || '' })); }); }, []);
  const holding = companies.find(c => c.id === d.company)?.isHolding ?? false;
  return (
    <>
      <section className="card">
        <h1>{t('Financial statements')}</h1>
        <Select label="Company" value={company} onChange={setCompany} options={[{ value: '', label: 'All companies' }, ...companies.map(c => ({ value: c.id, label: name(lang, c) }))]} />
        <Table rows={rows} columns={[
          { header: 'Company', cell: s => name(lang, s.company) },
          { header: 'Period end', cell: s => <Link to={`/financial-statements/${s.id}`} dir="ltr">{s.periodEnd}</Link> },
          { header: 'Period', cell: s => t(s.periodType) },
          { header: 'Basis', cell: s => t(s.basis) },
          { header: 'Assurance', cell: s => t(s.assurance) },
          { header: 'Version', cell: s => <>{s.versionNo} <small className="muted">{t(s.versionReason)}</small></> },
          { header: 'Status', cell: s => t(s.status) },
        ]} />
      </section>
      {can(me, 'fin.stmt.enter') && <Form title="New statement" submit="Create" onSubmit={async () => {
        const r = await api<{ id: string }>('POST', '/financial-statements', { ...d, unitScale: Number(d.unitScale), assurance: d.nature === 'BUDGET' ? 'MANAGEMENT' : d.assurance });
        nav(`/financial-statements/${r.id}`);
      }}>
        <Select label="Company" value={d.company} onChange={v => setD({ ...d, company: v, basis: 'STANDALONE' })} options={companies.map(c => ({ value: c.id, label: name(lang, c) }))} />
        <Select label="Period" value={d.periodType} onChange={v => setD({ ...d, periodType: v })} options={['ANNUAL', 'SEMIANNUAL', 'QUARTERLY', 'MONTHLY'].map(v => ({ value: v, label: v }))} />
        <Field label="Period end" value={d.periodEnd} onChange={v => setD({ ...d, periodEnd: v })} type="date" />
        <Select label="Basis" value={d.basis} onChange={v => setD({ ...d, basis: v })} options={(holding ? ['STANDALONE', 'CONSOLIDATED'] : ['STANDALONE']).map(v => ({ value: v, label: v }))} />
        <Select label="Nature" value={d.nature} onChange={v => setD({ ...d, nature: v })} options={['ACTUAL', 'BUDGET'].map(v => ({ value: v, label: v }))} />
        {d.nature === 'ACTUAL' && <Select label="Assurance" value={d.assurance} onChange={v => setD({ ...d, assurance: v })}
          options={['AUDITED', 'REVIEWED', 'MANAGEMENT'].map(v => ({ value: v, label: v }))} />}
        <Field label="Currency" value={d.currency} onChange={v => setD({ ...d, currency: v })} />
        <Select label="Unit" value={d.unitScale} onChange={v => setD({ ...d, unitScale: v })} options={Object.entries(units).map(([v, l]) => ({ value: v, label: l }))} />
      </Form>}
      <RevenueEstimates companies={companies} />
    </>
  );
}

export function StatementDetail() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const [data, setData] = useState<Detail | null>(null);
  const [etag, setEtag] = useState('');
  const [values, setValues] = useState<Record<string, string>>({});
  const [details, setDetails] = useState(false);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [reason, setReason] = useState('');
  const [paste, setPaste] = useState('');
  const [preview, setPreview] = useState<{ matched: { row: number; label: string; code: string; amount?: number }[]; unmatched: { row: number; label?: string }[] } | null>(null);
  const [auditor, setAuditor] = useState({ auditorName: '', auditOpinion: 'UNQUALIFIED' });
  const load = useCallback(async () => {
    const r = await apiWithETag<Detail>(`/financial-statements/${id}`);
    setData(r.data);
    setEtag(r.etag);
    setValues(Object.fromEntries(r.data.lines.filter(l => !l.isTotal || l.entered != null).map(l => [l.code, l.entered == null ? '' : String(l.entered)])));
    setAuditor({ auditorName: r.data.statement.auditorName ?? '', auditOpinion: r.data.statement.auditOpinion ?? 'UNQUALIFIED' });
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  const numbers = useMemo(() => Object.fromEntries(Object.entries(values).map(([k, v]) => [k, v === '' ? null : Number(v)])), [values]);
  const live = useMemo(() => data ? totals(data.lines, numbers) : {}, [data, numbers]);
  if (!data) return null;
  const s = data.statement;
  const draft = s.status === 'DRAFT';
  const enter = can(me, 'fin.stmt.enter');
  const balance = live.TOTAL_ASSETS != null ? live.TOTAL_ASSETS - ((numbers.TOTAL_LIABS ?? live.TOTAL_LIABS ?? 0) + (numbers.TOTAL_EQUITY ?? live.TOTAL_EQUITY ?? 0)) : null;
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const changed = () => data.lines.filter(l => (values[l.code] ?? '') !== (l.entered == null ? '' : String(l.entered)))
    .map(l => ({ code: l.code, amount: values[l.code] === '' || values[l.code] == null ? null : Number(values[l.code]) }));
  return (
    <>
      <section className="card">
        <h1>{name(lang, s.company)} <small className="muted" dir="ltr">{s.periodEnd}</small></h1>
        <p>{t(s.periodType)} · {t(s.basis)} · {t(s.assurance)} · {t(s.nature)} · <span dir="ltr">{s.currency}</span> · {t(units[s.unitScale] ?? '')} · {t('Version')} {s.versionNo} ({t(s.versionReason)}) · <strong>{t(s.status)}</strong></p>
        {balance != null && Math.abs(balance) > 1 && <p role="alert" className="error">{t('The assets differ from the liabilities and equity by')} <span dir="ltr">{amount(balance)}</span>{s.balanceReason && <> — {s.balanceReason}</>}</p>}
        {data.check.missingRequired.length > 0 && draft && <p className="warn">{t('Required lines are empty:')} <span dir="ltr">{data.check.missingRequired.join(' · ')}</span></p>}
        <Notice {...notice} />
        <div className="row">
          {draft && enter && <button onClick={() => act(() => api('PUT', `/financial-statements/${id}/lines`, { lines: changed() }))}>{t('Save')}</button>}
          {draft && enter && s.nature === 'ACTUAL' && <>
            <Field label="Reason for the imbalance" value={reason} onChange={setReason} required={false} />
            <button onClick={() => act(async () => {
              const lines = changed();
              if (lines.length) await api('PUT', `/financial-statements/${id}/lines`, { lines });
              await api('POST', `/financial-statements/${id}/actions/submit`, { balanceReason: reason || undefined });
            }, 'Submitted for approval.')}>{t('Submit')}</button>
          </>}
          {s.status === 'SUBMITTED' && can(me, 'fin.stmt.approve') && !data.preparedByMe && <>
            <button onClick={() => act(() => api('POST', `/financial-statements/${id}/actions/approve`, {}), 'Approved: the covenant tests are being re-evaluated.')}>{t('Approve')}</button>
            <Field label="Reason for returning" value={reason} onChange={setReason} required={false} />
            <button className="link" onClick={() => act(() => api('POST', `/financial-statements/${id}/actions/reject`, { reason }))}>{t('Return to the preparer')}</button>
          </>}
          {s.status === 'REJECTED' && enter && <button onClick={() => act(() => api('POST', `/financial-statements/${id}/actions/reopen`, {}))}>{t('Reopen as a draft')}</button>}
          {s.status === 'APPROVED' && enter && ['RESTATED', 'CORRECTION'].map(r => (
            <button key={r} className="link" onClick={async () => {
              setNotice({});
              try { nav(`/financial-statements/${(await api<{ id: string }>('POST', `/financial-statements/${id}/actions/new-version`, { reason: r })).id}`); } catch (e) { setNotice({ error: message(e) }); }
            }}>{t(r === 'RESTATED' ? 'New restated version' : 'New corrected version')}</button>))}
        </div>
        <h2>{t('Versions')}</h2>
        <Table rows={data.versions} columns={[
          { header: 'Version', cell: v => <Link to={`/financial-statements/${v.id}`}>{v.versionNo}</Link> },
          { header: 'Reason', cell: v => t(v.versionReason) },
          { header: 'Status', cell: v => t(v.status) },
          { header: 'Approved on', cell: v => <span dir="ltr">{v.approvedOn?.slice(0, 10)}</span> },
        ]} />
      </section>
      {draft && enter && s.assurance === 'AUDITED' && (
        <Form title="Auditor" submit="Save" onSubmit={async () => { await api('PATCH', `/financial-statements/${id}`, auditor, etag); await load(); }}>
          <Field label="Auditor's name" value={auditor.auditorName} onChange={v => setAuditor({ ...auditor, auditorName: v })} />
          <Select label="Audit opinion" value={auditor.auditOpinion} onChange={v => setAuditor({ ...auditor, auditOpinion: v })}
            options={['UNQUALIFIED', 'QUALIFIED', 'ADVERSE', 'DISCLAIMER'].map(v => ({ value: v, label: v }))} />
        </Form>
      )}
      <section className="card">
        <h2>{t('Statement lines')} <small className="muted">{t(units[s.unitScale] ?? '')}</small></h2>
        <label className="row"><input type="checkbox" checked={details} onChange={e => setDetails(e.target.checked)} /> <span>{t('Show the detail lines')}</span></label>
        {sections.map(sec => {
          const rows = data.lines.filter(l => l.section === sec && (details || l.isMain || l.isTotal || values[l.code]));
          if (rows.length === 0) return null;
          return (
            <div key={sec}>
              <h3>{t(sec)}</h3>
              <table>
                <tbody>{rows.map(l => (
                  <tr key={l.code} className={l.isTotal ? 'total' : ''}>
                    <td>{l.kind === 'OF_WHICH' || l.kind === 'DETAIL' ? '  ↳ ' : ''}{name(lang, l)}{l.isRequired && !l.isTotal && ' *'} <small className="muted" dir="ltr">{l.code}</small></td>
                    <td>{l.isTotal
                      ? <strong dir="ltr">{amount(live[l.code] ?? l.computed)}</strong>
                      : draft && enter
                        ? <input type="number" step="any" dir="ltr" value={values[l.code] ?? ''} aria-label={l.code} onChange={e => setValues({ ...values, [l.code]: e.target.value })} />
                        : <span dir="ltr">{amount(l.entered)}</span>}</td>
                  </tr>))}</tbody>
              </table>
            </div>
          );
        })}
      </section>
      {draft && enter && (
        <section className="card">
          <h2>{t('Paste from a spreadsheet')}</h2>
          <p className="muted">{t('One line per row: the name, the code or an alias of the line, a tab, then the amount.')}</p>
          <textarea rows={6} value={paste} onChange={e => setPaste(e.target.value)} dir="auto" />
          <button onClick={() => act(async () => {
            const rows = paste.split(/\r?\n/).filter(r => r.trim()).map(r => {
              const cells = r.split('\t');
              return { label: cells[0], amount: cells.length > 1 ? Number(cells[cells.length - 1]!.replace(/,/g, '')) : undefined };
            });
            setPreview(await api('POST', `/financial-statements/${id}/paste-preview`, { rows }));
          }, 'Check the matches, then import.')}>{t('Preview')}</button>
          {preview && <>
            <Table rows={preview.matched} columns={[
              { header: 'Row', cell: m => m.row }, { header: 'Pasted', cell: m => m.label }, { header: 'Line', cell: m => <span dir="ltr">{m.code}</span> },
              { header: 'Amount', cell: m => <span dir="ltr">{amount(m.amount)}</span> },
            ]} />
            {preview.unmatched.length > 0 && <p className="warn">{t('Not matched:')} {preview.unmatched.map(u => `${u.row}. ${u.label ?? ''}`).join(' · ')}</p>}
            <button onClick={() => act(async () => {
              await api('PUT', `/financial-statements/${id}/lines`, { entryMethod: 'PASTE', lines: preview.matched.map(m => ({ code: m.code, amount: m.amount ?? null })) });
              setPreview(null);
              setPaste('');
            }, 'Imported.')}>{t('Import the matched rows')}</button>
          </>}
        </section>
      )}
      {s.basis === 'CONSOLIDATED' && <ConsolidationUnits id={id} holding={s.company.id} draft={draft && enter} />}
      <StatementRatios id={id} approved={s.status === 'APPROVED'} />
    </>
  );
}

interface Unit { company: string; nameAr: string; nameEn?: string; role: string; method: string; ownershipPct?: number; recordedOwnershipPct?: number; hasStandalone: boolean; standaloneAssurance?: string }

function ConsolidationUnits({ id, holding, draft }: { id: string; holding: string; draft: boolean }) {
  const { t, lang } = useI18n();
  const [rows, setRows] = useState<Unit[]>([]);
  const [companies, setCompanies] = useState<Named[]>([]);
  const [u, setU] = useState({ company: '', role: 'SUBSIDIARY', method: 'FULL', ownershipPct: '' });
  const load = useCallback(async () => setRows((await api<{ items: Unit[] }>('GET', `/financial-statements/${id}/units`)).items), [id]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/companies').then(r => setCompanies(r.items)); }, []);
  return (
    <>
      <section className="card">
        <h2>{t('Consolidated units')}</h2>
        <Table rows={rows} columns={[
          { header: 'Company', cell: r => name(lang, r) },
          { header: 'Role', cell: r => t(r.role) },
          { header: 'Method', cell: r => t(r.method) },
          { header: 'Ownership %', cell: r => <span dir="ltr" className={r.recordedOwnershipPct != null && r.ownershipPct != null && r.recordedOwnershipPct !== r.ownershipPct ? 'warn' : ''}>
            {amount(r.ownershipPct)}{r.recordedOwnershipPct != null && ` (${t('recorded')} ${amount(r.recordedOwnershipPct)})`}</span> },
          { header: 'Own statement', cell: r => r.hasStandalone ? t(r.standaloneAssurance ?? 'Yes') : '—' },
          ...(draft ? [{ header: '', cell: (r: Unit) => <button className="link" onClick={async () => { await api('DELETE', `/financial-statements/${id}/units/${r.company}`); await load(); }}>{t('Remove')}</button> }] : []),
        ]} />
      </section>
      {draft && <Form title="Add a unit" submit="Add" onSubmit={async () => {
        await api('POST', `/financial-statements/${id}/units`, {
          company: u.role === 'PARENT' ? holding : u.company, role: u.role, method: u.role === 'PARENT' ? 'FULL' : u.method,
          ownershipPct: u.role === 'PARENT' || u.ownershipPct === '' ? undefined : Number(u.ownershipPct),
        });
        await load();
      }}>
        <Select label="Role" value={u.role} onChange={v => setU({ ...u, role: v })} options={['PARENT', 'SUBSIDIARY', 'ASSOCIATE', 'JOINT_VENTURE'].map(v => ({ value: v, label: v }))} />
        {u.role !== 'PARENT' && <>
          <Select label="Company" value={u.company} onChange={v => setU({ ...u, company: v })} options={[{ value: '', label: '' }, ...companies.filter(c => c.id !== holding).map(c => ({ value: c.id, label: name(lang, c) }))]} />
          <Select label="Method" value={u.method} onChange={v => setU({ ...u, method: v })} options={['FULL', 'EQUITY', 'PROPORTIONATE', 'NOT_CONSOLIDATED'].map(v => ({ value: v, label: v }))} />
          <Field label="Ownership %" value={u.ownershipPct} onChange={v => setU({ ...u, ownershipPct: v })} type="number" />
        </>}
      </Form>}
    </>
  );
}

interface Estimate { id: string; company: Named; fiscalYear: number; basis: string; amount: number; currency: string; basisNote: string; status: string; preparedByMe: boolean }

/** FR-FIN-019: the manual revenue estimates of a revenue-share covenant, approved by someone other than the preparer. */
function RevenueEstimates({ companies }: { companies: Named[] }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Estimate[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [d, setD] = useState({ company: '', fiscalYear: '', amount: '', currency: 'SAR', basisNote: '' });
  const load = useCallback(async () => setRows((await api<{ items: Estimate[] }>('GET', '/revenue-estimates')).items), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h2>{t('Revenue estimates')}</h2>
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Company', cell: e => name(lang, e.company) },
          { header: 'Fiscal year', cell: e => e.fiscalYear },
          { header: 'Basis', cell: e => t(e.basis) },
          { header: 'Amount', cell: e => <span dir="ltr">{amount(e.amount)} {e.currency}</span> },
          { header: 'Source', cell: e => e.basisNote },
          { header: 'Status', cell: e => t(e.status) },
          { header: '', cell: e => e.status === 'DRAFT' && can(me, 'fin.stmt.approve') && !e.preparedByMe && <button className="link" onClick={async () => {
            setNotice({});
            try { await api('POST', `/revenue-estimates/${e.id}/actions/approve`, {}); await load(); } catch (x) { setNotice({ error: message(x) }); }
          }}>{t('Approve')}</button> },
        ]} />
      </section>
      {can(me, 'fin.stmt.enter') && <Form title="New revenue estimate" submit="Create" onSubmit={async () => {
        await api('POST', '/revenue-estimates', { company: d.company || companies[0]?.id, fiscalYear: Number(d.fiscalYear), amount: Number(d.amount), currency: d.currency, basisNote: d.basisNote });
        setD({ ...d, amount: '', basisNote: '' });
        await load();
      }}>
        <Select label="Company" value={d.company} onChange={v => setD({ ...d, company: v })} options={companies.map(c => ({ value: c.id, label: name(lang, c) }))} />
        <Field label="Fiscal year" value={d.fiscalYear} onChange={v => setD({ ...d, fiscalYear: v })} type="number" />
        <Field label="Amount" value={d.amount} onChange={v => setD({ ...d, amount: v })} type="number" />
        <Field label="Currency" value={d.currency} onChange={v => setD({ ...d, currency: v })} />
        <Field label="Source of the estimate" value={d.basisNote} onChange={v => setD({ ...d, basisNote: v })} />
      </Form>}
    </>
  );
}
