// Mobile session tokens: a 15-minute access token and a refresh token that works once (the server revokes the
// session if a rotated refresh token is presented again). Only one refresh may run at a time, so concurrent
// requests never send the same refresh token twice. Pure module with injected storage and transport.

export interface Tokens { access_token: string; refresh_token: string; access_expires_at: string }

export interface TokenStore {
  load(): Promise<Tokens | null>;
  save(tokens: Tokens): Promise<void>;
  clear(): Promise<void>;
}

export type RefreshCall = (refreshToken: string) => Promise<{ status: number; body?: Tokens }>;

export class SessionManager {
  private inflight: Promise<string | null> | null = null;
  private store: TokenStore;
  private refreshCall: RefreshCall;
  private now: () => number;
  /** Called when the server refuses the refresh token, so the interface can return to sign-in. */
  onSignedOut: (() => void) | null = null;

  constructor(store: TokenStore, refreshCall: RefreshCall, now: () => number = () => Date.now()) {
    this.store = store;
    this.refreshCall = refreshCall;
    this.now = now;
  }

  /** A valid access token, refreshing it first if it expires within 30 seconds; null means sign in again. */
  async accessToken(): Promise<string | null> {
    const t = await this.store.load();
    if (!t) return null;
    if (new Date(t.access_expires_at).getTime() - this.now() > 30_000) return t.access_token;
    return this.refresh();
  }

  /** Refreshes once even when called many times concurrently. */
  refresh(): Promise<string | null> {
    if (!this.inflight) {
      this.inflight = this.doRefresh().finally(() => { this.inflight = null; });
    }
    return this.inflight;
  }

  private async doRefresh(): Promise<string | null> {
    const t = await this.store.load();
    if (!t) return null;
    const r = await this.refreshCall(t.refresh_token);
    if (r.status === 200 && r.body) {
      await this.store.save(r.body);
      return r.body.access_token;
    }
    if (r.status === 401 || r.status === 403) {                   // revoked, expired or reused: sign in again
      await this.store.clear();
      this.onSignedOut?.();
    }
    return null;
  }
}
