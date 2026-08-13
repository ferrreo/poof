// Drives the browser benchmark page in real headless Chrome via puppeteer-core.
// Usage: node benchmark/browser/run_chrome.mjs [--chrome /usr/bin/google-chrome] [--url http://127.0.0.1:8787/benchmark/browser/index.html] [--out wasm-browser-chrome.json]
import { writeFileSync, mkdirSync } from 'node:fs'
import puppeteer from 'puppeteer-core'

const argv = process.argv.slice(2)
function arg(name, fallback) {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : fallback
}

const chromePath = arg('--chrome', '/usr/bin/google-chrome')
const url = arg('--url', 'http://127.0.0.1:8787/benchmark/browser/index.html')
const outName = arg('--out', 'wasm-browser-chrome.json')

const browser = await puppeteer.launch({
  executablePath: chromePath,
  headless: 'new',
  args: ['--no-first-run', '--disable-background-timer-throttling'],
})
try {
  const page = await browser.newPage()
  await page.goto(url, { waitUntil: 'domcontentloaded' })

  let lastStatus = ''
  const started = Date.now()
  for (;;) {
    const state = await page.evaluate(() => ({
      done: !!window.__ZHL_BENCH_DONE__,
      err: window.__ZHL_BENCH_ERROR__ || null,
      status: document.querySelector('#status')?.textContent ?? '',
    }))
    if (state.err) throw new Error(`bench error: ${state.err}`)
    if (state.done) break
    if (state.status !== lastStatus) {
      lastStatus = state.status
      console.error(`[${((Date.now() - started) / 1000).toFixed(0)}s] ${state.status}`)
    }
    if (Date.now() - started > 15 * 60 * 1000) throw new Error('timeout after 15 min')
    await new Promise((r) => setTimeout(r, 1000))
  }

  const results = await page.evaluate(() => window.__ZHL_BENCH_RESULTS__)
  const backend = results.backend ?? 'wasm-browser'
  for (const row of results.rows) {
    console.log([backend, row.label, row.mibPerSec.toFixed(2), row.nsPerLine.toFixed(2), row.tokens].join('\t'))
  }
  console.log([backend, 'TOTAL', results.totalMibPerSec.toFixed(2)].join('\t'))

  mkdirSync(new URL('../results/', import.meta.url), { recursive: true })
  const out = new URL(`../results/${outName}`, import.meta.url)
  writeFileSync(out, JSON.stringify(results, null, 2))
  console.error(`wrote ${out.pathname}`)
} finally {
  await browser.close()
}
