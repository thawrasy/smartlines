import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// SCR-REQ-06 to 09 and SCR-WFL-05 (spec 13 section 7): the unified inbox with its counters (approvals waiting for me,
// including my delegators' while a delegation is in force; the tasks I hold; the queue I may claim, urgent first; my own
// requests waiting for me), and my delegations: who acts for me, for whom I act, a new one and its revocation.

type Row = Record<string, unknown>;
const str = (v: unknown) => v == null ? '' : String(v);
const day = (v: unknown) => str(v).slice(0, 16).replace('T', ' ');
const name = (lang: string, r: Row | null | undefined, base = 'displayName') =>
  r == null ? '' : str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

type InboxData = { counters: Record<string, number>; approvals: Row[]; tasks: Row[]; queue: Row[]; awaitingMe: Row[] };

export function Inbox() {
  const { t, lang } = useI18n();
  const [data, setData] = useState<InboxData | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { api<InboxData>('GET', '/inbox').then(setData).catch(e => setError(message(e))); }, []);
  const columns = [
    { header: 'Number', cell: (r: Row) => <Link to={`/requests/${str(r.id)}`} dir="ltr">{str(r.requestNo)}</Link> },
    { header: 'Type', cell: (r: Row) => str(r.type) },
    { header: 'Title', cell: (r: Row) => str(r.title) },
    { header: 'Stage', cell: (r: Row) => str(r.stage) },
    { header: 'Priority', cell: (r: Row) => r.priority === 'URGENT' ? <strong>{t('Urgent')}</strong> : t('Normal') },
    { header: 'Due', cell: (r: Row) => <span dir="ltr">{day(r.dueAt)}</span> },
    { header: 'SLA', cell: (r: Row) => str(r.slaState) === 'NONE' ? '' : t(`SLA ${str(r.slaState)}`) },
    { header: 'On behalf of', cell: (r: Row) => name(lang, r.onBehalfOf as Row | null) },
  ];
  if (!data) return <section className="card"><h1>{t('Inbox')}</h1><Notice error={error} /></section>;
  const c = data.counters;
  return (
    <section className="card">
      <h1>{t('Inbox')}</h1>
      <p>
        {t('Approvals')}: {c.approvals} · {t('My tasks')}: {c.tasks} · {t('Queue')}: {c.queue} · {t('Waiting for me')}: {c.awaitingMe}
        {(c.overdue ?? 0) > 0 && <> · <strong>{t('Overdue')}: {c.overdue}</strong></>}
        {(c.atRisk ?? 0) > 0 && <> · {t('At risk')}: {c.atRisk}</>}
      </p>
      <h2>{t('Approvals')}</h2>
      <Table rows={data.approvals} empty="No approval waits for you." columns={columns} />
      <h2>{t('My tasks')}</h2>
      <Table rows={data.tasks} empty="You hold no task." columns={columns} />
      <h2>{t('Queue')}</h2>
      <Table rows={data.queue} empty="The queue is empty." columns={columns} />
      <h2>{t('Waiting for me')}</h2>
      <Table rows={data.awaitingMe} empty="None of your requests waits for you." columns={columns} />
    </section>
  );
}

export function Delegations() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [rows, setRows] = useState<Row[]>([]);
  const [people, setPeople] = useState<Row[]>([]);
  const [q, setQ] = useState('');
  const [to, setTo] = useState('');
  const [startsOn, setStartsOn] = useState('');
  const [endsOn, setEndsOn] = useState('');
  const [scope, setScope] = useState('ALL');
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const all = can(me, 'req.delegate.manage');
  const load = useCallback(async () => {
    const r = await api<{ items: Row[] }>('GET', `/delegations${all ? '?view=all' : ''}`);
    setRows(r.items);
  }, [all]);
  useEffect(() => { void load().catch(e => setError(message(e))); }, [load]);
  useEffect(() => {
    api<{ items: Row[] }>('GET', `/delegations/people${q ? `?q=${encodeURIComponent(q)}` : ''}`).then(r => setPeople(r.items)).catch(() => setPeople([]));
  }, [q]);
  const create = async () => {
    setError(null); setOk(null);
    try {
      await api('POST', '/delegations', { to, startsOn, endsOn, scope, reason: reason || null });
      setOk(t('The delegation is saved.'));
      await load();
    } catch (e) { setError(message(e)); }
  };
  const revoke = async (id: string) => {
    setError(null); setOk(null);
    try {
      await api('POST', `/delegations/${id}/revoke`, {});
      setOk(t('The delegation is revoked.'));
      await load();
    } catch (e) { setError(message(e)); }
  };
  return (
    <section className="card">
      <h1>{t('Delegations')}</h1>
      <Notice error={error} ok={ok} />
      <Table rows={rows} empty="No delegation." columns={[
        { header: 'From', cell: r => name(lang, r, 'fromName') },
        { header: 'To', cell: r => name(lang, r, 'toName') },
        { header: 'Starts', cell: r => <span dir="ltr">{str(r.startsOn).slice(0, 10)}</span> },
        { header: 'Ends', cell: r => <span dir="ltr">{str(r.endsOn).slice(0, 10)}</span> },
        { header: 'Scope', cell: r => t(`Scope ${str(r.scope)}`) },
        { header: 'Status', cell: r => <Chip s={str(r.status)} /> },
        { header: '', cell: r => ['SCHEDULED', 'ACTIVE'].includes(str(r.status)) ? <button type="button" onClick={() => void revoke(str(r.id))}>{t('Revoke')}</button> : null },
      ]} />
      {can(me, 'req.delegate.own') && (
        <Form title="New delegation" submit="Save" onSubmit={create}>
          <Field label="Find a person" value={q} onChange={setQ} required={false} />
          <Select label="Delegate" value={to} onChange={setTo}
            options={[{ value: '', label: t('Choose') }, ...people.map(p => ({ value: str(p.id), label: name(lang, p) }))]} />
          <Field label="Starts on" type="date" value={startsOn} onChange={setStartsOn} />
          <Field label="Ends on" type="date" value={endsOn} onChange={setEndsOn} hint="At most 90 days." />
          <Select label="Scope" value={scope} onChange={setScope} options={[
            { value: 'ALL', label: t('Scope ALL') }, { value: 'APPROVALS_ONLY', label: t('Scope APPROVALS_ONLY') },
          ]} />
          <Field label="Reason" value={reason} onChange={setReason} required={false} />
        </Form>
      )}
    </section>
  );
}
