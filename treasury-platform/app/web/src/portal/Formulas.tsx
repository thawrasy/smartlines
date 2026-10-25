import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-FIN-03 (the formula library: templates, facility copies and analysis measures with their versions; an editor that
// checks the formula as it is written and previews it on an approved statement; approval by another user; the copy of
// a template to a facility) and the measures computed on an approved statement (FR-FIN-016).

interface FormulaRow {
  id: string; code: string; nameAr: string; nameEn?: string; scope: string; facility?: { id: string; facilityNo: string } | null; baseTemplate?: string; expression: string;
  inputKinds: string[]; resultUnit: string; definitionNote?: string; versionNo: number; status: string; preparedByMe: boolean;
}
interface Check { valid: boolean; errors: { position: number; code: string; message: string }[]; inputKinds: string[]; preview?: { value?: number; undefined?: string } | null }

const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 6 });

export function Formulas() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<FormulaRow[]>([]);
  const [open, setOpen] = useState<FormulaRow | null>(null);
  const [d, setD] = useState({ code: '', nameAr: '', scope: 'TEMPLATE', expression: '', resultUnit: 'RATIO', definitionNote: '' });
  const [check, setCheck] = useState<Check | null>(null);
  const [statement, setStatement] = useState('');
  const [facility, setFacility] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => setRows((await api<{ items: FormulaRow[] }>('GET', '/formulas')).items), []);
  useEffect(() => { void load(); }, [load]);
  const expression = open ? open.expression : d.expression;
  useEffect(() => {
    if (!expression.trim()) { setCheck(null); return; }
    const timer = setTimeout(() => {
      void api<Check>('POST', '/formulas/actions/validate', { expression, statement: statement || undefined }).then(setCheck).catch(() => setCheck(null));
    }, 400);
    return () => clearTimeout(timer);
  }, [expression, statement]);
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Formula library')}</h1>
        <Notice {...notice} />
        <Table rows={rows} columns={[
          { header: 'Code', cell: f => <button className="link" dir="ltr" onClick={() => setOpen(f)}>{f.code}</button> },
          { header: 'Name', cell: f => name(lang, f) },
          { header: 'Scope', cell: f => <>{t(f.scope)} {f.facility && <span dir="ltr">{f.facility.facilityNo}</span>}</> },
          { header: 'Formula', cell: f => <code dir="ltr">{f.expression}</code> },
          { header: 'Unit', cell: f => t(f.resultUnit) },
          { header: 'Version', cell: f => f.versionNo },
          { header: 'Status', cell: f => <Chip s={f.status} /> },
        ]} />
      </section>
      {open && (
        <section className="card">
          <h2 dir="ltr">{open.code} <small className="muted">v{open.versionNo} · {t(open.status)}</small></h2>
          {open.status === 'DRAFT' && can(me, 'fin.formula.manage')
            ? <label><span>{t('Formula')}</span><textarea dir="ltr" rows={3} value={open.expression} onChange={e => setOpen({ ...open, expression: e.target.value })} /></label>
            : <code dir="ltr">{open.expression}</code>}
          {open.definitionNote && <p className="muted">{open.definitionNote}</p>}
          <div className="row">
            {open.status === 'DRAFT' && can(me, 'fin.formula.manage') &&
              <button onClick={() => act(() => api('PATCH', `/formulas/${open.id}`, { expression: open.expression }))}>{t('Save')}</button>}
            {open.status === 'DRAFT' && can(me, 'fin.formula.approve') && !open.preparedByMe &&
              <button onClick={() => act(async () => { await api('POST', `/formulas/${open.id}/actions/approve`, {}); setOpen(null); }, 'Approved.')}>{t('Approve')}</button>}
            {open.status === 'APPROVED' && can(me, 'fin.formula.manage') &&
              <button className="link" onClick={() => act(async () => { await api('POST', `/formulas/${open.id}/actions/new-version`, {}); setOpen(null); })}>{t('New version')}</button>}
            {open.status === 'APPROVED' && open.scope === 'TEMPLATE' && can(me, 'fin.formula.manage') && <>
              <Field label="Facility (id)" value={facility} onChange={setFacility} required={false} />
              <button className="link" onClick={() => act(() => api('POST', `/formulas/${open.id}/actions/copy`, { facility }), 'Copied to the facility.')}>{t('Copy to the facility')}</button>
            </>}
          </div>
        </section>
      )}
      <section className="card">
        <h2>{t('Check and preview')}</h2>
        <Field label="Approved statement (id) for the preview" value={statement} onChange={setStatement} required={false} />
        {check && (check.valid
          ? <p className="ok">{t('The formula is valid.')} {t('Inputs:')} {check.inputKinds.map(k => t(k)).join(' · ')}
            {check.preview && <> — {t('Value on the statement:')} <strong dir="ltr">{check.preview.value != null ? amount(check.preview.value) : check.preview.undefined}</strong></>}</p>
          : <ul className="error">{check.errors.map((e, i) => <li key={i}><span dir="ltr">@{e.position}</span> {t(e.message)}</li>)}</ul>)}
      </section>
      {can(me, 'fin.formula.manage') && <Form title="New formula" submit="Create" onSubmit={async () => {
        await api('POST', '/formulas', d);
        setD({ ...d, code: '', nameAr: '', expression: '' });
        await load();
      }}>
        <Field label="Code" value={d.code} onChange={v => setD({ ...d, code: v.toUpperCase() })} />
        <Field label="Name" value={d.nameAr} onChange={v => setD({ ...d, nameAr: v })} />
        <Select label="Scope" value={d.scope} onChange={v => setD({ ...d, scope: v })} options={['TEMPLATE', 'ANALYSIS'].map(x => ({ value: x, label: x }))} />
        <Field label="Formula" value={d.expression} onChange={v => setD({ ...d, expression: v })} />
        <Select label="Unit" value={d.resultUnit} onChange={v => setD({ ...d, resultUnit: v })}
          options={(d.scope === 'ANALYSIS' ? ['RATIO', 'AMOUNT', 'PERCENT', 'DAYS'] : ['RATIO', 'AMOUNT', 'PERCENT']).map(x => ({ value: x, label: x }))} />
        <Field label="Definition note" value={d.definitionNote} onChange={v => setD({ ...d, definitionNote: v })} required={false} />
      </Form>}
    </>
  );
}

interface Ratio { code: string; nameAr: string; nameEn?: string; scope: string; unit: string; status: string; value?: number; reason?: string }

/** FR-FIN-016: the analysis measures of an approved statement. */
export function StatementRatios({ id, approved }: { id: string; approved: boolean }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Ratio[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => setRows((await api<{ items: Ratio[] }>('GET', `/financial-statements/${id}/ratios`)).items), [id]);
  useEffect(() => { void load(); }, [load]);
  if (!approved && rows.length === 0) return null;
  return (
    <section className="card">
      <h2>{t('Analysis measures')}</h2>
      <Notice {...notice} />
      <Table rows={rows} columns={[
        { header: 'Code', cell: r => <span dir="ltr">{r.code}</span> },
        { header: 'Name', cell: r => name(lang, r) },
        { header: 'Value', cell: r => r.status === 'COMPUTED' ? <span dir="ltr">{amount(r.value)} {r.unit === 'PERCENT' ? '%' : r.unit === 'DAYS' ? t('days') : ''}</span> : <span className="muted">{r.reason}</span> },
      ]} />
      {approved && can(me, 'fin.verify.run') && <button onClick={async () => {
        setNotice({});
        try { await api('POST', `/financial-statements/${id}/ratios/actions/compute`, {}); await load(); setNotice({ ok: 'Computed.' }); } catch (e) { setNotice({ error: message(e) }); }
      }}>{t('Compute the measures')}</button>}
    </section>
  );
}
