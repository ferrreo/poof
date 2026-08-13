// Browser-safe ESM mirror of benchmark/cases.mjs.
// Paths are URL paths relative to a static server rooted at the repo root
// (cases.mjs paths resolve relative to benchmark/, so 'corpus/x' → '/benchmark/corpus/x'
// and '../src/x' → '/src/x').

export const cases = [
  ['Zig 0.16', 'zig', '/benchmark/corpus/zig.txt'],
  ['Zig adversarial', 'zig', '/benchmark/corpus/zig_adversarial.txt'],
  ['real Zig source', 'zig', [
    '/src/regex/parser.zig',
    '/src/regex/vm.zig',
    '/src/runtime/native_runtime.zig',
    '/src/textmate/import.zig',
    '/src/textmate/plist.zig',
    '/src/native/dsl.zig',
    '/src/sublime/import.zig',
    '/src/tree_sitter/root.zig',
    '/src/runtime/engine.zig',
  ]],
  ['real Bash source', 'bash', [
    '/benchmark/gate.sh',
    '/tools/check_integrations.sh',
    '/tools/check_file_lines.sh',
    '/benchmark/run_compare.sh',
  ]],
  ['real JavaScript source', 'javascript', [
    '/benchmark/visual_compare.mjs',
    '/benchmark/differential_native.mjs',
    '/benchmark/shiki.mjs',
    '/benchmark/wasm.mjs',
  ]],
  ['real JSON source', 'json', [
    '/benchmark/package-lock.json',
    '/grammars/textmate/json.tmLanguage.json',
  ]],
  ['real Rust source', 'rust', '/benchmark/syntect/src/main.rs'],
  ['real TOML source', 'toml', [
    '/benchmark/syntect/Cargo.lock',
    '/benchmark/syntect_fancy/Cargo.lock',
    '/benchmark/syntect/Cargo.toml',
    '/benchmark/syntect_fancy/Cargo.toml',
  ]],
  ['real YAML source', 'yaml', '/.github/workflows/ci.yml'],
  ['real C source', 'c', '/benchmark/corpus/third_party/c_real_gzread.c'],
  ['real Python source', 'python', '/benchmark/corpus/third_party/python_real_requests_adapters.py'],
  ['real TypeScript source', 'typescript', '/benchmark/corpus/third_party/typescript_real_vscode_range.ts'],
  ['TypeScript', 'typescript', '/benchmark/corpus/typescript.txt'],
  ['Rust', 'rust', '/benchmark/corpus/rust.txt'],
  ['Python', 'python', '/benchmark/corpus/python.txt'],
  ['minified JSON', 'json', '/benchmark/corpus/json_min.txt'],
  ['minified JavaScript', 'javascript', '/benchmark/corpus/javascript_min.txt'],
  ['TextMate JSON', 'json', '/benchmark/corpus/textmate_json.txt'],
  ['C++', 'cpp', '/tests/fixtures/languages/cpp-textmate.cpp'],
  ['C#', 'csharp', '/tests/fixtures/languages/csharp-textmate.cs'],
  ['HTML', 'html', '/tests/fixtures/languages/html-textmate.html'],
  ['Java', 'java', '/tests/fixtures/languages/java-textmate.java'],
  ['JSX', 'jsx', '/tests/fixtures/languages/jsx-textmate.jsx'],
  ['Kotlin', 'kotlin', '/tests/fixtures/languages/kotlin-textmate.kt'],
  ['Markdown', 'markdown', '/README.md'],
  ['PHP', 'php', '/tests/fixtures/languages/php-textmate.php'],
  ['Ruby', 'ruby', '/tests/fixtures/languages/ruby-textmate.rb'],
  ['Swift', 'swift', '/tests/fixtures/languages/swift-textmate.swift'],
  ['TSX', 'tsx', '/tests/fixtures/languages/tsx-textmate.tsx'],
]

async function fetchText(path) {
  const response = await fetch(path)
  if (!response.ok) throw new Error(`fetch ${path} failed: ${response.status}`)
  return response.text()
}

export async function readSource(entry) {
  if (Array.isArray(entry)) {
    const parts = await Promise.all(entry.map(fetchText))
    return parts.join('\n')
  }
  return fetchText(entry)
}
