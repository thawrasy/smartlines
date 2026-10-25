import { useCallback, useEffect, useState } from 'react';
import { api, download, message } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table, useWithStepUp } from '../ui';
import { Chip } from '../brand';

// ---------- SCR-PLT-11 settings ----------

interface Setting { key: string; valueType: string; defaultValue: unknown; min: unknown; max: unknown; isSecurity: boolean; editable: boolean; description?: string; value: unknown; effective: unknown }

const show = (v: unknown) => v === null || v === undefined ? '' : String(v);

export function Settings() {
  const { t } = useI18n();
  const [items, setItems] = useState<Setting[]>([]);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [ok, setOk] = useState<string | null>(null);
  const load = useCallback(async () => {
    const r = await api<{ items: Setting[] }>('GET', '/settings');
    setItems(r.items);
    setDraft(Object.fromEntries(r.items.map(s => [s.key, show(s.effective)])));
  }, []);
  useEffect(() => { void load(); }, [load]);
  return (
    <Form title="Security and settings" submit="Save changes" onSubmit={async () => {
      setOk(null);
      const values: Record<string, unknown> = {};
      for (const s of items) {
        if (!s.editable || draft[s.key] === show(s.effective)) continue;
        values[s.key] = s.valueType === 'INT' ? Number(draft[s.key]) : s.valueType === 'BOOL' ? draft[s.key] === 'true' : draft[s.key];
      }
      if (Object.keys(values).length === 0) return;
      await api('PATCH', '/settings', { values });
      setOk('Saved. Each change is in the audit log with the old and new value.');
      await load();
    }}>
      <Table rows={items} columns={[
        { header: 'Setting', cell: s => <><code dir="ltr">{s.key}</code>{s.isSecurity && <small className="muted"> · {t('security')}</small>}<br /><small className="muted">{s.description}</small></> },
        { header: 'Value', cell: s => <input dir="ltr" disabled={!s.editable} value={draft[s.key] ?? ''} onChange={e => setDraft({ ...draft, [s.key]: e.target.value })} /> },
        { header: 'Allowed', cell: s => s.min !== null || s.max !== null ? `${show(s.min)} – ${show(s.max)}` : '' },
        { header: 'Default', cell: s => show(s.defaultValue) },
      ]} />
      <Notice ok={ok} />
    </Form>
  );
}

// ---------- support access ----------

interface Operator { id: string; displayName?: string; role: string }
interface Grant { id: string; operatorName?: string; startsAt: string; endsAt: string; reason: string; status: string }

export function Support() {
  const { t } = useI18n();
  const fmt = useFormat();
  const [operators, setOperators] = useState<Operator[]>([]);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [draft, setDraft] = useState({ operatorId: '', hours: '4', reason: '' });
  const load = useCallback(async () => {
    const [o, g] = await Promise.all([api<{ items: Operator[] }>('GET', '/support-operators'), api<{ items: Grant[] }>('GET', '/support-grants')]);
    setOperators(o.items);
    setGrants(g.items);
    setDraft(d => ({ ...d, operatorId: d.operatorId || o.items[0]?.id || '' }));
  }, []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <Form title="Give support access" submit="Give access" onSubmit={async () => {
        await api('POST', '/support-grants', { operatorId: draft.operatorId, hours: Number(draft.hours), reason: draft.reason });
        setDraft({ ...draft, reason: '' });
        await load();
      }}>
        <p>{t('A BankFas operator sees your data, read-only, for the hours you choose. Every page they open is in your audit log.')}</p>
        <Select label="Operator" value={draft.operatorId} onChange={v => setDraft({ ...draft, operatorId: v })}
          options={operators.map(o => ({ value: o.id, label: o.displayName ?? o.id }))} />
        <Field label="Hours (1 to 72)" value={draft.hours} onChange={v => setDraft({ ...draft, hours: v })} type="number" />
        <Field label="Reason" value={draft.reason} onChange={v => setDraft({ ...draft, reason: v })} />
      </Form>
      <section className="card">
        <h2>{t('Support access given')}</h2>
        <Table rows={grants} columns={[
          { header: 'Operator', cell: g => g.operatorName },
          { header: 'From', cell: g => fmt.dateTime(g.startsAt) },
          { header: 'Until', cell: g => fmt.dateTime(g.endsAt) },
          { header: 'Reason', cell: g => g.reason },
          { header: 'Status', cell: g => <Chip s={g.status} /> },
          { header: '', cell: g => g.status === 'ACTIVE' || g.status === 'SCHEDULED'
            ? <button className="link" onClick={async () => { await api('POST', `/support-grants/${g.id}/actions/revoke`, {}); await load(); }}>{t('Revoke')}</button> : null },
        ]} />
      </section>
    </>
  );
}

// ---------- SCR-PLT-12 numbering ----------

interface Sequence { sequenceKey: string; pattern: string; scopeLevel: string; periodBasis: string; gapPolicy: string; isActive: boolean; etag: string; example: string }

export function Numbering() {
  const { t } = useI18n();
  const [rows, setRows] = useState<Sequence[]>([]);
  const [draft, setDraft] = useState({ sequenceKey: '', pattern: '{seq:0000}-{yy}', gapPolicy: 'GAP_FREE' });
  const [preview, setPreview] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => setRows((await api<{ items: Sequence[] }>('GET', '/number-sequences')).items), []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    const id = setTimeout(() => {
      api<{ examples: string[] }>('POST', '/number-sequences/preview', { pattern: draft.pattern })
        .then(r => { setPreview(r.examples); setError(null); }).catch(e => { setPreview([]); setError(message(e)); });
    }, 300);
    return () => clearTimeout(id);
  }, [draft.pattern]);
  return (
    <>
      <section className="card">
        <h1>{t('Numbering')}</h1>
        <Table rows={rows} columns={[
          { header: 'Sequence', cell: s => <code dir="ltr">{s.sequenceKey}</code> },
          { header: 'Pattern', cell: s => <code dir="ltr">{s.pattern}</code> },
          { header: 'Example', cell: s => <span dir="ltr">{s.example}</span> },
          { header: 'Gaps', cell: s => t(s.gapPolicy) },
          { header: 'Active', cell: s => <input type="checkbox" checked={s.isActive}
            onChange={async e => { await api('PATCH', `/number-sequences/${encodeURIComponent(s.sequenceKey)}`, { isActive: e.target.checked }, s.etag); await load(); }} /> },
        ]} />
      </section>
      <Form title="New sequence" submit="Create" onSubmit={async () => { await api('POST', '/number-sequences', draft); await load(); }}>
        <Field label="Sequence key" value={draft.sequenceKey} onChange={v => setDraft({ ...draft, sequenceKey: v })} />
        <Field label="Pattern" value={draft.pattern} onChange={v => setDraft({ ...draft, pattern: v })} hint="Tags: {seq} or {seq:0000}, {yy}, {yyyy}." />
        <Select label="Gaps" value={draft.gapPolicy} onChange={v => setDraft({ ...draft, gapPolicy: v })}
          options={[{ value: 'GAP_FREE', label: 'GAP_FREE' }, { value: 'ALLOW_GAPS', label: 'ALLOW_GAPS' }]} />
        <p dir="ltr">{preview.join('   ')}</p>
        <Notice error={error} />
      </Form>
    </>
  );
}

// ---------- non-working days (FR-PLT-035) ----------

interface NonWorkingDay { id: string | null; platform: boolean; country: string; onDate: string; nameAr?: string; nameEn?: string; kind: string }

export function Calendar() {
  const { t } = useI18n();
  const [year, setYear] = useState(String(new Date().getFullYear()));
  const [rows, setRows] = useState<NonWorkingDay[]>([]);
  const [draft, setDraft] = useState({ country: 'SA', onDate: '', nameAr: '', nameEn: '', kind: 'HOLIDAY' });
  const load = useCallback(async () => setRows((await api<{ items: NonWorkingDay[] }>('GET', `/non-working-days?year=${encodeURIComponent(year)}`)).items), [year]);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <section className="card">
        <h1>{t('Non-working days')}</h1>
        <p>{t('The weekend and these days are skipped when a due date is counted in working days. The platform enters the public holidays; you add your own days.')}</p>
        <Field label="Year" value={year} onChange={setYear} type="number" />
        <Table rows={rows} columns={[
          { header: 'Date', cell: d => <span dir="ltr">{d.onDate}</span> },
          { header: 'Country', cell: d => d.country },
          { header: 'Name', cell: d => d.nameAr || d.nameEn },
          { header: 'Kind', cell: d => t(d.kind) },
          { header: 'Source', cell: d => t(d.platform ? 'Platform' : 'This account') },
          { header: '', cell: d => d.id
            ? <button className="link" onClick={async () => { await api('DELETE', `/non-working-days/${d.id}`); await load(); }}>{t('Remove')}</button> : null },
        ]} />
      </section>
      <Form title="Add a non-working day" submit="Add" onSubmit={async () => { await api('POST', '/non-working-days', draft); setDraft({ ...draft, onDate: '', nameAr: '', nameEn: '' }); await load(); }}>
        <Field label="Country (ISO)" value={draft.country} onChange={v => setDraft({ ...draft, country: v })} />
        <Field label="Date" value={draft.onDate} onChange={v => setDraft({ ...draft, onDate: v })} type="date" />
        <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} />
        <Select label="Kind" value={draft.kind} onChange={v => setDraft({ ...draft, kind: v })}
          options={['HOLIDAY', 'BRIDGE', 'OTHER'].map(k => ({ value: k, label: t(k) }))} />
      </Form>
    </>
  );
}

// ---------- SCR-PLT-13 audit log ----------

interface AuditRow { id: string; occurredAt: string; actorType: string; action: string; category: string; severity: string; result: string; ipAddress?: string; before: unknown; after: unknown }

export function Audit() {
  const { t } = useI18n();
  const fmt = useFormat();
  const withStepUp = useWithStepUp();
  const [rows, setRows] = useState<AuditRow[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [filter, setFilter] = useState({ category: '', severity: '', from: '', to: '' });
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async (more?: string) => {
    const p = new URLSearchParams({ limit: '50' });
    for (const [k, v] of Object.entries(filter)) if (v) p.set(k, v);
    if (more) p.set('cursor', more);
    try {
      const r = await api<{ items: AuditRow[]; nextCursor: string | null }>('GET', '/audit-events?' + p.toString());
      setRows(prev => more ? [...prev, ...r.items] : r.items);
      setCursor(r.nextCursor);
      setError(null);
    } catch (e) { setError(message(e)); }
  }, [filter]);
  useEffect(() => { void load(); }, [load]);
  return (
    <section className="card">
      <h1>{t('Audit log')}</h1>
      <div className="filters">
        <Select label="Category" value={filter.category} onChange={v => setFilter({ ...filter, category: v })}
          options={[{ value: '', label: 'All' }, ...['SECURITY', 'CONFIG', 'IDENTITY_ACCESS', 'TREASURY', 'SYSTEM'].map(c => ({ value: c, label: c }))]} />
        <Select label="Severity" value={filter.severity} onChange={v => setFilter({ ...filter, severity: v })}
          options={[{ value: '', label: 'All' }, { value: 'HIGH', label: 'HIGH' }, { value: 'INFO', label: 'INFO' }]} />
        <Field label="From" type="date" value={filter.from} onChange={v => setFilter({ ...filter, from: v })} required={false} />
        <Field label="To" type="date" value={filter.to} onChange={v => setFilter({ ...filter, to: v })} required={false} />
      </div>
      <div className="actions">
        <button className="secondary" onClick={async () => {
          try {
            await withStepUp('Exporting the audit log needs a fresh code.', code =>
              download('/audit-events/exports', { from: filter.from || new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10), to: filter.to || undefined,
                category: filter.category || undefined, stepUpCode: code }, 'audit.csv'));
          } catch (e) { setError(message(e)); }
        }}>{t('Export CSV')}</button>
      </div>
      <Notice error={error} />
      <Table rows={rows} columns={[
        { header: 'When', cell: r => fmt.dateTime(r.occurredAt) },
        { header: 'Action', cell: r => <code dir="ltr">{r.action}</code> },
        { header: 'Category', cell: r => r.category },
        { header: 'Severity', cell: r => r.severity === 'HIGH' ? <strong>{r.severity}</strong> : r.severity },
        { header: 'Result', cell: r => r.result },
        { header: 'Details', cell: r => <small dir="ltr">{JSON.stringify(r.after ?? r.before ?? '')}</small> },
      ]} />
      {cursor && <button className="secondary" onClick={() => void load(cursor)}>{t('Show more')}</button>}
    </section>
  );
}

// ---------- SCR-PLT-14 background jobs ----------

interface Job { jobKey: string; lastStatus: string; lastStartedAt: string; lastSucceededAt?: string; lastResult?: string; lastError?: string }

export function Jobs() {
  const { t } = useI18n();
  const fmt = useFormat();
  const [rows, setRows] = useState<Job[]>([]);
  useEffect(() => { api<{ items: Job[] }>('GET', '/jobs').then(r => setRows(r.items)).catch(() => setRows([])); }, []);
  return (
    <section className="card">
      <h1>{t('Background jobs')}</h1>
      <Table rows={rows} columns={[
        { header: 'Job', cell: j => <code dir="ltr">{j.jobKey}</code> },
        { header: 'Last run', cell: j => fmt.dateTime(j.lastStartedAt) },
        { header: 'Status', cell: j => <Chip s={j.lastStatus} /> },
        { header: 'Last success', cell: j => fmt.dateTime(j.lastSucceededAt) },
        { header: 'Result', cell: j => j.lastError ?? j.lastResult },
      ]} />
    </section>
  );
}

// ---------- FR-PLT-039 tenant data export ----------

interface DataExport {
  id: string; status: string; includesRestricted: boolean; requestedAt: string; requestedByEn?: string; requestedByAr?: string;
  finishedAt?: string; expiresAt?: string; sizeBytes?: number; sha256?: string; failureReason?: string; mine: number;
}

export function DataExports() {
  const { t, lang } = useI18n();
  const fmt = useFormat();
  const withStepUp = useWithStepUp();
  const [rows, setRows] = useState<DataExport[]>([]);
  const [restricted, setRestricted] = useState(false);
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => api<{ items: DataExport[] }>('GET', '/data-exports').then(r => setRows(r.items)).catch(e => setError(message(e))), []);
  useEffect(() => { void load(); }, [load]);
  const act = async (f: () => Promise<unknown>) => { try { await f(); setError(null); await load(); } catch (e) { setError(message(e)); } };
  return (
    <section className="card">
      <h1>{t('Data export')}</h1>
      <p>{t('The whole account is exported as one package: the tables as JSON and the files. It is kept for 7 days; only the user who asked downloads it, sealed with a password chosen at download and never stored. Open it with: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -in package.zip.enc -out package.zip')}</p>
      <div className="actions">
        <label><input type="checkbox" checked={restricted} onChange={e => setRestricted(e.target.checked)} /> {t('Include restricted data (needs the approval of a holder of identity reveal)')}</label>
        <button onClick={() => void act(() => api('POST', '/data-exports', { includesRestricted: restricted }))}>{t('Request an export')}</button>
      </div>
      <Field label="Package password (12 characters or more)" type="password" value={password} onChange={setPassword} required={false} />
      <Notice error={error} />
      <Table rows={rows} columns={[
        { header: 'Requested', cell: r => fmt.dateTime(r.requestedAt) },
        { header: 'By', cell: r => (lang === 'ar' ? r.requestedByAr : r.requestedByEn) ?? r.requestedByEn ?? r.requestedByAr },
        { header: 'Restricted data', cell: r => t(r.includesRestricted ? 'Yes' : 'No') },
        { header: 'Status', cell: r => <Chip s={r.status} /> },
        { header: 'Expires', cell: r => fmt.dateTime(r.expiresAt) },
        { header: 'Size', cell: r => r.sizeBytes ? `${Math.ceil(r.sizeBytes / 1024)} KB` : '' },
        { header: 'Details', cell: r => r.failureReason ?? (r.sha256 ? <small dir="ltr">SHA-256 {r.sha256}</small> : '') },
        { header: '', cell: r => <>
          {r.status === 'REQUESTED' && r.includesRestricted && <button className="secondary" onClick={() => void act(() => api('POST', `/data-exports/${r.id}/approve`))}>{t('Approve')}</button>}
          {r.status === 'READY' && r.mine === 1 && <button className="secondary" disabled={password.length < 12} onClick={() => void act(() =>
            withStepUp('Downloading the data export needs a fresh code.', code => download(`/data-exports/${r.id}/download`, { password, stepUpCode: code }, 'export.zip.enc')))}>{t('Download')}</button>}
        </> },
      ]} />
    </section>
  );
}
