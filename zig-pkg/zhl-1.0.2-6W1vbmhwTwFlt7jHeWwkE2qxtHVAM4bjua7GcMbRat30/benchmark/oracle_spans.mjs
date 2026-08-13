import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createOnigurumaEngine } from '@shikijs/engine-oniguruma'
import { INITIAL, Registry } from '@shikijs/vscode-textmate'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const zhlc = process.env.ZHLC || `${root}/zig-out/bin/zhlc`
const outPath = process.env.ZHL_ORACLE_SPANS_OUT || `${root}/zig-out/compatibility/oracle_spans.jsonl`
const cases = [
  { name: 'json', lang: 'json', grammar: 'json', fixture: 'tests/fixtures/languages/json-textmate.json' },
  { name: 'javascript', lang: 'javascript', grammar: 'javascript', fixture: 'tests/fixtures/languages/javascript-textmate.js' },
  { name: 'python', lang: 'python', grammar: 'python', fixture: 'tests/fixtures/languages/python-textmate.py' },
]

mkdirSync(dirname(outPath), { recursive: true })

const rows = []
let failed = false
const onig = await createOnigurumaEngine(import('shiki/wasm'))

for (const item of cases) {
  const source = readFileSync(resolve(root, item.fixture), 'utf8')
  const oracle = await oracleSpans(item, source)
  const zhl = zhlSpans(item)
  const oracleKeys = new Set(oracle.map(spanKey))
  const zhlKeys = new Set(zhl.map(spanKey))
  const missing = zhl.filter((span) => !oracleKeys.has(spanKey(span)))
  const extra = oracle.filter((span) => !zhlKeys.has(spanKey(span)))
  const exact = missing.length === 0 && extra.length === 0

  rows.push({
    schema: 'zhl.oracle-spans.v1',
    case: item.name,
    language: item.lang,
    fixture: item.fixture,
    oracle: 'vscode-textmate',
    state: exact ? 'supported' : 'unsupported',
    reason_code: exact ? 'ZHL-COMPAT-TEXTMATE-001' : null,
    reason: exact ? 'structured spans match selected TextMate oracle fixture' : 'structured spans differ from selected TextMate oracle fixture',
    accepted_divergences: 0,
    zhl_spans: zhl.length,
    oracle_spans: oracle.length,
    missing: missing.length,
    extra: extra.length,
    samples: exact ? [] : [...missing.slice(0, 5), ...extra.slice(0, 5)],
  })
  failed ||= !exact
}

writeFileSync(outPath, `${rows.map((row) => JSON.stringify(row)).join('\n')}\n`)

if (failed) {
  console.error(`oracle span mismatch; wrote ${outPath}`)
  process.exit(1)
}

console.log(`oracle spans ok: ${cases.length} cases; wrote ${outPath}`)

async function oracleSpans(item, source) {
  const langModule = await import(pathToFileURL(resolve(here, `node_modules/@shikijs/langs/dist/${item.lang}.mjs`)).href)
  const byScope = new Map()
  for (const grammar of langModule.default) if (grammar?.scopeName) byScope.set(grammar.scopeName, grammar)
  const rootScope = langModule.default.at(-1)?.scopeName
  const registry = new Registry({
    onigLib: {
      createOnigScanner(patterns) { return onig.createScanner(patterns) },
      createOnigString(text) { return onig.createString(text) },
    },
    loadGrammar(scopeName) { return byScope.get(scopeName) },
  })
  const grammar = await registry.loadGrammar(rootScope)
  if (!grammar) throw new Error(`${item.name}: missing oracle grammar ${rootScope}`)

  const lines = source.endsWith('\n') ? source.slice(0, -1).split('\n') : source.split('\n')
  const spans = []
  let state = INITIAL
  for (const [lineNo, line] of lines.entries()) {
    const styles = Array(line.length).fill('plain')
    const result = grammar.tokenizeLine(line, state)
    state = result.ruleStack
    for (const token of result.tokens) {
      const style = oracleStyle(token.scopes)
      if (!style) continue
      for (let col = token.startIndex; col < token.endIndex; col++) styles[col] = style
    }
    spans.push(...lineSpans(lineNo, styles))
  }
  return spans
}

function zhlSpans(item) {
  const text = execFileSync(zhlc, ['dump', resolve(root, item.fixture), '--grammar', item.grammar], { cwd: root, encoding: 'utf8' })
  return text.trim().split('\n').filter(Boolean).flatMap((row) => {
    const parts = row.split(':')
    const style = zhlStyle(parts[3])
    if (!style) return []
    return [{ line: Number(parts[0]), start: Number(parts[1]), end: Number(parts[2]), style }]
  })
}

function lineSpans(line, styles) {
  const spans = []
  for (let start = 0; start < styles.length;) {
    const style = styles[start]
    let end = start + 1
    while (end < styles.length && styles[end] === style) end++
    if (style !== 'plain') spans.push({ line, start, end, style })
    start = end
  }
  return spans
}

function zhlStyle(style) {
  if (style === 'field') return 'string'
  if (style === 'number_integer' || style === 'number_float') return 'number'
  if (['keyword', 'string', 'comment', 'function', 'builtin', 'type_name'].includes(style)) return style
  return null
}

function oracleStyle(scopes) {
  const joined = scopes.join(' ')
  if (joined.includes('comment')) return 'comment'
  if (joined.includes('string') || joined.includes('punctuation.definition.string')) return 'string'
  if (joined.includes('constant.numeric')) return 'number'
  if (joined.includes('constant.language')) return 'keyword'
  if (scopes.some((scope) => scope.startsWith('keyword') && !scope.startsWith('keyword.operator'))) return 'keyword'
  if (joined.includes('storage.type') || joined.includes('storage.modifier')) return 'keyword'
  if (joined.includes('entity.name.function')) return 'function'
  if (joined.includes('support.function.builtin') || joined.includes('variable.language') || joined.includes('support.constant')) return 'builtin'
  if (joined.includes('support.type') || joined.includes('entity.name.type')) return 'type_name'
  return null
}

function spanKey(span) {
  return `${span.line}:${span.start}:${span.end}:${span.style}`
}
