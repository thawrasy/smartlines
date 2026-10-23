import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Notice, Select, Table } from '../ui';
import { can, useMe } from './Portal';

// SCR-REQ-10 to 12 (FR-REQ-018 to 020): the requester's, the treasury officer's and the treasury manager's dashboards.
// The views a user may open follow their permissions; the counters are the lengths of the lists under them.

type Row = Record<string, unknown>;
type Data = Record<string, unknown> & { counters: Record<string, number> };
const str = (v: unknown) => v == null ? '' : typeof v === 'number' ? v.toLocaleString('en-US', { maximumFractionDigits: 2 }) : String(v);
const day = (v: unknown) => str(v).slice(0, 16).replace('T', ' ');
const pick = (lang: string, r: Row, base: string) => str(lang === 'ar' ? r[`${base}Ar`] ?? r[`${base}En`] : r[`${base}En`] ?? r[`${base}Ar`]);

export function Dashboards() {
  const { t, lang } = useI18n();
  const me = useMe();
  const views = [
    ...(can(me, 'req.view.own') ? [{ value: 'requester', label: t('My requests') }] : []),
    ...(can(me, 'req.claim') || can(me, 'req.execute') ? [{ value: 'officer', label: t('Treasury officer') }] : []),
    ...(can(me, 'req.dashboard.manager') ? [{ value: 'manager', label: t('Treasury manager') }] : []),
  ];
  const [view, setView] = useState(views[views.length - 1]?.value ?? 'requester');
  const [data, setData] = useState<Data | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setData(null); setError(null);
    api<Data>('GET', `/dashboards/${view}`).then(setData).catch(e => setError(message(e)));
  }, [view]);
  const number = { header: 'Number', cell: (r: Row) => <Link to={`/requests/${str(r.id ?? r.requestId)}`} dir="ltr">{str(r.requestNo)}</Link> };
  const list = (key: string, empty: string, extra: { header: string; cell: (r: Row) => React.ReactNode }[]) => (
    <Table rows={(data?.[key] as Row[]) ?? []} empty={empty} columns={[number, { header: 'Title', cell: r => str(r.title) }, ...extra]} />
  );
  const c = data?.counters ?? {};
  return (
    <section className="card">
      <h1>{t('Dashboards')}</h1>
      {views.length > 1 && <Select label="View" value={view} onChange={setView} options={views} />}
      <Notice error={error} />
      {data && view === 'requester' && (
        <>
          <p>{t('Open')}: {c.open} · {t('Waiting for me')}: {c.waitsForMe} · {t('Returned')}: {c.returned} · {t('Ended lately')}: {c.endedLately}</p>
          <h2>{t('Waiting for me')}</h2>
          {list('waitsForMe', 'None of your requests waits for you.', [{ header: 'Phase', cell: r => pick(lang, r, 'phaseName') }])}
          <h2>{t('Open')}</h2>
          {list('open', 'No open request.', [{ header: 'Phase', cell: r => pick(lang, r, 'phaseName') }, { header: 'Updated', cell: r => <span dir="ltr">{day(r.updatedAt)}</span> }])}
          <h2>{t('Ended lately')}</h2>
          {list('endedLately', 'Nothing ended lately.', [{ header: 'Status', cell: r => t(str(r.status)) }])}
        </>
      )}
      {data && view === 'officer' && (
        <>
          <p>{t('My tasks')}: {c.tasks} · {t('Queue')}: {c.queue} · {t('Overdue')}: {c.overdue} · {t('At the bank')}: {c.atBank}</p>
          <h2>{t('My tasks')}</h2>
          {list('tasks', 'You hold no task.', [
            { header: 'Stage', cell: r => str(r.stage) }, { header: 'Sub-status', cell: r => str(r.subStatus) },
            { header: 'Due', cell: r => <span dir="ltr">{day(r.dueAt)}</span> }, { header: 'SLA', cell: r => str(r.slaState) === 'NONE' ? '' : t(`SLA ${str(r.slaState)}`) },
          ])}
          <h2>{t('Queue')}</h2>
          {list('queue', 'The queue is empty.', [
            { header: 'Priority', cell: r => r.priority === 'URGENT' ? <strong>{t('Urgent')}</strong> : t('Normal') },
            { header: 'In the queue since', cell: r => <span dir="ltr">{day(r.queuedAt)}</span> },
          ])}
        </>
      )}
      {data && view === 'manager' && (
        <>
          <p>
            {t('Approvals')}: {c.approvals} · {t('Overdue')}: {c.overdue} · {t('At risk')}: {c.atRisk} · {t('Queue')}: {c.queue} · {t('Old reservations')}: {c.oldReservations}
          </p>
          <h2>{t('Approvals')}</h2>
          {list('approvals', 'No approval waits for you.', [
            { header: 'Stage', cell: r => str(r.stage) }, { header: 'Amount', cell: r => r.amount == null ? '' : <span dir="ltr">{str(r.amount)} {str(r.currency)}</span> },
            { header: 'Available', cell: r => r.available == null ? '' : <span dir="ltr">{str(r.available)}</span> },
            { header: 'SLA', cell: r => str(r.slaState) === 'NONE' ? '' : t(`SLA ${str(r.slaState)}`) },
          ])}
          <h2>{t('SLA breaches')}</h2>
          {list('breaches', 'No breach.', [
            { header: 'Stage', cell: r => str(r.stage) }, { header: 'Assigned to', cell: r => pick(lang, r, 'assigneeName') },
            { header: 'Due', cell: r => <span dir="ltr">{day(r.dueAt)}</span> }, { header: 'SLA', cell: r => t(`SLA ${str(r.slaState)}`) },
          ])}
          <h2>{t('Queue age')}</h2>
          <p dir="ltr">{str((data.queueAge as Row).count)} · {str((data.queueAge as Row).oldestHours)} h · {str((data.queueAge as Row).averageHours)} h</p>
          <h2>{t('Load per officer')}</h2>
          <Table rows={(data.load as Row[]) ?? []} empty="No open task." columns={[
            { header: 'Officer', cell: r => pick(lang, r, 'displayName') }, { header: 'Open', cell: r => str(r.open) }, { header: 'Overdue', cell: r => str(r.overdue) },
          ]} />
          <h2>{t('Reservations')}</h2>
          <Table rows={(data.reservations as Row[]) ?? []} empty="No active reservation." columns={[
            number, { header: 'Facility', cell: r => <span dir="ltr">{str(r.facilityNo)}</span> },
            { header: 'Amount', cell: r => <span dir="ltr">{str(r.amount)} {str(r.currency)}</span> }, { header: 'Age (days)', cell: r => str(r.ageDays) },
            { header: 'Expires', cell: r => <span dir="ltr">{str(r.expiresOn).slice(0, 10)}</span> },
            { header: '', cell: r => r.old ? <strong>{t('Old')}</strong> : r.overLimit ? t('Over the limit') : '' },
          ]} />
        </>
      )}
    </section>
  );
}
