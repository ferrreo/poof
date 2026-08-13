// Theme demo: renders Zig + TypeScript samples with zhl wasm and toggles
// between the @zhl/themes GitHub Dark / Light stylesheets.
import { init } from '/packages/zhl-wasm/index.js'

const status = document.getElementById('status')
const toggle = document.getElementById('toggle')
const panes = [
  { el: document.getElementById('zig'), lang: 'zig', corpus: '/benchmark/corpus/zig.txt' },
  { el: document.getElementById('ts'), lang: 'typescript', corpus: '/benchmark/corpus/typescript.txt' },
]

const LINES = 40
let dark = true

// zhl.renderHtml() output is produced by our own renderer, which
// HTML-escapes all source text; parse it into nodes via DOMParser.
function setRenderedHtml(container, html) {
  const doc = new DOMParser().parseFromString(html, 'text/html')
  container.replaceChildren(...doc.body.childNodes)
}

function applyTheme() {
  const add = dark ? 'zhl-github-dark' : 'zhl-github-light'
  const remove = dark ? 'zhl-github-light' : 'zhl-github-dark'
  for (const { el } of panes) {
    el.classList.add(add)
    el.classList.remove(remove)
  }
  document.body.classList.toggle('light', !dark)
  toggle.textContent = dark ? 'Switch to light' : 'Switch to dark'
}

toggle.addEventListener('click', () => {
  dark = !dark
  applyTheme()
})

try {
  const zhl = await init('/zig-out/bin/zhl_api.wasm')
  for (const pane of panes) {
    const text = await (await fetch(pane.corpus)).text()
    const sample = text.split('\n').slice(0, LINES).join('\n')
    setRenderedHtml(pane.el.querySelector('code'), zhl.renderHtml(pane.lang, sample))
  }
  applyTheme()
  status.textContent = 'ready'
  window.__ZHL_DEMO_READY__ = true
} catch (err) {
  status.textContent = `error: ${err.message}`
  window.__ZHL_DEMO_ERROR__ = String(err)
  throw err
}
