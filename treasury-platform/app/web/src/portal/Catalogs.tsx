import { useCallback, useEffect, useState } from 'react';
import { api, downloadGet, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';

// SCR-CAT-01 to 04: one screen for every catalogue (FR-CAT-005): add, edit, order, deactivate with where-used first,
// the inactive items on request; the lookup lists and the tenant's currencies (FR-CAT-020, FR-CAT-023).

interface Item {
  id: string; code: string; nameAr: string; nameEn?: string; description?: string; isActive: boolean; isSystem: boolean; isLocked: boolean;
  sortOrder: number; externalCode?: string; fromDefaults: boolean; etag: string; fields: Record<string, unknown>;
}
interface Kind { kind: string; canManage: boolean }

const KINDS: Record<string, string> = {
  'institution-types': 'Institution types', 'account-types': 'Account types', 'legal-entity-types': 'Legal forms', 'document-types': 'Document types',
  positions: 'Positions', 'power-types': 'Power types', 'operation-types': 'Operation types', 'product-categories': 'Product categories',
  products: 'Products', 'fee-types': 'Fee types', 'financing-types': 'Financing types', 'facility-types': 'Facility types', 'limit-types': 'Limit types',
  'collateral-types': 'Collateral types', 'obligation-types': 'Obligation types',
};

const LINKS: Record<string, { link: string; label: string; target: string }[]> = {
  products: [{ link: 'fee-types', label: 'Allowed fee types', target: 'fee-types' }, { link: 'financing-types', label: 'Allowed financing types', target: 'financing-types' }],
  'limit-types': [{ link: 'products', label: 'Allowed products', target: 'products' }],
  'operation-types': [{ link: 'power-types', label: 'Power types', target: 'power-types' }],
};

const text = (v: unknown) => v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);

/** The value typed for a field, back to the type the catalogue holds. */
function parse(before: unknown, raw: string): unknown {
  if (raw === '') return null;
  if (typeof before === 'boolean') return raw === 'true';
  if (typeof before === 'number') return Number(raw);
  if (typeof before === 'object' && before !== null) { try { return JSON.parse(raw); } catch { return raw; } }
  return raw;
}

function ItemEditor({ path, item, canManage, onDone }: { path: string; item: Item; canManage: boolean; onDone: () => Promise<void> }) {
  const { t } = useI18n();
  const [draft, setDraft] = useState({ nameAr: item.nameAr, nameEn: item.nameEn ?? '', description: item.description ?? '', externalCode: item.externalCode ?? '' });
  const [fields, setFields] = useState<Record<string, string>>(Object.fromEntries(Object.entries(item.fields).map(([k, v]) => [k, text(v)])));
  const [usage, setUsage] = useState<{ total: number; items: { table: string; count: number }[] } | null>(null);
  const [confirm, setConfirm] = useState(false);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const patch = async (body: Record<string, unknown>) => {
    setNotice({});
    try { await api('PATCH', `${path}/items/${item.id}`, body, item.etag); await onDone(); setNotice({ ok: 'Saved.' }); }
    catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <section className="card">
      <h2 dir="ltr">{item.code}</h2>
      <p className="muted">
        {item.isSystem ? t('From the defaults: its code is fixed.') : t('An item of this account.')} {item.isLocked && t('Locked: it stays active.')}
      </p>
      <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
      <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} required={false} />
      <Field label="Description" value={draft.description} onChange={v => setDraft({ ...draft, description: v })} required={false} />
      <Field label="External code" value={draft.externalCode} onChange={v => setDraft({ ...draft, externalCode: v })} required={false} />
      {Object.keys(item.fields).map(k => (
        <Field key={k} label={k} value={fields[k] ?? ''} onChange={v => setFields({ ...fields, [k]: v })} required={false} />
      ))}
      {canManage && (
        <div className="actions">
          <button onClick={() => void patch({
            ...draft, fields: Object.fromEntries(Object.entries(fields).filter(([k, v]) => v !== text(item.fields[k])).map(([k, v]) => [k, parse(item.fields[k], v)])),
            confirmImpact: confirm || undefined,
          })}>{t('Save changes')}</button>
          {item.isActive && !item.isLocked && (usage === null
            ? <button className="secondary" onClick={async () => setUsage(await api('GET', `${path}/items/${item.id}/usage`))}>{t('Deactivate')}</button>
            : <button className="secondary" onClick={() => void patch({ isActive: false })}>{t('Deactivate anyway ({n} uses)', { n: usage.total })}</button>)}
          {!item.isActive && <button className="secondary" onClick={() => void patch({ isActive: true })}>{t('Activate')}</button>}
          <label><input type="checkbox" checked={confirm} onChange={e => setConfirm(e.target.checked)} /> {t('I confirm the change of a flag with effect (treasury manager)')}</label>
        </div>
      )}
      {usage && <Table rows={usage.items} columns={[{ header: 'Used in', cell: u => <code dir="ltr">{u.table}</code> }, { header: 'Rows', cell: u => u.count }]} />}
      <Notice ok={notice.ok} error={notice.error} />
    </section>
  );
}

function Links({ kind, item, canManage }: { kind: string; item: Item; canManage: boolean }) {
  const { t } = useI18n();
  const [state, setState] = useState<Record<string, string>>({});
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const links = LINKS[kind] ?? [];
  useEffect(() => {
    void Promise.all(links.map(async l => [l.link, (await api<{ items: { code: string }[] }>('GET', `/catalogs/${kind}/items/${item.id}/${l.link}`)).items.map(i => i.code).join(', ')] as const))
      .then(r => setState(Object.fromEntries(r)));
  }, [kind, item.id]);   // eslint-disable-line react-hooks/exhaustive-deps
  if (links.length === 0) return null;
  return (
    <section className="card">
      {links.map(l => (
        <div key={l.link}>
          <Field label={l.label} value={state[l.link] ?? ''} onChange={v => setState({ ...state, [l.link]: v })} required={false} hint="Codes, separated by commas." />
          {canManage && <button className="secondary" onClick={async () => {
            setNotice({});
            try {
              await api('PUT', `/catalogs/${kind}/items/${item.id}/${l.link}`, { codes: (state[l.link] ?? '').split(',').map(s => s.trim()).filter(Boolean) });
              setNotice({ ok: 'Saved.' });
            } catch (e) { setNotice({ error: message(e) }); }
          }}>{t('Save')}</button>}
        </div>
      ))}
      <Notice ok={notice.ok} error={notice.error} />
    </section>
  );
}

function CatalogList({ path, kind, canManage, allowAdd = true }: { path: string; kind: string; canManage: boolean; allowAdd?: boolean }) {
  const { t, lang } = useI18n();
  const [items, setItems] = useState<Item[]>([]);
  const [showInactive, setShowInactive] = useState(false);
  const [q, setQ] = useState('');
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState({ code: '', nameAr: '', nameEn: '' });
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    const params = new URLSearchParams();
    if (showInactive && canManage) params.set('includeInactive', 'true');
    if (q) params.set('q', q);
    setItems((await api<{ items: Item[] }>('GET', `${path}${params.size ? '?' + params : ''}`)).items);
  }, [path, showInactive, canManage, q]);
  useEffect(() => { void load(); }, [load]);
  const move = async (i: number, by: number) => {
    const next = [...items];
    const [x] = next.splice(i, 1);
    if (!x) return;
    next.splice(i + by, 0, x);
    setError(null);
    try { await api('PUT', `${path}/order`, { items: next.map(n => n.id) }); await load(); } catch (e) { setError(message(e)); }
  };
  const item = items.find(i => i.id === selected);
  return (
    <>
      <section className="card">
        <div className="actions">
          <input placeholder={t('Search')} value={q} onChange={e => setQ(e.target.value)} />
          {canManage && <label><input type="checkbox" checked={showInactive} onChange={e => setShowInactive(e.target.checked)} /> {t('Show inactive items')}</label>}
        </div>
        <Notice error={error} />
        <Table rows={items} columns={[
          { header: 'Code', cell: i => <button className="link" dir="ltr" onClick={() => setSelected(i.id)}>{i.code}</button> },
          { header: 'Name', cell: i => lang === 'ar' ? i.nameAr : i.nameEn ?? i.nameAr },
          { header: 'Status', cell: i => t(i.isActive ? 'ACTIVE' : 'DISABLED') },
          { header: 'Type', cell: i => [i.isSystem && t('System'), i.isLocked && t('Locked')].filter(Boolean).join(' · ') },
          ...(canManage && !showInactive && !q ? [{ header: 'Order', cell: (i: Item) => {
            const n = items.indexOf(i);
            return <span className="actions">
              {n > 0 && <button className="link" aria-label={t('Up')} onClick={() => void move(n, -1)}>↑</button>}
              {n < items.length - 1 && <button className="link" aria-label={t('Down')} onClick={() => void move(n, 1)}>↓</button>}
            </span>;
          } }] : []),
        ]} />
      </section>
      {item && <ItemEditor key={item.id + item.etag} path={path} item={item} canManage={canManage} onDone={load} />}
      {item && !path.startsWith('/lookups/') && <Links kind={kind} item={item} canManage={canManage} />}
      {canManage && allowAdd && (
        <Form title="New item" submit="Add" onSubmit={async () => {
          await api('POST', `${path}/items`, { ...draft, nameEn: draft.nameEn || undefined });
          setDraft({ code: '', nameAr: '', nameEn: '' });
          await load();
        }}>
          <Field label="Code" value={draft.code} onChange={v => setDraft({ ...draft, code: v.toUpperCase() })} hint="Capital letters, digits and _; it cannot change later." />
          <Field label="Name (Arabic)" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
          <Field label="Name (English)" value={draft.nameEn} onChange={v => setDraft({ ...draft, nameEn: v })} required={false} />
        </Form>
      )}
    </>
  );
}

export function Catalogs() {
  const { t, lang } = useI18n();
  const [kinds, setKinds] = useState<Kind[]>([]);
  const [lookups, setLookups] = useState(false);
  const [lists, setLists] = useState<Item[]>([]);
  const [current, setCurrent] = useState('products');
  const [version, setVersion] = useState(0);
  useEffect(() => {
    api<{ items: Kind[]; lookups: boolean }>('GET', '/catalogs').then(r => { setKinds(r.items); setLookups(r.lookups); }).catch(() => setKinds([]));
  }, []);
  useEffect(() => {
    if (lookups) api<{ items: Item[] }>('GET', '/catalogs/lookup-lists').then(r => setLists(r.items)).catch(() => setLists([]));
  }, [lookups]);
  const isList = current.startsWith('list:');
  const list = isList ? lists.find(l => l.code === current.slice(5)) : undefined;
  const kind = kinds.find(k => k.kind === current);
  return (
    <>
      <section className="card">
        <h1>{t('Catalogues')}</h1>
        <Select label="Catalogue" value={current} onChange={setCurrent} options={[
          ...kinds.map(k => ({ value: k.kind, label: t(KINDS[k.kind] ?? k.kind) })),
          ...lists.map(l => ({ value: 'list:' + l.code, label: t('List') + ': ' + (lang === 'ar' ? l.nameAr : l.nameEn ?? l.nameAr) })),
          { value: 'currencies', label: t('Currencies') },
        ]} />
      </section>
      {current === 'currencies' && <Currencies />}
      {kind && <CatalogList key={kind.kind + version} path={`/catalogs/${kind.kind}`} kind={kind.kind} canManage={kind.canManage} />}
      {kind?.canManage && <CatalogTransfer key={'csv' + kind.kind} kind={kind.kind} onSaved={() => setVersion(v => v + 1)} />}
      {list && <CatalogList key={list.code} path={`/lookups/${list.code}`} kind="lookup-items" canManage={lookups}
        allowAdd={!list.isSystem || list.fields.allowTenantItems === true} />}
    </>
  );
}

interface ImportRow { line: number; code?: string; action: string; error?: string; message?: string }
interface ImportResult { applied: boolean; errors: number; creates: number; updates: number; rows: ImportRow[] }

/** FR-CAT-024: the catalogue as CSV, and its import previewed row by row before it saves; the code is the key and never changes. */
function CatalogTransfer({ kind, onSaved }: { kind: string; onSaved: () => void }) {
  const { t } = useI18n();
  const [csv, setCsv] = useState<string | null>(null);
  const [result, setResult] = useState<ImportResult | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const run = async (apply: boolean) => {
    if (!csv) return;
    try {
      const r = await api<ImportResult>('POST', `/catalogs/${kind}/import`, { csv, apply });
      setResult(r);
      setNotice(r.applied ? { ok: 'Saved.' } : {});
      if (r.applied) { setCsv(null); onSaved(); }
    } catch (e) { setNotice({ error: message(e) }); }
  };
  return (
    <section className="card">
      <h2>{t('Export and import')}</h2>
      <p className="muted">{t('The import reads the columns of the export. A known code changes its item and a new code adds one; codes never change. Nothing is saved until the preview has no error.')}</p>
      <div className="actions">
        <button className="secondary" onClick={() => void downloadGet(`/catalogs/${kind}/export`, `catalog-${kind}.csv`).catch(e => setNotice({ error: message(e) }))}>{t('Export CSV')}</button>
        <input type="file" accept=".csv,text/csv" onChange={async e => {
          const file = e.target.files?.[0];
          setResult(null);
          setCsv(file ? await file.text() : null);
        }} />
        <button className="secondary" disabled={!csv} onClick={() => void run(false)}>{t('Preview')}</button>
        <button disabled={!csv || !result || result.errors > 0} onClick={() => void run(true)}>{t('Save the import')}</button>
      </div>
      <Notice ok={notice.ok} error={notice.error} />
      {result && <>
        <p>{t('Added')}: {result.creates} · {t('Changed')}: {result.updates} · {t('Errors')}: {result.errors}</p>
        <Table rows={result.rows.filter(r => r.action !== 'UNCHANGED')} columns={[
          { header: 'Line', cell: r => r.line },
          { header: 'Code', cell: r => <span dir="ltr">{r.code}</span> },
          { header: 'Action', cell: r => t(r.action) },
          { header: 'Details', cell: r => r.message ? t(r.message) : '' },
        ]} />
      </>}
    </section>
  );
}

function Currencies() {
  const { t, lang } = useI18n();
  const [items, setItems] = useState<{ code: string; nameAr: string; nameEn: string; enabled: boolean }[]>([]);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const load = useCallback(async () => setItems((await api<{ items: typeof items }>('GET', '/currencies')).items), []);
  useEffect(() => { void load(); }, [load]);
  return (
    <section className="card">
      <h2>{t('Currencies')}</h2>
      <p className="muted">{t('Only the enabled currencies are offered in the forms; one disabled stays on the records that use it.')}</p>
      <div className="grid">
        {items.map(c => (
          <label key={c.code}>
            <input type="checkbox" checked={c.enabled} onChange={e => setItems(items.map(x => x.code === c.code ? { ...x, enabled: e.target.checked } : x))} />
            <span dir="ltr">{c.code}</span> {lang === 'ar' ? c.nameAr : c.nameEn}
          </label>
        ))}
      </div>
      <button onClick={async () => {
        setNotice({});
        try { await api('PUT', '/tenant-currencies', { codes: items.filter(c => c.enabled).map(c => c.code) }); setNotice({ ok: 'Saved.' }); await load(); }
        catch (e) { setNotice({ error: message(e) }); }
      }}>{t('Save')}</button>
      <Notice ok={notice.ok} error={notice.error} />
    </section>
  );
}
