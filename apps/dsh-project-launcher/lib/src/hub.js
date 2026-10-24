/**
 * Hub client for the plugin: the phone talks only to `watch.kluser.me`, and this
 * plugin bridges that queue into worktrees. Auth is the hub's own TOTP (RFC 6238,
 * SHA-1, 6 digits, 30 s) generated from the pairing secret on this machine.
 * @module dsh-project-launcher/hub
 */
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
/** RFC 4648 base32 decode (the hub stores Google-Authenticator base32). */
export function base32Decode(value) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    const clean = value.replace(/=+$/, '').toUpperCase().replace(/\s/g, '');
    let bits = 0;
    let accumulator = 0;
    const out = [];
    for (const char of clean) {
        const index = alphabet.indexOf(char);
        if (index === -1)
            continue;
        accumulator = (accumulator << 5) | index;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            out.push((accumulator >> bits) & 0xff);
        }
    }
    return Buffer.from(out);
}
/** One TOTP code for `at` (seconds). Mirrors `server/app/security.py`. */
export function totpCode(secret, at = Date.now() / 1000, period = 30) {
    const counter = Math.floor(at / period);
    const payload = Buffer.alloc(8);
    payload.writeBigUInt64BE(BigInt(counter));
    const digest = createHmac('sha1', base32Decode(secret)).update(payload).digest();
    const offset = digest[digest.length - 1] & 0x0f;
    const binary = ((digest[offset] & 0x7f) << 24) | (digest[offset + 1] << 16)
        | (digest[offset + 2] << 8) | digest[offset + 3];
    return String(binary % 1_000_000).padStart(6, '0');
}
/** Read the hub's pairing secret (the same file the CLI and apps use). */
export function readSecret(path = join(homedir(), '.config/watch-pilot/totp.secret')) {
    return readFileSync(path, 'utf8').trim().toUpperCase();
}
/** Minimal hub API the plugin needs. */
export class HubClient {
    base;
    secret;
    fetcher;
    constructor(base, secret, fetcher = fetch) {
        this.base = base;
        this.secret = secret;
        this.fetcher = fetcher;
    }
    static live(base = process.env['WATCHPILOT_URL'] ?? 'https://watch.kluser.me') {
        return new HubClient(base.replace(/\/$/, ''), readSecret());
    }
    async call(path, init = {}) {
        const response = await this.fetcher(`${this.base}${path}`, {
            ...init,
            headers: {
                accept: 'application/json',
                'content-type': 'application/json',
                'x-watch-totp': totpCode(this.secret),
                ...(init.headers ?? {}),
            },
        });
        if (!response.ok) {
            throw new Error(`hub ${path} → HTTP ${response.status}`);
        }
        return response.json();
    }
    /** The queue the plugin drains. */
    async pendingLaunches() {
        const payload = (await this.call('/api/v1/launches?pending=1'));
        return payload.items ?? [];
    }
    /** Report one milestone back (running/completed/failed → notification). */
    async report(launchId, body) {
        await this.call(`/api/v1/launches/${launchId}/report`, {
            method: 'POST',
            body: JSON.stringify(body),
        });
    }
    /** Publish one activity snapshot (who works, who does not, what they type). */
    async publishActivity(sessions) {
        await this.call('/api/v1/activity', {
            method: 'POST',
            body: JSON.stringify({ sessions }),
        });
    }
}
