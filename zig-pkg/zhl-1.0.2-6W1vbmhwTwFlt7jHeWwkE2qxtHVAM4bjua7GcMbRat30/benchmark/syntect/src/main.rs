use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use syntect::easy::HighlightLines;
use syntect::highlighting::ThemeSet;
use syntect::parsing::SyntaxSet;

struct Corpus {
    name: &'static str,
    extension: &'static str,
    sources: &'static [&'static str],
}

const CASES: &[Corpus] = &[
    Corpus {
        name: "Zig 0.16",
        extension: "zig",
        sources: &[include_str!("../../corpus/zig.txt")],
    },
    Corpus {
        name: "Zig adversarial",
        extension: "zig",
        sources: &[include_str!("../../corpus/zig_adversarial.txt")],
    },
    Corpus {
        name: "real Zig source",
        extension: "zig",
        sources: &[
            include_str!("../../../src/regex/parser.zig"),
            include_str!("../../../src/regex/vm.zig"),
            include_str!("../../../src/runtime/native_runtime.zig"),
            include_str!("../../../src/textmate/import.zig"),
            include_str!("../../../src/textmate/plist.zig"),
            include_str!("../../../src/native/dsl.zig"),
            include_str!("../../../src/sublime/import.zig"),
            include_str!("../../../src/tree_sitter/root.zig"),
            include_str!("../../../src/runtime/engine.zig"),
        ],
    },
    Corpus {
        name: "real Bash source",
        extension: "sh",
        sources: &[
            include_str!("../../gate.sh"),
            include_str!("../../../tools/check_integrations.sh"),
            include_str!("../../../tools/check_file_lines.sh"),
            include_str!("../../run_compare.sh"),
        ],
    },
    Corpus {
        name: "real JavaScript source",
        extension: "js",
        sources: &[
            include_str!("../../visual_compare.mjs"),
            include_str!("../../differential_native.mjs"),
            include_str!("../../shiki.mjs"),
            include_str!("../../wasm.mjs"),
        ],
    },
    Corpus {
        name: "real JSON source",
        extension: "json",
        sources: &[
            include_str!("../../package-lock.json"),
            include_str!("../../../grammars/textmate/json.tmLanguage.json"),
        ],
    },
    Corpus {
        name: "real Rust source",
        extension: "rs",
        sources: &[include_str!("main.rs")],
    },
    Corpus {
        name: "real TOML source",
        extension: "toml",
        sources: &[
            include_str!("../Cargo.lock"),
            include_str!("../../syntect_fancy/Cargo.lock"),
            include_str!("../Cargo.toml"),
            include_str!("../../syntect_fancy/Cargo.toml"),
        ],
    },
    Corpus {
        name: "real YAML source",
        extension: "yml",
        sources: &[include_str!("../../../.github/workflows/ci.yml")],
    },
    Corpus {
        name: "real C source",
        extension: "c",
        sources: &[include_str!("../../corpus/third_party/c_real_gzread.c")],
    },
    Corpus {
        name: "real Python source",
        extension: "py",
        sources: &[include_str!(
            "../../corpus/third_party/python_real_requests_adapters.py"
        )],
    },
    Corpus {
        name: "real TypeScript source",
        extension: "ts",
        sources: &[include_str!(
            "../../corpus/third_party/typescript_real_vscode_range.ts"
        )],
    },
    Corpus {
        name: "TypeScript",
        extension: "ts",
        sources: &[include_str!("../../corpus/typescript.txt")],
    },
    Corpus {
        name: "Rust",
        extension: "rs",
        sources: &[include_str!("../../corpus/rust.txt")],
    },
    Corpus {
        name: "Python",
        extension: "py",
        sources: &[include_str!("../../corpus/python.txt")],
    },
    Corpus {
        name: "minified JSON",
        extension: "json",
        sources: &[include_str!("../../corpus/json_min.txt")],
    },
    Corpus {
        name: "minified JavaScript",
        extension: "js",
        sources: &[include_str!("../../corpus/javascript_min.txt")],
    },
    Corpus {
        name: "TextMate JSON",
        extension: "json",
        sources: &[include_str!("../../corpus/textmate_json.txt")],
    },
    Corpus {
        name: "C++",
        extension: "cpp",
        sources: &[include_str!("../../../tests/fixtures/languages/cpp-textmate.cpp")],
    },
    Corpus {
        name: "C#",
        extension: "cs",
        sources: &[include_str!("../../../tests/fixtures/languages/csharp-textmate.cs")],
    },
    Corpus {
        name: "HTML",
        extension: "html",
        sources: &[include_str!("../../../tests/fixtures/languages/html-textmate.html")],
    },
    Corpus {
        name: "Java",
        extension: "java",
        sources: &[include_str!("../../../tests/fixtures/languages/java-textmate.java")],
    },
    Corpus {
        name: "JSX",
        extension: "jsx",
        sources: &[include_str!("../../../tests/fixtures/languages/jsx-textmate.jsx")],
    },
    Corpus {
        name: "Kotlin",
        extension: "kt",
        sources: &[include_str!("../../../tests/fixtures/languages/kotlin-textmate.kt")],
    },
    Corpus {
        name: "Markdown",
        extension: "md",
        sources: &[include_str!("../../../README.md")],
    },
    Corpus {
        name: "PHP",
        extension: "php",
        sources: &[include_str!("../../../tests/fixtures/languages/php-textmate.php")],
    },
    Corpus {
        name: "Ruby",
        extension: "rb",
        sources: &[include_str!("../../../tests/fixtures/languages/ruby-textmate.rb")],
    },
    Corpus {
        name: "Swift",
        extension: "swift",
        sources: &[include_str!("../../../tests/fixtures/languages/swift-textmate.swift")],
    },
    Corpus {
        name: "TSX",
        extension: "tsx",
        sources: &[include_str!("../../../tests/fixtures/languages/tsx-textmate.tsx")],
    },
];

struct CountingAlloc;

static ALLOC_COUNT: AtomicUsize = AtomicUsize::new(0);
static ALLOC_BYTES: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        ALLOC_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let syntax_dir = std::env::var("ZHL_SYNTECT_SYNTAX_DIR")
        .unwrap_or_else(|_| format!("{}/syntaxes", env!("CARGO_MANIFEST_DIR")));
    let regex_engine = std::env::var("ZHL_SYNTECT_ENGINE").unwrap_or_else(|_| "onig".to_string());

    ALLOC_COUNT.store(0, Ordering::Relaxed);
    ALLOC_BYTES.store(0, Ordering::Relaxed);

    let mut builder = two_face::syntax::extra_newlines().into_builder();
    builder.add_from_folder(syntax_dir, true).unwrap();
    let ps = builder.build();
    let ts = ThemeSet::load_defaults();
    let theme = &ts.themes["base16-ocean.dark"];
    let setup_allocs = ALLOC_COUNT.load(Ordering::Relaxed);
    let setup_alloc_bytes = ALLOC_BYTES.load(Ordering::Relaxed);

    let dump_path = args.get(2);
    let extension = args
        .get(3)
        .map(|arg| arg.as_str())
        .or_else(|| dump_path.and_then(|path| std::path::Path::new(path).extension()?.to_str()))
        .unwrap_or("zig");
    let syntax = find_syntax(&ps, extension).unwrap_or_else(|| ps.find_syntax_plain_text());

    if args.get(1).map(|arg| arg.as_str()) == Some("dump") {
        let path = args.get(2).expect("dump requires a source path");
        let source = std::fs::read_to_string(path).unwrap();
        let mut h = HighlightLines::new(syntax, theme);
        for (line_no, line) in source.split('\n').enumerate() {
            let ranges = h.highlight_line(line, &ps).unwrap();
            let mut col = 0usize;
            for (style, text) in ranges {
                let end = col + text.len();
                println!(
                    "{}:{}:{}:#{:02x}{:02x}{:02x}",
                    line_no, col, end, style.foreground.r, style.foreground.g, style.foreground.b
                );
                col = end;
            }
        }
        return;
    }

    let expected_rows = std::env::var("ZHL_EXPECT_COMPARE_ROWS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(CASES.len());
    let mut rows = 0usize;
    for case in CASES {
        rows += 1;
        run_case(
            case,
            &ps,
            theme,
            &regex_engine,
            setup_allocs,
            setup_alloc_bytes,
        );
    }
    assert_eq!(
        rows, expected_rows,
        "syntect benchmark row count changed: {rows} rows != {expected_rows}"
    );
}

fn run_case(
    case: &Corpus,
    ps: &SyntaxSet,
    theme: &syntect::highlighting::Theme,
    regex_engine: &str,
    setup_allocs: usize,
    setup_alloc_bytes: usize,
) {
    let Some(syntax) = find_syntax(ps, case.extension) else {
        println!("syntect {}", case.name);
        println!(
            "  skipped:      unsupported syntax extension {}",
            case.extension
        );
        return;
    };
    let source_len = case.sources.iter().map(|source| source.len()).sum();
    let iterations = iterations_for(source_len);
    let line_count = case
        .sources
        .iter()
        .map(|source| count_lines(source))
        .sum::<usize>();
    for _ in 0..20 {
        for source in case.sources {
            let mut h = HighlightLines::new(syntax, theme);
            for line in source.trim_end_matches('\n').split('\n') {
                let _ = h.highlight_line(line, &ps).unwrap();
            }
        }
    }

    ALLOC_COUNT.store(0, Ordering::Relaxed);
    ALLOC_BYTES.store(0, Ordering::Relaxed);

    let start = Instant::now();
    let mut token_count = 0usize;
    let mut bytes = 0usize;

    for _ in 0..iterations {
        for source in case.sources {
            let mut h = HighlightLines::new(syntax, theme);
            for line in source.trim_end_matches('\n').split('\n') {
                let ranges = h.highlight_line(line, &ps).unwrap();
                token_count += ranges.len();
            }
        }
        bytes += source_len;
    }

    let elapsed = start.elapsed();
    let elapsed_ns = elapsed.as_nanos() as f64;
    let seconds = elapsed.as_secs_f64();
    let mib = bytes as f64 / (1024.0 * 1024.0);
    let line_count = iterations * line_count;
    let hot_allocs = ALLOC_COUNT.load(Ordering::Relaxed);
    let hot_alloc_bytes = ALLOC_BYTES.load(Ordering::Relaxed);

    println!("syntect {}", case.name);
    println!("  regex_engine: {}", regex_engine);
    println!("  syntax:       {}", syntax.name);
    println!("  lines:        {}", line_count);
    println!("  bytes:        {}", bytes);
    println!("  tokens:       {}", token_count);
    println!("  elapsed_ms:   {:.3}", seconds * 1000.0);
    println!("  throughput:   {:.2} MiB/s", mib / seconds);
    println!("  ns_per_line:  {:.2}", elapsed_ns / line_count as f64);
    println!("  setup_allocs: {}", setup_allocs);
    println!("  setup_bytes:  {}", setup_alloc_bytes);
    println!("  hot_allocs:   {}", hot_allocs);
    println!("  hot_bytes:    {}", hot_alloc_bytes);
    println!("  total_allocs: {}", setup_allocs + hot_allocs);
    println!("  total_bytes:  {}", setup_alloc_bytes + hot_alloc_bytes);
}

fn find_syntax<'a>(
    ps: &'a SyntaxSet,
    extension: &str,
) -> Option<&'a syntect::parsing::SyntaxReference> {
    ps.find_syntax_by_extension(extension).or_else(|| {
        if extension == "zig" {
            ps.find_syntax_by_name("Zig")
        } else if extension == "jsx" {
            ps.find_syntax_by_extension("tsx")
        } else {
            None
        }
    })
}

fn count_lines(source: &str) -> usize {
    let lines = source.split('\n').count();
    if source.ends_with('\n') {
        lines - 1
    } else {
        lines
    }
}

fn iterations_for(source_len: usize) -> usize {
    let target_bytes = std::env::var("ZHL_SYNTECT_BYTES")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(512 * 1024usize);
    let by_size = if source_len == 0 {
        5
    } else {
        target_bytes / source_len
    };
    by_size.max(5)
}
