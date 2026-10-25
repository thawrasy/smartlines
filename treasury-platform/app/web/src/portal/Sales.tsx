import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, apiWithETag, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table, useWithStepUp } from '../ui';
import { Chip } from '../brand';
import { AttachForm, DownloadButton, useDocTypes } from './Attach';
import { LC_RECORDERS, LC_TYPES, LcFiles } from './Lcs';
import { can, useMe } from './Portal';

// SCR-LCE-01 to 09 (spec 15 section 7): the proforma of a request (customer, branch, project, lines and the totals the
// server computes, BR-LCE-001), the treasury's issue choices, the register and card of proformas with their void; the
// received letters of credit with their search by number, ERP reference or customer code, the record form, and the card
// with its balances (amount = earmarked + drawn + available), sales orders, collection documents, drawings and their
// discrepancies, amendments, the comparison with the proforma and the close. The server decides every permission; the
// screens only hide what this user may not do.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 10);
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);
const today = () => new Date().toISOString().slice(0, 10);
const num = (v: string) => v.trim() === '' ? undefined : Number(v);
const money = (v: unknown, cur?: unknown) => <span dir="ltr">{str(v)}{cur ? ` ${str(cur)}` : ''}</span>;

type Line = { description: string; qty: string; unitCode: string; unitPrice: string; notes: string };
type Proforma = {
  customer: string; branchCode: string; branchName: string; projectCode: string; projectName: string; projectSite: string;
  offerValidityDays: string; lcPaymentPct: string; placeOfReceipt: string; placeOfDelivery: string; lines: Line[];
};
const emptyLine = (): Line => ({ description: '', qty: '1', unitCode: 'PCS', unitPrice: '', notes: '' });
const HEAD: { key: Exclude<keyof Proforma, 'customer' | 'lines'>; label: string; type?: string }[] = [
  { key: 'branchCode', label: 'Branch code' }, { key: 'branchName', label: 'Branch' }, { key: 'projectCode', label: 'Project code' },
  { key: 'projectName', label: 'Project' }, { key: 'projectSite', label: 'Project site' }, { key: 'offerValidityDays', label: 'Offer valid for (days)', type: 'number' },
  { key: 'lcPaymentPct', label: 'Part paid by the credit %', type: 'number' }, { key: 'placeOfReceipt', label: 'Place of receipt' },
  { key: 'placeOfDelivery', label: 'Place of delivery' },
];

function fromForm(p: unknown): Proforma {
  const o = (p ?? {}) as Row;
  const lines = Array.isArray(o.lines) ? (o.lines as Row[]).map(l => ({
    description: str(l.description), qty: l.qty == null ? '' : String(l.qty), unitCode: str(l.unitCode),
    unitPrice: l.unitPrice == null ? '' : String(l.unitPrice), notes: str(l.notes),
  })) : [];
  return {
    customer: str(o.customer), branchCode: str(o.branchCode), branchName: str(o.branchName), projectCode: str(o.projectCode), projectName: str(o.projectName),
    projectSite: str(o.projectSite), offerValidityDays: o.offerValidityDays == null ? '' : String(o.offerValidityDays),
    lcPaymentPct: o.lcPaymentPct == null ? '100' : String(o.lcPaymentPct), placeOfReceipt: str(o.placeOfReceipt), placeOfDelivery: str(o.placeOfDelivery),
    lines: lines.length ? lines : [emptyLine()],
  };
}

function toForm(p: Proforma) {
  const s = (v: string) => v.trim() === '' ? undefined : v.trim();
  return {
    customer: s(p.customer), branchCode: s(p.branchCode), branchName: s(p.branchName), projectCode: s(p.projectCode), projectName: s(p.projectName),
    projectSite: s(p.projectSite), offerValidityDays: num(p.offerValidityDays), lcPaymentPct: num(p.lcPaymentPct) ?? 100,
    placeOfReceipt: s(p.placeOfReceipt), placeOfDelivery: s(p.placeOfDelivery),
    lines: p.lines.map(l => ({ description: l.description, qty: Number(l.qty || 0), unitCode: l.unitCode, unitPrice: Number(l.unitPrice || 0), notes: s(l.notes) })),
  };
}

type Totals = { lines?: { lineNo: number; lineTotal: number }[]; subtotal?: number; vatRatePct?: number | null; vatAmount?: number; total?: number; lcAmount?: number; currency?: string; problem?: string; message?: string };

/** SCR-LCE-01/02: the proforma of a request; saved into the form's "proforma" key, the totals from the server. */
export function ProformaEditor() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [rq, setRq] = useState<{ form: Row; fields: { key: string; editable: boolean }[]; head: Row } | null>(null);
  const [staff, setStaff] = useState<Row | null>(null);
  const [etag, setEtag] = useState('');
  const [p, setP] = useState<Proforma>(fromForm(null));
  const [totals, setTotals] = useState<Totals | null>(null);
  const [customers, setCustomers] = useState<Row[]>([]);
  const [q, setQ] = useState('');
  const [accounts, setAccounts] = useState<Row[]>([]);
  const [account, setAccount] = useState('');
  const [printLang, setPrintLang] = useState('both');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const r = await apiWithETag<{ request: { form: Row; fields: { key: string; editable: boolean }[]; head: Row }; staff?: Row }>(`/requests/${id}`);
    setRq(r.data.request);
    setStaff(r.data.staff ?? null);
    setEtag(r.etag);
    setP(fromForm(r.data.request.form.proforma));
    const issue = (r.data.request.form.proformaIssue ?? {}) as Row;
    if (issue.proceedsAccount) setAccount(str(issue.proceedsAccount));
    if (issue.printLanguage) setPrintLang(str(issue.printLanguage));
    setTotals(await api<Totals>('GET', `/requests/${id}/proforma-totals`).catch(() => null));
  }, [id]);
  useEffect(() => { void load().catch(e => setNotice({ error: message(e) })); }, [load]);
  useEffect(() => {
    api<{ items: Row[] }>('GET', `/counterparties?kind=CUSTOMER${q ? `&q=${encodeURIComponent(q)}` : ''}`).then(r => setCustomers(r.items)).catch(() => setCustomers([]));
  }, [q]);
  const issuing = staff?.stage === 'ISSUE_PROFORMA' && can(me, 'lc.proforma.issue');
  useEffect(() => {
    if (!issuing) return;
    api<{ items: Row[] }>('GET', `/sales/proceeds-accounts${totals?.currency ? `?currency=${totals.currency}` : ''}`).then(r => setAccounts(r.items)).catch(() => setAccounts([]));
  }, [issuing, totals?.currency]);
  if (!rq) return <section className="card"><Notice {...notice} /></section>;
  const editable = rq.fields.some(f => f.key === 'proforma' && f.editable);
  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: t(ok) }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const setLine = (i: number, k: keyof Line, v: string) => setP({ ...p, lines: p.lines.map((l, j) => j === i ? { ...l, [k]: v } : l) });
  const lineTotal = (i: number) => totals?.lines?.find(l => l.lineNo === i + 1)?.lineTotal;
  return (
    <>
      <section className="card">
        <h1>{t('The proforma')} <small dir="ltr">{str(rq.head.requestNo ?? rq.head.draftRef)}</small></h1>
        <p><Link to={`/requests/${id}`}>{t('Back to the request')}</Link> · <Link to={`/requests/${id}/terms`}>{t('Letter of credit terms')}</Link></p>
        <Notice {...notice} />
        {editable ? (
          <>
            <div className="row">
              <Field label="Find a customer" value={q} onChange={setQ} required={false} />
              <Select label="Customer" value={p.customer} onChange={v => setP({ ...p, customer: v })}
                options={[{ value: '', label: t('Choose') }, ...customers.map(c => ({ value: str(c.id), label: `${pick(lang, c, 'name')}${c.erpCode ? ` (${str(c.erpCode)})` : ''}` }))]} />
            </div>
            <div className="row">
              {HEAD.map(h => <Field key={h.key} label={h.label} type={h.type ?? 'text'} value={p[h.key]} onChange={v => setP({ ...p, [h.key]: v })} required={false} />)}
            </div>
          </>
        ) : (
          <dl className="facts">
            {HEAD.filter(h => p[h.key]).map(h => <><dt key={`${h.key}-t`}>{t(h.label)}</dt><dd key={h.key}>{p[h.key]}</dd></>)}
          </dl>
        )}
      </section>
      <section className="card">
        <h2>{t('Lines')}</h2>
        <table>
          <thead><tr>
            <th>#</th><th>{t('Description')}</th><th>{t('Quantity')}</th><th>{t('Unit')}</th><th>{t('Unit price')}</th><th>{t('Line total')}</th><th>{t('Notes')}</th>{editable && <th />}
          </tr></thead>
          <tbody>
            {p.lines.map((l, i) => (
              <tr key={i}>
                <td>{i + 1}</td>
                {editable ? (
                  <>
                    <td><input aria-label={t('Description')} value={l.description} onChange={e => setLine(i, 'description', e.target.value)} /></td>
                    <td><input dir="ltr" inputMode="decimal" aria-label={t('Quantity')} value={l.qty} onChange={e => setLine(i, 'qty', e.target.value)} /></td>
                    <td><input dir="ltr" aria-label={t('Unit')} value={l.unitCode} onChange={e => setLine(i, 'unitCode', e.target.value)} /></td>
                    <td><input dir="ltr" inputMode="decimal" aria-label={t('Unit price')} value={l.unitPrice} onChange={e => setLine(i, 'unitPrice', e.target.value)} /></td>
                  </>
                ) : <><td>{l.description}</td><td dir="ltr">{l.qty}</td><td dir="ltr">{l.unitCode}</td><td dir="ltr">{l.unitPrice}</td></>}
                <td>{money(lineTotal(i))}</td>
                <td>{editable ? <input aria-label={t('Notes')} value={l.notes} onChange={e => setLine(i, 'notes', e.target.value)} /> : l.notes}</td>
                {editable && <td><button type="button" className="secondary" disabled={p.lines.length === 1}
                  onClick={() => setP({ ...p, lines: p.lines.filter((_, j) => j !== i) })}>{t('Remove')}</button></td>}
              </tr>
            ))}
          </tbody>
        </table>
        {editable && (
          <div className="row">
            <button type="button" className="secondary" onClick={() => setP({ ...p, lines: [...p.lines, emptyLine()] })}>{t('Add a line')}</button>
            <button type="button" onClick={() => run(() => api('PATCH', `/requests/${id}`, { data: { proforma: toForm(p) } }, etag), 'Saved.')}>{t('Save and compute the totals')}</button>
          </div>
        )}
        {totals?.problem && <Notice error={`${totals.problem}: ${t(totals.message ?? (totals.problem === 'V-LCE-02' ? 'No VAT rate is in force for the company.' : 'Check the lines.'))}`} />}
        {totals && !totals.problem && (
          <dl className="facts">
            <dt>{t('Subtotal')}</dt><dd>{money(totals.subtotal, totals.currency)}</dd>
            <dt>{t('VAT')} <span dir="ltr">{str(totals.vatRatePct)}%</span></dt><dd>{money(totals.vatAmount, totals.currency)}</dd>
            <dt>{t('Total')}</dt><dd><strong>{money(totals.total, totals.currency)}</strong></dd>
            <dt>{t('Amount of the letter of credit')}</dt><dd>{money(totals.lcAmount, totals.currency)}</dd>
          </dl>
        )}
      </section>
      {issuing && (
        <Form title="Issue of the proforma" submit="Save the choices" onSubmit={() => run(() => api('PUT', `/requests/${id}/proforma-issue`, { proceedsAccount: account, printLanguage: printLang }), 'Saved.')}>
          <Select label="Proceeds account" value={account} onChange={setAccount}
            options={[{ value: '', label: t('Choose') }, ...accounts.map(a => ({ value: str(a.id), label: `${str(a.nickname)} · ${str(a.iban)} · ${pick(lang, a, 'bankName')}` }))]} />
          <Select label="Print language" value={printLang} onChange={setPrintLang}
            options={[{ value: 'both', label: t('Arabic and English') }, { value: 'ar', label: t('Arabic') }, { value: 'en', label: t('English') }]} />
          <p className="muted">{t('Complete the stage on the request to issue the proforma with its number.')}</p>
        </Form>
      )}
    </>
  );
}

/** SCR-LCE-03: the register of proformas (FR-LCE-008). */
export function ProformaRegister() {
  const { t, lang } = useI18n();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [hasLc, setHasLc] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const p = new URLSearchParams();
    if (q) p.set('q', q);
    if (status) p.set('status', status);
    if (hasLc) p.set('hasLc', hasLc);
    api<{ items: Row[] }>('GET', `/sales/proformas?${p.toString()}`).then(r => setRows(r.items)).catch(e => setError(message(e)));
  }, [q, status, hasLc]);
  return (
    <section className="card">
      <h1>{t('Proformas')}</h1>
      <Notice error={error} />
      <div className="row">
        <Field label="Search" value={q} onChange={setQ} required={false} />
        <Select label="Status" value={status} onChange={setStatus} options={[
          { value: '', label: t('All') }, { value: 'ISSUED', label: t('ISSUED') }, { value: 'SUPERSEDED', label: t('SUPERSEDED') }, { value: 'VOID', label: t('VOID') },
        ]} />
        <Select label="Letter of credit" value={hasLc} onChange={setHasLc} options={[
          { value: '', label: t('All') }, { value: 'true', label: t('Received') }, { value: 'false', label: t('Not received yet') },
        ]} />
      </div>
      <Table rows={rows} empty="No proforma here." columns={[
        { header: 'Number', cell: r => <Link to={`/sales/proformas/${str(r.id)}`} dir="ltr">{str(r.proformaNo)}</Link> },
        { header: 'Request', cell: r => <Link to={`/requests/${str(r.requestId)}`} dir="ltr">{str(r.requestNo)}</Link> },
        { header: 'Customer', cell: r => <>{pick(lang, r, 'customerName')} <small dir="ltr">{str(r.customerCode)}</small></> },
        { header: 'Project', cell: r => str(r.projectName ?? r.projectCode) },
        { header: 'Company', cell: r => pick(lang, r, 'companyName') },
        { header: 'Total', cell: r => money(r.total, r.currency) },
        { header: 'Issued on', cell: r => <span dir="ltr">{day(r.issueDate)}</span> },
        { header: 'Valid until', cell: r => <span dir="ltr">{day(r.validUntil)}</span> },
        { header: 'Credits', cell: r => str(r.credits) },
        { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
      ]} />
    </section>
  );
}

/** SCR-LCE-04: the card of a proforma, its document, the credits received against it, the copy and the void. */
export function ProformaCard() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const withStepUp = useWithStepUp();
  const [d, setD] = useState<{ proforma: Row; lines: Row[]; credits: Row[] } | null>(null);
  const [reason, setReason] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => setD(await api('GET', `/sales/proformas/${id}`)), [id]);
  useEffect(() => { void load().catch(e => setNotice({ error: message(e) })); }, [load]);
  if (!d) return <section className="card"><Notice {...notice} /></section>;
  const pf = d.proforma;
  const customer = (typeof pf.customer === 'string' ? JSON.parse(pf.customer) : pf.customer ?? {}) as Row;
  return (
    <section className="card">
      <h1 dir="ltr">{str(pf.proformaNo)} <small>{t(str(pf.status))}</small></h1>
      <Notice {...notice} />
      <p>
        <a href={`/api/v1/documents/${str(pf.documentId)}/content?version=1`} target="_blank" rel="noreferrer">{t('Open the issued proforma')}</a>
        {' · '}<DownloadPdf id={str(pf.documentId)} name={`proforma-${str(pf.proformaNo)}.pdf`} />
        {' · '}<Link to={`/requests/${str(pf.requestId)}`} dir="ltr">{str(pf.requestNo)}</Link>
        {can(me, 'req.create') && <> · <button type="button" className="secondary" onClick={async () => {
          try { const r = await api<{ id: string }>('POST', `/requests/${str(pf.requestId)}/copy`); nav(`/requests/${r.id}/proforma`); }
          catch (e) { setNotice({ error: message(e) }); }
        }}>{t('Copy into a new request')}</button></>}
      </p>
      <dl className="facts">
        <dt>{t('Customer')}</dt><dd>{str(lang === 'ar' ? customer.nameAr ?? customer.nameEn : customer.nameEn ?? customer.nameAr)} <small dir="ltr">{str(customer.erpCode)}</small></dd>
        <dt>{t('Company')}</dt><dd>{pick(lang, pf, 'companyName')}</dd>
        <dt>{t('Project')}</dt><dd>{str(pf.projectName)} <small dir="ltr">{str(pf.projectCode)}</small></dd>
        <dt>{t('Issued on')}</dt><dd dir="ltr">{day(pf.issueDate)}</dd>
        <dt>{t('Subtotal')}</dt><dd>{money(pf.subtotal, pf.currency)}</dd>
        <dt>{t('VAT')} <span dir="ltr">{str(pf.vatRatePct)}%</span></dt><dd>{money(pf.vatAmount, pf.currency)}</dd>
        <dt>{t('Total')}</dt><dd><strong>{money(pf.total, pf.currency)}</strong></dd>
        <dt>{t('Amount of the letter of credit')}</dt><dd>{money(pf.lcAmount, pf.currency)}</dd>
        {pf.supersededBy ? <><dt>{t('Superseded by')}</dt><dd dir="ltr">{str(pf.supersededBy)}</dd></> : null}
        {pf.voidReason ? <><dt>{t('Reason')}</dt><dd>{str(pf.voidReason)}</dd></> : null}
      </dl>
      <h2>{t('Lines')}</h2>
      <Table rows={d.lines} columns={[
        { header: '#', cell: r => str(r.lineNo) }, { header: 'Description', cell: r => str(r.description) },
        { header: 'Quantity', cell: r => <span dir="ltr">{str(r.qty)} {str(r.unitCode)}</span> }, { header: 'Unit price', cell: r => money(r.unitPrice) },
        { header: 'Line total', cell: r => money(r.lineTotal) },
      ]} />
      <h2>{t('Letters of credit received')}</h2>
      <Table rows={d.credits} empty="No letter of credit received yet." columns={[
        { header: 'Number', cell: r => can(me, 'lc.export.view') ? <Link to={`/sales/lcs/${str(r.id)}`} dir="ltr">{str(r.lcNumber)}</Link> : <span dir="ltr">{str(r.lcNumber)}</span> },
        { header: 'Amount', cell: r => money(r.amount, pf.currency) }, { header: 'Received', cell: r => <span dir="ltr">{day(r.receivedDate)}</span> },
        { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
      ]} />
      {can(me, 'lc.proforma.void') && pf.status === 'ISSUED' && (
        <Form title="Void the proforma" submit="Void" onSubmit={async () => {
          setNotice({});
          try {
            const r = await withStepUp('Voiding a proforma needs a fresh code.', code => api('POST', `/sales/proformas/${id}/void`, { reason, stepUpCode: code }));
            if (r) { await load(); setNotice({ ok: t('The proforma is void.') }); }
          } catch (e) { setNotice({ error: message(e) }); }
        }}>
          <Field label="Reason" value={reason} onChange={setReason} />
        </Form>
      )}
    </section>
  );
}

/** SCR-LCE-05: the received credits, searched by number, ERP reference or customer code; by default those that still take orders. */
export function SalesLcRegister() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [q, setQ] = useState('');
  const [all, setAll] = useState(false);
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const p = new URLSearchParams();
    if (q) p.set('q', q);
    if (all) p.set('all', 'true');
    api<{ items: Row[] }>('GET', `/sales/lcs?${p.toString()}`).then(r => setRows(r.items)).catch(e => setError(message(e)));
  }, [q, all]);
  return (
    <section className="card">
      <h1>{t('Received letters of credit')} {can(me, 'lc.export.record') && <small><Link to="/sales/lcs/new">{t('Record a received credit')}</Link></small>}</h1>
      <Notice error={error} />
      <div className="row">
        <Field label="Credit number, ERP reference or customer code" value={q} onChange={setQ} required={false} />
        <label><input type="checkbox" checked={all} onChange={e => setAll(e.target.checked)} /> {t('Include expired, closed and fully used credits')}</label>
      </div>
      <Table rows={rows} empty="No letter of credit here." columns={[
        { header: 'Number', cell: r => <Link to={`/sales/lcs/${str(r.id)}`} dir="ltr">{str(r.lcNumber)}</Link> },
        { header: 'Customer', cell: r => <>{pick(lang, r, 'customerName')} <small dir="ltr">{str(r.customerCode)}</small></> },
        { header: 'Company', cell: r => pick(lang, r, 'companyName') },
        { header: 'Proforma', cell: r => <span dir="ltr">{str(r.proformaNo)}</span> },
        { header: 'Amount', cell: r => money(r.amount, r.currency) },
        { header: 'Earmarked', cell: r => money(r.earmarked) },
        { header: 'Drawn', cell: r => money(r.drawn) },
        { header: 'Available', cell: r => <strong>{money(r.available)}</strong> },
        { header: 'Expiry', cell: r => <span dir="ltr">{day(r.expiryDate)}</span> },
        { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
      ]} />
    </section>
  );
}

/** SCR-LCE-06: a received credit, its customer, bank, proforma and the main terms; warnings are acknowledged with a reason. */
export function SalesLcNew() {
  const { t, lang } = useI18n();
  const nav = useNavigate();
  const [companies, setCompanies] = useState<Row[]>([]);
  const [customers, setCustomers] = useState<Row[]>([]);
  const [proformas, setProformas] = useState<Row[]>([]);
  const [banks, setBanks] = useState<Row[]>([]);
  const [f, setF] = useState({
    company: '', lcNumber: '', customer: '', institution: '', otherBankText: '', receivedDate: today(), proforma: '', bankReference: '', erpReference: '',
    amount: '', currencyId: '', expiryDate: '', latestShipmentDate: '', presentationDays: '21', confirmation: 'WITHOUT', availableWith: 'ADVISING_BANK',
  });
  const [warnings, setWarnings] = useState<string[]>([]);
  const [warningReason, setWarningReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/companies').then(r => { setCompanies(r.items); const first = r.items[0]; if (first) setF(x => ({ ...x, company: str(first.id) })); });
    void api<{ items: Row[] }>('GET', '/counterparties?kind=CUSTOMER').then(r => setCustomers(r.items)).catch(() => setCustomers([]));
    void api<{ items: Row[] }>('GET', '/sales/proformas?status=ISSUED').then(r => setProformas(r.items)).catch(() => setProformas([]));
    void api<{ items: Row[] }>('GET', '/institutions').then(r => setBanks(r.items)).catch(() => setBanks([]));
  }, []);
  const set = (k: keyof typeof f) => (v: string) => setF({ ...f, [k]: v });
  return (
    <Form title="Record a received credit" submit="Record" onSubmit={async () => {
      setError(null);
      const terms: Row = {
        amount: num(f.amount), expiryRule: 'ABSOLUTE', expiryDate: f.expiryDate || null, latestShipmentRule: f.latestShipmentDate ? 'ABSOLUTE' : null,
        latestShipmentDate: f.latestShipmentDate || null, presentationDays: num(f.presentationDays), confirmation: f.confirmation, availableWith: f.availableWith,
      };
      if (f.currencyId) terms.currencyId = f.currencyId.toUpperCase();
      try {
        const r = await api<{ id: string }>('POST', '/sales/lcs', {
          company: f.company, lcNumber: f.lcNumber, customer: f.customer || null, institution: f.institution || null, otherBankText: f.otherBankText || null,
          receivedDate: f.receivedDate, proforma: f.proforma || null, bankReference: f.bankReference || null, erpReference: f.erpReference || null, terms,
          acknowledge: warnings.length ? warnings : undefined, warningReason: warnings.length ? warningReason : undefined,
        });
        nav(`/sales/lcs/${r.id}`);
      } catch (e) {
        const code = (e as { problem?: { code?: string } }).problem?.code;
        if (code && /^V-LCE-1[238]$/.test(code) && !warnings.includes(code)) setWarnings([...warnings, code]);
        setError(message(e));
      }
    }}>
      <Notice error={error} />
      <Select label="Company" value={f.company} onChange={set('company')} options={companies.map(c => ({ value: str(c.id), label: pick(lang, c, 'name') }))} />
      <Field label="Credit number" value={f.lcNumber} onChange={set('lcNumber')} />
      <Select label="Proforma" value={f.proforma} onChange={set('proforma')}
        options={[{ value: '', label: t('None') }, ...proformas.map(p => ({ value: str(p.id), label: `${str(p.proformaNo)} · ${pick(lang, p, 'customerName')} · ${str(p.total)} ${str(p.currency)}` }))]} />
      <Select label="Customer" value={f.customer} onChange={set('customer')}
        options={[{ value: '', label: t('From the proforma') }, ...customers.map(c => ({ value: str(c.id), label: `${pick(lang, c, 'name')}${c.erpCode ? ` (${str(c.erpCode)})` : ''}` }))]} />
      <Select label="Advising bank" value={f.institution} onChange={set('institution')}
        options={[{ value: '', label: t('Other bank') }, ...banks.map(b => ({ value: str(b.id), label: pick(lang, b, 'name') }))]} />
      {!f.institution && <Field label="Bank (as written)" value={f.otherBankText} onChange={set('otherBankText')} required={false} />}
      <Field label="Received on" type="date" value={f.receivedDate} onChange={set('receivedDate')} />
      <Field label="Bank reference" value={f.bankReference} onChange={set('bankReference')} required={false} />
      <Field label="ERP reference" value={f.erpReference} onChange={set('erpReference')} required={false} />
      <Field label="Amount" type="number" value={f.amount} onChange={set('amount')} required={!f.proforma} />
      <Field label="Currency" value={f.currencyId} onChange={set('currencyId')} required={false} hint="Leave empty to take the proforma's." />
      <Field label="Expiry date" type="date" value={f.expiryDate} onChange={set('expiryDate')} />
      <Field label="Latest shipment date" type="date" value={f.latestShipmentDate} onChange={set('latestShipmentDate')} required={false} />
      <Field label="Presentation days" type="number" value={f.presentationDays} onChange={set('presentationDays')} required={false} />
      <Select label="Confirmation" value={f.confirmation} onChange={set('confirmation')} options={['WITHOUT', 'MAY_ADD', 'CONFIRMED'].map(o => ({ value: o, label: t(o) }))} />
      <Select label="Available with" value={f.availableWith} onChange={set('availableWith')}
        options={['ADVISING_BANK', 'ISSUING_BANK', 'ANY_BANK', 'NOMINATED_BANK'].map(o => ({ value: o, label: t(o) }))} />
      {warnings.length > 0 && (
        <>
          <p className="warn">{t('Warnings to acknowledge')}: <span dir="ltr">{warnings.join(', ')}</span></p>
          <Field label="Reason for going ahead" value={warningReason} onChange={setWarningReason} />
        </>
      )}
    </Form>
  );
}

type SalesCard = { lc: Row; terms: Row | null; orders: Row[]; drawings: (Row & { allocations: Row[]; discrepancies: Row[] })[]; amendments: Row[]; documents: Row[] };

/** SCR-LCE-07 to 09: the card of a received credit with its balances and every action on it. */
export function SalesLcCard() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const [d, setD] = useState<SalesCard | null>(null);
  const [cmp, setCmp] = useState<{ comparison: Row | null; lines: Row[] }>({ comparison: null, lines: [] });
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [order, setOrder] = useState({ orderRef: '', orderDate: today(), amount: '', deliveryDate: '' });
  const [coll, setColl] = useState({ amount: '', shipmentDate: '', invoiceRefs: '' });
  const [alloc, setAlloc] = useState<Record<string, string>>({});
  const [amend, setAmend] = useState({ origin: 'RECEIVED_FROM_CUSTOMER', newAmount: '', newExpiryDate: '', bankIssuedOn: today(), decision: 'ACCEPT', reason: '' });
  const [disc, setDisc] = useState<Record<string, string>>({});
  const [pay, setPay] = useState<Record<string, string>>({});
  const [closeReason, setCloseReason] = useState('');
  const docTypes = useDocTypes(LC_TYPES);
  const load = useCallback(async () => {
    setD(await api('GET', `/sales/lcs/${id}`));
    if (can(me, 'lc.compare')) setCmp(await api('GET', `/sales/lcs/${id}/comparison`).catch(() => ({ comparison: null, lines: [] })) as typeof cmp);
  }, [id, me]);
  useEffect(() => { void load().catch(e => setNotice({ error: message(e) })); }, [load]);
  const run = async (fn: () => Promise<unknown>, ok: string) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: t(ok) }); } catch (e) { setNotice({ error: message(e) }); }
  };
  if (!d) return <section className="card"><Notice {...notice} /></section>;
  const lc = d.lc;
  const cur = lc.currency;
  const active = str(lc.status) === 'ACTIVE';
  const open = d.orders.filter(o => ['EARMARKED', 'PARTIALLY_CONVERTED'].includes(str(o.status)));
  const drawer = can(me, 'lc.drawing.record');
  const post = (path: string, body: unknown) => api('POST', `/sales/lcs/${id}${path}`, body);
  return (
    <>
      <section className="card">
        <h1 dir="ltr">{str(lc.lcNumber)} <small>{t(str(lc.status))}</small></h1>
        <Notice {...notice} />
        <dl className="facts">
          <dt>{t('Customer')}</dt><dd>{pick(lang, lc, 'customerName')} <small dir="ltr">{str(lc.customerCode)}</small></dd>
          <dt>{t('Company')}</dt><dd>{pick(lang, lc, 'companyName')}</dd>
          {lc.proformaId ? <><dt>{t('Proforma')}</dt><dd><Link to={`/sales/proformas/${str(lc.proformaId)}`} dir="ltr">{str(lc.proformaNo)}</Link></dd></> : null}
          {'bankNameEn' in lc || 'customerBank' in lc ? <><dt>{t('Bank')}</dt><dd>{pick(lang, lc, 'bankName') || str(lc.customerBank)}</dd></> : null}
          {lc.erpReference ? <><dt>{t('ERP reference')}</dt><dd dir="ltr">{str(lc.erpReference)}</dd></> : null}
          <dt>{t('Received on')}</dt><dd dir="ltr">{day(lc.receivedDate)}</dd>
          <dt>{t('Expiry')}</dt><dd dir="ltr">{day(lc.expiryDate)}</dd>
          <dt>{t('Latest shipment')}</dt><dd dir="ltr">{day(lc.latestShipmentDate)}</dd>
          <dt>{t('Amendments')}</dt><dd>{str(lc.amendmentNo)}</dd>
        </dl>
        <table className="balances">
          <thead><tr><th>{t('Amount')}</th><th>{t('Earmarked')}</th><th>{t('Drawn')}</th><th>{t('Available')}</th><th>{t('Settled')}</th></tr></thead>
          <tbody><tr>
            <td>{money(lc.amount, cur)}</td><td>{money(lc.earmarked)}</td><td>{money(lc.drawn)}</td><td><strong>{money(lc.available)}</strong></td><td>{money(lc.settled)}</td>
          </tr></tbody>
        </table>
      </section>
      <section className="card">
        <h2>{t('Sales orders')}</h2>
        <Table rows={d.orders} empty="No sales order yet." columns={[
          { header: 'Order', cell: r => <span dir="ltr">{str(r.orderRef)}</span> },
          { header: 'Request', cell: r => <Link to={`/requests/${str(r.requestId)}`} dir="ltr">{str(r.requestNo)}</Link> },
          { header: 'Date', cell: r => <span dir="ltr">{day(r.orderDate)}</span> },
          { header: 'Amount', cell: r => money(r.amount) }, { header: 'Converted', cell: r => money(r.converted) },
          { header: 'Released', cell: r => money(r.released) }, { header: 'Remaining', cell: r => money(r.remaining) },
          { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
          { header: '', cell: r => can(me, 'lc.order.release') && ['EARMARKED', 'PARTIALLY_CONVERTED'].includes(str(r.status)) ? (
            <button type="button" className="secondary" onClick={() => {
              const reason = window.prompt(t('Reason'));
              if (reason) void run(() => api('POST', `/sales/orders/${str(r.id)}/close`, { reason }), 'The order is closed.');
            }}>{t('Close the order')}</button>
          ) : null },
        ]} />
        {can(me, 'req.create') && active && (
          <Form title="Raise a sales order" submit="Create the request" onSubmit={() => run(async () => {
            const r = await post('/sales-orders', { orderRef: order.orderRef, orderDate: order.orderDate, amount: Number(order.amount), deliveryDate: order.deliveryDate || null });
            nav(`/requests/${str((r as Row).id)}`);
          }, 'Saved.')}>
            <Field label="Order reference" value={order.orderRef} onChange={v => setOrder({ ...order, orderRef: v })} />
            <Field label="Order date" type="date" value={order.orderDate} onChange={v => setOrder({ ...order, orderDate: v })} />
            <Field label="Amount" type="number" value={order.amount} onChange={v => setOrder({ ...order, amount: v })} hint={`${t('Available')}: ${str(lc.available)} ${str(cur)}`} />
            <Field label="Delivery date" type="date" value={order.deliveryDate} onChange={v => setOrder({ ...order, deliveryDate: v })} required={false} />
          </Form>
        )}
      </section>
      <section className="card">
        <h2>{t('Drawings')}</h2>
        <Table rows={d.drawings} empty="No drawing yet." columns={[
          { header: 'No.', cell: r => str(r.drawingNo) },
          { header: 'Request', cell: r => r.requestId ? <Link to={`/requests/${str(r.requestId)}`} dir="ltr">{str(r.requestNo)}</Link> : '' },
          { header: 'Amount', cell: r => money(r.amount) },
          { header: 'On orders', cell: r => r.allocations.map(a => `${str(a.orderRef)}: ${str(a.amount)}`).join(' · ') },
          { header: 'Presented', cell: r => <span dir="ltr">{day(r.presentationDate)}</span> },
          { header: 'Paid', cell: r => money(r.settled) },
          { header: 'Discrepancies', cell: r => r.discrepancies.map(x => `${str(x.description)} (${t(str(x.status))})`).join(' · ') },
          { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
          { header: '', cell: r => {
            const no = str(r.drawingNo);
            const s = str(r.status);
            const openDisc = r.discrepancies.some(x => x.status === 'OPEN');
            return (
              <span>
                {drawer && ['PRESENTED', 'DISCREPANT'].includes(s) && !openDisc && <>
                  <button type="button" onClick={() => void run(() => post(`/drawings/${no}/decision`, { status: 'ACCEPTED' }), 'Saved.')}>{t('Accepted')}</button>{' '}
                  <button type="button" className="danger" onClick={() => void run(() => post(`/drawings/${no}/decision`, { status: 'REFUSED' }), 'Saved.')}>{t('Refused')}</button>{' '}
                  <input aria-label={t('Discrepancy')} placeholder={t('Discrepancy')} value={disc[no] ?? ''} onChange={e => setDisc({ ...disc, [no]: e.target.value })} />
                  <button type="button" disabled={!disc[no]} onClick={() => void run(() => post(`/drawings/${no}/discrepancies`, { description: disc[no] }), 'Saved.')}>{t('Record the discrepancy')}</button>
                </>}
                {openDisc && can(me, 'lc.discrepancy.decide') && <>
                  <input aria-label={t('Note')} placeholder={t('Note')} value={disc[no] ?? ''} onChange={e => setDisc({ ...disc, [no]: e.target.value })} />
                  <button type="button" disabled={!disc[no]} onClick={() => void run(() => post(`/drawings/${no}/discrepancy-decision`, { status: 'WAIVED', note: disc[no] }), 'Saved.')}>{t('Waived')}</button>{' '}
                  <button type="button" className="danger" disabled={!disc[no]} onClick={() => void run(() => post(`/drawings/${no}/discrepancy-decision`, { status: 'REFUSED', note: disc[no] }), 'Saved.')}>{t('Refused')}</button>
                </>}
                {drawer && s === 'ACCEPTED' && <>
                  <input dir="ltr" inputMode="decimal" aria-label={t('Payment')} value={pay[no] ?? ''} onChange={e => setPay({ ...pay, [no]: e.target.value })} />{' '}
                  <button type="button" onClick={() => void run(() => post(`/drawings/${no}/settlements`, { amount: Number(pay[no]), settledOn: today() }), 'Saved.')}>{t('Record the payment')}</button>
                </>}
              </span>
            );
          } },
        ]} />
        {can(me, 'req.create') && active && (
          <Form title="Collection documents" submit="Create the request" onSubmit={() => run(async () => {
            const allocations = Object.entries(alloc).filter(([, v]) => Number(v) > 0).map(([order, v]) => ({ order, amount: Number(v) }));
            const r = await post('/collections', { amount: Number(coll.amount), shipmentDate: coll.shipmentDate || null, invoiceRefs: coll.invoiceRefs || null, allocations });
            nav(`/requests/${str((r as Row).id)}`);
          }, 'Saved.')}>
            <Field label="Amount" type="number" value={coll.amount} onChange={v => setColl({ ...coll, amount: v })} />
            <Field label="Shipment date" type="date" value={coll.shipmentDate} onChange={v => setColl({ ...coll, shipmentDate: v })} required={false} />
            <Field label="Invoices" value={coll.invoiceRefs} onChange={v => setColl({ ...coll, invoiceRefs: v })} required={false} />
            {open.map(o => (
              <Field key={str(o.id)} label={`${t('On order')} ${str(o.orderRef)} (${t('Remaining')} ${str(o.remaining)})`} type="number"
                value={alloc[str(o.id)] ?? ''} onChange={v => setAlloc({ ...alloc, [str(o.id)]: v })} required={false} />
            ))}
            <p className="muted">{t('What is not put on an order is taken from the available balance.')}</p>
          </Form>
        )}
      </section>
      <section className="card">
        <h2>{t('Amendments')}</h2>
        <Table rows={d.amendments} empty="No amendment." columns={[
          { header: 'No.', cell: r => str(r.amendmentNo) }, { header: 'Origin', cell: r => t(str(r.origin)) },
          { header: 'Changes', cell: r => str(r.changeKinds) }, { header: 'New amount', cell: r => money(r.newAmount) },
          { header: 'New expiry', cell: r => <span dir="ltr">{day(r.newExpiryDate)}</span> }, { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
          { header: 'Reason', cell: r => str(r.reason) },
        ]} />
        {can(me, 'lc.amendment.record') && active && (
          <Form title="Record an amendment" submit="Record" onSubmit={() => run(() => post('/amendments', {
            origin: amend.origin, newAmount: num(amend.newAmount), newExpiryDate: amend.newExpiryDate || null, bankIssuedOn: amend.bankIssuedOn,
            decision: amend.decision, reason: amend.reason || null,
          }), 'The amendment is recorded.')}>
            <Select label="Origin" value={amend.origin} onChange={v => setAmend({ ...amend, origin: v })}
              options={['RECEIVED_FROM_CUSTOMER', 'OUR_REQUEST'].map(o => ({ value: o, label: t(o) }))} />
            <Field label="New amount" type="number" value={amend.newAmount} onChange={v => setAmend({ ...amend, newAmount: v })} required={false} />
            <Field label="New expiry" type="date" value={amend.newExpiryDate} onChange={v => setAmend({ ...amend, newExpiryDate: v })} required={false} />
            <Field label="Date of the amendment" type="date" value={amend.bankIssuedOn} onChange={v => setAmend({ ...amend, bankIssuedOn: v })} />
            <Select label="Decision" value={amend.decision} onChange={v => setAmend({ ...amend, decision: v })}
              options={[{ value: 'ACCEPT', label: t('Accept') }, { value: 'REJECT', label: t('Reject') }]} />
            <Field label="Reason" value={amend.reason} onChange={v => setAmend({ ...amend, reason: v })} required={amend.decision === 'REJECT'} />
          </Form>
        )}
      </section>
      {can(me, 'lc.compare') && lc.proformaId ? (
        <section className="card">
          <h2>{t('Comparison with the proforma')} {cmp.comparison ? <small>{t(str(cmp.comparison.status))} · <span dir="ltr">{day(cmp.comparison.runAt)}</span></small> : null}</h2>
          <button type="button" onClick={() => void run(() => post('/compare', {}), 'The comparison is done.')}>{t('Compare now')}</button>
          <Table rows={cmp.lines} empty="No comparison yet." columns={[
            { header: 'Field', cell: r => t(str(r.field)) },
            { header: 'Proforma', cell: r => <span dir="ltr">{str(r.baseline)}</span> },
            { header: 'Credit', cell: r => <span dir="ltr">{str(r.received)}</span> },
            { header: 'Verdict', cell: r => <span className={r.verdict === 'LESS_FAVOURABLE' || r.verdict === 'MISSING' ? 'warn' : ''}>{t(str(r.verdict))}</span> },
            { header: 'Decision', cell: r => r.verdict === 'MATCH' ? '' : (
              <Select label="Decision" value={str(r.decision)} onChange={v => {
                if (v) void run(() => api('PUT', `/sales/lcs/${id}/comparison/lines/${encodeURIComponent(str(r.field))}`, { decision: v }), 'Saved.');
              }} options={[{ value: '', label: t('Choose') }, ...['ACCEPT', 'REQUEST_AMENDMENT', 'IGNORE'].map(o => ({ value: o, label: t(o) }))]} />
            ) },
          ]} />
        </section>
      ) : null}
      <section className="card">
        <h2>{t('Files of the letter of credit')}</h2>
        <LcFiles rows={d.documents} />
        {LC_RECORDERS.some(p => can(me, p)) && <AttachForm path={`/sales/lcs/${id}/documents/upload`} types={docTypes} title="File a document on the credit" onDone={load} />}
        {can(me, 'lc.close') && ['ACTIVE', 'EXPIRED'].includes(str(lc.status)) && (
          <Form title="Close the letter of credit" submit="Close" onSubmit={() => run(() => post('/close', { reason: closeReason }), 'The letter of credit is closed.')}>
            <Field label="Reason" value={closeReason} onChange={setCloseReason} />
          </Form>
        )}
      </section>
    </>
  );
}

/** The issued proforma's PDF (its current version, docs/31 row 52). */
function DownloadPdf({ id, name }: { id: string; name: string }) {
  const { t } = useI18n();
  return <span>{t('PDF')}: <DownloadButton id={id} name={name} /></span>;
}
