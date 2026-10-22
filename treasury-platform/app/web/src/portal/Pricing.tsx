import { useCallback, useEffect, useState } from 'react';
import { api, message } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Notice, Select, Table } from '../ui';

// SCR-PRC-01 (the tariff schedules of a bank: versions, items and tiers; a treasury manager who did not prepare a
// version approves it, and it is fixed from then on) and SCR-PRC-02 (the pricing rules of a facility, with the lab that
// shows which rule wins for a limit, a company and an amount, and why the others lose).

interface Named { id: string; code?: string; nameAr?: string; nameEn?: string }
const name = (lang: string, x?: { nameAr?: string | null; nameEn?: string | null } | null) => x ? (lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? '' : '';
const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 4 });
const num = (v: string) => v === '' ? undefined : Number(v);

interface Schedule { id: string; institution: { id: string; code: string }; facilityNo?: string; nameAr: string; nameEn?: string; versionNo: number; effectiveFrom: string; effectiveTo?: string; status: string }
interface Item {
  id: string; feeType: string; itemCode: string; nameAr: string; nameEn?: string; chargeKind: string; rate?: number; fixedAmount?: number; perMillionAmount?: number;
  periodBasis: string; periodDays?: number; minAmount?: number; maxAmount?: number;
  tiers: { amountFrom?: number; amountTo?: number; periodFromDays?: number; periodToDays?: number; rate?: number; fixedAmount?: number }[];
}

export function TariffSchedules() {
  const { t, lang } = useI18n();
  const [rows, setRows] = useState<Schedule[]>([]);
  const [banks, setBanks] = useState<Named[]>([]);
  const [open, setOpen] = useState<string | null>(null);
  const [draft, setDraft] = useState({ institution: '', nameAr: '', effectiveFrom: '' });
  const load = useCallback(async () => setRows((await api<{ items: Schedule[] }>('GET', '/tariff-schedules')).items), []);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Named[] }>('GET', '/institutions').then(r => { setBanks(r.items); setDraft(d => ({ ...d, institution: d.institution || r.items[0]?.id || '' })); }); }, []);
  return (
    <>
      <section className="card">
        <h1>{t('Tariff schedules')}</h1>
        <Table rows={rows} columns={[
          { header: 'Bank', cell: s => <span dir="ltr">{s.institution.code}</span> },
          { header: 'Name', cell: s => <button className="link" onClick={() => setOpen(open === s.id ? null : s.id)}>{name(lang, s)}</button> },
          { header: 'Facility', cell: s => <span dir="ltr">{s.facilityNo}</span> },
          { header: 'Version', cell: s => s.versionNo },
          { header: 'Effective', cell: s => <span dir="ltr">{s.effectiveFrom}{s.effectiveTo && ` → ${s.effectiveTo}`}</span> },
          { header: 'Status', cell: s => t(s.status) },
        ]} />
      </section>
      {open && <TariffSchedule id={open} onChange={load} />}
      <Form title="New tariff version" submit="Create" onSubmit={async () => {
        const r = await api<{ id: string }>('POST', '/tariff-schedules', draft);
        setDraft({ ...draft, nameAr: '' });
        await load();
        setOpen(r.id);
      }}>
        <Select label="Bank" value={draft.institution} onChange={v => setDraft({ ...draft, institution: v })} options={banks.map(b => ({ value: b.id, label: `${b.code} ${name(lang, b)}` }))} />
        <Field label="Name" value={draft.nameAr} onChange={v => setDraft({ ...draft, nameAr: v })} />
        <Field label="Start date" value={draft.effectiveFrom} onChange={v => setDraft({ ...draft, effectiveFrom: v })} type="date" />
      </Form>
    </>
  );
}

function TariffSchedule({ id, onChange }: { id: string; onChange: () => Promise<void> }) {
  const { t, lang } = useI18n();
  const [data, setData] = useState<{ schedule: Schedule; items: Item[] } | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [item, setItem] = useState({ feeType: 'ISSUANCE', itemCode: '', nameAr: '', chargeKind: 'PERCENT', rate: '', fixedAmount: '', perMillionAmount: '', periodBasis: 'FLAT', periodDays: '', minAmount: '', maxAmount: '', noSourceReason: '' });
  const [tier, setTier] = useState({ item: '', amountFrom: '', amountTo: '', periodFromDays: '', periodToDays: '', rate: '', fixedAmount: '' });
  const load = useCallback(async () => setData(await api<{ schedule: Schedule; items: Item[] }>('GET', `/tariff-schedules/${id}`)), [id]);
  useEffect(() => { void load(); }, [load]);
  if (!data) return null;
  const draft = data.schedule.status === 'DRAFT';
  return (
    <>
      <section className="card">
        <h2>{name(lang, data.schedule)} <small className="muted">v{data.schedule.versionNo} · {t(data.schedule.status)}</small></h2>
        <Notice {...notice} />
        <Table rows={data.items} columns={[
          { header: 'Code', cell: i => <span dir="ltr">{i.itemCode}</span> },
          { header: 'Fee type', cell: i => t(i.feeType) },
          { header: 'Name', cell: i => name(lang, i) },
          { header: 'Charge', cell: i => <span dir="ltr">{t(i.chargeKind)} {i.rate != null && `${amount(i.rate)}%`} {amount(i.fixedAmount)} {i.perMillionAmount != null && `${amount(i.perMillionAmount)} / 1M`}</span> },
          { header: 'Period', cell: i => <>{t(i.periodBasis)}{i.periodDays != null && ` ${i.periodDays}`}</> },
          { header: 'Minimum', cell: i => <span dir="ltr">{amount(i.minAmount)}</span> },
          { header: 'Tiers', cell: i => i.tiers.map((x, n) => <div key={n} dir="ltr">
            {x.amountFrom != null && `${amount(x.amountFrom)}–${amount(x.amountTo) || '∞'}`}{x.periodFromDays != null && ` ${x.periodFromDays}–${x.periodToDays ?? '∞'}d`}: {x.rate != null ? `${amount(x.rate)}%` : amount(x.fixedAmount)}
          </div>) },
        ]} />
        {draft && <button onClick={async () => {
          setNotice({});
          try { await api('POST', `/tariff-schedules/${id}/actions/approve`, {}); setNotice({ ok: 'Approved' }); await load(); await onChange(); } catch (e) { setNotice({ error: message(e) }); }
        }}>{t('Approve')}</button>}
      </section>
      {draft && <>
        <Form title="Add a tariff item" submit="Add" onSubmit={async () => {
          await api('POST', `/tariff-schedules/${id}/items`, {
            feeType: item.feeType, itemCode: item.itemCode, nameAr: item.nameAr, chargeKind: item.chargeKind, rate: num(item.rate), fixedAmount: num(item.fixedAmount),
            perMillionAmount: num(item.perMillionAmount), periodBasis: item.periodBasis, periodDays: num(item.periodDays), minAmount: num(item.minAmount), maxAmount: num(item.maxAmount),
            noSourceReason: item.noSourceReason,
          });
          setItem({ ...item, itemCode: '', nameAr: '', rate: '', fixedAmount: '', perMillionAmount: '' });
          await load();
        }}>
          <Field label="Fee type" value={item.feeType} onChange={v => setItem({ ...item, feeType: v })} />
          <Field label="Code" value={item.itemCode} onChange={v => setItem({ ...item, itemCode: v })} />
          <Field label="Name" value={item.nameAr} onChange={v => setItem({ ...item, nameAr: v })} />
          <Select label="Charge" value={item.chargeKind} onChange={v => setItem({ ...item, chargeKind: v })} options={['PERCENT', 'FIXED', 'PER_MILLION', 'TIERED'].map(c => ({ value: c, label: c }))} />
          <Field label="Rate %" value={item.rate} onChange={v => setItem({ ...item, rate: v })} type="number" required={false} />
          <Field label="Fixed amount" value={item.fixedAmount} onChange={v => setItem({ ...item, fixedAmount: v })} type="number" required={false} />
          <Field label="Amount per million" value={item.perMillionAmount} onChange={v => setItem({ ...item, perMillionAmount: v })} type="number" required={false} />
          <Select label="Period" value={item.periodBasis} onChange={v => setItem({ ...item, periodBasis: v })}
            options={['FLAT', 'PER_ANNUM', 'PER_PERIOD_OR_PART'].map(c => ({ value: c, label: c }))} />
          <Field label="Period days" value={item.periodDays} onChange={v => setItem({ ...item, periodDays: v })} type="number" required={false} />
          <Field label="Minimum" value={item.minAmount} onChange={v => setItem({ ...item, minAmount: v })} type="number" required={false} />
          <Field label="Maximum" value={item.maxAmount} onChange={v => setItem({ ...item, maxAmount: v })} type="number" required={false} />
          <Field label="Source (or why there is none)" value={item.noSourceReason} onChange={v => setItem({ ...item, noSourceReason: v })} />
        </Form>
        <Form title="Add a tier" submit="Add" onSubmit={async () => {
          await api('POST', `/tariff-schedules/${id}/items/${tier.item}/tiers`, {
            amountFrom: num(tier.amountFrom), amountTo: num(tier.amountTo), periodFromDays: num(tier.periodFromDays), periodToDays: num(tier.periodToDays), rate: num(tier.rate),
            fixedAmount: num(tier.fixedAmount),
          });
          await load();
        }}>
          <Select label="Item" value={tier.item} onChange={v => setTier({ ...tier, item: v })}
            options={[{ value: '', label: '' }, ...data.items.filter(i => i.chargeKind === 'TIERED').map(i => ({ value: i.id, label: i.itemCode }))]} />
          <Field label="Amount from" value={tier.amountFrom} onChange={v => setTier({ ...tier, amountFrom: v })} type="number" required={false} />
          <Field label="Amount to" value={tier.amountTo} onChange={v => setTier({ ...tier, amountTo: v })} type="number" required={false} />
          <Field label="From day" value={tier.periodFromDays} onChange={v => setTier({ ...tier, periodFromDays: v })} type="number" required={false} />
          <Field label="To day" value={tier.periodToDays} onChange={v => setTier({ ...tier, periodToDays: v })} type="number" required={false} />
          <Field label="Rate %" value={tier.rate} onChange={v => setTier({ ...tier, rate: v })} type="number" required={false} />
          <Field label="Fixed amount" value={tier.fixedAmount} onChange={v => setTier({ ...tier, fixedAmount: v })} type="number" required={false} />
        </Form>
      </>}
    </>
  );
}

interface Rule {
  id: string; scopeLimit?: string; scopeCompany?: string; componentKind: string; rateState: string; feeType?: string; financingType?: string; method?: string;
  addOnPct?: number; baseRate?: string; marginPct?: number; ratePct?: number; fixedAmount?: number; periodBasis?: string; effectiveFrom: string; effectiveTo?: string;
}
interface Resolution {
  status: string; reason?: string; node?: string; ratePct?: number; amount?: number; vatAmount?: number; notIncome: boolean; currency: string;
  losers: { node?: string; reason: string }[]; warnings: string[];
}

/** SCR-PRC-02 inside the facility card: the rules of the approved revision or of the draft, a rule form and the lab. */
export function FacilityPricing({ id, company, draft, edit }: { id: string; company: string; draft: boolean; edit: boolean }) {
  const { t } = useI18n();
  const [limits, setLimits] = useState<{ id: string; code: string }[]>([]);
  const [view, setView] = useState<'approved' | 'draft'>('approved');
  const [rules, setRules] = useState<{ items: Rule[]; notSpecified: { feeType?: string; financingType?: string; scopeLimit?: string }[] } | null>(null);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const [rule, setRule] = useState({ scopeLimit: '', feeType: 'ISSUANCE', financingType: '', method: 'PERCENT_OF_AMOUNT', rateState: 'SET', ratePct: '', addOnPct: '', tariffItem: '',
    baseRate: '', marginPct: '', fixedAmount: '', periodBasis: 'FLAT', effectiveFrom: '', retroactiveReason: '', noSourceReason: '' });
  const [lab, setLab] = useState({ limit: '', feeType: 'ISSUANCE', financingType: '', amount: '', days: '90', asOf: '', contractDate: '' });
  const [result, setResult] = useState<Resolution | null>(null);
  const load = useCallback(async () => {
    try { setRules(await api('GET', `/facilities/${id}/pricing-rules${view === 'draft' ? '?view=draft' : ''}`)); } catch { setRules(null); }
  }, [id, view]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { if (!draft) setView('approved'); }, [draft]);
  useEffect(() => {
    void api<{ limits: { limit: { id: string; code: string } }[] }>('GET', `/facilities/${id}/limits${view === 'draft' ? '?view=draft' : ''}`)
      .then(r => setLimits(r.limits.map(l => l.limit))).catch(() => setLimits([]));
  }, [id, view]);
  return (
    <>
      <section className="card">
        <h2>{t('Pricing')}</h2>
        {draft && <div className="row">
          <button className={view === 'approved' ? '' : 'link'} onClick={() => setView('approved')}>{t('Approved')}</button>
          <button className={view === 'draft' ? '' : 'link'} onClick={() => setView('draft')}>{t('Draft')}</button>
        </div>}
        <Notice {...notice} />
        {rules && <>
          {rules.notSpecified.map((n, i) => <p key={i} className="warn">{t('Not specified in the agreement')}: {n.feeType ?? n.financingType} {n.scopeLimit && <span dir="ltr">({n.scopeLimit})</span>}</p>)}
          <Table rows={rules.items} columns={[
            { header: 'Scope', cell: r => <span dir="ltr">{r.scopeLimit ?? t('Facility')}{r.scopeCompany && ' · ' + t('Company')}</span> },
            { header: 'Component', cell: r => t(r.feeType ?? r.financingType ?? r.componentKind) },
            { header: 'Method', cell: r => t(r.method ?? '') },
            { header: 'Rate', cell: r => r.rateState !== 'SET' ? <span className="warn">{t(r.rateState)}</span>
              : <span dir="ltr">{r.baseRate && `${r.baseRate} + `}{amount(r.marginPct ?? r.addOnPct ?? r.ratePct)}{(r.marginPct ?? r.addOnPct ?? r.ratePct) != null && '%'} {amount(r.fixedAmount)}</span> },
            { header: 'Effective', cell: r => <span dir="ltr">{r.effectiveFrom}{r.effectiveTo && ` → ${r.effectiveTo}`}</span> },
            { header: '', cell: r => view === 'draft' && edit && !r.effectiveTo
              ? <button className="link" onClick={async () => {
                setNotice({});
                try { await api('DELETE', `/facilities/${id}/pricing-rules/${r.id}`); await load(); } catch (e) { setNotice({ error: message(e) }); }
              }}>{t('Remove')}</button> : null },
          ]} />
        </>}
      </section>
      {draft && edit && view === 'draft' && <Form title="Add a pricing rule" submit="Add" onSubmit={async () => {
        const isFinancing = rule.financingType !== '';
        await api('POST', `/facilities/${id}/pricing-rules`, {
          scopeLimit: rule.scopeLimit || undefined, feeType: isFinancing ? undefined : rule.feeType, financingType: isFinancing ? rule.financingType : undefined,
          method: rule.method, rateState: rule.rateState, ratePct: num(rule.ratePct), addOnPct: num(rule.addOnPct), tariffItem: rule.tariffItem || undefined,
          baseRate: rule.baseRate || undefined, marginPct: num(rule.marginPct), fixedAmount: num(rule.fixedAmount), periodBasis: rule.periodBasis,
          effectiveFrom: rule.effectiveFrom, retroactiveReason: rule.retroactiveReason || undefined, noSourceReason: rule.noSourceReason,
        });
        setRule({ ...rule, ratePct: '', addOnPct: '', marginPct: '', fixedAmount: '' });
        await load();
      }}>
        <Select label="Limit" value={rule.scopeLimit} onChange={v => setRule({ ...rule, scopeLimit: v })} options={[{ value: '', label: 'Facility' }, ...limits.map(l => ({ value: l.id, label: l.code }))]} />
        <Field label="Fee type" value={rule.feeType} onChange={v => setRule({ ...rule, feeType: v })} required={false} />
        <Field label="Financing type" value={rule.financingType} onChange={v => setRule({ ...rule, financingType: v })} required={false} />
        <Select label="Method" value={rule.method} onChange={v => setRule({ ...rule, method: v })}
          options={['TARIFF_AS_IS', 'TARIFF_PLUS_ADDON', 'BASE_PLUS_MARGIN', 'PERCENT_OF_AMOUNT', 'FIXED_AMOUNT', 'PER_MILLION', 'TIERED'].map(m => ({ value: m, label: m }))} />
        <Select label="Rate" value={rule.rateState} onChange={v => setRule({ ...rule, rateState: v })}
          options={['SET', 'NOT_SPECIFIED_IN_AGREEMENT', 'TO_BE_AGREED', 'BANK_TARIFF'].map(s => ({ value: s, label: s }))} />
        <Field label="Rate %" value={rule.ratePct} onChange={v => setRule({ ...rule, ratePct: v })} type="number" required={false} />
        <Field label="Add-on %" value={rule.addOnPct} onChange={v => setRule({ ...rule, addOnPct: v })} type="number" required={false} />
        <Field label="Tariff item" value={rule.tariffItem} onChange={v => setRule({ ...rule, tariffItem: v })} required={false} />
        <Field label="Base rate" value={rule.baseRate} onChange={v => setRule({ ...rule, baseRate: v })} required={false} />
        <Field label="Margin %" value={rule.marginPct} onChange={v => setRule({ ...rule, marginPct: v })} type="number" required={false} />
        <Field label="Fixed amount" value={rule.fixedAmount} onChange={v => setRule({ ...rule, fixedAmount: v })} type="number" required={false} />
        <Select label="Period" value={rule.periodBasis} onChange={v => setRule({ ...rule, periodBasis: v })}
          options={['FLAT', 'PER_ANNUM', 'PER_PERIOD_OR_PART'].map(c => ({ value: c, label: c }))} />
        <Field label="Start date" value={rule.effectiveFrom} onChange={v => setRule({ ...rule, effectiveFrom: v })} type="date" />
        <Field label="Reason for a past date" value={rule.retroactiveReason} onChange={v => setRule({ ...rule, retroactiveReason: v })} required={false} />
        <Field label="Source (or why there is none)" value={rule.noSourceReason} onChange={v => setRule({ ...rule, noSourceReason: v })} />
      </Form>}
      <Form title="Pricing lab" submit="Calculate" onSubmit={async () => {
        setResult(await api<Resolution>('POST', '/pricing/resolve', {
          facility: id, company, limit: lab.limit || undefined, feeType: lab.financingType ? undefined : lab.feeType, financingType: lab.financingType || undefined,
          amount: Number(lab.amount), days: Number(lab.days), asOf: lab.asOf || undefined, contractDate: lab.contractDate || undefined,
        }));
      }}>
        <Select label="Limit" value={lab.limit} onChange={v => setLab({ ...lab, limit: v })} options={[{ value: '', label: '' }, ...limits.map(l => ({ value: l.id, label: l.code }))]} />
        <Field label="Fee type" value={lab.feeType} onChange={v => setLab({ ...lab, feeType: v })} required={false} />
        <Field label="Financing type" value={lab.financingType} onChange={v => setLab({ ...lab, financingType: v })} required={false} />
        <Field label="Amount" value={lab.amount} onChange={v => setLab({ ...lab, amount: v })} type="number" />
        <Field label="Days" value={lab.days} onChange={v => setLab({ ...lab, days: v })} type="number" />
        <Field label="As of" value={lab.asOf} onChange={v => setLab({ ...lab, asOf: v })} type="date" required={false} />
        <Field label="Contract date" value={lab.contractDate} onChange={v => setLab({ ...lab, contractDate: v })} type="date" required={false} />
      </Form>
      {result && <section className="card">
        <h3>{t(result.status)}{result.reason && ` · ${t(result.reason)}`}</h3>
        <dl className="grid">
          <dt>{t('Rule from')}</dt><dd dir="ltr">{result.node}</dd>
          <dt>{t('Rate %')}</dt><dd dir="ltr">{amount(result.ratePct)}</dd>
          <dt>{t('Amount')}</dt><dd dir="ltr">{amount(result.amount)} {result.amount != null && result.currency}</dd>
          <dt>{t('VAT')}</dt><dd dir="ltr">{amount(result.vatAmount)}</dd>
          {result.notIncome && <><dt>{t('Not income')}</dt><dd>{t('Yes')}</dd></>}
        </dl>
        {result.warnings.map((w, i) => <p key={i} className="warn">{t(w)}</p>)}
        <Table rows={result.losers} columns={[
          { header: 'Rule from', cell: l => <span dir="ltr">{l.node}</span> },
          { header: 'Why not', cell: l => t(l.reason) },
        ]} />
      </section>}
    </>
  );
}
