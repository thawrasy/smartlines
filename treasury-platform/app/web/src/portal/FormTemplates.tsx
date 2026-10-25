import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-LCT-08 (FR-LCT-025 to 027, BR-LCT-017, 020): the bank form templates and their field maps. A holder of
// lc.template.manage writes a draft, maps its fields and activates it; a change to an active template is a new version.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : String(v);
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

// The transforms the print applies (BR-LCT-020) and the roots a source path starts with.
const TRANSFORMS = ['NONE', 'UPPER', 'DATE_DMY', 'DATE_HIJRI', 'AMOUNT_WORDS_AR', 'AMOUNT_WORDS_EN', 'CHECKBOX_EQ', 'CONCAT_DOCS', 'CHARGES_SUMMARY'];
const SOURCE_HINTS = [
  'terms.amount', 'terms.currency', 'terms.expiryDate', 'terms.latestShipmentDate', 'terms.beneficiaryName', 'terms.incoterm', 'terms.portOfLoading',
  'terms.portOfDischarge', 'terms.partialShipments', 'terms.transhipment', 'terms.documents', 'terms.charges', 'company.nameAr', 'company.nameEn',
  'company.crNumber', 'counterparty.nameEn', 'counterparty.country', 'facility.platformRef', 'facility.bankReferenceNo',
];

interface MapRow { targetName: string; sourceExpr: string; transform: string; transformArg: string; isRequired: boolean; seqNo: string }
const blankMap = (): MapRow => ({ targetName: '', sourceExpr: 'terms.', transform: 'NONE', transformArg: '', isRequired: false, seqNo: '' });

interface NewTemplate {
  code: string; formKind: string; institution: string; product: string; language: string; effectiveFrom: string; effectiveTo: string; annexVersion: string;
  footerTextAr: string; footerTextEn: string;
}

function body(f: NewTemplate) {
  return {
    code: f.code, formKind: f.formKind, institution: f.institution || undefined, product: f.product || undefined, language: f.language || undefined,
    effectiveFrom: f.effectiveFrom, effectiveTo: f.effectiveTo || undefined, annexVersion: f.annexVersion || undefined,
    footerTextAr: f.footerTextAr || undefined, footerTextEn: f.footerTextEn || undefined,
  };
}

function useBanks() {
  const [banks, setBanks] = useState<Row[]>([]);
  useEffect(() => { api<{ items: Row[] }>('GET', '/institutions?status=ACTIVE').then(r => setBanks(r.items)).catch(() => setBanks([])); }, []);
  return banks;
}

export function FormTemplates() {
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const banks = useBanks();
  const manage = can(me, 'lc.template.manage');
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [f, setF] = useState<NewTemplate>({ code: '', formKind: 'LC_APPLICATION', institution: '', product: '', language: '', effectiveFrom: '', effectiveTo: '', annexVersion: '', footerTextAr: '', footerTextEn: '' });
  useEffect(() => { api<{ items: Row[] }>('GET', '/lc-form-templates').then(r => setRows(r.items)).catch(e => setError(message(e))); }, []);
  return (
    <>
      <section className="card">
        <h1>{t('Bank form templates')}</h1>
        <Notice error={error} />
        <Table rows={rows} empty="No bank form template yet." columns={[
          { header: 'Code', cell: r => <Link to={`/lc-form-templates/${str(r.id)}`} dir="ltr">{str(r.code)}</Link> },
          { header: 'Version', cell: r => str(r.version) },
          { header: 'Form', cell: r => t(str(r.formKind)) },
          { header: 'Bank', cell: r => pick(lang, r, 'bankName') || t('Every bank') },
          { header: 'Product', cell: r => str(r.product) },
          { header: 'From', cell: r => <span dir="ltr">{str(r.effectiveFrom).slice(0, 10)}</span> },
          { header: 'To', cell: r => <span dir="ltr">{str(r.effectiveTo).slice(0, 10)}</span> },
          { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
        ]} />
      </section>
      {manage && (
        <Form title="New template" submit="Create the draft" onSubmit={async () => {
          const r = await api<{ id: string }>('POST', '/lc-form-templates', body(f));
          nav(`/lc-form-templates/${r.id}`);
        }}>
          <Field label="Code" value={f.code} onChange={v => setF({ ...f, code: v })} hint="Latin letters and digits; the versions of one form share it." />
          <Select label="Form" value={f.formKind} onChange={v => setF({ ...f, formKind: v })}
            options={['LC_APPLICATION', 'LC_AMENDMENT'].map(k => ({ value: k, label: t(k) }))} />
          <Select label="Bank" value={f.institution} onChange={v => setF({ ...f, institution: v })}
            options={[{ value: '', label: t('Every bank') }, ...banks.map(b => ({ value: str(b.id), label: pick(lang, b, 'name') || str(b.code) }))]} />
          <Field label="Product code (empty: every product)" value={f.product} onChange={v => setF({ ...f, product: v })} required={false} />
          <Select label="Language" value={f.language} onChange={v => setF({ ...f, language: v })}
            options={[{ value: '', label: '—' }, { value: 'ar', label: 'العربية' }, { value: 'en', label: 'English' }, { value: 'bi', label: t('Both') }]} />
          <Field label="In force from" type="date" value={f.effectiveFrom} onChange={v => setF({ ...f, effectiveFrom: v })} />
          <Field label="In force until (optional)" type="date" value={f.effectiveTo} onChange={v => setF({ ...f, effectiveTo: v })} required={false} />
          <Field label="Bank's form version" value={f.annexVersion} onChange={v => setF({ ...f, annexVersion: v })} required={false} />
          <Field label="Footer (Arabic)" value={f.footerTextAr} onChange={v => setF({ ...f, footerTextAr: v })} required={false} />
          <Field label="Footer (English)" value={f.footerTextEn} onChange={v => setF({ ...f, footerTextEn: v })} required={false} />
        </Form>
      )}
    </>
  );
}

export function FormTemplateDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const nav = useNavigate();
  const manage = can(me, 'lc.template.manage');
  const [data, setData] = useState<{ template: Row; maps: Row[] } | null>(null);
  const [maps, setMaps] = useState<MapRow[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    try {
      const r = await api<{ template: Row; maps: Row[] }>('GET', `/lc-form-templates/${id}`);
      setData(r);
      setMaps(r.maps.map(m => ({
        targetName: str(m.targetName), sourceExpr: str(m.sourceExpr), transform: str(m.transform) || 'NONE', transformArg: str(m.transformArg),
        isRequired: Boolean(m.isRequired), seqNo: str(m.seqNo),
      })));
    } catch (e) { setNotice({ error: message(e) }); }
  }, [id]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return <section className="card"><h1>{t('Bank form templates')}</h1><Notice error={notice.error} /></section>;
  const h = data.template;
  const draft = str(h.status) === 'DRAFT';
  const editable = manage && draft;
  const set = (i: number, patch: Partial<MapRow>) => setMaps(maps.map((m, j) => (j === i ? { ...m, ...patch } : m)));
  const saveMaps = async () => {
    setNotice({});
    try {
      await api('PUT', `/lc-form-templates/${id}/field-maps`, maps.filter(m => m.targetName.trim()).map(m => ({
        targetName: m.targetName.trim(), sourceExpr: m.sourceExpr.trim(), transform: m.transform, transformArg: m.transformArg || undefined,
        isRequired: m.isRequired, seqNo: m.seqNo ? Number(m.seqNo) : undefined,
      })));
      setNotice({ ok: 'The field maps are saved.' });
      await load();
    } catch (e) { setNotice({ error: message(e) }); }
  };
  // A new version: a draft with the same code and settings and a copy of these maps, to change and activate.
  const newVersion = async () => {
    setNotice({});
    try {
      const today = new Date().toISOString().slice(0, 10);
      const r = await api<{ id: string }>('POST', '/lc-form-templates', {
        code: str(h.code), formKind: str(h.formKind), institution: h.institution ? str(h.institution) : undefined, product: h.product ? str(h.product) : undefined,
        scope: h.scope ? str(h.scope) : undefined, channel: h.channel ? str(h.channel) : undefined, language: h.language ? str(h.language) : undefined,
        effectiveFrom: today, annexVersion: h.annexVersion ? str(h.annexVersion) : undefined,
        footerTextAr: h.footerTextAr ? str(h.footerTextAr) : undefined, footerTextEn: h.footerTextEn ? str(h.footerTextEn) : undefined,
      });
      if (data.maps.length) await api('PUT', `/lc-form-templates/${r.id}/field-maps`, data.maps);
      nav(`/lc-form-templates/${r.id}`);
    } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1><span dir="ltr">{str(h.code)}</span> · {t('Version')} {str(h.version)}</h1>
        <p>{t(str(h.formKind))} · {pick(lang, h, 'bankName') || t('Every bank')} · {t(str(h.status))} · {t('Legal review')}: {t(str(h.legalReview))}</p>
        <p className="muted" dir="ltr">{str(h.effectiveFrom).slice(0, 10)} → {str(h.effectiveTo).slice(0, 10) || '…'}</p>
        <Notice ok={notice.ok} error={notice.error} />
        {manage && (
          <div className="actions">
            {draft && <button onClick={async () => {
              setNotice({});
              try { await api('POST', `/lc-form-templates/${id}/activate`, {}); setNotice({ ok: 'The template is active; the version before it is retired.' }); await load(); }
              catch (e) { setNotice({ error: message(e) }); }
            }}>{t('Activate')}</button>}
            {!draft && <button className="secondary" onClick={() => void newVersion()}>{t('New version')}</button>}
          </div>
        )}
      </section>
      <section className="card">
        <h2>{t('Field maps')}</h2>
        {!editable && (
          <Table rows={data.maps} empty="No field map." columns={[
            { header: 'Target', cell: r => str(r.targetName) },
            { header: 'Source', cell: r => <code dir="ltr">{str(r.sourceExpr)}</code> },
            { header: 'Transform', cell: r => <span dir="ltr">{str(r.transform)}{r.transformArg ? ` (${str(r.transformArg)})` : ''}</span> },
            { header: 'Required', cell: r => r.isRequired ? t('Yes') : '' },
          ]} />
        )}
        {editable && (
          <>
            <p className="muted">{t('Each field of the bank form takes its value from a path of the request: terms., company., counterparty. or facility.')}</p>
            <datalist id="source-hints">{SOURCE_HINTS.map(s => <option key={s} value={s} />)}</datalist>
            <table>
              <thead><tr>
                <th>{t('Order')}</th><th>{t('Field of the form')}</th><th>{t('Source')}</th><th>{t('Transform')}</th><th>{t('Value')}</th><th>{t('Required')}</th><th />
              </tr></thead>
              <tbody>
                {maps.map((m, i) => (
                  <tr key={i}>
                    <td><input aria-label={t('Order')} type="number" value={m.seqNo} onChange={e => set(i, { seqNo: e.target.value })} style={{ width: '4em' }} /></td>
                    <td><input aria-label={t('Field of the form')} value={m.targetName} onChange={e => set(i, { targetName: e.target.value })} /></td>
                    <td><input aria-label={t('Source')} dir="ltr" list="source-hints" value={m.sourceExpr} onChange={e => set(i, { sourceExpr: e.target.value })} /></td>
                    <td>
                      <select aria-label={t('Transform')} value={m.transform} onChange={e => set(i, { transform: e.target.value })}>
                        {TRANSFORMS.map(x => <option key={x} value={x}>{t(x)}</option>)}
                      </select>
                    </td>
                    <td><input aria-label={t('Value')} value={m.transformArg} disabled={m.transform !== 'CHECKBOX_EQ'} onChange={e => set(i, { transformArg: e.target.value })} /></td>
                    <td><input aria-label={t('Required')} type="checkbox" checked={m.isRequired} onChange={e => set(i, { isRequired: e.target.checked })} /></td>
                    <td><button className="link" onClick={() => setMaps(maps.filter((_, j) => j !== i))}>{t('Remove')}</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="actions">
              <button className="secondary" onClick={() => setMaps([...maps, blankMap()])}>{t('Add a field')}</button>
              <button onClick={() => void saveMaps()}>{t('Save the field maps')}</button>
            </div>
          </>
        )}
        <p><Link to="/lc-form-templates">{t('Bank form templates')}</Link></p>
      </section>
    </>
  );
}
