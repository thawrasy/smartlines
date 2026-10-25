import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-FIN-08 (the readiness file of an assessment: the lender's dates within the lead time with their readiness, what
// the lender will ask for, the timeline of actions and the warnings issued; the endorsement for use outside the
// company and its evidence pack; the ratings the lenders communicated beside the assessment and the calibration) and
// SCR-FIN-09 (the loss rates of the provision matrix and the provision check of the statements). Seen from the
// company's side: what will the lender see, and what do we do before it.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 4 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 10);
const tone = (r: unknown) => r === 'RED' ? 'error' : r === 'AMBER' ? 'warn' : r === 'GREEN' ? 'ok' : '';
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

interface File { events: Row[]; requests: Row[]; actions: Row[]; warnings: Row[] }
interface Endorsement { endorsed: boolean; endorsedOn?: string; note?: string; bias?: string; useScope: string; canEndorse: boolean; reasons: string[] }

export function ReadinessFile() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [file, setFile] = useState<File | null>(null);
  const [endorsement, setEndorsement] = useState<Endorsement | null>(null);
  const [note, setNote] = useState('');
  const [purpose, setPurpose] = useState('');
  const [sha, setSha] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    setFile(await api('GET', `/fin/assessments/${id}/readiness`));
    setEndorsement(await api('GET', `/fin/assessments/${id}/endorsement`));
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!file || !endorsement) return null;
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Readiness before the lenders')} <small><Link to={`/assessments/${id}`}>{t('Open the assessment')}</Link></small></h1>
        <Table rows={file.events} empty="No lender date within the lead time." columns={[
          { header: 'Date', cell: r => <span dir="ltr">{day(r.EventDate)}</span> },
          { header: 'Kind', cell: r => t(str(r.EventKind)) },
          { header: 'Reference', cell: r => <span dir="ltr">{str(r.Reference ?? r.RefId)}</span> },
          { header: 'Readiness', cell: r => <strong className={tone(r.Readiness)}>{t(str(r.Readiness))}</strong> },
          { header: 'Reason', cell: r => pick(lang, r, 'Reason') || t(str(r.ReasonCode)) },
        ]} />
      </section>
      <section className="card">
        <h2>{t('What the lender will ask for')}</h2>
        <Table rows={file.requests} columns={[
          { header: 'Kind', cell: r => t(str(r.RequestKind)) },
          { header: 'Request', cell: r => pick(lang, r, 'Text') },
        ]} />
        <h2>{t('Actions before the date')}</h2>
        <Table rows={file.actions} columns={[
          { header: 'Deadline', cell: r => <span dir="ltr">{day(r.Deadline)}</span> },
          { header: 'Phase', cell: r => t(str(r.Phase)) },
          { header: 'Action', cell: r => pick(lang, r, 'Text') || <span dir="ltr">{str(r.ActionCode)}</span> },
        ]} />
        <h2>{t('Warnings issued')}</h2>
        <Table rows={file.warnings} columns={[
          { header: 'Issued on', cell: r => <span dir="ltr">{day(r.IssuedOn)}</span> },
          { header: 'Kind', cell: r => t(str(r.EventKind)) },
          { header: 'Date', cell: r => <span dir="ltr">{day(r.EventDate)}</span> },
          { header: 'Stage', cell: r => t(str(r.Stage)) },
          { header: 'Readiness', cell: r => <span className={tone(r.Readiness)}>{t(str(r.Readiness))}</span> },
        ]} />
      </section>
      <section className="card">
        <h2>{t('Use outside the company')}</h2>
        <Notice {...notice} />
        <p>{t(endorsement.useScope)}{endorsement.endorsed && <> · <span dir="ltr">{day(endorsement.endorsedOn)}</span> · {endorsement.note} · {t('Bias')} {t(str(endorsement.bias))}</>}</p>
        {!endorsement.endorsed && (endorsement.canEndorse ? <div className="row">
          <Field label="Why and for whom" value={note} onChange={setNote} />
          <button onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/endorse`, { note }), 'Endorsed.')}>{t('Endorse')}</button>
        </div> : <ul className="muted">{endorsement.reasons.map(r => <li key={r}>{t(r)}</li>)}</ul>)}
        {endorsement.endorsed && (can(me, 'fin.credit.endorse') || can(me, 'fin.credit.approve')) && <div className="row">
          <Field label="Purpose of the pack" value={purpose} onChange={setPurpose} />
          <button onClick={() => act(async () => setSha((await api<{ sha256: string }>('POST', `/fin/assessments/${id}/actions/evidence-pack`, { purpose })).sha256), 'Built.')}>
            {t('Build the evidence pack')}</button>
        </div>}
        {sha && <p>SHA-256 <code dir="ltr">{sha}</code></p>}
      </section>
    </>
  );
}

export function LenderRatings() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [companies, setCompanies] = useState<Row[]>([]);
  const [banks, setBanks] = useState<Row[]>([]);
  const [calibration, setCalibration] = useState<Row[]>([]);
  const [drivers, setDrivers] = useState<Row[]>([]);
  const [company, setCompany] = useState('');
  const [d, setD] = useState({ lender: '', ratingDate: '', lenderGradeLabel: '', grade: 'Baa3', mappingKind: 'GIVEN_BY_LENDER', lenderReasons: '', noSourceReason: '' });
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    setRows((await api<{ items: Row[] }>('GET', `/fin/lender-ratings${company ? `?company=${company}` : ''}`)).items);
    setCalibration(company ? (await api<{ items: Row[] }>('GET', `/fin/calibration?company=${company}`)).items : []);
  }, [company]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/companies').then(r => setCompanies(r.items));
    void api<{ items: Row[] }>('GET', '/institutions').then(r => setBanks(r.items));
  }, []);
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Lender ratings')}</h1>
        <Select label="Company" value={company} onChange={setCompany} options={[{ value: '', label: '' }, ...companies.map(c => ({ value: str(c.id), label: str(c.nameAr) }))]} />
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Date', cell: r => <span dir="ltr">{day(r.ratingDate)}</span> },
          { header: 'Company', cell: r => str(r.companyNameAr) },
          { header: 'Lender', cell: r => lang === 'ar' ? str(r.lenderNameAr) : str(r.lenderNameEn ?? r.lenderNameAr) },
          { header: 'Lender grade', cell: r => <span dir="ltr">{str(r.lenderGradeLabel)} → {str(r.lenderGrade)}</span> },
          { header: 'Assessment', cell: r => r.assessment ? <Link to={`/assessments/${str(r.assessment)}`} dir="ltr">{str(r.assessmentGrade)} ({day(r.assessmentDate)})</Link> : t('NO_ASSESSMENT') },
          { header: 'Gap', cell: r => <span dir="ltr">{str(r.gapNotches)}</span> },
          { header: 'Direction', cell: r => t(str(r.direction)) },
          { header: 'Source', cell: r => t(str(r.confidence)) },
          { header: '', cell: r => <>
            <button className="link" onClick={async () => setDrivers((await api<{ items: Row[] }>('GET', `/fin/lender-ratings/${str(r.id)}/gap-drivers`)).items)}>{t('Where they part')}</button>
            {can(me, 'fin.credit.approve') && !r.enteredByMe && r.sourceDocument && r.confidence !== 'CONFIRMED_AGAINST_ORIGINAL' &&
              <button className="link" onClick={() => act(() => api('POST', `/fin/lender-ratings/${str(r.id)}/actions/verify`, {}))}>{t('Confirm against the letter')}</button>}
          </> },
        ]} />
        {drivers.length > 0 && <Table rows={drivers} columns={[
          { header: 'Kind', cell: r => t(str(r.DriverKind)) },
          { header: 'Factor', cell: r => pick(lang, r, 'Name') },
          { header: 'Grade', cell: r => <span dir="ltr">{str(r.AssessmentGrade)}</span> },
          { header: 'Notches', cell: r => <span dir="ltr">{str(r.NotchesFromLender)}</span> },
          { header: 'Weight', cell: r => <span dir="ltr">{str(r.Weight)}</span> },
        ]} />}
      </section>
      {company && <section className="card">
        <h2>{t('Calibration')}</h2>
        <Table rows={calibration} columns={[
          { header: 'Lender', cell: r => r.allLenders ? t('All lenders') : str(r.lenderNameAr) },
          { header: 'Ratings', cell: r => str(r.ratings) },
          { header: 'Mean gap', cell: r => <span dir="ltr">{str(r.meanGapNotches)}</span> },
          { header: 'Latest gap', cell: r => <span dir="ltr">{str(r.latestGapNotches)}</span> },
          { header: 'Bias', cell: r => t(str(r.bias)) },
        ]} />
      </section>}
      {company && can(me, 'fin.credit.assess') && <Form title="Record a lender rating" submit="Save" onSubmit={async () => {
        await api('POST', '/fin/lender-ratings', { company, ...d, lenderGradeLabel: d.lenderGradeLabel || undefined, lenderReasons: d.lenderReasons || undefined });
        await load();
      }}>
        <Select label="Lender" value={d.lender} onChange={v => setD({ ...d, lender: v })} options={[{ value: '', label: '' }, ...banks.map(b => ({ value: str(b.id), label: str(b.nameAr) }))]} />
        <Field label="Rating date" value={d.ratingDate} onChange={v => setD({ ...d, ratingDate: v })} type="date" />
        <Field label="Lender's own label" value={d.lenderGradeLabel} onChange={v => setD({ ...d, lenderGradeLabel: v })} required={false} />
        <Field label="Grade on the scale" value={d.grade} onChange={v => setD({ ...d, grade: v })} />
        <Select label="Mapping" value={d.mappingKind} onChange={v => setD({ ...d, mappingKind: v })}
          options={[{ value: 'GIVEN_BY_LENDER', label: t('GIVEN_BY_LENDER') }, { value: 'MAPPED_BY_TREASURY', label: t('MAPPED_BY_TREASURY') }]} />
        <Field label="Reasons the lender gave" value={d.lenderReasons} onChange={v => setD({ ...d, lenderReasons: v })} required={false} />
        <Field label="Why there is no letter" value={d.noSourceReason} onChange={v => setD({ ...d, noSourceReason: v })} />
      </Form>}
    </>
  );
}

const buckets = ['AR_AGE_0_90', 'AR_AGE_91_180', 'AR_AGE_181_365', 'AR_AGE_OVER_365', 'AR_AGE_OVER_365_GOV'];

export function Provision() {
  const { t } = useI18n();
  const me = useMe();
  const [rates, setRates] = useState<Row[]>([]);
  const [checks, setChecks] = useState<Row[]>([]);
  const [d, setD] = useState({ bucket: 'AR_AGE_0_90', lossRatePct: '', effectiveFrom: '', note: '' });
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    setRates((await api<{ items: Row[] }>('GET', '/fin/loss-rates')).items);
    setChecks((await api<{ items: Row[] }>('GET', '/fin/provision-check')).items);
  }, []);
  useEffect(() => { void load(); }, [load]);
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Provision matrix')}</h1>
        <Notice {...notice} />
        <Table rows={rates} columns={[
          { header: 'Bucket', cell: r => t(str(r.bucket)) },
          { header: 'Loss rate', cell: r => <span dir="ltr">{str(r.lossRatePct)}%</span> },
          { header: 'Effective from', cell: r => <span dir="ltr">{str(r.effectiveFrom)}</span> },
          { header: 'Status', cell: r => <><Chip s={str(r.status)} />{r.fromPack ? ` · ${t('Default of the pack')}` : ''}</> },
          { header: '', cell: r => r.status === 'DRAFT' && !r.preparedByMe && can(me, 'fin.formula.approve') &&
            <button className="link" onClick={() => act(() => api('POST', `/fin/loss-rates/${str(r.id)}/actions/approve`, {}))}>{t('Approve')}</button> },
        ]} />
      </section>
      {can(me, 'fin.formula.manage') && <Form title="New loss rate" submit="Save" onSubmit={async () => {
        await api('POST', '/fin/loss-rates', { ...d, lossRatePct: Number(d.lossRatePct), note: d.note || undefined });
        await load();
      }}>
        <Select label="Bucket" value={d.bucket} onChange={v => setD({ ...d, bucket: v })} options={buckets.map(b => ({ value: b, label: t(b) }))} />
        <Field label="Loss rate" value={d.lossRatePct} onChange={v => setD({ ...d, lossRatePct: v })} type="number" />
        <Field label="Effective from" value={d.effectiveFrom} onChange={v => setD({ ...d, effectiveFrom: v })} type="date" />
        <Field label="Note" value={d.note} onChange={v => setD({ ...d, note: v })} required={false} />
      </Form>}
      <section className="card">
        <h2>{t('Provision check')}</h2>
        <Table rows={checks} columns={[
          { header: 'Company', cell: r => str(r.companyNameAr) },
          { header: 'Period end', cell: r => <span dir="ltr">{day(r.periodEnd)}</span> },
          { header: 'Recorded', cell: r => <span dir="ltr">{str(r.recordedAllowance)}</span> },
          { header: 'Expected', cell: r => <span dir="ltr">{str(r.expectedAllowance)}</span> },
          { header: 'Shortfall', cell: r => <span dir="ltr">{str(r.shortfall)}</span> },
          { header: 'Rates', cell: r => t(str(r.ratesStatus)) },
          { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
        ]} />
      </section>
    </>
  );
}
