import { useCallback, useEffect, useState } from 'react';
import { api } from '../api';
import { useI18n } from '../i18n';
import { Field, Form, Select, Table } from '../ui';

// docs/31 row 76: the business of a company with a bank, product by product: the rates agreed for the charges of a
// product (by its nature: the networks of POS, the transfers of payroll ...), the volumes by period with the commissions,
// the bank's profit, the company's return and the balance, and the cross-sale view that sums them per bank.

const amount = (n?: number | null) => n == null ? '' : n.toLocaleString('en-US', { maximumFractionDigits: 2 });
const label = (lang: string, ar: string, en?: string | null) => lang === 'ar' ? ar : en ?? ar;

interface SummaryRow {
  company: string; companyName: string; product: string; productNameAr: string; productNameEn?: string | null; family: string; currency?: string | null;
  volume?: number | null; txnCount?: number | null; feesPaid?: number | null; bankProfit?: number | null; companyReturn?: number | null; endBalance?: number | null; ratesInForce: number;
}
interface Summary { months: number; since: string; products: SummaryRow[]; productCount: number; totals: { currency: string; volume: number; feesPaid: number; bankProfit: number; companyReturn: number; endBalance: number }[] }

/** The cross-sale view of a bank or a relationship: what the company does with the bank, over the last months. */
export function CrossSale({ url, showCompany = false }: { url: string; showCompany?: boolean }) {
  const { t, lang } = useI18n();
  const [months, setMonths] = useState('12');
  const [d, setD] = useState<Summary | null>(null);
  useEffect(() => { void api<Summary>('GET', `${url}${url.includes('?') ? '&' : '?'}months=${months}`).then(setD).catch(() => setD(null)); }, [url, months]);
  if (!d) return null;
  return (
    <section className="card">
      <h2>{t('Business with the bank (cross-sale)')}</h2>
      <p className="muted">{t('The products the company deals in with the bank, their volumes, the commissions and charges the bank took and its profit: the weight of the relation in a negotiation.')}</p>
      <Select label="Period" value={months} onChange={setMonths} options={['3', '6', '12', '24', '36'].map(m => ({ value: m, label: `${m} ${t('months')}` }))} />
      <p>{t('Products')}: {d.productCount}</p>
      <Table rows={d.totals} columns={[
        { header: 'Currency', cell: x => <span dir="ltr">{x.currency}</span> },
        { header: 'Volume', cell: x => <span dir="ltr">{amount(x.volume)}</span> },
        { header: 'Commissions and charges', cell: x => <span dir="ltr">{amount(x.feesPaid)}</span> },
        { header: "Bank's profit", cell: x => <span dir="ltr">{amount(x.bankProfit)}</span> },
        { header: "Company's return", cell: x => <span dir="ltr">{amount(x.companyReturn)}</span> },
        { header: 'Balance', cell: x => <span dir="ltr">{amount(x.endBalance)}</span> },
      ]} />
      <Table rows={d.products} columns={[
        ...(showCompany ? [{ header: 'Company', cell: (x: SummaryRow) => x.companyName }] : []),
        { header: 'Product', cell: x => label(lang, x.productNameAr, x.productNameEn) },
        { header: 'Currency', cell: x => <span dir="ltr">{x.currency ?? ''}</span> },
        { header: 'Volume', cell: x => <span dir="ltr">{amount(x.volume)}</span> },
        { header: 'Transactions', cell: x => <span dir="ltr">{amount(x.txnCount)}</span> },
        { header: 'Commissions and charges', cell: x => <span dir="ltr">{amount(x.feesPaid)}</span> },
        { header: "Bank's profit", cell: x => <span dir="ltr">{amount(x.bankProfit)}</span> },
        { header: 'Balance', cell: x => <span dir="ltr">{amount(x.endBalance)}</span> },
        { header: 'Rates in force', cell: x => x.ratesInForce },
      ]} />
    </section>
  );
}

interface Rate { charge: string; chargeNameAr: string; chargeNameEn?: string | null; basis: string; ratePct?: number | null; fixedAmount?: number | null; minAmount?: number | null; maxAmount?: number | null; currency: string; validFrom: string; validTo?: string | null; inForce: boolean; notes?: string | null }
interface Volume { periodStart: string; periodEnd: string; currency: string; volume: number; txnCount?: number | null; feesPaid?: number | null; bankProfit?: number | null; companyReturn?: number | null; endBalance?: number | null; notes?: string | null }
interface Charge { code: string; nameAr: string; nameEn?: string | null }

/** The rates and the volumes of one product of a relationship. */
export function ProductBusiness({ relationship, product, productName, canEdit }: { relationship: string; product: string; productName: string; canEdit: boolean }) {
  const { t, lang } = useI18n();
  const base = `/relationships/${relationship}/products/${product}`;
  const [d, setD] = useState<{ rates: Rate[]; volumes: Volume[] } | null>(null);
  const [charges, setCharges] = useState<Charge[]>([]);
  const emptyRate = { charge: '', basis: 'PERCENT', ratePct: '', fixedAmount: '', minAmount: '', maxAmount: '', currency: 'SAR', validFrom: new Date().toISOString().slice(0, 10), notes: '' };
  const emptyVolume = { periodStart: '', periodEnd: '', currency: 'SAR', volume: '', txnCount: '', feesPaid: '', bankProfit: '', companyReturn: '', endBalance: '', notes: '' };
  const [rate, setRate] = useState(emptyRate);
  const [vol, setVol] = useState(emptyVolume);
  const load = useCallback(async () => setD(await api('GET', `${base}/business`)), [base]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => { void api<{ items: Charge[] }>('GET', `/product-charges?product=${product}`).then(r => { setCharges(r.items); setRate(x => ({ ...x, charge: r.items[0]?.code ?? '' })); }); }, [product]);
  const num = (v: string) => v.trim() === '' ? undefined : Number(v);
  if (!d) return null;
  return (
    <>
      <section className="card">
        <h2>{productName}: {t('Agreed rates')}</h2>
        <Table rows={d.rates} columns={[
          { header: 'Charge', cell: r => label(lang, r.chargeNameAr, r.chargeNameEn) },
          { header: 'Rate', cell: r => <span dir="ltr">{r.basis === 'PERCENT' ? `${r.ratePct}%` : `${amount(r.fixedAmount)} ${r.currency}`}</span> },
          { header: 'Minimum', cell: r => <span dir="ltr">{amount(r.minAmount)}</span> },
          { header: 'Cap', cell: r => <span dir="ltr">{r.maxAmount == null ? t('No cap') : `${amount(r.maxAmount)} ${r.currency}`}</span> },
          { header: 'From', cell: r => <span dir="ltr">{r.validFrom}</span> },
          { header: 'To', cell: r => <span dir="ltr">{r.validTo ?? ''}</span> },
          { header: 'Status', cell: r => r.inForce ? t('In force') : '' },
        ]} />
      </section>
      {canEdit && (
        <Form title="Add a rate" submit="Add" onSubmit={async () => {
          await api('POST', `${base}/rates`, {
            charge: rate.charge, basis: rate.basis, ratePct: rate.basis === 'PERCENT' ? num(rate.ratePct) : undefined, fixedAmount: rate.basis === 'FIXED' ? num(rate.fixedAmount) : undefined,
            minAmount: num(rate.minAmount), maxAmount: num(rate.maxAmount), currency: rate.currency, validFrom: rate.validFrom, notes: rate.notes || undefined,
          });
          setRate({ ...emptyRate, charge: rate.charge }); await load();
        }}>
          <Select label="Charge" value={rate.charge} onChange={v => setRate({ ...rate, charge: v })} options={charges.map(c => ({ value: c.code, label: label(lang, c.nameAr, c.nameEn) }))} />
          <Select label="Basis" value={rate.basis} onChange={v => setRate({ ...rate, basis: v })} options={[{ value: 'PERCENT', label: 'Percent' }, { value: 'FIXED', label: 'Fixed amount' }]} />
          {rate.basis === 'PERCENT'
            ? <Field label="Rate (%)" value={rate.ratePct} onChange={v => setRate({ ...rate, ratePct: v })} type="number" />
            : <Field label="Fixed amount" value={rate.fixedAmount} onChange={v => setRate({ ...rate, fixedAmount: v })} type="number" />}
          <Field label="Minimum" value={rate.minAmount} onChange={v => setRate({ ...rate, minAmount: v })} type="number" required={false} />
          <Field label="Cap" value={rate.maxAmount} onChange={v => setRate({ ...rate, maxAmount: v })} type="number" required={false} />
          <Field label="Currency" value={rate.currency} onChange={v => setRate({ ...rate, currency: v.toUpperCase() })} />
          <Field label="From" value={rate.validFrom} onChange={v => setRate({ ...rate, validFrom: v })} type="date" />
          <Field label="Notes" value={rate.notes} onChange={v => setRate({ ...rate, notes: v })} required={false} />
        </Form>
      )}
      <section className="card">
        <h2>{productName}: {t('Volumes')}</h2>
        <Table rows={d.volumes} columns={[
          { header: 'Period', cell: v => <span dir="ltr">{v.periodStart} → {v.periodEnd}</span> },
          { header: 'Volume', cell: v => <span dir="ltr">{amount(v.volume)} {v.currency}</span> },
          { header: 'Transactions', cell: v => <span dir="ltr">{amount(v.txnCount)}</span> },
          { header: 'Commissions and charges', cell: v => <span dir="ltr">{amount(v.feesPaid)}</span> },
          { header: "Bank's profit", cell: v => <span dir="ltr">{amount(v.bankProfit)}</span> },
          { header: "Company's return", cell: v => <span dir="ltr">{amount(v.companyReturn)}</span> },
          { header: 'Balance', cell: v => <span dir="ltr">{amount(v.endBalance)}</span> },
        ]} />
      </section>
      {canEdit && (
        <Form title="Add the figures of a period" submit="Add" onSubmit={async () => {
          await api('POST', `${base}/volumes`, {
            periodStart: vol.periodStart, periodEnd: vol.periodEnd, currency: vol.currency, volume: num(vol.volume) ?? 0, txnCount: num(vol.txnCount), feesPaid: num(vol.feesPaid),
            bankProfit: num(vol.bankProfit), companyReturn: num(vol.companyReturn), endBalance: num(vol.endBalance), notes: vol.notes || undefined,
          });
          setVol(emptyVolume); await load();
        }}>
          <Field label="Period start" value={vol.periodStart} onChange={v => setVol({ ...vol, periodStart: v })} type="date" />
          <Field label="Period end" value={vol.periodEnd} onChange={v => setVol({ ...vol, periodEnd: v })} type="date" />
          <Field label="Currency" value={vol.currency} onChange={v => setVol({ ...vol, currency: v.toUpperCase() })} />
          <Field label="Volume" value={vol.volume} onChange={v => setVol({ ...vol, volume: v })} type="number" />
          <Field label="Transactions" value={vol.txnCount} onChange={v => setVol({ ...vol, txnCount: v })} type="number" required={false} />
          <Field label="Commissions and charges" value={vol.feesPaid} onChange={v => setVol({ ...vol, feesPaid: v })} type="number" required={false} />
          <Field label="Bank's profit" value={vol.bankProfit} onChange={v => setVol({ ...vol, bankProfit: v })} type="number" required={false} />
          <Field label="Company's return" value={vol.companyReturn} onChange={v => setVol({ ...vol, companyReturn: v })} type="number" required={false} />
          <Field label="Balance at the end" value={vol.endBalance} onChange={v => setVol({ ...vol, endBalance: v })} type="number" required={false} />
          <Field label="Notes" value={vol.notes} onChange={v => setVol({ ...vol, notes: v })} required={false} />
        </Form>
      )}
    </>
  );
}
