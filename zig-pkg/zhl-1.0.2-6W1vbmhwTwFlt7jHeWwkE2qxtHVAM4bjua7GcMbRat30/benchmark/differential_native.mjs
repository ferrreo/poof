import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHighlighter } from 'shiki'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const zhlc = process.env.ZHLC || `${root}/zig-out/bin/zhlc`
const textmateDir = `${root}/grammars/textmate`

const cases = [
  ['bash', 'bash', 'sh'],
  ['c', 'c', 'c'],
  ['cpp', 'cpp', 'cpp'],
  ['csharp', 'csharp', 'cs'],
  ['css', 'css', 'css'],
  ['go', 'go', 'go'],
  ['html', 'html', 'html'],
  ['java', 'java', 'java'],
  ['javascript', 'javascript', 'js'],
  ['jsx', 'jsx', 'jsx'],
  ['json', 'json', 'json'],
  ['kotlin', 'kotlin', 'kt'],
  ['markdown', 'markdown', 'md'],
  ['php', 'php', 'php'],
  ['python', 'python', 'py'],
  ['ruby', 'ruby', 'rb'],
  ['rust', 'rust', 'rs'],
  ['sql', 'sql', 'sql'],
  ['swift', 'swift', 'swift'],
  ['toml', 'toml', 'toml'],
  ['tsx', 'tsx', 'tsx'],
  ['typescript', 'typescript', 'ts'],
  ['xml', 'xml', 'xml'],
  ['yaml', 'yaml', 'yaml'],
  ['zig', 'zig', 'zig'],
]
const expectedCaseNames = ['bash', 'c', 'cpp', 'csharp', 'css', 'go', 'html', 'java', 'javascript', 'jsx', 'json', 'kotlin', 'markdown', 'php', 'python', 'ruby', 'rust', 'sql', 'swift', 'toml', 'tsx', 'typescript', 'xml', 'yaml', 'zig']
checkExpectedCases()

const important = new Set(['keyword', 'builtin', 'string', 'number_integer', 'comment', 'function', 'operator'])
const ignoredStyles = {
  bash: new Set(['builtin']),
  kotlin: new Set(['function', 'keyword', 'operator']),
  yaml: new Set(['string']),
}
const highlighter = await createHighlighter({ themes: ['nord'], langs: cases.map(([, lang]) => lang) })
const failures = []
let checked = 0

for (const [name, lang, ext] of cases) {
  const fixture = `${root}/tests/fixtures/languages/${name}-textmate.${ext}`
  const grammar = `${root}/grammars/textmate/${name}.tmLanguage.json`
  const source = readFileSync(fixture, 'utf8')
  if (existsSync(grammar)) {
    const report = execFileSync(zhlc, ['report-textmate-json', grammar, '--include-dir', textmateDir], { cwd: root, encoding: 'utf8' }).trim()
    const missing = /missing=(\d+)/.exec(report)
    const externalMissing = /external_missing=(\d+)/.exec(report)
    if (!missing || Number(missing[1]) !== 0 || !externalMissing || Number(externalMissing[1]) !== 0) failures.push(`${name}: ${report}`)
  }

  const zhl = parseZhlDump(execFileSync(zhlc, ['dump', fixture, '--grammar', name], { cwd: root, encoding: 'utf8' }))
  const shiki = shikiToRanges(highlighter.codeToTokens(source, { lang, theme: 'nord' }).tokens, defaultColor(lang))
  const lines = source.split('\n')

  for (const row of zhl) {
    if (!important.has(row.style)) continue
    if (ignoredStyles[name]?.has(row.style)) continue
    const text = lines[row.line]?.slice(row.start, row.end) ?? ''
    if (text.trim().length === 0) continue
    checked += 1
    if (!overlapsColored(shiki, row)) failures.push(`${name}:${row.line}:${row.start}:${row.end}:${row.style}:${text}`)
  }
}

if (checked === 0) failures.push('no important native spans checked')
if (failures.length !== 0) {
  console.error('Native differential failures:')
  for (const failure of failures) console.error(`  ${failure}`)
  process.exit(1)
}

console.log(`native differential ok: ${cases.length} grammars, ${checked} zhl spans checked`)

function checkExpectedCases() {
  const names = cases.map(([name]) => name)
  if (names.join('\n') !== expectedCaseNames.join('\n')) {
    throw new Error(`native differential route list changed\n--- expected\n${expectedCaseNames.join('\n')}\n--- actual\n${names.join('\n')}`)
  }
}

function parseZhlDump(text) {
  return text.trim().split('\n').filter(Boolean).map((row) => {
    const [line, start, end, style] = row.split(':')
    return { line: Number(line), start: Number(start), end: Number(end), style }
  })
}

function shikiToRanges(lines, defaultColorValue) {
  return lines.flatMap((line, lineNo) => {
    let col = 0
    return line.map((token) => {
      const start = col
      col += token.content.length
      return { line: lineNo, start, end: col, colored: (token.color ?? defaultColorValue) !== defaultColorValue }
    })
  })
}

function defaultColor(lang) {
  return highlighter.codeToTokens('plain', { lang, theme: 'nord' }).tokens[0]?.[0]?.color ?? ''
}

function overlapsColored(ranges, row) {
  return ranges.some((range) => range.line === row.line && range.start < row.end && range.end > row.start && range.colored)
}
