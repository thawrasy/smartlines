import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Notice, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-OBL-03 (the covenant tests of a facility: period, due date, state, result, actual value against the threshold,
// headroom, and "why this result?" with the inputs the evaluation read) and SCR-FIN-05 (the breaches and early
// warnings found on the statements, R-FIN-05).

interface Test {
  id: string; obligationTitleAr: string; obligationTitleEn?: string; measureKind: string; formula?: string; periodStart: string; periodEnd: string; dueDate: string;
  evaluationNo: number; state: string; result?: string; method: string; actualValue?: number; threshold?: number; operator?: string; unit?: string; headroom?: number;
  headroomPct?: number; cancelReason?: string; reviewNote?: string; inputs?: Record<string, unknown> | null;
}

const name = (lang: string, ar?: string | null, en?: string | null) => (lang === 'ar' ? ar ?? en : en ?? ar) ?? '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 6 });
const ops: Record<string, string> = { GE: '≥', GT: '>', LE: '≤', LT: '<', EQ: '=' };
const resultClass = (r?: string) => r === 'BREACH' || r === 'MISSING_DATA' ? 'error' : r === 'WARNING' || r === 'NOT_COMPARABLE' ? 'warn' : r === 'COMPLIANT' ? 'ok' : '';

/** The tests on the facility card. */
export function FacilityCovenantTests({ id }: { id: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Test[]>([]);
  const [open, setOpen] = useState<{ test: Test; history: Test[]; breach?: { status: string; needsReview: boolean } | null } | null>(null);
  const [note, setNote] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    try { setRows((await api<{ items: Test[] }>('GET', `/facilities/${id}/covenant-tests`)).items); } catch { setRows([]); }
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  const show = async (test: string) => setOpen(await api('GET', `/covenant-tests/${test}`));
  const act = async (fn: () => Promise<unknown>) => {
    setNotice({});
    try { await fn(); await load(); if (open) await show(open.test.id); setNotice({ ok: 'Saved.' }); } catch (e) { setNotice({ error: message(e) }); }
  };
  const past = rows.filter(r => r.state !== 'SCHEDULED' && r.state !== 'CANCELLED');
  return (
    <>
      <section className="card">
        <h2>{t('Covenant tests')}</h2>
        <Notice {...notice} />
        <Table rows={past.length ? past : rows.slice(0, 8)} columns={[
          { header: 'Covenant', cell: r => name(lang, r.obligationTitleAr, r.obligationTitleEn) },
          { header: 'Period end', cell: r => <span dir="ltr">{r.periodEnd}</span> },
          { header: 'Due date', cell: r => <span dir="ltr">{r.dueDate}</span> },
          { header: 'State', cell: r => <Chip s={r.state} /> },
          { header: 'Result', cell: r => <span className={resultClass(r.result)}>{r.result ? t(r.result) : ''}</span> },
          { header: 'Value', cell: r => <span dir="ltr">{amount(r.actualValue)} {r.operator && `${ops[r.operator]} ${amount(r.threshold)}`}</span> },
          { header: 'Headroom', cell: r => <span dir="ltr">{amount(r.headroom)}{r.headroomPct != null && ` (${amount(r.headroomPct)}%)`}</span> },
          { header: '', cell: r => <button className="link" onClick={() => show(r.id)}>{t('Why this result?')}</button> },
        ]} />
      </section>
      {open && (
        <section className="card">
          <h3>{name(lang, open.test.obligationTitleAr, open.test.obligationTitleEn)} <small className="muted" dir="ltr">{open.test.periodStart} → {open.test.periodEnd}</small></h3>
          {open.breach && <p className={open.breach.needsReview ? 'warn' : 'error'}>{t('Breach')}: {t(open.breach.status)}{open.breach.needsReview && ` · ${t('Needs review')}`}</p>}
          <Table rows={open.history} columns={[
            { header: 'Evaluation', cell: h => h.evaluationNo },
            { header: 'Method', cell: h => t(h.method) },
            { header: 'Result', cell: h => <span className={resultClass(h.result)}>{h.result ? t(h.result) : t(h.state)}</span> },
            { header: 'Value', cell: h => <span dir="ltr">{amount(h.actualValue)}</span> },
          ]} />
          <h4>{t('Inputs')}</h4>
          <pre dir="ltr" className="scroll">{JSON.stringify(open.test.inputs, null, 2)}</pre>
          {open.test.reviewNote && <p>{t('Review note')}: {open.test.reviewNote}</p>}
          <div className="row">
            {can(me, 'fin.verify.run') && open.test.state !== 'CANCELLED' &&
              <button onClick={() => act(() => api('POST', `/covenant-tests/${open.test.id}/actions/evaluate`, {}))}>{t('Evaluate again')}</button>}
            {can(me, 'obl.record') && open.test.state === 'EVALUATED' && <>
              <Field label="Review note" value={note} onChange={setNote} required={false} />
              <button className="link" onClick={() => act(() => api('POST', `/covenant-tests/${open.test.id}/actions/review`, { note }))}>{t('Mark reviewed')}</button>
            </>}
          </div>
        </section>
      )}
    </>
  );
}

interface ReportRow {
  companyNameAr: string; facilityNo: string; bank?: string; obligationTitleAr: string; clauseRef?: string; formula?: string; periodEnd: string; result: string; severity: string;
  actualValue?: number; operator?: string; threshold?: number; headroomPct?: number; statementVersion: number; basis: string; assurance: string; statementSuperseded: boolean;
  breachStatus?: string; needsReview?: boolean;
}

/** SCR-FIN-05: R-FIN-05, the breaches and early warnings arising from the statements. */
export function StatementBreaches() {
  const { t } = useI18n();
  const [rows, setRows] = useState<ReportRow[]>([]);
  useEffect(() => { void api<{ items: ReportRow[] }>('GET', '/reports/statement-breaches').then(r => setRows(r.items)).catch(() => setRows([])); }, []);
  return (
    <section className="card">
      <h1>{t('Breaches found on the statements')}</h1>
      <Table rows={rows} columns={[
        { header: 'Company', cell: r => r.companyNameAr },
        { header: 'Facility', cell: r => <span dir="ltr">{r.facilityNo} {r.bank}</span> },
        { header: 'Covenant', cell: r => <>{r.obligationTitleAr} <small className="muted">{r.clauseRef}</small></> },
        { header: 'Period end', cell: r => <span dir="ltr">{r.periodEnd.slice(0, 10)}</span> },
        { header: 'Result', cell: r => <span className={r.severity === 'BREACH' ? 'error' : 'warn'}>{t(r.result)}</span> },
        { header: 'Value', cell: r => <span dir="ltr">{amount(r.actualValue)} {r.operator && `${ops[r.operator]} ${amount(r.threshold)}`} ({amount(r.headroomPct)}%)</span> },
        { header: 'Statement', cell: r => <>{t(r.basis)} · {t(r.assurance)} · v{r.statementVersion}{r.statementSuperseded && <span className="warn"> {t('superseded')}</span>}</> },
        { header: 'Breach', cell: r => <>{r.breachStatus ? t(r.breachStatus) : ''}{r.needsReview && <span className="warn"> {t('Needs review')}</span>}</> },
      ]} />
    </section>
  );
}
