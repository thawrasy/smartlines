import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// The inputs of a credit assessment beside its statement (FR-FIN-026 to 029, 034): its guarantors and the company's
// bureau report on SCR-FIN-06, the product lines of a company's year, and the lender's actual decision on the facility
// card. The guarantors and the bureau report change only while the assessment is a draft.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 4 }) : String(v);
const num = (v: string) => v === '' ? undefined : Number(v);

/** An active document on file, picked by its title. */
function DocumentSelect({ label, value, onChange }: { label: string; value: string; onChange: (v: string) => void }) {
  const [docs, setDocs] = useState<Row[]>([]);
  useEffect(() => { void api<{ items: Row[] }>('GET', '/documents?status=ACTIVE').then(r => setDocs(r.items)).catch(() => setDocs([])); }, []);
  return <Select label={label} value={value} onChange={onChange} options={[{ value: '', label: '' }, ...docs.map(x => ({ value: str(x.id), label: `${str(x.title)} ${str(x.documentNumber)}` }))]} />;
}

function useAct(load: () => Promise<unknown>) {
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return { notice, act };
}

export function AssessmentGuarantors({ id, draft }: { id: string; draft: boolean }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [parties, setParties] = useState<Row[]>([]);
  const [d, setD] = useState({ party: '', netWorth: '', liquidAssets: '', guaranteesGiven: '', guaranteedAmount: '', asOfDate: '', document: '' });
  const load = useCallback(async () => setRows((await api<{ items: Row[] }>('GET', `/fin/assessments/${id}/guarantors`)).items), [id]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (draft) void api<{ items: Row[] }>('GET', '/parties').then(r => setParties(r.items)).catch(() => setParties([])); }, [draft]);
  const { notice, act } = useAct(load);
  const edit = draft && can(me, 'fin.credit.assess');
  return (
    <section className="card">
      <h2>{t('Guarantors')}</h2>
      <Notice {...notice} />
      <Table rows={rows} columns={[
        { header: 'Guarantor', cell: g => str(lang === 'ar' ? g.partyNameAr ?? g.partyNameEn : g.partyNameEn ?? g.partyNameAr) },
        { header: 'Net worth', cell: g => <span dir="ltr">{str(g.netWorth)}</span> },
        { header: 'Liquid assets', cell: g => <span dir="ltr">{str(g.liquidAssets)}</span> },
        { header: 'Guarantees given', cell: g => <span dir="ltr">{str(g.guaranteesGiven)}</span> },
        { header: 'Guaranteed here', cell: g => <span dir="ltr">{str(g.guaranteedAmount)}</span> },
        { header: 'As of', cell: g => <span dir="ltr">{str(g.asOfDate)}</span> },
        { header: '', cell: g => edit && <button className="link" onClick={() => act(() => api('DELETE', `/fin/assessments/${id}/guarantors/${str(g.id)}`))}>{t('Remove')}</button> },
      ]} />
      {edit && <Form title="Add a guarantor" submit="Save" onSubmit={async () => {
        await api('POST', `/fin/assessments/${id}/guarantors`, {
          party: d.party, netWorth: num(d.netWorth), liquidAssets: num(d.liquidAssets), guaranteesGiven: num(d.guaranteesGiven), guaranteedAmount: num(d.guaranteedAmount),
          asOfDate: d.asOfDate, document: d.document,
        });
        await load();
      }}>
        <Select label="Guarantor" value={d.party} onChange={v => setD({ ...d, party: v })} options={[{ value: '', label: '' }, ...parties.map(p => ({ value: str(p.id), label: str(p.nameAr ?? p.nameEn) }))]} />
        <Field label="Net worth" value={d.netWorth} onChange={v => setD({ ...d, netWorth: v })} type="number" />
        <Field label="Liquid assets" value={d.liquidAssets} onChange={v => setD({ ...d, liquidAssets: v })} type="number" />
        <Field label="Guarantees given" value={d.guaranteesGiven} onChange={v => setD({ ...d, guaranteesGiven: v })} type="number" required={false} />
        <Field label="Guaranteed here" value={d.guaranteedAmount} onChange={v => setD({ ...d, guaranteedAmount: v })} type="number" />
        <Field label="As of" value={d.asOfDate} onChange={v => setD({ ...d, asOfDate: v })} type="date" />
        <DocumentSelect label="Document" value={d.document} onChange={v => setD({ ...d, document: v })} />
      </Form>}
    </section>
  );
}

const bureauFields = [
  ['totalLimits', 'Total limits'], ['totalOutstanding', 'Total outstanding'], ['lenderCount', 'Lenders'], ['worstDpd12m', 'Worst days past due, 12 months'],
  ['worstDpd24m', 'Worst days past due, 24 months'], ['defaults24mCount', 'Defaults, 24 months'], ['defaults24mAmount', 'Defaulted amount, 24 months'],
  ['bouncedCheques12mCount', 'Bounced cheques, 12 months'], ['bouncedCheques12mAmount', 'Bounced amount, 12 months'], ['judgmentsCount', 'Judgments'],
  ['judgmentsAmount', 'Judgment amount'], ['inquiries6m', 'Inquiries, 6 months'],
] as const;

export function AssessmentBureau({ id, draft }: { id: string; draft: boolean }) {
  const { t } = useI18n();
  const me = useMe();
  const [report, setReport] = useState<Row | null>(null);
  const [d, setD] = useState<Record<string, string>>({ reportDate: '', document: '' });
  const load = useCallback(async () => setReport((await api<{ report: Row | null }>('GET', `/fin/assessments/${id}/bureau`)).report), [id]);
  useEffect(() => { void load(); }, [load]);
  const { notice, act } = useAct(load);
  const edit = draft && can(me, 'fin.credit.assess');
  return (
    <section className="card">
      <h2>{t('Credit bureau report')}</h2>
      <Notice {...notice} />
      {report ? <dl className="grid">
        <dt>{t('Report date')}</dt><dd dir="ltr">{str(report.reportDate).slice(0, 10)}</dd>
        {bureauFields.map(([k, label]) => <span key={k}><dt>{t(label)}</dt><dd dir="ltr">{str(report[k])}</dd></span>)}
        <dt>{t('Current default')}</dt><dd>{report.currentDefault ? t('Yes') : t('No')}</dd>
        <dt>{t('Restructured')}</dt><dd>{report.restructured ? t('Yes') : t('No')}</dd>
      </dl> : <p className="muted">{t('No bureau report: the lender will ask for it.')}</p>}
      {edit && report && <button className="link" onClick={() => act(() => api('DELETE', `/fin/assessments/${id}/bureau`))}>{t('Remove')}</button>}
      {edit && <Form title="Record the bureau report" submit="Save" onSubmit={async () => {
        const body: Record<string, unknown> = { reportDate: d.reportDate, document: d.document, currentDefault: d.currentDefault === 'true', restructured: d.restructured === 'true' };
        for (const [k] of bureauFields) body[k] = num(d[k] ?? '');
        await api('PUT', `/fin/assessments/${id}/bureau`, body);
        await load();
      }}>
        <Field label="Report date" value={d.reportDate ?? ''} onChange={v => setD({ ...d, reportDate: v })} type="date" />
        <DocumentSelect label="Document" value={d.document ?? ''} onChange={v => setD({ ...d, document: v })} />
        {bureauFields.map(([k, label]) => <Field key={k} label={label} value={d[k] ?? ''} onChange={v => setD({ ...d, [k]: v })} type="number" required={k === 'totalLimits' || k === 'totalOutstanding' || k === 'lenderCount'} />)}
        <Select label="Current default" value={d.currentDefault ?? 'false'} onChange={v => setD({ ...d, currentDefault: v })} options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]} />
        <Select label="Restructured" value={d.restructured ?? 'false'} onChange={v => setD({ ...d, restructured: v })} options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]} />
      </Form>}
    </section>
  );
}

export function ProductLines() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [companies, setCompanies] = useState<Row[]>([]);
  const [categories, setCategories] = useState<Row[]>([]);
  const [company, setCompany] = useState('');
  const [year, setYear] = useState(String(new Date().getFullYear() - 1));
  const [d, setD] = useState({ nameAr: '', category: '', revenueSharePct: '', inventorySharePct: '', cashSalesPct: '', governmentSalesPct: '', exportSalesPct: '', typicalCreditDays: '' });
  const load = useCallback(async () => {
    if (!company) { setRows([]); return; }
    setRows((await api<{ items: Row[] }>('GET', `/fin/product-lines?company=${company}&year=${year}`)).items);
  }, [company, year]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/companies').then(r => setCompanies(r.items));
    void api<{ items: Row[] }>('GET', '/fin/product-categories').then(r => setCategories(r.items));
  }, []);
  const { notice, act } = useAct(load);
  const total = rows.reduce((s, r) => s + Number(r.revenueSharePct ?? 0), 0);
  return (
    <>
      <section className="card">
        <h1>{t('Product lines')}</h1>
        <div className="row">
          <Select label="Company" value={company} onChange={setCompany} options={[{ value: '', label: '' }, ...companies.map(c => ({ value: str(c.id), label: str(c.nameAr) }))]} />
          <Field label="Fiscal year" value={year} onChange={setYear} type="number" />
        </div>
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Line', cell: r => str(r.nameAr) },
          { header: 'Category', cell: r => str(lang === 'ar' ? r.categoryNameAr : r.categoryNameEn) },
          { header: 'Share of revenue', cell: r => <span dir="ltr">{str(r.revenueSharePct)}%</span> },
          { header: 'Share of inventory', cell: r => <span dir="ltr">{str(r.inventorySharePct)}%</span> },
          { header: 'Cash / government / export', cell: r => <span dir="ltr">{str(r.cashSalesPct)}% / {str(r.governmentSalesPct)}% / {str(r.exportSalesPct)}%</span> },
          { header: 'Credit days', cell: r => <span dir="ltr">{str(r.typicalCreditDays)}</span> },
          { header: '', cell: r => can(me, 'fin.credit.assess') && <button className="link" onClick={() => act(() => api('DELETE', `/fin/product-lines/${str(r.id)}`))}>{t('Remove')}</button> },
        ]} />
        {company && <p className="muted">{t('Share of revenue')} <span dir="ltr">{str(total)}%</span></p>}
      </section>
      {company && can(me, 'fin.credit.assess') && <Form title="Add a product line" submit="Save" onSubmit={async () => {
        await api('POST', '/fin/product-lines', {
          company, fiscalYear: Number(year), nameAr: d.nameAr, category: d.category, revenueSharePct: num(d.revenueSharePct), inventorySharePct: num(d.inventorySharePct),
          cashSalesPct: num(d.cashSalesPct), governmentSalesPct: num(d.governmentSalesPct), exportSalesPct: num(d.exportSalesPct), typicalCreditDays: num(d.typicalCreditDays),
        });
        await load();
      }}>
        <Field label="Line" value={d.nameAr} onChange={v => setD({ ...d, nameAr: v })} />
        <Select label="Category" value={d.category} onChange={v => setD({ ...d, category: v })}
          options={[{ value: '', label: '' }, ...categories.map(c => ({ value: str(c.code), label: str(lang === 'ar' ? c.nameAr : c.nameEn) }))]} />
        <Field label="Share of revenue" value={d.revenueSharePct} onChange={v => setD({ ...d, revenueSharePct: v })} type="number" />
        <Field label="Share of inventory" value={d.inventorySharePct} onChange={v => setD({ ...d, inventorySharePct: v })} type="number" required={false} />
        <Field label="Cash sales" value={d.cashSalesPct} onChange={v => setD({ ...d, cashSalesPct: v })} type="number" required={false} />
        <Field label="Government sales" value={d.governmentSalesPct} onChange={v => setD({ ...d, governmentSalesPct: v })} type="number" required={false} />
        <Field label="Export sales" value={d.exportSalesPct} onChange={v => setD({ ...d, exportSalesPct: v })} type="number" required={false} />
        <Field label="Credit days" value={d.typicalCreditDays} onChange={v => setD({ ...d, typicalCreditDays: v })} type="number" required={false} />
      </Form>}
    </>
  );
}

const actions = ['MAINTAINED', 'UNDRAWN_STOPPED', 'LIMIT_REDUCED', 'NOT_RENEWED'];

export function FacilityLenderDecisions({ id }: { id: string }) {
  const { t } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [d, setD] = useState({ decisionDate: '', effectiveDate: '', limitAction: 'MAINTAINED', newLimitAmount: '', marginChangeBp: '', feesChangeBp: '', note: '', noSourceReason: '', sourceDocument: '', sourcePage: '' });
  const load = useCallback(async () => {
    try { setRows((await api<{ items: Row[] }>('GET', `/facilities/${id}/lender-decisions`)).items); } catch { setRows([]); }
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  const { notice, act } = useAct(load);
  return (
    <section className="card">
      <h2>{t("The lender's decisions")}</h2>
      <Notice {...notice} />
      <Table rows={rows} columns={[
        { header: 'Decision date', cell: r => <span dir="ltr">{str(r.decisionDate)}</span> },
        { header: 'Effective from', cell: r => <span dir="ltr">{str(r.effectiveDate)}</span> },
        { header: 'Decision', cell: r => <>{t(str(r.limitAction))}{r.inForce ? <strong> · {t('In force')}</strong> : ''}</> },
        { header: 'New limit', cell: r => <span dir="ltr">{str(r.newLimitAmount)}</span> },
        { header: 'Margin and fees', cell: r => <span dir="ltr">{str(r.marginChangeBp)} / {str(r.feesChangeBp)} bp</span> },
        { header: 'Source', cell: r => t(str(r.confidence)) },
        { header: '', cell: r => can(me, 'fac.edit') && !r.enteredByMe && !!r.sourceDocument && r.confidence !== 'CONFIRMED_AGAINST_ORIGINAL' &&
          <button className="link" onClick={() => act(() => api('POST', `/facilities/${id}/lender-decisions/${str(r.id)}/actions/verify`, {}))}>{t('Confirm against the letter')}</button> },
      ]} />
      {can(me, 'fac.edit') && <Form title="Record the lender's decision" submit="Save" onSubmit={async () => {
        await api('POST', `/facilities/${id}/lender-decisions`, {
          decisionDate: d.decisionDate, effectiveDate: d.effectiveDate || undefined, limitAction: d.limitAction,
          newLimitAmount: d.limitAction === 'LIMIT_REDUCED' ? num(d.newLimitAmount) : undefined, marginChangeBp: num(d.marginChangeBp), feesChangeBp: num(d.feesChangeBp),
          note: d.note || undefined, sourceDocument: d.sourceDocument || undefined, sourcePage: d.sourceDocument ? d.sourcePage : undefined,
          noSourceReason: d.sourceDocument ? undefined : d.noSourceReason,
        });
        await load();
      }}>
        <Field label="Decision date" value={d.decisionDate} onChange={v => setD({ ...d, decisionDate: v })} type="date" />
        <Field label="Effective from" value={d.effectiveDate} onChange={v => setD({ ...d, effectiveDate: v })} type="date" required={false} />
        <Select label="Decision" value={d.limitAction} onChange={v => setD({ ...d, limitAction: v })} options={actions.map(a => ({ value: a, label: t(a) }))} />
        {d.limitAction === 'LIMIT_REDUCED' && <Field label="New limit" value={d.newLimitAmount} onChange={v => setD({ ...d, newLimitAmount: v })} type="number" />}
        <Field label="Margin change (bp)" value={d.marginChangeBp} onChange={v => setD({ ...d, marginChangeBp: v })} type="number" required={false} />
        <Field label="Fees change (bp)" value={d.feesChangeBp} onChange={v => setD({ ...d, feesChangeBp: v })} type="number" required={false} />
        <Field label="Note" value={d.note} onChange={v => setD({ ...d, note: v })} required={false} />
        <DocumentSelect label="The lender's letter" value={d.sourceDocument} onChange={v => setD({ ...d, sourceDocument: v })} />
        {d.sourceDocument ? <Field label="Page" value={d.sourcePage} onChange={v => setD({ ...d, sourcePage: v })} />
          : <Field label="Why there is no letter" value={d.noSourceReason} onChange={v => setD({ ...d, noSourceReason: v })} />}
      </Form>}
    </section>
  );
}
