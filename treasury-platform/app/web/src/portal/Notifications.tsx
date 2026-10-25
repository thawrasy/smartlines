import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message, apiBackground } from '../api';
import { useFormat, useI18n } from '../i18n';
import { Notice, Table } from '../ui';
import { Chip } from '../brand';
import { can, useMe } from './Portal';

// Spec 13 section 6.3: the bell with the unread counter, the user's notifications and preferences (FR-NTF-005, 006,
// 010), and for the account administrator the recipients and texts of each event (FR-NTF-003, 012) and the deliveries.

interface Item { id: string; eventCode: string; severity: string; title: string; body: string; deepLink?: string; createdAt: string; readAt?: string }
interface Feed { unreadCount: number; actionCount: number; items: Item[] }

/** The bell of the top bar: the unread count, refreshed every minute. */
export function Bell() {
  const { t } = useI18n();
  const [count, setCount] = useState(0);
  useEffect(() => {
    let live = true;
    const load = () => apiBackground<Feed>('/notifications?unread=true&limit=1').then(f => { if (live) setCount(f.unreadCount); }).catch(() => undefined);
    void load();
    const timer = window.setInterval(load, 60000);
    return () => { live = false; window.clearInterval(timer); };
  }, []);
  return <Link to="/notifications" className="bell" aria-label={t('Notifications')}>🔔{count > 0 && <span className="badge">{count}</span>}</Link>;
}

export function Notifications() {
  const { t } = useI18n();
  const fmt = useFormat();
  const [feed, setFeed] = useState<Feed | null>(null);
  const [prefs, setPrefs] = useState<{ groupKey: string; mandatoryInApp: boolean; emailAvailable: boolean; inApp: string; email: string }[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => {
    setFeed(await api<Feed>('GET', '/notifications?limit=100'));
    setPrefs((await api<{ items: typeof prefs }>('GET', '/notification-preferences')).items);
  }, []);
  useEffect(() => { void load(); }, [load]);
  if (!feed) return null;
  const read = async (id: string) => { await api('POST', `/notifications/${id}/actions/read`, {}); await load(); };
  const setPref = async (groupKey: string, channel: string, mode: string) => {
    try {
      await api('PUT', '/notification-preferences', { items: [{ groupKey, channel, mode }] });
      setNotice({ ok: 'Saved.' });
      await load();
    } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Notifications')}</h1>
        <p>{t('Unread')}: {feed.unreadCount} · {t('Action required')}: {feed.actionCount}</p>
        <button onClick={async () => { await api('POST', '/notifications/actions/read-all', {}); await load(); }}>{t('Mark all as read')}</button>
        <ul className="feed">
          {feed.items.map(n => (
            <li key={n.id} className={(n.readAt ? 'read ' : '') + 'sev-' + n.severity.toLowerCase()}>
              <strong>{n.title}</strong>
              <p>{n.body}</p>
              <small className="muted">{fmt.dateTime(n.createdAt)}</small>
              {n.deepLink && <> · <Link to={n.deepLink}>{t('Open')}</Link></>}
              {!n.readAt && <> · <button className="link" onClick={() => void read(n.id)}>{t('Mark as read')}</button></>}
            </li>
          ))}
        </ul>
        {feed.items.length === 0 && <p className="muted">{t('Nothing here yet.')}</p>}
      </section>
      <section className="card">
        <h2>{t('My notification preferences')}</h2>
        <Notice error={notice.error} ok={notice.ok} />
        <Table rows={prefs} columns={[
          { header: 'Group', cell: p => t(p.groupKey) },
          { header: 'In the application', cell: p => p.mandatoryInApp ? t('Always (mandatory)') : (
            <select value={p.inApp} onChange={e => void setPref(p.groupKey, 'IN_APP', e.target.value)}>
              <option value="IMMEDIATE">{t('IMMEDIATE')}</option><option value="OFF">{t('OFF')}</option>
            </select>) },
          { header: 'E-mail', cell: p => p.emailAvailable ? (
            <select value={p.email} onChange={e => void setPref(p.groupKey, 'EMAIL', e.target.value)}>
              <option value="IMMEDIATE">{t('IMMEDIATE')}</option><option value="DIGEST_DAILY">{t('DIGEST_DAILY')}</option>
              <option value="DIGEST_WEEKLY">{t('DIGEST_WEEKLY')}</option><option value="OFF">{t('OFF')}</option>
            </select>) : '—' },
        ]} />
      </section>
    </>
  );
}

interface EventDef {
  code: string; groupKey: string; nameAr?: string; nameEn?: string; severity: string; isMandatory: boolean; placeholders: string[];
  rules: { id: string; recipientKind: string; role?: string; permission?: string; isMandatory: boolean; isActive: boolean }[];
  templates: { channel: string; lang: string; subject: string; body: string; isTenantOverride: boolean }[];
}

export function NotificationSettings() {
  const { t, lang } = useI18n();
  const me = useMe();
  const [events, setEvents] = useState<EventDef[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [draft, setDraft] = useState({ channel: 'IN_APP', lang: 'ar', subject: '', body: '' });
  const [deliveries, setDeliveries] = useState<{ eventCode: string; channel: string; status: string; attempts: number; user: string; lastError?: string }[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [defaults, setDefaults] = useState<{ groupKey: string; mandatoryInApp: boolean; emailAvailable: boolean; inApp: string; email: string }[]>([]);
  const [preview, setPreview] = useState<{ subject: string; body: string } | null>(null);
  const load = useCallback(async () => {
    setEvents((await api<{ items: EventDef[] }>('GET', '/notification-events')).items);
    setDefaults((await api<{ items: typeof defaults }>('GET', '/notification-preferences/defaults')).items);
  }, []);
  useEffect(() => {
    void load();
    if (can(me, 'ntf.log.view')) void api<{ items: typeof deliveries }>('GET', '/notification-deliveries').then(r => setDeliveries(r.items));
  }, [load, me]);
  const ev = events.find(e => e.code === open);
  const act = async (f: () => Promise<unknown>) => {
    try { await f(); setNotice({ ok: 'Saved.' }); await load(); } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <>
      <section className="card">
        <h1>{t('Notification settings')}</h1>
        <Notice error={notice.error} ok={notice.ok} />
        <Table rows={events} columns={[
          { header: 'Event', cell: e => <button className="link" dir="ltr" onClick={() => setOpen(e.code)}>{e.code}</button> },
          { header: 'Name', cell: e => (lang === 'ar' ? e.nameAr ?? e.nameEn : e.nameEn ?? e.nameAr) ?? '' },
          { header: 'Severity', cell: e => t(e.severity) },
          { header: 'Mandatory', cell: e => e.isMandatory ? t('Yes') : t('No') },
          { header: 'Recipients', cell: e => e.rules.filter(r => r.isActive).map(r => r.role ?? r.permission).join(', ') },
        ]} />
      </section>
      <section className="card">
        <h2>{t('Default preferences of the account')}</h2>
        <p className="muted">{t('A user who has not chosen follows these; a mandatory group stays in the application.')}</p>
        <Table rows={defaults} columns={[
          { header: 'Group', cell: p => t(p.groupKey) },
          { header: 'In the application', cell: p => p.mandatoryInApp ? t('Always (mandatory)') : (
            <select value={p.inApp} onChange={e => void act(() => api('PUT', '/notification-preferences/defaults', { items: [{ groupKey: p.groupKey, channel: 'IN_APP', mode: e.target.value }] }))}>
              <option value="IMMEDIATE">{t('IMMEDIATE')}</option><option value="OFF">{t('OFF')}</option>
            </select>) },
          { header: 'E-mail', cell: p => p.emailAvailable ? (
            <select value={p.email} onChange={e => void act(() => api('PUT', '/notification-preferences/defaults', { items: [{ groupKey: p.groupKey, channel: 'EMAIL', mode: e.target.value }] }))}>
              <option value="IMMEDIATE">{t('IMMEDIATE')}</option><option value="DIGEST_DAILY">{t('DIGEST_DAILY')}</option>
              <option value="DIGEST_WEEKLY">{t('DIGEST_WEEKLY')}</option><option value="OFF">{t('OFF')}</option>
            </select>) : '—' },
        ]} />
      </section>
      {ev && (
        <section className="card">
          <h2 dir="ltr">{ev.code}</h2>
          <Table rows={ev.rules} columns={[
            { header: 'Recipient', cell: r => r.role ?? r.permission ?? '' },
            { header: 'Mandatory', cell: r => r.isMandatory ? t('Yes') : t('No') },
            { header: 'Status', cell: r => r.isMandatory ? t('ACTIVE') : (
              <button className="link" onClick={() => void act(() => api('PATCH', `/notification-events/${ev.code}/rules/${r.id}`, { isActive: !r.isActive }))}>
                {t(r.isActive ? 'Stop' : 'Activate')}
              </button>) },
          ]} />
          <p className="muted">{t('Placeholders')}: <span dir="ltr">{ev.placeholders.map(p => `{${p}}`).join(' ')}</span></p>
          <Table rows={ev.templates} columns={[
            { header: 'Channel', cell: x => t(x.channel) },
            { header: 'Language', cell: x => x.lang },
            { header: 'Subject', cell: x => x.subject },
            { header: 'Override', cell: x => x.isTenantOverride
              ? <button className="link" onClick={() => void act(() => api('DELETE', `/notification-events/${ev.code}/templates/${x.channel}/${x.lang}`))}>{t('Back to the default')}</button>
              : '' },
          ]} />
          <form className="stack" onSubmit={e => { e.preventDefault(); void act(() => api('PUT', `/notification-events/${ev.code}/templates/${draft.channel}/${draft.lang}`, { subject: draft.subject, body: draft.body })); }}>
            <div className="actions">
              <select value={draft.channel} onChange={e => setDraft({ ...draft, channel: e.target.value })}><option value="IN_APP">{t('IN_APP')}</option><option value="EMAIL">{t('EMAIL')}</option></select>
              <select value={draft.lang} onChange={e => setDraft({ ...draft, lang: e.target.value })}><option value="ar">العربية</option><option value="en">English</option></select>
            </div>
            <input placeholder={t('Subject')} value={draft.subject} onChange={e => setDraft({ ...draft, subject: e.target.value })} required />
            <textarea placeholder={t('Text')} value={draft.body} onChange={e => setDraft({ ...draft, body: e.target.value })} required rows={4} />
            <div className="actions">
              <button type="submit">{t('Save the text for this account')}</button>
              <button type="button" className="secondary" onClick={async () => {
                try { setPreview(await api<{ subject: string; body: string }>('POST', `/notification-events/${ev.code}/templates/${draft.channel}/${draft.lang}/preview`, { subject: draft.subject, body: draft.body })); setNotice({}); }
                catch (e) { setNotice({ error: message(e) }); }
              }}>{t('Preview')}</button>
              {draft.channel === 'EMAIL' && <button type="button" className="secondary" onClick={async () => {
                try {
                  const r = await api<{ sentTo: string }>('POST', `/notification-events/${ev.code}/templates/${draft.channel}/${draft.lang}/test`, { subject: draft.subject, body: draft.body });
                  setNotice({ ok: t('A test e-mail was sent to {to}.', { to: r.sentTo }) });
                } catch (e) { setNotice({ error: message(e) }); }
              }}>{t('Send me a test')}</button>}
            </div>
          </form>
          {preview && <div className="card"><strong>{preview.subject}</strong><p style={{ whiteSpace: 'pre-wrap' }}>{preview.body}</p></div>}
        </section>
      )}
      {deliveries.length > 0 && (
        <section className="card">
          <h2>{t('Deliveries')}</h2>
          <Table rows={deliveries} columns={[
            { header: 'Event', cell: d => <span dir="ltr">{d.eventCode}</span> },
            { header: 'Channel', cell: d => t(d.channel) },
            { header: 'User', cell: d => d.user },
            { header: 'Status', cell: d => <Chip s={d.status} /> },
            { header: 'Attempts', cell: d => d.attempts },
          ]} />
        </section>
      )}
    </>
  );
}
