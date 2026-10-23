import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-OBL-01 (the agenda of a facility: what falls due, what is late, submitted, waived or not applicable), SCR-OBL-02
// (the obligations of the facility as data: reporting rules, covenants with their thresholds, static clauses and
// restrictions, written in the facility's draft revision) and SCR-OBL-04 (the breaches: late reports and manual ones,
// cure, bank notice and waivers). Covenant tests are S2-b.

interface Obligation {
  id: string; family: string; type: string; titleAr: string; titleEn?: string; scopeLimit?: string; clauseRef?: string; graceDays?: number; cureDays?: number;
  paramValue?: number; paramUnit?: string; validFrom: string; validTo?: string;
  reporting?: { frequency: string; anchorKind: string; offsetValue?: number; offsetUnit: string; fixedDueDate?: string; direction: string } | null;
  covenant?: { measureKind: string; formula?: string; operator?: string; thresholdState: string; thresholdValue?: number; thresholdUnit?: string } | null;
}
interface Item {
  id: string; titleAr: string; frequency: string; periodEnd?: string; eventDate?: string; dueDate: string; status: string; statusReason?: string; submittedOn?: string;
  daysLate?: number; expectsEvidence: boolean;
}

const statusClass = (s: string) => s === 'OVERDUE' ? 'error' : s === 'DUE_SOON' ? 'warn' : '';

/** The obligations and the agenda on the facility card. */
export function FacilityObligations({ id, draft, edit }: { id: string; draft: boolean; edit: boolean }) {
  const { t } = useI18n();
  const me = useMe();
  const [view, setView] = useState<'approved' | 'draft'>('approved');
  const [rows, setRows] = useState<Obligation[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [compliance, setCompliance] = useState<{ status: string; overdue: number; dueSoon: number; openBreaches: number } | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [d, setD] = useState({ obligationType: 'AUDITED_ANNUAL_FS', titleAr: '', frequency: 'ANNUAL', anchorKind: 'AFTER_FISCAL_YEAR_END', offsetValue: '', offsetUnit: 'CALENDAR_DAYS',
    fixedDueDate: '', measureKind: 'RATIO', formula: '', operator: 'LE', thresholdState: 'SET', thresholdValue: '', cureDays: '', noSourceReason: '',
    testFrequency: 'ANNUAL', currency: 'SAR', aggregationMode: 'EACH_MONTH_MIN', annualWindowBasis: 'FISCAL_YEAR', revenueBasisRule: 'SAME_PERIOD', earlyWarningPct: '', submissionLagDays: '' });
  const [submit, setSubmit] = useState<{ item: string; on: string }>({ item: '', on: '' });
  const [event, setEvent] = useState({ obligation: '', on: '' });
  const [review, setReview] = useState({ obligation: '', status: 'COMPLIANT', next: '', note: '' });
  const load = useCallback(async () => {
    setRows((await api<{ items: Obligation[] }>('GET', `/facilities/${id}/obligations${view === 'draft' ? '?view=draft' : ''}`)).items);
    setItems((await api<{ items: Item[] }>('GET', `/facilities/${id}/agenda`)).items);
    try { setCompliance(await api('GET', `/facilities/${id}/compliance`)); } catch { setCompliance(null); }
  }, [id, view]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (!draft) setView('approved'); }, [draft]);
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const family = d.obligationType.endsWith('_FS') || d.obligationType.startsWith('NOTICE_') || d.obligationType.endsWith('_CERT') || d.obligationType.endsWith('_RENEWAL')
    ? 'REPORTING' : ['DEBT_TO_EQUITY', 'CURRENT_RATIO', 'DSCR', 'NET_DEBT_TO_EBITDA', 'MIN_TANGIBLE_NET_WORTH', 'REVENUE_CHANNELLING_PCT', 'CAPITAL_PRESERVATION', 'MIN_AVG_BALANCE', 'MIN_INFLOW',
    'NO_DIVIDENDS', 'NO_OWNERSHIP_CHANGE', 'SALES_PROCEEDS_DIRECTION'].includes(d.obligationType)
      ? 'COVENANT' : 'OTHER';
  return (
    <>
      <section className="card">
        <h2>{t('Obligations')} {compliance && <span className={`badge ${compliance.status === 'RED' ? 'error' : compliance.status === 'AMBER' ? 'warn' : ''}`}>{t(compliance.status)}</span>}</h2>
        {draft && <div className="row">
          <button className={view === 'approved' ? '' : 'link'} onClick={() => setView('approved')}>{t('Approved')}</button>
          <button className={view === 'draft' ? '' : 'link'} onClick={() => setView('draft')}>{t('Draft')}</button>
        </div>}
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Obligation', cell: o => <>{o.titleAr} <small className="muted">{t(o.family)}</small></> },
          { header: 'Rule', cell: o => o.reporting ? <span dir="ltr">{o.reporting.frequency} · {o.reporting.anchorKind} {o.reporting.offsetValue ?? o.reporting.fixedDueDate} {o.reporting.offsetUnit}</span>
            : o.covenant ? <span dir="ltr">{o.covenant.formula} {o.covenant.thresholdState === 'SET' ? `${o.covenant.operator} ${o.covenant.thresholdValue}` : t(o.covenant.thresholdState)}</span>
              : o.paramValue != null ? <span dir="ltr">{o.paramValue} {o.paramUnit}</span> : null },
          { header: 'Effective', cell: o => <span dir="ltr">{o.validFrom}{o.validTo && ` → ${o.validTo}`}</span> },
          { header: '', cell: o => view === 'draft' && edit ? <button className="link" onClick={() => void act(() => api('DELETE', `/facilities/${id}/obligations/${o.id}`))}>{t('Remove')}</button>
            : o.reporting?.frequency === 'EVENT_BASED' && can(me, 'obl.record') ? <button className="link" onClick={() => setEvent({ obligation: o.id, on: '' })}>{t('Log an event')}</button>
              : o.covenant?.measureKind === 'NONE' && can(me, 'obl.record') ? <button className="link" onClick={() => setReview({ obligation: o.id, status: 'COMPLIANT', next: '', note: '' })}>{t('Record a review')}</button>
                : null },
        ]} />
        {review.obligation && <div className="row">
          <Select label="Status" value={review.status} onChange={v => setReview({ ...review, status: v })}
            options={['COMPLIANT', 'NON_COMPLIANT', 'UNDER_REVIEW'].map(x => ({ value: x, label: t(x) }))} />
          <Field label="Next review" value={review.next} onChange={v => setReview({ ...review, next: v })} type="date" required={false} />
          <Field label="Note" value={review.note} onChange={v => setReview({ ...review, note: v })} required={false} />
          <button onClick={() => void act(async () => {
            await api('POST', `/facilities/${id}/obligations/${review.obligation}/reviews`, { status: review.status, nextReviewOn: review.next || undefined, note: review.note || undefined });
            setReview({ obligation: '', status: 'COMPLIANT', next: '', note: '' });
          })}>{t('Record a review')}</button>
        </div>}
        {event.obligation && <div className="row">
          <Field label="Event date" value={event.on} onChange={v => setEvent({ ...event, on: v })} type="date" />
          <button onClick={() => void act(async () => { await api('POST', `/facilities/${id}/obligations/${event.obligation}/events`, { eventDate: event.on }); setEvent({ obligation: '', on: '' }); })}>{t('Log an event')}</button>
        </div>}
      </section>
      {draft && edit && view === 'draft' && <Form title="Add an obligation" submit="Add" onSubmit={() => act(() => api('POST', `/facilities/${id}/obligations`, {
        obligationType: d.obligationType, titleAr: d.titleAr, noSourceReason: d.noSourceReason, cureDays: d.cureDays ? Number(d.cureDays) : undefined,
        reporting: family === 'REPORTING' ? {
          frequency: d.frequency, anchorKind: d.anchorKind, offsetValue: d.anchorKind === 'FIXED_DATE' ? undefined : Number(d.offsetValue || 0), offsetUnit: d.offsetUnit,
          fixedDueDate: d.anchorKind === 'FIXED_DATE' ? d.fixedDueDate : undefined, expectsEvidence: false,
        } : undefined,
        covenant: family === 'COVENANT' ? d.measureKind === 'NONE' ? { measureKind: 'NONE' } : {
          measureKind: d.measureKind, formula: ['RATIO', 'AMOUNT', 'PERCENT_OF_REVENUE'].includes(d.measureKind) ? d.formula || d.obligationType : undefined,
          operator: d.thresholdState === 'SET' ? d.operator : undefined, thresholdState: d.thresholdState,
          thresholdValue: d.thresholdState === 'SET' ? Number(d.thresholdValue) : undefined, testFrequency: d.testFrequency,
          thresholdUnit: d.thresholdState === 'SET' && ['AVERAGE_BALANCE', 'FLOW_VOLUME'].includes(d.measureKind) ? 'AMOUNT' : undefined,
          currency: d.thresholdState === 'SET' && ['AMOUNT', 'AVERAGE_BALANCE', 'FLOW_VOLUME'].includes(d.measureKind) ? d.currency : undefined,
          aggregationMode: d.measureKind === 'AVERAGE_BALANCE' ? d.aggregationMode : undefined,
          annualWindowBasis: ['FLOW_VOLUME', 'PERCENT_OF_REVENUE'].includes(d.measureKind) ? d.annualWindowBasis : undefined,
          revenueBasisRule: d.measureKind === 'PERCENT_OF_REVENUE' ? d.revenueBasisRule : undefined,
          earlyWarningPct: d.earlyWarningPct === '' ? undefined : Number(d.earlyWarningPct), submissionLagDays: d.submissionLagDays === '' ? undefined : Number(d.submissionLagDays),
        } : undefined,
      }))}>
        <Field label="Obligation type" value={d.obligationType} onChange={v => setD({ ...d, obligationType: v.toUpperCase() })} />
        <Field label="Title" value={d.titleAr} onChange={v => setD({ ...d, titleAr: v })} />
        {family === 'REPORTING' && <>
          <Select label="Frequency" value={d.frequency} onChange={v => setD({ ...d, frequency: v })}
            options={['ANNUAL', 'SEMIANNUAL', 'QUARTERLY', 'MONTHLY', 'ONE_TIME', 'EVENT_BASED', 'ON_DEMAND'].map(x => ({ value: x, label: x }))} />
          <Select label="Anchor" value={d.anchorKind} onChange={v => setD({ ...d, anchorKind: v })}
            options={['AFTER_FISCAL_YEAR_END', 'AFTER_PERIOD_END', 'BEFORE_EVENT', 'AFTER_EVENT', 'FIXED_DATE', 'ON_DEMAND_REQUEST'].map(x => ({ value: x, label: x }))} />
          {d.anchorKind === 'FIXED_DATE'
            ? <Field label="Due date" value={d.fixedDueDate} onChange={v => setD({ ...d, fixedDueDate: v })} type="date" />
            : <><Field label="Offset" value={d.offsetValue} onChange={v => setD({ ...d, offsetValue: v })} type="number" />
              <Select label="Unit" value={d.offsetUnit} onChange={v => setD({ ...d, offsetUnit: v })} options={['CALENDAR_DAYS', 'BUSINESS_DAYS', 'MONTHS'].map(x => ({ value: x, label: x }))} /></>}
        </>}
        {family === 'COVENANT' && <>
          <Select label="Measure" value={d.measureKind} onChange={v => setD({ ...d, measureKind: v })} options={['RATIO', 'AMOUNT', 'PERCENT_OF_REVENUE', 'AVERAGE_BALANCE', 'FLOW_VOLUME', 'NONE'].map(x => ({ value: x, label: x }))} />
          {d.measureKind !== 'NONE' && <><Field label="Formula" value={d.formula} onChange={v => setD({ ...d, formula: v })} required={false} />
          <Select label="Threshold" value={d.thresholdState} onChange={v => setD({ ...d, thresholdState: v })}
            options={['SET', 'NOT_SPECIFIED_IN_AGREEMENT', 'TO_BE_DETERMINED'].map(x => ({ value: x, label: x }))} />
          {d.thresholdState === 'SET' && <>
            <Select label="Operator" value={d.operator} onChange={v => setD({ ...d, operator: v })} options={['LE', 'GE', 'LT', 'GT', 'EQ'].map(x => ({ value: x, label: x }))} />
            <Field label="Threshold value" value={d.thresholdValue} onChange={v => setD({ ...d, thresholdValue: v })} type="number" />
            {['AMOUNT', 'AVERAGE_BALANCE', 'FLOW_VOLUME'].includes(d.measureKind) && <Field label="Currency" value={d.currency} onChange={v => setD({ ...d, currency: v })} />}
          </>}
          <Select label="Test frequency" value={d.testFrequency} onChange={v => setD({ ...d, testFrequency: v })}
            options={['ANNUAL', 'SEMIANNUAL', 'QUARTERLY', 'MONTHLY', 'ROLLING_12M'].map(x => ({ value: x, label: x }))} />
          {d.measureKind === 'AVERAGE_BALANCE' && <Select label="Months taken" value={d.aggregationMode} onChange={v => setD({ ...d, aggregationMode: v })}
            options={['EACH_MONTH_MIN', 'PERIOD_AVERAGE', 'POINT_IN_TIME', 'PERIOD_SUM'].map(x => ({ value: x, label: x }))} />}
          {['FLOW_VOLUME', 'PERCENT_OF_REVENUE'].includes(d.measureKind) && <Select label="Annual window" value={d.annualWindowBasis} onChange={v => setD({ ...d, annualWindowBasis: v })}
            options={['FISCAL_YEAR', 'CALENDAR_YEAR', 'FACILITY_YEAR'].map(x => ({ value: x, label: x }))} />}
          {d.measureKind === 'PERCENT_OF_REVENUE' && <Select label="Revenue basis" value={d.revenueBasisRule} onChange={v => setD({ ...d, revenueBasisRule: v })}
            options={['SAME_PERIOD', 'PRIOR_YEAR', 'MANUAL_ESTIMATE'].map(x => ({ value: x, label: x }))} />}
          <Field label="Early warning %" value={d.earlyWarningPct} onChange={v => setD({ ...d, earlyWarningPct: v })} type="number" required={false} />
          <Field label="Submission lag (days)" value={d.submissionLagDays} onChange={v => setD({ ...d, submissionLagDays: v })} type="number" required={false} />
          </>}
        </>}
        <Field label="Cure days" value={d.cureDays} onChange={v => setD({ ...d, cureDays: v })} type="number" required={false} />
        <Field label="Source (or why there is none)" value={d.noSourceReason} onChange={v => setD({ ...d, noSourceReason: v })} />
      </Form>}
      <section className="card">
        <h2>{t('Agenda')}</h2>
        <Table rows={items} columns={[
          { header: 'Obligation', cell: i => i.titleAr },
          { header: 'Period', cell: i => <span dir="ltr">{i.periodEnd ?? i.eventDate}</span> },
          { header: 'Due date', cell: i => <span dir="ltr">{i.dueDate}</span> },
          { header: 'Status', cell: i => <span className={statusClass(i.status)}>{t(i.status)}{i.daysLate ? ` (${i.daysLate} ${t('days late')})` : ''}</span> },
          { header: '', cell: i => ['SCHEDULED', 'DUE_SOON', 'OVERDUE'].includes(i.status) && can(me, 'obl.record')
            ? <button className="link" onClick={() => setSubmit({ item: i.id, on: '' })}>{t('Submit')}</button> : i.statusReason },
        ]} />
        {submit.item && <div className="row">
          <Field label="Submission date" value={submit.on} onChange={v => setSubmit({ ...submit, on: v })} type="date" />
          <button onClick={() => void act(async () => { await api('POST', `/reporting-instances/${submit.item}/actions/submit`, { submittedOn: submit.on }); setSubmit({ item: '', on: '' }); })}>{t('Submit')}</button>
        </div>}
      </section>
    </>
  );
}

interface Breach {
  id: string; facility: string; facilityNo: string; obligation: string; kind: string; detectedOn: string; status: string; cureDeadline?: string; bankNotifiedOn?: string;
  waiverRef?: string; resolvedOn?: string;
}

/** SCR-OBL-04: the breach register with its actions. */
export function Breaches() {
  const { t } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Breach[]>([]);
  const [status, setStatus] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [waiver, setWaiver] = useState({ breach: '', waiverRef: '', waiverDate: '', bankContact: '', document: '' });
  const load = useCallback(async () => setRows((await api<{ items: Breach[] }>('GET', `/breaches${status ? '?status=' + status : ''}`)).items), [status]);
  useEffect(() => { void load(); }, [load]);
  const act = async (b: string, action: string, body: object = {}) => {
    setNotice({});
    try { await api('POST', `/breaches/${b}/actions/${action}`, body); await load(); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Breaches')}</h1>
        <Select label="Status" value={status} onChange={setStatus} options={['', 'OPEN', 'IN_CURE', 'CURED', 'WAIVED', 'CLOSED_NO_ACTION'].map(s => ({ value: s, label: s || 'All' }))} />
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Facility', cell: b => <Link to={`/facilities/${b.facility}`} dir="ltr">{b.facilityNo}</Link> },
          { header: 'Obligation', cell: b => b.obligation },
          { header: 'Kind', cell: b => t(b.kind) },
          { header: 'Detected', cell: b => <span dir="ltr">{b.detectedOn}</span> },
          { header: 'Status', cell: b => <>{t(b.status)}{b.cureDeadline && <small className="muted" dir="ltr"> {b.cureDeadline}</small>}</> },
          { header: '', cell: b => ['OPEN', 'IN_CURE'].includes(b.status) ? <span className="actions">
            {can(me, 'obl.breach.manage') && <>
              <button className="link" onClick={() => void act(b.id, 'notify-bank')}>{t('Bank notified')}</button>
              <button className="link" onClick={() => void act(b.id, 'cure')}>{t('Cured')}</button>
              <button className="link" onClick={() => setWaiver({ ...waiver, breach: b.id })}>{t('Record a waiver')}</button>
            </>}
            {b.waiverRef && can(me, 'obl.waiver.approve') && <button className="link" onClick={() => void act(b.id, 'approve-waiver')}>{t('Approve the waiver')}</button>}
          </span> : <span dir="ltr">{b.resolvedOn}</span> },
        ]} />
      </section>
      {waiver.breach && <Form title="Record a waiver" submit="Save" onSubmit={() => act(waiver.breach, 'record-waiver', waiver)}>
        <Field label="Bank reference" value={waiver.waiverRef} onChange={v => setWaiver({ ...waiver, waiverRef: v })} />
        <Field label="Waiver date" value={waiver.waiverDate} onChange={v => setWaiver({ ...waiver, waiverDate: v })} type="date" />
        <Field label="Bank contact (its id)" value={waiver.bankContact} onChange={v => setWaiver({ ...waiver, bankContact: v })} />
        <Field label="Waiver document (its id)" value={waiver.document} onChange={v => setWaiver({ ...waiver, document: v })} />
      </Form>}
    </>
  );
}
