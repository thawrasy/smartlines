import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-FIN-06 (the credit self-assessment of a statement: the analyst's qualitative grades and their justification, the
// computation by the database, the grade on the 21-step scale, the factors, the findings, the remedies; submit,
// approve or return) and SCR-FIN-07 (the presentation versions of a statement before its approval: the remedies
// chosen, the build, the trial assessment beside the source and the choice with its reason). The grades are an
// indicative internal mapping on the scale named after Moody's symbols, not an agency rating (docs/35).

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 4 }) : String(v);
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

export function Assessments() {
  const { t } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [cards, setCards] = useState<Row[]>([]);
  const [statements, setStatements] = useState<Row[]>([]);
  const [d, setD] = useState({ statement: '', scorecard: '', assessmentDate: '', isTrial: 'false' });
  const load = useCallback(async () => setRows((await api<{ items: Row[] }>('GET', '/fin/assessments')).items), []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    void api<{ items: Row[] }>('GET', '/fin/scorecards').then(r => { setCards(r.items); setD(x => ({ ...x, scorecard: x.scorecard || str(r.items[0]?.code) })); });
    void api<{ items: Row[] }>('GET', '/financial-statements').then(r => setStatements(r.items));
  }, []);
  return (
    <>
      <section className="card">
        <h1>{t('Credit self-assessments')}</h1>
        <p className="muted">{t('An indicative internal grade on a scale named after Moody\'s symbols; not an agency rating.')}</p>
        <Table rows={rows} columns={[
          { header: 'Company', cell: r => str(r.companyNameAr) },
          { header: 'Period end', cell: r => <Link to={`/assessments/${str(r.id)}`} dir="ltr">{str(r.periodEnd).slice(0, 10)}</Link> },
          { header: 'Scorecard', cell: r => <span dir="ltr">{str(r.scorecard)}</span> },
          { header: 'Grade', cell: r => <strong dir="ltr">{str(r.finalGrade ?? r.financialGrade)}</strong> },
          { header: 'Status', cell: r => <>{t(str(r.status))}{r.isTrial ? ` · ${t('Trial')}` : ''}</> },
        ]} />
      </section>
      {can(me, 'fin.credit.assess') && <Form title="New assessment" submit="Create" onSubmit={async () => {
        await api('POST', '/fin/assessments', { ...d, isTrial: d.isTrial === 'true', assessmentDate: d.assessmentDate || undefined });
        await load();
      }}>
        <Select label="Statement" value={d.statement} onChange={v => setD({ ...d, statement: v })}
          options={[{ value: '', label: '' }, ...statements.map(s => ({ value: str(s.id), label: `${str((s.company as Row)?.nameAr)} ${str(s.periodEnd)} v${str(s.versionNo)} ${t(str(s.status))}` }))]} />
        <Select label="Scorecard" value={d.scorecard} onChange={v => setD({ ...d, scorecard: v })} options={cards.map(c => ({ value: str(c.code), label: str(c.code) }))} />
        <Field label="Assessment date" value={d.assessmentDate} onChange={v => setD({ ...d, assessmentDate: v })} type="date" required={false} />
        <Select label="Trial" value={d.isTrial} onChange={v => setD({ ...d, isTrial: v })} options={[{ value: 'false', label: 'No' }, { value: 'true', label: 'Yes' }]} />
      </Form>}
    </>
  );
}

export function AssessmentDetail() {
  const { id = '' } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [data, setData] = useState<{ status: string; isTrial: boolean; preparedByMe: boolean; report: Row | null; inputs: Row[] } | null>(null);
  const [factors, setFactors] = useState<Row[]>([]);
  const [findings, setFindings] = useState<Row[]>([]);
  const [remedies, setRemedies] = useState<Row[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [input, setInput] = useState({ metric: 'BUSINESS_PROFILE', grade: 'Baa3', justification: '' });
  const [reason, setReason] = useState('');
  const load = useCallback(async () => {
    setData(await api('GET', `/fin/assessments/${id}`));
    setFactors((await api<{ items: Row[] }>('GET', `/fin/assessments/${id}/report/factors`)).items);
    setFindings((await api<{ items: Row[] }>('GET', `/fin/assessments/${id}/report/findings`)).items);
    setRemedies((await api<{ items: Row[] }>('GET', `/fin/assessments/${id}/report/remedies`)).items);
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return null;
  const r = data.report ?? {};
  const draft = data.status === 'DRAFT';
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{str(r.CompanyNameAr)} <small className="muted" dir="ltr">{str(r.ScorecardCode)} · {str(r.AssessmentDate).slice(0, 10)}</small></h1>
        <p>{t(data.status)}{data.isTrial && ` · ${t('Trial')}`} · {t(str(r.ResultState))}</p>
        <p><strong dir="ltr">{str(r.FinalGrade ?? r.FinancialGrade)}</strong> {pick(lang, r, 'FinalGradeDescription')} · {t('Liquidity')} <span dir="ltr">{str(r.LiquidityLabel)}</span>
          · {t('Outlook')} {pick(lang, r, 'OutlookName')}</p>
        <p className="muted">{t('Financial grade')} <span dir="ltr">{str(r.FinancialGrade)}</span> · {t('Standalone grade')} <span dir="ltr">{str(r.StandaloneGrade)}</span>
          · {t('Coverage')} <span dir="ltr">{str(r.CoveragePct)}%</span> · {t('Disclosures given')} <span dir="ltr">{str(r.CompletenessPct)}%</span></p>
        <p>{lang === 'ar' ? str(r.SummaryAr) : str(r.SummaryEn)}</p>
        <Notice {...notice} />
        <div className="row">
          {draft && can(me, 'fin.credit.assess') && <button onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/compute`, {}), 'Computed.')}>{t('Compute')}</button>}
          {draft && !data.isTrial && can(me, 'fin.credit.assess') && <button onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/submit`, {}), 'Submitted for approval.')}>{t('Submit')}</button>}
          {data.status === 'SUBMITTED' && can(me, 'fin.credit.approve') && !data.preparedByMe && <>
            <button onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/approve`, {}), 'Approved.')}>{t('Approve')}</button>
            <Field label="Reason for returning" value={reason} onChange={setReason} required={false} />
            <button className="link" onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/reject`, { reason }))}>{t('Return to the preparer')}</button>
          </>}
          {data.status === 'REJECTED' && can(me, 'fin.credit.assess') && <button onClick={() => act(() => api('POST', `/fin/assessments/${id}/actions/reopen`, {}))}>{t('Reopen as a draft')}</button>}
        </div>
      </section>
      <section className="card">
        <h2>{t('Qualitative grades')}</h2>
        <Table rows={data.inputs} columns={[
          { header: 'Kind', cell: i => t(str(i.kind)) },
          { header: 'Factor', cell: i => <span dir="ltr">{str(i.metric)} {str(i.subfactor)}</span> },
          { header: 'Grade', cell: i => <span dir="ltr">{str(i.grade ?? i.notches)}</span> },
          { header: 'Justification', cell: i => str(i.justification) },
        ]} />
        {draft && can(me, 'fin.credit.assess') && <Form title="Grade a factor" submit="Save" onSubmit={async () => {
          await api('POST', `/fin/assessments/${id}/inputs`, { kind: 'QUALITATIVE', ...input });
          await load();
        }}>
          <Field label="Factor" value={input.metric} onChange={v => setInput({ ...input, metric: v.toUpperCase() })} />
          <Field label="Grade" value={input.grade} onChange={v => setInput({ ...input, grade: v })} />
          <Field label="Justification" value={input.justification} onChange={v => setInput({ ...input, justification: v })} />
        </Form>}
      </section>
      <section className="card">
        <h2>{t('Factors')}</h2>
        <Table rows={factors} columns={[
          { header: 'Factor', cell: f => pick(lang, f, 'MetricName') },
          { header: 'Value', cell: f => <span dir="ltr">{str(f.Value)}</span> },
          { header: 'Score', cell: f => <span dir="ltr">{str(f.Score)}</span> },
          { header: 'Grade', cell: f => <span dir="ltr">{str(f.Grade)}</span> },
          { header: 'Weight', cell: f => <span dir="ltr">{str(f.WeightPct)}</span> },
        ]} />
      </section>
      <section className="card">
        <h2>{t('Findings')}</h2>
        <Table rows={findings} columns={[
          { header: 'Kind', cell: f => pick(lang, f, 'Kind') || t(str(f.Kind)) },
          { header: 'Finding', cell: f => pick(lang, f, 'Text') },
        ]} />
        <h2>{t('Remedies')}</h2>
        <Table rows={remedies} columns={[
          { header: 'Remedy', cell: x => pick(lang, x, 'RemedyName') || <span dir="ltr">{str(x.RemedyCode)}</span> },
          { header: 'Grade after it', cell: x => <span dir="ltr">{str(x.ProFormaGrade)}</span> },
        ]} />
      </section>
    </>
  );
}

/** SCR-FIN-07: the presentation versions of a statement before its approval. */
export function PresentationVersions() {
  const { t } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [statements, setStatements] = useState<Row[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [d, setD] = useState({ sourceStatement: '', nameAr: '', remedy: 'RETAIN_EARNINGS', justification: '' });
  const [reason, setReason] = useState('');
  const load = useCallback(async () => setRows((await api<{ items: Row[] }>('GET', '/fin/presentation-versions')).items), []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Row[] }>('GET', '/financial-statements').then(r => setStatements(r.items.filter(s => s.status === 'DRAFT' || s.status === 'SUBMITTED'))); }, []);
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Presentation versions')}</h1>
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Name', cell: v => str(v.nameAr) },
          { header: 'Status', cell: v => t(str(v.status)) },
          { header: 'Convertible', cell: v => v.isConvertible == null ? '' : t(v.isConvertible ? 'Yes' : 'No') },
          { header: 'Trial', cell: v => v.trialAssessment ? <Link to={`/assessments/${str(v.trialAssessment)}`}>{t('Open')}</Link> : '' },
          { header: '', cell: v => <>
            {v.status === 'DRAFT' && can(me, 'fin.stmt.enter') && <button className="link" onClick={() => act(() => api('POST', `/fin/presentation-versions/${str(v.id)}/actions/build`, {}), 'Built.')}>{t('Build')}</button>}
            {v.status === 'BUILT' && can(me, 'fin.stmt.approve') && !v.preparedByMe &&
              <button className="link" onClick={() => act(() => api('POST', `/fin/presentation-versions/${str(v.id)}/actions/choose`, { reason }), 'Chosen.')}>{t('Choose')}</button>}
          </> },
        ]} />
        {can(me, 'fin.stmt.approve') && <Field label="Reason for the choice" value={reason} onChange={setReason} required={false} />}
      </section>
      {can(me, 'fin.stmt.enter') && <Form title="New presentation version" submit="Create" onSubmit={async () => {
        await api('POST', '/fin/presentation-versions', { sourceStatement: d.sourceStatement, nameAr: d.nameAr, steps: [{ remedy: d.remedy, justification: d.justification }] });
        await load();
      }}>
        <Select label="Statement" value={d.sourceStatement} onChange={v => setD({ ...d, sourceStatement: v })}
          options={[{ value: '', label: '' }, ...statements.map(s => ({ value: str(s.id), label: `${str((s.company as Row)?.nameAr)} ${str(s.periodEnd)}` }))]} />
        <Field label="Name" value={d.nameAr} onChange={v => setD({ ...d, nameAr: v })} />
        <Field label="Remedy" value={d.remedy} onChange={v => setD({ ...d, remedy: v.toUpperCase() })} />
        <Field label="Justification" value={d.justification} onChange={v => setD({ ...d, justification: v })} />
      </Form>}
    </>
  );
}
