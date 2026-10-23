import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api';
import { useI18n } from '../i18n';
import { Field, Select, Table } from '../ui';

// SCR-OBL-04 (the compliance of a facility on a date by BR-OBL-010: the colour and the rules that set it, the counters
// per family, each measured covenant with its latest result, headroom, the trend over its evaluations, the review flag
// of its breach, and links to the test's "why", the statements it read and the breach) and R-OBL-05 (the group's
// facilities by company, bank and colour).

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 6 }) : String(v);
const tone = (c: unknown) => c === 'RED' || c === 'BREACH' || c === 'MISSING_DATA' ? 'error' : c === 'AMBER' || c === 'WARNING' ? 'warn' : c === 'GREEN' || c === 'COMPLIANT' ? 'ok' : 'muted';
const ops: Record<string, string> = { GE: '≥', GT: '>', LE: '≤', LT: '<', EQ: '=' };

interface Compliance {
  colour: string; asOf: string; validity?: string; reasons: { code: string; count: number }[]; notAssessed: number; notComparable: number; needsReview: number;
  families: { family: string; obligations: number; measured: number; breaches: number; warnings: number }[];
  measures: (Row & { trend: Row[]; statements: { id: string; versionNo: number }[]; breach?: { id: string; status: string; needsReview: boolean } | null })[];
}

export function FacilityCompliance({ id }: { id: string }) {
  const { t, lang } = useI18n();
  const [asOf, setAsOf] = useState('');
  const [c, setC] = useState<Compliance | null>(null);
  const load = useCallback(async () => {
    try { setC(await api('GET', `/facilities/${id}/compliance${asOf ? `?asOf=${asOf}` : ''}`)); } catch { setC(null); }
  }, [id, asOf]);
  useEffect(() => { void load(); }, [load]);
  if (!c) return null;
  return (
    <section className="card">
      <h2>{t('Compliance')} <span className={`badge ${tone(c.colour)}`}>{t(c.colour)}</span> <small className="muted" dir="ltr">{c.asOf}</small></h2>
      <Field label="On the date" value={asOf} onChange={setAsOf} type="date" required={false} />
      {c.reasons.length > 0 && <ul>{c.reasons.map(r => <li key={r.code}>{t(r.code)} <span dir="ltr">({r.count})</span></li>)}</ul>}
      <p className="muted">{t('Not assessed')} <span dir="ltr">{c.notAssessed}</span> · {t('Not comparable')} <span dir="ltr">{c.notComparable}</span>
        · {t('Needs review')} <span dir="ltr">{c.needsReview}</span></p>
      <Table rows={c.families} columns={[
        { header: 'Family', cell: r => t(r.family) },
        { header: 'Obligations', cell: r => r.obligations },
        { header: 'Measured', cell: r => r.measured },
        { header: 'Breaches', cell: r => r.breaches },
        { header: 'Warnings', cell: r => r.warnings },
      ]} />
      <Table rows={c.measures} columns={[
        { header: 'Covenant', cell: m => str(lang === 'ar' ? m.obligationTitleAr : m.obligationTitleEn ?? m.obligationTitleAr) },
        { header: 'Period end', cell: m => <span dir="ltr">{str(m.periodEnd)}</span> },
        { header: 'Result', cell: m => <span className={tone(m.result)}>{m.result ? t(str(m.result)) : t(str(m.state ?? 'SCHEDULED'))}</span> },
        { header: 'Value', cell: m => <span dir="ltr">{str(m.actualValue)} {m.operator ? `${ops[str(m.operator)]} ${str(m.threshold)}` : ''}</span> },
        { header: 'Headroom', cell: m => <span dir="ltr">{str(m.headroom)}{m.headroomPct != null && ` (${str(m.headroomPct)}%)`}</span> },
        { header: 'Evaluations', cell: m => <span dir="ltr">{m.trend.map(x => `${str(x.evaluationNo)}:${t(str(x.result))}`).join(' → ')}</span> },
        { header: 'Statement', cell: m => <>{m.statements.map(s => <span key={s.id} dir="ltr">v{s.versionNo} </span>)}</> },
        { header: 'Breach', cell: m => m.breach ? <>{t(m.breach.status)}{m.breach.needsReview && <span className="warn"> {t('Needs review')}</span>}</> : '' },
      ]} />
    </section>
  );
}

/** R-OBL-05: the group's dashboard. */
export function GroupCompliance() {
  const { t } = useI18n();
  const [rows, setRows] = useState<Row[]>([]);
  const [colour, setColour] = useState('');
  const [asOf, setAsOf] = useState('');
  useEffect(() => {
    const q = new URLSearchParams();
    if (colour) q.set('colour', colour);
    if (asOf) q.set('asOf', asOf);
    void api<{ items: Row[] }>('GET', `/reports/compliance${q.size ? `?${q}` : ''}`).then(r => setRows(r.items)).catch(() => setRows([]));
  }, [colour, asOf]);
  return (
    <section className="card">
      <h1>{t('Group compliance')}</h1>
      <div className="row">
        <Select label="Colour" value={colour} onChange={setColour} options={['', 'RED', 'AMBER', 'GREEN', 'GREY'].map(v => ({ value: v, label: v ? t(v) : '' }))} />
        <Field label="On the date" value={asOf} onChange={setAsOf} type="date" required={false} />
      </div>
      <Table rows={rows} columns={[
        { header: 'Company', cell: r => str(r.companyNameAr) },
        { header: 'Facility', cell: r => { const c = r.compliance as Row; return <Link to={`/facilities/${str(c.facility)}`} dir="ltr">{str(c.facilityNo)}</Link>; } },
        { header: 'Bank', cell: r => <span dir="ltr">{(r.banks as string[]).join(', ')}</span> },
        { header: 'Colour', cell: r => { const c = r.compliance as Row; return <span className={`badge ${tone(c.colour)}`}>{t(str(c.colour))}</span>; } },
        { header: 'Reasons', cell: r => ((r.compliance as Row).reasons as { code: string; count: number }[]).map(x => `${t(x.code)} (${x.count})`).join(' · ') },
      ]} />
    </section>
  );
}
