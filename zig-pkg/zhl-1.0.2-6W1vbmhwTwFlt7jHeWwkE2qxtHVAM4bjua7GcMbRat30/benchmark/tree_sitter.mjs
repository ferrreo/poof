import { execFileSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { isAbsolute, join, resolve } from 'node:path'
import { performance } from 'node:perf_hooks'

const require = createRequire(import.meta.url)
const Parser = require('tree-sitter')
const JavaScript = require('tree-sitter-javascript')

const JAVASCRIPT_LANGUAGE_ID = 9
const source = 'function add(a) { return a + 1 }'
const querySource = `
(function_declaration name: (identifier) @function)
(formal_parameters (identifier) @parameter)
(return_statement "return" @keyword)
(number) @number
`

const repoRoot = fileURLToPath(new URL('../', import.meta.url))
const zhlcArg = process.env.ZHLC ?? 'zig-out/bin/zhlc'
const zhlc = isAbsolute(zhlcArg) ? zhlcArg : resolve(repoRoot, zhlcArg)
const temp = mkdtempSync(join(tmpdir(), 'zhl-tree-sitter-'))
const sourcePath = join(temp, 'tree-sitter.js')
writeFileSync(sourcePath, `${source}\n`)

const parser = new Parser()
const setupStart = performance.now()
parser.setLanguage(JavaScript)
const query = new Parser.Query(JavaScript, querySource)
const setupMs = performance.now() - setupStart

const parseStart = performance.now()
const tree = parser.parse(source)
const captures = queryCaptures(query, tree.rootNode)
const parseMs = performance.now() - parseStart

const dump = execFileSync(zhlc, ['dump', sourcePath, '--grammar', 'javascript'], { encoding: 'utf8' })
const nativeTokens = parseDump(dump)

const overlayStart = performance.now()
const overlaid = overlay(source.length, nativeTokens, captures)
const overlayMs = performance.now() - overlayStart

assertToken(overlaid, source.indexOf('add'), 'add', 'function', JAVASCRIPT_LANGUAGE_ID)
assertToken(overlaid, source.indexOf('(a)') + 1, 'a', 'parameter', JAVASCRIPT_LANGUAGE_ID)
assertToken(overlaid, source.indexOf('return'), 'return', 'keyword', JAVASCRIPT_LANGUAGE_ID)
assertToken(overlaid, source.indexOf('1'), '1', 'number_integer', JAVASCRIPT_LANGUAGE_ID)

writeVisual(nativeTokens, overlaid)

console.log('tree-sitter JavaScript overlay')
console.log(`  lines:        1`)
console.log(`  bytes:        ${Buffer.byteLength(source)}`)
console.log(`  captures:     ${captures.length}`)
console.log(`  native_tokens:${nativeTokens.length}`)
console.log(`  overlay_tokens:${overlaid.length}`)
console.log(`  setup_ms:     ${setupMs.toFixed(3)}`)
console.log(`  parse_ms:     ${parseMs.toFixed(3)}`)
console.log(`  overlay_ms:   ${overlayMs.toFixed(3)}`)
console.log(`  visual:       benchmark/visual/tree_sitter_overlay.html`)

function queryCaptures(query, rootNode) {
  const captures = []
  for (const match of query.matches(rootNode)) {
    for (const capture of match.captures) {
      captures.push({
        start: capture.node.startIndex,
        end: capture.node.endIndex,
        style: styleFromCapture(capture.name),
        language: JAVASCRIPT_LANGUAGE_ID,
      })
    }
  }
  captures.sort((a, b) => a.start - b.start || a.end - b.end)
  for (let i = 1; i < captures.length; i += 1) {
    if (captures[i].start < captures[i - 1].end) throw new Error('overlapping tree-sitter captures')
  }
  return captures
}

function styleFromCapture(name) {
  if (name === 'function') return 'function'
  if (name === 'parameter') return 'parameter'
  if (name === 'keyword') return 'keyword'
  if (name === 'number') return 'number_integer'
  return 'plain'
}

function parseDump(dump) {
  const tokens = []
  for (const line of dump.trim().split('\n')) {
    const [lineNo, start, end, style, scope, language] = line.split(':')
    if (lineNo !== '0') continue
    tokens.push({
      start: Number(start),
      end: Number(end),
      style,
      scope,
      language: Number(language),
    })
  }
  return tokens
}

function overlay(lineLen, baseTokens, captures) {
  const output = []
  let captureIndex = 0
  let cursor = 0
  for (const base of baseTokens) {
    emitSegment(output, cursor, base.start, 'plain', 0, captures, () => captureIndex, (value) => { captureIndex = value })
    emitSegment(output, base.start, base.end, base.style, base.language, captures, () => captureIndex, (value) => { captureIndex = value })
    cursor = base.end
  }
  emitSegment(output, cursor, lineLen, 'plain', 0, captures, () => captureIndex, (value) => { captureIndex = value })
  return output
}

function emitSegment(output, start, end, style, language, captures, getIndex, setIndex) {
  let captureIndex = getIndex()
  let pos = start
  while (captureIndex < captures.length && captures[captureIndex].end <= start) captureIndex += 1
  while (captureIndex < captures.length && captures[captureIndex].start < end) {
    const capture = captures[captureIndex]
    if (capture.start > pos) emit(output, pos, Math.min(capture.start, end), style, language)
    const captureStart = Math.max(pos, capture.start)
    const captureEnd = Math.min(end, capture.end)
    emit(output, captureStart, captureEnd, capture.style, capture.language)
    pos = captureEnd
    if (capture.end <= pos) captureIndex += 1
    else break
  }
  emit(output, pos, end, style, language)
  setIndex(captureIndex)
}

function emit(output, start, end, style, language) {
  if (end <= start) return
  output.push({ start, end, style, language })
}

function assertToken(tokens, start, needle, style, language) {
  const end = start + needle.length
  const found = tokens.some((token) => token.start <= start && token.end >= end && token.style === style && token.language === language)
  if (!found) throw new Error(`missing overlay token ${needle}:${style}:${language}`)
}

function writeVisual(nativeTokens, overlaid) {
  const outDir = new URL('visual/', import.meta.url)
  mkdirSync(outDir, { recursive: true })
  writeFileSync(new URL('tree_sitter_overlay.html', outDir), `<!doctype html>
<meta charset="utf-8">
<title>zhl Tree-sitter overlay</title>
<style>
body{font:14px/1.5 system-ui,sans-serif;margin:24px;color:#202124}
pre{padding:12px;border:1px solid #dadce0;border-radius:6px;overflow:auto}
.keyword{color:#7b1fa2}.function{color:#0b57d0}.parameter{color:#b3261e}.number_integer{color:#0b8043}.operator{color:#5f6368}.plain{color:#202124}
</style>
<h1>zhl Tree-sitter overlay</h1>
<h2>native JavaScript</h2>
<pre>${render(nativeTokens)}</pre>
<h2>Tree-sitter overlay</h2>
<pre>${render(overlaid)}</pre>
`)
}

function render(tokens) {
  return tokens.map((token) => `<span class="${token.style}">${escapeHtml(source.slice(token.start, token.end))}</span>`).join('')
}

function escapeHtml(text) {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
