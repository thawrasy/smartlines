import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-LCI-13 and 14 (spec 14 section 7): the register of purchase letters of credit with its search, and the card of a
// credit with its presentations, their decision and payment, its amendments and the manual close. The facility,
// margin and utilisation show only to holders of lc.view.internal (the server leaves them out otherwise).

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 10);
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);
const today = () => new Date().toISOString().slice(0, 10);

export function LcRegister() {
  const { t, lang } = useI18n();
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const [rows, setRows] = useState<Row[]>([]);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const p = new URLSearchParams();
    if (q) p.set('q', q);
    if (status) p.set('status', status);
    api<{ items: Row[] }>('GET', `/lcs?${p.toString()}`).then(r => setRows(r.items)).catch(e => setError(message(e)));
  }, [q, status]);
  return (
    <section className="card">
      <h1>{t('Letters of credit')}</h1>
      <Notice error={error} />
      <div className="row">
        <Field label="Search" value={q} onChange={setQ} required={false} />
        <Select label="Status" value={status} onChange={setStatus} options={[
          { value: '', label: t('All') }, { value: 'ACTIVE', label: t('ACTIVE') }, { value: 'EXPIRED', label: t('EXPIRED') }, { value: 'CLOSED', label: t('CLOSED') },
        ]} />
      </div>
      <Table rows={rows} empty="No letter of credit here." columns={[
        { header: 'Number', cell: r => <Link to={`/lcs/${str(r.id)}`} dir="ltr">{str(r.lcNumber)}</Link> },
        { header: 'Request', cell: r => r.requestId ? <Link to={`/requests/${str(r.requestId)}`} dir="ltr">{str(r.requestNo)}</Link> : '' },
        { header: 'Counterparty', cell: r => pick(lang, r, 'counterpartyName') },
        { header: 'Company', cell: r => pick(lang, r, 'companyName') },
        { header: 'Bank', cell: r => pick(lang, r, 'bankName') },
        { header: 'Amount', cell: r => <span dir="ltr">{str(r.amount)} {str(r.currency)}</span> },
        { header: 'Drawn', cell: r => <span dir="ltr">{str(r.drawn)}</span> },
        { header: 'Expiry', cell: r => <span dir="ltr">{day(r.expiryDate)}</span> },
        { header: 'Status', cell: r => t(str(r.status)) },
      ]} />
    </section>
  );
}

export function LcCard() {
  const { id } = useParams();
  const { t, lang } = useI18n();
  const me = useMe();
  const [data, setData] = useState<{ lc: Row; drawings: Row[]; amendments: Row[] } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const [amount, setAmount] = useState('');
  const [presented, setPresented] = useState(today());
  const [advice, setAdvice] = useState('');
  const [basis, setBasis] = useState('');
  const [pay, setPay] = useState<Record<string, string>>({});
  const [reason, setReason] = useState('');
  const load = useCallback(async () => setData(await api('GET', `/lcs/${id}`)), [id]);
  useEffect(() => { void load().catch(e => setError(message(e))); }, [load]);
  const run = async (fn: () => Promise<unknown>, done: string) => {
    setError(null); setOk(null);
    try { await fn(); setOk(t(done)); await load(); } catch (e) { setError(message(e)); }
  };
  if (!data) return <section className="card"><Notice error={error} /></section>;
  const lc = data.lc;
  const active = ['ACTIVE', 'EXPIRED'].includes(str(lc.status));
  const drawer = can(me, 'lc.drawing.record');
  return (
    <section className="card">
      <h1 dir="ltr">{str(lc.lcNumber)} <small>{t(str(lc.status))}</small></h1>
      <Notice error={error} ok={ok} />
      <dl className="facts">
        <dt>{t('Counterparty')}</dt><dd>{pick(lang, lc, 'counterpartyName')}</dd>
        <dt>{t('Company')}</dt><dd>{pick(lang, lc, 'companyName')}</dd>
        <dt>{t('Bank')}</dt><dd>{pick(lang, lc, 'bankName')}</dd>
        <dt>{t('Request')}</dt><dd>{lc.requestId ? <Link to={`/requests/${str(lc.requestId)}`} dir="ltr">{str(lc.requestNo)}</Link> : ''}</dd>
        <dt>{t('Amount')}</dt><dd dir="ltr">{str(lc.amount)} {str(lc.currency)}</dd>
        <dt>{t('Exposure')}</dt><dd dir="ltr">{str(lc.exposureAmount)}</dd>
        <dt>{t('Drawn')}</dt><dd dir="ltr">{str(lc.drawn)}</dd>
        <dt>{t('Settled')}</dt><dd dir="ltr">{str(lc.settled)}</dd>
        <dt>{t('Issued on')}</dt><dd dir="ltr">{day(lc.issueDate)}</dd>
        <dt>{t('Expiry')}</dt><dd dir="ltr">{day(lc.expiryDate)}</dd>
        {'utilized' in lc && <><dt>{t('Utilised on the facility')}</dt><dd dir="ltr">{str(lc.utilized)} · {str(lc.facilityNo)}</dd></>}
      </dl>
      <h2>{t('Presentations')}</h2>
      <Table rows={data.drawings} empty="No presentation yet." columns={[
        { header: 'No.', cell: r => str(r.drawingNo) },
        { header: 'Amount', cell: r => <span dir="ltr">{str(r.amount)}</span> },
        { header: 'Presented', cell: r => <span dir="ltr">{day(r.presentationDate)}</span> },
        { header: 'Examination by', cell: r => <span dir="ltr">{day(r.examinationDeadline)}</span> },
        { header: 'Maturity', cell: r => <span dir="ltr">{day(r.maturityDate)}</span> },
        { header: 'Paid', cell: r => <span dir="ltr">{str(r.settled)}</span> },
        { header: 'Status', cell: r => t(str(r.status)) },
        { header: '', cell: r => !drawer ? null : ['PRESENTED', 'DISCREPANT'].includes(str(r.status)) ? (
          <span>
            <button type="button" onClick={() => void run(() => api('POST', `/lcs/${id}/drawings/${str(r.drawingNo)}/decision`, { status: 'ACCEPTED' }), 'Saved.')}>{t('Accepted')}</button>{' '}
            <button type="button" onClick={() => void run(() => api('POST', `/lcs/${id}/drawings/${str(r.drawingNo)}/decision`, { status: 'DISCREPANT' }), 'Saved.')}>{t('Discrepant')}</button>{' '}
            <button type="button" onClick={() => void run(() => api('POST', `/lcs/${id}/drawings/${str(r.drawingNo)}/decision`, { status: 'REFUSED' }), 'Saved.')}>{t('Refused')}</button>
          </span>
        ) : str(r.status) === 'ACCEPTED' ? (
          <span>
            <input dir="ltr" inputMode="decimal" aria-label={t('Payment')} value={pay[str(r.drawingNo)] ?? ''} onChange={e => setPay({ ...pay, [str(r.drawingNo)]: e.target.value })} />{' '}
            <button type="button" onClick={() => void run(() => api('POST', `/lcs/${id}/drawings/${str(r.drawingNo)}/settlements`,
              { amount: Number(pay[str(r.drawingNo)]), settledOn: today() }), 'Saved.')}>{t('Record the payment')}</button>
          </span>
        ) : null },
      ]} />
      {drawer && active && (
        <Form title="New presentation" submit="Record" onSubmit={() => run(() => api('POST', `/lcs/${id}/drawings`,
          { amount: Number(amount), presentationDate: presented, bankAdviceRef: advice || null, maturityBasisDate: basis || null }), 'The presentation is recorded.')}>
          <Field label="Amount" value={amount} onChange={setAmount} />
          <Field label="Presented on" type="date" value={presented} onChange={setPresented} />
          <Field label="Bank advice" value={advice} onChange={setAdvice} required={false} />
          {str(lc.lcType) !== 'SIGHT' && <Field label="Tenor runs from" type="date" value={basis} onChange={setBasis} required={false} />}
        </Form>
      )}
      <h2>{t('Amendments')}</h2>
      <Table rows={data.amendments} empty="No amendment." columns={[
        { header: 'No.', cell: r => str(r.amendmentNo) },
        { header: 'Changes', cell: r => str(r.changeKinds) },
        { header: 'Amount change', cell: r => <span dir="ltr">{str(r.amountDelta)}</span> },
        { header: 'New expiry', cell: r => <span dir="ltr">{day(r.newExpiryDate)}</span> },
        { header: 'Status', cell: r => t(str(r.status)) },
      ]} />
      {can(me, 'lc.close') && active && (
        <Form title="Close the letter of credit" submit="Close" onSubmit={() => run(() => api('POST', `/lcs/${id}/close`, { reason }), 'The letter of credit is closed.')}>
          <Field label="Reason" value={reason} onChange={setReason} />
        </Form>
      )}
    </section>
  );
}
