import { createHmac } from 'node:crypto';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Decode(text: string): Buffer {
  const clean = text.replace(/[\s=]/g, '').toUpperCase();
  let bits = 0, value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const i = B32.indexOf(ch);
    if (i < 0) throw new Error(`not base32: ${ch}`);
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return Buffer.from(out);
}

/** RFC 6238 with HMAC-SHA1, 6 digits and 30 s steps. */
export function totp(secret: Buffer, step: number): string {
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(step));
  const h = createHmac('sha1', secret).update(msg).digest();
  const o = h[h.length - 1] & 0x0f;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1_000_000).padStart(6, '0');
}

/** A code of a step after the last one used for the secret: the database refuses a step twice (ADR 0040). */
export class Authenticator {
  private last = -1;
  constructor(private readonly secret: Buffer) {}
  async next(): Promise<string> {
    let step = Math.floor(Date.now() / 30_000);
    while (step <= this.last) {
      await new Promise(r => setTimeout(r, 1_000));
      step = Math.floor(Date.now() / 30_000);
    }
    this.last = step;
    return totp(this.secret, step);
  }
}

/** The newest link to a page of the given path in the mail drop for an address; waits for the worker to send it. */
export async function linkSentTo(dir: string, email: string, path: string, timeoutMs = 60_000): Promise<string> {
  const end = Date.now() + timeoutMs;
  const pattern = new RegExp(`https://[^\\s]+${path.replace('/', '\\/')}#[a-z]+=[A-Za-z0-9_-]+`);
  while (Date.now() < end) {
    const files = readdirSync(dir).filter(f => f.endsWith('.eml')).map(f => join(dir, f))
      .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
    for (const f of files) {
      const text = readFileSync(f, 'utf8');
      if (!text.includes(`To: ${email}`)) continue;
      const m = text.match(pattern);
      if (m) return m[0];
    }
    await new Promise(r => setTimeout(r, 1_000));
  }
  throw new Error(`no ${path} link for ${email} in ${dir}`);
}
