import { createOnigurumaEngine } from '@shikijs/engine-oniguruma'
import { INITIAL, Registry } from '@shikijs/vscode-textmate'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { cases, readSource } from './cases.mjs'

const targetBytes = Number(process.env.ZHL_VSCODE_TEXTMATE_BYTES ?? 512_000)
const expectedRows = Number(process.env.ZHL_EXPECT_COMPARE_ROWS ?? cases.length)

globalThis.gc?.()
const memBeforeSetup = process.memoryUsage()
const onig = await createOnigurumaEngine(import('shiki/wasm'))
const grammars = await loadGrammars([...new Set(cases.map(([, lang]) => lang))])
const registry = new Registry({
  onigLib: {
    createOnigScanner(patterns) { return onig.createScanner(patterns) },
    createOnigString(source) { return onig.createString(source) },
  },
  loadGrammar(scopeName) { return grammars.byScope.get(scopeName) },
})
const grammarByLang = new Map()
for (const [lang, scope] of grammars.scopeByLang) grammarByLang.set(lang, await registry.loadGrammar(scope))
globalThis.gc?.()
const memAfterSetup = process.memoryUsage()

let rows = 0
for (const [name, lang, path] of cases) {
  rows++
  const grammar = grammarByLang.get(lang)
  const source = readSource(path)
  const lines = splitLines(source)
  const lineCount = lines.length
  const sourceBytes = Buffer.byteLength(source)
  const iterations = Math.max(5, Math.floor(targetBytes / Math.max(1, sourceBytes)))

  for (let i = 0; i < 20; i++) tokenize(grammar, lines)

  globalThis.gc?.()
  const memBeforeHot = process.memoryUsage()
  const start = process.hrtime.bigint()
  let tokenCount = 0
  let bytes = 0

  for (let i = 0; i < iterations; i++) {
    tokenCount += tokenize(grammar, lines)
    bytes += sourceBytes
  }

  const elapsedNs = Number(process.hrtime.bigint() - start)
  globalThis.gc?.()
  const memAfterHot = process.memoryUsage()
  const seconds = elapsedNs / 1_000_000_000
  const mib = bytes / (1024 * 1024)

  console.log(`vscode-textmate ${name} TextMate Oniguruma`)
  console.log(`  lines:        ${iterations * lineCount}`)
  console.log(`  bytes:        ${bytes}`)
  console.log(`  tokens:       ${tokenCount}`)
  console.log(`  elapsed_ms:   ${(seconds * 1000).toFixed(3)}`)
  console.log(`  throughput:   ${(mib / seconds).toFixed(2)} MiB/s`)
  console.log(`  ns_per_line:  ${(elapsedNs / (iterations * lineCount)).toFixed(2)}`)
  console.log(`  setup_heap:   ${memAfterSetup.heapUsed - memBeforeSetup.heapUsed}`)
  console.log(`  setup_rss:    ${memAfterSetup.rss - memBeforeSetup.rss}`)
  console.log(`  setup_external:${memAfterSetup.external - memBeforeSetup.external}`)
  console.log(`  setup_buffers:${memAfterSetup.arrayBuffers - memBeforeSetup.arrayBuffers}`)
  console.log(`  hot_heap:     ${memAfterHot.heapUsed - memBeforeHot.heapUsed}`)
  console.log(`  hot_rss:      ${memAfterHot.rss - memBeforeHot.rss}`)
  console.log(`  hot_external: ${memAfterHot.external - memBeforeHot.external}`)
  console.log(`  hot_buffers:  ${memAfterHot.arrayBuffers - memBeforeHot.arrayBuffers}`)
  console.log(`  total_heap:   ${memAfterHot.heapUsed - memBeforeSetup.heapUsed}`)
  console.log(`  total_rss:    ${memAfterHot.rss - memBeforeSetup.rss}`)
  console.log(`  total_external:${memAfterHot.external - memBeforeSetup.external}`)
  console.log(`  total_buffers:${memAfterHot.arrayBuffers - memBeforeSetup.arrayBuffers}`)
  console.log(`  alloc_counts: unavailable-in-node`)
}

if (rows !== expectedRows) throw new Error(`vscode-textmate benchmark row count changed: ${rows} rows != ${expectedRows}`)

async function loadGrammars(langs) {
  const byScope = new Map()
  const scopeByLang = new Map()
  const dist = resolve('node_modules/@shikijs/langs/dist')
  for (const lang of langs) {
    const mod = await import(pathToFileURL(resolve(dist, `${lang}.mjs`)).href)
    for (const grammar of mod.default) if (grammar?.scopeName) byScope.set(grammar.scopeName, grammar)
    scopeByLang.set(lang, mod.default.at(-1).scopeName)
  }
  return { byScope, scopeByLang }
}

function splitLines(source) {
  return source.endsWith('\n') ? source.slice(0, -1).split('\n') : source.split('\n')
}

function tokenize(grammar, lines) {
  let state = INITIAL
  let count = 0
  for (const line of lines) {
    const result = grammar.tokenizeLine(line, state)
    count += result.tokens.length
    state = result.ruleStack
  }
  return count
}
