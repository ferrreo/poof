#!/usr/bin/env sh
set -eu

ZHL_EXPECT_COMPARE_ROWS=${ZHL_EXPECT_COMPARE_ROWS:-$(node --input-type=module -e 'import { cases } from "./benchmark/cases.mjs"; console.log(cases.length)')}
export ZHL_EXPECT_COMPARE_ROWS

if [ "${ZHL_SKIP_NATIVE_GATE:-0}" != 1 ]; then
    sh benchmark/gate.sh
fi
if [ "${ZHL_SKIP_WASM:-0}" != 1 ]; then
    zig build wasm -Doptimize=ReleaseFast
    npm --prefix benchmark run wasm
fi
npm --prefix benchmark run shiki
npm --prefix benchmark run vscode-textmate
ZHL_SYNTECT_ENGINE=onig cargo run --manifest-path benchmark/syntect/Cargo.toml --bin zhl-syntect-bench --release
ZHL_SYNTECT_ENGINE=fancy-regex ZHL_SYNTECT_SYNTAX_DIR=benchmark/syntect/syntaxes cargo run --manifest-path benchmark/syntect_fancy/Cargo.toml --release
