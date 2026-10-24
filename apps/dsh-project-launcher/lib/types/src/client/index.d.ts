/**
 * Browser half of `dsh-project-launcher`: one chip in the New-Conversation
 * overlay that lists the projects and fires a prompt in a chosen project
 * **already inside a fresh, named worktree**.
 *
 * Self-contained on purpose: the file compiles to CommonJS and is wrapped in
 * the platform's module-loader factory, so every import must be a module-table
 * word (`react`, `@deepseek-ai/cordis`) and nothing local may leak in.
 * @module dsh-project-launcher/client
 */
import type { Context as ClientContext } from '@deepseek-ai/cordis';
/** Required services: session navigation and the overlay-slot contribution. */
export declare const inject: string[];
/** Client plugin body: contribute the launcher chip to the overlay slot. */
export declare function apply(ctx: ClientContext): void;
