// Unified ESM benchmark harness for zhl backends and shiki.
// Runs under both Node and Bun:
//   node esm_bench.mjs <wasm|node-ffi|shiki>
//   bun  esm_bench.mjs <wasm|node-ffi|bun-ffi|shiki>
//
// Env:
//   ZHL_BENCH_BYTES  - target bytes per case (default: 512_000 for shiki, 64 MiB otherwise)
//   ZHL_BENCH_CASES  - comma-separated case indices to subset (e.g. "0,15")

import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { cases, readSource } from './cases.mjs'

const BACKENDS = ['wasm', 'node-ffi', 'bun-ffi', 'shiki']
const backend = process.argv[2]
if (!BACKENDS.includes(backend)) {
  console.error(`usage: esm_bench.mjs <${BACKENDS.join('|')}>`)
  process.exit(1)
}

const isBun = typeof Bun !== 'undefined'
const runtime = isBun ? 'bun' : 'node'
if (backend === 'bun-ffi' && !isBun) {
  console.error('bun-ffi backend requires the bun runtime: bun esm_bench.mjs bun-ffi')
  process.exit(1)
}

const targetBytes = Number(process.env.ZHL_BENCH_BYTES ?? (backend === 'shiki' ? 512_000 : 64 * 1024 * 1024))

let selectedCases = cases.map((c, i) => [i, c])
if (process.env.ZHL_BENCH_CASES) {
  const indices = process.env.ZHL_BENCH_CASES.split(',').map((s) => Number(s.trim()))
  selectedCases = indices.map((i) => {
    if (!cases[i]) throw new Error(`ZHL_BENCH_CASES: no case at index ${i}`)
    return [i, cases[i]]
  })
}

const WARMUP = 20

// Set up the backend; returns run(lang, source) -> token/span count for one pass.
async function setup() {
  if (backend === 'wasm') {
    const { init } = await import('../packages/zhl-wasm/index.js')
    const wasmPath = fileURLToPath(new URL('../zig-out/bin/zhl_api.wasm', import.meta.url))
    const zhl = await init(await readFile(wasmPath))
    return { resolveLang: (name) => mustLangId(zhl, name), run: (langId, source) => zhl.highlightTokenCount(langId, source) }
  }
  if (backend === 'node-ffi') {
    const { open } = await import('../packages/zhl-node/index.js')
    const zhl = open()
    return { resolveLang: (name) => mustLangId(zhl, name), run: (langId, source) => zhl.highlightTokenCount(langId, source) }
  }
  if (backend === 'bun-ffi') {
    const { open } = await import('../packages/zhl-bun/index.js')
    const zhl = open()
    return { resolveLang: (name) => mustLangId(zhl, name), run: (langId, source) => zhl.highlightTokenCount(langId, source) }
  }
  // shiki
  const { createHighlighter } = await import('shiki')
  const highlighter = await createHighlighter({
    themes: ['nord'],
    langs: [...new Set(cases.map(([, lang]) => lang))],
  })
  return {
    resolveLang: (name) => name,
    run: (lang, source) => {
      const result = highlighter.codeToTokens(source, { lang, theme: 'nord' })
      let spans = 0
      for (const line of result.tokens) spans += line.length
      return spans
    },
  }
}

function mustLangId(zhl, name) {
  const id = zhl.languageId(name)
  if (id === 0) throw new Error(`unknown language: ${name}`)
  return id
}

const { resolveLang, run } = await setup()

const results = []
let totalBytes = 0
let totalNs = 0n

for (const [index, [label, lang, path]] of selectedCases) {
  const source = readSource(path)
  const sourceBytes = Buffer.byteLength(source, 'utf8')
  const lines = source.split('\n').length
  const iterations = Math.max(5, Math.floor(targetBytes / Math.max(1, sourceBytes)))
  const langHandle = resolveLang(lang)

  let count = 0
  for (let i = 0; i < WARMUP; i++) count = run(langHandle, source)
  if (!(count > 0)) throw new Error(`sanity failure: case ${index} "${label}" produced ${count} tokens`)

  const start = process.hrtime.bigint()
  for (let i = 0; i < iterations; i++) count = run(langHandle, source)
  const elapsedNs = process.hrtime.bigint() - start

  const bytes = sourceBytes * iterations
  const seconds = Number(elapsedNs) / 1e9
  const mibPerSec = bytes / (1024 * 1024) / seconds
  const nsPerLine = Number(elapsedNs) / (iterations * lines)

  totalBytes += bytes
  totalNs += elapsedNs

  console.log(`${backend}\t${label}\t${mibPerSec.toFixed(2)}\t${nsPerLine.toFixed(2)}\t${count}`)
  results.push({
    index,
    label,
    lang,
    sourceBytes,
    lines,
    iterations,
    elapsedNs: Number(elapsedNs),
    mibPerSec: Number(mibPerSec.toFixed(2)),
    nsPerLine: Number(nsPerLine.toFixed(2)),
    tokensOrSpans: count,
  })
}

const totalSeconds = Number(totalNs) / 1e9
const totalMibPerSec = totalBytes / (1024 * 1024) / totalSeconds
console.log(`${backend}\tTOTAL\t${totalMibPerSec.toFixed(2)}\t\t`)

const outDir = fileURLToPath(new URL('results/', import.meta.url))
await mkdir(outDir, { recursive: true })
const outFile = `${outDir}${backend}-${runtime}.json`
await writeFile(outFile, JSON.stringify({
  backend,
  runtime,
  targetBytes,
  warmup: WARMUP,
  timestamp: new Date().toISOString(),
  total: {
    bytes: totalBytes,
    elapsedNs: Number(totalNs),
    mibPerSec: Number(totalMibPerSec.toFixed(2)),
  },
  cases: results,
}, null, 2) + '\n')
console.error(`wrote ${outFile}`)
