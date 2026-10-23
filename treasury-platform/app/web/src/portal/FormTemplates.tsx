import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Notice, Table } from '../ui';

// SCR-LCT-08 (FR-LCT-025, BR-LCT-017, 020): the bank form templates and their field maps, read-only. A template is
// written and activated through the API by a holder of lc.template.manage; a change is a new version.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : String(v);
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

export function FormTemplates() {
  const { t, lang } = useI18n();
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api<{ items: Row[] }>('GET', '/lc-form-templates').then(r => setRows(r.items)).catch(e => setError(message(e))); }, []);
  return (
    <section className="card">
      <h1>{t('Bank form templates')}</h1>
      <Notice error={error} />
      <Table rows={rows} empty="No bank form template yet." columns={[
        { header: 'Code', cell: r => <Link to={`/lc-form-templates/${str(r.id)}`} dir="ltr">{str(r.code)}</Link> },
        { header: 'Version', cell: r => str(r.version) },
        { header: 'Form', cell: r => t(str(r.formKind)) },
        { header: 'Bank', cell: r => pick(lang, r, 'bankName') },
        { header: 'Product', cell: r => str(r.product) },
        { header: 'From', cell: r => <span dir="ltr">{str(r.effectiveFrom).slice(0, 10)}</span> },
        { header: 'To', cell: r => <span dir="ltr">{str(r.effectiveTo).slice(0, 10)}</span> },
        { header: 'Status', cell: r => t(str(r.status)) },
      ]} />
    </section>
  );
}

export function FormTemplateDetail() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const [data, setData] = useState<{ template: Row; maps: Row[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api<{ template: Row; maps: Row[] }>('GET', `/lc-form-templates/${id}`).then(setData).catch(e => setError(message(e))); }, [id]);
  if (!data) return <section className="card"><h1>{t('Bank form templates')}</h1><Notice error={error} /></section>;
  const h = data.template;
  return (
    <section className="card">
      <h1><span dir="ltr">{str(h.code)}</span> · {t('Version')} {str(h.version)}</h1>
      <p>{t(str(h.formKind))} · {pick(lang, h, 'bankName')} · {t(str(h.status))} · {t('Legal review')}: {t(str(h.legalReview))}</p>
      <h2>{t('Field maps')}</h2>
      <Table rows={data.maps} empty="No field map." columns={[
        { header: 'Target', cell: r => str(r.targetName) },
        { header: 'Source', cell: r => <code dir="ltr">{str(r.sourceExpr)}</code> },
        { header: 'Transform', cell: r => <span dir="ltr">{str(r.transform)}{r.transformArg ? ` (${str(r.transformArg)})` : ''}</span> },
        { header: 'Required', cell: r => r.isRequired ? t('Yes') : '' },
      ]} />
      <p><Link to="/lc-form-templates">{t('Bank form templates')}</Link></p>
    </section>
  );
}
