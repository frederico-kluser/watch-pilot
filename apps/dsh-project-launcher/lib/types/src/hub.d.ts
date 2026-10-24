/**
 * Hub client for the plugin: the phone talks only to `watch.kluser.me`, and this
 * plugin bridges that queue into worktrees. Auth is the hub's own TOTP (RFC 6238,
 * SHA-1, 6 digits, 30 s) generated from the pairing secret on this machine.
 * @module dsh-project-launcher/hub
 */
/** RFC 4648 base32 decode (the hub stores Google-Authenticator base32). */
export declare function base32Decode(value: string): Buffer;
/** One TOTP code for `at` (seconds). Mirrors `server/app/security.py`. */
export declare function totpCode(secret: string, at?: number, period?: number): string;
/** Read the hub's pairing secret (the same file the CLI and apps use). */
export declare function readSecret(path?: string): string;
/** One launch request, mirrored from the hub wire. */
export interface LaunchWire {
    launch_id: string;
    prompt: string;
    project: string;
    new_story: boolean;
    story_name: string;
    status: string;
    worktree_path?: string;
    session_id?: string;
}
/** One activity entry the plugin publishes. */
export interface ActivityWire {
    id: string;
    name: string;
    state: 'running' | 'idle' | 'waiting';
    line: string;
    workspace?: string;
    model?: string;
}
/** Minimal hub API the plugin needs. */
export declare class HubClient {
    private readonly base;
    private readonly secret;
    private readonly fetcher;
    constructor(base: string, secret: string, fetcher?: typeof fetch);
    static live(base?: string): HubClient;
    private call;
    /** The queue the plugin drains. */
    pendingLaunches(): Promise<LaunchWire[]>;
    /** Report one milestone back (running/completed/failed → notification). */
    report(launchId: string, body: {
        status: string;
        detail?: string;
        worktree_path?: string;
        session_id?: string;
    }): Promise<void>;
    /** Publish one activity snapshot (who works, who does not, what they type). */
    publishActivity(sessions: ActivityWire[]): Promise<void>;
}
