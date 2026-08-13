const std = @import("std");
const textmate_import = @import("import.zig");
const types = @import("types.zig");

pub const RuleKind = types.RuleKind;
pub const RuleSummary = types.RuleSummary;
pub const Summary = types.Summary;
pub const summarizeJson = textmate_import.summarizeJson;
pub const summarizePlist = textmate_import.summarizePlist;

test "TextMate JSON summary preserves order" {
    const json =
        \\{
        \\  "scopeName": "source.test",
        \\  "name": "Test",
        \\  "firstLineMatch": "^#!/usr/bin/env zig",
        \\  "patterns": [
        \\    {"name":"comment.line.test","match":"//.*$"},
        \\    {"include":"#strings"},
        \\    {"name":"string.quoted.test","begin":"\"","end":"\"","patterns":[
        \\      {"name":"constant.escape.test","match":"\\\\."}
        \\    ]}
        \\  ]
        \\}
    ;

    var summary = try summarizeJson(std.testing.allocator, json);
    defer summary.deinit();

    try std.testing.expectEqualStrings("source.test", summary.scope_name);
    try std.testing.expectEqualStrings("^#!/usr/bin/env zig", summary.first_line_match.?);
    try std.testing.expectEqual(@as(usize, 4), summary.rules.len);
    try std.testing.expectEqual(RuleKind.match, summary.rules[0].kind);
    try std.testing.expectEqual(RuleKind.include, summary.rules[1].kind);
    try std.testing.expectEqual(RuleKind.begin_end, summary.rules[2].kind);
}

test "TextMate JSON summary accepts grammar array exports" {
    const json =
        \\[
        \\  {"name": "Metadata"},
        \\  {"scopeName": "source.test", "patterns": [
        \\    {"name":"keyword.control.test","match":"\\b(if)\\b"}
        \\  ]},
        \\  {"scopeName": "source.extra", "patterns": [
        \\    {"name":"constant.numeric.test","match":"[0-9]+"}
        \\  ]}
        \\]
    ;

    var summary = try summarizeJson(std.testing.allocator, json);
    defer summary.deinit();

    try std.testing.expectEqualStrings("source.extra", summary.scope_name);
    try std.testing.expectEqual(@as(usize, 1), summary.rules.len);
    try std.testing.expectEqual(RuleKind.match, summary.rules[0].kind);
}

test "TextMate JSON summary skips recursive repository includes" {
    const json =
        \\{
        \\  "scopeName": "source.test",
        \\  "patterns": [{"include":"#loop"}],
        \\  "repository": {
        \\    "loop": {"patterns": [
        \\      {"name":"keyword.control.test","match":"\\b(if)\\b"},
        \\      {"include":"#loop"}
        \\    ]}
        \\  }
        \\}
    ;

    var summary = try summarizeJson(std.testing.allocator, json);
    defer summary.deinit();

    var match_count: usize = 0;
    var repository_count: usize = 0;
    for (summary.rules) |rule| switch (rule.kind) {
        .match => match_count += 1,
        .repository => repository_count += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), match_count);
    try std.testing.expectEqual(@as(usize, 1), repository_count);
}

test "TextMate plist summary extracts top-level match rules" {
    const xml =
        \\<plist><dict>
        \\<key>scopeName</key><string>source.test</string>
        \\<key>name</key><string>Test</string>
        \\<key>firstLineMatch</key><string>^#!.*zig</string>
        \\<key>patterns</key><array>
        \\<dict><key>match</key><string>\b(if|return)\b</string></dict>
        \\</array>
        \\</dict></plist>
    ;

    var summary = try summarizePlist(std.testing.allocator, xml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("source.test", summary.scope_name);
    try std.testing.expectEqualStrings("^#!.*zig", summary.first_line_match.?);
    try std.testing.expectEqual(@as(usize, 1), summary.rules.len);
    try std.testing.expectEqual(RuleKind.match, summary.rules[0].kind);
}

test "TextMate plist summary lowers repository begin-end captures" {
    const xml =
        \\<plist version="1.0"><dict>
        \\<key>scopeName</key><string>source.fixture</string>
        \\<key>patterns</key><array>
        \\<dict><key>include</key><string>#strings</string></dict>
        \\</array>
        \\<key>repository</key><dict>
        \\<key>strings</key><dict>
        \\<key>name</key><string>string.quoted.test</string>
        \\<key>contentName</key><string>source.test</string>
        \\<key>begin</key><string>&quot;</string>
        \\<key>end</key><string>&quot;</string>
        \\<key>beginCaptures</key><dict>
        \\<key>0</key><dict><key>name</key><string>punctuation.definition.string.test</string></dict>
        \\</dict>
        \\<key>patterns</key><array>
        \\<dict><key>name</key><string>support.function.builtin.test</string><key>match</key><string>@</string></dict>
        \\</array>
        \\</dict>
        \\</dict>
        \\</dict></plist>
    ;

    var summary = try summarizePlist(std.testing.allocator, xml);
    defer summary.deinit();

    try std.testing.expectEqualStrings("source.fixture", summary.scope_name);
    try std.testing.expectEqual(@as(usize, 2), summary.rules.len);
    try std.testing.expectEqual(RuleKind.begin_end, summary.rules[0].kind);
    try std.testing.expectEqualStrings("\"", summary.rules[0].pattern.?);
    try std.testing.expectEqual(@as(usize, 1), summary.rules[0].captures.len);
    try std.testing.expectEqual(RuleKind.match, summary.rules[1].kind);
}
