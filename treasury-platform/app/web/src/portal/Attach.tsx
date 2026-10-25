import { useEffect, useState } from 'react';
import { api, downloadGet, message, upload } from '../api';
import { useI18n } from '../i18n';
import { Field, Notice, Select } from '../ui';

// Files kept in the system (docs/31 row 52): a file uploaded onto a request, a letter of credit or a facility goes into
// the encrypted document store, scanned, and is attached at once. The server checks every permission.

type DocType = { code: string; nameAr?: string; nameEn?: string };

/** The document types of the catalogue, filtered to the codes given (all when none). */
export function useDocTypes(codes?: string[]) {
  const [types, setTypes] = useState<DocType[]>([]);
  const key = codes?.join(',') ?? '';
  useEffect(() => {
    api<{ items: DocType[] }>('GET', '/catalogs/document-types').then(r => {
      const wanted = key ? key.split(',') : null;
      setTypes(wanted ? r.items.filter(t => wanted.includes(t.code)).sort((a, b) => wanted.indexOf(a.code) - wanted.indexOf(b.code)) : r.items);
    }).catch(() => setTypes([]));
  }, [key]);
  return types;
}

/** A small form: the type (unless fixed), a title and the file; posts multipart to `path` and reports back. */
export function AttachForm({ path, types, fixedType, extra, title = 'Attach a file', onDone }: {
  path: string; types?: DocType[]; fixedType?: string; extra?: Record<string, string>; title?: string; onDone: () => Promise<void> | void;
}) {
  const { t, lang } = useI18n();
  const [type, setType] = useState('');
  const [name, setName] = useState('');
  const [file, setFile] = useState<File | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<{ ok?: string; error?: string }>({});
  const chosen = fixedType ?? (type || types?.[0]?.code || '');
  return (
    <form className="attach" onSubmit={async e => {
      e.preventDefault();
      setNotice({});
      if (!file) { setNotice({ error: t('Choose a file.') }); return; }
      const form = new FormData();
      if (chosen) form.append('documentType', chosen);
      form.append('title', name || file.name);
      Object.entries(extra ?? {}).forEach(([k, v]) => { if (v) form.append(k, v); });
      form.append('file', file);
      setBusy(true);
      try {
        await upload(path, form);
        setNotice({ ok: t('The file is saved and attached.') });
        setName(''); setFile(null); (e.target as HTMLFormElement).reset();
        await onDone();
      } catch (x) { setNotice({ error: message(x) }); } finally { setBusy(false); }
    }}>
      <h3>{t(title)}</h3>
      <Notice {...notice} />
      <div className="row">
        {!fixedType && types && <Select label="Document type" value={chosen} onChange={setType}
          options={types.map(x => ({ value: x.code, label: String((lang === 'ar' ? x.nameAr ?? x.nameEn : x.nameEn ?? x.nameAr) ?? x.code) }))} />}
        <Field label="Title" value={name} onChange={setName} required={false} hint="The file name when left empty." />
        <label><span>{t('File')}</span><input type="file" onChange={e => setFile(e.target.files?.[0] ?? null)} required /></label>
      </div>
      <button type="submit" disabled={busy}>{t(busy ? 'Uploading…' : 'Upload and attach')}</button>
    </form>
  );
}

/** A button that downloads a stored document. */
export function DownloadButton({ id, name }: { id: string; name?: string }) {
  const { t } = useI18n();
  const [error, setError] = useState<string | null>(null);
  return <>
    <button type="button" className="link" onClick={async () => { setError(null); try { await downloadGet(`/documents/${id}/content`, name ?? 'document'); } catch (e) { setError(message(e)); } }}>{t('Download')}</button>
    {error && <span className="warn"> {error}</span>}
  </>;
}

/** Downloads the PDF of a printed page (format=pdf). */
export function PdfButton({ path, name, label = 'Download PDF' }: { path: string; name: string; label?: string }) {
  const { t } = useI18n();
  const [error, setError] = useState<string | null>(null);
  return <>
    <button type="button" className="secondary" onClick={async () => {
      setError(null);
      try { await downloadGet(`${path}${path.includes('?') ? '&' : '?'}format=pdf`, name); } catch (e) { setError(message(e)); }
    }}>{t(label)}</button>
    {error && <span className="warn"> {error}</span>}
  </>;
}
