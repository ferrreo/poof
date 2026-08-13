const std = @import("std");
const zhl = @import("zhl");

pub const bash = @import("bash.zig");
pub const c = @import("c.zig");
pub const cpp = @import("cpp.zig");
pub const csharp = @import("csharp.zig");
pub const css = @import("css.zig");
pub const go = @import("go.zig");
pub const html = @import("html.zig");
pub const java = @import("java.zig");
pub const javascript = @import("javascript.zig");
pub const jsx = @import("jsx.zig");
pub const json = @import("json.zig");
pub const kotlin = @import("kotlin.zig");
pub const log = @import("log.zig");
pub const markdown = @import("markdown.zig");
pub const php = @import("php.zig");
pub const python = @import("python.zig");
pub const ruby = @import("ruby.zig");
pub const rust = @import("rust.zig");
pub const sql = @import("sql.zig");
pub const swift = @import("swift.zig");
pub const toml = @import("toml.zig");
pub const tsx = @import("tsx.zig");
pub const typescript = @import("typescript.zig");
pub const xml = @import("xml.zig");
pub const yaml = @import("yaml.zig");
pub const zig_0_16 = @import("zig_0_16.zig");
pub const zig_0_16_generated = @import("zig_0_16_generated.zig");

pub const LanguageId = enum(u16) {
    bash = 1,
    c = 2,
    cpp = 3,
    csharp = 4,
    css = 5,
    go = 6,
    html = 7,
    java = 8,
    javascript = 9,
    jsx = 10,
    json = 11,
    kotlin = 12,
    markdown = 13,
    php = 14,
    python = 15,
    ruby = 16,
    rust = 17,
    sql = 18,
    swift = 19,
    toml = 20,
    tsx = 21,
    typescript = 22,
    xml = 23,
    yaml = 24,
    zig = 25,
    log = 26,
};

pub const LanguageMetadata = struct {
    id: LanguageId,
    canonical: []const u8,
    display_name: []const u8,
    scope: []const u8,
    aliases: []const []const u8,
    extensions: []const []const u8,
    mime_types: []const []const u8,
};

pub const languages = [_]LanguageMetadata{
    .{ .id = .bash, .canonical = "bash", .display_name = "Bash", .scope = "source.shell", .aliases = &.{ "sh", "shell" }, .extensions = &.{ "sh", "bash", "zsh" }, .mime_types = &.{"application/x-sh"} },
    .{ .id = .c, .canonical = "c", .display_name = "C", .scope = "source.c", .aliases = &.{ "h", "ansi-c" }, .extensions = &.{ "c", "h" }, .mime_types = &.{"text/x-csrc"} },
    .{ .id = .cpp, .canonical = "cpp", .display_name = "C++", .scope = "source.cpp", .aliases = &.{ "c++", "cc", "cxx" }, .extensions = &.{ "cpp", "cc", "cxx", "hpp", "hh", "hxx" }, .mime_types = &.{"text/x-c++src"} },
    .{ .id = .csharp, .canonical = "csharp", .display_name = "C#", .scope = "source.cs", .aliases = &.{ "cs", "c#" }, .extensions = &.{"cs"}, .mime_types = &.{"text/x-csharp"} },
    .{ .id = .css, .canonical = "css", .display_name = "CSS", .scope = "source.css", .aliases = &.{}, .extensions = &.{"css"}, .mime_types = &.{"text/css"} },
    .{ .id = .go, .canonical = "go", .display_name = "Go", .scope = "source.go", .aliases = &.{"golang"}, .extensions = &.{"go"}, .mime_types = &.{"text/x-go"} },
    .{ .id = .html, .canonical = "html", .display_name = "HTML", .scope = "text.html.basic", .aliases = &.{ "htm", "xhtml" }, .extensions = &.{ "html", "htm", "xhtml" }, .mime_types = &.{ "text/html", "application/xhtml+xml" } },
    .{ .id = .java, .canonical = "java", .display_name = "Java", .scope = "source.java", .aliases = &.{}, .extensions = &.{"java"}, .mime_types = &.{"text/x-java-source"} },
    .{ .id = .javascript, .canonical = "javascript", .display_name = "JavaScript", .scope = "source.js", .aliases = &.{ "js", "mjs", "cjs", "node" }, .extensions = &.{ "js", "mjs", "cjs" }, .mime_types = &.{ "text/javascript", "application/javascript" } },
    .{ .id = .jsx, .canonical = "jsx", .display_name = "JSX", .scope = "source.js.jsx", .aliases = &.{"javascriptreact"}, .extensions = &.{"jsx"}, .mime_types = &.{"text/jsx"} },
    .{ .id = .json, .canonical = "json", .display_name = "JSON", .scope = "source.json", .aliases = &.{ "jsonc", "jsonl" }, .extensions = &.{ "json", "jsonc", "jsonl" }, .mime_types = &.{"application/json"} },
    .{ .id = .kotlin, .canonical = "kotlin", .display_name = "Kotlin", .scope = "source.kotlin", .aliases = &.{"kt"}, .extensions = &.{ "kt", "kts" }, .mime_types = &.{"text/x-kotlin"} },
    .{ .id = .log, .canonical = "log", .display_name = "Log", .scope = "text.log", .aliases = &.{}, .extensions = &.{"log"}, .mime_types = &.{"text/plain"} },
    .{ .id = .markdown, .canonical = "markdown", .display_name = "Markdown", .scope = "text.html.markdown", .aliases = &.{ "md", "mdown" }, .extensions = &.{ "md", "markdown", "mdown" }, .mime_types = &.{"text/markdown"} },
    .{ .id = .php, .canonical = "php", .display_name = "PHP", .scope = "text.html.php", .aliases = &.{}, .extensions = &.{ "php", "phtml" }, .mime_types = &.{"application/x-httpd-php"} },
    .{ .id = .python, .canonical = "python", .display_name = "Python", .scope = "source.python", .aliases = &.{ "py", "pyw" }, .extensions = &.{ "py", "pyw" }, .mime_types = &.{"text/x-python"} },
    .{ .id = .ruby, .canonical = "ruby", .display_name = "Ruby", .scope = "source.ruby", .aliases = &.{"rb"}, .extensions = &.{ "rb", "ruby" }, .mime_types = &.{"text/x-ruby"} },
    .{ .id = .rust, .canonical = "rust", .display_name = "Rust", .scope = "source.rust", .aliases = &.{"rs"}, .extensions = &.{"rs"}, .mime_types = &.{"text/rust"} },
    .{ .id = .sql, .canonical = "sql", .display_name = "SQL", .scope = "source.sql", .aliases = &.{}, .extensions = &.{"sql"}, .mime_types = &.{"application/sql"} },
    .{ .id = .swift, .canonical = "swift", .display_name = "Swift", .scope = "source.swift", .aliases = &.{}, .extensions = &.{"swift"}, .mime_types = &.{"text/x-swift"} },
    .{ .id = .toml, .canonical = "toml", .display_name = "TOML", .scope = "source.toml", .aliases = &.{}, .extensions = &.{"toml"}, .mime_types = &.{"application/toml"} },
    .{ .id = .tsx, .canonical = "tsx", .display_name = "TSX", .scope = "source.tsx", .aliases = &.{"typescriptreact"}, .extensions = &.{"tsx"}, .mime_types = &.{"text/tsx"} },
    .{ .id = .typescript, .canonical = "typescript", .display_name = "TypeScript", .scope = "source.ts", .aliases = &.{ "ts", "mts", "cts" }, .extensions = &.{ "ts", "mts", "cts" }, .mime_types = &.{"text/typescript"} },
    .{ .id = .xml, .canonical = "xml", .display_name = "XML", .scope = "text.xml", .aliases = &.{ "xsd", "svg" }, .extensions = &.{ "xml", "xsd", "svg" }, .mime_types = &.{ "application/xml", "text/xml", "image/svg+xml" } },
    .{ .id = .yaml, .canonical = "yaml", .display_name = "YAML", .scope = "source.yaml", .aliases = &.{ "yml", "yaml" }, .extensions = &.{ "yaml", "yml" }, .mime_types = &.{ "application/yaml", "text/yaml" } },
    .{ .id = .zig, .canonical = "zig", .display_name = "Zig 0.16", .scope = "source.zig", .aliases = &.{"zig_0_16"}, .extensions = &.{"zig"}, .mime_types = &.{"text/zig"} },
};

pub fn findByName(name: []const u8) ?*const LanguageMetadata {
    for (&languages) |*language| {
        if (std.mem.eql(u8, name, language.canonical)) return language;
        for (language.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) return language;
        }
    }
    return null;
}

pub fn findByExtension(ext: []const u8) ?*const LanguageMetadata {
    const normalized = if (std.mem.startsWith(u8, ext, ".")) ext[1..] else ext;
    for (&languages) |*language| {
        for (language.extensions) |language_ext| {
            if (std.mem.eql(u8, normalized, language_ext)) return language;
        }
    }
    return null;
}

pub fn findByMime(mime: []const u8) ?*const LanguageMetadata {
    for (&languages) |*language| {
        for (language.mime_types) |language_mime| {
            if (std.mem.eql(u8, mime, language_mime)) return language;
        }
    }
    return null;
}

test {
    _ = bash;
    _ = c;
    _ = cpp;
    _ = csharp;
    _ = css;
    _ = go;
    _ = html;
    _ = java;
    _ = javascript;
    _ = jsx;
    _ = json;
    _ = kotlin;
    _ = log;
    _ = markdown;
    _ = php;
    _ = python;
    _ = ruby;
    _ = rust;
    _ = sql;
    _ = swift;
    _ = toml;
    _ = tsx;
    _ = typescript;
    _ = xml;
    _ = yaml;
    _ = zig_0_16;
    _ = zig_0_16_generated;
}

test "language metadata ids are stable and unique" {
    try std.testing.expectEqual(@as(usize, 26), languages.len);
    var seen = [_]bool{false} ** 27;
    for (languages) |language| {
        const id = @intFromEnum(language.id);
        try std.testing.expect(id > 0 and id < seen.len);
        try std.testing.expect(!seen[id]);
        seen[id] = true;
    }
}

test "language metadata resolves aliases" {
    try std.testing.expectEqual(LanguageId.javascript, findByName("js").?.id);
    try std.testing.expectEqual(LanguageId.typescript, findByName("ts").?.id);
    try std.testing.expectEqual(LanguageId.python, findByName("py").?.id);
    try std.testing.expectEqual(LanguageId.markdown, findByName("md").?.id);
    try std.testing.expectEqual(LanguageId.yaml, findByName("yml").?.id);
    try std.testing.expectEqual(LanguageId.zig, findByName("zig_0_16").?.id);
}

test "language metadata resolves extensions and MIME" {
    try std.testing.expectEqual(LanguageId.cpp, findByExtension(".hpp").?.id);
    try std.testing.expectEqual(LanguageId.csharp, findByExtension("cs").?.id);
    try std.testing.expectEqual(LanguageId.html, findByMime("text/html").?.id);
    try std.testing.expectEqual(LanguageId.javascript, findByMime("application/javascript").?.id);
    try std.testing.expectEqual(LanguageId.xml, findByMime("image/svg+xml").?.id);
}

test "native log grammar highlights values and severity" {
    const source = "Jul 30 19:04:11 host systemd[4042]: Failed with result 'exit-code'.";
    const Highlighter = zhl.Engine(log.grammar, .{});
    var highlighter = Highlighter.init(.{});
    var scratch = Highlighter.Scratch.init();
    var sink = zhl.sinks.TokenBuffer(32).init();
    _ = try highlighter.highlightLine(source, Highlighter.State.initial(), &scratch, &sink);

    var saw_number = false;
    var saw_error = false;
    for (sink.slice()) |token| {
        saw_number = saw_number or token.style_id == .keyword;
        saw_error = saw_error or token.style_id == .string and
            std.mem.eql(u8, source[token.start..token.end], "Failed");
    }
    try std.testing.expect(saw_number);
    try std.testing.expect(saw_error);
}
