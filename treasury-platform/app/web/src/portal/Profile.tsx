import { useCallback, useEffect, useState } from 'react';
import { api, ApiError } from '../api';
import { useFormat, useI18n, type Lang } from '../i18n';
import { Field, Form, Notice, Select, Table, useWithStepUp } from '../ui';
import { useMe } from './Portal';

interface Session { id: string; createdAt: string; lastSeenAt: string; ipAddress?: string; userAgent?: string }

// SCR-PLT-15
export function Profile() {
  const me = useMe();
  const { t, setLang } = useI18n();
  const fmt = useFormat();
  const withStepUp = useWithStepUp();
  const [prefs, setPrefs] = useState({ preferredLanguage: me.user.preferredLanguage ?? 'en', digitsPreference: 'WESTERN' });
  const [pw, setPw] = useState({ currentPassword: '', newPassword: '', again: '' });
  const [ok, setOk] = useState<string | null>(null);
  const [sessions, setSessions] = useState<{ items: Session[]; current: string | null }>({ items: [], current: null });
  const load = useCallback(async () => setSessions(await api<{ items: Session[]; current: string | null }>('GET', '/me/sessions')), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <>
      <Form title="Preferences" submit="Save" onSubmit={async () => {
        await api('PATCH', '/me/preferences', prefs);
        setLang(prefs.preferredLanguage as Lang);
      }}>
        <Select label="Language" value={prefs.preferredLanguage} onChange={v => setPrefs({ ...prefs, preferredLanguage: v })}
          options={[{ value: 'en', label: 'English' }, { value: 'ar', label: 'العربية' }]} />
        <Select label="Digits" value={prefs.digitsPreference} onChange={v => setPrefs({ ...prefs, digitsPreference: v })}
          options={[{ value: 'WESTERN', label: '0123' }, { value: 'ARABIC_INDIC', label: '٠١٢٣' }]} />
      </Form>
      <Form title="Change your password" submit="Change password" onSubmit={async () => {
        setOk(null);
        if (pw.newPassword !== pw.again) throw new ApiError({ status: 422, code: 'MISMATCH', title: 'The two passwords differ.' });
        const r = await withStepUp('Changing your password needs a fresh code.', code =>
          api('POST', '/me/password', { currentPassword: pw.currentPassword, newPassword: pw.newPassword, stepUpCode: code }).then(() => true));
        if (r) { setOk('Your password is changed. Your other sessions have ended.'); setPw({ currentPassword: '', newPassword: '', again: '' }); await load(); }
      }}>
        <Field label="Current password" value={pw.currentPassword} onChange={v => setPw({ ...pw, currentPassword: v })} type="password" autoComplete="current-password" />
        <Field label="New password" value={pw.newPassword} onChange={v => setPw({ ...pw, newPassword: v })} type="password" autoComplete="new-password" />
        <Field label="Repeat the password" value={pw.again} onChange={v => setPw({ ...pw, again: v })} type="password" autoComplete="new-password" />
        <Notice ok={ok} />
      </Form>
      <section className="card">
        <h2>{t('Your sessions')}</h2>
        <Table rows={sessions.items} columns={[
          { header: 'Started', cell: s => fmt.dateTime(s.createdAt) },
          { header: 'Last seen', cell: s => fmt.dateTime(s.lastSeenAt) },
          { header: 'Browser', cell: s => <small dir="ltr">{s.userAgent}</small> },
          { header: '', cell: s => s.id === sessions.current ? t('This session')
            : <button className="link" onClick={async () => { await api('DELETE', `/me/sessions/${s.id}`); await load(); }}>{t('End')}</button> },
        ]} />
      </section>
    </>
  );
}
