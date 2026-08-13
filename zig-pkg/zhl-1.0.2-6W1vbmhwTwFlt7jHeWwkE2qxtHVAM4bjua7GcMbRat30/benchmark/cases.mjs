import { readFileSync } from 'node:fs'

export const cases = [
  ['Zig 0.16', 'zig', 'corpus/zig.txt'],
  ['Zig adversarial', 'zig', 'corpus/zig_adversarial.txt'],
  ['real Zig source', 'zig', [
    '../src/regex/parser.zig',
    '../src/regex/vm.zig',
    '../src/runtime/native_runtime.zig',
    '../src/textmate/import.zig',
    '../src/textmate/plist.zig',
    '../src/native/dsl.zig',
    '../src/sublime/import.zig',
    '../src/tree_sitter/root.zig',
    '../src/runtime/engine.zig',
  ]],
  ['real Bash source', 'bash', [
    'gate.sh',
    '../tools/check_integrations.sh',
    '../tools/check_file_lines.sh',
    'run_compare.sh',
  ]],
  ['real JavaScript source', 'javascript', [
    'visual_compare.mjs',
    'differential_native.mjs',
    'shiki.mjs',
    'wasm.mjs',
  ]],
  ['real JSON source', 'json', [
    'package-lock.json',
    '../grammars/textmate/json.tmLanguage.json',
  ]],
  ['real Rust source', 'rust', 'syntect/src/main.rs'],
  ['real TOML source', 'toml', [
    'syntect/Cargo.lock',
    'syntect_fancy/Cargo.lock',
    'syntect/Cargo.toml',
    'syntect_fancy/Cargo.toml',
  ]],
  ['real YAML source', 'yaml', '../.github/workflows/ci.yml'],
  ['real C source', 'c', 'corpus/third_party/c_real_gzread.c'],
  ['real Python source', 'python', 'corpus/third_party/python_real_requests_adapters.py'],
  ['real TypeScript source', 'typescript', 'corpus/third_party/typescript_real_vscode_range.ts'],
  ['TypeScript', 'typescript', 'corpus/typescript.txt'],
  ['Rust', 'rust', 'corpus/rust.txt'],
  ['Python', 'python', 'corpus/python.txt'],
  ['minified JSON', 'json', 'corpus/json_min.txt'],
  ['minified JavaScript', 'javascript', 'corpus/javascript_min.txt'],
  ['TextMate JSON', 'json', 'corpus/textmate_json.txt'],
  ['C++', 'cpp', '../tests/fixtures/languages/cpp-textmate.cpp'],
  ['C#', 'csharp', '../tests/fixtures/languages/csharp-textmate.cs'],
  ['HTML', 'html', '../tests/fixtures/languages/html-textmate.html'],
  ['Java', 'java', '../tests/fixtures/languages/java-textmate.java'],
  ['JSX', 'jsx', '../tests/fixtures/languages/jsx-textmate.jsx'],
  ['Kotlin', 'kotlin', '../tests/fixtures/languages/kotlin-textmate.kt'],
  ['Markdown', 'markdown', '../README.md'],
  ['PHP', 'php', '../tests/fixtures/languages/php-textmate.php'],
  ['Ruby', 'ruby', '../tests/fixtures/languages/ruby-textmate.rb'],
  ['Swift', 'swift', '../tests/fixtures/languages/swift-textmate.swift'],
  ['TSX', 'tsx', '../tests/fixtures/languages/tsx-textmate.tsx'],
]

export function readSource(path) {
  if (Array.isArray(path)) return path.map((item) => readFileSync(new URL(item, import.meta.url), 'utf8')).join('\n')
  return readFileSync(new URL(path, import.meta.url), 'utf8')
}
