import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-FIN-02 (the monthly balances of the accounts by month, a red dot where an expected month has no figure, the
// source of each cell; the flows routed to the banks with their totals for the year; how each flow covenant stands;
// the close of a company's periods). A figure is entered as a draft and confirmed as entered by another user.

interface Named { id: string; code?: string; nameAr?: string; nameEn?: string }
interface Cell {
  month: string; expected: boolean; missing: boolean; id?: string; avgDailyBalance?: number; minBalance?: number; endBalance?: number; sourceKind?: string; status?: string;
  enteredByMe: boolean; reopenReason?: string;
}
interface AccountGrid { id: string; company: Named; bank: string; accountNumber: string; nickname?: string; currency: string; status: string; cells: Cell[] }
interface Flow {
  id: string; company: Named; institution: { id: string; code: string }; facility?: { id: string; facilityNo: string } | null; month: string; kind: string; amount: number;
  currency: string; basisNote?: string; status: string; enteredByMe: boolean; reopenReason?: string;
}
interface Performance {
  facilityNo: string; companyNameAr: string; measureKind: string; windowStart: string; windowEnd: string; currency: string; thresholdValue: number; achieved: number;
  awaitingConfirmation: number; remaining?: number; requiredPerRemainingMonth?: number; achievementPct?: number; state: string;
}

const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 2 });

export function MonthlyFigures() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [companies, setCompanies] = useState<Named[]>([]);
  const [company, setCompany] = useState('');
  const [grid, setGrid] = useState<{ months: string[]; accounts: AccountGrid[] } | null>(null);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [picked, setPicked] = useState<string[]>([]);
  const [reason, setReason] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    if (!company) return;
    setGrid(await api('GET', `/account-stats?company=${company}`));
    setEdits({});
    setPicked([]);
  }, [company]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/companies').then(r => { setCompanies(r.items); setCompany(c => c || r.items[0]?.id || ''); }); }, []);
  useEffect(() => { void load(); }, [load]);
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { const r = await fn() as { warnings?: string[] } | undefined; await load(); setNotice({ ok: r?.warnings?.length ? `${t(ok)} ${r.warnings.join(' · ')}` : ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Monthly balances')}</h1>
        <Select label="Company" value={company} onChange={setCompany} options={companies.map(c => ({ value: c.id, label: name(lang, c) }))} />
        <Notice {...notice} />
        {grid && <div className="scroll"><table>
          <thead><tr><th>{t('Account')}</th>{grid.months.map(m => <th key={m} dir="ltr">{m.slice(0, 7)}</th>)}</tr></thead>
          <tbody>{grid.accounts.map(a => (
            <tr key={a.id}>
              <td><span dir="ltr">{a.bank} {a.accountNumber}</span> <small className="muted">{a.currency} {a.nickname}</small></td>
              {a.cells.map(c => {
                const key = `${a.id}|${c.month}`;
                const editable = can(me, 'fin.stats.enter') && c.status !== 'CONFIRMED' && (c.expected || c.id);
                return (
                  <td key={c.month} className={c.missing ? 'error' : c.status === 'CONFIRMED' ? 'ok' : ''} title={[c.sourceKind && t(c.sourceKind), c.reopenReason].filter(Boolean).join(' · ')}>
                    {c.missing && <span aria-label={t('Missing')}>● </span>}
                    {editable
                      ? <input type="number" step="any" dir="ltr" aria-label={key} value={edits[key] ?? (c.avgDailyBalance == null ? '' : String(c.avgDailyBalance))}
                          onChange={e => setEdits({ ...edits, [key]: e.target.value })} />
                      : <span dir="ltr">{amount(c.avgDailyBalance)}</span>}
                    {c.id && c.status === 'DRAFT' && can(me, 'fin.stats.confirm') && !c.enteredByMe &&
                      <input type="checkbox" aria-label={`${t('Confirm')} ${key}`} checked={picked.includes(c.id)} onChange={e => setPicked(e.target.checked ? [...picked, c.id!] : picked.filter(x => x !== c.id))} />}
                    {c.id && c.status === 'CONFIRMED' && can(me, 'fin.stats.confirm') && !c.enteredByMe &&
                      <button className="link" onClick={() => act(() => api('POST', `/account-stats/${c.id}/actions/reopen`, { reason }), 'Reopened.')}>{t('Reopen')}</button>}
                  </td>
                );
              })}
            </tr>))}</tbody>
        </table></div>}
        <div className="row">
          {can(me, 'fin.stats.enter') && <button onClick={() => act(() => api('PUT', '/account-stats', {
            items: Object.entries(edits).filter(([, v]) => v !== '').map(([k, v]) => { const [account, month] = k.split('|'); return { account, month, avgDailyBalance: Number(v), sourceKind: 'BANK_STATEMENT' }; }),
          }))}>{t('Save')}</button>}
          {picked.length > 0 && <button onClick={() => act(() => api('POST', '/account-stats/actions/confirm', { ids: picked }), 'Confirmed.')}>{t('Confirm the selected figures')}</button>}
          {can(me, 'fin.stats.confirm') && <Field label="Reason for reopening" value={reason} onChange={setReason} required={false} />}
        </div>
      </section>
      {company && <BankFlows company={company} />}
      {company && <PeriodClose company={company} />}
    </>
  );
}

function BankFlows({ company }: { company: string }) {
  const { t } = useI18n();
  const me = useMe();
  const [year, setYear] = useState(String(new Date().getFullYear()));
  const [data, setData] = useState<{ items: Flow[]; totals: { bank: string; currency: string; confirmed: number; awaitingConfirmation: number }[] } | null>(null);
  const [perf, setPerf] = useState<Performance[]>([]);
  const [banks, setBanks] = useState<Named[]>([]);
  const [picked, setPicked] = useState<string[]>([]);
  const [reason, setReason] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [d, setD] = useState({ institution: '', month: '', amount: '', currency: 'SAR', basisNote: '' });
  const load = useCallback(async () => {
    setData(await api('GET', `/bank-flows?company=${company}&year=${year}`));
    setPerf((await api<{ items: Performance[] }>('GET', '/bank-flows/performance')).items);
    setPicked([]);
  }, [company, year]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/institutions').then(r => { setBanks(r.items); setD(x => ({ ...x, institution: x.institution || r.items[0]?.id || '' })); }); }, []);
  const act = async (fn: () => Promise<unknown>, ok = 'Saved.') => {
    setNotice({});
    try { await fn(); await load(); setNotice({ ok }); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h2>{t('Flows routed to the banks')}</h2>
        <Field label="Year" value={year} onChange={setYear} type="number" />
        <Notice {...notice} />
        {data && <>
          <Table rows={data.items} columns={[
            { header: 'Month', cell: f => <span dir="ltr">{f.month.slice(0, 7)}</span> },
            { header: 'Bank', cell: f => <span dir="ltr">{f.institution.code}</span> },
            { header: 'Facility', cell: f => <span dir="ltr">{f.facility?.facilityNo ?? t('Bank level')}</span> },
            { header: 'Kind', cell: f => t(f.kind) },
            { header: 'Amount', cell: f => <span dir="ltr">{amount(f.amount)} {f.currency}</span> },
            { header: 'Status', cell: f => t(f.status) },
            { header: '', cell: f => <>
              {f.status === 'DRAFT' && can(me, 'fin.stats.confirm') && !f.enteredByMe &&
                <input type="checkbox" aria-label={t('Confirm')} checked={picked.includes(f.id)} onChange={e => setPicked(e.target.checked ? [...picked, f.id] : picked.filter(x => x !== f.id))} />}
              {f.status === 'CONFIRMED' && can(me, 'fin.stats.confirm') && !f.enteredByMe &&
                <button className="link" onClick={() => act(() => api('POST', `/bank-flows/${f.id}/actions/reopen`, { reason }), 'Reopened.')}>{t('Reopen')}</button>}
            </> },
          ]} />
          <h3>{t('Totals of the year')}</h3>
          <Table rows={data.totals} columns={[
            { header: 'Bank', cell: x => <span dir="ltr">{x.bank}</span> },
            { header: 'Confirmed', cell: x => <span dir="ltr">{amount(x.confirmed)} {x.currency}</span> },
            { header: 'Awaiting confirmation', cell: x => <span dir="ltr">{amount(x.awaitingConfirmation)}</span> },
          ]} />
        </>}
        <div className="row">
          {picked.length > 0 && <button onClick={() => act(() => api('POST', '/bank-flows/actions/confirm', { ids: picked }), 'Confirmed.')}>{t('Confirm the selected figures')}</button>}
          {can(me, 'fin.stats.confirm') && <Field label="Reason for reopening" value={reason} onChange={setReason} required={false} />}
        </div>
      </section>
      {can(me, 'fin.stats.enter') && <Form title="New bank flow" submit="Add" onSubmit={async () => {
        await api('POST', '/bank-flows', { company, institution: d.institution, month: d.month, amount: Number(d.amount), currency: d.currency, basisNote: d.basisNote || undefined });
        setD({ ...d, amount: '', basisNote: '' });
        await load();
      }}>
        <Select label="Bank" value={d.institution} onChange={v => setD({ ...d, institution: v })} options={banks.map(b => ({ value: b.id, label: b.code ?? '' }))} />
        <Field label="Month" value={d.month} onChange={v => setD({ ...d, month: v })} type="month" />
        <Field label="Amount" value={d.amount} onChange={v => setD({ ...d, amount: v })} type="number" />
        <Field label="Currency" value={d.currency} onChange={v => setD({ ...d, currency: v })} />
        <Field label="Basis of the amount" value={d.basisNote} onChange={v => setD({ ...d, basisNote: v })} required={false} />
      </Form>}
      <section className="card">
        <h2>{t('Flow covenants')}</h2>
        <Table rows={perf} columns={[
          { header: 'Facility', cell: p => <span dir="ltr">{p.facilityNo}</span> },
          { header: 'Window', cell: p => <span dir="ltr">{p.windowStart.slice(0, 10)} → {p.windowEnd.slice(0, 10)}</span> },
          { header: 'Required', cell: p => <span dir="ltr">{amount(p.thresholdValue)} {p.currency}</span> },
          { header: 'Achieved', cell: p => <span dir="ltr">{amount(p.achieved)} ({amount(p.achievementPct)}%)</span> },
          { header: 'Remaining', cell: p => <span dir="ltr">{amount(p.remaining)}</span> },
          { header: 'A month', cell: p => <span dir="ltr">{amount(p.requiredPerRemainingMonth)}</span> },
          { header: 'State', cell: p => <span className={p.state === 'BEHIND' ? 'error' : ''}>{t(p.state)}</span> },
        ]} />
      </section>
    </>
  );
}

function PeriodClose({ company }: { company: string }) {
  const { t } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<{ lockedThrough: string; status: string; reason: string; reopenReason?: string; lockedByMe: boolean }[]>([]);
  const [d, setD] = useState({ lockedThrough: '', reason: '' });
  const load = useCallback(async () => setRows((await api<{ items: typeof rows }>('GET', `/reporting-periods?company=${company}`)).items), [company]);
  useEffect(() => { void load(); }, [load]);
  if (!can(me, 'fin.period.lock') && rows.length === 0) return null;
  return (
    <>
      <section className="card">
        <h2>{t('Closed periods')}</h2>
        <Table rows={rows} columns={[
          { header: 'Closed through', cell: r => <span dir="ltr">{r.lockedThrough.slice(0, 10)}</span> },
          { header: 'Status', cell: r => t(r.status) },
          { header: 'Reason', cell: r => r.reopenReason ?? r.reason },
        ]} />
      </section>
      {can(me, 'fin.period.lock') && <Form title="Close or reopen the periods" submit="Close the periods" onSubmit={async () => {
        await api('POST', `/reporting-periods/${company}/actions/lock`, d);
        await load();
      }}>
        <Field label="Closed through" value={d.lockedThrough} onChange={v => setD({ ...d, lockedThrough: v })} type="date" required={false} />
        <Field label="Reason" value={d.reason} onChange={v => setD({ ...d, reason: v })} />
        <button type="button" className="link" onClick={async () => { await api('POST', `/reporting-periods/${company}/actions/reopen`, { reason: d.reason }); await load(); }}>{t('Reopen the latest close')}</button>
      </Form>}
    </>
  );
}
