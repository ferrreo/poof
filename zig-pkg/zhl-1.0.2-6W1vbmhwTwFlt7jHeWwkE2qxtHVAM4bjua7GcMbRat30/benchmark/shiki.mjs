import { createHighlighter } from 'shiki'
import { cases, readSource } from './cases.mjs'

const targetBytes = Number(process.env.ZHL_SHIKI_BYTES ?? 512_000)
const expectedRows = Number(process.env.ZHL_EXPECT_COMPARE_ROWS ?? cases.length)

globalThis.gc?.()
const memBeforeSetup = process.memoryUsage()
const highlighter = await createHighlighter({
  themes: ['nord'],
  langs: [...new Set(cases.map(([, lang]) => lang))],
})
globalThis.gc?.()
const memAfterSetup = process.memoryUsage()

let rows = 0
for (const [name, lang, path] of cases) {
  rows++
  const source = readSource(path)
  const lineCount = source.endsWith('\n') ? source.split('\n').length - 1 : source.split('\n').length
  const sourceBytes = Buffer.byteLength(source)
  const iterations = Math.max(5, Math.floor(targetBytes / Math.max(1, sourceBytes)))

  for (let i = 0; i < 20; i++) {
    highlighter.codeToTokens(source, { lang, theme: 'nord' })
  }

  globalThis.gc?.()
  const memBeforeHot = process.memoryUsage()
  const start = process.hrtime.bigint()
  let tokenCount = 0
  let bytes = 0

  for (let i = 0; i < iterations; i++) {
    const result = highlighter.codeToTokens(source, { lang, theme: 'nord' })
    for (const line of result.tokens) tokenCount += line.length
    bytes += sourceBytes
  }

  const elapsedNs = Number(process.hrtime.bigint() - start)
  globalThis.gc?.()
  const memAfterHot = process.memoryUsage()
  const seconds = elapsedNs / 1_000_000_000
  const mib = bytes / (1024 * 1024)

  console.log(`shiki ${name} TextMate`)
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

if (rows !== expectedRows) throw new Error(`shiki benchmark row count changed: ${rows} rows != ${expectedRows}`)
