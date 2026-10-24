/**
 * Activity publisher: who is working, who is not, and what each session is
 * doing right now — the real harness telemetry `dsh-work-game` renders,
 * republished to `watch.kluser.me` so the phone sees it.
 *
 * Event surface (verified against the harness checkout, same as the
 * dsh-work-game adapter): `sessions.list()` and `sessions.on(name, handler)`
 * with `agent/status` ({agent, status}) and `session/event` (session, event).
 * @module dsh-project-launcher/activity
 */
import type { ActivityWire } from './hub.ts';
/** The hub slice the publisher needs (narrowed for tests). */
export interface HubLike {
    publishActivity(sessions: ActivityWire[]): Promise<void>;
}
/** Narrowed session catalogue slice (`ctx.sessions`). */
export interface SessionsLike {
    list(): Array<{
        id: string;
        header?: {
            cwd?: string;
            title?: string;
        };
    }>;
}
/**
 * Event source: on the HOST these are Cordis events (`ctx.on`), not store
 * methods — the `sessions.on` shape belongs to the browser store. Both are
 * accepted here so the publisher works either side.
 */
export interface EventsLike {
    on(event: string, handler: (...args: unknown[]) => void): () => void;
}
/** Publisher options. */
export interface ActivityDeps {
    readonly hub: HubLike;
    readonly sessions: SessionsLike;
    /** Cordis-style events (host) — falls back to `sessions.on` when absent. */
    readonly events?: EventsLike;
    readonly intervalMs?: number;
    readonly log?: (message: string) => void;
}
/** Default logger: stderr, so failures never disappear silently. */
export declare function defaultLog(message: string): void;
/** Start publishing snapshots; returns the disposer. */
export declare function startActivityPublisher(deps: ActivityDeps): () => void;
/** One short human line for one session event (what the agent is doing). */
export declare function lineOf(event: {
    type?: string;
    data?: Record<string, unknown>;
}): string;
