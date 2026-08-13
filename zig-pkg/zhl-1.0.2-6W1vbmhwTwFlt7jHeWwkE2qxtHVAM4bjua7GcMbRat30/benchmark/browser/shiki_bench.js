// Browser benchmark for shiki (real TextMate grammars + oniguruma wasm).
// Methodology mirrors benchmark/esm_bench.mjs (shiki backend):
// 20 warmup runs, iterations = max(5, floor(targetBytes / sourceBytes)),
// timed with performance.now(). "tokens" column = span count
// (sum of per-line token array lengths from codeToTokens).
//
// Query params:
//   ?bytes=N     target bytes per case (default 512_000, matching esm_bench shiki)
//   ?cases=0,15  subset of case indices

import { createHighlighter } from './shiki_bundle.js'
import { cases, readSource } from './cases.js'

const WARMUP = 20
const statusEl = document.getElementById('status')
const errorEl = document.getElementById('error')
const tbody = document.querySelector('#results tbody')
const jsonEl = document.getElementById('results-json')
const encoder = new TextEncoder()

const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)))

function addRow(label, mibPerSec, nsPerLine, tokens) {
  const tr = document.createElement('tr')
  for (const text of [label, mibPerSec.toFixed(2), nsPerLine.toFixed(2), String(tokens)]) {
    const td = document.createElement('td')
    td.textContent = text
    tr.appendChild(td)
  }
  tbody.appendChild(tr)
}

try {
  const params = new URLSearchParams(location.search)
  const targetBytes = Number(params.get('bytes') ?? 512_000)

  let selectedCases = cases.map((c, i) => [i, c])
  if (params.get('cases')) {
    const indices = params.get('cases').split(',').map((s) => Number(s.trim()))
    selectedCases = indices.map((i) => {
      if (!cases[i]) throw new Error(`?cases: no case at index ${i}`)
      return [i, cases[i]]
    })
  }

  statusEl.textContent = 'initializing shiki…'
  const highlighter = await createHighlighter({
    themes: ['nord'],
    langs: [...new Set(cases.map(([, lang]) => lang))],
  })

  const run = (lang, source) => {
    const result = highlighter.codeToTokens(source, { lang, theme: 'nord' })
    let spans = 0
    for (const line of result.tokens) spans += line.length
    return spans
  }

  const rows = []
  const skipped = []
  let totalBytes = 0
  let totalNs = 0

  for (let n = 0; n < selectedCases.length; n++) {
    const [index, [label, lang, path]] = selectedCases[n]
    statusEl.textContent = `running ${n + 1}/${selectedCases.length}: ${label}`
    await nextFrame()

    try {
      const source = await readSource(path)
      const sourceBytes = encoder.encode(source).length
      const lines = source.split('\n').length
      const iterations = Math.max(5, Math.floor(targetBytes / Math.max(1, sourceBytes)))

      let count = 0
      for (let i = 0; i < WARMUP; i++) count = run(lang, source)
      if (!(count > 0)) throw new Error(`sanity failure: case ${index} "${label}" produced ${count} spans`)

      const start = performance.now()
      for (let i = 0; i < iterations; i++) count = run(lang, source)
      const elapsedNs = (performance.now() - start) * 1e6

      const bytes = sourceBytes * iterations
      const seconds = elapsedNs / 1e9
      const mibPerSec = bytes / (1024 * 1024) / seconds
      const nsPerLine = elapsedNs / (iterations * lines)

      totalBytes += bytes
      totalNs += elapsedNs

      addRow(label, mibPerSec, nsPerLine, count)
      rows.push({
        label,
        mibPerSec: Number(mibPerSec.toFixed(2)),
        nsPerLine: Number(nsPerLine.toFixed(2)),
        tokens: count,
      })
    } catch (caseErr) {
      // Skip failing cases (e.g. a lang missing in browser) rather than abort.
      skipped.push({ index, label, error: String(caseErr) })
      console.error(`case ${index} "${label}" skipped: ${caseErr}`)
    }
  }

  const totalMibPerSec = Number((totalBytes / (1024 * 1024) / (totalNs / 1e9)).toFixed(2))
  statusEl.textContent = `done — TOTAL ${totalMibPerSec} MiB/s${skipped.length ? ` (${skipped.length} skipped)` : ''}`

  window.__ZHL_BENCH_RESULTS__ = {
    backend: 'shiki-browser',
    runtime: navigator.userAgent,
    rows,
    totalMibPerSec,
    ...(skipped.length ? { skipped } : {}),
  }
  jsonEl.textContent = JSON.stringify(window.__ZHL_BENCH_RESULTS__)
  window.__ZHL_BENCH_DONE__ = true
} catch (err) {
  window.__ZHL_BENCH_ERROR__ = String(err)
  errorEl.textContent = String(err && err.stack ? err.stack : err)
  statusEl.textContent = 'error'
}
