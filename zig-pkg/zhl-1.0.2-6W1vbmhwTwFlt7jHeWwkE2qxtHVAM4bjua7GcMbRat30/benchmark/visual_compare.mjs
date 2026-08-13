import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createHighlighter } from 'shiki'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const outDir = `${here}/visual`
const fixtureDir = `${outDir}/fixtures`
const outPath = `${outDir}/index.html`
const zhlc = process.env.ZHLC || `${root}/zig-out/bin/zhlc`
const zigSource = readFileSync(`${root}/tests/golden/zig_basic.input.zig`, 'utf8')

const styleColors = {
  plain: '#d8dee9',
  keyword: '#81a1c1',
  builtin: '#88c0d0',
  string: '#a3be8c',
  multiline_string: '#a3be8c',
  char: '#a3be8c',
  escape: '#d08770',
  format_placeholder: '#ebcb8b',
  number_integer: '#b48ead',
  number_float: '#b48ead',
  comment: '#616e88',
  doc_comment: '#616e88',
  container_doc_comment: '#616e88',
  function: '#88c0d0',
  type_name: '#8fbcbb',
  parameter: '#ebcb8b',
  operator: '#eceff4',
  punctuation: '#eceff4',
  label: '#d08770',
  field: '#d08770',
  invalid: '#bf616a',
}

if (!process.env.ZHLC) execFileSync('zig', ['build'], { cwd: root, stdio: 'inherit' })

const cases = [
  {
    id: 'zig-zhl',
    title: 'Zig 0.16 (.zhl grammar)',
    lang: 'zig',
    ext: 'zig',
    source: zigSource,
    probes: [
      { text: 'print', zhl: 'function', shiki: 'colored' },
      { text: '\\n', zhl: 'escape', zhlExact: true, zhlDistinctFrom: 'string', shiki: 'colored' },
      { text: ';', zhl: 'punctuation', shiki: 'colored' },
      { text: 'Thing', zhl: 'plain', shiki: 'plain' },
      { text: '// done', zhl: 'comment', shiki: 'colored', syntect: 'colored' },
    ],
  },
  {
    id: 'json-zhl',
    title: 'JSON (.zhl grammar)',
    lang: 'json',
    ext: 'json',
    source: '{\n  "name": "zhl",\n  "enabled": true,\n  "count": 42,\n  "items": ["zig", null]\n}\n',
    probes: [
      { text: '"name"', zhl: 'field', shiki: 'colored' },
      { text: '"zhl"', zhl: 'string', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'rust-zhl',
    title: 'Rust (.zhl grammar)',
    lang: 'rust',
    ext: 'rs',
    source: 'pub struct Thing { value: u32 }\nfn main() {\n    /* outer /* inner */ still */\n    let answer = 42;\n    println!("value={}", answer); // comment\n}\n',
    probes: [
      { text: 'pub', zhl: 'keyword', shiki: 'colored' },
      { text: 'Thing', zhl: 'type_name', shiki: 'colored' },
      { text: 'u32', zhl: 'builtin', shiki: 'colored' },
      { text: 'main', zhl: 'function', shiki: 'colored' },
      { text: '{}', zhl: 'format_placeholder', zhlExact: true, zhlDistinctFrom: 'string', shiki: 'colored' },
      { text: '/* outer /* inner */ still */', zhl: 'comment', shiki: 'colored' },
      { text: '// comment', zhl: 'comment', shiki: 'colored' },
    ],
  },
  {
    id: 'toml-zhl',
    title: 'TOML (.zhl grammar)',
    lang: 'toml',
    ext: 'toml',
    source: '[package]\nname = "zhl"\nversion = "1.0.0"\nenabled = true\ncount = 42\n',
    probes: [
      { text: 'name', zhl: 'field', shiki: 'plain' },
      { text: '"zhl"', zhl: 'string', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'yaml-zhl',
    title: 'YAML (.zhl grammar)',
    lang: 'yaml',
    ext: 'yaml',
    source: 'name: zhl\nenabled: true\ncount: 42\nitems:\n  - zig\n  - textmate\n',
    probes: [
      { text: 'name', zhl: 'field', shiki: 'colored' },
      { text: 'true', zhl: 'keyword', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
      { text: 'items', zhl: 'field', shiki: 'colored' },
    ],
  },
  {
    id: 'c-zhl',
    title: 'C (.zhl grammar)',
    lang: 'c',
    ext: 'c',
    source: 'int main(void) {\n    /* block comment */\n    printf("value=%d\\n", 42); // comment\n    return 0;\n}\n',
    probes: [
      { text: 'int', zhl: 'keyword', shiki: 'colored' },
      { text: 'printf', zhl: 'function', shiki: 'colored' },
      { text: '"value=%d\\n"', zhl: 'string', shiki: 'colored' },
      { text: 'return', zhl: 'keyword', shiki: 'colored' },
      { text: '/* block comment */', zhl: 'comment', shiki: 'colored' },
      { text: '0', zhl: 'number_integer', shiki: 'colored' },
      { text: '// comment', zhl: 'comment', shiki: 'colored' },
    ],
  },
  {
    id: 'cpp-zhl',
    title: 'C++ (.zhl grammar)',
    lang: 'cpp',
    ext: 'cpp',
    source: 'template <typename T>\nclass Box { public: T value; };\nint main() { Box<int> box{42}; return box.value; }\n',
    probes: [
      { text: 'template', zhl: 'keyword', shiki: 'colored' },
      { text: 'Box', zhl: 'type_name', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'csharp-zhl',
    title: 'C# (.zhl grammar)',
    lang: 'csharp',
    ext: 'cs',
    source: '[assembly: Demo]\n[Serializable, Route("box")]\npublic class Box { public string Format() { return "value"; } }\n',
    probes: [
      { text: '[assembly', zhl: 'function', shiki: 'colored' },
      { text: '[Serializable', zhl: 'function', shiki: 'colored' },
      { text: 'public', zhl: 'keyword', shiki: 'colored' },
      { text: 'Box', zhl: 'type_name', shiki: 'colored' },
      { text: '"value"', zhl: 'string', shiki: 'colored' },
    ],
  },
  {
    id: 'html-zhl',
    title: 'HTML (.zhl grammar)',
    lang: 'html',
    ext: 'html',
    source: '<!-- comment -->\n<main>&amp;</main>\n',
    probes: [
      { text: '<!-- comment -->', zhl: 'comment', shiki: 'colored' },
      { text: '<main', zhl: 'field', shiki: 'colored' },
    ],
  },
  {
    id: 'java-zhl',
    title: 'Java (.zhl grammar)',
    lang: 'java',
    ext: 'java',
    source: '@java.lang.Deprecated\npublic class Box { String format() { return "value"; } }\n',
    probes: [
      { text: '@java.lang.Deprecated', zhl: 'function', shiki: 'colored' },
      { text: 'public', zhl: 'keyword', shiki: 'colored' },
      { text: 'Box', zhl: 'type_name', shiki: 'colored' },
      { text: '"value"', zhl: 'string', shiki: 'colored' },
    ],
  },
  {
    id: 'kotlin-zhl',
    title: 'Kotlin (.zhl grammar)',
    lang: 'kotlin',
    ext: 'kt',
    source: '@file\n@kotlin.Deprecated\nclass Box { fun format(value: Int): String = "value=$value" }\n',
    probes: [
      { text: '@file', zhl: 'function', shiki: 'plain' },
      { text: '@kotlin.Deprecated', zhl: 'function', shiki: 'plain' },
      { text: 'class', zhl: 'keyword', shiki: 'colored' },
      { text: 'Box', zhl: 'type_name', shiki: 'colored' },
      { text: '"value=$value"', zhl: 'string', shiki: 'colored' },
    ],
  },
  {
    id: 'markdown-zhl',
    title: 'Markdown (.zhl grammar)',
    lang: 'markdown',
    ext: 'md',
    source: '# Title\n\n- item\n\n`code`\n',
    probes: [
      { text: '# Title', zhl: 'field', shiki: 'colored' },
      { text: '`code`', zhl: 'string', shiki: 'colored' },
      { text: '-', zhl: 'punctuation', shiki: 'colored' },
    ],
  },
  {
    id: 'php-zhl',
    title: 'PHP (.zhl grammar)',
    lang: 'php',
    ext: 'php',
    source: '<?php\nclass Box { public function format($value) { return "value=$value"; } }\n',
    probes: [
      { text: 'class', zhl: 'keyword', shiki: 'colored' },
      { text: 'format', zhl: 'function', shiki: 'colored' },
      { text: '$value', zhl: 'field', shiki: 'colored' },
    ],
  },
  {
    id: 'ruby-zhl',
    title: 'Ruby (.zhl grammar)',
    lang: 'ruby',
    ext: 'rb',
    source: 'class Box\n  def format(value)\n    "value=#{value}"\n  end\nend\n',
    probes: [
      { text: 'class', zhl: 'keyword', shiki: 'colored' },
      { text: 'format', zhl: 'function', shiki: 'colored' },
      { text: '"value=#{value}"', zhl: 'string', shiki: 'colored' },
    ],
  },
  {
    id: 'swift-zhl',
    title: 'Swift (.zhl grammar)',
    lang: 'swift',
    ext: 'swift',
    source: '@available\nstruct App { static func main() { let value = 42; print("value=\\(value)") } }\n',
    probes: [
      { text: '@available', zhl: 'function', shiki: 'colored' },
      { text: 'struct', zhl: 'keyword', shiki: 'colored' },
      { text: 'App', zhl: 'type_name', shiki: 'plain' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'jsx-zhl',
    title: 'JSX (.zhl grammar)',
    lang: 'jsx',
    ext: 'jsx',
    source: 'export function View() { return <section>{42}</section>; }\n',
    probes: [
      { text: 'export', zhl: 'keyword', shiki: 'colored' },
      { text: 'View', zhl: 'function', shiki: 'colored' },
      { text: '<section', zhl: 'field', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'tsx-zhl',
    title: 'TSX (.zhl grammar)',
    lang: 'tsx',
    ext: 'tsx',
    source: 'export function View(): Props { return <section>{42}</section>; }\n',
    probes: [
      { text: '): Props', zhl: 'type_name', shiki: 'colored' },
      { text: '<section', zhl: 'field', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'bash-zhl',
    title: 'Bash (.zhl grammar)',
    lang: 'bash',
    grammarLang: 'bash',
    ext: 'sh',
    source: '#!/usr/bin/env bash\nname="zhl"\nprintf "%s\\n" "$name"\n',
    probes: [
      { text: 'name', zhl: 'field', shiki: 'colored' },
      { text: '"zhl"', zhl: 'string', shiki: 'colored' },
      { text: 'printf', zhl: 'builtin', shiki: 'plain' },
    ],
  },
  {
    id: 'javascript-zhl',
    title: 'JavaScript (.zhl grammar)',
    lang: 'javascript',
    ext: 'js',
    source: 'const name = "zhl";\n/* block comment */\nconst count = 42;\n',
    probes: [
      { text: 'const', zhl: 'keyword', shiki: 'colored' },
      { text: '"zhl"', zhl: 'string', shiki: 'colored' },
      { text: '/* block comment */', zhl: 'comment', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'typescript-zhl',
    title: 'TypeScript (.zhl grammar)',
    lang: 'typescript',
    ext: 'ts',
    source: 'const name = "zhl"\n/* block comment */\ntype Thing = string\n',
    probes: [
      { text: 'const', zhl: 'keyword', shiki: 'colored' },
      { text: '"zhl"', zhl: 'string', shiki: 'colored' },
      { text: '/* block comment */', zhl: 'comment', shiki: 'colored' },
      { text: 'Thing', zhl: 'type_name', shiki: 'colored' },
      { text: 'string', zhl: 'builtin', shiki: 'colored' },
    ],
  },
  {
    id: 'python-zhl',
    title: 'Python (.zhl grammar)',
    lang: 'python',
    ext: 'py',
    source: '@pkg.dataclass\ndef greet(name):\n    value = 42\n',
    probes: [
      { text: '@pkg.dataclass', zhl: 'function', shiki: 'colored' },
      { text: 'def', zhl: 'keyword', shiki: 'colored' },
      { text: 'greet', zhl: 'function', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
    ],
  },
  {
    id: 'css-zhl',
    title: 'CSS (.zhl grammar)',
    lang: 'css',
    ext: 'css',
    source: '/* comment */ .class#id { color: #f00; content: "str"; font-size: 12px; background: url(https://ex.com/a.png); }\n@media (min-width: 10rem) { }',
    probes: [
      { text: '/* comment */', zhl: 'comment', shiki: 'colored' },
      { text: '"str"', zhl: 'string', shiki: 'colored' },
      { text: '12', zhl: 'number_integer', shiki: 'colored' },
      { text: '@media', zhl: 'keyword', shiki: 'colored' },
      { text: 'url', zhl: 'builtin', shiki: 'colored' },
      { text: '{ }', zhl: 'punctuation', shiki: 'colored' },
    ],
  },
  {
    id: 'go-zhl',
    title: 'Go (.zhl grammar)',
    lang: 'go',
    ext: 'go',
    source: 'package main\n\n// line comment\nfunc foo() {\n    value := 42\n    text := "hello\\nworld"\n    raw := `line one\nline two with backticks`\n    println(text, value)\n}\n',
    probes: [
      { text: 'package', zhl: 'keyword', shiki: 'colored' },
      { text: '// line comment', zhl: 'comment', shiki: 'colored' },
      { text: 'foo', zhl: 'function', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
      { text: '"hello\\nworld"', zhl: 'string', shiki: 'colored' },
      { text: 'println', zhl: 'builtin', shiki: 'colored' },
      { text: ':=', zhl: 'operator', shiki: 'colored' },
      // raw multiline probe exercises cross-line raw string (native block_comment rule)
      { text: 'line two with backticks', zhl: 'string', shiki: 'colored' },
    ],
  },
  {
    id: 'sql-zhl',
    title: 'SQL (.zhl grammar)',
    lang: 'sql',
    ext: 'sql',
    source: "-- line comment\nSELECT count FROM users WHERE name 'O''Reilly' LIMIT 42\n/* block comment */\n",
    probes: [
      { text: '-- line comment', zhl: 'comment', shiki: 'colored' },
      { text: 'SELECT', zhl: 'keyword', shiki: 'colored' },
      { text: '42', zhl: 'number_integer', shiki: 'colored' },
      { text: "'O''Reilly'", zhl: 'string', shiki: 'colored' },
      { text: '/* block comment */', zhl: 'comment', shiki: 'colored' },
    ],
  },
  {
    id: 'xml-zhl',
    title: 'XML (.zhl grammar)',
    lang: 'xml',
    ext: 'xml',
    source: '<?xml?>\n<!-- comment -->\n<root>&amp;<child></child></root>\n',
    probes: [
      { text: '<?xml', zhl: 'punctuation', shiki: 'colored' },
      { text: '<!-- comment -->', zhl: 'comment', shiki: 'colored' },
      { text: '<root', zhl: 'field', shiki: 'colored' },
      { text: '&amp;', zhl: 'char', shiki: 'colored' },
    ],
  },
]
const expectedCaseIds = [
  'zig-zhl',
  'json-zhl',
  'rust-zhl',
  'toml-zhl',
  'yaml-zhl',
  'c-zhl',
  'cpp-zhl',
  'csharp-zhl',
  'html-zhl',
  'java-zhl',
  'kotlin-zhl',
  'markdown-zhl',
  'php-zhl',
  'ruby-zhl',
  'swift-zhl',
  'jsx-zhl',
  'tsx-zhl',
  'bash-zhl',
  'javascript-zhl',
  'typescript-zhl',
  'python-zhl',
  'css-zhl',
  'go-zhl',
  'sql-zhl',
  'xml-zhl',
]
checkExpectedCases()

rmSync(outDir, { recursive: true, force: true })
mkdirSync(fixtureDir, { recursive: true })

const highlighter = await createHighlighter({
  themes: ['nord'],
  langs: [...new Set(cases.map((item) => item.lang))],
})

const results = []
const failures = []
for (const item of cases) {
  const sourcePath = `${fixtureDir}/${item.id}.${item.ext}`
  writeFileSync(sourcePath, item.source)
  const report = 'grammar_input=.zhl'
  const zhlRanges = parseZhlDump(execFileSync(zhlc, zhlArgs(item, sourcePath), { cwd: root, encoding: 'utf8' }))
  const shikiRanges = shikiToRanges(highlighter.codeToTokens(item.source, { lang: item.lang, theme: 'nord' }).tokens, defaultColor(item.lang))
  const syntectRanges = parseColorDump(execFileSync('cargo', [
    'run',
    '--release',
    '--quiet',
    '--manifest-path',
    `${here}/syntect/Cargo.toml`,
    '--bin',
    'zhl-syntect-bench',
    '--',
    'dump',
    sourcePath,
    item.ext,
  ], { cwd: root, encoding: 'utf8' }))
  const syntectDefault = mostCommonColor(syntectRanges)
  const result = { ...item, sourcePath, report, zhlRanges, shikiRanges, syntectRanges, syntectDefault, shikiDefault: defaultColor(item.lang) }
  failures.push(...checkProbes(result))
  failures.push(...checkCoverage(result))
  results.push(result)
}

writeFileSync(outPath, renderHtml(results))

if (failures.length !== 0) {
  console.error('Visual/token comparison failures:')
  for (const failure of failures) console.error(`  ${failure}`)
  console.error(`artifact: ${outPath}`)
  process.exit(1)
}

console.log(`visual compare ok: ${outPath}`)
for (const item of results) {
  console.log(`  ${item.id}: zhl=${item.zhlRanges.length} shiki=${item.shikiRanges.length} syntect=${item.syntectRanges.length} ${item.report}`)
}

function zhlArgs(item, sourcePath) {
  return ['dump', sourcePath, '--grammar', item.grammarLang ?? item.lang]
}

function checkExpectedCases() {
  const actual = cases.map((item) => item.id).join('\n')
  const expected = expectedCaseIds.join('\n')
  if (actual !== expected) throw new Error(`visual comparison cases changed\n--- expected\n${expected}\n--- actual\n${actual}`)
}

function parseZhlDump(text) {
  return text.trim().split('\n').filter(Boolean).map((row) => {
    const [line, start, end, style] = row.split(':')
    return { line: Number(line), start: Number(start), end: Number(end), style, color: styleColors[style] ?? styleColors.plain }
  })
}

function parseColorDump(text) {
  return text.trim().split('\n').filter(Boolean).map((row) => {
    const [line, start, end, color] = row.split(':')
    return { line: Number(line), start: Number(start), end: Number(end), color, style: color }
  })
}

function shikiToRanges(lines, defaultColorValue) {
  return lines.flatMap((line, lineNo) => {
    let col = 0
    return line.map((token) => {
      const start = col
      col += token.content.length
      return { line: lineNo, start, end: col, color: token.color ?? defaultColorValue, style: token.color ?? defaultColorValue }
    })
  })
}

function checkProbes(item) {
  const problems = []
  for (const probe of item.probes) {
    const range = findRange(item.source, probe.text)
    problems.push(...checkOne(item, 'zhl', item.zhlRanges, range, probe.zhl, styleColors.plain))
    if (probe.zhlExact) problems.push(...checkExactZhl(item, range, probe.zhl))
    if (probe.zhlDistinctFrom) problems.push(...checkDistinctZhl(item, range, probe.zhlDistinctFrom))
    problems.push(...checkOne(item, 'Shiki', item.shikiRanges, range, probe.shiki, item.shikiDefault))
    if (probe.syntect) problems.push(...checkOne(item, 'syntect', item.syntectRanges, range, probe.syntect, item.syntectDefault))
  }
  return problems
}

function checkDistinctZhl(item, probeRange, baselineStyle) {
  const baseline = styleColors[baselineStyle] ?? styleColors.plain
  for (let col = probeRange.start; col < probeRange.end; col++) {
    if (paintedColorAt(item.zhlRanges, probeRange.line, col, styleColors.plain) === baseline) {
      const text = item.source.split('\n')[probeRange.line].slice(probeRange.start, probeRange.end)
      return [`${item.id} zhl expected visible color over ${JSON.stringify(text)}`]
    }
  }
  return []
}

function checkExactZhl(item, probeRange, expectedStyle) {
  for (let col = probeRange.start; col < probeRange.end; col++) {
    if (paintedStyleAt(item.zhlRanges, probeRange.line, col, 'plain') !== expectedStyle) {
      const text = item.source.split('\n')[probeRange.line].slice(probeRange.start, probeRange.end)
      return [`${item.id} zhl expected style ${expectedStyle} over ${JSON.stringify(text)}`]
    }
  }
  return []
}

function checkOne(item, label, ranges, probeRange, expected, defaultColorValue) {
  const seen = ranges.filter((range) => range.line === probeRange.line && range.start < probeRange.end && range.end > probeRange.start)
  const styles = new Set(seen.map((range) => range.style))
  const colors = new Set(seen.map((range) => range.color))
  const text = item.source.split('\n')[probeRange.line].slice(probeRange.start, probeRange.end)
  if (expected === 'colored') {
    if (![...colors].some((color) => color !== defaultColorValue)) return [`${item.id} ${label} stayed plain over ${JSON.stringify(text)}`]
  } else if (expected === 'plain') {
    if ([...colors].some((color) => color !== defaultColorValue)) return [`${item.id} ${label} colored expected-plain ${JSON.stringify(text)}`]
  } else if (!styles.has(expected)) {
    return [`${item.id} ${label} expected ${expected} over ${JSON.stringify(text)}, saw ${[...styles].join(',') || 'none'}`]
  }
  return []
}

function checkCoverage(item) {
  const problems = []
  const lines = item.source.split('\n')
  for (let lineNo = 0; lineNo < lines.length; lineNo++) {
    const line = lines[lineNo]
    for (let col = 0; col < line.length; col++) {
      if (/\s/.test(line[col])) continue
      const zhlColored = coloredAt(item.zhlRanges, lineNo, col, styleColors.plain)
      const shikiColored = coloredAt(item.shikiRanges, lineNo, col, item.shikiDefault)
      if (shikiColored && !zhlColored) {
        problems.push(`${item.id} missing colored span at ${lineNo + 1}:${col + 1} ${JSON.stringify(line[col])}`)
        if (problems.length >= 12) return problems
      }
    }
  }
  return problems
}

function coloredAt(ranges, line, col, defaultColorValue) {
  return paintedColorAt(ranges, line, col, defaultColorValue) !== defaultColorValue
}

function paintedColorAt(ranges, line, col, defaultColorValue) {
  let color = defaultColorValue
  for (const range of ranges) {
    if (range.line !== line || range.start > col || range.end <= col) continue
    color = range.color
  }
  return color
}

function paintedStyleAt(ranges, line, col, defaultStyle) {
  let style = defaultStyle
  for (const range of ranges) {
    if (range.line !== line || range.start > col || range.end <= col) continue
    style = range.style
  }
  return style
}

function findRange(source, text) {
  const index = source.indexOf(text)
  if (index < 0) throw new Error(`missing probe ${JSON.stringify(text)}`)
  const prefix = source.slice(0, index)
  const line = prefix.split('\n').length - 1
  const start = prefix.length - prefix.lastIndexOf('\n') - 1
  return { line, start, end: start + text.length }
}

function defaultColor(lang) {
  return highlighter.codeToTokens('plain', { lang, theme: 'nord' }).tokens[0][0].color
}

function mostCommonColor(ranges) {
  const counts = new Map()
  for (const range of ranges) counts.set(range.color, (counts.get(range.color) ?? 0) + Math.max(1, range.end - range.start))
  return [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0]
}

function renderHtml(items) {
  return `<!doctype html>
<meta charset="utf-8">
<title>zhl visual compare</title>
<style>
body{margin:0;background:#1f2430;color:#d8dee9;font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
main{padding:24px;display:grid;gap:28px}
h1,h2{font:700 18px/1.2 system-ui,sans-serif;margin:0;color:#eceff4}
h2{font-size:15px}
.case{display:grid;gap:10px}
.grid{display:grid;grid-template-columns:70px repeat(3,minmax(0,1fr));gap:1px;background:#3b4252;border:1px solid #3b4252}
.head,.line-no,.cell{background:#2e3440;padding:6px 10px;white-space:pre;overflow:auto}
.head{font-weight:700;color:#eceff4;position:sticky;top:0}
.line-no{color:#7b8496;text-align:right}
.cell span{white-space:pre}
</style>
<main>
<h1>zhl visual compare</h1>
${items.map(renderCase).join('\n')}
</main>`
}

function renderCase(item) {
  const lines = item.source.split('\n')
  return `<section class="case">
<h2>${escapeHtml(item.title)}</h2>
<div class="grid">
<div class="head">line</div><div class="head">zhl</div><div class="head">Shiki nord</div><div class="head">syntect base16-ocean</div>
${lines.map((line, i) => `<div class="line-no">${i + 1}</div><div class="cell">${paint(line, rangesFor(item.zhlRanges, i), styleColors.plain)}</div><div class="cell">${paint(line, rangesFor(item.shikiRanges, i), item.shikiDefault)}</div><div class="cell">${paint(line, rangesFor(item.syntectRanges, i), item.syntectDefault)}</div>`).join('\n')}
</div>
</section>`
}

function rangesFor(ranges, line) {
  return ranges.filter((range) => range.line === line)
}

function paint(line, ranges, defaultColorValue) {
  const colors = Array.from(line, () => defaultColorValue)
  for (const range of ranges) {
    const start = Math.max(0, range.start)
    const end = Math.min(line.length, range.end)
    for (let i = start; i < end; i++) colors[i] = range.color
  }
  let out = ''
  let pos = 0
  while (pos < line.length) {
    const color = colors[pos]
    let end = pos + 1
    while (end < line.length && colors[end] === color) end++
    out += span(line.slice(pos, end), color)
    pos = end
  }
  return out || '&nbsp;'
}

function span(text, color) {
  return `<span style="color:${escapeAttr(color)}">${escapeHtml(text)}</span>`
}

function escapeHtml(text) {
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

function escapeAttr(text) {
  return String(text).replaceAll('"', '&quot;')
}
