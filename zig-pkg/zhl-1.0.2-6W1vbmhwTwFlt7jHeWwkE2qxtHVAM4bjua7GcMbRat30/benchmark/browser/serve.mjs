// Tiny zero-dep static file server for the browser benchmark harness.
// Serves the REPO ROOT so /packages/..., /zig-out/..., /benchmark/... are reachable.
//
//   node benchmark/browser/serve.mjs   (PORT env overrides default 8787)

import { createServer } from 'node:http'
import { createReadStream, existsSync, statSync } from 'node:fs'
import { extname, join, normalize, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const repoRoot = fileURLToPath(new URL('../../', import.meta.url))
const port = Number(process.env.PORT ?? 8787)

const MIME = {
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.wasm': 'application/wasm',
  '.html': 'text/html',
  '.css': 'text/css',
  '.json': 'application/json',
}

const server = createServer((req, res) => {
  const urlPath = decodeURIComponent(new URL(req.url, 'http://localhost').pathname)
  const relative = normalize(urlPath).replace(/^(\.\.(\/|\\|$))+/, '')
  let filePath = join(repoRoot, relative)

  if (!filePath.startsWith(repoRoot.endsWith(sep) ? repoRoot : repoRoot + sep) && filePath !== repoRoot) {
    res.writeHead(403).end('forbidden')
    return
  }
  if (existsSync(filePath) && statSync(filePath).isDirectory()) {
    filePath = join(filePath, 'index.html')
  }
  if (!existsSync(filePath) || !statSync(filePath).isFile()) {
    res.writeHead(404, { 'content-type': 'text/plain' }).end(`not found: ${urlPath}`)
    return
  }

  res.writeHead(200, {
    'content-type': MIME[extname(filePath)] ?? 'application/octet-stream',
    'cache-control': 'no-store',
  })
  createReadStream(filePath).pipe(res)
})

server.listen(port, '127.0.0.1', () => {
  console.log(`listening on http://127.0.0.1:${port}`)
})
