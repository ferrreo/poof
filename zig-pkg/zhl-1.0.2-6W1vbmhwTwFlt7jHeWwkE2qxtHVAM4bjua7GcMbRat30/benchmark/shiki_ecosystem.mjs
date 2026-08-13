import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { availableParallelism, tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { languageNames } from '@shikijs/langs'
import { bundledLanguagesInfo } from 'shiki'

const here = dirname(fileURLToPath(import.meta.url))
const root = dirname(here)
const zhlc = process.env.ZHLC || `${root}/zig-out/bin/zhlc`
const dist = resolve(here, 'node_modules/@shikijs/langs/dist')
const tmp = mkdtempSync(`${tmpdir()}/zhl-shiki-`)
const jobs = workerCount()
const expectedLanguages = Number(process.env.ZHL_EXPECT_SHIKI_LANGUAGES ?? 253)
const expectedScopes = Number(process.env.ZHL_EXPECT_SHIKI_SCOPES ?? 301)
const expectedIncludeRoots = Number(process.env.ZHL_EXPECT_SHIKI_INCLUDE_ROOTS ?? 111)
const expectedIncludeScopes = Number(process.env.ZHL_EXPECT_SHIKI_INCLUDE_SCOPES ?? 138)
const expectedIncludePairs = Number(process.env.ZHL_EXPECT_SHIKI_INCLUDE_PAIRS ?? 723)

try {
  const byScope = new Map()
  const byLang = new Map()
  const targets = []

  for (const lang of languageNames) {
    const mod = await import(pathToFileURL(resolve(dist, `${lang}.mjs`)).href)
    for (const grammar of mod.default) {
      if (!grammar?.scopeName) continue
      registerLanguageAliases(byLang, grammar)
      if (!byScope.has(grammar.scopeName)) writeGrammar(byScope, grammar)
    }
    const target = mod.default.at(-1)
    if (target?.scopeName) targets.push([lang, target.scopeName, byScope.get(target.scopeName)])
  }
  addScopeAliases(byScope, byLang)
  const includeStats = dependencyStats(byScope)

  const reports = new Array(targets.length)
  let next = 0
  const workers = Array.from({ length: Math.min(jobs, targets.length) }, async () => {
    while (next < targets.length) {
      const index = next++
      reports[index] = await checkTarget(targets[index])
    }
  })
  await Promise.all(workers)

  const failures = []
  for (let index = 0; index < targets.length; index += 1) {
    const [lang, scope] = targets[index]
    const report = reports[index]
    const missing = Number(/missing=(\d+)/.exec(report)?.[1] ?? 1)
    const external = Number(/external_missing=(\d+)/.exec(report)?.[1] ?? 1)
    const converted = Number(/converted=(\d+)/.exec(report)?.[1] ?? 0)
    const skipped = Number(/skipped=(\d+)/.exec(report)?.[1] ?? 1)
    const generated = Number(/native-zig .* rules=(\d+)/.exec(report)?.[1] ?? 0)
    const ok = report.includes('native ') && report.includes('generated-module ok') && !report.includes('error:')
    if (missing !== 0 || external !== 0 || converted === 0 || skipped !== 0 || generated === 0 || !ok) failures.push(`${lang} ${scope}: ${report}`)
  }

  if (failures.length !== 0) {
    console.error(`shiki ecosystem unsupported: ${failures.length}/${targets.length}`)
    for (const failure of failures) console.error(failure)
    process.exit(1)
  }
  if (targets.length !== expectedLanguages || byScope.size !== expectedScopes) {
    throw new Error(`shiki ecosystem count changed: ${targets.length} languages/${byScope.size} scopes != ${expectedLanguages}/${expectedScopes}`)
  }
  if (includeStats.roots !== expectedIncludeRoots || includeStats.scopes !== expectedIncludeScopes || includeStats.pairs !== expectedIncludePairs) {
    throw new Error(`shiki dependency graph changed: ${includeStats.roots} roots/${includeStats.scopes} scopes/${includeStats.pairs} pairs != ${expectedIncludeRoots}/${expectedIncludeScopes}/${expectedIncludePairs}`)
  }
  console.log(`shiki ecosystem ok: ${targets.length} languages, ${byScope.size} scopes converted, ${includeStats.pairs} dependency pairs`)
} finally {
  rmSync(tmp, { recursive: true, force: true })
}

function safeName(value) {
  return value.replace(/[^A-Za-z0-9_.-]+/g, '_')
}

function writeGrammar(byScope, grammar) {
  const file = `${tmp}/${byScope.size}-${safeName(grammar.scopeName)}.tmLanguage.json`
  byScope.set(grammar.scopeName, file)
  writeFileSync(file, JSON.stringify(grammar))
}

function registerLanguageAliases(byLang, grammar) {
  const names = new Set([grammar.name, ...(grammar.aliases ?? [])].filter(Boolean))
  for (const part of grammar.scopeName.split(/[.#]/)) {
    if (part.length > 1) names.add(part)
  }
  for (const info of bundledLanguagesInfo) {
    if (info.id === grammar.name || info.aliases?.includes(grammar.name)) {
      names.add(info.id)
      for (const alias of info.aliases ?? []) names.add(alias)
    }
  }
  for (const name of names) byLang.set(name, grammar)
}

function addScopeAliases(byScope, byLang) {
  writeGrammar(byScope, { scopeName: 'text.plain', name: 'plaintext', patterns: [] })
  let changed = true
  while (changed) {
    changed = false
    const missing = unresolvedScopes(byScope)
    for (const scope of missing) {
      if (byScope.has(scope)) continue
      const grammar = grammarForScopeAlias(scope, byLang)
      if (!grammar) continue
      writeGrammar(byScope, { ...grammar, scopeName: scope })
      changed = true
    }
  }
}

function unresolvedScopes(byScope) {
  const missing = new Set()
  for (const [scope, file] of byScope) {
    const grammar = JSON.parse(readFileSync(file, 'utf8'))
    collectUnresolved(grammar, scope, byScope, missing, new Set())
  }
  return missing
}

function dependencyStats(byScope) {
  const roots = new Set()
  const scopes = new Set()
  const pairs = new Set()
  for (const [scope, file] of byScope) {
    const grammar = JSON.parse(readFileSync(file, 'utf8'))
    for (const include of includeScopes(grammar)) {
      if (include === scope || !byScope.has(include)) continue
      roots.add(scope)
      scopes.add(include)
      pairs.add(`${scope}->${include}`)
    }
  }
  return { roots: roots.size, scopes: scopes.size, pairs: pairs.size }
}

function collectUnresolved(grammar, rootScope, byScope, missing, visited) {
  for (const include of includeScopes(grammar)) {
    const external = byScope.get(include)
    if (include === rootScope) continue
    if (!external) {
      missing.add(include)
      continue
    }
    if (visited.has(include)) continue
    visited.add(include)
    collectUnresolved(JSON.parse(readFileSync(external, 'utf8')), rootScope, byScope, missing, visited)
  }
}

function includeScopes(value, out = []) {
  if (!value || typeof value !== 'object') return out
  if (typeof value.include === 'string' && externalInclude(value.include)) out.push(value.include.split('#')[0])
  if (Array.isArray(value.patterns)) for (const pattern of value.patterns) includeScopes(pattern, out)
  if (value.repository) for (const child of Object.values(value.repository)) includeScopes(child, out)
  if (value.injections) for (const child of Object.values(value.injections)) includeScopes(child, out)
  return out
}

function externalInclude(value) {
  return value !== '$self' && value !== '$base' && !value.startsWith('#')
}

function grammarForScopeAlias(scope, byLang) {
  const parts = scope.split(/[.#]/).filter(Boolean)
  for (let i = parts.length - 1; i >= 0; i -= 1) {
    const grammar = byLang.get(parts[i])
    if (grammar) return grammar
  }
  const names = [...byLang.keys()].sort((a, b) => b.length - a.length)
  for (let i = parts.length - 1; i >= 0; i -= 1) {
    for (const name of names) {
      if (name.length < 3) continue
      if (parts[i].startsWith(name) || parts[i].endsWith(name)) return byLang.get(name)
    }
  }
  return null
}

function workerCount() {
  const requested = Number(process.env.ZHL_SHIKI_JOBS ?? 0)
  if (Number.isInteger(requested) && requested > 0) return requested
  return Math.max(1, availableParallelism() * 4)
}

async function checkTarget([lang, scope, file]) {
  const out = `${tmp}/converted-${safeName(lang)}-${safeName(scope)}.zhl`
  const zigOut = `${tmp}/converted-${safeName(lang)}-${safeName(scope)}.zig`
  const report = await runZhlc(['report-textmate-json', file, '--include-dir', tmp])
  const converted = await runZhlc(['convert-textmate-json', file, out, '--include-dir', tmp])
  const checked = await runZhlc(['check-native', out])
  const generated = await runZhlc(['compile-native', out, zigOut])
  const compiled = await compileGeneratedModule(lang, scope, zigOut)
  return `${report}\n${converted}\n${checked}\n${generated}\n${compiled}`.trim()
}

function runZhlc(args) {
  return runCommand(zhlc, args)
}

function compileGeneratedModule(lang, scope, zigOut) {
  const cache = `${tmp}/zig-cache-${safeName(lang)}-${safeName(scope)}`
  const globalCache = `${tmp}/zig-global-cache`
  mkdirSync(cache, { recursive: true })
  mkdirSync(globalCache, { recursive: true })
  return runCommand('zig', [
    'build-lib',
    '-fno-emit-bin',
    '--cache-dir',
    cache,
    '--global-cache-dir',
    globalCache,
    '--dep',
    'zhl',
    `-Mroot=${zigOut}`,
    '-Mzhl=src/root.zig',
  ], 'generated-module ok')
}

function runCommand(file, args, okOutput = null) {
  return new Promise((resolveOutput) => {
    execFile(file, args, { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      const output = `${stdout ?? ''}${stderr ?? ''}`.trim()
      resolveOutput(err ? (output || err.message || '') : (output || okOutput || ''))
    })
  })
}
