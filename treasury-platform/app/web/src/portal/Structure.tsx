import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Notice, Table } from '../ui';
import { can, useMe } from './Portal';

// Screens 14 (ownership tab) and 15 (the change wizard) of spec 10, and the mismatch report (FR-ORG-015 to 018).
// The structure is confidential: a user who only requests (RQ) does not see it (owner default OQ-19).

interface Holder { id: string; code: string; nameAr: string; nameEn?: string; kind: string; company?: string }
interface Holding {
  holder: Holder; sharePercent: number; sharesCount?: number; layer: number; intermediate?: { id: string; nameAr: string; nameEn?: string };
  isBeneficialOwner: boolean; effectiveFrom: string; effectiveTo?: string;
}
interface Ownership { asOf: string; total: number; difference: number; status: string; current: Holding[]; planned: Holding[]; history: Holding[] }
interface Effective { holder: Holder; effectivePercent: number; direct: boolean; indirect: boolean; suggestBeneficialOwner: boolean }
interface Line { holder: string; label: string; sharePercent: string; sharesCount: string; layer: string; intermediate: string }

const name = (lang: string, x: { nameAr?: string; nameEn?: string }) => (lang === 'ar' ? x.nameAr : x.nameEn) ?? x.nameAr ?? x.nameEn ?? '';
const today = () => new Date().toISOString().slice(0, 10);

/** The structure tabs are for the users who manage or review it, not for a requester alone (OQ-19). */
export const seesStructure = (me: ReturnType<typeof useMe>) =>
  ['org.ownership.manage', 'org.company.manage', 'org.body.manage', 'org.grant.create', 'org.grant.approve', 'audit.view.treasury'].some(p => can(me, p));

function PartySearch({ onPick }: { onPick: (id: string, label: string) => void }) {
  const { t, lang } = useI18n();
  const [q, setQ] = useState('');
  const [found, setFound] = useState<{ id: string; partyCode: string; nameAr?: string; nameEn?: string }[]>([]);
  useEffect(() => {
    if (q.trim().length < 2) { setFound([]); return; }
    const timer = window.setTimeout(() => {
      void api<{ items: typeof found }>('GET', '/parties?q=' + encodeURIComponent(q.trim())).then(r => setFound(r.items.slice(0, 8))).catch(() => setFound([]));
    }, 250);
    return () => window.clearTimeout(timer);
  }, [q]);
  return (
    <div className="stack">
      <input aria-label={t('Find a person or an entity')} placeholder={t('Find a person or an entity')} value={q} onChange={e => setQ(e.target.value)} />
      {found.map(p => (
        <button key={p.id} type="button" className="link" onClick={() => { onPick(p.id, `${p.partyCode} · ${name(lang, p)}`); setQ(''); }}>
          <span dir="ltr">{p.partyCode}</span> · {name(lang, p)}
        </button>
      ))}
    </div>
  );
}

export function OwnershipPanel({ company }: { company: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [asOf, setAsOf] = useState(today());
  const [data, setData] = useState<Ownership | null>(null);
  const [effective, setEffective] = useState<{ items: Effective[]; warnings: string[] } | null>(null);
  const [wizard, setWizard] = useState(false);
  const load = useCallback(async () => {
    setData(await api<Ownership>('GET', `/companies/${company}/ownership?asOf=${asOf}`));
    setEffective(await api<{ items: Effective[]; warnings: string[] }>('GET', `/companies/${company}/ownership/effective?asOf=${asOf}`));
  }, [company, asOf]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return null;
  const rows = (list: Holding[]) => (
    <Table rows={list} columns={[
      { header: 'Holder', cell: h => <Link to={h.holder.company ? `/companies/${h.holder.company}` : `/parties/${h.holder.id}`}>{name(lang, h.holder)}</Link> },
      { header: 'Share', cell: h => <span dir="ltr">{h.sharePercent}%</span> },
      { header: 'Path', cell: h => h.layer === 1 ? t('Direct') : `${t('Through')} ${h.intermediate ? name(lang, h.intermediate) : ''}` },
      { header: 'From', cell: h => <span dir="ltr">{h.effectiveFrom}</span> },
      { header: 'To', cell: h => <span dir="ltr">{h.effectiveTo ?? '—'}</span> },
    ]} />
  );
  return (
    <>
      <section className="card">
        <h2>{t('Ownership')}</h2>
        <div className="actions">
          <label>{t('On the date')} <input type="date" value={asOf} onChange={e => setAsOf(e.target.value)} /></label>
          {can(me, 'org.ownership.manage') && <button onClick={() => setWizard(true)}>{t('Change the ownership')}</button>}
        </div>
        <p className={data.total === 100 ? 'muted' : 'error'}>
          {t('Direct holdings total')}: <span dir="ltr">{data.total}%</span>
          {data.total !== 100 && <> · {t('Difference')}: <span dir="ltr">{data.difference}%</span></>}
          {' · '}{t(data.status)}
        </p>
        {rows(data.current)}
      </section>
      {wizard && <OwnershipWizard company={company} current={data.current} onDone={async () => { setWizard(false); await load(); }} />}
      {data.planned.length > 0 && <section className="card"><h3>{t('Planned')}</h3>{rows(data.planned)}</section>}
      {effective && (
        <section className="card">
          <h3>{t('Effective ownership')}</h3>
          {effective.warnings.map(w => <p key={w} className="error">{w}</p>)}
          <Table rows={effective.items} columns={[
            { header: 'Holder', cell: e => name(lang, e.holder) },
            { header: 'Effective share', cell: e => <span dir="ltr">{e.effectivePercent}%</span> },
            { header: 'Path', cell: e => [e.direct ? t('Direct') : '', e.indirect ? t('Indirect') : ''].filter(Boolean).join(' + ') },
            { header: 'Beneficial owner', cell: e => e.suggestBeneficialOwner ? t('Suggested (25% or more)') : '' },
          ]} />
        </section>
      )}
      {data.history.length > 0 && <section className="card"><h3>{t('History')}</h3>{rows(data.history)}</section>}
    </>
  );
}

function OwnershipWizard({ company, current, onDone }: { company: string; current: Holding[]; onDone: () => Promise<void> }) {
  const { t, lang } = useI18n();
  const [from, setFrom] = useState(today());
  const [lines, setLines] = useState<Line[]>(current.map(h => ({
    holder: h.holder.id, label: name(lang, h.holder), sharePercent: String(h.sharePercent), sharesCount: h.sharesCount ? String(h.sharesCount) : '',
    layer: String(h.layer), intermediate: h.intermediate?.id ?? '',
  })));
  const [retroactive, setRetroactive] = useState(false);
  const [reason, setReason] = useState('');
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const total = lines.filter(l => l.layer === '1').reduce((s, l) => s + (Number(l.sharePercent) || 0), 0);
  const set = (i: number, patch: Partial<Line>) => setLines(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)));
  const body = (dryRun: boolean) => ({
    effectiveFrom: from, dryRun, retroactive, reason: reason || undefined,
    holdings: lines.map(l => ({
      holder: l.holder, sharePercent: l.sharePercent ? Number(l.sharePercent) : undefined, sharesCount: l.sharesCount ? Number(l.sharesCount) : undefined,
      layer: Number(l.layer), intermediate: l.intermediate || undefined,
    })),
  });
  const send = async (dryRun: boolean) => {
    try {
      await api('POST', `/companies/${company}/ownership/changes`, body(dryRun));
      if (dryRun) setNotice({ ok: 'The change is valid.' });
      else await onDone();
    } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <section className="card">
      <h2>{t('Change the ownership')}</h2>
      <Notice error={notice.error} ok={notice.ok} />
      <label>{t('Effective from')} <input type="date" value={from} onChange={e => setFrom(e.target.value)} /></label>
      <Table rows={lines.map((l, i) => ({ l, i }))} columns={[
        { header: 'Holder', cell: r => r.l.label },
        { header: 'Share %', cell: r => <input aria-label={`${t('Share %')} ${r.l.label}`} dir="ltr" value={r.l.sharePercent} onChange={e => set(r.i, { sharePercent: e.target.value })} /> },
        { header: 'Shares', cell: r => <input aria-label={`${t('Shares')} ${r.l.label}`} dir="ltr" value={r.l.sharesCount} onChange={e => set(r.i, { sharesCount: e.target.value })} /> },
        { header: 'Path', cell: r => r.l.layer === '1' ? t('Direct') : t('Indirect') },
        { header: '', cell: r => <button type="button" className="link" onClick={() => setLines(lines.filter((_, j) => j !== r.i))}>{t('Remove')}</button> },
      ]} />
      <PartySearch onPick={(id, label) => setLines([...lines, { holder: id, label, sharePercent: '', sharesCount: '', layer: '1', intermediate: '' }])} />
      <p className={Math.abs(total - 100) < 0.0000005 ? 'muted' : 'error'}>
        {t('Total')}: <span dir="ltr">{Number(total.toFixed(6))}%</span> · {t('Difference')}: <span dir="ltr">{Number((100 - total).toFixed(6))}%</span>
      </p>
      <label><input type="checkbox" checked={retroactive} onChange={e => setRetroactive(e.target.checked)} /> {t('Retroactive correction')}</label>
      {retroactive && <input placeholder={t('Reason')} value={reason} onChange={e => setReason(e.target.value)} />}
      <div className="actions">
        <button type="button" className="secondary" onClick={() => void send(true)}>{t('Check')}</button>
        <button type="button" onClick={() => void send(false)}>{t('Save the change')}</button>
      </div>
    </section>
  );
}

/** FR-ORG-016: the companies whose direct holdings do not total 100% on the date. */
export function OwnershipMismatch() {
  const { t, lang } = useI18n();
  const [asOf, setAsOf] = useState(today());
  const [items, setItems] = useState<{ company: string; code: string; nameAr: string; nameEn?: string; total: number; difference: number; recorded: boolean }[]>([]);
  useEffect(() => { void api<{ items: typeof items }>('GET', `/reports/ownership-mismatch?asOf=${asOf}`).then(r => setItems(r.items)); }, [asOf]);
  return (
    <section className="card">
      <h1>{t('Ownership that does not total 100%')}</h1>
      <label>{t('On the date')} <input type="date" value={asOf} onChange={e => setAsOf(e.target.value)} /></label>
      <Table rows={items} columns={[
        { header: 'Code', cell: r => <Link to={`/companies/${r.company}`} dir="ltr">{r.code}</Link> },
        { header: 'Name', cell: r => name(lang, r) },
        { header: 'Total', cell: r => <span dir="ltr">{r.total}%</span> },
        { header: 'Difference', cell: r => <span dir="ltr">{r.difference}%</span> },
        { header: 'Recorded', cell: r => r.recorded ? t('Yes') : t('Not recorded yet') },
      ]} />
    </section>
  );
}

// ---------- screens 14 (governance and authorities tabs), 16, 17 and 20 ----------

interface Member {
  id: string; party: { id: string; code: string; nameAr: string; nameEn?: string }; position: { code: string; nameAr: string; nameEn?: string };
  termStart: string; termEnd?: string; resignedOn?: string; state: string;
}
interface Body { id: string; bodyType: string; nameAr?: string; nameEn?: string; termStart?: string; termEnd?: string; status: string; members: Member[] }
interface Grant {
  id: string; granteeKind: string; holder: { party?: string; nameAr?: string; nameEn?: string; bodyType?: string; position?: string };
  powerType: { code: string; nameAr: string; nameEn?: string }; institution?: { code: string }; ceiling?: { amount: number; currency: string };
  requiresJoint: boolean; jointNote?: string; validFrom: string; validTo?: string; status: string; state: string; createdByYou: boolean;
}

export function GovernancePanel({ company }: { company: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [bodies, setBodies] = useState<Body[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [draft, setDraft] = useState({ bodyType: 'BOARD_OF_DIRECTORS', termStart: today(), termEnd: '', replace: false, carryMembers: true });
  const [member, setMember] = useState<{ body: string; party: string; label: string; position: string; termStart: string }>({ body: '', party: '', label: '', position: 'BOARD_MEMBER', termStart: today() });
  const load = useCallback(async () => setBodies((await api<{ items: Body[] }>('GET', `/companies/${company}/bodies?includeClosed=true`)).items), [company]);
  useEffect(() => { void load(); }, [load]);
  const act = async (f: () => Promise<unknown>) => { try { await f(); setNotice({ ok: 'Saved.' }); await load(); } catch (e) { setNotice({ error: message(e) }); } };
  const manage = can(me, 'org.body.manage');
  return (
    <>
      <Notice error={notice.error} ok={notice.ok} />
      {bodies.map(b => (
        <section key={b.id} className="card">
          <h3>{t(b.bodyType)} {b.status === 'CLOSED' && <small className="muted">({t('CLOSED')})</small>}</h3>
          <p className="muted" dir="ltr">{b.termStart ?? '—'} → {b.termEnd ?? '—'}</p>
          <Table rows={b.members} columns={[
            { header: 'Member', cell: m => <Link to={`/parties/${m.party.id}`}>{name(lang, m.party)}</Link> },
            { header: 'Position', cell: m => name(lang, m.position) },
            { header: 'From', cell: m => <span dir="ltr">{m.termStart}</span> },
            { header: 'To', cell: m => <span dir="ltr">{m.resignedOn ?? m.termEnd ?? '—'}</span> },
            { header: 'Status', cell: m => t(m.state) },
            { header: '', cell: m => manage && b.status === 'ACTIVE' && m.state === 'ACTIVE'
              ? <button className="link" onClick={() => void act(() => api('POST', `/bodies/${b.id}/members/${m.id}/actions/resign`, { on: today() }))}>{t('Resigned today')}</button> : '' },
          ]} />
          {manage && b.status === 'ACTIVE' && (
            <div className="actions">
              {member.body === b.id && member.party
                ? <span>{member.label}</span>
                : <PartySearch onPick={(id, label) => setMember({ ...member, body: b.id, party: id, label })} />}
              <input aria-label={t('Position')} dir="ltr" value={member.position} onChange={e => setMember({ ...member, position: e.target.value.toUpperCase() })} />
              <input type="date" aria-label={t('From')} value={member.termStart} onChange={e => setMember({ ...member, termStart: e.target.value })} />
              <button disabled={member.body !== b.id || !member.party} onClick={() => void act(async () => {
                await api('POST', `/bodies/${b.id}/members`, { party: member.party, position: member.position, termStart: member.termStart });
                setMember({ ...member, party: '', label: '' });
              })}>{t('Add the member')}</button>
            </div>
          )}
        </section>
      ))}
      {manage && (
        <section className="card">
          <h3>{t('New governing body')}</h3>
          <div className="actions">
            <select aria-label={t('Body')} value={draft.bodyType} onChange={e => setDraft({ ...draft, bodyType: e.target.value })}>
              {['BOARD_OF_DIRECTORS', 'BOARD_OF_MANAGERS', 'MANAGEMENT', 'GENERAL_ASSEMBLY'].map(x => <option key={x} value={x}>{t(x)}</option>)}
            </select>
            <input type="date" aria-label={t('From')} value={draft.termStart} onChange={e => setDraft({ ...draft, termStart: e.target.value })} />
            <input type="date" aria-label={t('To')} value={draft.termEnd} onChange={e => setDraft({ ...draft, termEnd: e.target.value })} />
            <label><input type="checkbox" checked={draft.replace} onChange={e => setDraft({ ...draft, replace: e.target.checked })} /> {t('Replace the active body')}</label>
            <button onClick={() => void act(() => api('POST', `/companies/${company}/bodies`, { ...draft, termEnd: draft.termEnd || undefined }))}>{t('Create')}</button>
          </div>
        </section>
      )}
    </>
  );
}

export function GrantsPanel({ company }: { company: string }) {
  const { t, lang } = useI18n();
  const me = useMe();
  const [grants, setGrants] = useState<Grant[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [q, setQ] = useState({ powerType: 'BORROW_FACILITIES', amount: '', currency: 'SAR', date: today() });
  const [answer, setAnswer] = useState<{ items: { grant: Grant; flags: string[] }[]; suggestion?: string } | null>(null);
  const [draft, setDraft] = useState({ party: '', label: '', powerType: 'SIGN_CONTRACTS', ceilingAmount: '', ceilingCurrency: 'SAR', validFrom: today(), validTo: '', exceptionReason: '' });
  const load = useCallback(async () => setGrants((await api<{ items: Grant[] }>('GET', `/companies/${company}/grants`)).items), [company]);
  useEffect(() => { void load(); }, [load]);
  const act = async (f: () => Promise<unknown>) => { try { await f(); setNotice({ ok: 'Saved.' }); await load(); } catch (e) { setNotice({ error: message(e) }); } };
  const holder = (g: Grant) => (g.granteeKind === 'BODY' ? t(g.holder.bodyType ?? '') : name(lang, g.holder));
  return (
    <>
      <section className="card">
        <h2>{t('Authority grants')}</h2>
        <Notice error={notice.error} ok={notice.ok} />
        <Table rows={grants} columns={[
          { header: 'Holder', cell: g => holder(g) },
          { header: 'Power', cell: g => name(lang, g.powerType) },
          { header: 'Ceiling', cell: g => g.ceiling ? <span dir="ltr">{g.ceiling.amount} {g.ceiling.currency}</span> : t('Not specified') },
          { header: 'Joint', cell: g => g.requiresJoint ? (g.jointNote ?? t('Yes')) : '' },
          { header: 'Period', cell: g => <span dir="ltr">{g.validFrom} → {g.validTo ?? '—'}</span> },
          { header: 'Status', cell: g => t(g.state) },
          { header: '', cell: g => (
            <span className="actions">
              {g.status === 'DRAFT' && can(me, 'org.grant.create') && <button className="link" onClick={() => void act(() => api('POST', `/grants/${g.id}/actions/submit`, {}))}>{t('Send for approval')}</button>}
              {g.status === 'PENDING_APPROVAL' && can(me, 'org.grant.approve') && !g.createdByYou && <>
                <button className="link" onClick={() => void act(() => api('POST', `/grants/${g.id}/actions/approve`, {}))}>{t('Approve')}</button>
                <button className="link" onClick={() => { const reason = window.prompt(t('Reason')); if (reason) void act(() => api('POST', `/grants/${g.id}/actions/reject`, { reason })); }}>{t('Reject')}</button>
              </>}
              {g.status === 'ACTIVE' && can(me, 'org.grant.approve') && (
                <button className="link" onClick={() => { const reason = window.prompt(t('Reason')); if (reason) void act(() => api('POST', `/grants/${g.id}/actions/revoke`, { reason })); }}>{t('Revoke')}</button>)}
            </span>) },
        ]} />
      </section>
      {can(me, 'org.grant.create') && (
        <section className="card">
          <h3>{t('New grant by power of attorney')}</h3>
          <div className="actions">
            {draft.party ? <span>{draft.label}</span> : <PartySearch onPick={(id, label) => setDraft({ ...draft, party: id, label })} />}
            <input aria-label={t('Power')} dir="ltr" value={draft.powerType} onChange={e => setDraft({ ...draft, powerType: e.target.value.toUpperCase() })} />
            <input aria-label={t('Ceiling')} dir="ltr" value={draft.ceilingAmount} onChange={e => setDraft({ ...draft, ceilingAmount: e.target.value })} />
            <input type="date" aria-label={t('From')} value={draft.validFrom} onChange={e => setDraft({ ...draft, validFrom: e.target.value })} />
            <input placeholder={t('Exception instead of the source document')} value={draft.exceptionReason} onChange={e => setDraft({ ...draft, exceptionReason: e.target.value })} />
            <button disabled={!draft.party} onClick={() => void act(() => api('POST', `/companies/${company}/grants`, {
              granteeKind: 'PARTY', party: draft.party, powerType: draft.powerType, ceilingAmount: draft.ceilingAmount ? Number(draft.ceilingAmount) : undefined,
              ceilingCurrency: draft.ceilingAmount ? draft.ceilingCurrency : undefined, validFrom: draft.validFrom, exceptionReason: draft.exceptionReason || undefined,
            }))}>{t('Create')}</button>
          </div>
        </section>
      )}
      <section className="card">
        <h3>{t('Who may act?')}</h3>
        <div className="actions">
          <input aria-label={t('Power')} dir="ltr" value={q.powerType} onChange={e => setQ({ ...q, powerType: e.target.value.toUpperCase() })} />
          <input aria-label={t('Amount')} dir="ltr" value={q.amount} onChange={e => setQ({ ...q, amount: e.target.value })} />
          <input aria-label={t('Currency')} dir="ltr" value={q.currency} onChange={e => setQ({ ...q, currency: e.target.value.toUpperCase() })} />
          <input type="date" aria-label={t('On the date')} value={q.date} onChange={e => setQ({ ...q, date: e.target.value })} />
          <button onClick={() => void api<typeof answer>('GET', `/companies/${company}/grants/query?powerType=${q.powerType}&date=${q.date}${q.amount ? `&amount=${q.amount}&currency=${q.currency}` : ''}`)
            .then(setAnswer).catch(e => setNotice({ error: message(e) }))}>{t('Ask')}</button>
        </div>
        {answer && <>
          <Table rows={answer.items} columns={[
            { header: 'Holder', cell: r => holder(r.grant) },
            { header: 'Ceiling', cell: r => r.grant.ceiling ? <span dir="ltr">{r.grant.ceiling.amount} {r.grant.ceiling.currency}</span> : t('Not specified') },
            { header: 'Conditions', cell: r => r.flags.map(x => t(x)).join(' · ') + (r.grant.jointNote ? ` · ${r.grant.jointNote}` : '') },
          ]} />
          {answer.suggestion && <p className="error">{t(answer.suggestion)}</p>}
        </>}
      </section>
    </>
  );
}

/** FR-ORG-029 (screen 20): each gap with its count and the companies to open. */
export function StructureIntegrity() {
  const { t, lang } = useI18n();
  const [items, setItems] = useState<{ item: string; count: number; rows: { company: string; code: string; nameAr: string; nameEn?: string; detail?: string }[] }[]>([]);
  useEffect(() => { void api<{ items: typeof items }>('GET', '/reports/structure-integrity').then(r => setItems(r.items)); }, []);
  return (
    <section className="card">
      <h1>{t('Structure integrity')}</h1>
      {items.length === 0 && <p className="muted">{t('Nothing here yet.')}</p>}
      {items.map(i => (
        <div key={i.item}>
          <h3>{t(i.item)} ({i.count})</h3>
          <Table rows={i.rows} columns={[
            { header: 'Code', cell: r => <Link to={`/companies/${r.company}`} dir="ltr">{r.code}</Link> },
            { header: 'Name', cell: r => name(lang, r) },
            { header: 'Detail', cell: r => <span dir="ltr">{r.detail ?? ''}</span> },
          ]} />
        </div>
      ))}
    </section>
  );
}
