import { createOnigurumaEngine } from '@shikijs/engine-oniguruma'
import { readFileSync } from 'node:fs'

const expectedCases = Number(process.env.ZHL_EXPECT_ONIG_CASES ?? 1324)
const expectedGeneratedCases = Number(process.env.ZHL_EXPECT_ONIG_GENERATED_CASES ?? 4)
const expectedChecked = Number(process.env.ZHL_EXPECT_ONIG_CHECKED ?? 1318)
const expectedSkipped = Number(process.env.ZHL_EXPECT_ONIG_SKIPPED ?? 10)
const expectedSkippedPatterns = new Set([
  '(?(?=a)yes|no)',
  '(?(?<=a)b|c)',
  '(?(?<!a)b|c)',
  '\\x{41 42}{2}',
  'a{2,3}+b',
  'a{,2}+a',
  'a{2,3}+a',
])
const nativeOnigSkippedCases = [
  ['a{2,3}+a', 'aaa', 0, [0, 3]],
  ['a{2,3}+a', 'aaaa', 0, [0, 4]],
  ['a{2,3}+b', 'aaab', 0, [0, 4]],
  ['a{2,3}+b', 'aab', 0, [0, 3]],
  ['a{,2}+a', 'aa', 0, [0, 2]],
  ['a{,2}+a', 'aaa', 0, [0, 3]],
]

const source = readFileSync(new URL('../src/regex/vm.zig', import.meta.url), 'utf8')
const nativeOnigSource = readFileSync(new URL('syntect/src/onig_cases.rs', import.meta.url), 'utf8')
const marker = 'test "regex VM runs table-driven Oniguruma conformance cases"'
const start = source.indexOf(marker)
if (start < 0) throw new Error('missing regex VM conformance test')
const tableStart = source.indexOf('const cases = [_]Case{', start)
const tableEnd = source.indexOf('};', tableStart)
if (tableStart < 0 || tableEnd < 0) throw new Error('missing conformance case table')

const cases = []
const caseRe = /\.{\s*\.pattern\s*=\s*("(?:\\.|[^"\\])*")\s*,\s*\.text\s*=\s*("(?:\\.|[^"\\])*")(.*?)},/gs
for (const match of source.slice(tableStart, tableEnd).matchAll(caseRe)) {
  const rest = match[3]
  const text = parseZigStringWithByteMap(match[2])
  const start = numberField(rest, 'start') ?? 0
  cases.push({
    pattern: parseZigString(match[1]),
    text: text.value,
    byteAtUnit: text.byteAtUnit,
    unitAtByte: text.unitAtByte,
    start,
    startUnit: unitOffset(text, start),
    wantStart: nullableNumberField(rest, 'want_start', 0),
    wantEnd: nullableNumberField(rest, 'want_end', undefined),
    wantCaptureSlot: numberField(rest, 'want_capture_slot') ?? 0,
    wantCaptureStart: nullableNumberField(rest, 'want_capture_start', undefined),
    wantCaptureEnd: nullableNumberField(rest, 'want_capture_end', undefined),
  })
}
if (cases.length === 0) throw new Error('no conformance cases parsed')
if (cases.length !== expectedCases) {
  throw new Error(`Oniguruma conformance case count changed: ${cases.length} rows != ${expectedCases}`)
}
const generatedCases = [
  asciiCase('\\s{300}', ' '.repeat(300), 0, 300),
  asciiCase('\\s{300}', ' '.repeat(299), null, null),
  asciiCase('a {0,1000}b', `a${' '.repeat(1000)}b`, 0, 1002),
  asciiCase('a {0,1000}b', `a${' '.repeat(1001)}b`, null, null),
]
if (generatedCases.length !== expectedGeneratedCases) {
  throw new Error(`generated Oniguruma conformance case count changed: ${generatedCases.length} rows != ${expectedGeneratedCases}`)
}
cases.push(...generatedCases)

const onig = await createOnigurumaEngine(import('shiki/wasm'))
let checked = 0
let skipped = 0
for (const c of cases) {
  if (shikiScannerDiverges(c.pattern)) {
    if (!expectedSkippedPatterns.has(c.pattern)) throw new Error(`unexpected skipped Oniguruma case: ${c.pattern}`)
    skipped += 1
    continue
  }
  if (expectedSkippedPatterns.has(c.pattern)) throw new Error(`expected skipped Oniguruma case was checked: ${c.pattern}`)
  const scanner = onig.createScanner([shikiPattern(c.pattern)])
  const text = onig.createString(c.text)
  const found = scanner.findNextMatchSync(text, c.startUnit)
  const exact = exactCapture(c, found)
  if (c.wantEnd == null) {
    if (exact) throw new Error(`expected no match: ${c.pattern} on ${JSON.stringify(c.text)}`)
    checked += 1
    continue
  }
  if (!exact) throw new Error(`expected match: ${c.pattern} on ${JSON.stringify(c.text)}`)
  const start = byteOffset(c, exact.start)
  const end = byteOffset(c, exact.end)
  if (start !== c.wantStart || end !== c.wantEnd) {
    throw new Error(`mismatch ${c.pattern}: got ${start}-${end}, want ${c.wantStart}-${c.wantEnd}`)
  }
  if (c.wantCaptureSlot !== 0) {
    const capture = found.captureIndices[c.wantCaptureSlot]
    const unset = !capture || capture.start < 0 || capture.start === 0xffffffff
    if (c.wantCaptureEnd == null) {
      if (!unset) throw new Error(`capture ${c.wantCaptureSlot} should be unset for ${c.pattern}`)
    } else if (unset || byteOffset(c, capture.start) !== c.wantCaptureStart || byteOffset(c, capture.end) !== c.wantCaptureEnd) {
      const got = unset ? 'unset' : `${byteOffset(c, capture.start)}-${byteOffset(c, capture.end)}`
      throw new Error(`capture ${c.wantCaptureSlot} mismatch ${c.pattern}: got ${got}, want ${c.wantCaptureStart}-${c.wantCaptureEnd}`)
    }
  }
  checked += 1
}
if (checked !== expectedChecked || skipped !== expectedSkipped) {
  throw new Error(`Oniguruma conformance coverage changed: ${checked} checked/${skipped} skipped != ${expectedChecked}/${expectedSkipped}`)
}
checkNativeOnigSkippedCoverage()
console.log(`oniguruma conformance cases ok: ${checked} checked, ${skipped} skipped`)

function checkNativeOnigSkippedCoverage() {
  for (const [pattern, text, start, want] of nativeOnigSkippedCases) {
    const row = `Case { pattern: r"${pattern}", text: "${text}", start: ${start}, want: Some((${want[0]}, ${want[1]})) }`
    if (!nativeOnigSource.includes(row)) throw new Error(`native onig skipped checker missing ${pattern} on ${text}`)
  }
}

function numberField(text, name) {
  const match = new RegExp(`\\.${name}\\s*=\\s*(\\d+)`).exec(text)
  return match ? Number(match[1]) : null
}

function nullableNumberField(text, name, fallback) {
  const match = new RegExp(`\\.${name}\\s*=\\s*(null|\\d+)`).exec(text)
  if (!match) return fallback
  return match[1] === 'null' ? null : Number(match[1])
}

function parseZigString(raw) {
  return parseZigStringWithByteMap(raw).value
}

function asciiCase(pattern, text, wantStart, wantEnd) {
  const offsets = Array.from({ length: text.length + 1 }, (_, i) => i)
  return {
    pattern,
    text,
    byteAtUnit: offsets,
    unitAtByte: offsets,
    start: 0,
    startUnit: 0,
    wantStart,
    wantEnd,
    wantCaptureSlot: 0,
    wantCaptureStart: null,
    wantCaptureEnd: null,
  }
}

function parseZigStringWithByteMap(raw) {
  const text = raw.slice(1, -1)
  let out = ''
  let bytes = 0
  const byteAtUnit = [0]
  const unitAtByte = [0]
  const append = (value, byteLen) => {
    const start = out.length
    out += value
    for (let i = start; i < out.length; i += 1) byteAtUnit[i] = bytes
    for (let i = 0; i < byteLen; i += 1) unitAtByte[bytes + i] = start
    bytes += byteLen
    byteAtUnit[out.length] = bytes
    unitAtByte[bytes] = out.length
  }
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] !== '\\') {
      const cp = text.codePointAt(i)
      const value = String.fromCodePoint(cp)
      append(value, Buffer.byteLength(value, 'utf8'))
      if (value.length === 2) i += 1
      continue
    }
    i += 1
    switch (text[i]) {
      case 'n': append('\n', 1); break
      case 'r': append('\r', 1); break
      case 't': append('\t', 1); break
      case '\\': append('\\', 1); break
      case '"': append('"', 1); break
      case 'x':
        append(String.fromCharCode(Number.parseInt(text.slice(i + 1, i + 3), 16)), 1)
        i += 2
        break
      case 'u': {
        if (text[i + 1] !== '{') throw new Error(`unsupported Zig unicode escape in ${raw}`)
        const close = text.indexOf('}', i + 2)
        if (close < 0) throw new Error(`unterminated Zig unicode escape in ${raw}`)
        const value = String.fromCodePoint(Number.parseInt(text.slice(i + 2, close), 16))
        append(value, Buffer.byteLength(value, 'utf8'))
        i = close
        break
      }
      default: append(text[i], 1)
    }
  }
  return { value: out, byteAtUnit, unitAtByte }
}

function byteOffset(c, unitOffset) {
  return c.byteAtUnit[unitOffset] ?? Buffer.byteLength(c.text.slice(0, unitOffset), 'utf8')
}

function unitOffset(c, byteOffset) {
  return c.unitAtByte[byteOffset] ?? c.value.length
}

function shikiScannerDiverges(pattern) {
  return pattern.includes('(?(?') ||
    pattern.includes('\\x{41 42}') ||
    /\{\d*,?\d*\}\+/.test(pattern)
}

function shikiPattern(pattern) {
  return pattern.includes('\\K') ? `\\G(?:${pattern})` : pattern
}

function exactCapture(c, found) {
  const capture = found?.captureIndices[0]
  if (!capture) return null
  return c.pattern.includes('\\K') || capture.start === c.startUnit ? capture : null
}
