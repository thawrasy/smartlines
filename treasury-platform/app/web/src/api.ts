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

async function send(method: Method, path: string, body?: unknown, ifMatch?: string): Promise<Response> {
  const headers: Record<string, string> = { Accept: 'application/json' };
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
    throw new ApiError({ status: response.status, code: p.code ?? 'ERROR', title: p.title ?? 'Something went wrong.', correlationId: p.correlationId });
  }
  return response;
}

export async function api<T>(method: Method, path: string, body?: unknown, ifMatch?: string): Promise<T> {
  const response = await send(method, path, body, ifMatch);
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
