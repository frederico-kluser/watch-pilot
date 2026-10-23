/**
 * Minimal type shims for the browser half.
 *
 * The client bundle requires `react` from the platform module table at load
 * time, so no React package exists at build time: this file declares the tiny
 * slice the panel uses. `@deepseek-ai/cordis` is likewise a type-only word.
 */

declare module 'react' {
  export type ReactNode = unknown
  export function createElement(type: unknown, props?: unknown, ...children: unknown[]): unknown
  export function useState<T>(initial: T | (() => T)): [T, (value: T | ((previous: T) => T)) => void]
  export function useEffect(effect: () => void | (() => void), dependencies?: unknown[]): void
}

declare module '@deepseek-ai/cordis' {
  export interface Context {
    get(name: string): unknown
    effect(disposer: () => void | (() => void), label?: string): void
    slots?: unknown
  }
}
