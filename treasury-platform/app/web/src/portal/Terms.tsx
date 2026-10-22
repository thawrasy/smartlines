import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-CMP-01: the comparable terms of a facility (projected on approval from the typed fields, or entered for the
// keys that are not projected) and the comparison of one key across facilities, where a value the agreement does not
// specify keeps its state and stays out of the ranking.

interface Term {
  id: string; facility: string; facilityNo: string; key: string; nameAr: string; nameEn?: string; otherLabel?: string; limit?: string; valueState: string;
  value?: number | string | boolean | null; unit: string; bound: string; origin: string; effectiveFrom: string; effectiveTo?: string; confidence: string;
}
interface TermType { code: string; nameAr: string; nameEn?: string; category: string; valueKind: string; unit: string; direction: string; isActive: boolean; projected: boolean }

const show = (t: (s: string) => string, x: Term) =>
  x.valueState !== 'SPECIFIED' ? <span className="warn">{t(x.valueState)}</span> : <span dir="ltr">{typeof x.value === 'boolean' ? (x.value ? '✔' : '—') : String(x.value)} {x.unit}</span>;

/** The terms tab of the facility card. */
export function FacilityTerms({ id, draft, edit }: { id: string; draft: boolean; edit: boolean }) {
  const { t, lang } = useI18n();
  const [view, setView] = useState<'approved' | 'draft'>('approved');
  const [rows, setRows] = useState<Term[]>([]);
  const [types, setTypes] = useState<TermType[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [d, setD] = useState({ termType: '', valueState: 'SPECIFIED', value: '', otherLabel: '', noSourceReason: '' });
  const load = useCallback(async () => setRows((await api<{ items: Term[] }>('GET', `/facilities/${id}/terms${view === 'draft' ? '?view=draft' : ''}`)).items), [id, view]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (!draft) setView('approved'); }, [draft]);
  useEffect(() => { void api<{ items: TermType[] }>('GET', '/term-types').then(r => setTypes(r.items.filter(x => x.isActive && !x.projected))).catch(() => setTypes([])); }, []);
  const type = types.find(x => x.code === d.termType);
  return (
    <>
      <section className="card">
        <h2>{t('Comparable terms')}</h2>
        {draft && <div className="row">
          <button className={view === 'approved' ? '' : 'link'} onClick={() => setView('approved')}>{t('Approved')}</button>
          <button className={view === 'draft' ? '' : 'link'} onClick={() => setView('draft')}>{t('Draft')}</button>
        </div>}
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Key', cell: x => <>{lang === 'ar' ? x.nameAr : x.nameEn ?? x.nameAr}{x.otherLabel && ` (${x.otherLabel})`} <small className="muted" dir="ltr">{x.key}</small></> },
          { header: 'Limit', cell: x => <span dir="ltr">{x.limit}</span> },
          { header: 'Value', cell: x => show(t, x) },
          { header: 'Origin', cell: x => t(x.origin) },
          { header: 'Effective', cell: x => <span dir="ltr">{x.effectiveFrom}{x.effectiveTo && ` → ${x.effectiveTo}`}</span> },
          { header: '', cell: x => view === 'draft' && edit && x.origin === 'ENTERED' ? <button className="link" onClick={async () => {
            setNotice({});
            try { await api('DELETE', `/facilities/${id}/terms/${x.id}`); await load(); } catch (e) { setNotice({ error: message(e) }); }
          }}>{t('Remove')}</button> : null },
        ]} />
      </section>
      {draft && edit && view === 'draft' && <Form title="Enter a term" submit="Add" onSubmit={async () => {
        const kind = type?.valueKind ?? 'TEXT';
        const specified = d.valueState === 'SPECIFIED';
        await api('POST', `/facilities/${id}/terms`, {
          termType: d.termType, valueState: d.valueState, otherLabel: d.otherLabel || undefined, noSourceReason: d.noSourceReason,
          valueNumber: specified && ['PERCENT', 'AMOUNT', 'DAYS', 'MONTHS', 'COUNT'].includes(kind) ? Number(d.value) : undefined,
          valueText: specified && kind === 'TEXT' ? d.value : undefined, valueBool: specified && kind === 'BOOLEAN' ? d.value === 'true' : undefined,
          valueEnum: specified && kind === 'ENUM' ? d.value : undefined,
        });
        setD({ ...d, value: '' });
        await load();
      }}>
        <Select label="Key" value={d.termType} onChange={v => setD({ ...d, termType: v })} options={[{ value: '', label: '' }, ...types.map(x => ({ value: x.code, label: `${x.code} ${lang === 'ar' ? x.nameAr : x.nameEn ?? x.nameAr}` }))]} />
        <Select label="State" value={d.valueState} onChange={v => setD({ ...d, valueState: v })}
          options={['SPECIFIED', 'NOT_SPECIFIED_IN_AGREEMENT', 'NOT_APPLICABLE', 'UNKNOWN'].map(x => ({ value: x, label: x }))} />
        {d.valueState === 'SPECIFIED' && <Field label="Value" value={d.value} onChange={v => setD({ ...d, value: v })} />}
        {d.termType === 'OTHER' && <Field label="Label" value={d.otherLabel} onChange={v => setD({ ...d, otherLabel: v })} />}
        <Field label="Source (or why there is none)" value={d.noSourceReason} onChange={v => setD({ ...d, noSourceReason: v })} />
      </Form>}
    </>
  );
}

/** The comparison of one key across facilities (FR-CMP-008). */
export function TermCompare() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [types, setTypes] = useState<TermType[]>([]);
  const [key, setKey] = useState('');
  const [asOf, setAsOf] = useState('');
  const [r, setR] = useState<{ direction: string; best?: Term | null; average?: number | null; ranked: { rank: number; term: Term }[]; unranked: Term[] } | null>(null);
  const [error, setError] = useState<string | undefined>();
  useEffect(() => { void api<{ items: TermType[] }>('GET', '/term-types').then(x => setTypes(x.items)).catch(() => setTypes([])); }, []);
  useEffect(() => {
    if (!key) return;
    void api<typeof r>('GET', `/terms/compare?key=${encodeURIComponent(key)}${asOf ? '&asOf=' + asOf : ''}`).then(setR).catch(e => setError(message(e)));
  }, [key, asOf]);
  return (
    <section className="card">
      <h1>{t('Compare terms')}</h1>
      <Notice error={error} />
      <div className="row">
        <Select label="Key" value={key} onChange={setKey} options={[{ value: '', label: '' }, ...types.filter(x => x.isActive).map(x => ({ value: x.code, label: `${x.code} ${lang === 'ar' ? x.nameAr : x.nameEn ?? x.nameAr}` }))]} />
        <Field label="As of" value={asOf} onChange={setAsOf} type="date" required={false} />
      </div>
      {r && <>
        <p>{t(({ LOWER_BETTER: 'Lower is better', HIGHER_BETTER: 'Higher is better' } as Record<string, string>)[r.direction] ?? 'Not ranked')}{r.best && <> · {t('Best')}: <Link to={`/facilities/${r.best.facility}`} dir="ltr">{r.best.facilityNo}</Link> {show(t, r.best)}</>}
          {r.average != null && <> · {t('Average')}: <span dir="ltr">{r.average}</span></>}</p>
        <Table rows={r.ranked} columns={[
          { header: 'Rank', cell: x => x.rank },
          { header: 'Facility', cell: x => <Link to={`/facilities/${x.term.facility}`} dir="ltr">{x.term.facilityNo}</Link> },
          { header: 'Value', cell: x => show(t, x.term) },
          { header: 'Limit', cell: x => <span dir="ltr">{x.term.limit}</span> },
        ]} />
        {r.unranked.length > 0 && <><h3>{t('Outside the ranking')}</h3>
          <Table rows={r.unranked} columns={[
            { header: 'Facility', cell: x => <Link to={`/facilities/${x.facility}`} dir="ltr">{x.facilityNo}</Link> },
            { header: 'Value', cell: x => show(t, x) },
          ]} /></>}
      </>}
      {can(me, 'cmp.manage') && types.some(x => !x.isActive) && <><h3>{t('Proposed keys')}</h3>
        <Table rows={types.filter(x => !x.isActive)} columns={[
          { header: 'Key', cell: x => <><span dir="ltr">{x.code}</span> {lang === 'ar' ? x.nameAr : x.nameEn ?? x.nameAr}</> },
          { header: '', cell: x => <button className="link" onClick={() => void api('POST', `/term-types/${x.code}/actions/promote`, {})
            .then(() => api<{ items: TermType[] }>('GET', '/term-types')).then(y => setTypes(y.items)).catch(e => setError(message(e)))}>{t('Promote')}</button> },
        ]} /></>}
    </section>
  );
}
