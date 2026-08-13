import { readFileSync } from 'node:fs'
import { cases } from './cases.mjs'

const jsLabels = cases.map(([name]) => name)
const nativeSource = readFileSync(new URL('bench.zig', import.meta.url), 'utf8')
const syntectSource = readFileSync(new URL('syntect/src/main.rs', import.meta.url), 'utf8')
const syntectFancyManifest = readFileSync(new URL('syntect_fancy/Cargo.toml', import.meta.url), 'utf8')
const shikiSource = readFileSync(new URL('shiki.mjs', import.meta.url), 'utf8')
const vscodeTextMateSource = readFileSync(new URL('vscode_textmate.mjs', import.meta.url), 'utf8')
const wasmSource = readFileSync(new URL('wasm.mjs', import.meta.url), 'utf8')
const runCompareSource = readFileSync(new URL('run_compare.sh', import.meta.url), 'utf8')
const nativeGateSource = readFileSync(new URL('gate.sh', import.meta.url), 'utf8')
const buildSource = readFileSync(new URL('../build.zig', import.meta.url), 'utf8')
const nativeLabels = [...nativeSource.matchAll(/bench(?:Case|Sources)\("zhl ([^"]+) native"/g)].map((match) => match[1])
const syntectLabels = [...syntectSource.matchAll(/name: "([^"]+)"/g)].map((match) => match[1])

check('native zhl', nativeLabels)
check('syntect', syntectLabels)
checkJsRunnerLabels('shiki', shikiSource, 'shiki ${name} TextMate')
checkJsRunnerLabels('vscode-textmate', vscodeTextMateSource, 'vscode-textmate ${name} TextMate Oniguruma')
checkMetrics('native zhl', nativeSource, ['setup_allocs:', 'hot_allocs:', 'total_allocs:', 'setup_bytes:', 'hot_bytes:', 'total_bytes:'])
checkMetrics('wasm zhl', wasmSource, ['setup_allocs:', 'hot_allocs:', 'total_allocs:', 'setup_bytes:', 'hot_bytes:', 'total_bytes:', 'setup_heap:', 'hot_heap:', 'total_heap:'])
checkMetrics('shiki', shikiSource, ['setup_heap:', 'hot_heap:', 'total_heap:', 'setup_rss:', 'hot_rss:', 'total_rss:', 'setup_external:', 'hot_external:', 'total_external:', 'setup_buffers:', 'hot_buffers:', 'total_buffers:', 'alloc_counts:'])
checkMetrics('vscode-textmate', vscodeTextMateSource, ['setup_heap:', 'hot_heap:', 'total_heap:', 'setup_rss:', 'hot_rss:', 'total_rss:', 'setup_external:', 'hot_external:', 'total_external:', 'setup_buffers:', 'hot_buffers:', 'total_buffers:', 'alloc_counts:'])
checkMetrics('syntect', syntectSource, ['setup_allocs:', 'hot_allocs:', 'total_allocs:', 'setup_bytes:', 'hot_bytes:', 'total_bytes:'])
checkCompareRunner()
checkCompareBuildStep()
checkNativeGateRows()
checkSyntectFancyBench()
checkWasmBench()

function check(label, labels) {
  const expected = jsLabels.join('\n')
  const actual = labels.join('\n')
  if (actual !== expected) {
    throw new Error(`${label} benchmark cases differ from benchmark/cases.mjs\n--- expected\n${expected}\n--- actual\n${actual}`)
  }
}

function checkMetrics(label, source, required) {
  for (const metric of required) {
    if (!source.includes(metric)) throw new Error(`${label} benchmark missing metric ${metric}`)
  }
}

function checkJsRunnerLabels(label, source, outputLabel) {
  if (!source.includes("import { cases, readSource } from './cases.mjs'")) {
    throw new Error(`${label} benchmark does not import shared benchmark cases`)
  }
  if (!source.includes('for (const [name, lang, path] of cases)')) {
    throw new Error(`${label} benchmark does not iterate shared benchmark case labels`)
  }
  if (!source.includes(outputLabel)) {
    throw new Error(`${label} benchmark output label changed`)
  }
}

function checkCompareRunner() {
  const required = [
    'benchmark/gate.sh',
    'zig build wasm',
    'npm --prefix benchmark run wasm',
    'npm --prefix benchmark run shiki',
    'npm --prefix benchmark run vscode-textmate',
    'ZHL_EXPECT_COMPARE_ROWS=',
    'ZHL_SYNTECT_ENGINE=onig',
    'ZHL_SYNTECT_ENGINE=fancy-regex',
    'benchmark/syntect_fancy/Cargo.toml',
  ]
  for (const command of required) {
    if (!runCompareSource.includes(command)) throw new Error(`benchmark/run_compare.sh missing ${command}`)
  }
}

function checkCompareBuildStep() {
  const command = 'ZHL_SKIP_NATIVE_GATE=1 ZHL_SKIP_WASM=1 benchmark/run_compare.sh'
  if (!buildSource.includes(command)) {
    throw new Error(`build.zig benchmark compare step missing ${command}`)
  }
}

function checkNativeGateRows() {
  const match = /expected_rows=\$\{ZHL_EXPECT_NATIVE_ROWS:-(\d+)\}/.exec(nativeGateSource)
  if (!match) throw new Error('native benchmark gate row default missing')
  if (Number(match[1]) !== cases.length) {
    throw new Error(`native benchmark gate row default changed: ${match[1]} != ${cases.length}`)
  }
}

function checkSyntectFancyBench() {
  const required = [
    'path = "../syntect/src/main.rs"',
    'default-features = false',
    'default-fancy',
  ]
  for (const manifest of required) {
    if (!syntectFancyManifest.includes(manifest)) throw new Error(`syntect fancy benchmark missing ${manifest}`)
  }
}

function checkWasmBench() {
  if (!wasmSource.includes("'real TypeScript source'") || !wasmSource.includes("'TSX'")) throw new Error('wasm labels changed')
  if (!wasmSource.includes('zhl_wasm_case_count()')) throw new Error('wasm benchmark missing case count')
  if (!wasmSource.includes('zhl_wasm_corpus_lines(caseId)')) throw new Error('wasm benchmark missing corpus line metric')
  if (!wasmSource.includes('zhl_wasm_corpus_bytes(caseId)')) throw new Error('wasm benchmark missing corpus byte metric')
  const wasmExportSource = readFileSync(new URL('../src/runtime/wasm_export.zig', import.meta.url), 'utf8')
  if (!wasmExportSource.includes('@embedFile("zig_bench_corpus")')) throw new Error('wasm benchmark corpus changed')
  if (!wasmExportSource.includes('grammars.zig_0_16.grammar')) throw new Error('wasm benchmark grammar changed')
  if (!wasmExportSource.includes('pub export fn zhl_wasm_case_count() u32')) throw new Error('wasm case count export missing')
  if (!wasmExportSource.includes(`return ${cases.length};`)) throw new Error('wasm case count changed')
  if (!wasmExportSource.includes('grammars.typescript.grammar') || !wasmExportSource.includes('grammars.tsx.grammar')) throw new Error('wasm grammar routes changed')
}
