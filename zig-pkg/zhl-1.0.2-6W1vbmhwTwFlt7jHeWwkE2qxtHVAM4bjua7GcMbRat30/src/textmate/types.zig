const std = @import("std");
const textmate_captures = @import("captures.zig");

pub const MaxTextMateCaptures = 64;
pub const MaxRegexAtoms = 64;
pub const MaxRegexVmPattern = 512;
pub const MaxLargeRegexVmPattern = 8192;

pub const RuleKind = enum {
    match,
    begin_end,
    while_rule,
    include,
    repository,
};

pub const RuleSummary = struct {
    kind: RuleKind,
    parent: ?u32 = null,
    name: ?[]u8 = null,
    capture_scope: ?[]u8 = null,
    content_name: ?[]u8 = null,
    pattern: ?[]u8 = null,
    end: ?[]u8 = null,
    include: ?[]u8 = null,
    apply_end_pattern_last: bool = false,
    captures: []textmate_captures.CaptureEntry = &.{},
    end_captures: []textmate_captures.CaptureEntry = &.{},
};

pub const Summary = struct {
    allocator: std.mem.Allocator,
    scope_name: []u8,
    name: ?[]u8,
    first_line_match: ?[]u8 = null,
    injections_total: u32 = 0,
    injections_applied: u32 = 0,
    rules: []RuleSummary,

    pub fn deinit(self: *Summary) void {
        self.allocator.free(self.scope_name);
        if (self.name) |name| self.allocator.free(name);
        if (self.first_line_match) |pattern| self.allocator.free(pattern);
        freeRuleSummaries(self.allocator, self.rules);
        self.allocator.free(self.rules);
    }
};

pub fn freeRuleSummaries(allocator: std.mem.Allocator, rules: []RuleSummary) void {
    for (rules) |rule| {
        if (rule.name) |value| allocator.free(value);
        if (rule.capture_scope) |value| allocator.free(value);
        if (rule.content_name) |value| allocator.free(value);
        if (rule.pattern) |value| allocator.free(value);
        if (rule.end) |value| allocator.free(value);
        if (rule.include) |value| allocator.free(value);
        if (rule.captures.len != 0) allocator.free(rule.captures);
        if (rule.end_captures.len != 0) allocator.free(rule.end_captures);
    }
}
