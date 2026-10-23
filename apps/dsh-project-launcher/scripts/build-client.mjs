/**
 * Browser-bundle build for `dsh-project-launcher`.
 *
 * The platform loads browser halves through its module loader:
 * `window.__ModuleLoader__.load({ id, factory })`, where `factory(require)`
 * answers module-table words (here: `react`) and the plugin body returns its
 * exports. The client compiles to CommonJS first (one self-contained file), so
 * the wrapper is a straight concatenation — no bundler, no surprises.
 * @module scripts/build-client
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const TSC = join(ROOT, 'node_modules/typescript/bin/tsc')
const BUILD_DIR = join(ROOT, 'lib/client-cjs')
const OUT = join(ROOT, 'lib/client.cjs')
const PLUGIN_ID = 'dsh-project-launcher'

mkdirSync(BUILD_DIR, { recursive: true })
execFileSync('node', [
  TSC,
  join(ROOT, 'types/shims.d.ts'),
  join(ROOT, 'src/client/index.ts'),
  '--module', 'commonjs',
  '--target', 'ES2023',
  '--moduleResolution', 'node',
  '--outDir', BUILD_DIR,
  '--skipLibCheck',
  '--strict',
  '--ignoreConfig',
  '--ignoreDeprecations', '6.0',
], { stdio: 'inherit' })

const body = readFileSync(join(BUILD_DIR, 'index.js'), 'utf8')
const bundle = `window.__ModuleLoader__.load({
\tid: "${PLUGIN_ID}",
\tfactory: (require) => {
\t\tvar module = { exports: {} };
\t\tvar exports = module.exports;
${body.split('\n').map((line) => `\t\t${line}`).join('\n')}
\t\treturn module.exports; }
});
`
writeFileSync(OUT, bundle)
console.log(`→ ${OUT} (${bundle.length} bytes)`)
