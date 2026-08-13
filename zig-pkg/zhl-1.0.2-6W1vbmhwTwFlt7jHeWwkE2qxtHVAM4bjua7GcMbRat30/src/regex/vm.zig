const std = @import("std");
const regex_absent = @import("absent.zig");
const regex_escape = @import("escape.zig");
const regex_groups = @import("groups.zig");
const regex_match = @import("match.zig");
const regex_refs = @import("refs.zig");
const regex_scan = @import("scan.zig");
const regex_validate = @import("validate.zig");
const regex_vm_char = @import("vm_char.zig");
const regex_vm_meta = @import("vm_meta.zig");
const regex_vm_parse = @import("vm_parse.zig");
const regex_vm_types = @import("vm_types.zig");
const max_captures = regex_vm_types.max_captures;
const max_repeat = regex_vm_parse.max_repeat;
const Flags = regex_vm_types.Flags;
const MatchState = regex_vm_types.MatchState;
pub const Capture = regex_vm_types.Capture;
pub const Match = regex_vm_types.Match;
pub const CompileError = regex_vm_types.CompileError;
pub const MatchError = regex_vm_types.MatchError;
const bytesEqual = regex_vm_char.bytesEqual;
const digitAt = regex_vm_char.digitAt;
const matchClass = regex_vm_char.matchClass;
const matchEscapedByte = regex_vm_char.matchEscapedByte;
const matchUnicodeClass = regex_vm_char.matchUnicodeClass;
const spaceAt = regex_vm_char.spaceAt;
const wordAt = regex_vm_char.wordAt;
const wordBoundary = regex_vm_char.wordBoundary;
const wordEnd = regex_vm_char.wordEnd;
const wordStart = regex_vm_char.wordStart;
const applyFlagRun = regex_vm_meta.applyFlagRun;
const captureSlot = regex_vm_meta.captureSlot;
const commentGroupEnd = regex_vm_meta.commentGroupEnd;
const effectiveGroupFlags = regex_vm_meta.effectiveGroupFlags;
const findClassEnd = regex_vm_meta.findClassEnd;
const findGroupEnd = regex_vm_meta.findGroupEnd;
const groupInnerStart = regex_vm_meta.groupInnerStart;
const groupStart = regex_vm_meta.groupStart;
const inlineGroupFlags = regex_vm_meta.inlineGroupFlags;
const isCapturingGroup = regex_vm_meta.isCapturingGroup;
const namedCaptureName = regex_vm_meta.namedCaptureName;
const skipExtended = regex_vm_meta.skipExtended;
const skipIgnored = regex_vm_meta.skipIgnored;
const topLevelSplit = regex_vm_meta.topLevelSplit;
pub fn Program(comptime max_pattern: usize) type {
    return struct {
        const Self = @This();
        pattern: [max_pattern]u8 = undefined,
        len: usize = 0,
        pub fn compile(pattern: []const u8) CompileError!Self {
            @setEvalBranchQuota(10_000_000);
            if (pattern.len > max_pattern) return error.PatternTooLarge;
            var out = Self{ .len = pattern.len };
            @memcpy(out.pattern[0..pattern.len], pattern);
            if (!regex_validate.balanced(pattern) or !regex_validate.escapesSupported(pattern)) return error.UnsupportedRegex;
            if (!regex_validate.boundedRepeatsSupported(pattern, max_repeat)) return error.UnsupportedRegex;
            if (!regex_groups.supported(pattern)) return error.UnsupportedRegex;
            if (!conditionalsSupported(pattern)) return error.UnsupportedRegex;
            if (!regex_validate.lookaroundSupported(pattern)) return error.UnsupportedRegex;
            if (!regex_refs.referencesSupported(pattern)) return error.UnsupportedRegex;
            return out;
        }
        pub fn find(self: *const Self, text: []const u8, start: usize, scratch: anytype) MatchError!?Match {
            if (std.mem.startsWith(u8, self.pattern[0..self.len], "\\G"))
                return try self.matchAtSearchStart(text, start, start, scratch);
            var i = start;
            while (i <= text.len) : (i += 1) {
                if (try self.matchAtSearchStart(text, i, start, scratch)) |m| return m;
            }
            return null;
        }
        pub fn matchAt(self: *const Self, text: []const u8, start: usize, scratch: anytype) MatchError!?Match {
            var captures = [_]Capture{.{}} ** max_captures;
            return try self.matchAtWithCaptures(text, start, start, scratch, &captures);
        }
        pub fn matchAtCaptures(self: *const Self, text: []const u8, start: usize, scratch: anytype, out: anytype) MatchError!?Match {
            return try self.matchAtCapturesSearchStart(text, start, start, scratch, out);
        }
        pub fn matchAtCapturesSearchStart(self: *const Self, text: []const u8, start: usize, search_start: usize, scratch: anytype, out: anytype) MatchError!?Match {
            var captures = [_]Capture{.{}} ** max_captures;
            const found = try self.matchAtWithCaptures(text, start, search_start, scratch, &captures);
            const n = @min(out.len, captures.len);
            @memcpy(out[0..n], captures[0..n]);
            return found;
        }
        fn matchAtSearchStart(self: *const Self, text: []const u8, start: usize, search_start: usize, scratch: anytype) MatchError!?Match {
            var captures = [_]Capture{.{}} ** max_captures;
            return try self.matchAtWithCaptures(text, start, search_start, scratch, &captures);
        }
        fn matchAtWithCaptures(self: *const Self, text: []const u8, start: usize, search_start: usize, scratch: anytype, captures: *[max_captures]Capture) MatchError!?Match {
            scratch.reset();
            const pattern = self.pattern[0..self.len];
            const expr_start: usize = if (std.mem.startsWith(u8, pattern, "\\G")) 2 else 0;
            const state = try matchExpr(pattern, expr_start, pattern.len, text, start, search_start, captures, scratch, .{}, text.len);
            return if (state) |out| .{ .start = if (captures[0].set) captures[0].start else start, .end = out.pos } else null;
        }
    };
}
fn matchExpr(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const literal_alt: @import("vm_literal_alt.zig").Result = if (flags.extended) .{ .supported = false } else @import("vm_literal_alt.zig").match(pattern, start, end, text[0..limit], pos, flags.ignore_case);
    if (literal_alt.supported) return if (literal_alt.end) |next| .{ .pos = next, .limit = limit } else null;
    var branch = start;
    var i = start;
    var branch_flags = flags;
    var scan_flags = flags;
    while (true) : (i += 1) {
        if (scan_flags.extended) i = skipExtended(pattern, i, end);
        if (i == end or pattern[i] == '|') {
            const saved = captures.*;
            if (try matchSeq(pattern, branch, i, text, pos, search_start, captures, scratch, branch_flags, limit)) |out| return out;
            captures.* = saved;
            if (i == end) return null;
            branch = i + 1;
            branch_flags = scan_flags;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = findClassEnd(pattern, i) orelse end;
        } else if (commentGroupEnd(pattern, i, end)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            scan_flags = applyFlagRun(pattern[i + 2 .. next - 1], scan_flags);
            i = next - 1;
        } else if (pattern[i] == '(') {
            i = findGroupEnd(pattern, i, scan_flags) orelse end;
        }
    }
}
fn matchSeq(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    try scratch.tick();
    const seq_start = if (flags.extended) skipExtended(pattern, start, end) else start;
    if (std.mem.startsWith(u8, pattern[seq_start..end], "\\K")) {
        captures[0] = .{ .start = pos, .end = pos, .set = true };
        return try matchSeq(pattern, seq_start + 2, end, text, pos, search_start, captures, scratch, flags, limit);
    }
    if (regex_scan.isolatedFlagEnd(pattern, seq_start, end)) |next| return try matchSeq(pattern, next, end, text, pos, search_start, captures, scratch, applyFlagRun(pattern[seq_start + 2 .. next - 1], flags), limit);
    if (commentGroupEnd(pattern, seq_start, end)) |next| return try matchSeq(pattern, next, end, text, pos, search_start, captures, scratch, flags, limit);
    if (seq_start == end) return .{ .pos = pos, .limit = limit };
    const term = regex_vm_parse.term(pattern, seq_start, end, flags.extended) orelse return null;
    const repeat = regex_vm_parse.quantifier(pattern, term.end, end);
    if (canRetryGroup(pattern, term) and repeat.next == term.end) {
        if (try matchGroupThen(pattern, term, repeat.next, end, text, pos, search_start, captures, scratch, flags, limit)) |out| return out;
        return null;
    }
    return try matchRepeat(pattern, term, repeat, end, text, pos, search_start, captures, scratch, flags, limit);
}
const Term = regex_vm_parse.Term;
const Repeat = regex_vm_parse.Repeat;
fn matchRepeat(pattern: []const u8, term: Term, repeat: Repeat, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    if (!termCanCapture(pattern, term)) {
        if (isSingleRepeat(repeat)) return try matchSingleNoCaptureThenSeq(pattern, term, repeat, seq_end, text, pos, search_start, captures, scratch, flags, limit);
        return try matchRepeatNoCapture(pattern, term, repeat, seq_end, text, pos, search_start, captures, scratch, flags, limit);
    }
    if (isSingleRepeat(repeat)) return try matchSingleThenSeq(pattern, term, repeat, seq_end, text, pos, search_start, captures, scratch, flags, limit);
    return try matchRepeatWithCaptures(pattern, term, repeat, seq_end, text, pos, search_start, captures, scratch, flags, limit);
}
fn isSingleRepeat(repeat: Repeat) bool {
    return repeat.min == 1 and repeat.max == 1 and !repeat.lazy and !repeat.possessive and !repeat.optional_exact;
}
fn matchSingleThenSeq(pattern: []const u8, term: Term, repeat: Repeat, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const saved = captures.*;
    const next = try matchTerm(pattern, term, text, pos, search_start, captures, scratch, flags, limit) orelse {
        captures.* = saved;
        return null;
    };
    if (try matchSeq(pattern, repeat.next, seq_end, text, next.pos, search_start, captures, scratch, flags, next.limit)) |out| return out;
    if (canBacktrackGroupBody(pattern, term)) {
        captures.* = saved;
        if (try matchGroupThen(pattern, term, repeat.next, seq_end, text, pos, search_start, captures, scratch, flags, limit)) |out| return out;
    }
    captures.* = saved;
    return null;
}
inline fn matchSingleNoCaptureThenSeq(pattern: []const u8, term: Term, repeat: Repeat, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const next = try matchTerm(pattern, term, text, pos, search_start, captures, scratch, flags, limit) orelse return null;
    return try matchSeq(pattern, repeat.next, seq_end, text, next.pos, search_start, captures, scratch, flags, next.limit);
}
fn matchRepeatWithCaptures(pattern: []const u8, term: Term, repeat: Repeat, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    var positions: [max_repeat + 1]usize = undefined;
    var limits: [max_repeat + 1]usize = undefined;
    const base_captures = captures.*;
    positions[0] = pos;
    limits[0] = limit;
    var count: usize = 0;
    while (count < repeat.max and count < max_repeat) {
        const before = captures.*;
        const next = try matchTerm(pattern, term, text, positions[count], search_start, captures, scratch, flags, limits[count]) orelse break;
        if (next.pos == positions[count] and next.limit == limits[count] and count >= repeat.min and capturesSame(&before, captures)) {
            if (canRetryGroup(pattern, term)) if (try matchGroupThen(pattern, term, repeat.next, seq_end, text, positions[count], search_start, captures, scratch, flags, limits[count])) |out| return out;
            break;
        }
        count += 1;
        positions[count] = next.pos;
        limits[count] = next.limit;
    }
    if (repeat.optional_exact) {
        if (count == repeat.max) {
            if (!try replayRepeatCaptures(pattern, term, count, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
            if (try matchSeq(pattern, repeat.next, seq_end, text, positions[count], search_start, captures, scratch, flags, limits[count])) |out| return out;
        }
        captures.* = base_captures;
        return try matchSeq(pattern, repeat.next, seq_end, text, positions[0], search_start, captures, scratch, flags, limits[0]);
    }
    if (count < repeat.min) { captures.* = base_captures; return null; }
    if (repeat.possessive) {
        if (!try replayRepeatCaptures(pattern, term, count, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
        return try matchSeq(pattern, repeat.next, seq_end, text, positions[count], search_start, captures, scratch, flags, limits[count]);
    }
    var n = if (repeat.lazy) repeat.min else count;
    while (true) {
        if (!try replayRepeatCaptures(pattern, term, n, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
        if (try matchSeq(pattern, repeat.next, seq_end, text, positions[n], search_start, captures, scratch, flags, limits[n])) |out| return out;
        if (n > 0 and canBacktrackGroupBody(pattern, term)) {
            if (!try replayRepeatCaptures(pattern, term, n - 1, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
            if (try matchGroupThen(pattern, term, repeat.next, seq_end, text, positions[n - 1], search_start, captures, scratch, flags, limits[n - 1])) |out| return out;
        }
        if (repeat.lazy) {
            if (n == count) break;
            n += 1;
        } else {
            if (n == repeat.min) break;
            n -= 1;
        }
    }
    captures.* = base_captures;
    return null;
}
fn matchRepeatNoCapture(pattern: []const u8, term: Term, repeat: Repeat, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    var positions: [max_repeat + 1]usize = undefined;
    var limits: [max_repeat + 1]usize = undefined;
    const base_captures = captures.*;
    positions[0] = pos;
    limits[0] = limit;
    var count: usize = 0;
    while (count < repeat.max and count < max_repeat) {
        captures.* = base_captures;
        const next = try matchTerm(pattern, term, text, positions[count], search_start, captures, scratch, flags, limits[count]) orelse break;
        if (next.pos == positions[count] and next.limit == limits[count] and count >= repeat.min) break;
        count += 1;
        positions[count] = next.pos;
        limits[count] = next.limit;
    }
    if (repeat.optional_exact) {
        if (count == repeat.max) {
            captures.* = base_captures;
            if (try matchSeq(pattern, repeat.next, seq_end, text, positions[count], search_start, captures, scratch, flags, limits[count])) |out| return out;
        }
        captures.* = base_captures;
        return try matchSeq(pattern, repeat.next, seq_end, text, positions[0], search_start, captures, scratch, flags, limits[0]);
    }
    if (count < repeat.min) return null;
    if (repeat.possessive) {
        captures.* = base_captures;
        return try matchSeq(pattern, repeat.next, seq_end, text, positions[count], search_start, captures, scratch, flags, limits[count]);
    }
    var n = if (repeat.lazy) repeat.min else count;
    while (true) {
        captures.* = base_captures;
        if (try matchSeq(pattern, repeat.next, seq_end, text, positions[n], search_start, captures, scratch, flags, limits[n])) |out| return out;
        if (n > 0 and canBacktrackGroupBody(pattern, term)) {
            captures.* = base_captures;
            if (try matchGroupThen(pattern, term, repeat.next, seq_end, text, positions[n - 1], search_start, captures, scratch, flags, limits[n - 1])) |out| return out;
        }
        if (repeat.lazy) {
            if (n == count) break;
            n += 1;
        } else {
            if (n == repeat.min) break;
            n -= 1;
        }
    }
    captures.* = base_captures;
    return null;
}
fn termCanCapture(pattern: []const u8, term: Term) bool {
    return term.start < term.end and ((term.start + 1 < term.end and pattern[term.start] == '\\' and pattern[term.start + 1] == 'g') or (pattern[term.start] == '(' and captureSlot(pattern, term.end) != captureSlot(pattern, term.start)));
}
fn capturesSame(a: *const [max_captures]Capture, b: *const [max_captures]Capture) bool { for (a.*, b.*) |x, y| if (x.start != y.start or x.end != y.end or x.set != y.set) return false; return true; }
fn replayRepeatCaptures(pattern: []const u8, term: Term, count: usize, positions: *const [max_repeat + 1]usize, limits: *const [max_repeat + 1]usize, text: []const u8, search_start: usize, base_captures: *const [max_captures]Capture, captures: *[max_captures]Capture, scratch: anytype, flags: Flags) MatchError!bool {
    captures.* = base_captures.*;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const next = try matchTerm(pattern, term, text, positions[i], search_start, captures, scratch, flags, limits[i]) orelse return false;
        if (next.pos != positions[i + 1] or next.limit != limits[i + 1]) return false;
    }
    return true;
}
fn matchSeqThen(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize, suffix: usize, seq_end: usize, slot: usize, group_pos: usize, suffix_flags: Flags) MatchError!?MatchState {
    try scratch.tick();
    const seq_start = if (flags.extended) skipExtended(pattern, start, end) else start;
    if (std.mem.startsWith(u8, pattern[seq_start..end], "\\K")) {
        captures[0] = .{ .start = pos, .end = pos, .set = true };
        return try matchSeqThen(pattern, seq_start + 2, end, text, pos, search_start, captures, scratch, flags, limit, suffix, seq_end, slot, group_pos, suffix_flags);
    }
    if (regex_scan.isolatedFlagEnd(pattern, seq_start, end)) |next| return try matchSeqThen(pattern, next, end, text, pos, search_start, captures, scratch, applyFlagRun(pattern[seq_start + 2 .. next - 1], flags), limit, suffix, seq_end, slot, group_pos, suffix_flags);
    if (commentGroupEnd(pattern, seq_start, end)) |next| return try matchSeqThen(pattern, next, end, text, pos, search_start, captures, scratch, flags, limit, suffix, seq_end, slot, group_pos, suffix_flags);
    if (seq_start == end) return try finishGroupThen(pattern, text, pos, search_start, captures, scratch, limit, suffix, seq_end, slot, group_pos, suffix_flags);
    const term = regex_vm_parse.term(pattern, seq_start, end, flags.extended) orelse return null;
    const repeat = regex_vm_parse.quantifier(pattern, term.end, end);
    return try matchRepeatThen(pattern, term, repeat, end, text, pos, search_start, captures, scratch, flags, limit, suffix, seq_end, slot, group_pos, suffix_flags);
}
fn matchRepeatThen(pattern: []const u8, term: Term, repeat: Repeat, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize, suffix: usize, seq_end: usize, slot: usize, group_pos: usize, suffix_flags: Flags) MatchError!?MatchState {
    if (!termCanCapture(pattern, term)) return try matchRepeatThenNoCapture(pattern, term, repeat, end, text, pos, search_start, captures, scratch, flags, limit, suffix, seq_end, slot, group_pos, suffix_flags);
    return try matchRepeatThenWithCaptures(pattern, term, repeat, end, text, pos, search_start, captures, scratch, flags, limit, suffix, seq_end, slot, group_pos, suffix_flags);
}
fn matchRepeatThenWithCaptures(pattern: []const u8, term: Term, repeat: Repeat, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize, suffix: usize, seq_end: usize, slot: usize, group_pos: usize, suffix_flags: Flags) MatchError!?MatchState {
    var positions: [max_repeat + 1]usize = undefined;
    var limits: [max_repeat + 1]usize = undefined;
    const base_captures = captures.*;
    positions[0] = pos;
    limits[0] = limit;
    var count: usize = 0;
    while (count < repeat.max and count < max_repeat) {
        const before = captures.*;
        const next = try matchTerm(pattern, term, text, positions[count], search_start, captures, scratch, flags, limits[count]) orelse break;
        if (next.pos == positions[count] and next.limit == limits[count] and count >= repeat.min and capturesSame(&before, captures)) break;
        count += 1;
        positions[count] = next.pos;
        limits[count] = next.limit;
    }
    if (repeat.optional_exact) {
        if (count == repeat.max) {
            if (!try replayRepeatCaptures(pattern, term, count, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
            if (try matchSeqThen(pattern, repeat.next, end, text, positions[count], search_start, captures, scratch, flags, limits[count], suffix, seq_end, slot, group_pos, suffix_flags)) |out| return out;
        }
        captures.* = base_captures;
        return try matchSeqThen(pattern, repeat.next, end, text, positions[0], search_start, captures, scratch, flags, limits[0], suffix, seq_end, slot, group_pos, suffix_flags);
    }
    if (count < repeat.min) { captures.* = base_captures; return null; }
    if (repeat.possessive) {
        if (!try replayRepeatCaptures(pattern, term, count, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
        return try matchSeqThen(pattern, repeat.next, end, text, positions[count], search_start, captures, scratch, flags, limits[count], suffix, seq_end, slot, group_pos, suffix_flags);
    }
    var n = if (repeat.lazy) repeat.min else count;
    while (true) {
        if (!try replayRepeatCaptures(pattern, term, n, &positions, &limits, text, search_start, &base_captures, captures, scratch, flags)) return null;
        if (try matchSeqThen(pattern, repeat.next, end, text, positions[n], search_start, captures, scratch, flags, limits[n], suffix, seq_end, slot, group_pos, suffix_flags)) |out| return out;
        if (repeat.lazy) {
            if (n == count) break;
            n += 1;
        } else {
            if (n == repeat.min) break;
            n -= 1;
        }
    }
    captures.* = base_captures;
    return null;
}
fn matchRepeatThenNoCapture(pattern: []const u8, term: Term, repeat: Repeat, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize, suffix: usize, seq_end: usize, slot: usize, group_pos: usize, suffix_flags: Flags) MatchError!?MatchState {
    var positions: [max_repeat + 1]usize = undefined;
    var limits: [max_repeat + 1]usize = undefined;
    const base_captures = captures.*;
    positions[0] = pos;
    limits[0] = limit;
    var count: usize = 0;
    while (count < repeat.max and count < max_repeat) {
        captures.* = base_captures;
        const next = try matchTerm(pattern, term, text, positions[count], search_start, captures, scratch, flags, limits[count]) orelse break;
        if (next.pos == positions[count] and next.limit == limits[count] and count >= repeat.min) break;
        count += 1;
        positions[count] = next.pos;
        limits[count] = next.limit;
    }
    if (repeat.optional_exact) {
        if (count == repeat.max) {
            captures.* = base_captures;
            if (try matchSeqThen(pattern, repeat.next, end, text, positions[count], search_start, captures, scratch, flags, limits[count], suffix, seq_end, slot, group_pos, suffix_flags)) |out| return out;
        }
        captures.* = base_captures;
        return try matchSeqThen(pattern, repeat.next, end, text, positions[0], search_start, captures, scratch, flags, limits[0], suffix, seq_end, slot, group_pos, suffix_flags);
    }
    if (count < repeat.min) return null;
    if (repeat.possessive) {
        captures.* = base_captures;
        return try matchSeqThen(pattern, repeat.next, end, text, positions[count], search_start, captures, scratch, flags, limits[count], suffix, seq_end, slot, group_pos, suffix_flags);
    }
    var n = if (repeat.lazy) repeat.min else count;
    while (true) {
        captures.* = base_captures;
        if (try matchSeqThen(pattern, repeat.next, end, text, positions[n], search_start, captures, scratch, flags, limits[n], suffix, seq_end, slot, group_pos, suffix_flags)) |out| return out;
        if (repeat.lazy) {
            if (n == count) break;
            n += 1;
        } else {
            if (n == repeat.min) break;
            n -= 1;
        }
    }
    captures.* = base_captures;
    return null;
}
fn finishGroupThen(pattern: []const u8, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, limit: usize, suffix: usize, seq_end: usize, slot: usize, group_pos: usize, suffix_flags: Flags) MatchError!?MatchState {
    const saved = captures.*;
    if (slot != 0 and slot < captures.len) captures[slot] = .{ .start = group_pos, .end = pos, .set = true };
    if (try matchSeq(pattern, suffix, seq_end, text, pos, search_start, captures, scratch, suffix_flags, limit)) |out| return out;
    captures.* = saved;
    return null;
}
fn matchTerm(pattern: []const u8, term: Term, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    if (term.start >= term.end) return null;
    if (pattern[term.start] == '(') return try matchGroup(pattern, term, text, pos, search_start, captures, scratch, flags, limit);
    if (term.start + 1 < term.end and pattern[term.start] == '\\' and pattern[term.start + 1] == 'g') {
        return try matchSubexpCall(pattern, term.start + 1, term.end, text, pos, search_start, captures, scratch, flags, limit);
    }
    const next = switch (pattern[term.start]) {
        '.' => if (pos < limit and pos < text.len and (flags.dot_matches_line_break or !regex_match.dotExcludedAt(text, pos))) regex_match.scalarEnd(text, pos) else null,
        '^' => if (regex_escape.lineStartAnchorMatches(text, pos)) pos else null,
        '$' => if (regex_escape.lineEndAnchorMatches(text[0..limit], pos)) pos else null,
        '[' => matchClass(pattern[term.start..term.end], text, pos, flags),
        '\\' => matchEscape(pattern, term.start + 1, term.end, text, pos, search_start, captures, flags, limit),
        else => if (pos < limit) regex_escape.matchLiteralBytes(pattern[term.start..term.end], text[0..limit], pos, flags.ignore_case) else null,
    };
    return if (next) |out| if (out <= limit) .{ .pos = out, .limit = limit } else null else null;
}
fn matchGroup(pattern: []const u8, term: Term, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    if (std.mem.startsWith(u8, pattern[term.start..], "(?(")) return matchConditional(pattern, term, text, pos, search_start, captures, scratch, flags, limit);
    if (regex_absent.expressionParts(pattern, term.start)) |parts| return try matchAbsent(pattern, parts, text, pos, search_start, captures, scratch, flags, limit);
    if (regex_absent.repeaterParts(pattern, term.start)) |parts| return try matchAbsentRepeater(pattern, parts, text, pos, search_start, captures, scratch, flags, limit);
    if (regex_absent.stopperParts(pattern, term.start)) |parts| return try matchAbsentStopper(pattern, parts, text, pos, search_start, captures, scratch, flags, limit);
    if (regex_absent.rangeClearEnd(pattern, term.start) != null) return .{ .pos = pos, .limit = text.len };
    const inner_start = groupInnerStart(pattern, term.start);
    const inner_end = term.end - 1;
    const inner_flags = inlineGroupFlags(pattern, term.start, flags);
    if (std.mem.startsWith(u8, pattern[term.start..], "(?=")) return if (try matchExpr(pattern, inner_start, inner_end, text, pos, search_start, captures, scratch, flags, limit) != null) .{ .pos = pos, .limit = limit } else null;
    if (std.mem.startsWith(u8, pattern[term.start..], "(?!")) return if (try matchExpr(pattern, inner_start, inner_end, text, pos, search_start, captures, scratch, flags, limit) == null) .{ .pos = pos, .limit = limit } else null;
    if (std.mem.startsWith(u8, pattern[term.start..], "(?<=")) return if (try matchLookBehind(pattern, inner_start, inner_end, text, pos, search_start, captures, scratch, flags, limit)) .{ .pos = pos, .limit = limit } else null;
    if (std.mem.startsWith(u8, pattern[term.start..], "(?<!")) return if (!try matchLookBehind(pattern, inner_start, inner_end, text, pos, search_start, captures, scratch, flags, limit)) .{ .pos = pos, .limit = limit } else null;
    const slot = if (isCapturingGroup(pattern, term.start)) captureSlot(pattern, term.start) else 0;
    const out = try matchExpr(pattern, inner_start, inner_end, text, pos, search_start, captures, scratch, inner_flags, limit) orelse return null;
    if (slot != 0 and slot < captures.len) captures[slot] = .{ .start = pos, .end = out.pos, .set = true };
    return out;
}
fn matchAbsent(pattern: []const u8, parts: regex_absent.Parts, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const absent_limit = try absentLimit(pattern, parts, text, pos, search_start, captures, scratch, flags, limit);
    const saved = captures.*;
    const out = try matchExpr(pattern, parts.expr_start, parts.expr_end, text, pos, search_start, captures, scratch, flags, absent_limit) orelse {
        captures.* = saved;
        return null;
    };
    return if (out.pos <= absent_limit) .{ .pos = out.pos, .limit = limit } else null;
}
fn matchAbsentRepeater(pattern: []const u8, parts: regex_absent.Parts, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    return .{ .pos = try absentLimit(pattern, parts, text, pos, search_start, captures, scratch, flags, limit), .limit = limit };
}
fn matchAbsentStopper(pattern: []const u8, parts: regex_absent.Parts, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const absent_limit = try absentLimit(pattern, parts, text, pos, search_start, captures, scratch, flags, limit);
    return .{ .pos = pos, .limit = @min(limit, absent_limit) };
}
fn absentLimit(pattern: []const u8, parts: regex_absent.Parts, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!usize {
    var i = pos;
    while (i <= limit) : (i += 1) {
        const saved = captures.*;
        const found = try matchExpr(pattern, parts.absent_start, parts.absent_end, text, i, search_start, captures, scratch, flags, limit);
        captures.* = saved;
        if (found != null) return i;
    }
    return limit;
}
fn matchGroupThen(pattern: []const u8, term: Term, suffix: usize, seq_end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const inner_start = groupInnerStart(pattern, term.start);
    const inner_end = term.end - 1;
    const inner_flags = inlineGroupFlags(pattern, term.start, flags);
    const slot = if (isCapturingGroup(pattern, term.start)) captureSlot(pattern, term.start) else 0;
    var branch = inner_start;
    while (true) {
        const split = topLevelSplit(pattern, branch, inner_end, inner_flags);
        const branch_end = split orelse inner_end;
        const saved = captures.*;
        if (try matchSeqThen(pattern, branch, branch_end, text, pos, search_start, captures, scratch, inner_flags, limit, suffix, seq_end, slot, pos, flags)) |done| return done;
        captures.* = saved;
        branch = (split orelse return null) + 1;
    }
}
fn canRetryGroup(pattern: []const u8, term: Term) bool {
    const start = term.start;
    if (pattern[start] != '(' or std.mem.startsWith(u8, pattern[start..], "(?(") or std.mem.startsWith(u8, pattern[start..], "(?~") or std.mem.startsWith(u8, pattern[start..], "(?>") or std.mem.startsWith(u8, pattern[start..], "(?=") or std.mem.startsWith(u8, pattern[start..], "(?!") or std.mem.startsWith(u8, pattern[start..], "(?<=") or std.mem.startsWith(u8, pattern[start..], "(?<!")) return false;
    const inner = pattern[groupInnerStart(pattern, start) .. term.end - 1];
    return std.mem.indexOfScalar(u8, inner, '|') != null and std.mem.indexOf(u8, inner, "(?") == null;
}
fn canBacktrackGroupBody(pattern: []const u8, term: Term) bool {
    const start = term.start;
    return pattern[start] == '(' and
        !std.mem.startsWith(u8, pattern[start..], "(?(") and
        !std.mem.startsWith(u8, pattern[start..], "(?~") and
        !std.mem.startsWith(u8, pattern[start..], "(?>") and
        !std.mem.startsWith(u8, pattern[start..], "(?=") and
        !std.mem.startsWith(u8, pattern[start..], "(?!") and
        !std.mem.startsWith(u8, pattern[start..], "(?<=") and
        !std.mem.startsWith(u8, pattern[start..], "(?<!");
}
fn matchConditional(pattern: []const u8, term: Term, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const condition = conditionalBodyStart(pattern, term.start, flags) orelse return null;
    const body_end = term.end - 1;
    const split = topLevelSplit(pattern, condition.body_start, body_end, flags);
    if (try conditionSet(pattern, condition, text, pos, search_start, captures, scratch, flags, limit))
        return try matchExpr(pattern, condition.body_start, split orelse body_end, text, pos, search_start, captures, scratch, flags, limit);
    return if (split) |bar|
        try matchExpr(pattern, bar + 1, body_end, text, pos, search_start, captures, scratch, flags, limit)
    else if (condition.body_start == body_end) null else .{ .pos = pos, .limit = limit };
}
fn matchLookBehind(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!bool {
    var i: usize = 0;
    while (i <= pos) : (i += 1) {
        const saved = captures.*;
        if (try matchExprEndsAt(pattern, start, end, text, i, pos, search_start, captures, scratch, flags, limit)) return true;
        captures.* = saved;
    }
    return false;
}
fn matchExprEndsAt(pattern: []const u8, start: usize, end: usize, text: []const u8, pos: usize, target: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!bool {
    const branch_limit = @min(limit, target);
    var branch = start;
    var i = start;
    var branch_flags = flags;
    var scan_flags = flags;
    while (true) : (i += 1) {
        if (scan_flags.extended) i = skipExtended(pattern, i, end);
        if (i == end or pattern[i] == '|') {
            const saved = captures.*;
            if (try matchSeq(pattern, branch, i, text, pos, search_start, captures, scratch, branch_flags, branch_limit)) |out| {
                if (out.pos == target) return true;
            }
            captures.* = saved;
            if (i == end) return false;
            branch = i + 1;
            branch_flags = scan_flags;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = findClassEnd(pattern, i) orelse end;
        } else if (commentGroupEnd(pattern, i, end)) |next| {
            i = next - 1;
        } else if (regex_scan.isolatedFlagEnd(pattern, i, end)) |next| {
            scan_flags = applyFlagRun(pattern[i + 2 .. next - 1], scan_flags);
            i = next - 1;
        } else if (pattern[i] == '(') {
            i = findGroupEnd(pattern, i, scan_flags) orelse end;
        }
    }
}
fn matchEscape(pattern: []const u8, index: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, flags: Flags, limit: usize) ?usize {
    if (index >= end) return null;
    return switch (pattern[index]) {
        'A' => if (pos == 0) pos else null,
        'G' => if (pos == search_start) pos else null,
        'z' => if (pos == limit) pos else null,
        'Z' => if (regex_escape.endAnchorMatches(text[0..limit], pos, true)) pos else null,
        'b' => if (wordBoundary(text, pos, flags)) pos else null,
        'B' => if (!wordBoundary(text, pos, flags)) pos else null,
        'm' => if (wordStart(text, pos, flags)) pos else null,
        'M' => if (regex_escape.parseMeta(pattern, index, end)) |parsed| matchEscapedByte(parsed, text, pos, flags) else if (wordEnd(text, pos, flags)) pos else null,
        'd' => digitAt(text, pos, flags),
        'h' => if (pos < text.len and std.ascii.isHex(text[pos])) pos + 1 else null,
        'w' => wordAt(text, pos, flags),
        's' => spaceAt(text, pos, flags),
        'N' => if (pos < text.len and !regex_match.dotExcludedAt(text, pos)) regex_match.scalarEnd(text, pos) else null,
        'O' => if (pos < text.len) regex_match.scalarEnd(text, pos) else null,
        'R' => regex_match.generalNewline(text, pos),
        'X' => regex_match.textSegment(text, pos),
        'y' => if (regex_match.textSegmentBoundary(text, pos)) pos else null,
        'Y' => if (!regex_match.textSegmentBoundary(text, pos)) pos else null,
        'D' => if (pos < text.len and digitAt(text, pos, flags) == null) regex_match.scalarEnd(text, pos) else null,
        'H' => if (pos < text.len and !std.ascii.isHex(text[pos])) regex_match.scalarEnd(text, pos) else null,
        'W' => if (pos < text.len and wordAt(text, pos, flags) == null) regex_match.scalarEnd(text, pos) else null,
        'S' => if (pos < text.len and spaceAt(text, pos, flags) == null) regex_match.scalarEnd(text, pos) else null,
        '1'...'9' => |digit| matchBackref(digit - '0', text, pos, captures, flags),
        'k' => matchNamedBackref(pattern, index, end, text, pos, captures, flags),
        'g' => null,
        'p' => matchUnicodeClass(pattern, index, end, text, pos, false, flags),
        'P' => matchUnicodeClass(pattern, index, end, text, pos, true, flags),
        'x' => regex_escape.matchCodepoint(regex_escape.parseCodepoint(pattern, index, end), text, pos, flags.ignore_case),
        '0' => matchEscapedByte(regex_escape.parseOctal(pattern, index, end), text, pos, flags),
        'o', 'u' => regex_escape.matchCodepoint(regex_escape.parseCodepoint(pattern, index, end), text, pos, flags.ignore_case),
        'c', 'C' => matchEscapedByte(regex_escape.parseControl(pattern, index, end) orelse regex_escape.parseControlDash(pattern, index, end), text, pos, flags),
        else => |c| if (pos < text.len and bytesEqual(text[pos], regex_escape.byte(c), flags.ignore_case)) pos + 1 else null,
    };
}
fn matchBackref(slot: usize, text: []const u8, pos: usize, captures: *const [max_captures]Capture, flags: Flags) ?usize {
    if (slot >= captures.len or !captures[slot].set) return null;
    const value = text[captures[slot].start..captures[slot].end];
    return regex_escape.matchLiteralBytes(value, text, pos, flags.ignore_case);
}
fn matchSubexpCall(pattern: []const u8, index: usize, end: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const value = regex_refs.sameLevel(regex_refs.name(pattern, index, end) orelse return null);
    if (regex_refs.nonnegativeInteger(value)) |slot| return try matchSubexpSlot(pattern, slot, text, pos, search_start, captures, scratch, flags, limit);
    if (regex_refs.relativeInteger(value)) |offset| return try matchSubexpSlot(pattern, relativeBackrefSlot(pattern, index, offset) orelse return null, text, pos, search_start, captures, scratch, flags, limit);
    return try matchSubexpGroup(pattern, groupStart(pattern, 0, value) orelse return null, text, pos, search_start, captures, scratch, flags, limit);
}
fn matchSubexpSlot(pattern: []const u8, slot: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    if (slot == 0) return try matchExpr(pattern, 0, pattern.len, text, pos, search_start, captures, scratch, flags, limit);
    return try matchSubexpGroup(pattern, groupStart(pattern, slot, "") orelse return null, text, pos, search_start, captures, scratch, flags, limit);
}
fn matchSubexpGroup(pattern: []const u8, group_start: usize, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!?MatchState {
    const group_end = findGroupEnd(pattern, group_start, flags) orelse return null;
    const out = try matchExpr(pattern, groupInnerStart(pattern, group_start), group_end, text, pos, search_start, captures, scratch, effectiveGroupFlags(pattern, group_start, flags), limit) orelse return null;
    const slot = captureSlot(pattern, group_start);
    if (slot < captures.len) captures[slot] = .{ .start = pos, .end = out.pos, .set = true };
    return out;
}
fn matchNamedBackref(pattern: []const u8, index: usize, end: usize, text: []const u8, pos: usize, captures: *const [max_captures]Capture, flags: Flags) ?usize {
    const name = regex_refs.sameLevel(regex_refs.name(pattern, index, end) orelse return null);
    if (regex_refs.positiveInteger(name)) |slot| return matchBackref(slot, text, pos, captures, flags);
    if (regex_refs.relativeInteger(name)) |offset| return matchBackref(relativeBackrefSlot(pattern, index, offset) orelse return null, text, pos, captures, flags);
    var slot: usize = 0;
    var best: ?usize = null;
    var scan_flags = Flags{};
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) {
            continue;
        } else if (pattern[i] == '\\') {
            i += 1;
        } else if (pattern[i] == '[') {
            i = findClassEnd(pattern, i) orelse return null;
        } else if (pattern[i] == '(' and isCapturingGroup(pattern, i)) {
            slot += 1;
            const capture_name = namedCaptureName(pattern, i) orelse continue;
            if (std.mem.eql(u8, name, capture_name)) best = matchBackref(slot, text, pos, captures, flags) orelse best;
        }
    }
    return best;
}
fn relativeBackrefSlot(pattern: []const u8, index: usize, offset: isize) ?usize {
    const before = captureSlot(pattern, index) - 1;
    if (offset >= 0) return before + @as(usize, @intCast(offset));
    const back: usize = @intCast(-offset);
    return if (back <= before) before - back + 1 else null;
}
fn readNumber(pattern: []const u8, index: *usize) ?usize {
    const start = index.*;
    var value: usize = 0;
    while (index.* < pattern.len and std.ascii.isDigit(pattern[index.*])) : (index.* += 1) value = value * 10 + pattern[index.*] - '0';
    return if (index.* == start) null else value;
}
const Conditional = struct {
    slot: usize = 0,
    name: []const u8 = "",
    expr_start: usize = 0,
    expr_end: usize = 0,
    body_start: usize,
};
fn conditionalBodyStart(pattern: []const u8, start: usize, flags: Flags) ?Conditional {
    if (!std.mem.startsWith(u8, pattern[start..], "(?(")) return null;
    var i = start + 3;
    if (i >= pattern.len) return null;
    const close_byte: ?u8 = switch (pattern[i]) {
        '<' => '>',
        '\'' => '\'',
        else => null,
    };
    if (close_byte) |close| {
        const name_start = i + 1;
        const name_len = std.mem.indexOfScalar(u8, pattern[name_start..], close) orelse return null;
        i = name_start + name_len + 1;
        if (name_len == 0 or i >= pattern.len or pattern[i] != ')') return null;
        const value = regex_refs.sameLevel(pattern[name_start .. name_start + name_len]);
        if (conditionSlot(pattern, start, value)) |slot| return .{ .slot = slot, .body_start = i + 1 };
        if (!regex_refs.validName(value)) return null;
        return .{ .name = value, .body_start = i + 1 };
    }
    if (readNumber(pattern, &i)) |slot| {
        if (slot == 0 or i >= pattern.len or pattern[i] != ')') return null;
        return .{ .slot = slot, .body_start = i + 1 };
    }
    const signed_start = i;
    if (readSignedConditionSlot(pattern, start, &i)) |slot| {
        if (i >= pattern.len or pattern[i] != ')') return null;
        return .{ .slot = slot, .body_start = i + 1 };
    }
    if (i != signed_start) return null;
    if (pattern[i] == '?' and i + 1 < pattern.len and (pattern[i + 1] == '=' or pattern[i + 1] == '!' or pattern[i + 1] == '<')) {
        const close = findGroupEnd(pattern, start + 2, flags) orelse return null;
        return .{ .expr_start = start + 2, .expr_end = close + 1, .body_start = close + 1 };
    }
    const condition_end = findConditionEnd(pattern, i, flags) orelse return null;
    return .{ .expr_start = i, .expr_end = condition_end, .body_start = condition_end + 1 };
}
fn conditionSlot(pattern: []const u8, condition_start: usize, value: []const u8) ?usize {
    if (regex_refs.positiveInteger(value)) |slot| return slot;
    if (regex_refs.relativeInteger(value)) |offset| return relativeBackrefSlot(pattern, condition_start, offset);
    return null;
}
fn readSignedConditionSlot(pattern: []const u8, condition_start: usize, index: *usize) ?usize {
    const start = index.*;
    if (start >= pattern.len or (pattern[start] != '-' and pattern[start] != '+')) return null;
    index.* += 1;
    while (index.* < pattern.len and std.ascii.isDigit(pattern[index.*])) : (index.* += 1) {}
    if (index.* == start + 1) return null;
    return conditionSlot(pattern, condition_start, pattern[start..index.*]);
}
fn conditionSet(pattern: []const u8, condition: Conditional, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, flags: Flags, limit: usize) MatchError!bool {
    if (condition.slot != 0) return condition.slot < captures.len and captures[condition.slot].set;
    if (condition.expr_end > condition.expr_start) {
        const saved = captures.*;
        defer captures.* = saved;
        return try matchExpr(pattern, condition.expr_start, condition.expr_end, text, pos, search_start, captures, scratch, flags, limit) != null;
    }
    var slot: usize = 0;
    var scan_flags = Flags{};
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) continue else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return false else if (pattern[i] == '(' and isCapturingGroup(pattern, i)) {
            slot += 1;
            if (slot < captures.len and captures[slot].set and std.mem.eql(u8, condition.name, namedCaptureName(pattern, i) orelse "")) return true;
        }
    }
    return false;
}
fn findConditionEnd(pattern: []const u8, start: usize, flags: Flags) ?usize {
    var i = start;
    var scan_flags = flags;
    while (i < pattern.len) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) continue;
        if (pattern[i] == ')') return i;
        if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return null else if (pattern[i] == '(') i = findGroupEnd(pattern, i, scan_flags) orelse return null;
    }
    return null;
}
fn conditionalsSupported(pattern: []const u8) bool {
    var scan_flags = Flags{};
    var i: usize = 0;
    while (i + 2 < pattern.len) : (i += 1) {
        if (skipIgnored(pattern, &i, pattern.len, &scan_flags)) continue else if (pattern[i] == '\\') i += 1 else if (pattern[i] == '[') i = findClassEnd(pattern, i) orelse return false else if (std.mem.startsWith(u8, pattern[i..], "(?(")) {
            if (conditionalBodyStart(pattern, i, scan_flags) == null) return false;
        }
    }
    return true;
}
test "regex VM handles grouped alternation and lookaround" {
    const P = Program(256);
    const p = try P.compile("(?<![$_[:alnum:]])(?:(?<=\\.\\.\\.)|(?<!\\.))(this|true)(?![$_[:alnum:]])");
    const flags = try P.compile("(?-im:(?<!\\w)(?:void|int)(?!\\w))");
    const bounded = try P.compile("(?<![$_[:alnum:]])(?:(?<=\\.\\.\\.)|(?<!\\.))(?:\\b(export)\\s+)?(?:\\b(declare)\\s+)?\\b(const(?!\\s+enum\\b))(?![$_[:alnum:]])(?:(?=\\.\\.\\.)|(?!\\.))\\s*");
    const ident = try P.compile("\\b([_[:alpha:]]\\w*)\\b");
    const ident_start = try P.compile("[_[:alpha:]]");
    const word_tail = try P.compile("\\w*");
    const unicode_word = try P.compile("\\p{word}+");
    const anchored = try P.compile("\\G(true|false)");
    const anchored_alt = try P.compile("(?:^|\\G)true");
    const class_n = try P.compile("[n]");
    const class_backslash_n = try P.compile("[\\\\n]");
    const possessive = try P.compile("((?:[A-Z_a-z][0-9A-Z_a-z]*+|::)++)\\s*(\\()");
    const possessive_star = try P.compile("a*+a");
    const possessive_maybe = try P.compile("a?+a");
    const bounded_plus = try P.compile("a{1,2}+a");
    const yaml_key_begin = try P.compile("[^-\\]!\"#%\\&'*,:>?@\\[`{|}\\s]|[-:?]\\S");
    const yaml_key_lookahead = try P.compile("(?=(?:[^-\\]!\"#%\\&'*,:>?@\\[`{|}\\s]|[-:?]\\S)([^:\\s]|:\\S|\\s+(?![#\\s]))*\\s*:(\\s|$))");
    const shell_builtin = try P.compile("(?<!\\w)(?:printf)(?!/)(?!\\w)(?!-)");
    const shell_command = try Program(1024).compile("[\\t ]*+(?![\\n!#\\&()<>\\[{|]|$|[\\t ;])(?!nocorrect |nocorrect\\t|nocorrect$|readonly |readonly\\t|readonly$|function |function\\t|function$|foreach |foreach\\t|foreach$|coproc |coproc\\t|coproc$|logout |logout\\t|logout$|export |export\\t|export$|select |select\\t|select$|repeat |repeat\\t|repeat$|pushd |pushd\\t|pushd$|until |until\\t|until$|while |while\\t|while$|local |local\\t|local$|case |case\\t|case$|done |done\\t|done$|elif |elif\\t|elif$|else |else\\t|else$|esac |esac\\t|esac$|popd |popd\\t|popd$|then |then\\t|then$|time |time\\t|time$|for |for\\t|for$|end |end\\t|end$|fi |fi\\t|fi$|do |do\\t|do$|in |in\\t|in$|if |if$)(?!\\\\\\n?$)");
    const shell_argument = try P.compile("[\\t ]++(?![\\n#\\&(\\[|]|$|;)");
    const shell_word_end = try P.compile("(?=[\\t \\&;|]|$|[\\n)`])|(?=<)");
    const c_escape_class = try P.compile("[\"'?\\\\abefnprtv]");
    const c_escape = try P.compile("\\\\([\"'?\\\\abefnprtv]|[0-3]\\d{0,2}|[4-7]\\d?|x\\h{0,2}|u\\h{0,4}|U\\h{0,8})");
    const omitted_min = try P.compile("a{,2}b");
    const exact_reluctant = try P.compile("a{2}?b");
    const repeat_space_300 = try P.compile("\\s{300}");
    const ignore_case = try P.compile("(?i:if|while)+");
    const isolated_case = try P.compile("a(?i)b");
    const isolated_case_alt = try P.compile("(?:(?i)a|b)");
    const isolated_extended = try P.compile("(?x)% (\\d+)? # field\n [s]");
    const isolated_extended_alt = try P.compile("(?:(?x)a b|c d)");
    const isolated_extended_comment_syntax = try P.compile("(?x)(a # fake (?q) extension\n)");
    const extended_comment_close = try P.compile("(?x)(a # fake ) closer\n)b");
    const extended_comment_pipe = try P.compile("(?x)(a # fake |\n|b)c");
    const extended_disabled_group = try P.compile("(?x)(?-x:#)");
    const extended_comment_numeric_backref = try P.compile("(?x)# (fake)\n(a)\\1");
    const extended_comment_subexp = try P.compile("(?x)# (fake)\n(a)\\g<1>");
    const extended_comment_conditional = try P.compile("(?x)# (fake)\n(a)?(?(1)yes|no)");
    const extended_comment_fake_conditional = try P.compile("(?x)# (?(?q)bad|bad)\na");
    const extended_comment_regex_condition = try P.compile("(?x)(?(a # fake )\n)a|b)");
    const ascii_flags = try P.compile("(?WDSPy:abc)");
    const isolated_ascii_flags = try P.compile("(?WDS)y");
    const segment_flags = try P.compile("(?y{g}:abc)");
    const isolated_segment_flags = try P.compile("(?y{g})abc");
    const word_segment_flags = try P.compile("(?y{w}:abc)");
    const isolated_word_segment_flags = try P.compile("(?y{w})abc");
    const comment_group = try P.compile("a(?# ignored ( | )b|ac");
    const comment_before_capture = try P.compile("(?# fake ( group )(a)\\1");
    const conditional = try P.compile("(a)?(?(1)yes|no)");
    const conditional_comment = try P.compile("(a)?(?(1)(?# ignored | )yes|no)");
    const conditional_lookahead = try P.compile("(?(?=a)a|b)");
    const conditional_literal = try P.compile("(?(a)a|b)");
    const named_cond_angle = try P.compile("(?<word>a)?(?(<word>)yes|no)");
    const named_cond_quote = try P.compile("(?'word'a)?(?('word')yes|no)");
    const numeric_cond_quote = try P.compile("(a)?(?('1')yes|no)");
    const numeric_cond_quote_level = try P.compile("(a)?(?('1+0')yes|no)");
    const relative_cond = try P.compile("(a)?(?(-1)yes|no)");
    const relative_cond_angle = try P.compile("(a)?(?(<-1>)yes|no)");
    const relative_cond_quote = try P.compile("(a)?(?('-1')yes|no)");
    const wrapped_numeric_cond = try P.compile("(a)?(?(<1>)yes|no)");
    const atomic = try P.compile("(?>ab|a)b");
    const named_angle = try P.compile("(?<word>ab)\\k<word>");
    const named_quote = try P.compile("(?'word'ab)\\k'word'");
    const named_numeric = try P.compile("(ab)\\k<1>");
    const named_numeric_quote = try P.compile("(ab)\\k'1'");
    const named_level = try P.compile("(?<word>ab)\\k<word+0>");
    const named_quote_level = try P.compile("(?'word'ab)\\k'word-0'");
    const named_numeric_level = try P.compile("(ab)\\k<1+0>");
    const named_numeric_quote_level = try P.compile("(ab)\\k'1+0'");
    const relative_numeric = try P.compile("(a)(b)\\k<-1>\\k<-2>");
    const relative_numeric_level = try P.compile("(a)(b)\\k<-1+0>\\k<-2+0>");
    const duplicate_name = try P.compile("(?<word>ab)(?<word>a)?\\k<word>");
    const ci_numbered_backref = try P.compile("(?i)(ab)\\1");
    const ci_named_backref = try P.compile("(?i)(?<word>ab)\\k<word>");
    const ci_relative_backref = try P.compile("(?i)(a)(b)\\k<-1>\\k<-2>");
    const scoped_sensitive_backref = try P.compile("(?i:(?-i:(ab)\\1))");
    const conditional_bare_regex = try P.compile("(?(name)yes|no)");
    const named_cond_level = try P.compile("(?<word>a)?(?(<word+0>)yes|no)");
    const numeric_cond_level = try P.compile("(a)?(?(<1+0>)yes|no)");
    const subexp_numeric = try P.compile("(ab)\\g<1>");
    const subexp_numeric_quote = try P.compile("(ab)\\g'1'");
    const subexp_named = try P.compile("(?<word>ab)\\g<word>");
    const subexp_named_quote = try P.compile("(?'word'ab)\\g'word'");
    const subexp_relative = try P.compile("(a)(b)\\g<-1>\\g<-2>");
    const subexp_forward = try P.compile("\\g<+1>(ab)");
    const subexp_forward_quote = try P.compile("\\g'+1'(ab)");
    const subexp_level = try P.compile("(?<word>ab)\\g<word+0>");
    const subexp_quote_level = try P.compile("(?'word'ab)\\g'word+0'");
    const subexp_called_options = try P.compile("(?-i:\\g<word>)(?i:(?<word>a)){0}");
    const subexp_zero_width_named_def = try P.compile("(?<path>[A-Z]+){0}\\g<path>");
    const subexp_zero_width_named_def_quoted = try P.compile("(?<path>[A-Z]+){0}\"\\g<path>\"");
    const dotted_subexp = try P.compile("(?<type.name>a)\\g<type.name>");
    const dotted_subexp_quote = try P.compile("(?'type.name'a)\\g'type.name'");
    const subexp_whole = try P.compile("a\\g<0>?");
    const subexp_whole_quote = try P.compile("a\\g'0'?");
    const mixed_numbered = try P.compile("(?<x>a)(b)\\2");
    const mixed_named_numeric = try P.compile("(?<x>a)(b)\\k<2>");
    const mixed_named_relative = try P.compile("(?<x>a)(b)\\k<-1>");
    const mixed_subexp_numeric = try P.compile("(?<x>a)(b)\\g<2>");
    const mixed_subexp_relative = try P.compile("(?<x>a)(b)\\g<-1>");
    const keep = try P.compile("foo\\Kbar");
    const keep_alt = try P.compile("foo\\Kbar|baz\\Kqux");
    const spaces_300 = [_]u8{' '} ** 300;
    var scratch = @import("scratch.zig").VmScratch(256).init();
    var captures = [_]Capture{.{}} ** max_captures;
    try std.testing.expectEqual(@as(usize, 4), (try p.matchAt("this", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try p.matchAt("a.this", 2, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try flags.matchAt("int", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try bounded.matchAtCaptures("const name", 0, &scratch, &captures)).?.end);
    try std.testing.expect(captures[3].set);
    try std.testing.expectEqual(@as(usize, 0), captures[3].start);
    try std.testing.expectEqual(@as(usize, 5), captures[3].end);
    try std.testing.expectEqual(@as(usize, 1), (try ident_start.matchAt("g", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try word_tail.matchAt("greet", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try unicode_word.matchAt("greet", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 9), (try ident.matchAt("def greet", 4, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try anchored.matchAt("x true", 2, &scratch)).?.end);
    try std.testing.expect(try anchored.find("x true", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 2), (try anchored.find("x true", 2, &scratch)).?.start);
    try std.testing.expect(try anchored_alt.find("x true", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 2), (try anchored_alt.find("x true", 2, &scratch)).?.start);
    try std.testing.expectEqual(@as(usize, 1), (try class_n.matchAt("n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try class_backslash_n.matchAt("n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try possessive.matchAtCaptures("main(", 0, &scratch, &captures)).?.end);
    try std.testing.expectEqual(@as(usize, 0), captures[1].start);
    try std.testing.expectEqual(@as(usize, 4), captures[1].end);
    try std.testing.expectEqual(@as(?Match, null), try possessive_star.matchAt("aaa", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try possessive_maybe.matchAt("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try bounded_plus.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try bounded_plus.matchAt("aaa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try yaml_key_begin.matchAt("name: zhl", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 0), (try yaml_key_lookahead.matchAt("name: zhl", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try shell_builtin.matchAt("printf", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 0), (try shell_command.matchAt("printf", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try shell_argument.matchAt(" \"x\"", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try shell_word_end.matchAt("printf x", 6, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try c_escape_class.matchAt("n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try c_escape.matchAt("\\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try omitted_min.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try omitted_min.matchAt("aab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try omitted_min.matchAt("aaab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try exact_reluctant.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try exact_reluctant.matchAt("aab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try exact_reluctant.matchAt("ab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 300), (try repeat_space_300.matchAt(spaces_300[0..], 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try repeat_space_300.matchAt(spaces_300[0..299], 0, &scratch));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("a{3,2}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("a{1025}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(ab){1,1025}"));
    try std.testing.expectEqual(@as(usize, 9), (try ignore_case.find("x IFWhile", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try isolated_case.matchAt("aB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try isolated_case_alt.matchAt("B", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try isolated_extended.matchAt("%42s", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try isolated_extended_alt.matchAt("cd", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try isolated_extended_comment_syntax.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try extended_comment_close.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try extended_comment_pipe.matchAt("ac", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try extended_comment_pipe.matchAt("bc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try extended_disabled_group.matchAt("#", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try extended_comment_numeric_backref.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try extended_comment_subexp.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try extended_comment_conditional.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try extended_comment_fake_conditional.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try extended_comment_regex_condition.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try extended_comment_regex_condition.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try ascii_flags.matchAt("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try isolated_ascii_flags.matchAt("y", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try segment_flags.matchAt("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try isolated_segment_flags.matchAt("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try word_segment_flags.matchAt("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try isolated_word_segment_flags.matchAt("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try comment_group.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try comment_group.matchAt("ac", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try comment_before_capture.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try conditional.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try conditional.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try conditional_comment.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try conditional_lookahead.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try conditional_lookahead.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try conditional_literal.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try conditional_literal.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_cond_angle.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try named_cond_angle.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_cond_quote.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try numeric_cond_quote.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try numeric_cond_quote_level.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try relative_cond.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try relative_cond.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try relative_cond_angle.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try relative_cond_angle.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try relative_cond_quote.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try wrapped_numeric_cond.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try wrapped_numeric_cond.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try atomic.matchAt("ab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try atomic.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_angle.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try named_angle.matchAt("abac", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try named_quote.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_numeric.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_numeric_quote.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_quote_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_numeric_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_numeric_quote_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try relative_numeric.matchAt("abba", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try relative_numeric_level.matchAt("abba", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try duplicate_name.matchAt("abaa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try duplicate_name.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try ci_numbered_backref.matchAt("abAB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try ci_named_backref.matchAt("abAB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try ci_relative_backref.matchAt("abBA", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try scoped_sensitive_backref.matchAt("abAB", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try scoped_sensitive_backref.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try conditional_bare_regex.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try named_cond_level.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try named_cond_level.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try numeric_cond_level.matchAt("ayes", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try numeric_cond_level.matchAt("no", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_numeric.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_numeric_quote.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_named.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_named_quote.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_relative.matchAt("abba", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_forward.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_forward_quote.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_quote_level.matchAt("abab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try subexp_called_options.matchAt("A", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try subexp_zero_width_named_def.matchAt("PATH", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try subexp_zero_width_named_def.matchAt("path", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 6), (try subexp_zero_width_named_def_quoted.matchAt("\"PATH\"", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try dotted_subexp.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try dotted_subexp_quote.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try subexp_whole.matchAt("aaa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try subexp_whole_quote.matchAt("aaa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_numbered.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_named_numeric.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_named_relative.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_subexp_numeric.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_subexp_relative.matchAt("abb", 0, &scratch)).?.end);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\1"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(a)\\2"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\k<missing>"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<type.name>a)\\k<type.name>"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<type-name>a)\\k<type-name>"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?'type-name'a)\\k'type-name'"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<type.name>a)?(?(<type.name>)yes|no)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<type-name>a)?(?(<type-name>)yes|no)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\g<2>(a)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<x>a)(?<x>b)\\g<x>"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<x>a)?(?('bad.name')yes|no)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\g<0>a"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(\\g<1>)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<x>\\g<x>)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<x>a|\\g<x>b)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("("));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("["));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?C)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?C42)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?{code})"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?{code}X)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(*name)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(*name[tag]{arg})"));
    _ = try P.compile("(?<x>a|b\\g<x>)");
    const kept = (try keep.find("x foobar", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 5), kept.start);
    try std.testing.expectEqual(@as(usize, 8), kept.end);
    const kept_alt = (try keep_alt.matchAt("bazqux", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 3), kept_alt.start);
    try std.testing.expectEqual(@as(usize, 6), kept_alt.end);
}

test "regex VM handles shorthand and anchor lookaround" {
    const P = Program(64);
    const line_start = try P.compile("^abc");
    const line_end = try P.compile("abc$");
    const non_space_ahead = try P.compile("(?=\\S)\\w+");
    const space_ahead = try P.compile("(?!\\S)\\s+");
    const end_ahead = try P.compile("\\w+(?=$)");
    const space_behind = try P.compile("(?<=\\s)\\w+");
    const no_non_space_behind = try P.compile("(?<!\\S)\\w+");
    const property_ahead = try P.compile("(?=\\p{Alpha})\\w+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 4), (try non_space_ahead.matchAt("word", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try line_start.find("xx\nabc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try line_end.find("abc\r\nx", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try line_end.find("abc\xe2\x80\xa8x", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try line_end.find("abcx", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try non_space_ahead.matchAt(" word", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try non_space_ahead.matchAt("\xe2\x80\xa8word", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try space_ahead.matchAt(" word", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try end_ahead.find("x end", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try end_ahead.find("x end\nnext", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try end_ahead.matchAt("end ", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 5), (try space_behind.matchAt(" word", 1, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try no_non_space_behind.matchAt("word", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try no_non_space_behind.matchAt("xword", 1, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try property_ahead.matchAt("word", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try property_ahead.matchAt("1word", 0, &scratch));
}

test "regex VM handles Oniguruma word start and end anchors" {
    const P = Program(32);
    const exact = try P.compile("\\mword\\M");
    const run = try P.compile("\\m\\w+\\M");
    const meta = try P.compile("\\M-a");
    var scratch = @import("scratch.zig").VmScratch(32).init();

    const word = (try exact.find("a word!", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), word.start);
    try std.testing.expectEqual(@as(usize, 6), word.end);
    try std.testing.expectEqual(@as(?Match, null), try exact.find("swordfish", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try run.find(" a_b ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try run.find(" é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try meta.matchAt("\xe1", 0, &scratch)).?.end);
}

test "regex VM handles negative shorthand classes" {
    const P = Program(32);
    const hex = try P.compile("\\h+");
    const non_digit = try P.compile("\\D+");
    const non_space = try P.compile("\\S+");
    const non_word = try P.compile("\\W+");
    const non_hex = try P.compile("\\H+");
    const class_hex = try P.compile("[\\h]+");
    const class_non_digit = try P.compile("[\\D]+");
    const class_non_space = try P.compile("[\\S]+");
    const class_non_word = try P.compile("[\\W]+");
    const class_non_hex = try P.compile("[\\H]+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 4), (try hex.matchAt("7fAFz", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try hex.matchAt("z", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 5), (try non_digit.find("12-ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try non_space.matchAt("\x85", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try non_space.matchAt("\xe2\x80\xa8", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try non_space.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try non_word.find("ab- ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try non_word.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try non_hex.find("7f-z", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try non_digit.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try class_hex.matchAt("7fAFz", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_hex.matchAt("z", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 5), (try class_non_digit.find("12-ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_non_space.matchAt("\x85", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try class_non_space.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try class_non_word.find("ab- ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_non_word.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try class_non_hex.find("7f-z", 0, &scratch)).?.end);
}

test "regex VM retries group alternatives before suffix" {
    const P = Program(64);
    const capture = try P.compile("(ab|a)b");
    const shy = try P.compile("(?:ab|a)b");
    const named = try P.compile("(?<x>ab|a)b");
    const atomic = try P.compile("(?>ab|a)b");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 2), (try capture.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try shy.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try named.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try atomic.matchAt("ab", 0, &scratch));
}

test "regex VM checks capture status for zero-length repeats" {
    const P = Program(64);
    const both_empty = try P.compile("(?:()|())*\\1\\2");
    const trailing = try P.compile("(?:\\1a|())*");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 0), (try both_empty.matchAt("", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try trailing.matchAt("a", 0, &scratch)).?.end);
}

test "regex VM keeps unnamed numeric slots in named mode" {
    const P = Program(64);
    const named = try P.compile("(a)(?<word>b)\\k<word>");
    var scratch = @import("scratch.zig").VmScratch(64).init();
    var captures = [_]Capture{.{}} ** 4;

    try std.testing.expectEqual(@as(usize, 3), (try named.matchAtCaptures("abb", 0, &scratch, &captures)).?.end);
    try std.testing.expectEqual(@as(usize, 0), captures[1].start);
    try std.testing.expectEqual(@as(usize, 1), captures[1].end);
    try std.testing.expectEqual(@as(usize, 1), captures[2].start);
    try std.testing.expectEqual(@as(usize, 2), captures[2].end);
}

test "regex VM enforces scratch step limit" {
    const P = Program(32);
    const p = try P.compile("(a|aa)*b");
    var scratch = @import("scratch.zig").VmScratch(64).init();
    scratch.step_limit = 1;

    try std.testing.expectError(error.RegexStepLimitExceeded, p.find("aaaaab", 0, &scratch));
}

test "regex VM rejects repeated lookaround" {
    const P = Program(64);

    _ = try P.compile("(?=a)a");
    _ = try P.compile("(?!b)a");
    _ = try P.compile("(?<=a)b");
    _ = try P.compile("(?<!b)a");
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?=a)*"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?!b){5}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?=a)?"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<=a)*"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<=a)+"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<=a)?"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<=a){2}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<!a)*"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<!a){2}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("a(?i)*"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("a(?-i){1,2}"));
}

test "regex VM rejects negative lookbehind captures" {
    const P = Program(64);
    const positive_capture = try P.compile("(?<=(a))b\\1");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    _ = try P.compile("(?<!a)b");
    _ = try P.compile("(?<!(?:a))b");
    _ = try P.compile("(?<=(a))b");
    try std.testing.expectEqual(@as(usize, 3), (try positive_capture.matchAt("aba", 1, &scratch)).?.end);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<!(a))b"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<!(?<x>a))b"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?<x>a)(?<!(b))c"));
}

test "regex VM handles variable-width lookbehind" {
    const P = Program(64);
    const positive = try P.compile("(?<=a+)b");
    const negative = try P.compile("(?<!a+)b");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 4), (try positive.matchAt("aaab", 3, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try negative.matchAt("aaab", 3, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try negative.matchAt("b", 0, &scratch)).?.end);
}

test "regex VM handles Oniguruma newline escapes" {
    const P = Program(32);
    const dot = try P.compile(".+");
    const dot_all = try P.compile("(?m:.)");
    const dot_all_disabled = try P.compile("(?m:(?-m:.))");
    const no_line_break = try P.compile("\\N+");
    const any_byte = try P.compile("\\O+");
    const newline = try P.compile("a\\Rb");
    const segment = try P.compile("\\y\\X\\y");
    const inner_segment = try P.compile("\\r\\Y\\n");
    const no_inner_boundary = try P.compile("\\r\\y\\n");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 4), (try dot.matchAt("abc\r", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try dot.matchAt("é\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\r", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\x0b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try dot.matchAt("\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot_all.matchAt("\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try dot_all_disabled.matchAt("\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try no_line_break.matchAt("abc\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try no_line_break.matchAt("é\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try no_line_break.matchAt("\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try no_line_break.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try no_line_break.matchAt("\xe2\x80\xa9", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try any_byte.matchAt("\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try any_byte.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try newline.matchAt("a\r\nb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try newline.matchAt("a\nb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try newline.matchAt("a\x85b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try newline.matchAt("a\xe2\x80\xa8b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try newline.matchAt("a\xe2\x80\xa9b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try segment.matchAt("\r\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try segment.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try segment.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try inner_segment.matchAt("\r\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try no_inner_boundary.matchAt("\r\n", 0, &scratch));
}

test "regex VM handles Oniguruma absolute end anchors" {
    const P = Program(32);
    const lower = try P.compile("\\Aabc\\z");
    const upper = try P.compile("\\Aabc\\Z");
    const upper_after_cr = try P.compile("\\Aabc\\r\\Z");
    const end_after_a = try P.compile("a\\z");
    const line_end_after_a = try P.compile("a\\Z");
    const start_after_a = try P.compile("a\\A");
    const search_start_after_a = try P.compile("a\\G");
    var scratch = @import("scratch.zig").VmScratch(64).init();
    var captures = [_]Capture{.{}} ** max_captures;

    try std.testing.expectEqual(@as(usize, 3), (try lower.find("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try lower.find("abc\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try upper.find("abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try upper.find("abc\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try upper.find("abc\r\n", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try upper.find("abc\x85", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try upper.find("abc\xe2\x80\xa8", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try upper_after_cr.find("abc\r\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try upper.find("abc\n\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try end_after_a.find("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try end_after_a.find("a\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try line_end_after_a.find("a\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try start_after_a.find("a", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try search_start_after_a.find("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try search_start_after_a.matchAtCapturesSearchStart("a", 0, 1, &scratch, &captures)).?.end);
}

test "regex VM handles Oniguruma absent expressions" {
    const P = Program(64);
    const absent_repeater = try P.compile("(?~345)");
    const absent_digits = try P.compile("(?~|345|\\d*)");
    const absent_then_suffix = try P.compile("a(?~|end|\\O*)end");
    const absent_repeater_then_suffix = try P.compile("a(?~end)end");
    const absent_alt = try P.compile("(?~|345|[a-z]+|\\d*)");
    const absent_stopper = try P.compile("(?~|345)\\O*");
    const absent_stopper_blocks_suffix = try P.compile("a(?~|end)\\O*end");
    const absent_range_clear = try P.compile("(?~|345)\\O*(?~|)345");
    const absent_end = try P.compile("(?~|end|\\O*\\z)end");
    const absent_line_end = try P.compile("(?~|end|\\O*$)end");
    const absent_final_linebreak_end = try P.compile("(?~|\nend|\\O*\\Z)\nend");
    var scratch = @import("scratch.zig").VmScratch(128).init();

    try std.testing.expectEqual(@as(usize, 2), (try absent_repeater.matchAt("12345678", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 0), (try absent_repeater.matchAt("345", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try absent_repeater.matchAt("123", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try absent_digits.matchAt("12345678", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 0), (try absent_digits.matchAt("345", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try absent_digits.matchAt("123", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try absent_then_suffix.matchAt("abcend", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try absent_repeater_then_suffix.matchAt("abcend", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try absent_alt.matchAt("abc345", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try absent_stopper.matchAt("123345", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try absent_stopper_blocks_suffix.matchAt("abcend", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 6), (try absent_range_clear.matchAt("123345", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try absent_end.matchAt("abcend", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try absent_line_end.matchAt("abcend", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 7), (try absent_final_linebreak_end.matchAt("abc\nend", 0, &scratch)).?.end);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?~)"));
}

test "regex VM routes absent expressions outside fast compiler" {
    const Fast = @import("parser.zig").Program(32);
    const Vm = Program(32);

    try std.testing.expectError(error.UnsupportedRegex, Fast.compile("(?~345)"));
    try std.testing.expectError(error.UnsupportedRegex, Fast.compile("(?~|345|\\d*)"));
    try std.testing.expectError(error.UnsupportedRegex, Fast.compile("(?~|345)"));
    try std.testing.expectError(error.UnsupportedRegex, Fast.compile("(?~|)"));
    _ = try Vm.compile("(?~345)");
    _ = try Vm.compile("(?~|345|\\d*)");
    _ = try Vm.compile("(?~|345)");
    _ = try Vm.compile("(?~|)");
}

test "regex VM handles Unicode property aliases" {
    const P = Program(64);
    const upper = try P.compile("\\p{upper}+");
    const alnum = try P.compile("\\p{alnum}+");
    const alpha = try P.compile("\\p{Alpha}+");
    const xdigit = try P.compile("\\p{XDigit}+");
    const ascii = try P.compile("\\p{ASCII}+");
    const any = try P.compile("\\p{Any}+");
    const assigned = try P.compile("[\\p{Assigned}]+");
    const not_any = try P.compile("\\P{Any}+");
    const control = try P.compile("\\p{Cc}+");
    const control_name = try P.compile("[\\p{Control}]+");
    const separator = try P.compile("\\p{Zs}+");
    const separator_name = try P.compile("[\\p{Space_Separator}]+");
    const connector = try P.compile("\\p{Connector_Punctuation}+");
    const upper_posix = try P.compile("[[:Alpha:][:XDigit:]]+");
    const class = try P.compile("[\\p{upper}\\p{Nd}_]+");
    const inverse_class = try P.compile("[\\P{upper}]+");
    const inverse_ascii = try P.compile("\\P{ASCII}+");
    const inverse_prefix = try P.compile("\\p{^Alpha}+");
    const double_inverse = try P.compile("\\P{^Alpha}+");
    const short_categories = try P.compile("[\\pL\\pN\\pP\\pS\\pZ\\pC]+");
    const short_inverse = try P.compile("\\PL+");
    const gc_upper = try P.compile("\\p{gc=Lu}+");
    const loose_lower = try P.compile("\\p{General_Category=lowercase-letter}+");
    const loose_decimal = try P.compile("[\\p{General Category=decimal number}]+");
    const script_latin = try P.compile("\\p{Script=Latin}+");
    const script_han = try P.compile("[\\p{sc=Hani}]+");
    const alphabetic = try P.compile("[\\p{Alphabetic}\\p{N}]+");
    const cased_letter = try P.compile("[\\p{LC}\\p{Cased_Letter}]+");
    const letter_subcategories = try P.compile("[\\p{Lt}\\p{Lm}\\p{Lo}]+");
    const unicode_identifier = try P.compile("[\\p{L}_][\\p{L}\\p{N}\\p{M}]*");
    const mark = try P.compile("\\p{M}+");
    const unicode_number = try P.compile("\\p{N}+");
    const unicode_connector = try P.compile("\\p{Pc}+");
    const inverse_letter_class = try P.compile("[\\P{L}]+");
    const greek = try P.compile("\\p{Greek}+");
    const greek_prompt = try P.compile("[#$%>❯➜\\p{Greek}]+");
    const symbols = try P.compile("[\\p{Sm}\\p{So}]+");
    const word_property = try P.compile("\\p{Word}+");
    const inverse_word_property = try P.compile("\\P{Word}+");
    const class_word_property = try P.compile("[\\p{Word}]+");
    const class_inverse_word_property = try P.compile("[\\P{Word}]+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 3), (try upper.matchAt("ABCd", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try alnum.matchAt("A1!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try alpha.matchAt("AbC1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try xdigit.matchAt("0fAFz", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try ascii.matchAt("Az\x7f\x80", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try any.matchAt("\x00A\xff", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try assigned.matchAt("\x00A\xff", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try not_any.matchAt("x", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try control.matchAt("\x00\x1f\x7f ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try control_name.matchAt("\x00\x1f\x7f ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try separator.matchAt("  \t", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try separator_name.matchAt("  \t", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try connector.matchAt("_-", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try upper_posix.matchAt("AZf0!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try class.matchAt("A1_Z", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class.matchAt("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try inverse_class.matchAt("a1A", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try inverse_ascii.matchAt("\x80A", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try inverse_prefix.matchAt("12a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try double_inverse.matchAt("AbC1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 7), (try short_categories.matchAt("A1!$ \x01_", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try short_inverse.matchAt("12a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try gc_upper.matchAt("ABCd", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try loose_lower.matchAt("abcD", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try loose_decimal.matchAt("123a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try script_latin.matchAt("éA!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try script_han.matchAt("漢A", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try alphabetic.matchAt("Ab12!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try cased_letter.matchAt("Aǅé1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 7), (try letter_subcategories.matchAt("ǅʰ漢A", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 7), (try unicode_identifier.matchAt("éclair", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try unicode_identifier.matchAt("á1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try mark.matchAt("́x", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try unicode_number.matchAt("١x", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try unicode_connector.matchAt("‿x", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try inverse_letter_class.matchAt("1é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try inverse_letter_class.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try greek.matchAt("αβx", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try greek.matchAt("ab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 5), (try greek_prompt.matchAt("α❯x", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try symbols.matchAt("≤☃x", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try word_property.matchAt("é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try inverse_word_property.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try inverse_word_property.matchAt("!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class_word_property.matchAt("é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_inverse_word_property.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try class_inverse_word_property.matchAt("!", 0, &scratch)).?.end);
}

test "regex VM keeps simple repeats off capture snapshot stack" {
    const P = Program(128);
    const xml_processing_instruction = try P.compile("<\\?[A-Za-z_][A-Za-z0-9_.-]*");
    const xml_tag = try P.compile("</?[A-Za-z_][A-Za-z0-9_.:-]*");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 5), (try xml_processing_instruction.matchAt("<?xml version=\"1.0\"?>", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try xml_tag.matchAt("</root>", 0, &scratch)).?.end);
}

test "regex VM handles Oniguruma control escapes" {
    const P = Program(32);
    const c_style = try P.compile("\\n\\t\\r");
    const c_style_class = try P.compile("[\\n\\t\\r]+");
    const controls = try P.compile("\\a[\\b]\\e\\f\\v");
    const control_letters = try P.compile("\\cA[\\cB]");
    const control_dash = try P.compile("\\C-C[\\C-D]");
    const meta = try P.compile("\\M-a[\\M-b]");
    const meta_control = try P.compile("\\M-\\C-c[\\M-\\C-d]");
    const whitespace = try P.compile("\\s+");
    const class_whitespace = try P.compile("[\\s]+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 3), (try c_style.matchAt("\n\t\r", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try c_style_class.matchAt("\n\t\r ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try controls.matchAt("\x07\x08\x1b\x0c\x0b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try control_letters.matchAt("\x01\x02", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try control_dash.matchAt("\x03\x04", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try meta.matchAt("\xe1\xe2", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try meta_control.matchAt("\x83\x84", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try whitespace.matchAt("\x0b\x0c", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class_whitespace.matchAt("\x0b\x0c", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try whitespace.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try class_whitespace.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try whitespace.matchAt("\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try whitespace.matchAt("\xe2\x80\xa9", 0, &scratch)).?.end);
}

test "regex VM handles Oniguruma hex byte escapes" {
    const P = Program(32);
    const literal = try P.compile("\\x41\\x{42}");
    const class = try P.compile("[\\x00-\\x08]+");
    const octal = try P.compile("\\010[\\011]\\0");
    const octal_class = try P.compile("[\\010-\\011]+");
    const codepoint = try P.compile("\\o{101}[\\u0042]");
    const codepoint_class = try P.compile("[\\o{100}-\\u0042]+");
    const hex_sequence = try P.compile("\\x{41 42}\\x{1f600}");
    const octal_sequence = try P.compile("\\o{101 102}");
    const sequence_repeat = try P.compile("\\x{41 42}{2}");
    const sequence_ignore_case = try P.compile("(?i:\\x{41 42})");
    const wide = try P.compile("\\x{200C}\\u2028");
    const wide_octal = try P.compile("\\o{20015}");
    const wide_class = try P.compile("[\\x{200C}\\x{200D}_]+");
    const not_wide_class = try P.compile("[^\\x{200C}a]+");
    const not_newline_class = try P.compile("[^\\n]+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 2), (try literal.matchAt("AB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class.matchAt("\x00\x08\t", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class.matchAt("\t", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try octal.matchAt("\x08\t\x00", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try octal_class.matchAt("\x08\t\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try codepoint.matchAt("AB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try codepoint_class.matchAt("@ABc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try hex_sequence.matchAt("AB\xf0\x9f\x98\x80", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try octal_sequence.matchAt("AB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try sequence_repeat.matchAt("ABAB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try sequence_ignore_case.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try wide.matchAt("\xe2\x80\x8c\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try wide_octal.matchAt("\xe2\x80\x8d", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 7), (try wide_class.matchAt("_\xe2\x80\x8c\xe2\x80\x8d", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try not_wide_class.matchAt("\xe2\x80\x8db", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try not_wide_class.matchAt("\xe2\x80\x8c", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try not_wide_class.matchAt("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 3), (try not_newline_class.matchAt("éx\n", 0, &scratch)).?.end);
}

test "regex VM handles broader POSIX bracket classes" {
    const P = Program(64);
    const ascii = try P.compile("[[:ascii:]]+");
    const blank = try P.compile("[[:blank:]]+");
    const cntrl = try P.compile("[[:cntrl:]]+");
    const graph = try P.compile("[[:graph:]]+");
    const lower = try P.compile("[[:lower:]]+");
    const print = try P.compile("[[:print:]]+");
    const punct = try P.compile("[[:punct:]]+");
    const space = try P.compile("[[:space:]]+");
    const word = try P.compile("[[:word:]]+");
    const inverse_word = try P.compile("[[:^word:]]+");
    const outer_not_word = try P.compile("[^[:word:]]+");
    const non_alpha = try P.compile("[[:^alpha:]]+");
    const outer_negated = try P.compile("[^[:^digit:]]+");
    const mixed_case = try P.compile("[[:Alpha:]]+");
    const intersection = try P.compile("[a-w&&[^c-g]z]+");
    const nested = try P.compile("[[a-c][x-z]]+");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 3), (try ascii.matchAt("\x00A\x7f\x80", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try blank.matchAt(" \t\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try cntrl.matchAt("\x00\x1f\x7f ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try graph.find(" !~\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try graph.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try lower.matchAt("abcD", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try print.matchAt(" !~\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try print.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try punct.find("a!/@[~z", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try space.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try word.matchAt("a1_-", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try word.matchAt("é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try inverse_word.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try outer_not_word.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try inverse_word.matchAt("!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try outer_not_word.matchAt("!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try non_alpha.matchAt("123abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try outer_negated.matchAt("123abc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try mixed_case.matchAt("AbC1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try intersection.find("cdabhwz", 0, &scratch)).?.start);
    try std.testing.expectEqual(@as(usize, 6), (try intersection.find("cdabhwz", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try nested.matchAt("abcxyzm", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try nested.matchAt("m", 0, &scratch));
}

test "regex VM handles Oniguruma ASCII space option" {
    const P = Program(64);
    const unicode_space = try P.compile("\\s+");
    const ascii_escape = try P.compile("(?S:\\s+)");
    const ascii_inverse = try P.compile("(?S:\\S+)");
    const ascii_posix = try P.compile("(?S:[[:space:]]+)");
    const ascii_posix_inverse = try P.compile("(?S:[[:^space:]]+)");
    const ascii_property = try P.compile("(?S:\\p{Space}+)");
    const ascii_property_inverse = try P.compile("(?S:\\P{Space}+)");
    const ascii_posix_flag = try P.compile("(?P:\\s+)");
    var scratch = @import("scratch.zig").VmScratch(64).init();

    try std.testing.expectEqual(@as(usize, 1), (try unicode_space.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try unicode_space.matchAt("\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try ascii_escape.matchAt("\x85", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try ascii_escape.matchAt("\xe2\x80\xa8", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try ascii_escape.matchAt(" \t\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try ascii_inverse.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try ascii_inverse.matchAt(" ", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try ascii_posix.matchAt("\x85", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try ascii_posix_inverse.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try ascii_property.matchAt("\x85", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try ascii_property_inverse.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try ascii_posix_flag.matchAt("\x85", 0, &scratch));
}

test "regex VM treats escaped quote markers as literals" {
    const P = Program(32);
    const quote = try P.compile("\\Qliteral\\E");
    const class = try P.compile("[\\Q]");
    var scratch = @import("scratch.zig").VmScratch(16).init();

    _ = try P.compile("\\\\Q");
    try std.testing.expectEqual(@as(usize, 9), (try quote.matchAt("QliteralE", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try class.matchAt("Q", 0, &scratch)).?.end);
}

test "regex VM runs table-driven Oniguruma conformance cases" {
    const P = Program(128);
    const Case = struct {
        pattern: []const u8,
        text: []const u8,
        start: usize = 0,
        want_start: ?usize = 0,
        want_end: ?usize,
        want_capture_slot: u8 = 0,
        want_capture_start: ?usize = null,
        want_capture_end: ?usize = null,
    };
    const cases = [_]Case{
        .{ .pattern = "\\A(?:foo|bar)\\z", .text = "bar", .want_end = 3 },
        .{ .pattern = "\\Qliteral\\E", .text = "QliteralE", .want_end = 9 },
        .{ .pattern = "\\Qa.b*\\E", .text = "QaZbbbbE", .want_end = 8 },
        .{ .pattern = "\\Qa.b*\\E", .text = "Qa.b*E", .want_start = null, .want_end = null },
        .{ .pattern = "\\Q[abc]\\E", .text = "QaE", .want_end = 3 },
        .{ .pattern = "\\Q[abc]\\E", .text = "QbE", .want_end = 3 },
        .{ .pattern = "\\Q[abc]\\E", .text = "QdE", .want_start = null, .want_end = null },
        .{ .pattern = "\\Q(a|b)\\E", .text = "QaE", .want_end = 3 },
        .{ .pattern = "\\Q(a|b)\\E", .text = "QbE", .want_end = 3 },
        .{ .pattern = "\\E", .text = "E", .want_end = 1 },
        .{ .pattern = "[\\Q]", .text = "Q", .want_end = 1 },
        .{ .pattern = "[\\E]", .text = "E", .want_end = 1 },
        .{ .pattern = "\\Aabc\\Z", .text = "abc\n", .want_end = 3 },
        .{ .pattern = "\\Aabc", .text = "abc", .want_end = 3 },
        .{ .pattern = "\\Aabc", .text = "x\nabc", .start = 2, .want_start = null, .want_end = null },
        .{ .pattern = "abc\\z", .text = "abc", .want_end = 3 },
        .{ .pattern = "abc\\z", .text = "abc\n", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\Z", .text = "abc\n", .want_end = 3 },
        .{ .pattern = "abc\\Z", .text = "abc\r", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\Z", .text = "abc\r\n", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\Z", .text = "abc\x85", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\Z", .text = "abc\xe2\x80\xa8", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\r\\Z", .text = "abc\r\n", .want_end = 4 },
        .{ .pattern = "\\Gabc", .text = "abc", .want_end = 3 },
        .{ .pattern = "\\Gabc", .text = "xabc", .want_start = null, .want_end = null },
        .{ .pattern = "\\Gabc", .text = "xabc", .start = 1, .want_start = 1, .want_end = 4 },
        .{ .pattern = "a\\Gb", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "a\\Ab", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "abc$", .text = "abc\r", .want_start = null, .want_end = null },
        .{ .pattern = "abc$", .text = "abc\r\n", .want_start = null, .want_end = null },
        .{ .pattern = "abc$", .text = "abc\xe2\x80\xa8", .want_start = null, .want_end = null },
        .{ .pattern = "abc\\r$", .text = "abc\r\n", .want_end = 4 },
        .{ .pattern = "\\A(?:a|ab)", .text = "ab", .want_end = 1 },
        .{ .pattern = "(?:a|ab)\\z", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?=a)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?!b)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?<=a)b", .text = "ab", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<!b)a", .text = "a", .want_end = 1 },
        .{ .pattern = "a(?:b)?", .text = "a", .want_end = 1 },
        .{ .pattern = "a(?:b)??b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?:|a)b", .text = "b", .want_end = 1 },
        .{ .pattern = "(?:|a)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "a(?:|b)c", .text = "ac", .want_end = 2 },
        .{ .pattern = "a(?:|b)c", .text = "abc", .want_end = 3 },
        .{ .pattern = "(?:(a)|)b", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(?:(a)|)b", .text = "ab", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?:a|ab)?b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?:ab|a)?b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?m:.)", .text = "\n", .want_end = 1 },
        .{ .pattern = "(?m:a.)", .text = "a\n", .want_end = 2 },
        .{ .pattern = "(?x)a # comment\n b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?#c)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?i:a)(?-i:b)", .text = "Ab", .want_end = 2 },
        .{ .pattern = "(?i:abc)", .text = "ABC", .want_end = 3 },
        .{ .pattern = "(?i)ab", .text = "AB", .want_end = 2 },
        .{ .pattern = "(?i)a(?-i)b", .text = "Ab", .want_end = 2 },
        .{ .pattern = "(?i)a(?-i)b", .text = "AB", .want_start = null, .want_end = null },
        .{ .pattern = "(?i:a)(?-i)b", .text = "Ab", .want_end = 2 },
        .{ .pattern = "(?i:a)(?-i)b", .text = "AB", .want_start = null, .want_end = null },
        .{ .pattern = "(?i)(?-i:a)", .text = "a", .want_end = 1 },
        .{ .pattern = "(?i)(?-i:a)", .text = "A", .want_start = null, .want_end = null },
        .{ .pattern = "(?x)% (\\d+)? # field\n [s]", .text = "%42s", .want_end = 4 },
        .{ .pattern = "(?x)a\\ b", .text = "a b", .want_end = 3 },
        .{ .pattern = "(?x)a\\#b", .text = "a#b", .want_end = 3 },
        .{ .pattern = "(?x)(?-x:a b)", .text = "a b", .want_end = 3 },
        .{ .pattern = "(?x)(?-x:a b)", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "(?:(?x)a b|c d)", .text = "cd", .want_end = 2 },
        .{ .pattern = "(?x)(a # fake (?q) extension\n)", .text = "a", .want_end = 1 },
        .{ .pattern = "(?x)(a # fake ) closer\n)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?x)(a # fake |\n|b)c", .text = "ac", .want_end = 2 },
        .{ .pattern = "(?x)(a # fake |\n|b)c", .text = "bc", .want_end = 2 },
        .{ .pattern = "(?x)(?-x:#)", .text = "#", .want_end = 1 },
        .{ .pattern = "(?x)# (fake)\n(a)\\1", .text = "aa", .want_end = 2 },
        .{ .pattern = "(?x)# (fake)\n(a)\\g<1>", .text = "aa", .want_end = 2 },
        .{ .pattern = "(?x)# (fake)\n(a)?(?(1)yes|no)", .text = "ayes", .want_end = 4 },
        .{ .pattern = "(?WDS)y", .text = "y", .want_end = 1 },
        .{ .pattern = "(?y{g}:abc)", .text = "abc", .want_end = 3 },
        .{ .pattern = "(?y{g})abc", .text = "abc", .want_end = 3 },
        .{ .pattern = "(?y{w}:abc)", .text = "abc", .want_end = 3 },
        .{ .pattern = "(?y{w})abc", .text = "abc", .want_end = 3 },
        .{ .pattern = "a(?# ignored ( | )b|ac", .text = "ab", .want_end = 2 },
        .{ .pattern = "a(?# ignored ( | )b|ac", .text = "ac", .want_end = 2 },
        .{ .pattern = "(?# fake ( group )(a)\\1", .text = "aa", .want_end = 2 },
        .{ .pattern = "(a)?(?(1)(?# ignored | )yes|no)", .text = "ayes", .want_end = 4 },
        .{ .pattern = "(?(name)yes|no)", .text = "no", .want_end = 2 },
        .{ .pattern = "(['\"]).*?\\1", .text = "\"x\"", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<word>ab)(?<word>a)?\\k<word>", .text = "abaa", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(?'word'ab)\\k'word'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(ab)\\k<1>", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(ab)\\k'1'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?<word>ab)\\k<word+0>", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?'word'ab)\\k'word-0'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(ab)\\k<1+0>", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(ab)\\k'1+0'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(a)(b)\\k<-1>\\k<-2>", .text = "abba", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(a)(b)\\k<-1+0>\\k<-2+0>", .text = "abba", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(?i)(ab)\\1", .text = "abAB", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?i)(?<word>ab)\\k<word>", .text = "abAB", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(a)?b", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(a)|(b)", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(a)|(b)", .text = "b", .want_end = 1, .want_capture_slot = 2, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a(b))?c", .text = "c", .want_end = 1, .want_capture_slot = 2 },
        .{ .pattern = "(?<x>a)?b", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(?:(a)|b)\\1?", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(a)?\\1?", .text = "", .want_end = 0, .want_capture_slot = 1 },
        .{ .pattern = "(?=(a))\\1", .text = "a", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?!(a))b", .text = "b", .want_end = 1, .want_capture_slot = 1 },
        .{ .pattern = "(?=(ab|a)b)\\1b", .text = "ab", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)+", .text = "aaa", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(a(b)?)+", .text = "aba", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(a(b)?)+", .text = "aba", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "((a)|b)+", .text = "bb", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "((a)|b)+", .text = "bb", .want_end = 2, .want_capture_slot = 2 },
        .{ .pattern = "(a(b)|ac)+", .text = "acab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "(a(b)|ac)+", .text = "acab", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 3, .want_capture_end = 4 },
        .{ .pattern = "(a(b)?)+\\2", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(a(b)?)+\\2", .text = "abab", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "((a)?b)+", .text = "abb", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "((a)?b)+", .text = "abb", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a|(b))+", .text = "aa", .want_end = 2, .want_capture_slot = 2 },
        .{ .pattern = "(?:(a)|(b)|(c))+", .text = "abc", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?:(a)|(b)|(c))+", .text = "abc", .want_end = 3, .want_capture_slot = 3, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(?:(a)|(b)|(c))+", .text = "ccc", .want_end = 3, .want_capture_slot = 1 },
        .{ .pattern = "((ab)|a)+b", .text = "aab", .want_end = 3, .want_capture_slot = 2 },
        .{ .pattern = "((a)b|a)+", .text = "aba", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(1)yes|no)", .text = "no", .want_end = 2, .want_capture_slot = 1 },
        .{ .pattern = "(a)?(?(1)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<x>a)?(?(<x>)yes|no)", .text = "no", .want_end = 2, .want_capture_slot = 1 },
        .{ .pattern = "(?'word'a)?(?('word')yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?'word'a)?(?('word')yes|no)", .text = "no", .want_end = 2, .want_capture_slot = 1 },
        .{ .pattern = "(a)?(?('1')yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?('1')yes|no)", .text = "no", .want_end = 2, .want_capture_slot = 1 },
        .{ .pattern = "(a)?(?(<1>)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<word>a)?(?(<word+0>)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(<1+0>)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(1))b", .text = "ab", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(1))b", .text = "b", .want_start = null, .want_end = null },
        .{ .pattern = "(?<a>x)(?(<a>))y", .text = "xy", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<a>x)?(?(<a>))y", .text = "y", .want_start = null, .want_end = null },
        .{ .pattern = "(a)?(?(1)yes)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(1)yes)", .text = "no", .want_end = 0 },
        .{ .pattern = "(?<x>a)?(?(<x>)yes)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<x>a)?(?(<x>)yes)", .text = "no", .want_end = 0 },
        .{ .pattern = "(?'x'a)?(?('x')yes)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?'x'a)?(?('x')yes)", .text = "no", .want_end = 0 },
        .{ .pattern = "(a)?(?(-1)yes)", .text = "no", .want_end = 0 },
        .{ .pattern = "(a)(?(+1)c)(b)", .text = "ab", .want_end = 2, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(a)(?(+1)c)(b)", .text = "acb", .want_start = null, .want_end = null },
        .{ .pattern = "(a)(?(+1)b|c)(b)", .text = "acb", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(a)(?(+1)b|c)(b)", .text = "abb", .want_start = null, .want_end = null },
        .{ .pattern = "(a)?(?(-1)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?(<-1>)yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?('-1')yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)?(?('-1')yes|no)", .text = "no", .want_end = 2, .want_capture_slot = 1 },
        .{ .pattern = "(a)?(?('1+0')yes|no)", .text = "ayes", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?(?=a)yes|no)", .text = "no", .want_end = 2 },
        .{ .pattern = "(a)(?(-1)b|c)", .text = "ab", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a)(?(-1)b|c)", .text = "ac", .want_start = null, .want_end = null },
        .{ .pattern = "(?<=a+)b", .text = "aaab", .start = 3, .want_start = 3, .want_end = 4 },
        .{ .pattern = "(?<!a+)b", .text = "b", .want_end = 1 },
        .{ .pattern = "(?<!a+)b", .text = "ab", .start = 1, .want_start = null, .want_end = null },
        .{ .pattern = "(?<=ab)c", .text = "abc", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<!ab)c", .text = "xxc", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<!ab)c", .text = "abc", .start = 2, .want_start = null, .want_end = null },
        .{ .pattern = "(?(?<=a)b|c)", .text = "ab", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?(?<!a)b|c)", .text = "cb", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<x>a)\\g<x>", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(a)\\g<1>", .text = "aa", .want_end = 2 },
        .{ .pattern = "(?'word'ab)\\g'word'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "(ab)\\g'1'", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "\\g<+1>(ab)", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "\\g'+1'(ab)", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "(?-i:\\g<word>)(?i:(?<word>a)){0}", .text = "A", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?<path>[A-Z]+){0}\\g<path>", .text = "PATH", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 4 },
        .{ .pattern = "(?<path>[A-Z]+){0}\"\\g<path>\"", .text = "\"PATH\"", .want_end = 6, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 5 },
        .{ .pattern = "(?<type-name>a)\\g<type-name>", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(?'type-name'a)\\g'type-name'", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(?<type.name>a)\\g<type.name>", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(?'type.name'a)\\g'type.name'", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "a\\g<0>?", .text = "aaa", .want_end = 3 },
        .{ .pattern = "a\\g'0'?", .text = "aaa", .want_end = 3 },
        .{ .pattern = "(?<x>a)(b)\\2", .text = "abb", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 1, .want_capture_end = 2 },
        .{ .pattern = "(?<x>a)(b)\\g<2>", .text = "abb", .want_end = 3, .want_capture_slot = 2, .want_capture_start = 2, .want_capture_end = 3 },
        .{ .pattern = "(?<x>ab)\\k<x>", .text = "abab", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?<=(a))b\\1", .text = "aba", .start = 1, .want_start = 1, .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(α)(β)", .text = "αβ", .want_end = 4, .want_capture_slot = 2, .want_capture_start = 2, .want_capture_end = 4 },
        .{ .pattern = "(?<g>α)\\k<g>", .text = "αα", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(é)?(?(1)α|β)", .text = "éα", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(é)?(?(1)α|β)", .text = "β", .want_end = 2 },
        .{ .pattern = "(?<=α)β", .text = "αβ", .start = 2, .want_start = 2, .want_end = 4 },
        .{ .pattern = "(?i)é", .text = "É", .want_end = 2 },
        .{ .pattern = "(?i)É", .text = "é", .want_end = 2 },
        .{ .pattern = "(?i)α", .text = "Α", .want_end = 2 },
        .{ .pattern = "(?i)ж", .text = "Ж", .want_end = 2 },
        .{ .pattern = "(?i)k", .text = "K", .want_end = 3 },
        .{ .pattern = "(?i)å", .text = "Å", .want_end = 3 },
        .{ .pattern = "(?i)ω", .text = "Ω", .want_end = 3 },
        .{ .pattern = "(?i)[é]", .text = "É", .want_end = 2 },
        .{ .pattern = "(?i)[α]", .text = "Α", .want_end = 2 },
        .{ .pattern = "(?i)[K]", .text = "k", .want_end = 1 },
        .{ .pattern = "(?i)[Å]", .text = "å", .want_end = 2 },
        .{ .pattern = "(?i)[Ω]", .text = "ω", .want_end = 2 },
        .{ .pattern = "\\h+", .text = "09AfG", .want_end = 4 },
        .{ .pattern = "\\H+", .text = "Gz9", .want_end = 2 },
        .{ .pattern = "\\d+", .text = "123a", .want_end = 3 },
        .{ .pattern = "\\D+", .text = "abc1", .want_end = 3 },
        .{ .pattern = "[\\h]+", .text = "09AfG", .want_end = 4 },
        .{ .pattern = "[\\H]+", .text = "Gz9", .want_end = 2 },
        .{ .pattern = "\\w+", .text = "A_1!", .want_end = 3 },
        .{ .pattern = "\\W+", .text = "!-A", .want_end = 2 },
        .{ .pattern = "[\\w]+", .text = "A_1!", .want_end = 3 },
        .{ .pattern = "[\\W]+", .text = "!-A", .want_end = 2 },
        .{ .pattern = "\\w+", .text = "é!", .want_end = 2 },
        .{ .pattern = "\\W+", .text = "!é", .want_end = 1 },
        .{ .pattern = "\\s+", .text = " \tA", .want_end = 2 },
        .{ .pattern = "\\S+", .text = "abc ", .want_end = 3 },
        .{ .pattern = "[\\s]+", .text = " \tA", .want_end = 2 },
        .{ .pattern = "[\\S]+", .text = "abc ", .want_end = 3 },
        .{ .pattern = "(?i)(é)\\1", .text = "éÉ", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?i)(α)\\1", .text = "αΑ", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(?i)ς", .text = "Σ", .want_end = 2 },
        .{ .pattern = "a(?~|end|\\O*)end", .text = "abcend", .want_end = 6 },
        .{ .pattern = "(?~345)", .text = "12345678", .want_end = 2 },
        .{ .pattern = "\\R", .text = "\r\n", .want_end = 2 },
        .{ .pattern = "\\R", .text = "\n", .want_end = 1 },
        .{ .pattern = "\\R", .text = "\r", .want_end = 1 },
        .{ .pattern = "\\R", .text = "\x0b", .want_end = 1 },
        .{ .pattern = "\\R", .text = "\x0c", .want_end = 1 },
        .{ .pattern = "\\R", .text = "\x85", .want_end = 1 },
        .{ .pattern = "\\R", .text = "\u{2028}", .want_end = 3 },
        .{ .pattern = "\\R", .text = "\u{2029}", .want_end = 3 },
        .{ .pattern = "\\R", .text = "x", .want_start = null, .want_end = null },
        .{ .pattern = "a\\Rb", .text = "a\r\nb", .want_end = 4 },
        .{ .pattern = "\\N+", .text = "ab\n", .want_end = 2 },
        .{ .pattern = "\\O+", .text = "a\n", .want_end = 2 },
        .{ .pattern = "\\X", .text = "\r\n", .want_end = 2 },
        .{ .pattern = "\\X", .text = "á", .want_end = 3 },
        .{ .pattern = "\\X", .text = "🇬🇧", .want_end = 8 },
        .{ .pattern = "\\X", .text = "👨‍👩‍👧‍👦", .want_end = 25 },
        .{ .pattern = "\\X", .text = "का", .want_end = 6 },
        .{ .pattern = "\\X", .text = "؀a", .want_end = 3 },
        .{ .pattern = "\\X", .text = "각", .want_end = 9 },
        .{ .pattern = "\\X", .text = "각", .want_end = 6 },
        .{ .pattern = "\\X", .text = "1️⃣", .want_end = 7 },
        .{ .pattern = "\\X", .text = "a‍b", .want_end = 4 },
        .{ .pattern = "\\X", .text = "क्‍ष", .want_end = 9 },
        .{ .pattern = "\\X", .text = "👩‍💻", .want_end = 11 },
        .{ .pattern = "\\X", .text = "🏴󠁧󠁢󠁥󠁮󠁧󠁿", .want_end = 28 },
        .{ .pattern = "\\X", .text = "👨🏽‍💻x", .want_end = 15 },
        .{ .pattern = "\\X", .text = "👨🏽‍❤️‍💋‍👨🏿x", .want_end = 35 },
        .{ .pattern = "\\X", .text = "🏳️‍🌈x", .want_end = 14 },
        .{ .pattern = "\\X", .text = "#️⃣x", .want_end = 7 },
        .{ .pattern = "\\X", .text = "*️⃣x", .want_end = 7 },
        .{ .pattern = "\\y\\X\\y", .text = "a", .want_end = 1 },
        .{ .pattern = "\\y\\X\\y", .text = "á", .want_end = 3 },
        .{ .pattern = "\\Y", .text = "á", .start = 1, .want_start = 1, .want_end = 1 },
        .{ .pattern = "\\h+", .text = "09afG", .want_end = 4 },
        .{ .pattern = "\\H+", .text = "G!x", .want_end = 3 },
        .{ .pattern = "\\H+", .text = "éG", .want_end = 3 },
        .{ .pattern = "[\\h]+", .text = "09afG", .want_end = 4 },
        .{ .pattern = "[\\H]+", .text = "G!x", .want_end = 3 },
        .{ .pattern = "\\v+", .text = "\x0b\n", .want_end = 1 },
        .{ .pattern = "\\v+", .text = "\n", .want_start = null, .want_end = null },
        .{ .pattern = "[\\v]+", .text = "\x0b\n", .want_end = 1 },
        .{ .pattern = "[\\v]+", .text = "\n", .want_start = null, .want_end = null },
        .{ .pattern = "a\\Bb", .text = "ab", .want_end = 2 },
        .{ .pattern = "\\B", .text = "ab", .start = 1, .want_start = 1, .want_end = 1 },
        .{ .pattern = "\\b", .text = "ab", .want_end = 0 },
        .{ .pattern = "\\b", .text = "ab", .start = 2, .want_start = 2, .want_end = 2 },
        .{ .pattern = "\\b", .text = " a", .start = 1, .want_start = 1, .want_end = 1 },
        .{ .pattern = "\\b", .text = "é", .want_end = 0 },
        .{ .pattern = "\\b", .text = "é", .start = 2, .want_start = 2, .want_end = 2 },
        .{ .pattern = "(?W:\\b)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?W:\\B)", .text = "é", .want_end = 0 },
        .{ .pattern = "(?W:\\b)", .text = "a", .want_end = 0 },
        .{ .pattern = "^b", .text = "a\nb", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "b$", .text = "a\nb\n", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "\\A", .text = "abc", .want_end = 0 },
        .{ .pattern = "\\A", .text = "abc", .start = 1, .want_start = null, .want_end = null },
        .{ .pattern = "\\Z", .text = "abc", .start = 3, .want_start = 3, .want_end = 3 },
        .{ .pattern = "\\Z", .text = "abc\n", .start = 3, .want_start = 3, .want_end = 3 },
        .{ .pattern = "\\Z", .text = "abc\r\n", .start = 4, .want_start = 4, .want_end = 4 },
        .{ .pattern = "$", .text = "abc\r\n", .start = 4, .want_start = 4, .want_end = 4 },
        .{ .pattern = "\\z", .text = "abc", .start = 3, .want_start = 3, .want_end = 3 },
        .{ .pattern = "(?m:^b)", .text = "a\nb", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?i:a)(?-i:a)", .text = "Aa", .want_end = 2 },
        .{ .pattern = "(?i:a)(?-i:a)", .text = "AA", .want_start = null, .want_end = null },
        .{ .pattern = "(?i:[a-z]+)", .text = "ABC!", .want_end = 3 },
        .{ .pattern = ".", .text = "é", .want_end = 2 },
        .{ .pattern = ".", .text = "\n", .want_start = null, .want_end = null },
        .{ .pattern = ".", .text = "\r", .want_end = 1 },
        .{ .pattern = ".", .text = "\x85", .want_end = 1 },
        .{ .pattern = ".", .text = "\u{2028}", .want_end = 3 },
        .{ .pattern = "\\N", .text = "é", .want_end = 2 },
        .{ .pattern = "\\N", .text = "\n", .want_start = null, .want_end = null },
        .{ .pattern = "\\N", .text = "\r", .want_end = 1 },
        .{ .pattern = "\\N", .text = "\x85", .want_end = 1 },
        .{ .pattern = "\\N", .text = "\u{2029}", .want_end = 3 },
        .{ .pattern = "\\O", .text = "é", .want_end = 2 },
        .{ .pattern = "[^a]+", .text = "éa", .want_end = 2 },
        .{ .pattern = "\\a\\e\\f\\v", .text = "\x07\x1b\x0c\x0b", .want_end = 4 },
        .{ .pattern = "\\x41\\x{42}", .text = "AB", .want_end = 2 },
        .{ .pattern = "\\x{41 42}{2}", .text = "ABAB", .want_end = 4 },
        .{ .pattern = "\\o{101}", .text = "A", .want_end = 1 },
        .{ .pattern = "\\u0041", .text = "A", .want_end = 1 },
        .{ .pattern = "\\cA\\C-B", .text = "\x01\x02", .want_end = 2 },
        .{ .pattern = "\\C-C[\\C-D]", .text = "\x03\x04", .want_end = 2 },
        .{ .pattern = "\\M-a[\\M-b]", .text = "\xe1\xe2", .want_end = 2 },
        .{ .pattern = "\\M-\\C-c[\\M-\\C-d]", .text = "\x83\x84", .want_end = 2 },
        .{ .pattern = "[\\M-a]+", .text = "\xe1\xe1A", .want_end = 2 },
        .{ .pattern = "\\n\\t\\r", .text = "\n\t\r", .want_end = 3 },
        .{ .pattern = "a{,2}b", .text = "aab", .want_end = 3 },
        .{ .pattern = "a{2}?b", .text = "b", .want_end = 1 },
        .{ .pattern = "a{2,3}?a", .text = "aaa", .want_end = 3 },
        .{ .pattern = "a{65}", .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .want_end = 65 },
        .{ .pattern = "a{65}", .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .want_start = null, .want_end = null },
        .{ .pattern = "a{65,66}", .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", .want_end = 66 },
        .{ .pattern = "a{65}?a", .text = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .want_end = 66 },
        .{ .pattern = "a{2,3}+b", .text = "aaab", .want_end = 4 },
        .{ .pattern = "a{,2}+a", .text = "aa", .want_end = 2 },
        .{ .pattern = "a{2,3}+a", .text = "aaa", .want_end = 3 },
        .{ .pattern = "a{2,3}+a", .text = "aaaa", .want_end = 4 },
        .{ .pattern = "a{2,3}+b", .text = "aab", .want_end = 3 },
        .{ .pattern = "a{,2}+a", .text = "aaa", .want_end = 3 },
        .{ .pattern = "[a-w&&[^c-g]z]+", .text = "abhw", .want_end = 4 },
        .{ .pattern = "[[a-c][x-z]]+", .text = "abcxyzm", .want_end = 6 },
        .{ .pattern = "[[:^word:]]+", .text = "!", .want_end = 1 },
        .{ .pattern = "[[:^word:]]+", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "[^[:word:]]+", .text = "!", .want_end = 1 },
        .{ .pattern = "[[b-d]&&[^c]]+", .text = "bd", .want_end = 2 },
        .{ .pattern = "foo\\Kbar", .text = "foobar", .want_start = 3, .want_end = 6 },
        .{ .pattern = "a\\Kb", .text = "ab", .want_start = 1, .want_end = 2 },
        .{ .pattern = "(foo)\\Kbar", .text = "foobar", .want_start = 3, .want_end = 6, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 3 },
        .{ .pattern = "(?:foo|fo)\\Ko", .text = "foo", .want_start = 2, .want_end = 3 },
        .{ .pattern = "foo\\K(?=bar)bar", .text = "foobar", .want_start = 3, .want_end = 6 },
        .{ .pattern = "\\Gbar", .text = "foobar", .start = 3, .want_start = 3, .want_end = 6 },
        .{ .pattern = "(?>ab|a)b", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "(?>ab|a)b", .text = "abb", .want_end = 3 },
        .{ .pattern = "(?S:\\s+)", .text = "\x85", .want_start = null, .want_end = null },
        .{ .pattern = "(?S:\\S+)", .text = "\x85", .want_end = 1 },
        .{ .pattern = "(?S:\\s+)", .text = " ", .want_end = 1 },
        .{ .pattern = "\\d+", .text = "१२", .want_end = 6 },
        .{ .pattern = "(?D:\\d+)", .text = "१२", .want_start = null, .want_end = null },
        .{ .pattern = "\\D+", .text = "१", .want_start = null, .want_end = null },
        .{ .pattern = "(?D:\\D+)", .text = "१", .want_end = 3 },
        .{ .pattern = "\\b\\w+\\b", .text = "é", .want_end = 2 },
        .{ .pattern = "(?W:\\b\\w+\\b)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?W:\\w+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:\\w+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:\\s+)", .text = "\x85", .want_start = null, .want_end = null },
        .{ .pattern = "(?S:[[:space:]]+)", .text = "\x85", .want_start = null, .want_end = null },
        .{ .pattern = "(?S:[[:^space:]]+)", .text = "\x85", .want_end = 1 },
        .{ .pattern = "\\p{ASCII}+", .text = "AZ", .want_end = 2 },
        .{ .pattern = "\\p{Alpha}+", .text = "AZaz", .want_end = 4 },
        .{ .pattern = "\\p{XDigit}+", .text = "09Af", .want_end = 4 },
        .{ .pattern = "\\p{Word}+", .text = "a_1!", .want_end = 3 },
        .{ .pattern = "\\P{Word}+", .text = "!-a", .want_end = 2 },
        .{ .pattern = "\\p{Punct}+", .text = "!/@[~a", .want_end = 4 },
        .{ .pattern = "\\P{Punct}+", .text = "~`a!", .want_end = 3 },
        .{ .pattern = "\\p{Graph}+", .text = "!~\n", .want_end = 2 },
        .{ .pattern = "\\p{Print}+", .text = " !\n", .want_end = 2 },
        .{ .pattern = "\\p{Blank}+", .text = " \t\n", .want_end = 2 },
        .{ .pattern = "\\p{Cntrl}+", .text = "\x00\x1f\x7f ", .want_end = 3 },
        .{ .pattern = "\\p{Alnum}+", .text = "Az09_", .want_end = 4 },
        .{ .pattern = "\\P{ASCII}+", .text = "\x80A", .want_end = 1 },
        .{ .pattern = "\\p{Space}+", .text = " \t\nX", .want_end = 3 },
        .{ .pattern = "\\P{Space}+", .text = "abc ", .want_end = 3 },
        .{ .pattern = "\\p{Space}+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\p{White_Space}+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\p{Whitespace}+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\p{WhiteSpace}+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\p{Blank}+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\P{Space}+", .text = "A ", .want_end = 1 },
        .{ .pattern = "[\\p{White_Space}]+", .text = " A", .want_end = 2 },
        .{ .pattern = "\\p{Newline}+", .text = "\nA", .want_end = 1 },
        .{ .pattern = "\\P{Newline}+", .text = "A\n", .want_end = 1 },
        .{ .pattern = "[\\p{Newline}]+", .text = "\nA", .want_end = 1 },
        .{ .pattern = "[\\P{Newline}]+", .text = "A\n", .want_end = 1 },
        .{ .pattern = "(?S:\\p{Space}+)", .text = "\x85", .want_start = null, .want_end = null },
        .{ .pattern = "(?S:\\P{Space}+)", .text = "\x85", .want_end = 1 },
        .{ .pattern = "\\p{Alpha}+", .text = "é1", .want_end = 2 },
        .{ .pattern = "\\p{Alnum}+", .text = "é१!", .want_end = 5 },
        .{ .pattern = "(?P:\\p{Alpha}+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:\\p{Alnum}+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?D:\\p{Digit}+)", .text = "१", .want_start = null, .want_end = null },
        .{ .pattern = "(?W:\\p{Word}+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?D:[\\D]+)", .text = "१", .want_end = 3 },
        .{ .pattern = "(?W:[\\W]+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?S:[\\S]+)", .text = "\x85", .want_end = 1 },
        .{ .pattern = "(?P:[\\P{Alpha}]+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?P:\\P{Alnum}+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?D:\\P{Digit}+)", .text = "१", .want_end = 3 },
        .{ .pattern = "(?W:\\P{Word}+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?S:\\P{Space}+)", .text = "\x85", .want_end = 1 },
        .{ .pattern = "\\p{Greek}+", .text = "αβA", .want_end = 4 },
        .{ .pattern = "\\p{Greek}+", .text = "éα", .start = 2, .want_start = 2, .want_end = 4 },
        .{ .pattern = "\\P{Greek}+", .text = "Aβ", .want_end = 1 },
        .{ .pattern = "\\p{Word}+", .text = "é!", .want_end = 2 },
        .{ .pattern = "\\p{Latin}+", .text = "éЖ", .want_end = 2 },
        .{ .pattern = "\\p{Cyrillic}+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "\\p{Han}+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\p{Letter}+", .text = "éЖ漢1", .want_end = 7 },
        .{ .pattern = "\\p{Ll}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\p{Lu}+", .text = "Éa", .want_end = 2 },
        .{ .pattern = "\\p{Lower}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\p{Lowercase}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\p{Upper}+", .text = "Éa", .want_end = 2 },
        .{ .pattern = "\\p{Uppercase}+", .text = "Éa", .want_end = 2 },
        .{ .pattern = "\\p{Lo}+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\p{Lm}+", .text = "ʰA", .want_end = 2 },
        .{ .pattern = "\\p{Lt}+", .text = "ǅa", .want_end = 2 },
        .{ .pattern = "\\p{LC}+", .text = "Aaǅ1", .want_end = 4 },
        .{ .pattern = "\\p{Cased_Letter}+", .text = "ǅ1", .want_end = 2 },
        .{ .pattern = "\\P{LC}+", .text = "1A", .want_end = 1 },
        .{ .pattern = "\\P{Ll}+", .text = "Aé", .want_end = 1 },
        .{ .pattern = "[\\p{LC}]+", .text = "Aǅ1", .want_end = 3 },
        .{ .pattern = "[\\p{Ll}\\p{Lu}]+", .text = "éÉ1", .want_end = 4 },
        .{ .pattern = "\\p{Hiragana}+", .text = "あア", .want_end = 3 },
        .{ .pattern = "\\p{Katakana}+", .text = "アあ", .want_end = 3 },
        .{ .pattern = "\\p{Hebrew}+", .text = "אA", .want_end = 2 },
        .{ .pattern = "\\p{Arabic}+", .text = "شA", .want_end = 2 },
        .{ .pattern = "\\P{Latin}+", .text = "Жé", .want_end = 2 },
        .{ .pattern = "[\\p{Latin}]+", .text = "éЖ", .want_end = 2 },
        .{ .pattern = "[\\p{Cyrillic}]+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "[\\p{Han}]+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "[\\p{Hiragana}]+", .text = "あア", .want_end = 3 },
        .{ .pattern = "[\\p{Katakana}]+", .text = "アあ", .want_end = 3 },
        .{ .pattern = "[\\p{Hebrew}]+", .text = "אA", .want_end = 2 },
        .{ .pattern = "[\\p{Arabic}]+", .text = "شA", .want_end = 2 },
        .{ .pattern = "[\\P{Latin}]+", .text = "Жé", .want_end = 2 },
        .{ .pattern = "\\p{Latn}+", .text = "éЖ", .want_end = 2 },
        .{ .pattern = "\\p{Cyrl}+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "\\p{Hani}+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\p{Hira}+", .text = "あア", .want_end = 3 },
        .{ .pattern = "\\p{Kana}+", .text = "アあ", .want_end = 3 },
        .{ .pattern = "\\p{Hebr}+", .text = "אA", .want_end = 2 },
        .{ .pattern = "\\p{Arab}+", .text = "شA", .want_end = 2 },
        .{ .pattern = "\\p{Common}+", .text = "123A", .want_end = 3 },
        .{ .pattern = "\\p{Zyyy}+", .text = "€A", .want_end = 3 },
        .{ .pattern = "\\p{Inherited}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{Zinh}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\P{Common}+", .text = "A!", .want_end = 1 },
        .{ .pattern = "[\\p{Common}]+", .text = "!A", .want_end = 1 },
        .{ .pattern = "[\\p{Inherited}]+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{Devanagari}+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\p{Deva}+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\P{Devanagari}+", .text = "Aअ", .want_end = 1 },
        .{ .pattern = "[\\p{Devanagari}]+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\p{Thai}+", .text = "กA", .want_end = 3 },
        .{ .pattern = "\\p{Hangul}+", .text = "가A", .want_end = 3 },
        .{ .pattern = "\\p{Hang}+", .text = "가A", .want_end = 3 },
        .{ .pattern = "\\p{Bopomofo}+", .text = "ㄅA", .want_end = 3 },
        .{ .pattern = "\\p{Armenian}+", .text = "ԱA", .want_end = 2 },
        .{ .pattern = "\\p{Armn}+", .text = "ԱA", .want_end = 2 },
        .{ .pattern = "\\P{Armenian}+", .text = "AԱ", .want_end = 1 },
        .{ .pattern = "[\\p{Armenian}]+", .text = "ԱA", .want_end = 2 },
        .{ .pattern = "\\p{Georgian}+", .text = "აA", .want_end = 3 },
        .{ .pattern = "\\p{Geor}+", .text = "აA", .want_end = 3 },
        .{ .pattern = "\\P{Georgian}+", .text = "Aა", .want_end = 1 },
        .{ .pattern = "[\\p{Georgian}]+", .text = "აA", .want_end = 3 },
        .{ .pattern = "\\p{Runic}+", .text = "ᚠA", .want_end = 3 },
        .{ .pattern = "\\p{Ethi}+", .text = "ሀA", .want_end = 3 },
        .{ .pattern = "\\p{Khmer}+", .text = "កA", .want_end = 3 },
        .{ .pattern = "\\p{Khmr}+", .text = "កA", .want_end = 3 },
        .{ .pattern = "\\P{Khmer}+", .text = "Aក", .want_end = 1 },
        .{ .pattern = "[\\p{Khmer}]+", .text = "កA", .want_end = 3 },
        .{ .pattern = "\\p{Lao}+", .text = "ກA", .want_end = 3 },
        .{ .pattern = "\\p{Laoo}+", .text = "ກA", .want_end = 3 },
        .{ .pattern = "\\P{Lao}+", .text = "Aກ", .want_end = 1 },
        .{ .pattern = "[\\p{Lao}]+", .text = "ກA", .want_end = 3 },
        .{ .pattern = "\\p{Myanmar}+", .text = "ကA", .want_end = 3 },
        .{ .pattern = "\\p{Mymr}+", .text = "ကA", .want_end = 3 },
        .{ .pattern = "\\P{Myanmar}+", .text = "Aက", .want_end = 1 },
        .{ .pattern = "[\\p{Myanmar}]+", .text = "ကA", .want_end = 3 },
        .{ .pattern = "\\p{Sinhala}+", .text = "අA", .want_end = 3 },
        .{ .pattern = "\\p{Sinh}+", .text = "අA", .want_end = 3 },
        .{ .pattern = "\\P{Sinhala}+", .text = "Aඅ", .want_end = 1 },
        .{ .pattern = "[\\p{Sinhala}]+", .text = "අA", .want_end = 3 },
        .{ .pattern = "\\p{Tamil}+", .text = "அA", .want_end = 3 },
        .{ .pattern = "\\p{Taml}+", .text = "அA", .want_end = 3 },
        .{ .pattern = "\\P{Tamil}+", .text = "Aஅ", .want_end = 1 },
        .{ .pattern = "[\\p{Tamil}]+", .text = "அA", .want_end = 3 },
        .{ .pattern = "\\p{Telugu}+", .text = "అA", .want_end = 3 },
        .{ .pattern = "\\p{Telu}+", .text = "అA", .want_end = 3 },
        .{ .pattern = "\\P{Telugu}+", .text = "Aఅ", .want_end = 1 },
        .{ .pattern = "[\\p{Telugu}]+", .text = "అA", .want_end = 3 },
        .{ .pattern = "\\p{Kannada}+", .text = "ಅA", .want_end = 3 },
        .{ .pattern = "\\p{Knda}+", .text = "ಅA", .want_end = 3 },
        .{ .pattern = "\\P{Kannada}+", .text = "Aಅ", .want_end = 1 },
        .{ .pattern = "[\\p{Kannada}]+", .text = "ಅA", .want_end = 3 },
        .{ .pattern = "\\p{Malayalam}+", .text = "അA", .want_end = 3 },
        .{ .pattern = "\\p{Mlym}+", .text = "അA", .want_end = 3 },
        .{ .pattern = "\\P{Malayalam}+", .text = "Aഅ", .want_end = 1 },
        .{ .pattern = "[\\p{Malayalam}]+", .text = "അA", .want_end = 3 },
        .{ .pattern = "\\p{Bengali}+", .text = "অA", .want_end = 3 },
        .{ .pattern = "\\p{Beng}+", .text = "অA", .want_end = 3 },
        .{ .pattern = "\\P{Bengali}+", .text = "Aঅ", .want_end = 1 },
        .{ .pattern = "[\\p{Bengali}]+", .text = "অA", .want_end = 3 },
        .{ .pattern = "\\p{Gurmukhi}+", .text = "ਅA", .want_end = 3 },
        .{ .pattern = "\\p{Guru}+", .text = "ਅA", .want_end = 3 },
        .{ .pattern = "\\P{Gurmukhi}+", .text = "Aਅ", .want_end = 1 },
        .{ .pattern = "[\\p{Gurmukhi}]+", .text = "ਅA", .want_end = 3 },
        .{ .pattern = "\\p{Gujarati}+", .text = "અA", .want_end = 3 },
        .{ .pattern = "\\p{Gujr}+", .text = "અA", .want_end = 3 },
        .{ .pattern = "\\P{Gujarati}+", .text = "Aઅ", .want_end = 1 },
        .{ .pattern = "[\\p{Gujarati}]+", .text = "અA", .want_end = 3 },
        .{ .pattern = "\\p{Oriya}+", .text = "ଅA", .want_end = 3 },
        .{ .pattern = "\\p{Orya}+", .text = "ଅA", .want_end = 3 },
        .{ .pattern = "\\P{Oriya}+", .text = "Aଅ", .want_end = 1 },
        .{ .pattern = "[\\p{Oriya}]+", .text = "ଅA", .want_end = 3 },
        .{ .pattern = "\\p{Tibetan}+", .text = "ཀA", .want_end = 3 },
        .{ .pattern = "\\p{Tibt}+", .text = "ཀA", .want_end = 3 },
        .{ .pattern = "\\P{Tibetan}+", .text = "Aཀ", .want_end = 1 },
        .{ .pattern = "[\\p{Tibetan}]+", .text = "ཀA", .want_end = 3 },
        .{ .pattern = "\\p{Malayalam}+", .text = "ᰀA", .want_start = null, .want_end = null },
        .{ .pattern = "\\p{Balinese}+", .text = "ᬅA", .want_end = 3 },
        .{ .pattern = "\\p{Bali}+", .text = "ᬅA", .want_end = 3 },
        .{ .pattern = "\\P{Balinese}+", .text = "Aᬅ", .want_end = 1 },
        .{ .pattern = "[\\p{Balinese}]+", .text = "ᬅA", .want_end = 3 },
        .{ .pattern = "\\p{Batak}+", .text = "ᯀA", .want_end = 3 },
        .{ .pattern = "\\p{Batk}+", .text = "ᯀA", .want_end = 3 },
        .{ .pattern = "\\P{Batak}+", .text = "Aᯀ", .want_end = 1 },
        .{ .pattern = "[\\p{Batak}]+", .text = "ᯀA", .want_end = 3 },
        .{ .pattern = "\\p{Buginese}+", .text = "ᨀA", .want_end = 3 },
        .{ .pattern = "\\p{Bugi}+", .text = "ᨀA", .want_end = 3 },
        .{ .pattern = "\\P{Buginese}+", .text = "Aᨀ", .want_end = 1 },
        .{ .pattern = "[\\p{Buginese}]+", .text = "ᨀA", .want_end = 3 },
        .{ .pattern = "\\p{Cham}+", .text = "ꨀA", .want_end = 3 },
        .{ .pattern = "\\P{Cham}+", .text = "Aꨀ", .want_end = 1 },
        .{ .pattern = "[\\p{Cham}]+", .text = "ꨀA", .want_end = 3 },
        .{ .pattern = "\\p{Javanese}+", .text = "ꦄA", .want_end = 3 },
        .{ .pattern = "\\p{Java}+", .text = "ꦄA", .want_end = 3 },
        .{ .pattern = "\\P{Javanese}+", .text = "Aꦄ", .want_end = 1 },
        .{ .pattern = "[\\p{Javanese}]+", .text = "ꦄA", .want_end = 3 },
        .{ .pattern = "\\p{Lepcha}+", .text = "ᰀA", .want_end = 3 },
        .{ .pattern = "\\p{Lepc}+", .text = "ᰀA", .want_end = 3 },
        .{ .pattern = "\\P{Lepcha}+", .text = "Aᰀ", .want_end = 1 },
        .{ .pattern = "[\\p{Lepcha}]+", .text = "ᰀA", .want_end = 3 },
        .{ .pattern = "\\p{Limbu}+", .text = "ᤀA", .want_end = 3 },
        .{ .pattern = "\\p{Limb}+", .text = "ᤀA", .want_end = 3 },
        .{ .pattern = "\\P{Limbu}+", .text = "Aᤀ", .want_end = 1 },
        .{ .pattern = "[\\p{Limbu}]+", .text = "ᤀA", .want_end = 3 },
        .{ .pattern = "\\p{New_Tai_Lue}+", .text = "ᦀA", .want_end = 3 },
        .{ .pattern = "\\p{Talu}+", .text = "ᦀA", .want_end = 3 },
        .{ .pattern = "\\P{New_Tai_Lue}+", .text = "Aᦀ", .want_end = 1 },
        .{ .pattern = "[\\p{New_Tai_Lue}]+", .text = "ᦀA", .want_end = 3 },
        .{ .pattern = "\\p{Tai_Le}+", .text = "ᥐA", .want_end = 3 },
        .{ .pattern = "\\p{Tale}+", .text = "ᥐA", .want_end = 3 },
        .{ .pattern = "\\P{Tai_Le}+", .text = "Aᥐ", .want_end = 1 },
        .{ .pattern = "[\\p{Tai_Le}]+", .text = "ᥐA", .want_end = 3 },
        .{ .pattern = "\\p{Rejang}+", .text = "ꤰA", .want_end = 3 },
        .{ .pattern = "\\p{Rjng}+", .text = "ꤰA", .want_end = 3 },
        .{ .pattern = "\\P{Rejang}+", .text = "Aꤰ", .want_end = 1 },
        .{ .pattern = "[\\p{Rejang}]+", .text = "ꤰA", .want_end = 3 },
        .{ .pattern = "\\p{Adlam}+", .text = "𞤀A", .want_end = 4 },
        .{ .pattern = "\\p{Adlm}+", .text = "𞤀A", .want_end = 4 },
        .{ .pattern = "\\P{Adlam}+", .text = "A𞤀", .want_end = 1 },
        .{ .pattern = "[\\p{Adlam}]+", .text = "𞤀A", .want_end = 4 },
        .{ .pattern = "\\p{Ahom}+", .text = "𑜀A", .want_end = 4 },
        .{ .pattern = "\\P{Ahom}+", .text = "A𑜀", .want_end = 1 },
        .{ .pattern = "[\\p{Ahom}]+", .text = "𑜀A", .want_end = 4 },
        .{ .pattern = "\\p{Avestan}+", .text = "𐬀A", .want_end = 4 },
        .{ .pattern = "\\p{Avst}+", .text = "𐬀A", .want_end = 4 },
        .{ .pattern = "\\P{Avestan}+", .text = "A𐬀", .want_end = 1 },
        .{ .pattern = "[\\p{Avestan}]+", .text = "𐬀A", .want_end = 4 },
        .{ .pattern = "\\p{Bassa_Vah}+", .text = "𖫐A", .want_end = 4 },
        .{ .pattern = "\\p{Bass}+", .text = "𖫐A", .want_end = 4 },
        .{ .pattern = "\\P{Bassa_Vah}+", .text = "A𖫐", .want_end = 1 },
        .{ .pattern = "[\\p{Bassa_Vah}]+", .text = "𖫐A", .want_end = 4 },
        .{ .pattern = "\\p{Bhaiksuki}+", .text = "𑰀A", .want_end = 4 },
        .{ .pattern = "\\p{Bhks}+", .text = "𑰀A", .want_end = 4 },
        .{ .pattern = "\\P{Bhaiksuki}+", .text = "A𑰀", .want_end = 1 },
        .{ .pattern = "[\\p{Bhaiksuki}]+", .text = "𑰀A", .want_end = 4 },
        .{ .pattern = "\\p{Brahmi}+", .text = "𑀅A", .want_end = 4 },
        .{ .pattern = "\\p{Brah}+", .text = "𑀅A", .want_end = 4 },
        .{ .pattern = "\\P{Brahmi}+", .text = "A𑀅", .want_end = 1 },
        .{ .pattern = "[\\p{Brahmi}]+", .text = "𑀅A", .want_end = 4 },
        .{ .pattern = "\\p{Carian}+", .text = "𐊠A", .want_end = 4 },
        .{ .pattern = "\\p{Cari}+", .text = "𐊠A", .want_end = 4 },
        .{ .pattern = "\\P{Carian}+", .text = "A𐊠", .want_end = 1 },
        .{ .pattern = "[\\p{Carian}]+", .text = "𐊠A", .want_end = 4 },
        .{ .pattern = "\\p{Caucasian_Albanian}+", .text = "𐔰A", .want_end = 4 },
        .{ .pattern = "\\p{Aghb}+", .text = "𐔰A", .want_end = 4 },
        .{ .pattern = "\\P{Caucasian_Albanian}+", .text = "A𐔰", .want_end = 1 },
        .{ .pattern = "[\\p{Caucasian_Albanian}]+", .text = "𐔰A", .want_end = 4 },
        .{ .pattern = "\\p{Chakma}+", .text = "𑄃A", .want_end = 4 },
        .{ .pattern = "\\p{Cakm}+", .text = "𑄃A", .want_end = 4 },
        .{ .pattern = "\\P{Chakma}+", .text = "A𑄃", .want_end = 1 },
        .{ .pattern = "[\\p{Chakma}]+", .text = "𑄃A", .want_end = 4 },
        .{ .pattern = "\\p{Cuneiform}+", .text = "𒀀A", .want_end = 4 },
        .{ .pattern = "\\p{Xsux}+", .text = "𒀀A", .want_end = 4 },
        .{ .pattern = "\\P{Cuneiform}+", .text = "A𒀀", .want_end = 1 },
        .{ .pattern = "[\\p{Cuneiform}]+", .text = "𒀀A", .want_end = 4 },
        .{ .pattern = "\\p{Dives_Akuru}+", .text = "𑤀A", .want_end = 4 },
        .{ .pattern = "\\p{Diak}+", .text = "𑤀A", .want_end = 4 },
        .{ .pattern = "\\P{Dives_Akuru}+", .text = "A𑤀", .want_end = 1 },
        .{ .pattern = "[\\p{Dives_Akuru}]+", .text = "𑤀A", .want_end = 4 },
        .{ .pattern = "\\p{Dogra}+", .text = "𑠀A", .want_end = 4 },
        .{ .pattern = "\\p{Dogr}+", .text = "𑠀A", .want_end = 4 },
        .{ .pattern = "\\P{Dogra}+", .text = "A𑠀", .want_end = 1 },
        .{ .pattern = "[\\p{Dogra}]+", .text = "𑠀A", .want_end = 4 },
        .{ .pattern = "\\p{Duployan}+", .text = "𛱰A", .want_end = 4 },
        .{ .pattern = "\\p{Dupl}+", .text = "𛱰A", .want_end = 4 },
        .{ .pattern = "\\P{Duployan}+", .text = "A𛱰", .want_end = 1 },
        .{ .pattern = "[\\p{Duployan}]+", .text = "𛱰A", .want_end = 4 },
        .{ .pattern = "\\p{Egyptian_Hieroglyphs}+", .text = "𓀀A", .want_end = 4 },
        .{ .pattern = "\\p{Egyp}+", .text = "𓀀A", .want_end = 4 },
        .{ .pattern = "\\P{Egyptian_Hieroglyphs}+", .text = "A𓀀", .want_end = 1 },
        .{ .pattern = "[\\p{Egyptian_Hieroglyphs}]+", .text = "𓀀A", .want_end = 4 },
        .{ .pattern = "\\p{Elbasan}+", .text = "𐔀A", .want_end = 4 },
        .{ .pattern = "\\p{Elba}+", .text = "𐔀A", .want_end = 4 },
        .{ .pattern = "\\P{Elbasan}+", .text = "A𐔀", .want_end = 1 },
        .{ .pattern = "[\\p{Elbasan}]+", .text = "𐔀A", .want_end = 4 },
        .{ .pattern = "\\p{Elymaic}+", .text = "𐿠A", .want_end = 4 },
        .{ .pattern = "\\p{Elym}+", .text = "𐿠A", .want_end = 4 },
        .{ .pattern = "\\P{Elymaic}+", .text = "A𐿠", .want_end = 1 },
        .{ .pattern = "[\\p{Elymaic}]+", .text = "𐿠A", .want_end = 4 },
        .{ .pattern = "\\p{Glagolitic}+", .text = "ⰀA", .want_end = 3 },
        .{ .pattern = "\\p{Glag}+", .text = "ⰀA", .want_end = 3 },
        .{ .pattern = "\\P{Glagolitic}+", .text = "AⰀ", .want_end = 1 },
        .{ .pattern = "[\\p{Glagolitic}]+", .text = "ⰀA", .want_end = 3 },
        .{ .pattern = "\\p{Grantha}+", .text = "𑌅A", .want_end = 4 },
        .{ .pattern = "\\p{Gran}+", .text = "𑌅A", .want_end = 4 },
        .{ .pattern = "\\P{Grantha}+", .text = "A𑌅", .want_end = 1 },
        .{ .pattern = "[\\p{Grantha}]+", .text = "𑌅A", .want_end = 4 },
        .{ .pattern = "\\p{Gunjala_Gondi}+", .text = "𑵠A", .want_end = 4 },
        .{ .pattern = "\\p{Gong}+", .text = "𑵠A", .want_end = 4 },
        .{ .pattern = "\\P{Gunjala_Gondi}+", .text = "A𑵠", .want_end = 1 },
        .{ .pattern = "[\\p{Gunjala_Gondi}]+", .text = "𑵠A", .want_end = 4 },
        .{ .pattern = "\\p{Hanifi_Rohingya}+", .text = "𐴀A", .want_end = 4 },
        .{ .pattern = "\\p{Rohg}+", .text = "𐴀A", .want_end = 4 },
        .{ .pattern = "\\P{Hanifi_Rohingya}+", .text = "A𐴀", .want_end = 1 },
        .{ .pattern = "[\\p{Hanifi_Rohingya}]+", .text = "𐴀A", .want_end = 4 },
        .{ .pattern = "\\p{Imperial_Aramaic}+", .text = "𐡀A", .want_end = 4 },
        .{ .pattern = "\\p{Armi}+", .text = "𐡀A", .want_end = 4 },
        .{ .pattern = "\\P{Imperial_Aramaic}+", .text = "A𐡀", .want_end = 1 },
        .{ .pattern = "[\\p{Imperial_Aramaic}]+", .text = "𐡀A", .want_end = 4 },
        .{ .pattern = "\\p{Inscriptional_Parthian}+", .text = "𐭀A", .want_end = 4 },
        .{ .pattern = "\\p{Prti}+", .text = "𐭀A", .want_end = 4 },
        .{ .pattern = "\\P{Inscriptional_Parthian}+", .text = "A𐭀", .want_end = 1 },
        .{ .pattern = "[\\p{Inscriptional_Parthian}]+", .text = "𐭀A", .want_end = 4 },
        .{ .pattern = "\\p{Inscriptional_Pahlavi}+", .text = "𐭠A", .want_end = 4 },
        .{ .pattern = "\\p{Phli}+", .text = "𐭠A", .want_end = 4 },
        .{ .pattern = "\\P{Inscriptional_Pahlavi}+", .text = "A𐭠", .want_end = 1 },
        .{ .pattern = "[\\p{Inscriptional_Pahlavi}]+", .text = "𐭠A", .want_end = 4 },
        .{ .pattern = "\\p{Kaithi}+", .text = "𑂃A", .want_end = 4 },
        .{ .pattern = "\\p{Kthi}+", .text = "𑂃A", .want_end = 4 },
        .{ .pattern = "\\P{Kaithi}+", .text = "A𑂃", .want_end = 1 },
        .{ .pattern = "[\\p{Kaithi}]+", .text = "𑂃A", .want_end = 4 },
        .{ .pattern = "\\p{Khojki}+", .text = "𑈀A", .want_end = 4 },
        .{ .pattern = "\\p{Khoj}+", .text = "𑈀A", .want_end = 4 },
        .{ .pattern = "\\P{Khojki}+", .text = "A𑈀", .want_end = 1 },
        .{ .pattern = "[\\p{Khojki}]+", .text = "𑈀A", .want_end = 4 },
        .{ .pattern = "\\p{Khitan_Small_Script}+", .text = "𘬀A", .want_end = 4 },
        .{ .pattern = "\\p{Kits}+", .text = "𘬀A", .want_end = 4 },
        .{ .pattern = "\\P{Khitan_Small_Script}+", .text = "A𘬀", .want_end = 1 },
        .{ .pattern = "[\\p{Khitan_Small_Script}]+", .text = "𘬀A", .want_end = 4 },
        .{ .pattern = "\\p{Lycian}+", .text = "𐊀A", .want_end = 4 },
        .{ .pattern = "\\p{Lyci}+", .text = "𐊀A", .want_end = 4 },
        .{ .pattern = "\\P{Lycian}+", .text = "A𐊀", .want_end = 1 },
        .{ .pattern = "[\\p{Lycian}]+", .text = "𐊀A", .want_end = 4 },
        .{ .pattern = "\\p{Lydian}+", .text = "𐤠A", .want_end = 4 },
        .{ .pattern = "\\p{Lydi}+", .text = "𐤠A", .want_end = 4 },
        .{ .pattern = "\\P{Lydian}+", .text = "A𐤠", .want_end = 1 },
        .{ .pattern = "[\\p{Lydian}]+", .text = "𐤠A", .want_end = 4 },
        .{ .pattern = "\\p{Mahajani}+", .text = "𑅐A", .want_end = 4 },
        .{ .pattern = "\\p{Mahj}+", .text = "𑅐A", .want_end = 4 },
        .{ .pattern = "\\P{Mahajani}+", .text = "A𑅐", .want_end = 1 },
        .{ .pattern = "[\\p{Mahajani}]+", .text = "𑅐A", .want_end = 4 },
        .{ .pattern = "\\p{Makasar}+", .text = "𑻠A", .want_end = 4 },
        .{ .pattern = "\\p{Maka}+", .text = "𑻠A", .want_end = 4 },
        .{ .pattern = "\\P{Makasar}+", .text = "A𑻠", .want_end = 1 },
        .{ .pattern = "[\\p{Makasar}]+", .text = "𑻠A", .want_end = 4 },
        .{ .pattern = "\\p{Mandaic}+", .text = "ࡀA", .want_end = 3 },
        .{ .pattern = "\\p{Mand}+", .text = "ࡀA", .want_end = 3 },
        .{ .pattern = "\\P{Mandaic}+", .text = "Aࡀ", .want_end = 1 },
        .{ .pattern = "[\\p{Mandaic}]+", .text = "ࡀA", .want_end = 3 },
        .{ .pattern = "\\p{Manichaean}+", .text = "\u{10ac0}A", .want_end = 4 },
        .{ .pattern = "\\p{Mani}+", .text = "\u{10ac0}A", .want_end = 4 },
        .{ .pattern = "\\P{Manichaean}+", .text = "A\u{10ac0}", .want_end = 1 },
        .{ .pattern = "[\\p{Manichaean}]+", .text = "\u{10ac0}A", .want_end = 4 },
        .{ .pattern = "\\p{Marchen}+", .text = "\u{11c70}A", .want_end = 4 },
        .{ .pattern = "\\p{Marc}+", .text = "\u{11c70}A", .want_end = 4 },
        .{ .pattern = "\\P{Marchen}+", .text = "A\u{11c70}", .want_end = 1 },
        .{ .pattern = "[\\p{Marchen}]+", .text = "\u{11c70}A", .want_end = 4 },
        .{ .pattern = "\\p{Masaram_Gondi}+", .text = "\u{11d00}A", .want_end = 4 },
        .{ .pattern = "\\p{Gonm}+", .text = "\u{11d00}A", .want_end = 4 },
        .{ .pattern = "\\P{Masaram_Gondi}+", .text = "A\u{11d00}", .want_end = 1 },
        .{ .pattern = "[\\p{Masaram_Gondi}]+", .text = "\u{11d00}A", .want_end = 4 },
        .{ .pattern = "\\p{Medefaidrin}+", .text = "\u{16e40}A", .want_end = 4 },
        .{ .pattern = "\\p{Medf}+", .text = "\u{16e40}A", .want_end = 4 },
        .{ .pattern = "\\P{Medefaidrin}+", .text = "A\u{16e40}", .want_end = 1 },
        .{ .pattern = "[\\p{Medefaidrin}]+", .text = "\u{16e40}A", .want_end = 4 },
        .{ .pattern = "\\p{Mende_Kikakui}+", .text = "\u{1e800}A", .want_end = 4 },
        .{ .pattern = "\\p{Mend}+", .text = "\u{1e800}A", .want_end = 4 },
        .{ .pattern = "\\P{Mende_Kikakui}+", .text = "A\u{1e800}", .want_end = 1 },
        .{ .pattern = "[\\p{Mende_Kikakui}]+", .text = "\u{1e800}A", .want_end = 4 },
        .{ .pattern = "\\p{Meroitic_Cursive}+", .text = "\u{109a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Merc}+", .text = "\u{109a0}A", .want_end = 4 },
        .{ .pattern = "\\P{Meroitic_Cursive}+", .text = "A\u{109a0}", .want_end = 1 },
        .{ .pattern = "[\\p{Meroitic_Cursive}]+", .text = "\u{109a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Meroitic_Hieroglyphs}+", .text = "\u{10980}A", .want_end = 4 },
        .{ .pattern = "\\p{Mero}+", .text = "\u{10980}A", .want_end = 4 },
        .{ .pattern = "\\P{Meroitic_Hieroglyphs}+", .text = "A\u{10980}", .want_end = 1 },
        .{ .pattern = "[\\p{Meroitic_Hieroglyphs}]+", .text = "\u{10980}A", .want_end = 4 },
        .{ .pattern = "\\p{Miao}+", .text = "\u{16f00}A", .want_end = 4 },
        .{ .pattern = "\\p{Plrd}+", .text = "\u{16f00}A", .want_end = 4 },
        .{ .pattern = "\\P{Miao}+", .text = "A\u{16f00}", .want_end = 1 },
        .{ .pattern = "[\\p{Miao}]+", .text = "\u{16f00}A", .want_end = 4 },
        .{ .pattern = "\\p{Modi}+", .text = "\u{11600}A", .want_end = 4 },
        .{ .pattern = "\\P{Modi}+", .text = "A\u{11600}", .want_end = 1 },
        .{ .pattern = "[\\p{Modi}]+", .text = "\u{11600}A", .want_end = 4 },
        .{ .pattern = "\\p{Multani}+", .text = "\u{11280}A", .want_end = 4 },
        .{ .pattern = "\\p{Mult}+", .text = "\u{11280}A", .want_end = 4 },
        .{ .pattern = "\\P{Multani}+", .text = "A\u{11280}", .want_end = 1 },
        .{ .pattern = "[\\p{Multani}]+", .text = "\u{11280}A", .want_end = 4 },
        .{ .pattern = "\\p{Nabataean}+", .text = "\u{10880}A", .want_end = 4 },
        .{ .pattern = "\\p{Nbat}+", .text = "\u{10880}A", .want_end = 4 },
        .{ .pattern = "\\P{Nabataean}+", .text = "A\u{10880}", .want_end = 1 },
        .{ .pattern = "[\\p{Nabataean}]+", .text = "\u{10880}A", .want_end = 4 },
        .{ .pattern = "\\p{Nandinagari}+", .text = "\u{119a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Nand}+", .text = "\u{119a0}A", .want_end = 4 },
        .{ .pattern = "\\P{Nandinagari}+", .text = "A\u{119a0}", .want_end = 1 },
        .{ .pattern = "[\\p{Nandinagari}]+", .text = "\u{119a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Newa}+", .text = "\u{11400}A", .want_end = 4 },
        .{ .pattern = "\\P{Newa}+", .text = "A\u{11400}", .want_end = 1 },
        .{ .pattern = "[\\p{Newa}]+", .text = "\u{11400}A", .want_end = 4 },
        .{ .pattern = "\\p{Nushu}+", .text = "\u{1b170}A", .want_end = 4 },
        .{ .pattern = "\\p{Nshu}+", .text = "\u{1b170}A", .want_end = 4 },
        .{ .pattern = "\\P{Nushu}+", .text = "A\u{1b170}", .want_end = 1 },
        .{ .pattern = "[\\p{Nushu}]+", .text = "\u{1b170}A", .want_end = 4 },
        .{ .pattern = "\\p{Old_North_Arabian}+", .text = "\u{10a80}A", .want_end = 4 },
        .{ .pattern = "\\p{Narb}+", .text = "\u{10a80}A", .want_end = 4 },
        .{ .pattern = "\\P{Old_North_Arabian}+", .text = "A\u{10a80}", .want_end = 1 },
        .{ .pattern = "[\\p{Old_North_Arabian}]+", .text = "\u{10a80}A", .want_end = 4 },
        .{ .pattern = "\\p{Old_Permic}+", .text = "\u{10350}A", .want_end = 4 },
        .{ .pattern = "\\p{Perm}+", .text = "\u{10350}A", .want_end = 4 },
        .{ .pattern = "\\P{Old_Permic}+", .text = "A\u{10350}", .want_end = 1 },
        .{ .pattern = "[\\p{Old_Permic}]+", .text = "\u{10350}A", .want_end = 4 },
        .{ .pattern = "\\p{Old_Persian}+", .text = "\u{103a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Xpeo}+", .text = "\u{103a0}A", .want_end = 4 },
        .{ .pattern = "\\P{Old_Persian}+", .text = "A\u{103a0}", .want_end = 1 },
        .{ .pattern = "[\\p{Old_Persian}]+", .text = "\u{103a0}A", .want_end = 4 },
        .{ .pattern = "\\p{Old_Sogdian}+", .text = "\u{10f00}A", .want_end = 4 },
        .{ .pattern = "\\p{Sogo}+", .text = "\u{10f00}A", .want_end = 4 },
        .{ .pattern = "\\P{Old_Sogdian}+", .text = "A\u{10f00}", .want_end = 1 },
        .{ .pattern = "[\\p{Old_Sogdian}]+", .text = "\u{10f00}A", .want_end = 4 },
        .{ .pattern = "\\p{Syriac}+", .text = "ܐA", .want_end = 2 },
        .{ .pattern = "\\p{Syrc}+", .text = "ܐA", .want_end = 2 },
        .{ .pattern = "\\P{Syriac}+", .text = "Aܐ", .want_end = 1 },
        .{ .pattern = "[\\p{Syriac}]+", .text = "ܐA", .want_end = 2 },
        .{ .pattern = "\\p{Thaana}+", .text = "ހA", .want_end = 2 },
        .{ .pattern = "\\p{Thaa}+", .text = "ހA", .want_end = 2 },
        .{ .pattern = "\\P{Thaana}+", .text = "Aހ", .want_end = 1 },
        .{ .pattern = "[\\p{Thaana}]+", .text = "ހA", .want_end = 2 },
        .{ .pattern = "\\p{Nko}+", .text = "ߊA", .want_end = 2 },
        .{ .pattern = "\\p{Nkoo}+", .text = "ߊA", .want_end = 2 },
        .{ .pattern = "\\P{Nko}+", .text = "Aߊ", .want_end = 1 },
        .{ .pattern = "[\\p{Nko}]+", .text = "ߊA", .want_end = 2 },
        .{ .pattern = "\\p{Cherokee}+", .text = "ᎠA", .want_end = 3 },
        .{ .pattern = "\\p{Cher}+", .text = "ᎠA", .want_end = 3 },
        .{ .pattern = "\\P{Cherokee}+", .text = "AᎠ", .want_end = 1 },
        .{ .pattern = "[\\p{Cherokee}]+", .text = "ᎠA", .want_end = 3 },
        .{ .pattern = "\\p{Canadian_Aboriginal}+", .text = "ᐁA", .want_end = 3 },
        .{ .pattern = "\\p{Cans}+", .text = "ᐁA", .want_end = 3 },
        .{ .pattern = "\\P{Canadian_Aboriginal}+", .text = "Aᐁ", .want_end = 1 },
        .{ .pattern = "[\\p{Canadian_Aboriginal}]+", .text = "ᐁA", .want_end = 3 },
        .{ .pattern = "\\p{Ogham}+", .text = "ᚁA", .want_end = 3 },
        .{ .pattern = "\\p{Ogam}+", .text = "ᚁA", .want_end = 3 },
        .{ .pattern = "\\P{Ogham}+", .text = "Aᚁ", .want_end = 1 },
        .{ .pattern = "[\\p{Ogham}]+", .text = "ᚁA", .want_end = 3 },
        .{ .pattern = "\\p{Mongolian}+", .text = "ᠠA", .want_end = 3 },
        .{ .pattern = "\\p{Mong}+", .text = "ᠠA", .want_end = 3 },
        .{ .pattern = "\\P{Mongolian}+", .text = "Aᠠ", .want_end = 1 },
        .{ .pattern = "[\\p{Mongolian}]+", .text = "ᠠA", .want_end = 3 },
        .{ .pattern = "\\p{Coptic}+", .text = "ⲀA", .want_end = 3 },
        .{ .pattern = "\\p{Copt}+", .text = "ⲀA", .want_end = 3 },
        .{ .pattern = "\\P{Coptic}+", .text = "AⲀ", .want_end = 1 },
        .{ .pattern = "[\\p{Coptic}]+", .text = "ⲀA", .want_end = 3 },
        .{ .pattern = "\\p{Gothic}+", .text = "𐌰A", .want_end = 4 },
        .{ .pattern = "\\p{Goth}+", .text = "𐌰A", .want_end = 4 },
        .{ .pattern = "\\P{Gothic}+", .text = "A𐌰", .want_end = 1 },
        .{ .pattern = "[\\p{Gothic}]+", .text = "𐌰A", .want_end = 4 },
        .{ .pattern = "\\p{Deseret}+", .text = "𐐀A", .want_end = 4 },
        .{ .pattern = "\\p{Dsrt}+", .text = "𐐀A", .want_end = 4 },
        .{ .pattern = "\\P{Deseret}+", .text = "A𐐀", .want_end = 1 },
        .{ .pattern = "[\\p{Deseret}]+", .text = "𐐀A", .want_end = 4 },
        .{ .pattern = "\\p{Old_Italic}+", .text = "𐌀A", .want_end = 4 },
        .{ .pattern = "\\p{Ital}+", .text = "𐌀A", .want_end = 4 },
        .{ .pattern = "\\P{Old_Italic}+", .text = "A𐌀", .want_end = 1 },
        .{ .pattern = "[\\p{Old_Italic}]+", .text = "𐌀A", .want_end = 4 },
        .{ .pattern = "\\p{Tagalog}+", .text = "ᜀA", .want_end = 3 },
        .{ .pattern = "\\p{Tglg}+", .text = "ᜀA", .want_end = 3 },
        .{ .pattern = "\\P{Tagalog}+", .text = "Aᜀ", .want_end = 1 },
        .{ .pattern = "[\\p{Tagalog}]+", .text = "ᜀA", .want_end = 3 },
        .{ .pattern = "\\p{Hanunoo}+", .text = "ᜠA", .want_end = 3 },
        .{ .pattern = "\\p{Hano}+", .text = "ᜠA", .want_end = 3 },
        .{ .pattern = "\\P{Hanunoo}+", .text = "Aᜠ", .want_end = 1 },
        .{ .pattern = "[\\p{Hanunoo}]+", .text = "ᜠA", .want_end = 3 },
        .{ .pattern = "\\p{Buhid}+", .text = "ᝀA", .want_end = 3 },
        .{ .pattern = "\\p{Buhd}+", .text = "ᝀA", .want_end = 3 },
        .{ .pattern = "\\P{Buhid}+", .text = "Aᝀ", .want_end = 1 },
        .{ .pattern = "[\\p{Buhid}]+", .text = "ᝀA", .want_end = 3 },
        .{ .pattern = "\\p{Tagbanwa}+", .text = "ᝠA", .want_end = 3 },
        .{ .pattern = "\\p{Tagb}+", .text = "ᝠA", .want_end = 3 },
        .{ .pattern = "\\P{Tagbanwa}+", .text = "Aᝠ", .want_end = 1 },
        .{ .pattern = "[\\p{Tagbanwa}]+", .text = "ᝠA", .want_end = 3 },
        .{ .pattern = "\\p{Yi}+", .text = "ꀀA", .want_end = 3 },
        .{ .pattern = "\\p{Yiii}+", .text = "ꀀA", .want_end = 3 },
        .{ .pattern = "\\P{Yi}+", .text = "Aꀀ", .want_end = 1 },
        .{ .pattern = "[\\p{Yi}]+", .text = "ꀀA", .want_end = 3 },
        .{ .pattern = "\\p{Braille}+", .text = "⠀A", .want_end = 3 },
        .{ .pattern = "\\p{Brai}+", .text = "⠀A", .want_end = 3 },
        .{ .pattern = "\\P{Braille}+", .text = "A⠀", .want_end = 1 },
        .{ .pattern = "[\\p{Braille}]+", .text = "⠀A", .want_end = 3 },
        .{ .pattern = "\\p{Tifinagh}+", .text = "ⴰA", .want_end = 3 },
        .{ .pattern = "\\p{Tfng}+", .text = "ⴰA", .want_end = 3 },
        .{ .pattern = "\\P{Tifinagh}+", .text = "Aⴰ", .want_end = 1 },
        .{ .pattern = "[\\p{Tifinagh}]+", .text = "ⴰA", .want_end = 3 },
        .{ .pattern = "\\p{Vai}+", .text = "ꔀA", .want_end = 3 },
        .{ .pattern = "\\p{Vaii}+", .text = "ꔀA", .want_end = 3 },
        .{ .pattern = "\\P{Vai}+", .text = "Aꔀ", .want_end = 1 },
        .{ .pattern = "[\\p{Vai}]+", .text = "ꔀA", .want_end = 3 },
        .{ .pattern = "\\p{Lisu}+", .text = "ꓐA", .want_end = 3 },
        .{ .pattern = "\\p{Lisu}+", .text = "𑾰A", .want_end = 4 },
        .{ .pattern = "\\P{Lisu}+", .text = "Aꓐ", .want_end = 1 },
        .{ .pattern = "[\\p{Lisu}]+", .text = "ꓐA", .want_end = 3 },
        .{ .pattern = "\\p{Bamum}+", .text = "ꚠA", .want_end = 3 },
        .{ .pattern = "\\p{Bamu}+", .text = "ꚠA", .want_end = 3 },
        .{ .pattern = "\\P{Bamum}+", .text = "Aꚠ", .want_end = 1 },
        .{ .pattern = "[\\p{Bamum}]+", .text = "ꚠA", .want_end = 3 },
        .{ .pattern = "\\p{Syloti_Nagri}+", .text = "ꠀA", .want_end = 3 },
        .{ .pattern = "\\p{Sylo}+", .text = "ꠀA", .want_end = 3 },
        .{ .pattern = "\\P{Syloti_Nagri}+", .text = "Aꠀ", .want_end = 1 },
        .{ .pattern = "[\\p{Syloti_Nagri}]+", .text = "ꠀA", .want_end = 3 },
        .{ .pattern = "\\p{Phags_Pa}+", .text = "ꡀA", .want_end = 3 },
        .{ .pattern = "\\p{Phag}+", .text = "ꡀA", .want_end = 3 },
        .{ .pattern = "\\P{Phags_Pa}+", .text = "Aꡀ", .want_end = 1 },
        .{ .pattern = "[\\p{Phags_Pa}]+", .text = "ꡀA", .want_end = 3 },
        .{ .pattern = "\\p{Saurashtra}+", .text = "ꢂA", .want_end = 3 },
        .{ .pattern = "\\p{Saur}+", .text = "ꢂA", .want_end = 3 },
        .{ .pattern = "\\P{Saurashtra}+", .text = "Aꢂ", .want_end = 1 },
        .{ .pattern = "[\\p{Saurashtra}]+", .text = "ꢂA", .want_end = 3 },
        .{ .pattern = "\\p{Kayah_Li}+", .text = "꤀A", .want_end = 3 },
        .{ .pattern = "\\p{Kali}+", .text = "꤀A", .want_end = 3 },
        .{ .pattern = "\\P{Kayah_Li}+", .text = "A꤀", .want_end = 1 },
        .{ .pattern = "[\\p{Kayah_Li}]+", .text = "꤀A", .want_end = 3 },
        .{ .pattern = "\\p{In_Basic_Latin}+", .text = "Aé", .want_end = 1 },
        .{ .pattern = "\\p{InBasicLatin}+", .text = "!é", .want_end = 1 },
        .{ .pattern = "\\P{In_Basic_Latin}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "[\\p{In_Basic_Latin}]+", .text = "AZé", .want_end = 2 },
        .{ .pattern = "\\p{In_Latin_1_Supplement}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\p{InLatin1Supplement}+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\P{In_Latin_1_Supplement}+", .text = "Aé", .want_end = 1 },
        .{ .pattern = "[\\p{In_Latin_1_Supplement}]+", .text = "éA", .want_end = 2 },
        .{ .pattern = "\\p{In_Latin_Extended_A}+", .text = "ĀA", .want_end = 2 },
        .{ .pattern = "\\p{InLatinExtendedA}+", .text = "ĀA", .want_end = 2 },
        .{ .pattern = "\\P{In_Latin_Extended_A}+", .text = "AĀ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Latin_Extended_A}]+", .text = "ĀA", .want_end = 2 },
        .{ .pattern = "\\p{In_Latin_Extended_B}+", .text = "ƀA", .want_end = 2 },
        .{ .pattern = "\\p{InLatinExtendedB}+", .text = "ƀA", .want_end = 2 },
        .{ .pattern = "\\P{In_Latin_Extended_B}+", .text = "Aƀ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Latin_Extended_B}]+", .text = "ƀA", .want_end = 2 },
        .{ .pattern = "\\p{In_IPA_Extensions}+", .text = "ɐA", .want_end = 2 },
        .{ .pattern = "\\p{InIPAExtensions}+", .text = "ɐA", .want_end = 2 },
        .{ .pattern = "\\P{In_IPA_Extensions}+", .text = "Aɐ", .want_end = 1 },
        .{ .pattern = "[\\p{In_IPA_Extensions}]+", .text = "ɐA", .want_end = 2 },
        .{ .pattern = "\\p{In_Spacing_Modifier_Letters}+", .text = "ʰA", .want_end = 2 },
        .{ .pattern = "\\p{InSpacingModifierLetters}+", .text = "ʰA", .want_end = 2 },
        .{ .pattern = "\\P{In_Spacing_Modifier_Letters}+", .text = "Aʰ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Spacing_Modifier_Letters}]+", .text = "ʰA", .want_end = 2 },
        .{ .pattern = "\\p{In_Combining_Diacritical_Marks}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{InCombiningDiacriticalMarks}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\P{In_Combining_Diacritical_Marks}+", .text = "Á", .want_end = 1 },
        .{ .pattern = "[\\p{In_Combining_Diacritical_Marks}]+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{In_Greek_and_Coptic}+", .text = "αA", .want_end = 2 },
        .{ .pattern = "\\p{InGreekAndCoptic}+", .text = "αA", .want_end = 2 },
        .{ .pattern = "\\P{In_Greek_and_Coptic}+", .text = "Aα", .want_end = 1 },
        .{ .pattern = "[\\p{In_Greek_and_Coptic}]+", .text = "αA", .want_end = 2 },
        .{ .pattern = "\\p{In_Cyrillic}+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "\\p{InCyrillic}+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "\\P{In_Cyrillic}+", .text = "AЖ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Cyrillic}]+", .text = "ЖA", .want_end = 2 },
        .{ .pattern = "\\p{In_Hebrew}+", .text = "אA", .want_end = 2 },
        .{ .pattern = "\\p{InHebrew}+", .text = "אA", .want_end = 2 },
        .{ .pattern = "\\P{In_Hebrew}+", .text = "Aא", .want_end = 1 },
        .{ .pattern = "[\\p{In_Hebrew}]+", .text = "אA", .want_end = 2 },
        .{ .pattern = "\\p{In_Arabic}+", .text = "شA", .want_end = 2 },
        .{ .pattern = "\\p{InArabic}+", .text = "شA", .want_end = 2 },
        .{ .pattern = "\\P{In_Arabic}+", .text = "Aش", .want_end = 1 },
        .{ .pattern = "[\\p{In_Arabic}]+", .text = "شA", .want_end = 2 },
        .{ .pattern = "\\p{In_Devanagari}+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\p{InDevanagari}+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\P{In_Devanagari}+", .text = "Aअ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Devanagari}]+", .text = "अA", .want_end = 3 },
        .{ .pattern = "\\p{In_Thai}+", .text = "กA", .want_end = 3 },
        .{ .pattern = "\\p{InThai}+", .text = "กA", .want_end = 3 },
        .{ .pattern = "\\P{In_Thai}+", .text = "Aก", .want_end = 1 },
        .{ .pattern = "[\\p{In_Thai}]+", .text = "กA", .want_end = 3 },
        .{ .pattern = "\\p{In_Hangul_Jamo}+", .text = "ᄀA", .want_end = 3 },
        .{ .pattern = "\\p{InHangulJamo}+", .text = "ᄀA", .want_end = 3 },
        .{ .pattern = "\\P{In_Hangul_Jamo}+", .text = "Aᄀ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Hangul_Jamo}]+", .text = "ᄀA", .want_end = 3 },
        .{ .pattern = "\\p{In_Hiragana}+", .text = "あA", .want_end = 3 },
        .{ .pattern = "\\p{InHiragana}+", .text = "あA", .want_end = 3 },
        .{ .pattern = "\\P{In_Hiragana}+", .text = "Aあ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Hiragana}]+", .text = "あA", .want_end = 3 },
        .{ .pattern = "\\p{In_Katakana}+", .text = "アA", .want_end = 3 },
        .{ .pattern = "\\p{InKatakana}+", .text = "アA", .want_end = 3 },
        .{ .pattern = "\\P{In_Katakana}+", .text = "Aア", .want_end = 1 },
        .{ .pattern = "[\\p{In_Katakana}]+", .text = "アA", .want_end = 3 },
        .{ .pattern = "\\p{In_Bopomofo}+", .text = "ㄅA", .want_end = 3 },
        .{ .pattern = "\\p{InBopomofo}+", .text = "ㄅA", .want_end = 3 },
        .{ .pattern = "\\P{In_Bopomofo}+", .text = "Aㄅ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Bopomofo}]+", .text = "ㄅA", .want_end = 3 },
        .{ .pattern = "\\p{In_Hangul_Compatibility_Jamo}+", .text = "ㄱA", .want_end = 3 },
        .{ .pattern = "\\p{InHangulCompatibilityJamo}+", .text = "ㄱA", .want_end = 3 },
        .{ .pattern = "\\P{In_Hangul_Compatibility_Jamo}+", .text = "Aㄱ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Hangul_Compatibility_Jamo}]+", .text = "ㄱA", .want_end = 3 },
        .{ .pattern = "\\p{In_Katakana_Phonetic_Extensions}+", .text = "ㇰA", .want_end = 3 },
        .{ .pattern = "\\p{InKatakanaPhoneticExtensions}+", .text = "ㇰA", .want_end = 3 },
        .{ .pattern = "\\P{In_Katakana_Phonetic_Extensions}+", .text = "Aㇰ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Katakana_Phonetic_Extensions}]+", .text = "ㇰA", .want_end = 3 },
        .{ .pattern = "\\p{In_CJK_Symbols_and_Punctuation}+", .text = "、A", .want_end = 3 },
        .{ .pattern = "\\p{InCJKSymbolsAndPunctuation}+", .text = "、A", .want_end = 3 },
        .{ .pattern = "\\P{In_CJK_Symbols_and_Punctuation}+", .text = "A、", .want_end = 1 },
        .{ .pattern = "[\\p{In_CJK_Symbols_and_Punctuation}]+", .text = "、A", .want_end = 3 },
        .{ .pattern = "\\p{In_CJK_Compatibility}+", .text = "㌀A", .want_end = 3 },
        .{ .pattern = "\\p{InCJKCompatibility}+", .text = "㌀A", .want_end = 3 },
        .{ .pattern = "\\P{In_CJK_Compatibility}+", .text = "A㌀", .want_end = 1 },
        .{ .pattern = "[\\p{In_CJK_Compatibility}]+", .text = "㌀A", .want_end = 3 },
        .{ .pattern = "\\p{In_CJK_Unified_Ideographs}+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\p{InCJKUnifiedIdeographs}+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\P{In_CJK_Unified_Ideographs}+", .text = "A漢", .want_end = 1 },
        .{ .pattern = "[\\p{In_CJK_Unified_Ideographs}]+", .text = "漢A", .want_end = 3 },
        .{ .pattern = "\\p{In_Hangul_Syllables}+", .text = "가A", .want_end = 3 },
        .{ .pattern = "\\p{InHangulSyllables}+", .text = "가A", .want_end = 3 },
        .{ .pattern = "\\P{In_Hangul_Syllables}+", .text = "A가", .want_end = 1 },
        .{ .pattern = "[\\p{In_Hangul_Syllables}]+", .text = "가A", .want_end = 3 },
        .{ .pattern = "\\p{In_CJK_Compatibility_Ideographs}+", .text = "豈A", .want_end = 3 },
        .{ .pattern = "\\p{InCJKCompatibilityIdeographs}+", .text = "豈A", .want_end = 3 },
        .{ .pattern = "\\P{In_CJK_Compatibility_Ideographs}+", .text = "A豈", .want_end = 1 },
        .{ .pattern = "[\\p{In_CJK_Compatibility_Ideographs}]+", .text = "豈A", .want_end = 3 },
        .{ .pattern = "\\p{In_CJK_Compatibility_Forms}+", .text = "︰A", .want_end = 3 },
        .{ .pattern = "\\p{InCJKCompatibilityForms}+", .text = "︰A", .want_end = 3 },
        .{ .pattern = "\\P{In_CJK_Compatibility_Forms}+", .text = "A︰", .want_end = 1 },
        .{ .pattern = "[\\p{In_CJK_Compatibility_Forms}]+", .text = "︰A", .want_end = 3 },
        .{ .pattern = "\\p{In_Halfwidth_and_Fullwidth_Forms}+", .text = "ＡA", .want_end = 3 },
        .{ .pattern = "\\p{InHalfwidthAndFullwidthForms}+", .text = "ＡA", .want_end = 3 },
        .{ .pattern = "\\P{In_Halfwidth_and_Fullwidth_Forms}+", .text = "AＡ", .want_end = 1 },
        .{ .pattern = "[\\p{In_Halfwidth_and_Fullwidth_Forms}]+", .text = "ＡA", .want_end = 3 },
        .{ .pattern = "\\P{Latn}+", .text = "Жé", .want_end = 2 },
        .{ .pattern = "[^\\p{Latin}]+", .text = "Жé", .want_end = 2 },
        .{ .pattern = "[\\p{Latin}\\p{Cyrillic}]+", .text = "éЖ1", .want_end = 4 },
        .{ .pattern = "[\\p{Han}\\p{Hiragana}\\p{Katakana}]+", .text = "漢あアA", .want_end = 9 },
        .{ .pattern = "\\p{Cf}+", .text = "‌A", .want_end = 3 },
        .{ .pattern = "\\p{Sm}+", .text = "∑A", .want_end = 3 },
        .{ .pattern = "\\p{So}+", .text = "☃A", .want_end = 3 },
        .{ .pattern = "\\p{Sc}+", .text = "$€A", .want_end = 4 },
        .{ .pattern = "\\p{Currency_Symbol}+", .text = "$€A", .want_end = 4 },
        .{ .pattern = "\\p{Sk}+", .text = "^`A", .want_end = 2 },
        .{ .pattern = "\\p{Modifier_Symbol}+", .text = "^`A", .want_end = 2 },
        .{ .pattern = "\\p{Me}+", .text = "⃝A", .want_end = 3 },
        .{ .pattern = "\\p{No}+", .text = "²A", .want_end = 2 },
        .{ .pattern = "\\p{Nl}+", .text = "ᛮA", .want_end = 3 },
        .{ .pattern = "\\p{Nd}+", .text = "१२A", .want_end = 6 },
        .{ .pattern = "\\P{Nd}+", .text = "A१", .want_end = 1 },
        .{ .pattern = "[\\p{Nl}\\p{Nd}]+", .text = "ᛮ१A", .want_end = 6 },
        .{ .pattern = "[\\P{Nl}]+", .text = "Aᛮ", .want_end = 1 },
        .{ .pattern = "\\p{Zs}+", .text = " x", .want_end = 2 },
        .{ .pattern = "\\p{Space_Separator}+", .text = " x", .want_end = 3 },
        .{ .pattern = "\\p{Zl}+", .text = " x", .want_end = 3 },
        .{ .pattern = "\\p{Zp}+", .text = " x", .want_end = 3 },
        .{ .pattern = "\\p{Z}+", .text = " x", .want_end = 3 },
        .{ .pattern = "\\p{Separator}+", .text = "  x", .want_end = 4 },
        .{ .pattern = "\\P{Z}+", .text = "A ", .want_end = 1 },
        .{ .pattern = "[\\p{Zs}]+", .text = "　x", .want_end = 3 },
        .{ .pattern = "[\\p{Zl}]+", .text = " x", .want_end = 3 },
        .{ .pattern = "[\\p{Zp}]+", .text = " x", .want_end = 3 },
        .{ .pattern = "[\\p{Separator}]+", .text = "  x", .want_end = 4 },
        .{ .pattern = "\\p{P}+", .text = "—A", .want_end = 3 },
        .{ .pattern = "\\p{Punctuation}+", .text = "。A", .want_end = 3 },
        .{ .pattern = "\\p{Pd}+", .text = "—A", .want_end = 3 },
        .{ .pattern = "\\p{Dash_Punctuation}+", .text = "—A", .want_end = 3 },
        .{ .pattern = "\\p{Ps}+", .text = "（A", .want_end = 3 },
        .{ .pattern = "\\p{Pe}+", .text = "）A", .want_end = 3 },
        .{ .pattern = "\\p{Pi}+", .text = "«A", .want_end = 2 },
        .{ .pattern = "\\p{Pf}+", .text = "»A", .want_end = 2 },
        .{ .pattern = "\\p{Po}+", .text = "。A", .want_end = 3 },
        .{ .pattern = "\\P{P}+", .text = "A—", .want_end = 1 },
        .{ .pattern = "[\\p{P}]+", .text = "—A", .want_end = 3 },
        .{ .pattern = "\\p{M}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{Mn}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{Nonspacing_Mark}+", .text = "́A", .want_end = 2 },
        .{ .pattern = "\\p{Mc}+", .text = "ःA", .want_end = 3 },
        .{ .pattern = "\\p{Spacing_Mark}+", .text = "ःA", .want_end = 3 },
        .{ .pattern = "\\p{Enclosing_Mark}+", .text = "⃝A", .want_end = 3 },
        .{ .pattern = "\\p{Mc}+", .text = "́A", .want_start = null, .want_end = null },
        .{ .pattern = "\\p{Mn}+", .text = "ःA", .want_start = null, .want_end = null },
        .{ .pattern = "\\p{Me}+", .text = "́A", .want_start = null, .want_end = null },
        .{ .pattern = "\\P{Mc}+", .text = "Aः", .want_end = 1 },
        .{ .pattern = "[\\p{Mc}]+", .text = "ःA", .want_end = 3 },
        .{ .pattern = "\\p{Cc}+", .text = "\u{85}A", .want_end = 2 },
        .{ .pattern = "\\p{Control}+", .text = "\u{85}A", .want_end = 2 },
        .{ .pattern = "\\p{C}+", .text = "\u{85}A", .want_end = 2 },
        .{ .pattern = "\\P{Cc}+", .text = "A\u{85}", .want_end = 1 },
        .{ .pattern = "[\\p{Cc}]+", .text = "\u{85}A", .want_end = 2 },
        .{ .pattern = "\\p{Co}+", .text = "\u{e000}A", .want_end = 3 },
        .{ .pattern = "\\p{Private_Use}+", .text = "\u{e000}A", .want_end = 3 },
        .{ .pattern = "\\p{S}+", .text = "€A", .want_end = 3 },
        .{ .pattern = "\\p{Symbol}+", .text = "☃A", .want_end = 3 },
        .{ .pattern = "\\P{S}+", .text = "A€", .want_end = 1 },
        .{ .pattern = "[\\p{S}]+", .text = "∑A", .want_end = 3 },
        .{ .pattern = "\\p{^Alpha}+", .text = "12a", .want_end = 2 },
        .{ .pattern = "\\P{^Alpha}+", .text = "Az1", .want_end = 2 },
        .{ .pattern = "[\\p{^Alpha}]+", .text = "12a", .want_end = 2 },
        .{ .pattern = "[\\P{^Alpha}]+", .text = "Az1", .want_end = 2 },
        .{ .pattern = "\\p{Decimal_Number}+", .text = "१२A", .want_end = 6 },
        .{ .pattern = "\\p{Uppercase_Letter}+", .text = "ABCa", .want_end = 3 },
        .{ .pattern = "\\P{Uppercase_Letter}+", .text = "abcA", .want_end = 3 },
        .{ .pattern = "[\\p{Lt}\\p{Lm}\\p{Lo}]+", .text = "ǅʰ漢A", .want_end = 7 },
        .{ .pattern = "[\\p{Pd}\\p{Ps}\\p{Pe}]+", .text = "-()A", .want_end = 3 },
        .{ .pattern = "[\\p{Sc}\\p{No}]+", .text = "$²A", .want_end = 3 },
        .{ .pattern = "\\h+", .text = "09AfG", .want_end = 4 },
        .{ .pattern = "\\H+", .text = "G_z", .want_end = 3 },
        .{ .pattern = "\\d+\\D+", .text = "123abc", .want_end = 6 },
        .{ .pattern = "\\w+\\W+", .text = "A_1!-", .want_end = 5 },
        .{ .pattern = "\\bword\\b", .text = "word", .want_end = 4 },
        .{ .pattern = "foo\\B", .text = "foobar", .want_end = 3 },
        .{ .pattern = "\\Bbar", .text = "foobar", .start = 3, .want_start = 3, .want_end = 6 },
        .{ .pattern = "\\P{Digit}+", .text = "abc123", .want_end = 3 },
        .{ .pattern = "(?i:[a-f]+)", .text = "AFz", .want_end = 2 },
        .{ .pattern = "(?i)[k]", .text = "K", .want_end = 3 },
        .{ .pattern = "(?i)[a-z]+", .text = "K", .want_end = 3 },
        .{ .pattern = "(?i)[^k]+", .text = "K", .want_start = null, .want_end = null },
        .{ .pattern = "(?i)[ω]", .text = "Ω", .want_end = 3 },
        .{ .pattern = "(?i)[å]", .text = "Å", .want_end = 3 },
        .{ .pattern = "(?i)Σ", .text = "ς", .want_end = 2 },
        .{ .pattern = "(?i)[σ]", .text = "ς", .want_end = 2 },
        .{ .pattern = "(?i)ß", .text = "ẞ", .want_end = 3 },
        .{ .pattern = "(?i)ẞ", .text = "ß", .want_end = 2 },
        .{ .pattern = "(?i)[ß]", .text = "ẞ", .want_end = 3 },
        .{ .pattern = "(?i)[ẞ]", .text = "ß", .want_end = 2 },
        .{ .pattern = "(?i)Ā", .text = "ā", .want_end = 2 },
        .{ .pattern = "(?i)[Į]", .text = "į", .want_end = 2 },
        .{ .pattern = "(?i)S", .text = "ſ", .want_end = 2 },
        .{ .pattern = "(?i)µ", .text = "Μ", .want_end = 2 },
        .{ .pattern = "(?i)Ĳ", .text = "ĳ", .want_end = 2 },
        .{ .pattern = "(?i)[Ĺ]", .text = "ĺ", .want_end = 2 },
        .{ .pattern = "(?i)Ŋ", .text = "ŋ", .want_end = 2 },
        .{ .pattern = "(?i)Ÿ", .text = "ÿ", .want_end = 2 },
        .{ .pattern = "(?i)Ͱ", .text = "ͱ", .want_end = 2 },
        .{ .pattern = "(?i)[Ϣ]", .text = "ϣ", .want_end = 2 },
        .{ .pattern = "(?i)ϴ", .text = "θ", .want_end = 2 },
        .{ .pattern = "(?i)[Ϸ]", .text = "ϸ", .want_end = 2 },
        .{ .pattern = "(?i)Ѡ", .text = "ѡ", .want_end = 2 },
        .{ .pattern = "(?i)[Ҋ]", .text = "ҋ", .want_end = 2 },
        .{ .pattern = "(?i)Ӂ", .text = "ӂ", .want_end = 2 },
        .{ .pattern = "(?i)[Ԯ]", .text = "ԯ", .want_end = 2 },
        .{ .pattern = "(?i)Ա", .text = "ա", .want_end = 2 },
        .{ .pattern = "(?i)[Ֆ]", .text = "ֆ", .want_end = 2 },
        .{ .pattern = "(?i)Ⴀ", .text = "ⴀ", .want_end = 3 },
        .{ .pattern = "(?i)[Ა]", .text = "ა", .want_end = 3 },
        .{ .pattern = "(?i)Ꭰ", .text = "ꭰ", .want_end = 3 },
        .{ .pattern = "(?i)[Ꮐ]", .text = "ꮐ", .want_end = 3 },
        .{ .pattern = "(?i)Ᏸ", .text = "ᏸ", .want_end = 3 },
        .{ .pattern = "(?i)[Ᏽ]", .text = "ᏽ", .want_end = 3 },
        .{ .pattern = "(?i)Ａ", .text = "ａ", .want_end = 3 },
        .{ .pattern = "(?i)[Ｍ]", .text = "ｍ", .want_end = 3 },
        .{ .pattern = "(?i)Ｚ", .text = "ｚ", .want_end = 3 },
        .{ .pattern = "(?i)Ɓ", .text = "ɓ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɔ]", .text = "ɔ", .want_end = 2 },
        .{ .pattern = "(?i)Ƃ", .text = "ƃ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƈ]", .text = "ƈ", .want_end = 2 },
        .{ .pattern = "(?i)Ɗ", .text = "ɗ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƌ]", .text = "ƌ", .want_end = 2 },
        .{ .pattern = "(?i)Ǝ", .text = "ǝ", .want_end = 2 },
        .{ .pattern = "(?i)[Ə]", .text = "ə", .want_end = 2 },
        .{ .pattern = "(?i)Ɛ", .text = "ɛ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƒ]", .text = "ƒ", .want_end = 2 },
        .{ .pattern = "(?i)Ɠ", .text = "ɠ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɣ]", .text = "ɣ", .want_end = 2 },
        .{ .pattern = "(?i)Ɩ", .text = "ɩ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɨ]", .text = "ɨ", .want_end = 2 },
        .{ .pattern = "(?i)Ƙ", .text = "ƙ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɯ]", .text = "ɯ", .want_end = 2 },
        .{ .pattern = "(?i)Ɲ", .text = "ɲ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɵ]", .text = "ɵ", .want_end = 2 },
        .{ .pattern = "(?i)Ơ", .text = "ơ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƣ]", .text = "ƣ", .want_end = 2 },
        .{ .pattern = "(?i)Ƥ", .text = "ƥ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƨ]", .text = "ƨ", .want_end = 2 },
        .{ .pattern = "(?i)Ʃ", .text = "ʃ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƭ]", .text = "ƭ", .want_end = 2 },
        .{ .pattern = "(?i)Ʈ", .text = "ʈ", .want_end = 2 },
        .{ .pattern = "(?i)[Ư]", .text = "ư", .want_end = 2 },
        .{ .pattern = "(?i)Ʊ", .text = "ʊ", .want_end = 2 },
        .{ .pattern = "(?i)[Ʋ]", .text = "ʋ", .want_end = 2 },
        .{ .pattern = "(?i)Ƴ", .text = "ƴ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƶ]", .text = "ƶ", .want_end = 2 },
        .{ .pattern = "(?i)Ʒ", .text = "ʒ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƹ]", .text = "ƹ", .want_end = 2 },
        .{ .pattern = "(?i)Ƽ", .text = "ƽ", .want_end = 2 },
        .{ .pattern = "(?i)Ƅ", .text = "ƅ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɖ]", .text = "ɖ", .want_end = 2 },
        .{ .pattern = "(?i)Ʀ", .text = "ʀ", .want_end = 2 },
        .{ .pattern = "(?i)Ǎ", .text = "ǎ", .want_end = 2 },
        .{ .pattern = "(?i)[Ǯ]", .text = "ǯ", .want_end = 2 },
        .{ .pattern = "(?i)Ƕ", .text = "ƕ", .want_end = 2 },
        .{ .pattern = "(?i)[Ƿ]", .text = "ƿ", .want_end = 2 },
        .{ .pattern = "(?i)Ȁ", .text = "ȁ", .want_end = 2 },
        .{ .pattern = "(?i)[Ȳ]", .text = "ȳ", .want_end = 2 },
        .{ .pattern = "(?i)Ⱥ", .text = "ⱥ", .want_end = 3 },
        .{ .pattern = "(?i)[Ƚ]", .text = "ƚ", .want_end = 2 },
        .{ .pattern = "(?i)Ƀ", .text = "ƀ", .want_end = 2 },
        .{ .pattern = "(?i)[Ɏ]", .text = "ɏ", .want_end = 2 },
        .{ .pattern = "(?i)Ḁ", .text = "ḁ", .want_end = 3 },
        .{ .pattern = "(?i)[Ḃ]", .text = "ḃ", .want_end = 3 },
        .{ .pattern = "(?i)Ṡ", .text = "ṡ", .want_end = 3 },
        .{ .pattern = "(?i)[Ẕ]", .text = "ẕ", .want_end = 3 },
        .{ .pattern = "(?i)ẛ", .text = "Ṡ", .want_end = 3 },
        .{ .pattern = "(?i)[ẛ]", .text = "ṡ", .want_end = 3 },
        .{ .pattern = "(?i)Ạ", .text = "ạ", .want_end = 3 },
        .{ .pattern = "(?i)[Ấ]", .text = "ấ", .want_end = 3 },
        .{ .pattern = "(?i)Ỗ", .text = "ỗ", .want_end = 3 },
        .{ .pattern = "(?i)[Ự]", .text = "ự", .want_end = 3 },
        .{ .pattern = "(?i)Ỹ", .text = "ỹ", .want_end = 3 },
        .{ .pattern = "(?i)[Ỿ]", .text = "ỿ", .want_end = 3 },
        .{ .pattern = "(?i)Ϳ", .text = "ϳ", .want_end = 2 },
        .{ .pattern = "(?i)[Ά]", .text = "ά", .want_end = 2 },
        .{ .pattern = "(?i)Έ", .text = "έ", .want_end = 2 },
        .{ .pattern = "(?i)[Ώ]", .text = "ώ", .want_end = 2 },
        .{ .pattern = "(?i)Ͻ", .text = "ͻ", .want_end = 2 },
        .{ .pattern = "(?i)[Ͽ]", .text = "ͽ", .want_end = 2 },
        .{ .pattern = "(?i)Ⅎ", .text = "ⅎ", .want_end = 3 },
        .{ .pattern = "(?i)[Ⅰ]", .text = "ⅰ", .want_end = 3 },
        .{ .pattern = "(?i)Ⅿ", .text = "ⅿ", .want_end = 3 },
        .{ .pattern = "(?i)[Ↄ]", .text = "ↄ", .want_end = 3 },
        .{ .pattern = "(?i)Ⓐ", .text = "ⓐ", .want_end = 3 },
        .{ .pattern = "(?i)[Ⓩ]", .text = "ⓩ", .want_end = 3 },
        .{ .pattern = "(?i)Ἀ", .text = "ἀ", .want_end = 3 },
        .{ .pattern = "(?i)[Ἕ]", .text = "ἕ", .want_end = 3 },
        .{ .pattern = "(?i)Ὑ", .text = "ὑ", .want_end = 3 },
        .{ .pattern = "(?i)ᾈ", .text = "ᾀ", .want_end = 3 },
        .{ .pattern = "(?i)[ᾭ]", .text = "ᾥ", .want_end = 3 },
        .{ .pattern = "(?i)Ὰ", .text = "ὰ", .want_end = 3 },
        .{ .pattern = "(?i)[Ά]", .text = "ά", .want_end = 3 },
        .{ .pattern = "(?i)ᾼ", .text = "ᾳ", .want_end = 3 },
        .{ .pattern = "(?i)Ὲ", .text = "ὲ", .want_end = 3 },
        .{ .pattern = "(?i)[Ή]", .text = "ή", .want_end = 3 },
        .{ .pattern = "(?i)Ῐ", .text = "ῐ", .want_end = 3 },
        .{ .pattern = "(?i)Ὶ", .text = "ὶ", .want_end = 3 },
        .{ .pattern = "(?i)Ῠ", .text = "ῠ", .want_end = 3 },
        .{ .pattern = "(?i)[Ύ]", .text = "ύ", .want_end = 3 },
        .{ .pattern = "(?i)Ῥ", .text = "ῥ", .want_end = 3 },
        .{ .pattern = "(?i)Ὸ", .text = "ὸ", .want_end = 3 },
        .{ .pattern = "(?i)[Ώ]", .text = "ώ", .want_end = 3 },
        .{ .pattern = "(?i)ῼ", .text = "ῳ", .want_end = 3 },
        .{ .pattern = "(?i)Ꙁ", .text = "ꙁ", .want_end = 3 },
        .{ .pattern = "(?i)[Ꚛ]", .text = "ꚛ", .want_end = 3 },
        .{ .pattern = "(?i)Ꜣ", .text = "ꜣ", .want_end = 3 },
        .{ .pattern = "(?i)[Ꝯ]", .text = "ꝯ", .want_end = 3 },
        .{ .pattern = "(?i)Ꝺ", .text = "ꝺ", .want_end = 3 },
        .{ .pattern = "(?i)[Ᵹ]", .text = "ᵹ", .want_end = 3 },
        .{ .pattern = "(?i)Ꞑ", .text = "ꞑ", .want_end = 3 },
        .{ .pattern = "(?i)[Ɦ]", .text = "ɦ", .want_end = 2 },
        .{ .pattern = "(?i)Ꭓ", .text = "ꭓ", .want_end = 3 },
        .{ .pattern = "(?i)[Ꞔ]", .text = "ꞔ", .want_end = 3 },
        .{ .pattern = "(?i)Ꟈ", .text = "ꟈ", .want_end = 3 },
        .{ .pattern = "(?i)Ꟶ", .text = "ꟶ", .want_end = 3 },
        .{ .pattern = "(?i)Ⰰ", .text = "ⰰ", .want_end = 3 },
        .{ .pattern = "(?i)[Ⱟ]", .text = "ⱟ", .want_end = 3 },
        .{ .pattern = "(?i)Ⱡ", .text = "ⱡ", .want_end = 3 },
        .{ .pattern = "(?i)[Ɫ]", .text = "ɫ", .want_end = 2 },
        .{ .pattern = "(?i)Ȿ", .text = "ȿ", .want_end = 2 },
        .{ .pattern = "(?i)Ⲁ", .text = "ⲁ", .want_end = 3 },
        .{ .pattern = "(?i)[Ⳳ]", .text = "ⳳ", .want_end = 3 },
        .{ .pattern = "(?i)𞤀", .text = "𞤢", .want_end = 4 },
        .{ .pattern = "(?i)[𞤡]", .text = "𞥃", .want_end = 4 },
        .{ .pattern = "(?i)𖹀", .text = "𖹠", .want_end = 4 },
        .{ .pattern = "(?i)[𖹟]", .text = "𖹿", .want_end = 4 },
        .{ .pattern = "(?i)Ⴧ", .text = "ⴧ", .want_end = 3 },
        .{ .pattern = "(?i)[Ⴭ]", .text = "ⴭ", .want_end = 3 },
        .{ .pattern = "(?i)Ჽ", .text = "ჽ", .want_end = 3 },
        .{ .pattern = "(?i)[Ჾ]", .text = "ჾ", .want_end = 3 },
        .{ .pattern = "(?i)Ჿ", .text = "ჿ", .want_end = 3 },
        .{ .pattern = "(?i)Ǆ", .text = "ǆ", .want_end = 2 },
        .{ .pattern = "(?i)[Ǳ]", .text = "ǳ", .want_end = 2 },
        .{ .pattern = "(?i)ǅ", .text = "ǆ", .want_end = 2 },
        .{ .pattern = "(?i)[ǲ]", .text = "ǳ", .want_end = 2 },
        .{ .pattern = "(?i)Ǆ", .text = "ǅ", .want_end = 2 },
        .{ .pattern = "(?i)[Ǳ]", .text = "ǲ", .want_end = 2 },
        .{ .pattern = "(?i)𐐀", .text = "𐐨", .want_end = 4 },
        .{ .pattern = "(?i)𐕰", .text = "𐖗", .want_end = 4 },
        .{ .pattern = "(?i)[𐕺]", .text = "𐖡", .want_end = 4 },
        .{ .pattern = "(?i)𐕼", .text = "𐖣", .want_end = 4 },
        .{ .pattern = "(?i)[𐖊]", .text = "𐖱", .want_end = 4 },
        .{ .pattern = "(?i)𐖌", .text = "𐖳", .want_end = 4 },
        .{ .pattern = "(?i)[𐖍]", .text = "𐖴", .want_end = 4 },
        .{ .pattern = "(?i)𐖎", .text = "𐖵", .want_end = 4 },
        .{ .pattern = "(?i)[𐖏]", .text = "𐖶", .want_end = 4 },
        .{ .pattern = "(?i)𐖐", .text = "𐖷", .want_end = 4 },
        .{ .pattern = "(?i)[𐖑]", .text = "𐖸", .want_end = 4 },
        .{ .pattern = "(?i)𐖒", .text = "𐖹", .want_end = 4 },
        .{ .pattern = "(?i)𐖔", .text = "𐖻", .want_end = 4 },
        .{ .pattern = "(?i)[𐖕]", .text = "𐖼", .want_end = 4 },
        .{ .pattern = "(?i)[𐒰]", .text = "𐓘", .want_end = 4 },
        .{ .pattern = "(?i)𐲀", .text = "𐳀", .want_end = 4 },
        .{ .pattern = "(?i)[𑢠]", .text = "𑣀", .want_end = 4 },
        .{ .pattern = "a{0}b", .text = "b", .want_end = 1 },
        .{ .pattern = "(?x:a\\ b)", .text = "a b", .want_end = 3 },
        .{ .pattern = "(?x:[a b]+)", .text = "ab ", .want_end = 3 },
        .{ .pattern = "(?:a|bc){2}", .text = "abca", .want_end = 3 },
        .{ .pattern = "[[:ascii:]]+", .text = "AZ09", .want_end = 4 },
        .{ .pattern = "[[:blank:]]+", .text = " \t", .want_end = 2 },
        .{ .pattern = "[[:digit:]]+", .text = "१", .want_end = 3 },
        .{ .pattern = "(?D:[[:digit:]]+)", .text = "१", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:[[:digit:]]+)", .text = "१", .want_start = null, .want_end = null },
        .{ .pattern = "(?D:[[:^digit:]]+)", .text = "१", .want_end = 3 },
        .{ .pattern = "(?P:[[:^digit:]]+)", .text = "१", .want_end = 3 },
        .{ .pattern = "[[:alpha:]]+", .text = "é", .want_end = 2 },
        .{ .pattern = "(?P:[[:alpha:]]+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:[[:^alpha:]]+)", .text = "é", .want_end = 2 },
        .{ .pattern = "[[:word:]]+", .text = "é", .want_end = 2 },
        .{ .pattern = "(?W:[[:word:]]+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?W:[[:^word:]]+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?P:[[:^word:]]+)", .text = "é", .want_end = 2 },
        .{ .pattern = "(?W:[\\w]+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "(?D:[\\d]+)", .text = "१", .want_start = null, .want_end = null },
        .{ .pattern = "(?P:[\\p{Word}]+)", .text = "é", .want_start = null, .want_end = null },
        .{ .pattern = "[[:alnum:]]+", .text = "Az09!", .want_end = 4 },
        .{ .pattern = "[[:xdigit:]]+", .text = "09Af", .want_end = 4 },
        .{ .pattern = "[[:^digit:]]+", .text = "abc", .want_end = 3 },
        .{ .pattern = "[[:^alpha:]]+", .text = "123abc", .want_end = 3 },
        .{ .pattern = "[[:graph:]]+", .text = "!~\n", .want_end = 2 },
        .{ .pattern = "[[:print:]]+", .text = " !\n", .want_end = 2 },
        .{ .pattern = "[[:cntrl:]]+", .text = "\x00\x1f\x7f ", .want_end = 3 },
        .{ .pattern = "[[:^xdigit:]]+", .text = "G!0", .want_end = 2 },
        .{ .pattern = "[^\\n]+", .text = "ab\n", .want_end = 2 },
        .{ .pattern = "a(?=b)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "a(?!c)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "a(?!b)", .text = "ac", .want_end = 1 },
        .{ .pattern = "a(?!b)", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "(?<=ab)c", .text = "abc", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<!ab)c", .text = "xbc", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<=a|ab)c", .text = "abc", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<!a|ab)c", .text = "abc", .want_start = null, .want_end = null },
        .{ .pattern = "(?<=αβ)γ", .text = "αβγ", .start = 4, .want_start = 4, .want_end = 6 },
        .{ .pattern = "(?<=a+)b", .text = "aaab", .start = 3, .want_start = 3, .want_end = 4 },
        .{ .pattern = "(?<=a{2,3})b", .text = "aaab", .start = 3, .want_start = 3, .want_end = 4 },
        .{ .pattern = "(?<!a{2,3})b", .text = "aaab", .want_start = null, .want_end = null },
        .{ .pattern = "(?<=^)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?<!^)a", .text = "ba", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<=\\G)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?<=\\G)a", .text = "ba", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<!\\G)a", .text = "ba", .start = 1, .want_start = null, .want_end = null },
        .{ .pattern = "(?<=\\A)a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?<!\\A)a", .text = "ba", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<=a\\b)b", .text = "ab", .start = 1, .want_start = null, .want_end = null },
        .{ .pattern = "(?<=a\\B)b", .text = "ab", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<=\\ba)b", .text = "ab", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "(?<=\\p{Greek})β", .text = "αβ", .start = 2, .want_start = 2, .want_end = 4 },
        .{ .pattern = "(?<=\\p{Greek}+)β", .text = "ααβ", .start = 4, .want_start = 4, .want_end = 6 },
        .{ .pattern = "(?<=\\d{2})x", .text = "12x", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "(?<!\\d{2})x", .text = "1x", .start = 1, .want_start = 1, .want_end = 2 },
        .{ .pattern = "\\X", .text = "a", .want_end = 1 },
        .{ .pattern = "\\X", .text = "á", .want_end = 3 },
        .{ .pattern = "\\y\\X\\y", .text = "á", .want_end = 3 },
        .{ .pattern = "\\Y", .text = "á", .start = 1, .want_start = 1, .want_end = 1 },
        .{ .pattern = "\\y", .text = "á", .start = 3, .want_start = 3, .want_end = 3 },
        .{ .pattern = "(?~345)", .text = "12345678", .want_end = 2 },
        .{ .pattern = "(?~|345|\\d*)", .text = "12345678", .want_end = 2 },
        .{ .pattern = "a(?~|end|\\O*)end", .text = "abcend", .want_end = 6 },
        .{ .pattern = "(?~|345)\\O*", .text = "123345", .want_end = 3 },
        .{ .pattern = "(?~|345)\\O*(?~|)345", .text = "123345", .want_end = 6 },
        .{ .pattern = "a(?~end)end", .text = "abcend", .want_end = 6 },
        .{ .pattern = "(?~|345|[a-z]+|\\d*)", .text = "abc345", .want_end = 3 },
        .{ .pattern = "(?~|345)\\O*", .text = "123", .want_end = 3 },
        .{ .pattern = "(?~345)", .text = "345", .want_end = 0 },
        .{ .pattern = "a+?a", .text = "aaa", .want_end = 2 },
        .{ .pattern = "(a*)a", .text = "aaa", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(a*?)a", .text = "aaa", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 0 },
        .{ .pattern = "(a+)a", .text = "aaa", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(a+?)a", .text = "aaa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a{1,3})a", .text = "aaaa", .want_end = 4, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 3 },
        .{ .pattern = "(a{1,3}?)a", .text = "aaaa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a{,2})a", .text = "aaa", .want_end = 3, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 2 },
        .{ .pattern = "(a{,2}?)a", .text = "aaa", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 0 },
        .{ .pattern = "(a?)a", .text = "a", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 0 },
        .{ .pattern = "(a??)a", .text = "a", .want_end = 1, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 0 },
        .{ .pattern = "(a)?a", .text = "a", .want_end = 1, .want_capture_slot = 1, .want_capture_end = null },
        .{ .pattern = "(a)?a", .text = "aa", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(a|ab)b", .text = "ab", .want_end = 2, .want_capture_slot = 1, .want_capture_start = 0, .want_capture_end = 1 },
        .{ .pattern = "(?:ab|a)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?:ab|a)b", .text = "abb", .want_end = 3 },
        .{ .pattern = "(?>a*)a", .text = "aaa", .want_start = null, .want_end = null },
        .{ .pattern = "(?>a*)", .text = "aaa", .want_end = 3 },
        .{ .pattern = "(?>ab|a)b", .text = "ab", .want_start = null, .want_end = null },
        .{ .pattern = "(?>a|ab)b", .text = "ab", .want_end = 2 },
        .{ .pattern = "(?>a*+)a", .text = "aaa", .want_start = null, .want_end = null },
        .{ .pattern = "(?>a*+)b", .text = "aaab", .want_end = 4 },
        .{ .pattern = "(?~|end|(?:ab|a)*)end", .text = "aabend", .want_end = 6 },
        .{ .pattern = "(?>ab|a)(?~|end|\\O*)end", .text = "abend", .want_end = 5 },
        .{ .pattern = "(?:a?)*a", .text = "a", .want_end = 1 },
        .{ .pattern = "a?+a", .text = "a", .want_start = null, .want_end = null },
        .{ .pattern = "a?+a", .text = "aa", .want_end = 2 },
        .{ .pattern = "a*+a", .text = "aaa", .want_start = null, .want_end = null },
        .{ .pattern = "a++a", .text = "aaa", .want_start = null, .want_end = null },
        .{ .pattern = "a++a", .text = "aaaa", .want_start = null, .want_end = null },
        .{ .pattern = "a{2,}b", .text = "aaab", .want_end = 4 },
        .{ .pattern = "a??a", .text = "a", .want_end = 1 },
        .{ .pattern = "(?m:^b)", .text = "a\nb", .start = 2, .want_start = 2, .want_end = 3 },
        .{ .pattern = "a$", .text = "a\n", .want_end = 1 },
        .{ .pattern = "[[:ascii:]]+", .text = "A\x7f\x80", .want_end = 2 },
        .{ .pattern = "[[:alnum:]]+", .text = "Az09_", .want_end = 4 },
        .{ .pattern = "[[:blank:]]+", .text = " \t\n", .want_end = 2 },
        .{ .pattern = "[[:cntrl:]]+", .text = "\x00\x1f\x7f ", .want_end = 3 },
        .{ .pattern = "[[:graph:]]+", .text = "!~\n", .want_end = 2 },
        .{ .pattern = "[[:print:]]+", .text = " !\n", .want_end = 2 },
        .{ .pattern = "[[:punct:]]+", .text = "!/@[~a", .want_end = 4 },
        .{ .pattern = "[[:space:]]+", .text = " \t\nx", .want_end = 3 },
        .{ .pattern = "[[:word:]]+", .text = "a1_-", .want_end = 3 },
        .{ .pattern = "[[:xdigit:]]+", .text = "09AfG", .want_end = 4 },
        .{ .pattern = "[[:^xdigit:]]+", .text = "G!0", .want_end = 2 },
    };
    var scratch = @import("scratch.zig").VmScratch(128).init();

    for (cases) |case| {
        const program = try P.compile(case.pattern);
        var captures = [_]Capture{.{}} ** max_captures;
        const match = try program.matchAtCaptures(case.text, case.start, &scratch, &captures);
        if (case.want_end) |end| {
            const found = match orelse {
                std.debug.print("missing regex VM conformance match: {s} on {s} at {d}\n", .{ case.pattern, case.text, case.start });
                return error.TestExpectedEqual;
            };
            try std.testing.expectEqual(case.want_start.?, found.start);
            try std.testing.expectEqual(end, found.end);
            if (case.want_capture_slot != 0) {
                const capture = captures[case.want_capture_slot];
                if (case.want_capture_end) |capture_end| {
                    try std.testing.expect(capture.set);
                    try std.testing.expectEqual(case.want_capture_start.?, capture.start);
                    try std.testing.expectEqual(capture_end, capture.end);
                } else {
                    try std.testing.expect(!capture.set);
                }
            }
        } else {
            try std.testing.expectEqual(@as(?Match, null), match);
        }
    }
}
