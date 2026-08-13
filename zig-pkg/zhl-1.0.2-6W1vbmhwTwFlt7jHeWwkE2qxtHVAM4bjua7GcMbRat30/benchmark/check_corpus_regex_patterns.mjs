import { execFile } from 'node:child_process'
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { availableParallelism } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

const zhlc = process.env.ZHLC
if (!zhlc) {
  console.error('ZHLC must point at zhlc')
  process.exit(1)
}

const cache = process.env.ZHL_CORPUS_CACHE ?? '.zig-cache/zhl-corpus'
const outDir = process.env.ZHL_COMPATIBILITY_DIR ?? 'zig-out/compatibility'
const workDir = '.zig-cache/corpus-regex-patterns'
const textmateDir = join(cache, 'grammars/textmate')
const sublimePartsDir = join(cache, 'grammars/sublime')
const sublimeDir = join(workDir, 'sublime')
const outFile = join(outDir, 'corpus-regex-patterns.jsonl')

mkdirSync(outDir, { recursive: true })
rmSync(workDir, { recursive: true, force: true })
mkdirSync(sublimeDir, { recursive: true })

const tasks = []
const jobs = Number(process.env.ZHL_CORPUS_REGEX_JOBS ?? 0) || availableParallelism()

for (const file of files(textmateDir, '.tmLanguage.json')) {
  const path = join(textmateDir, file)
  const extracted = extractTextMatePatterns(JSON.parse(readFileSync(path, 'utf8'))).length
  tasks.push(async () => {
    const report = await runJson('report-textmate-json', [path, '--json', '--include-dir', textmateDir])
    const ok = report.missing === 0 && report.external_missing === 0 && report.skipped === 0
    return {
      schema: 'zhl.corpus-regex-pattern.v1',
      kind: 'textmate-json',
      source: rel(path),
      extracted,
      patterns: report.patterns,
      supported: report.supported,
      missing: report.missing,
      external_missing: report.external_missing,
      skipped: report.skipped,
      ok,
    }
  })
}

for (const file of files(sublimePartsDir, '.sublime-syntax.part00')) {
  const base = file.slice(0, -'.part00'.length)
  const path = join(sublimeDir, base)
  writeFileSync(path, parts(sublimePartsDir, base + '.part').map((part) => readFileSync(join(sublimePartsDir, part), 'utf8')).join(''))
  const extracted = extractSublimePatterns(readFileSync(path, 'utf8')).length
  tasks.push(async () => {
    const report = await runJson('report-sublime', [path, '--json'])
    const ok = report.missing === 0 && report.skipped === 0
    return {
      schema: 'zhl.corpus-regex-pattern.v1',
      kind: 'sublime-syntax',
      source: rel(join(sublimePartsDir, file)),
      extracted,
      patterns: report.patterns,
      supported: report.supported,
      missing: report.missing,
      skipped: report.skipped,
      ok,
    }
  })
}

const records = await runTasks(tasks)
records.sort((a, b) => a.kind.localeCompare(b.kind) || a.source.localeCompare(b.source))
writeFileSync(outFile, records.map((record) => JSON.stringify(record)).join('\n') + '\n')

if (records.some((record) => !record.ok)) {
  console.error(`unsupported corpus regex patterns; see ${outFile}`)
  process.exit(1)
}

console.log(`corpus regex patterns ok: ${records.length} grammars -> ${outFile}`)

function files(dir, suffix) {
  return readdirSync(dir).filter((file) => file.endsWith(suffix)).sort()
}

function parts(dir, prefix) {
  return readdirSync(dir).filter((file) => file.startsWith(prefix)).sort()
}

function rel(path) {
  return path.startsWith(cache + '/') ? path.slice(cache.length + 1) : path
}

async function runJson(command, args) {
  const { stdout } = await execFileAsync(zhlc, [command, ...args], { encoding: 'utf8', maxBuffer: 1024 * 1024 * 16 })
  return JSON.parse(stdout.trim())
}

async function runTasks(taskList) {
  let index = 0
  const records = []
  const workerCount = Math.max(1, Math.min(jobs, taskList.length))
  await Promise.all(Array.from({ length: workerCount }, async () => {
    for (;;) {
      const task = taskList[index++]
      if (!task) return
      records.push(await task())
    }
  }))
  return records
}

function extractTextMatePatterns(value, out = []) {
  if (Array.isArray(value)) {
    for (const item of value) extractTextMatePatterns(item, out)
    return out
  }
  if (!value || typeof value !== 'object') return out

  for (const field of ['firstLineMatch', 'match', 'begin', 'end', 'while']) {
    if (typeof value[field] === 'string') out.push({ field, pattern: value[field] })
  }
  for (const child of Object.values(value)) extractTextMatePatterns(child, out)
  return out
}

function extractSublimePatterns(source) {
  const out = []
  for (const line of source.split(/\r?\n/)) {
    const match = /^\s*-?\s*(first_line_match|match|escape):\s*(.*)$/.exec(line)
    if (!match) continue
    const value = unquoteYamlScalar(match[2])
    if (value && value !== '|' && value !== '>') out.push({ field: match[1], pattern: value })
  }
  return out
}

function unquoteYamlScalar(value) {
  const trimmed = value.trim()
  if (trimmed.length < 2) return trimmed
  if (trimmed[0] === "'" && trimmed.at(-1) === "'") return trimmed.slice(1, -1).replaceAll("''", "'")
  if (trimmed[0] === '"' && trimmed.at(-1) === '"') return trimmed.slice(1, -1)
  return trimmed
}
