// The API client (ADR 0040): same origin, the session in an HttpOnly cookie, the CSRF token from GET /api/v1/csrf in
// X-CSRF-Token on every unsafe request, an Idempotency-Key on every POST, and If-Match when a change needs the ETag.
export interface Problem { status: number; code: string; title: string; correlationId?: string }

export class ApiError extends Error {
  constructor(public readonly problem: Problem) { super(problem.title); }
}

type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
let csrf: Promise<string> | null = null;

function csrfToken(): Promise<string> {
  csrf ??= fetch('/api/v1/csrf', { credentials: 'same-origin' })
    .then(r => r.json() as Promise<{ token: string }>)
    .then(j => j.token);
  return csrf;
}

/** Raised when the server ends the session (idle, absolute, logout elsewhere): the screen goes to the sign-in page. */
export const SESSION_ENDED = 'bankfas:session-ended';

async function send(method: Method, path: string, body?: unknown, ifMatch?: string, background = false): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  // A request the screen makes by itself does not keep an idle session alive (FR-PLT-014).
  if (background) headers['X-Background-Request'] = '1';
  if (method !== 'GET') {
    headers['Content-Type'] = 'application/json';
    headers['X-CSRF-Token'] = await csrfToken();
  }
  if (method === 'POST') headers['Idempotency-Key'] = crypto.randomUUID();
  if (ifMatch) headers['If-Match'] = ifMatch;
  const response = await fetch('/api/v1' + path, {
    method, headers, credentials: 'same-origin', body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    const p = (await response.json().catch(() => ({}))) as Partial<Problem>;
    if (response.status === 401 && p.code === 'SESSION_INVALID' && !path.includes('/auth/')) window.dispatchEvent(new Event(SESSION_ENDED));
    throw new ApiError({ status: response.status, code: p.code ?? 'ERROR', title: p.title ?? 'Something went wrong.', correlationId: p.correlationId });
  }
  return response;
}

export async function api<T>(method: Method, path: string, body?: unknown, ifMatch?: string): Promise<T> {
  const response = await send(method, path, body, ifMatch);
  if (response.status === 204 || response.headers.get('Content-Length') === '0') return undefined as T;
  return (await response.json()) as T;
}

/** A GET the screen makes on its own (polling): it does not extend the session. */
export async function apiBackground<T>(path: string): Promise<T> {
  const response = await send('GET', path, undefined, undefined, true);
  if (response.status === 204 || response.headers.get('Content-Length') === '0') return undefined as T;
  return (await response.json()) as T;
}

/** A single read with its ETag, for a later change with If-Match. */
export async function apiWithETag<T>(path: string): Promise<{ data: T; etag: string }> {
  const response = await send('GET', path);
  return { data: (await response.json()) as T, etag: response.headers.get('ETag') ?? '' };
}

/** A POST that answers with a file, saved by the browser. */
export async function download(path: string, body: unknown, fallbackName: string): Promise<void> {
  const response = await send('POST', path, body);
  const name = /filename="?([^";]+)"?/.exec(response.headers.get('Content-Disposition') ?? '')?.[1] ?? fallbackName;
  const url = URL.createObjectURL(await response.blob());
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

export function message(e: unknown): string {
  return e instanceof ApiError ? e.problem.title : 'Something went wrong. Try again.';
}

/** A multipart POST of a file and its fields (the document store); the browser sets the boundary. */
export async function upload<T>(path: string, form: FormData): Promise<T> {
  const response = await fetch('/api/v1' + path, {
    method: 'POST', credentials: 'same-origin', body: form,
    headers: { Accept: 'application/json', 'X-CSRF-Token': await csrfToken(), 'Idempotency-Key': crypto.randomUUID() },
  });
  if (!response.ok) {
    const p = (await response.json().catch(() => ({}))) as Partial<Problem>;
    throw new ApiError({ status: response.status, code: p.code ?? 'ERROR', title: p.title ?? 'Something went wrong.', correlationId: p.correlationId });
  }
  return (await response.json()) as T;
}

/** A GET that answers with a file, saved by the browser. */
export async function downloadGet(path: string, fallbackName: string): Promise<void> {
  const response = await send('GET', path);
  const name = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/.exec(response.headers.get('Content-Disposition') ?? '')?.[1] ?? fallbackName;
  const url = URL.createObjectURL(await response.blob());
  const a = document.createElement('a');
  a.href = url;
  a.download = decodeURIComponent(name);
  a.click();
  URL.revokeObjectURL(url);
}
