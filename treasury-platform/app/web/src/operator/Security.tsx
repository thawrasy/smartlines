import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table, useStepUp } from '../ui';

/** The two-step verification policy of a tenant, as shown (ADR 0048). */
export const MFA_LABELS: Record<string, string> = { PLATFORM: 'As the platform setting', REQUIRED: 'Required', OFF: 'Off' };

interface Overview {
  settings: { guardEnabled: boolean; apiPerMinute: number; refusalLimit: number; refusalWindowSeconds: number; blockMinutes: number; trustedProxies: string[]; alertRecipients: number };
  counts: { autoBlocks24h: number; openIncidents: number };
  mfa: { platformRequired: boolean; tenants: { policy: string; tenants: number }[] };
  blocks: { id: string; clientIp: string; source: string; reason: string; blockedAt: string; blockedUntil?: string; blockedBy?: string }[];
  events: { occurredAt: string; actorType: string; action: string; severity: string; ipAddress?: string; result: string }[];
}

// Security: the guard's settings, the blocked addresses and the latest security events (docs/31 row 48, ADR 0047)
export function Security({ admin }: { admin: boolean }) {
  const { t } = useI18n();
  const fmt = useFormat();
  const ask = useStepUp();
  const [d, setD] = useState<Overview | null>(null);
  const [f, setF] = useState({ clientIp: '', reason: '', hours: '24' });
  const [mfaRequired, setMfaRequired] = useState('false');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    const r = await api<Overview>('GET', '/operator/security/overview');
    setD(r);
    setMfaRequired(String(r.mfa.platformRequired));
  }, []);
  useEffect(() => { void load(); }, [load]);
  if (!d) return null;
  const lift = async (id: string) => {
    setNotice({});
    const mfaCode = await ask('Lifting a block needs a fresh code.');
    if (!mfaCode) return;
    try { await api('POST', `/operator/security/blocks/${id}/actions/lift`, { mfaCode }); await load(); } catch (e) { setNotice({ error: message(e) }); }
  };
  const s = d.settings;
  return (
    <>
      <section className="card">
        <h1>{t('Security')}</h1>
        <p>{t('Automatic blocks in the last 24 hours')}: <strong>{d.counts.autoBlocks24h}</strong> · {t('Open incidents')}: <strong>{d.counts.openIncidents}</strong></p>
        <Table rows={([
          ['The guard', s.guardEnabled ? t('On') : t('Off')],
          ['API requests a minute from one address', String(s.apiPerMinute)],
          ['Refusals that block an address', `${s.refusalLimit} / ${s.refusalWindowSeconds} s`],
          ['Automatic block (minutes)', String(s.blockMinutes)],
          ['Trusted proxies', s.trustedProxies.join(', ')],
          ['Alert recipients', String(s.alertRecipients)],
        ] as [string, string][])} columns={[{ header: 'Setting', cell: ([k]) => t(k) }, { header: 'Value', cell: ([, v]) => <span dir="ltr">{v}</span> }]} />
        <p className="muted">{t('The values are platform settings (Security section); the trusted proxy is never blocked.')}</p>
      </section>
      <section className="card">
        <h2>{t('Two-step verification')}</h2>
        <p>{t('For the users of every tenant whose own setting is the platform\'s')}: <strong>{t(d.mfa.platformRequired ? 'Required' : 'Not required')}</strong></p>
        <Table rows={d.mfa.tenants} columns={[{ header: 'Tenant setting', cell: r => t(MFA_LABELS[r.policy] ?? r.policy) }, { header: 'Tenants', cell: r => String(r.tenants) }]} />
        {admin && (
          <Form title="Two-step verification for the platform" submit="Save" onSubmit={async () => {
            const mfaCode = await ask('Changing two-step verification needs a fresh code.');
            if (!mfaCode) return;
            await api('PUT', '/operator/security/mfa', { required: mfaRequired === 'true', mfaCode });
            await load();
          }}>
            <Select label="Two-step verification" value={mfaRequired} onChange={setMfaRequired}
              options={[{ value: 'false', label: t('Not required (trial)') }, { value: 'true', label: t('Required') }]} />
          </Form>
        )}
      </section>
      <section className="card">
        <h2>{t('Blocked addresses')}</h2>
        <Notice ok={notice.ok} error={notice.error} />
        <Table rows={d.blocks} empty="No address is blocked." columns={[
          { header: 'Address', cell: b => <span dir="ltr">{b.clientIp}</span> },
          { header: 'Source', cell: b => t(b.source) },
          { header: 'Reason', cell: b => b.reason },
          { header: 'Since', cell: b => fmt.dateTime(b.blockedAt) },
          { header: 'Until', cell: b => b.blockedUntil ? fmt.dateTime(b.blockedUntil) : t('Until lifted') },
          { header: 'By', cell: b => <span dir="ltr">{b.blockedBy ?? t('SYSTEM')}</span> },
          { header: '', cell: b => admin ? <button className="link" onClick={() => void lift(b.id)}>{t('Lift')}</button> : null },
        ]} />
      </section>
      {admin && (
        <Form title="Block an address" submit="Block" onSubmit={async () => {
          const mfaCode = await ask('Blocking an address needs a fresh code.');
          if (!mfaCode) return;
          await api('POST', '/operator/security/blocks', { clientIp: f.clientIp.trim(), reason: f.reason, hours: f.hours ? Number(f.hours) : undefined, mfaCode });
          setF({ clientIp: '', reason: '', hours: '24' });
          await load();
        }}>
          <Field label="IP address" value={f.clientIp} onChange={v => setF({ ...f, clientIp: v })} hint="Never the address of the reverse proxy; the platform refuses it." />
          <Field label="Reason" value={f.reason} onChange={v => setF({ ...f, reason: v })} />
          <Field label="Hours (empty: until lifted)" value={f.hours} onChange={v => setF({ ...f, hours: v })} type="number" required={false} />
        </Form>
      )}
      <section className="card">
        <h2>{t('Security events')}</h2>
        <Table rows={d.events} empty="No security event yet." columns={[
          { header: 'When', cell: e => fmt.dateTime(e.occurredAt) },
          { header: 'Event', cell: e => t(e.action) },
          { header: 'Severity', cell: e => t(e.severity) },
          { header: 'By', cell: e => t(e.actorType) },
          { header: 'Address', cell: e => <span dir="ltr">{e.ipAddress ?? ''}</span> },
          { header: 'Result', cell: e => t(e.result) },
        ]} />
      </section>
    </>
  );
}

interface Incident {
  id: string; incidentNo: string; title: string; severity: string; status: string; detectedAt: string; description: string;
  rootCause?: string; actions?: string; clientIps?: string; openedBy: string; closedAt?: string; closedBy?: string;
}

const SEVERITIES = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
const STATUSES = ['OPEN', 'CONTAINED', 'RESOLVED', 'CLOSED'];

// The incident register (DOC-S15): from detection to the close with the root cause and the corrective actions
export function Incidents({ admin }: { admin: boolean }) {
  const { t } = useI18n();
  const fmt = useFormat();
  const ask = useStepUp();
  const [rows, setRows] = useState<Incident[]>([]);
  const [open, setOpen] = useState<Incident | null>(null);
  const [f, setF] = useState({ title: '', severity: 'MEDIUM', detectedAt: '', description: '', clientIps: '' });
  const [c, setC] = useState({ status: 'CONTAINED', rootCause: '', actions: '' });
  const load = useCallback(async () => setRows((await api<{ items: Incident[] }>('GET', '/operator/security/incidents')).items), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Security incidents')}</h1>
        <Table rows={rows} empty="No incident is recorded." columns={[
          { header: 'Number', cell: i => <button className="link" dir="ltr" onClick={() => { setOpen(i); setC({ status: i.status === 'OPEN' ? 'CONTAINED' : i.status, rootCause: i.rootCause ?? '', actions: i.actions ?? '' }); }}>{i.incidentNo}</button> },
          { header: 'Title', cell: i => i.title },
          { header: 'Severity', cell: i => t(i.severity) },
          { header: 'Status', cell: i => t(i.status) },
          { header: 'Detected', cell: i => fmt.dateTime(i.detectedAt) },
        ]} />
      </section>
      {open && (
        <section className="card">
          <h2 dir="auto">{open.incidentNo} · {open.title}</h2>
          <p>{open.description}</p>
          {open.clientIps && <p>{t('Addresses')}: <span dir="ltr">{open.clientIps}</span></p>}
          {open.rootCause && <p>{t('Root cause')}: {open.rootCause}</p>}
          {open.actions && <p>{t('Corrective actions')}: {open.actions}</p>}
          <p className="muted">{t('Opened by')} <span dir="ltr">{open.openedBy}</span>{open.closedBy && <> · {t('Closed by')} <span dir="ltr">{open.closedBy}</span> {fmt.dateTime(open.closedAt)}</>}</p>
        </section>
      )}
      {admin && open && open.status !== 'CLOSED' && (
        <Form title="Update the incident" submit="Save" onSubmit={async () => {
          const mfaCode = await ask('Changing an incident needs a fresh code.');
          if (!mfaCode) return;
          await api('PATCH', `/operator/security/incidents/${open.id}`, { status: c.status, rootCause: c.rootCause || undefined, actions: c.actions || undefined, mfaCode });
          setOpen(null);
          await load();
        }}>
          <Select label="Status" value={c.status} onChange={v => setC({ ...c, status: v })} options={STATUSES.map(s => ({ value: s, label: t(s) }))} />
          <Field label="Root cause (to close)" value={c.rootCause} onChange={v => setC({ ...c, rootCause: v })} required={c.status === 'CLOSED'} />
          <Field label="Corrective actions" value={c.actions} onChange={v => setC({ ...c, actions: v })} required={false} />
        </Form>
      )}
      {admin && (
        <Form title="Record an incident" submit="Record" onSubmit={async () => {
          const mfaCode = await ask('Recording an incident needs a fresh code.');
          if (!mfaCode) return;
          await api('POST', '/operator/security/incidents', { ...f, detectedAt: f.detectedAt ? new Date(f.detectedAt).toISOString() : undefined, clientIps: f.clientIps || undefined, mfaCode });
          setF({ title: '', severity: 'MEDIUM', detectedAt: '', description: '', clientIps: '' });
          await load();
        }}>
          <Field label="Title" value={f.title} onChange={v => setF({ ...f, title: v })} />
          <Select label="Severity" value={f.severity} onChange={v => setF({ ...f, severity: v })} options={SEVERITIES.map(s => ({ value: s, label: t(s) }))} />
          <Field label="Detected at (empty: now)" value={f.detectedAt} onChange={v => setF({ ...f, detectedAt: v })} type="datetime-local" required={false} />
          <Field label="What was seen" value={f.description} onChange={v => setF({ ...f, description: v })} />
          <Field label="Addresses involved" value={f.clientIps} onChange={v => setF({ ...f, clientIps: v })} required={false} />
        </Form>
      )}
    </>
  );
}
