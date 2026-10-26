import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { PdfButton } from './Attach';

// SCR-LCT-01 to 03 (spec 14 section 7; OQ-16): the terms of a purchase letter of credit on its request: the main fields
// of the field dictionary, the beneficiary chosen from the counterparties, the documents required from the clause
// library, the charges preset, and the findings of the V-LCT checks as the requester edits (errors block the submission,
// warnings are shown). A locked version is read only; the server decides which fields this user may edit.

type Row = Record<string, unknown>;
type Terms = {
  status: string | null; version?: number; editable?: boolean; treasuryEditable?: boolean; fields?: Row; documents?: Row[]; charges?: Row[];
  findings?: { code: string; severity: string; field: string | null; message: string }[]; exposureAmount?: number | null; beneficiaryIban?: string | null;
};
const str = (v: unknown) => v == null ? '' : String(v);

// tag: the field of the SWIFT MT700 message the term goes into (shown beside it); a term with none is not a field of its own.
type Def = { key: string; label: string; type?: 'text' | 'number' | 'date'; options?: string[]; tag?: string };
const FIELDS: Def[] = [
  { key: 'lcType', label: 'Type of credit', options: ['SIGHT', 'DEFERRED_PAYMENT', 'ACCEPTANCE', 'NEGOTIATION', 'MIXED'], tag: '41a' },
  { key: 'deferralDays', label: 'Deferral days', type: 'number', tag: '42P' },
  { key: 'maturityBasis', label: 'Tenor runs from', options: ['SHIPMENT_DATE', 'DELIVERY_NOTE_DATE', 'INVOICE_DATE', 'DOCUMENTS_RECEIPT_DATE', 'ACCEPTANCE_DATE'], tag: '42P' },
  { key: 'availableWith', label: 'Available with', options: ['ADVISING_BANK', 'ISSUING_BANK', 'ANY_BANK', 'NOMINATED_BANK'], tag: '41a' },
  { key: 'confirmation', label: 'Confirmation', options: ['WITHOUT', 'MAY_ADD', 'CONFIRMED'], tag: '49' },
  { key: 'advisingBankName', label: 'Advising bank' },
  { key: 'advisingBankAddress', label: 'Advising bank address' },
  { key: 'advisingBankBic', label: 'Advising bank BIC' },
  { key: 'currencyId', label: 'Currency', tag: '32B' },
  { key: 'amount', label: 'Amount', type: 'number', tag: '32B' },
  { key: 'toleranceMode', label: 'Tolerance', options: ['NONE', 'ABOUT', 'PLUS_MINUS'], tag: '39A' },
  { key: 'tolerancePlusPct', label: 'Plus tolerance %', type: 'number', tag: '39A' },
  { key: 'toleranceMinusPct', label: 'Minus tolerance %', type: 'number', tag: '39A' },
  { key: 'expiryRule', label: 'Expiry', options: ['ABSOLUTE', 'DAYS_AFTER_ISSUE'], tag: '31D' },
  { key: 'expiryDate', label: 'Expiry date', type: 'date', tag: '31D' },
  { key: 'expiryDaysAfterIssue', label: 'Days from issue to expiry', type: 'number', tag: '31D' },
  { key: 'expiryPlace', label: 'Place of expiry', tag: '31D' },
  { key: 'latestShipmentRule', label: 'Latest shipment', options: ['ABSOLUTE', 'DAYS_AFTER_ISSUE'], tag: '44C' },
  { key: 'latestShipmentDate', label: 'Latest shipment date', type: 'date', tag: '44C' },
  { key: 'presentationDays', label: 'Presentation days', type: 'number', tag: '48' },
  { key: 'presentationBasis', label: 'Presentation from', options: ['SHIPMENT_DATE', 'DELIVERY_NOTE_DATE', 'INVOICE_DATE'], tag: '48' },
  { key: 'partialShipments', label: 'Partial shipments', options: ['ALLOWED', 'NOT_ALLOWED'], tag: '43P' },
  { key: 'transhipment', label: 'Transhipment', options: ['ALLOWED', 'NOT_ALLOWED', 'NOT_APPLICABLE'], tag: '43T' },
  { key: 'transportMode', label: 'Transport', options: ['SEA', 'AIR', 'ROAD', 'RAIL', 'COURIER', 'MULTIMODAL', 'DOMESTIC_DELIVERY'] },
  { key: 'portOfLoading', label: 'Port of loading', tag: '44E' },
  { key: 'portOfDischarge', label: 'Port of discharge', tag: '44F' },
  { key: 'incotermId', label: 'Incoterm', tag: '45A' },
  { key: 'incotermPlace', label: 'Incoterm place', tag: '45A' },
  { key: 'goodsDescription', label: 'Goods', tag: '45A' },
  { key: 'insuranceResponsibility', label: 'Insurance by', options: ['APPLICANT', 'BENEFICIARY', 'NOT_REQUIRED_BY_TERMS'] },
  { key: 'lcTextLanguage', label: 'Language of the credit', options: ['EN', 'AR', 'BOTH'] },
];

/** The SWIFT MT700 field of a term (the owner's choice: the code alone, as on the bank's copy of the message). 42C for an
 * acceptance credit's drafts, 42P otherwise. */
function Tag({ tag, lcType }: { tag?: string; lcType?: string }) {
  if (!tag) return null;
  return <small className="swift-tag" dir="ltr">{tag === '42P' && lcType === 'ACCEPTANCE' ? '42C' : tag}</small>;
}

/** A sight credit is paid at sight: no deferral, so its days and the date they run from are not asked (V-LCT-06). */
const DEFERRAL = new Set(['deferralDays', 'maturityBasis']);
const hasDeferral = (lcType: string | undefined) => lcType === 'DEFERRED_PAYMENT' || lcType === 'ACCEPTANCE' || lcType === 'MIXED';

export function TermsEditor() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const [terms, setTerms] = useState<Terms | null>(null);
  const [edit, setEdit] = useState<Record<string, string>>({});
  const [clauses, setClauses] = useState<Row[]>([]);
  const [docs, setDocs] = useState<{ clause: string; originals: string; copies: string }[]>([]);
  const [suppliers, setSuppliers] = useState<Row[]>([]);
  const [q, setQ] = useState('');
  const [preset, setPreset] = useState('OWN_BANK');
  const [iban, setIban] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const load = useCallback(async () => {
    const r = await api<Terms>('GET', `/requests/${id}/terms`);
    setTerms(r);
    const f = r.fields ?? {};
    setEdit(Object.fromEntries(FIELDS.map(d => [d.key, str(f[d.key]).slice(0, d.type === 'date' ? 10 : undefined)])));
    setDocs((r.documents ?? []).map(d => ({ clause: str(d.clause), originals: str(d.originals), copies: str(d.copies) })));
  }, [id]);
  useEffect(() => { void load().catch(e => setError(message(e))); }, [load]);
  useEffect(() => { api<{ items: Row[] }>('GET', '/document-clauses').then(r => setClauses(r.items)).catch(() => setClauses([])); }, []);
  useEffect(() => {
    api<{ items: Row[] }>('GET', `/counterparties?kind=SUPPLIER${q ? `&q=${encodeURIComponent(q)}` : ''}`).then(r => setSuppliers(r.items)).catch(() => setSuppliers([]));
  }, [q]);
  const run = async (fn: () => Promise<unknown>, done: string) => {
    setError(null); setOk(null);
    try { await fn(); setOk(t(done)); await load(); } catch (e) { setError(message(e)); }
  };
  if (!terms) return <section className="card"><Notice error={error} /></section>;
  if (terms.status == null) return <section className="card"><h1>{t('Letter of credit terms')}</h1><p>{t('This request has no terms.')}</p></section>;
  const editable = !!terms.editable && terms.status === 'DRAFT';
  // Terms asked of a customer (scope SALES): the applicant is the proforma's customer and our company the beneficiary.
  const sales = str(terms.fields?.scope) === 'SALES';
  const save = () => run(async () => {
    const before = terms.fields ?? {};
    const changed: Record<string, unknown> = {};
    for (const d of FIELDS) {
      const v = DEFERRAL.has(d.key) && !hasDeferral(edit.lcType) ? '' : edit[d.key] ?? '';
      if (v === str(before[d.key]).slice(0, d.type === 'date' ? 10 : undefined)) continue;
      changed[d.key] = v === '' ? null : d.type === 'number' ? Number(v) : v;
    }
    await api('PUT', `/requests/${id}/terms`, { fields: changed });
  }, 'The terms are saved.');
  return (
    <section className="card">
      <h1>{t('Letter of credit terms')} <small>{t('Version')} {terms.version} · {t(terms.status)}</small></h1>
      <p>
        <Link to={`/requests/${id}`}>{t('Back to the request')}</Link>
        {' · '}<a href={`/api/v1/requests/${id}/terms/print?lang=${lang}`} target="_blank" rel="noreferrer">{t('Print the terms')}</a>
        {' · '}<PdfButton path={`/requests/${id}/terms/print?lang=${lang}`} name={`terms-v${terms.version ?? 1}.pdf`} />
      </p>
      {terms.beneficiaryIban && <p>{t("Beneficiary's IBAN")}: <span dir="ltr">{terms.beneficiaryIban}</span></p>}
      <Notice error={error} ok={ok} />
      {terms.exposureAmount != null && <p>{t('Exposure')}: <span dir="ltr">{terms.exposureAmount.toLocaleString('en-US')}</span></p>}
      <p className="muted"><small>{t('Beside each term: its field in the SWIFT MT700 message.')}</small></p>
      <h2>{t('Checks')}</h2>
      <Table rows={(terms.findings ?? []) as unknown as Row[]} empty="No finding." columns={[
        { header: 'Severity', cell: r => r.severity === 'E' ? <strong>{t('Error')}</strong> : t('Warning') },
        { header: 'Field', cell: r => { const d = FIELDS.find(x => x.key === r.field); return d ? <>{t(d.label)} <Tag tag={d.tag} lcType={edit.lcType} /></> : str(r.field); } },
        { header: 'Finding', cell: r => t(str(r.message)) },
      ]} />
      {editable ? (
        <>
          {sales ? <p>{t('Applicant')}: {str(terms.fields?.applicantName)}</p> : <>
          <Form title="Beneficiary · 59" submit="Choose" onSubmit={() => run(() => api('PUT', `/requests/${id}/terms`, { fields: { beneficiary: edit.beneficiary } }), 'The terms are saved.')}>
            <Field label="Find a supplier" value={q} onChange={setQ} required={false} />
            <Select label="Supplier" value={edit.beneficiary ?? ''} onChange={v => setEdit({ ...edit, beneficiary: v })}
              options={[{ value: '', label: t('Choose') }, ...suppliers.map(s => ({ value: str(s.id), label: `${lang === 'ar' ? str(s.nameAr ?? s.nameEn) : str(s.nameEn)} (${str(s.country)})` }))]} />
          </Form>
          <Form title="Beneficiary's IBAN" submit="Save" onSubmit={() => run(() => api('PUT', `/requests/${id}/terms/beneficiary-iban`, { iban }), 'The IBAN is saved.')}>
            <Field label="IBAN" value={iban} onChange={setIban} required={false} hint="It is stored encrypted and shown masked." />
          </Form>
          </>}
          <Form title="Terms" submit="Save" onSubmit={save}>
            {FIELDS.filter(d => !DEFERRAL.has(d.key) || hasDeferral(edit.lcType)).map(d => <div key={d.key} className="with-tag">
              {d.options
                ? <Select label={d.label} value={edit[d.key] ?? ''} onChange={v => setEdit({ ...edit, [d.key]: v })}
                    options={[{ value: '', label: '—' }, ...d.options.map(o => ({ value: o, label: t(o) }))]} />
                : <Field label={d.label} type={d.type ?? 'text'} value={edit[d.key] ?? ''} onChange={v => setEdit({ ...edit, [d.key]: v })} required={false} />}
              <Tag tag={d.tag} lcType={edit.lcType} />
            </div>)}
          </Form>
          <Form title="Documents required · 46A" submit="Save the documents" onSubmit={() => run(() => api('PUT', `/requests/${id}/terms/documents`,
            docs.filter(d => d.clause).map(d => ({ clause: d.clause, originals: Number(d.originals || 0), copies: Number(d.copies || 0) }))), 'The documents are saved.')}>
            {docs.map((d, i) => (
              <div className="row" key={i}>
                <Select label="Document" value={d.clause} onChange={v => setDocs(docs.map((x, j) => j === i ? { ...x, clause: v } : x))}
                  options={[{ value: '', label: t('Choose') }, ...clauses.map(c => ({ value: str(c.code), label: lang === 'ar' ? str(c.nameAr ?? c.nameEn) : str(c.nameEn) }))]} />
                <Field label="Originals" type="number" value={d.originals} onChange={v => setDocs(docs.map((x, j) => j === i ? { ...x, originals: v } : x))} />
                <Field label="Copies" type="number" value={d.copies} onChange={v => setDocs(docs.map((x, j) => j === i ? { ...x, copies: v } : x))} />
              </div>
            ))}
            <button type="button" onClick={() => setDocs([...docs, { clause: '', originals: '1', copies: '1' }])}>{t('Add a document')}</button>
          </Form>
          <Form title="Charges · 71D" submit="Apply the preset" onSubmit={() => run(() => api('PUT', `/requests/${id}/terms/charges`, { preset }), 'The charges are set.')}>
            <Select label="Preset" value={preset} onChange={setPreset} options={['OWN_BANK', 'ALL_APPLICANT', 'ALL_BENEFICIARY', 'SPLIT_50'].map(p => ({ value: p, label: t(`Charges ${p}`) }))} />
          </Form>
        </>
      ) : (
        <Table rows={FIELDS.filter(d => terms.fields?.[d.key] != null).map(d => ({ key: d.key, label: d.label, value: terms.fields?.[d.key] }))} empty="No field." columns={[
          { header: 'Field', cell: r => t(str(r.label)) }, { header: 'Value', cell: r => <span dir="auto">{t(str(r.value))}</span> },
          { header: 'SWIFT', cell: r => <Tag tag={FIELDS.find(d => d.key === r.key)?.tag} lcType={str(terms.fields?.lcType)} /> },
        ]} />
      )}
      <h2>{t('Charges')}</h2>
      <Table rows={terms.charges ?? []} empty="No charge." columns={[
        { header: 'Category', cell: r => t(str(r.category)) }, { header: 'Payer', cell: r => t(str(r.payer)) }, { header: 'Applicant share %', cell: r => str(r.applicantSharePct) },
      ]} />
    </section>
  );
}
