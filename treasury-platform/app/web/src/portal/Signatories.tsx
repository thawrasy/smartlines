import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Notice, Table } from '../ui';
import { can, useMe } from './Portal';
import { PartySearch } from './Structure';

// SCR-ACC-02 to 04 (spec 11): the signatories of a relationship with their status and period, their authorities on the
// bank or an account, and the actions of their lifecycle. A change of an authority is a new row (FR-ACC-017).

interface Authority {
  id: string; account?: { id: string; mask: string }; operationType: string; ceilingMode: string; maxPerTransaction?: number; dailyLimit?: number;
  currency?: string; isJoint: boolean; jointClasses: string[]; validFrom: string; validTo?: string; state: string;
}
interface Signatory {
  id: string; party: { id: string; nameAr: string; nameEn?: string }; signatureClass: string; validFrom: string; validTo?: string; status: string;
  hasSpecimen: boolean; documentExpiry?: string;
}

const name = (lang: string, x: { nameAr?: string; nameEn?: string }) => (lang === 'ar' ? x.nameAr : x.nameEn) ?? x.nameAr ?? x.nameEn ?? '';
const today = () => new Date().toISOString().slice(0, 10);

export function SignatoriesPanel({ relationship }: { relationship: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [items, setItems] = useState<{ signatory: Signatory; authorities: Authority[] }[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [draft, setDraft] = useState({ party: '', label: '', signatureClass: 'A', validFrom: today(), validTo: '', authorizationDocument: '' });
  const [auth, setAuth] = useState({ signatory: '', operationType: 'TRANSFERS', ceilingMode: 'LIMITED', maxPerTransaction: '', currency: 'SAR', validFrom: today() });
  const load = useCallback(async () => {
    try { setItems((await api<{ items: typeof items }>('GET', `/relationships/${relationship}/signatories`)).items); } catch { setItems([]); }
  }, [relationship]);
  useEffect(() => { void load(); }, [load]);
  const act = async (f: () => Promise<unknown>) => { try { await f(); setNotice({ ok: 'Saved.' }); await load(); } catch (e) { setNotice({ error: message(e) }); } };
  if (!can(me, 'sig.view')) return null;
  const manage = can(me, 'sig.manage');
  return (
    <section className="card">
      <h2>{t('Signatories')}</h2>
      <Notice error={notice.error} ok={notice.ok} />
      {items.map(({ signatory: s, authorities }) => (
        <div key={s.id} className="stack">
          <h3>{name(lang, s.party)} · {t('Class')} {s.signatureClass} · {t(s.status)}</h3>
          <p className="muted" dir="ltr">{s.validFrom} → {s.validTo ?? '—'}{s.documentExpiry ? ` · ${s.documentExpiry}` : ''}</p>
          <Table rows={authorities} columns={[
            { header: 'Operation', cell: a => t(a.operationType) },
            { header: 'Account', cell: a => a.account ? <span dir="ltr">{a.account.mask}</span> : t('The whole bank') },
            { header: 'Ceiling', cell: a => a.ceilingMode === 'LIMITED' ? <span dir="ltr">{a.maxPerTransaction ?? '—'} / {a.dailyLimit ?? '—'} {a.currency}</span> : t(a.ceilingMode) },
            { header: 'Joint', cell: a => a.isJoint ? a.jointClasses.join(', ') || t('Yes') : '' },
            { header: 'Period', cell: a => <span dir="ltr">{a.validFrom} → {a.validTo ?? '—'}</span> },
            { header: 'Status', cell: a => t(a.state) },
          ]} />
          {manage && (
            <div className="actions">
              {s.status === 'ACTIVE' && <button className="link" onClick={() => void act(() => api('POST', `/signatories/${s.id}/actions/suspend`, {}))}>{t('Suspend')}</button>}
              {s.status === 'SUSPENDED' && <button className="link" onClick={() => void act(() => api('POST', `/signatories/${s.id}/actions/resume`, {}))}>{t('Resume')}</button>}
              {['PENDING', 'ACTIVE', 'SUSPENDED'].includes(s.status) && (
                <button className="link" onClick={() => { const reason = window.prompt(t('Reason')); if (reason) void act(() => api('POST', `/signatories/${s.id}/actions/revoke`, { reason })); }}>{t('Revoke')}</button>)}
              <button className="link" onClick={() => setAuth({ ...auth, signatory: s.id })}>{t('Add an authority')}</button>
            </div>
          )}
          {auth.signatory === s.id && (
            <div className="actions">
              <input aria-label={t('Operation')} dir="ltr" value={auth.operationType} onChange={e => setAuth({ ...auth, operationType: e.target.value.toUpperCase() })} />
              <select aria-label={t('Ceiling')} value={auth.ceilingMode} onChange={e => setAuth({ ...auth, ceilingMode: e.target.value })}>
                {['LIMITED', 'UNLIMITED', 'UNSPECIFIED'].map(m => <option key={m} value={m}>{t(m)}</option>)}
              </select>
              {auth.ceilingMode === 'LIMITED' && <>
                <input aria-label={t('Amount')} dir="ltr" value={auth.maxPerTransaction} onChange={e => setAuth({ ...auth, maxPerTransaction: e.target.value })} />
                <input aria-label={t('Currency')} dir="ltr" value={auth.currency} onChange={e => setAuth({ ...auth, currency: e.target.value.toUpperCase() })} />
              </>}
              <input type="date" aria-label={t('From')} value={auth.validFrom} onChange={e => setAuth({ ...auth, validFrom: e.target.value })} />
              <button onClick={() => void act(async () => {
                await api('POST', `/signatories/${s.id}/authorities`, {
                  operationType: auth.operationType, ceilingMode: auth.ceilingMode, validFrom: auth.validFrom,
                  maxPerTransaction: auth.ceilingMode === 'LIMITED' && auth.maxPerTransaction ? Number(auth.maxPerTransaction) : undefined,
                  currency: auth.ceilingMode === 'LIMITED' ? auth.currency : undefined,
                });
                setAuth({ ...auth, signatory: '' });
              })}>{t('Save')}</button>
            </div>
          )}
        </div>
      ))}
      {items.length === 0 && <p className="muted">{t('Nothing here yet.')}</p>}
      {manage && (
        <div className="actions">
          {draft.party ? <span>{draft.label}</span> : <PartySearch onPick={(id, label) => setDraft({ ...draft, party: id, label })} />}
          <input aria-label={t('Class')} dir="ltr" value={draft.signatureClass} onChange={e => setDraft({ ...draft, signatureClass: e.target.value.toUpperCase() })} />
          <input type="date" aria-label={t('From')} value={draft.validFrom} onChange={e => setDraft({ ...draft, validFrom: e.target.value })} />
          <input type="date" aria-label={t('To')} value={draft.validTo} onChange={e => setDraft({ ...draft, validTo: e.target.value })} />
          <input aria-label={t('Authorisation document')} placeholder={t('Authorisation document')} dir="ltr" value={draft.authorizationDocument}
            onChange={e => setDraft({ ...draft, authorizationDocument: e.target.value })} />
          <button disabled={!draft.party} onClick={() => void act(async () => {
            await api('POST', `/relationships/${relationship}/signatories`, {
              party: draft.party, signatureClass: draft.signatureClass, validFrom: draft.validFrom, validTo: draft.validTo || undefined,
              authorizationDocument: draft.authorizationDocument || undefined,
            });
            setDraft({ ...draft, party: '', label: '' });
          })}>{t('Add the signatory')}</button>
        </div>
      )}
    </section>
  );
}
