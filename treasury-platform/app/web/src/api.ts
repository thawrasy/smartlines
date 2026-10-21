// The API client (ADR 0040): same origin, the session in an HttpOnly cookie, and the CSRF token from
// GET /api/v1/csrf echoed in X-CSRF-Token on every unsafe request.
export interface Problem { status: number; code: string; title: string; correlationId?: string }

export class ApiError extends Error {
  constructor(public readonly problem: Problem) { super(problem.title); }
}

let csrf: Promise<string> | null = null;

function csrfToken(): Promise<string> {
  csrf ??= fetch('/api/v1/csrf', { credentials: 'same-origin' })
    .then(r => r.json() as Promise<{ token: string }>)
    .then(j => j.token);
  return csrf;
}

export async function api<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (method !== 'GET') {
    headers['Content-Type'] = 'application/json';
    headers['X-CSRF-Token'] = await csrfToken();
  }
  const response = await fetch('/api/v1' + path, {
    method, headers, credentials: 'same-origin', body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (response.status === 204) return undefined as T;
  const json: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const p = (json ?? {}) as Partial<Problem>;
    throw new ApiError({ status: response.status, code: p.code ?? 'ERROR', title: p.title ?? 'Something went wrong.', correlationId: p.correlationId });
  }
  return json as T;
}

export function message(e: unknown): string {
  return e instanceof ApiError ? e.problem.title : 'Something went wrong. Try again.';
}
