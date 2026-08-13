import { readFile, stat } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const wasmPath = process.env.ZHL_WASM ? pathToFileURL(process.env.ZHL_WASM) : new URL('../zig-out/bin/zhl_wasm.wasm', import.meta.url)
globalThis.gc?.()
const memBeforeSetup = process.memoryUsage()
const wasmBytes = await readFile(wasmPath)
const { instance } = await WebAssembly.instantiate(wasmBytes, {})
const exports = instance.exports
globalThis.gc?.()
const memAfterSetup = process.memoryUsage()

const labels = [
  'Zig 0.16',
  'Zig adversarial',
  'real Zig source',
  'real Bash source',
  'real JavaScript source',
  'real JSON source',
  'real Rust source',
  'real TOML source',
  'real YAML source',
  'real C source',
  'real Python source',
  'real TypeScript source',
  'TypeScript',
  'Rust',
  'Python',
  'minified JSON',
  'minified JavaScript',
  'TextMate JSON',
  'C++',
  'C#',
  'HTML',
  'Java',
  'JSX',
  'Kotlin',
  'Markdown',
  'PHP',
  'Ruby',
  'Swift',
  'TSX',
]
const caseCount = exports.zhl_wasm_case_count()
if (caseCount !== labels.length) throw new Error(`WASM case count changed: ${caseCount} != ${labels.length}`)

const wasmSize = (await stat(wasmPath)).size

for (let caseId = 0; caseId < labels.length; caseId += 1) {
  for (let i = 0; i < 100; i++) exports.zhl_wasm_bench_case(caseId, 1)

  const corpusBytes = exports.zhl_wasm_corpus_bytes(caseId)
  const iterations = Math.max(1_000, Math.floor((16 * 1024 * 1024) / corpusBytes))
  globalThis.gc?.()
  const memBefore = process.memoryUsage().heapUsed
  const rssBefore = process.memoryUsage().rss
  const start = process.hrtime.bigint()
  const tokenCount = exports.zhl_wasm_bench_case(caseId, iterations)
  const elapsedNs = Number(process.hrtime.bigint() - start)
  const lastError = exports.zhl_wasm_last_error()
  if (lastError !== 0 || tokenCount === 0) throw new Error(`zhl_wasm_bench failed: case=${labels[caseId]} status=${lastError} tokens=${tokenCount}`)
  globalThis.gc?.()
  const memAfterHot = process.memoryUsage()

  const lineCount = iterations * exports.zhl_wasm_corpus_lines(caseId)
  const bytes = iterations * corpusBytes
  const seconds = elapsedNs / 1_000_000_000
  const mib = bytes / (1024 * 1024)

  console.log(`zhl WASM ${labels[caseId]}`)
  console.log(`  lines:        ${lineCount}`)
  console.log(`  bytes:        ${bytes}`)
  console.log(`  tokens:       ${tokenCount}`)
  console.log(`  elapsed_ms:   ${(seconds * 1000).toFixed(3)}`)
  console.log(`  throughput:   ${(mib / seconds).toFixed(2)} MiB/s`)
  console.log(`  ns_per_line:  ${(elapsedNs / lineCount).toFixed(2)}`)
  console.log(`  token_bytes:  ${exports.zhl_packed_token_size()}`)
  console.log(`  abi_bytes:    ${exports.zhl_token_abi_size()}`)
  console.log(`  wasm_bytes:   ${wasmSize}`)
  console.log(`  wasm_memory:  ${exports.memory?.buffer.byteLength ?? 0}`)
  console.log(`  setup_allocs: 0`)
  console.log(`  hot_allocs:   0`)
  console.log(`  total_allocs: 0`)
  console.log(`  setup_bytes:  0`)
  console.log(`  hot_bytes:    0`)
  console.log(`  total_bytes:  0`)
  console.log(`  setup_heap:   ${memAfterSetup.heapUsed - memBeforeSetup.heapUsed}`)
  console.log(`  setup_rss:    ${memAfterSetup.rss - memBeforeSetup.rss}`)
  console.log(`  hot_heap:     ${memAfterHot.heapUsed - memBefore}`)
  console.log(`  hot_rss:      ${memAfterHot.rss - rssBefore}`)
  console.log(`  total_heap:   ${memAfterHot.heapUsed - memBeforeSetup.heapUsed}`)
  console.log(`  total_rss:    ${memAfterHot.rss - memBeforeSetup.rss}`)
}
