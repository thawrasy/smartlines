import { useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Notice, Select, Table } from '../ui';

// The letter of credit reports (spec 14 section 10; S5): the catalogue the server allows this user, a report's filters,
// its rows (up to 1,000 on the screen) and the CSV export, which the server audits.

type Row = Record<string, unknown>;
type Def = { code: string; titleEn: string; titleAr: string; columns: string[]; defaultDays: number | null };
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 })
  : typeof v === 'boolean' ? (v ? '✓' : '') : /^\d{4}-\d{2}-\d{2}T00:00:00/.test(String(v)) ? String(v).slice(0, 10) : String(v);

export function Reports() {
  const { t, lang } = useI18n();
  const [defs, setDefs] = useState<Def[]>([]);
  const [code, setCode] = useState('');
  const [companies, setCompanies] = useState<Row[]>([]);
  const [f, setF] = useState({ company: '', from: '', to: '', days: '', status: '' });
  const [data, setData] = useState<{ items: Row[]; truncated: boolean; asOf: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    api<{ items: Def[] }>('GET', '/reports').then(r => { setDefs(r.items); const first = r.items[0]; if (first) setCode(first.code); }).catch(e => setError(message(e)));
    api<{ items: Row[] }>('GET', '/companies').then(r => setCompanies(r.items)).catch(() => setCompanies([]));
  }, []);
  const def = defs.find(d => d.code === code);
  const query = () => {
    const p = new URLSearchParams();
    for (const [k, v] of Object.entries(f)) if (v) p.set(k, v);
    return p.toString();
  };
  useEffect(() => {
    if (!code) return;
    setError(null);
    api<{ items: Row[]; truncated: boolean; asOf: string }>('GET', `/reports/${code}?${query()}`).then(setData).catch(e => { setData(null); setError(message(e)); });
  }, [code, f]);
  if (defs.length === 0) return <section className="card"><h1>{t('Reports')}</h1><Notice error={error} /><p>{t('No report is open to you.')}</p></section>;
  return (
    <section className="card">
      <h1>{t('Reports')}</h1>
      <Notice error={error} />
      <div className="row">
        <Select label="Report" value={code} onChange={setCode} options={defs.map(d => ({ value: d.code, label: `${d.code} · ${lang === 'ar' ? d.titleAr : d.titleEn}` }))} />
        <Select label="Company" value={f.company} onChange={v => setF({ ...f, company: v })}
          options={[{ value: '', label: t('All') }, ...companies.map(c => ({ value: String(c.id), label: String(lang === 'ar' ? c.nameAr ?? c.nameEn : c.nameEn ?? c.nameAr) }))]} />
        <Field label="From" type="date" value={f.from} onChange={v => setF({ ...f, from: v })} required={false} />
        <Field label="To" type="date" value={f.to} onChange={v => setF({ ...f, to: v })} required={false} />
        {def?.defaultDays != null && <Field label="Days" type="number" value={f.days} onChange={v => setF({ ...f, days: v })} required={false} hint={`${t('Default')}: ${def.defaultDays}`} />}
        <Field label="Status" value={f.status} onChange={v => setF({ ...f, status: v })} required={false} />
      </div>
      <p>
        <a href={`/api/v1/reports/${code}/export?${query()}`} download>{t('Export as CSV')}</a>
        {data && <> · {t('As of')} <span dir="ltr">{str(data.asOf).slice(0, 10)}</span> · {data.items.length} {t('rows')}</>}
        {data?.truncated && <> · <span className="warn">{t('The screen shows the first 1,000 rows; the export has them all.')}</span></>}
      </p>
      {def && data && (
        <Table rows={data.items} empty="Nothing here yet." columns={def.columns.map(c => ({ header: c, cell: (r: Row) => <span dir={typeof r[c] === 'number' ? 'ltr' : undefined}>{/^[A-Z_]+$/.test(str(r[c])) ? t(str(r[c])) : str(r[c])}</span> }))} />
      )}
    </section>
  );
}
