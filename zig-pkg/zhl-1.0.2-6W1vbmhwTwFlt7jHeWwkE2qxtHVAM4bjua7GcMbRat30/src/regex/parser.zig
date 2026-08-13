const std = @import("std");
const regex_classes = @import("classes.zig");
const regex_class_parse = @import("class_parse.zig");
const regex_alt = @import("alt.zig");
const regex_escape = @import("escape.zig");
const regex_lowered = @import("lowered.zig");
const regex_match = @import("match.zig");
const regex_property = @import("property.zig");
const regex_repeat = @import("repeat.zig");
const regex_types = @import("types.zig");
pub const CompileError = error{ ProgramTooLarge, DanglingEscape, UnclosedClass, InvalidRange, UnsupportedRegex };
pub const MatchError = error{ RegexVmStackOverflow, RegexStepLimitExceeded };
pub const VmScratch = @import("scratch.zig").VmScratch;

pub const AtomKind = regex_types.AtomKind;
pub const Atom = regex_types.Atom;
pub const Quantifier = regex_types.Quantifier;
pub const Match = regex_types.Match;
pub const Capture = regex_types.Capture;
const max_lookahead_bytes = regex_types.max_lookahead_bytes;
const max_captures = regex_types.max_captures;
pub fn Program(comptime max_atoms: usize) type {
    return struct {
        const Self = @This();
        atoms: [max_atoms]Atom = undefined,
        count: usize = 0,
        anchor_start: bool = false,
        anchor_end: bool = false,
        absolute_start: bool = false,
        search_start_anchor: bool = false,
        pub fn compile(pattern: []const u8) CompileError!Self {
            @setEvalBranchQuota(10_000_000);
            var out = Self{};
            if (regex_lowered.classify(pattern)) |lowered| {
                var atom = Atom{ .kind = .lowered, .lowered_kind = lowered.kind };
                const lookahead = lowered.lookahead();
                atom.alt_count = lowered.alt_count;
                var alt_i: usize = 0;
                while (alt_i < lowered.alt_count) : (alt_i += 1) {
                    atom.alt_lens[alt_i] = lowered.alt_lens[alt_i];
                    @memcpy(atom.alt_bytes[alt_i][0..lowered.alt_lens[alt_i]], lowered.alt_bytes[alt_i][0..lowered.alt_lens[alt_i]]);
                }
                @memcpy(atom.alt_bytes[7][0..lookahead.len], lookahead);
                atom.alt_lens[7] = @intCast(lookahead.len);
                try out.appendAtom(atom);
                return out;
            }
            var i: usize = 0;
            var capture_count: u8 = 0;
            if (i < pattern.len and pattern[i] == '^') {
                out.anchor_start = true;
                i += 1;
            } else if (std.mem.startsWith(u8, pattern, "\\G") or std.mem.startsWith(u8, pattern, "\\A")) {
                out.anchor_start = true;
                out.absolute_start = pattern[1] == 'A';
                out.search_start_anchor = pattern[1] == 'G';
                i += 2;
            }
            while (i < pattern.len) {
                if (pattern[i] == '$' and i + 1 == pattern.len) {
                    out.anchor_end = true;
                    i += 1;
                    break;
                }
                if (isolatedSegmentFlagEnd(pattern, i)) |next| {
                    i = next;
                    continue;
                }
                var atom: Atom = undefined;
                switch (pattern[i]) {
                    '.' => {
                        atom = .{ .kind = .any };
                        i += 1;
                    },
                    '[' => atom = try parseClass(pattern, &i),
                    '(' => atom = if (i + 1 < pattern.len and pattern[i + 1] == '?')
                        if (regex_alt.isNamedCaptureStart(pattern, i))
                            try regex_alt.parseNamedLiteral(pattern, &i, &capture_count)
                        else if (regex_alt.isNonCapturingStart(pattern, i))
                            try regex_alt.parseNonCapturing(pattern, &i)
                        else if (regex_alt.isInlineFlagStart(pattern, i))
                            try regex_alt.parseInlineFlag(pattern, &i)
                        else
                            try parseLookaround(pattern, &i)
                    else
                        try regex_alt.parseLiteral(pattern, &i, &capture_count),
                    '\\' => {
                        i += 1;
                        if (i >= pattern.len) return error.DanglingEscape;
                        atom = switch (pattern[i]) {
                            'd' => .{ .kind = .digit },
                            'h' => .{ .kind = .hex },
                            'w' => .{ .kind = .word },
                            'W' => .{ .kind = .non_word },
                            's' => .{ .kind = .space },
                            'N' => .{ .kind = .any },
                            'O' => .{ .kind = .any_byte },
                            'R' => .{ .kind = .general_newline },
                            'X' => .{ .kind = .any_byte, .class_negated = true },
                            'y', 'Y' => .{ .kind = .text_segment_boundary, .class_negated = pattern[i] == 'Y' },
                            'S' => .{ .kind = .non_space },
                            'A' => .{ .kind = .absolute_start_anchor },
                            'G' => .{ .kind = .search_start_anchor },
                            'z' => .{ .kind = .absolute_end_anchor },
                            'Z' => .{ .kind = .final_newline_end_anchor },
                            'D', 'H' => blk: {
                                var class = Atom{ .kind = .byte_class, .class_negated = true, .class_scalar_high = true };
                                regex_classes.addEscape(&class.class_mask, regex_escape.asciiLower(pattern[i]));
                                break :blk class;
                            },
                            'b' => .{ .kind = .word_boundary },
                            'B' => .{ .kind = .non_word_boundary },
                            'm' => .{ .kind = .word_start },
                            'M' => blk: {
                                if (regex_escape.parseMeta(pattern, i, pattern.len)) |parsed| {
                                    i = parsed.end - 1;
                                    break :blk .{ .kind = .literal, .byte = parsed.byte };
                                }
                                break :blk .{ .kind = .word_end };
                            },
                            'p' => try regex_property.parseFastAtom(pattern, &i, false),
                            'P' => try regex_property.parseFastAtom(pattern, &i, true),
                            '1'...'9' => blk: {
                                const slot = pattern[i] - '0';
                                if (slot > capture_count) return error.UnsupportedRegex;
                                break :blk .{ .kind = .backref, .capture_slot = slot };
                            },
                            'x', 'o', 'u', 'c', 'C' => blk: {
                                const parsed = regex_escape.parseEscapedByte(pattern, i, pattern.len) orelse return error.UnsupportedRegex;
                                i = parsed.end - 1;
                                break :blk .{ .kind = .literal, .byte = parsed.byte };
                            },
                            '0' => blk: {
                                const parsed = regex_escape.parseOctal(pattern, i, pattern.len) orelse return error.UnsupportedRegex;
                                i = parsed.end - 1;
                                break :blk .{ .kind = .literal, .byte = parsed.byte };
                            },
                            else => if (regex_escape.isNonLiteral(pattern[i])) return error.UnsupportedRegex else .{ .kind = .literal, .byte = regex_escape.byte(pattern[i]) },
                        };
                        i += 1;
                    },
                    ')', '|', '}' => return error.UnsupportedRegex,
                    '*', '+', '?' => return error.UnsupportedRegex,
                    else => {
                        atom = .{ .kind = .literal, .byte = pattern[i] };
                        i += 1;
                    },
                }
                if (i < pattern.len) {
                    switch (pattern[i]) {
                        '?' => {
                            atom.quantifier = .zero_or_one;
                            i += 1;
                        },
                        '*' => {
                            atom.quantifier = .zero_or_more;
                            i += 1;
                        },
                        '+' => {
                            atom.quantifier = .one_or_more;
                            i += 1;
                        },
                        else => {},
                    }
                    if (atom.quantifier != .one and i < pattern.len) {
                        if (pattern[i] == '?') {
                            atom.lazy = true;
                            i += 1;
                        } else if (pattern[i] == '+') {
                            atom.possessive = true;
                            i += 1;
                        }
                    }
                }
                if (!atomAllowsQuantifier(atom) and atom.quantifier != .one) return error.UnsupportedRegex;
                if (i < pattern.len and pattern[i] == '{' and std.mem.indexOfScalar(u8, pattern[i + 1 ..], '}') != null) {
                    if (!atomAllowsQuantifier(atom) or atom.quantifier != .one) return error.UnsupportedRegex;
                    const repeat = try regex_repeat.parse(pattern, &i);
                    var options = RepeatOptions{};
                    if (i < pattern.len) {
                        if (pattern[i] == '+') {
                            i += 1;
                        } else if (pattern[i] == '?') {
                            if (repeat.min == repeat.max and !repeat.open) options.optional_exact = true else options.lazy = true;
                            i += 1;
                        }
                    }
                    try out.appendRepeat(atom, repeat, options);
                } else try out.appendAtom(atom);
            }
            return out;
        }
        fn appendAtom(self: *Self, atom: Atom) CompileError!void {
            if (self.count == max_atoms) return error.ProgramTooLarge;
            self.atoms[self.count] = atom;
            self.count += 1;
        }
        const RepeatOptions = struct { possessive: bool = false, lazy: bool = false, optional_exact: bool = false };
        fn appendRepeat(self: *Self, atom: Atom, repeat: regex_repeat.Repeat, options: RepeatOptions) CompileError!void {
            if (options.optional_exact) {
                if (repeat.min > std.math.maxInt(u8)) return error.UnsupportedRegex;
                try self.appendAtom(.{ .kind = .optional_exact_start, .byte = @intCast(repeat.min) });
            }
            var n: usize = 0;
            while (n < repeat.min) : (n += 1) try self.appendAtom(atom);
            if (repeat.open) {
                var tail = atom;
                tail.quantifier = .zero_or_more;
                tail.possessive = options.possessive;
                tail.lazy = options.lazy;
                try self.appendAtom(tail);
            } else {
                while (n < repeat.max) : (n += 1) {
                    var optional = atom;
                    optional.quantifier = .zero_or_one;
                    optional.possessive = options.possessive;
                    optional.lazy = options.lazy;
                    try self.appendAtom(optional);
                }
            }
        }
        pub fn find(self: *const Self, text: []const u8, start: usize, scratch: anytype) MatchError!?Match {
            if (self.absolute_start) {
                return if (start == 0) try self.matchAtSearchStart(text, 0, start, scratch) else null;
            }
            if (self.search_start_anchor) return try self.matchAtSearchStart(text, start, start, scratch);
            if (self.anchor_start) {
                var i = start;
                while (i <= text.len) : (i += 1) {
                    if (regex_escape.lineStartAnchorMatches(text, i))
                        if (try self.matchAtSearchStart(text, i, start, scratch)) |m| return m;
                }
                return null;
            }
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
        pub fn matchAtCaptures(self: *const Self, text: []const u8, start: usize, scratch: anytype, out: []Capture) MatchError!?Match {
            return try self.matchAtCapturesSearchStart(text, start, start, scratch, out);
        }
        pub fn matchAtCapturesSearchStart(self: *const Self, text: []const u8, start: usize, search_start: usize, scratch: anytype, out: []Capture) MatchError!?Match {
            var captures = [_]Capture{.{}} ** max_captures;
            const match = try self.matchAtWithCaptures(text, start, search_start, scratch, &captures);
            const n = @min(out.len, captures.len);
            @memcpy(out[0..n], captures[0..n]);
            return match;
        }
        fn matchAtSearchStart(self: *const Self, text: []const u8, start: usize, search_start: usize, scratch: anytype) MatchError!?Match {
            var captures = [_]Capture{.{}} ** max_captures;
            return try self.matchAtWithCaptures(text, start, search_start, scratch, &captures);
        }
        fn matchAtWithCaptures(
            self: *const Self,
            text: []const u8,
            start: usize,
            search_start: usize,
            scratch: anytype,
            captures: *[max_captures]Capture,
        ) MatchError!?Match {
            if (self.absolute_start and start != 0) return null;
            if (self.anchor_start) {
                if (self.search_start_anchor) {
                    if (start != search_start) return null;
                } else if (!regex_escape.lineStartAnchorMatches(text, start)) return null;
            }
            scratch.reset();
            var atom_i: usize = 0;
            var pos: usize = start;

            while (true) {
                try scratch.tick();
                if (atom_i == self.count) {
                    if (!self.anchor_end or regex_escape.lineEndAnchorMatches(text, pos)) {
                        return .{ .start = start, .end = pos };
                    }
                } else {
                    const atom = self.atoms[atom_i];
                    if (atom.kind == .optional_exact_start) {
                        try scratch.push(.{ .atom_i = atom_i + @as(usize, atom.byte) + 1, .pos = pos });
                        atom_i += 1;
                        continue;
                    }
                    switch (atom.quantifier) {
                        .one => {
                            if (matchAtom(atom, text, pos, search_start, captures)) |next| {
                                pos = next;
                                atom_i += 1;
                                continue;
                            }
                        },
                        .zero_or_one => {
                            if (atom.possessive) {
                                if (matchAtom(atom, text, pos, search_start, captures)) |next| pos = next;
                                atom_i += 1;
                                continue;
                            }
                            if (atom.lazy) {
                                if (matchAtom(atom, text, pos, search_start, captures)) |next| try scratch.push(.{ .atom_i = atom_i + 1, .pos = next });
                                atom_i += 1;
                                continue;
                            }
                            try scratch.push(.{ .atom_i = atom_i + 1, .pos = pos });
                            if (matchAtom(atom, text, pos, search_start, captures)) |next| {
                                pos = next;
                                atom_i += 1;
                                continue;
                            }
                            atom_i += 1;
                            continue;
                        },
                        .zero_or_more => {
                            if (atom.possessive) {
                                pos = consumeRun(atom, text, pos, search_start, captures);
                                atom_i += 1;
                                continue;
                            }
                            if (atom.lazy) {
                                if (matchAtom(atom, text, pos, search_start, captures)) |next| try scratch.push(.{ .atom_i = atom_i, .pos = next });
                                atom_i += 1;
                                continue;
                            }
                            const max = consumeRun(atom, text, pos, search_start, captures);
                            try pushGreedyBacktracks(atom, text, pos, max, search_start, captures, scratch, atom_i + 1);
                            pos = max;
                            atom_i += 1;
                            continue;
                        },
                        .one_or_more => {
                            if (matchAtom(atom, text, pos, search_start, captures)) |first| {
                                pos = first;
                                if (atom.possessive) {
                                    pos = consumeRun(atom, text, pos, search_start, captures);
                                    atom_i += 1;
                                    continue;
                                }
                                if (atom.lazy) {
                                    if (matchAtom(atom, text, pos, search_start, captures)) |next| try scratch.push(.{ .atom_i = atom_i, .pos = next });
                                    atom_i += 1;
                                    continue;
                                }
                                const max = consumeRun(atom, text, pos, search_start, captures);
                                try pushGreedyBacktracks(atom, text, pos, max, search_start, captures, scratch, atom_i + 1);
                                pos = max;
                                atom_i += 1;
                                continue;
                            }
                        },
                    }
                }

                const frame = scratch.pop() orelse return null;
                atom_i = frame.atom_i;
                pos = frame.pos;
            }
        }
    };
}

fn consumeRun(atom: Atom, text: []const u8, start: usize, search_start: usize, captures: *[max_captures]Capture) usize {
    var pos = start;
    while (matchAtom(atom, text, pos, search_start, captures)) |next| {
        if (next == pos) break;
        pos = next;
    }
    return pos;
}

fn pushGreedyBacktracks(atom: Atom, text: []const u8, start: usize, max: usize, search_start: usize, captures: *[max_captures]Capture, scratch: anytype, next_atom_i: usize) MatchError!void {
    const saved = captures.*;
    defer captures.* = saved;
    try scratch.push(.{ .atom_i = next_atom_i, .pos = start });
    var pos = start;
    while (matchAtom(atom, text, pos, search_start, captures)) |next| {
        if (next <= pos or next >= max) break;
        try scratch.push(.{ .atom_i = next_atom_i, .pos = next });
        pos = next;
    }
}

fn matchAtom(atom: Atom, text: []const u8, pos: usize, search_start: usize, captures: *[max_captures]Capture) ?usize {
    if (atom.kind == .literal_alt or atom.kind == .capture_alt) {
        const next = regex_alt.match(atom, text, pos) orelse return null;
        if (atom.kind == .capture_alt) {
            captures[atom.capture_slot] = .{ .start = pos, .end = next, .set = true };
        }
        return next;
    }
    if (atom.kind == .backref) return matchBackref(atom, text, pos, captures);
    if (atom.kind == .lowered) return regex_lowered.match(atom.lowered_kind, atom.alt_bytes, atom.alt_lens, atom.alt_count, atom.alt_bytes[7][0..atom.alt_lens[7]], text, pos, captures);
    if (atom.kind == .general_newline) return regex_match.generalNewline(text, pos);
    if (atom.kind == .word) return regex_match.wordAt(text, pos);
    if (atom.kind == .non_word) return if (pos < text.len and regex_match.wordAt(text, pos) == null) regex_match.scalarEnd(text, pos) else null;
    if (atom.kind == .space) return regex_match.spaceAt(text, pos);
    if (atom.kind == .non_space) return if (pos < text.len and regex_match.spaceAt(text, pos) == null) regex_match.scalarEnd(text, pos) else null;
    if (atom.kind == .any) return if (pos < text.len and !regex_match.dotExcludedAt(text, pos)) regex_match.scalarEnd(text, pos) else null;
    if (atom.kind == .any_byte and !atom.class_negated) return if (pos < text.len) regex_match.scalarEnd(text, pos) else null;
    if (atom.kind == .any_byte and atom.class_negated) return regex_match.textSegment(text, pos);
    if (atom.kind == .byte_class) return matchByteClass(atom, text, pos);
    if (!atomConsumesByte(atom)) {
        return if (matchZeroWidth(atom, text, pos, search_start)) pos else null;
    }
    return if (matchOne(atom, text, pos)) pos + 1 else null;
}

fn atomConsumesByte(atom: Atom) bool {
    return switch (atom.kind) {
        .word_boundary,
        .non_word_boundary,
        .absolute_start_anchor,
        .search_start_anchor,
        .absolute_end_anchor,
        .final_newline_end_anchor,
        .word_start,
        .word_end,
        .text_segment_boundary,
        .positive_lookahead,
        .negative_lookahead,
        .positive_lookbehind,
        .negative_lookbehind,
        .optional_exact_start,
        => false,
        .lowered => regex_lowered.consumes(atom.lowered_kind),
        else => true,
    };
}

fn atomAllowsQuantifier(atom: Atom) bool {
    return atomConsumesByte(atom) and atom.kind != .backref;
}

fn isolatedSegmentFlagEnd(pattern: []const u8, start: usize) ?usize {
    if (start + 1 >= pattern.len or pattern[start] != '(' or pattern[start + 1] != '?') return null;
    const close = regex_escape.flagRunEnd(pattern, start + 2, pattern.len, ')') orelse return null;
    var i = start + 2;
    while (i < close) {
        const next = regex_escape.flagTokenEnd(pattern, i, close) orelse return null;
        if (pattern[i] != 'y' or i + 3 >= close or pattern[i + 1] != '{' or
            (pattern[i + 2] != 'g' and pattern[i + 2] != 'w') or pattern[i + 3] != '}')
            return null;
        i = next;
    }
    return close + 1;
}

fn matchZeroWidth(atom: Atom, text: []const u8, pos: usize, search_start: usize) bool {
    const lookahead = atom.lookahead_bytes[0..atom.lookahead_len];
    return switch (atom.kind) {
        .word_boundary => regex_match.wordBoundary(text, pos),
        .non_word_boundary => !regex_match.wordBoundary(text, pos),
        .absolute_start_anchor => pos == 0,
        .search_start_anchor => pos == search_start,
        .absolute_end_anchor => pos == text.len,
        .final_newline_end_anchor => regex_escape.endAnchorMatches(text, pos, true),
        .word_start => regex_match.wordStart(text, pos),
        .word_end => regex_match.wordEnd(text, pos),
        .text_segment_boundary => regex_match.textSegmentBoundary(text, pos) != atom.class_negated,
        .positive_lookahead => if (atom.byte == '$') regex_escape.lineEndAnchorMatches(text, pos) else if (atom.byte == 'S') pos < text.len and regex_match.spaceAt(text, pos) == null else std.mem.startsWith(u8, text[pos..], lookahead),
        .negative_lookahead => if (atom.byte == '$') !regex_escape.lineEndAnchorMatches(text, pos) else if (atom.byte == 'S') pos >= text.len or regex_match.spaceAt(text, pos) != null else !std.mem.startsWith(u8, text[pos..], lookahead),
        .positive_lookbehind => if (atom.byte == 'S') pos > 0 and !matchOne(.{ .kind = .space }, text, pos - 1) else pos >= lookahead.len and std.mem.eql(u8, text[pos - lookahead.len .. pos], lookahead),
        .negative_lookbehind => if (atom.byte == 'S') pos == 0 or matchOne(.{ .kind = .space }, text, pos - 1) else pos < lookahead.len or !std.mem.eql(u8, text[pos - lookahead.len .. pos], lookahead),
        else => false,
    };
}

fn matchOne(atom: Atom, text: []const u8, pos: usize) bool {
    if (pos >= text.len) return false;
    const byte = text[pos];
    return switch (atom.kind) {
        .literal => byte == atom.byte,
        .any => !regex_match.dotExcludedAt(text, pos),
        .any_byte => true,
        .digit => byte >= '0' and byte <= '9',
        .hex => std.ascii.isHex(byte),
        .space => regex_match.spaceAt(text, pos) != null,
        .non_space => regex_match.spaceAt(text, pos) == null,
        .byte_class => regex_classes.contains(atom.class_mask, byte) != atom.class_negated,
        .word,
        .non_word,
        .word_boundary,
        .non_word_boundary,
        .absolute_start_anchor,
        .search_start_anchor,
        .absolute_end_anchor,
        .final_newline_end_anchor,
        .positive_lookahead,
        .negative_lookahead,
        .positive_lookbehind,
        .negative_lookbehind,
        .word_start,
        .word_end,
        .text_segment_boundary,
        .optional_exact_start,
        .literal_alt,
        .capture_alt,
        .backref,
        .general_newline,
        .lowered,
        => false,
    };
}

fn matchByteClass(atom: Atom, text: []const u8, pos: usize) ?usize {
    if (pos >= text.len) return null;
    if (atom.class_scalar_high and text[pos] >= 0x80) {
        if (regex_match.scalarEndIfStart(text, pos)) |next| return next;
    }
    if (regex_classes.contains(atom.class_mask, text[pos]) == atom.class_negated) return null;
    return pos + 1;
}

fn parseLookaround(pattern: []const u8, index: *usize) CompileError!Atom {
    if (index.* + 3 >= pattern.len or pattern[index.* + 1] != '?') return error.UnsupportedRegex;
    var kind: AtomKind = undefined;
    if (pattern[index.* + 2] == '<') {
        if (index.* + 4 >= pattern.len) return error.UnsupportedRegex;
        kind = switch (pattern[index.* + 3]) {
            '=' => .positive_lookbehind,
            '!' => .negative_lookbehind,
            else => return error.UnsupportedRegex,
        };
        index.* += 4;
    } else {
        kind = switch (pattern[index.* + 2]) {
            '=' => .positive_lookahead,
            '!' => .negative_lookahead,
            else => return error.UnsupportedRegex,
        };
        index.* += 3;
    }
    var atom = Atom{ .kind = kind };
    while (index.* < pattern.len and pattern[index.*] != ')') {
        if (atom.lookahead_len == max_lookahead_bytes) return error.UnsupportedRegex;
        if (pattern[index.*] == '$' and index.* + 1 < pattern.len and pattern[index.* + 1] == ')') {
            atom.byte = '$';
            index.* += 1;
            break;
        }
        if (pattern[index.*] == '\\' and index.* + 2 < pattern.len and pattern[index.* + 1] == 'S' and pattern[index.* + 2] == ')') {
            atom.byte = 'S';
            index.* += 2;
            break;
        }
        const byte = if (pattern[index.*] == '\\') blk: {
            index.* += 1;
            if (index.* >= pattern.len) return error.DanglingEscape;
            if (regex_escape.parseEscapedByte(pattern, index.*, pattern.len)) |parsed| {
                index.* = parsed.end - 1;
                break :blk parsed.byte;
            }
            if (regex_escape.isClass(pattern[index.*]) or regex_escape.isNonLiteral(pattern[index.*]) or pattern[index.*] == 'b' or pattern[index.*] == 'B' or pattern[index.*] == 'p' or pattern[index.*] == 'P')
                return error.UnsupportedRegex;
            if (pattern[index.*] == '0') return error.UnsupportedRegex;
            break :blk regex_escape.byte(pattern[index.*]);
        } else if (regex_escape.isMeta(pattern[index.*])) return error.UnsupportedRegex else pattern[index.*];
        atom.lookahead_bytes[atom.lookahead_len] = byte;
        atom.lookahead_len += 1;
        index.* += 1;
    }
    if (index.* >= pattern.len or pattern[index.*] != ')' or (atom.lookahead_len == 0 and atom.byte == 0)) return error.UnsupportedRegex;
    index.* += 1;
    return atom;
}

fn matchBackref(atom: Atom, text: []const u8, pos: usize, captures: *const [max_captures]Capture) ?usize {
    const capture = captures[atom.capture_slot];
    if (!capture.set) return null;
    const value = text[capture.start..capture.end];
    if (std.mem.startsWith(u8, text[pos..], value)) return pos + value.len;
    return null;
}

fn parseClass(pattern: []const u8, index: *usize) CompileError!Atom {
    var atom = Atom{ .kind = .byte_class };
    const parsed = try regex_class_parse.parseWithOptions(pattern, index.*, .{
        .byte_posix = true,
        .ascii_unicode_properties = true,
    });
    if (parsed.codepoint_count != 0 or parsed.range_count != 0) return error.UnsupportedRegex;
    atom.class_mask = parsed.mask;
    atom.class_scalar_high = parsed.scalar_high;
    index.* = parsed.end + 1;
    return atom;
}

test "regex VM matches bounded quantifiers without allocation" {
    const P = Program(16);
    const p = try P.compile("^a+b$");
    const exact = try P.compile("a{3}");
    const range = try P.compile("ab{1,3}c");
    const open = try P.compile("ab{2,}c");
    const omitted_min = try P.compile("a{,2}b");
    const literal_left_brace = try P.compile("{");
    const literal_unclosed_bound = try P.compile("a{2,3");
    var scratch = VmScratch(16).init();

    const m = (try p.find("aaab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 0), m.start);
    try std.testing.expectEqual(@as(usize, 4), m.end);
    try std.testing.expect(try p.find("aaac", 0, &scratch) == null);

    try std.testing.expect((try exact.find("xxaaa", 0, &scratch)) != null);
    try std.testing.expect((try range.find("xac abbbc", 0, &scratch)) != null);
    try std.testing.expect((try range.find("abbbbc", 0, &scratch)) == null);
    try std.testing.expect((try open.find("abbc", 0, &scratch)) != null);
    try std.testing.expect((try omitted_min.find("b", 0, &scratch)) != null);
    try std.testing.expectEqual(@as(usize, 3), (try omitted_min.matchAt("aab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try omitted_min.matchAt("aaab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try literal_left_brace.matchAt("{", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try literal_unclosed_bound.matchAt("a{2,3", 0, &scratch)).?.end);
    try std.testing.expectError(error.InvalidRange, P.compile("a{3,2}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("a{,}"));
}

test "fast regex rejects class escapes inside literal alternations" {
    const P = Program(16);

    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?:\\s)"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?S:\\p{Space})"));
}

test "regex VM enforces scratch step limit" {
    const P = Program(16);
    const p = try P.compile("a*b");
    var scratch = VmScratch(16).init();
    scratch.step_limit = 1;

    try std.testing.expectError(error.RegexStepLimitExceeded, p.find("aaaab", 0, &scratch));
}

test "regex VM handles \\G search-start anchor" {
    const P = Program(16);
    const p = try P.compile("\\Gabc");
    const boolean = try P.compile("\\G(true|false)");
    const line_start = try P.compile("^abc");
    const line_end = try P.compile("abc$");
    var scratch = VmScratch(16).init();
    var captures = [_]Capture{.{}} ** max_captures;

    try std.testing.expect(try p.find("xxabc", 0, &scratch) == null);
    const m = (try p.find("xxabc", 2, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 5), m.end);
    try std.testing.expect(try line_start.find("xxabc", 2, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 6), (try line_start.find("xx\nabc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 6), (try line_start.find("xx\nabc", 3, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try line_end.find("abc\nx", 0, &scratch)).?.end);
    try std.testing.expect(try line_end.find("abc\r\nx", 0, &scratch) == null);
    try std.testing.expect(try line_end.find("abc\xe2\x80\xa8x", 0, &scratch) == null);
    try std.testing.expect(try line_end.find("abcx", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 6), (try boolean.matchAtCaptures("x true", 2, &scratch, &captures)).?.end);
    try std.testing.expectEqual(@as(usize, 2), captures[1].start);
    try std.testing.expectEqual(@as(usize, 6), captures[1].end);
}

test "regex VM handles Oniguruma absolute anchors" {
    const P = Program(16);
    const lower = try P.compile("\\Aabc\\z");
    const upper = try P.compile("\\Aabc\\Z");
    const upper_after_cr = try P.compile("\\Aabc\\r\\Z");
    const lower_after_a = try P.compile("a\\z");
    const upper_after_a = try P.compile("a\\Z");
    const absolute_after_optional = try P.compile("a?\\A");
    const search_start_after_a = try P.compile("a\\G");
    const absolute_end_before_a = try P.compile("\\za");
    const final_line_end_then_newline = try P.compile("\\Z\\n");
    var scratch = VmScratch(16).init();
    var captures = [_]Capture{.{}} ** max_captures;

    try std.testing.expect((try lower.find("abc", 0, &scratch)).?.end == 3);
    try std.testing.expect(try lower.find("xabc", 1, &scratch) == null);
    try std.testing.expect(try lower.find("abcd", 0, &scratch) == null);
    try std.testing.expect(try lower.find("abc\n", 0, &scratch) == null);
    try std.testing.expect((try upper.find("abc", 0, &scratch)).?.end == 3);
    try std.testing.expect((try upper.find("abc\n", 0, &scratch)).?.end == 3);
    try std.testing.expect(try upper.find("abc\r\n", 0, &scratch) == null);
    try std.testing.expect(try upper.find("abc\x85", 0, &scratch) == null);
    try std.testing.expect(try upper.find("abc\xe2\x80\xa8", 0, &scratch) == null);
    try std.testing.expect((try upper_after_cr.find("abc\r\n", 0, &scratch)).?.end == 4);
    try std.testing.expect(try upper.find("abc\n\n", 0, &scratch) == null);
    try std.testing.expect((try lower_after_a.find("a", 0, &scratch)).?.end == 1);
    try std.testing.expect(try lower_after_a.find("a\n", 0, &scratch) == null);
    try std.testing.expect((try upper_after_a.find("a\n", 0, &scratch)).?.end == 1);
    try std.testing.expectEqual(@as(usize, 0), (try absolute_after_optional.matchAt("", 0, &scratch)).?.end);
    try std.testing.expect(try search_start_after_a.find("a", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 1), (try search_start_after_a.matchAtCapturesSearchStart("a", 0, 1, &scratch, &captures)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try absolute_end_before_a.find("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try final_line_end_then_newline.find("a\n", 0, &scratch)).?.end);
}

test "regex VM decodes escaped control bytes" {
    const P = Program(16);
    const newline = try P.compile("a\\nb");
    const tab_alt = try P.compile("(a\\tb)");
    const class = try P.compile("[\\t-\\n]");
    var scratch = VmScratch(32).init();

    const n = (try newline.find("x a\nb", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), n.start);
    try std.testing.expectEqual(@as(usize, 5), n.end);

    const t = (try tab_alt.find("a\tb", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 0), t.start);
    try std.testing.expectEqual(@as(usize, 3), t.end);

    const c = (try class.find("x\t", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), c.start);
    try std.testing.expectEqual(@as(usize, 2), c.end);
}

test "regex VM handles Oniguruma newline escapes" {
    const P = Program(16);
    const dot = try P.compile(".+");
    const no_line_break = try P.compile("\\N+");
    const any_byte = try P.compile("\\O+");
    const newline = try P.compile("a\\Rb");
    const segment = try P.compile("\\y\\X\\y");
    const inner_segment = try P.compile("\\r\\Y\\n");
    const no_inner_boundary = try P.compile("\\r\\y\\n");
    var scratch = VmScratch(32).init();

    try std.testing.expectEqual(@as(usize, 4), (try dot.matchAt("abc\r", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\r", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\x0b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try dot.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try dot.matchAt("\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try dot.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try no_line_break.matchAt("abc\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try no_line_break.matchAt("\n", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try no_line_break.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try no_line_break.matchAt("\xe2\x80\xa9", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try no_line_break.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try any_byte.matchAt("\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try any_byte.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try any_byte.matchAt("😀", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try newline.matchAt("a\r\nb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try newline.matchAt("a\nb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try newline.matchAt("a\x85b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try newline.matchAt("a\xe2\x80\xa8b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 5), (try newline.matchAt("a\xe2\x80\xa9b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try segment.matchAt("\r\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try segment.matchAt("a", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try inner_segment.matchAt("\r\n", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try no_inner_boundary.matchAt("\r\n", 0, &scratch));
}

test "regex VM handles Oniguruma control escapes" {
    const P = Program(16);
    const controls = try P.compile("\\a[\\b]\\e\\f\\v");
    const whitespace = try P.compile("\\s+");
    const class_whitespace = try P.compile("[\\s]+");
    var scratch = VmScratch(32).init();

    try std.testing.expectError(error.UnsupportedRegex, P.compile("(\\b)"));
    try std.testing.expectEqual(@as(usize, 5), (try controls.matchAt("\x07\x08\x1b\x0c\x0b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try whitespace.matchAt("\x0b\x0c", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class_whitespace.matchAt("\x0b\x0c", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try whitespace.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try class_whitespace.matchAt("\x85", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try whitespace.matchAt("\xe2\x80\xa8", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try whitespace.matchAt("\xe2\x80\xa9", 0, &scratch)).?.end);
}

test "fast regex rejects Oniguruma keep escape" {
    const P = Program(16);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("foo\\Kbar"));
}

test "regex VM handles Oniguruma hex byte escapes" {
    const P = Program(16);
    const literal = try P.compile("\\x41\\x{42}");
    const class = try P.compile("[\\x00-\\x08]+");
    const codepoint = try P.compile("\\o{101}\\u0042");
    const codepoint_class = try P.compile("[\\o{100}-\\u0042]+");
    const octal = try P.compile("\\010[\\011]");
    const control = try P.compile("\\cA[\\C-B]");
    const meta = try P.compile("\\M-a[\\M-b]");
    const meta_control = try P.compile("\\M-\\C-c[\\M-\\C-d]");
    var scratch = VmScratch(32).init();

    try std.testing.expectEqual(@as(usize, 2), (try literal.matchAt("AB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class.matchAt("\x00\x08\t", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class.matchAt("\t", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try codepoint.matchAt("AB", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try codepoint_class.matchAt("@ABc", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try octal.matchAt("\x08\t", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try control.matchAt("\x01\x02", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try meta.matchAt("\xe1\xe2", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try meta_control.matchAt("\x83\x84", 0, &scratch)).?.end);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\x{100}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\o{400}"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\u0100"));
    try std.testing.expectError(error.UnsupportedRegex, P.compile("[\\x{200C}]"));
}

test "regex VM backtracks greedy star" {
    const P = Program(16);
    const p = try P.compile("a.*b");
    const plus = try P.compile("a.+b");
    var scratch = VmScratch(32).init();

    const m = (try p.find("xxa123bzz", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);
    try std.testing.expectEqual(@as(usize, 4), (try p.matchAt("abbb", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 4), (try plus.matchAt("abbb", 0, &scratch)).?.end);
}

test "regex VM handles lazy quantifiers" {
    const P = Program(16);
    const star = try P.compile("a.*?b");
    const plus = try P.compile("a.+?b");
    const maybe = try P.compile("ab??c");
    var scratch = VmScratch(32).init();

    const s = (try star.find("xa123b456b", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), s.start);
    try std.testing.expectEqual(@as(usize, 6), s.end);

    const p = (try plus.find("xa123b456b", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 6), p.end);

    const m = (try maybe.find("xac abc", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), m.start);
    try std.testing.expectEqual(@as(usize, 3), m.end);
}

test "regex accepts possessive quantifier syntax" {
    const P = Program(16);
    const spaces = try P.compile("[\\t ]++x");
    const maybe = try P.compile("ab?+c");
    const star = try P.compile("a*+a");
    const optional = try P.compile("a?+a");
    const bounded_plus = try P.compile("a{1,2}+a");
    const open_plus = try P.compile("a{1,}+a");
    const omitted_plus = try P.compile("a{,2}+a");
    var scratch = VmScratch(32).init();

    try std.testing.expect((try spaces.find("  x", 0, &scratch)) != null);
    try std.testing.expect((try maybe.find("abc", 0, &scratch)) != null);
    try std.testing.expectEqual(@as(?Match, null), try star.matchAt("aaa", 0, &scratch));
    try std.testing.expectEqual(@as(?Match, null), try optional.matchAt("a", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try bounded_plus.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try bounded_plus.matchAt("aaa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try open_plus.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try omitted_plus.matchAt("aa", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try omitted_plus.matchAt("aaa", 0, &scratch)).?.end);
}

test "fast regex handles Oniguruma bounded question suffixes" {
    const P = Program(16);
    const omitted_min = try P.compile("a{,2}b");
    const exact_optional = try P.compile("a{2}?b");
    const bounded_lazy = try P.compile("a{1,3}?a");
    var scratch = VmScratch(32).init();

    try std.testing.expectEqual(@as(usize, 1), (try omitted_min.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try omitted_min.matchAt("aab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try omitted_min.matchAt("aaab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try exact_optional.matchAt("b", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try exact_optional.matchAt("aab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try exact_optional.matchAt("ab", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 2), (try bounded_lazy.matchAt("aaa", 0, &scratch)).?.end);
}

test "regex accepts Oniguruma ASCII option flags" {
    const P = Program(16);
    const ascii_flags = try P.compile("(?WDSPy:ab)");
    const segment_flags = try P.compile("(?y{g}:ab)");
    const word_segment_flags = try P.compile("(?y{w}:ab)");
    const isolated_segment_flags = try P.compile("(?y{g})ab");
    const isolated_word_segment_flags = try P.compile("(?y{w})ab");
    var scratch = VmScratch(32).init();

    try std.testing.expectEqual(@as(usize, 2), (try ascii_flags.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try segment_flags.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try word_segment_flags.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try isolated_segment_flags.matchAt("ab", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try isolated_word_segment_flags.matchAt("ab", 0, &scratch)).?.end);
}

test "regex VM handles class ranges and negated classes" {
    const P = Program(16);
    const ident = try P.compile("@[A-Za-z_][A-Za-z0-9_]*");
    var scratch = VmScratch(32).init();

    const ident_match = (try ident.find("call @import now", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 5), ident_match.start);
    try std.testing.expectEqual(@as(usize, 12), ident_match.end);

    const quoted = try P.compile("\"[^\"\\\\]*\"");
    const quoted_match = (try quoted.find("x \"hello\" y", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), quoted_match.start);
    try std.testing.expectEqual(@as(usize, 9), quoted_match.end);

    const consonants = try P.compile("[a-z&&[^aeiou]]+");
    const consonants_match = (try consonants.find("aeiobcdu", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 4), consonants_match.start);
    try std.testing.expectEqual(@as(usize, 7), consonants_match.end);

    const nested = try P.compile("[[a-c][x-z]]+");
    try std.testing.expectEqual(@as(usize, 6), (try nested.matchAt("abcxyzm", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try nested.matchAt("m", 0, &scratch));
}

test "regex VM handles POSIX bracket classes" {
    const P = Program(16);
    const ident = try P.compile("[[:alpha:]_][[:alnum:]_]*");
    const hex = try P.compile("[[:xdigit:]]+");
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
    var scratch = VmScratch(32).init();

    const i = (try ident.find("1 _abc42", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), i.start);
    try std.testing.expectEqual(@as(usize, 8), i.end);

    const h = (try hex.find("xx 7fAF zz", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 3), h.start);
    try std.testing.expectEqual(@as(usize, 7), h.end);
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
    try std.testing.expectError(error.UnsupportedRegex, P.compile("[[:emoji:]]"));
}

test "regex VM handles Oniguruma hex digit escape" {
    const P = Program(16);
    const scalar = try P.compile("\\h+");
    const class = try P.compile("[_\\h]+");
    const non_scalar = try P.compile("\\H+");
    const non_class = try P.compile("[\\H]+");
    var scratch = VmScratch(32).init();

    const s = (try scalar.find("x 7fAF", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), s.start);
    try std.testing.expectEqual(@as(usize, 6), s.end);

    const c = (try class.find("x _7f", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), c.start);
    try std.testing.expectEqual(@as(usize, 5), c.end);
    const ns = (try non_scalar.find("7f-z", 0, &scratch)).?;
    const nc = (try non_class.find("7f-z", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), ns.start);
    try std.testing.expectEqual(@as(usize, 4), ns.end);
    try std.testing.expectEqual(@as(usize, 2), nc.start);
    try std.testing.expectEqual(@as(usize, 4), nc.end);
}

test "regex VM handles non-space escape and literal close bracket" {
    const P = Program(16);
    const non_space = try P.compile("\\S+");
    const class_non_space = try P.compile("[\\S]+");
    const non_digit = try P.compile("\\D+");
    const class_non_digit = try P.compile("[\\D]+");
    const non_word = try P.compile("\\W+");
    const class_non_word = try P.compile("[\\W]+");
    const close_brackets = try P.compile("]]");
    var scratch = VmScratch(32).init();

    const s = (try non_space.find("  word ", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), s.start);
    try std.testing.expectEqual(@as(usize, 6), s.end);
    try std.testing.expect((try class_non_space.find("  word ", 0, &scratch)).?.start == 2);
    try std.testing.expect(try non_space.matchAt("\x85", 0, &scratch) == null);
    try std.testing.expect(try non_space.matchAt("\xe2\x80\xa8", 0, &scratch) == null);
    try std.testing.expectEqual(@as(usize, 2), (try non_space.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expect(try class_non_space.matchAt("\x85", 0, &scratch) == null);
    const nd = (try non_digit.find("12-ab", 0, &scratch)).?;
    const cnd = (try class_non_digit.find("12-ab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), nd.start);
    try std.testing.expectEqual(@as(usize, 5), nd.end);
    try std.testing.expectEqual(@as(usize, 2), cnd.start);
    try std.testing.expectEqual(@as(usize, 5), cnd.end);
    try std.testing.expectEqual(@as(usize, 2), (try non_digit.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class_non_digit.matchAt("é", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try non_word.find("ab- ", 0, &scratch)).?.start);
    try std.testing.expectEqual(@as(?Match, null), try non_word.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try class_non_word.find("ab- ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_non_word.matchAt("é", 0, &scratch));
    try std.testing.expect((try close_brackets.find("x ]] y", 0, &scratch)).?.start == 2);
}

test "regex VM handles ASCII Unicode property classes" {
    const P = Program(64);
    const letters = try P.compile("\\p{L}+");
    const ident = try P.compile("[\\p{L}_][\\p{Word}]*");
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
    const not_number = try P.compile("\\P{N}+");
    const alphabetic = try P.compile("[\\p{Alphabetic}\\p{N}]+");
    const cased_letter = try P.compile("[\\p{LC}\\p{Cased_Letter}]+");
    const letter_subcategories = try P.compile("[\\p{Lt}\\p{Lm}\\p{Lo}]+");
    const math_symbols = try P.compile("[\\p{Sm}]+");
    const word_property = try P.compile("\\p{Word}+");
    const inverse_word_property = try P.compile("\\P{Word}+");
    const class_word_property = try P.compile("[\\p{Word}]+");
    const class_inverse_word_property = try P.compile("[\\P{Word}]+");
    var scratch = VmScratch(32).init();

    const word = (try letters.find("123 abc", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 4), word.start);
    try std.testing.expectEqual(@as(usize, 7), word.end);
    try std.testing.expect((try ident.find("_abc42", 0, &scratch)) != null);
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
    try std.testing.expectEqual(@as(usize, 4), (try alphabetic.matchAt("Ab12!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try cased_letter.matchAt("AbC1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try letter_subcategories.matchAt("AbC1", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try math_symbols.matchAt("+<=", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try word_property.matchAt("é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try inverse_word_property.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try inverse_word_property.matchAt("!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 2), (try class_word_property.matchAt("é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(?Match, null), try class_inverse_word_property.matchAt("é", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 1), (try class_inverse_word_property.matchAt("!", 0, &scratch)).?.end);
    try std.testing.expect((try not_number.find("123 abc", 0, &scratch)).?.start == 3);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\p{Emoji}"));
}

test "regex VM handles word boundaries" {
    const P = Program(16);
    const word = try P.compile("\\bif\\b");
    var scratch = VmScratch(32).init();

    const m = (try word.find("diff if iff", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 5), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);

    const non_boundary = try P.compile("\\Bif");
    const n = (try non_boundary.find("diff if", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), n.start);
    try std.testing.expectEqual(@as(usize, 3), n.end);

    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\b*"));
}

test "regex VM handles fixed literal lookahead" {
    const P = Program(16);
    const positive = try P.compile("a(?=b)");
    const negative = try P.compile("a(?!b)");
    var scratch = VmScratch(32).init();

    const yes = (try positive.find("xab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), yes.start);
    try std.testing.expectEqual(@as(usize, 2), yes.end);
    try std.testing.expect(try positive.find("xac", 0, &scratch) == null);

    const no = (try negative.find("xac", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 1), no.start);
    try std.testing.expectEqual(@as(usize, 2), no.end);
    try std.testing.expect(try negative.find("xab", 0, &scratch) == null);
}

test "regex VM handles shorthand and anchor lookaround" {
    const P = Program(16);
    const non_space = try P.compile("(?=\\S)a");
    const end = try P.compile("a(?=$)");
    const not_non_space = try P.compile("(?!\\S) ");
    const behind_non_space = try P.compile("(?<=\\S)b");
    var scratch = VmScratch(32).init();

    try std.testing.expect((try non_space.matchAt("a", 0, &scratch)) != null);
    try std.testing.expect(try non_space.matchAt(" a", 0, &scratch) == null);
    try std.testing.expect(try non_space.matchAt("\xe2\x80\xa8", 0, &scratch) == null);
    try std.testing.expect((try end.find("a", 0, &scratch)) != null);
    try std.testing.expect((try end.find("a\nb", 0, &scratch)) != null);
    try std.testing.expect(try end.find("ab", 0, &scratch) == null);
    try std.testing.expect((try not_non_space.find(" a", 0, &scratch)) != null);
    try std.testing.expect((try behind_non_space.find("ab", 0, &scratch)) != null);
}

test "fast regex handles Oniguruma word start and end anchors" {
    const P = Program(16);
    const exact = try P.compile("\\mword\\M");
    const run = try P.compile("\\m\\w+\\M");
    const meta = try P.compile("\\M-a");
    var scratch = VmScratch(16).init();

    const word = (try exact.find("a word!", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), word.start);
    try std.testing.expectEqual(@as(usize, 6), word.end);
    try std.testing.expectEqual(@as(?Match, null), try exact.find("swordfish", 0, &scratch));
    try std.testing.expectEqual(@as(usize, 4), (try run.find(" a_b ", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 3), (try run.find(" é!", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try meta.matchAt("\xe1", 0, &scratch)).?.end);
}

test "regex VM handles fixed literal lookbehind" {
    const P = Program(16);
    const positive = try P.compile("(?<=a)b");
    const negative = try P.compile("(?<!a)b");
    var scratch = VmScratch(32).init();

    const yes = (try positive.find("xab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), yes.start);
    try std.testing.expectEqual(@as(usize, 3), yes.end);
    try std.testing.expect(try positive.find("xcb", 0, &scratch) == null);

    const no = (try negative.find("xcb", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), no.start);
    try std.testing.expectEqual(@as(usize, 3), no.end);
    try std.testing.expect(try negative.find("xab", 0, &scratch) == null);
}

test "regex VM handles bounded literal alternation groups" {
    const P = Program(16);
    const p = try P.compile("(if|while|return)");
    const non_capture = try P.compile("(?:if|while)+");
    const atomic = try P.compile("(?>if|while)");
    const atomic_space = try P.compile("^(?>\\s*)//");
    const ignore_case = try P.compile("(?i:if|while)+");
    const multiline = try P.compile("(?m:if)");
    const extended = try P.compile("(?x:a b|c d)");
    const flag_negation = try P.compile("(?-i:IF)");
    var scratch = VmScratch(32).init();

    const m = (try p.find("x while y", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 7), m.end);
    try std.testing.expect(try p.find("x switch y", 0, &scratch) == null);
    const quantified = try P.compile("(a|b)+");
    try std.testing.expect(try quantified.find("xxabba", 0, &scratch) != null);
    try std.testing.expect((try non_capture.find("x ifwhile", 0, &scratch)) != null);
    try std.testing.expect((try atomic.find("x while", 0, &scratch)) != null);
    try std.testing.expect((try atomic_space.find("  //", 0, &scratch)) != null);
    try std.testing.expect((try ignore_case.find("x IFWhile", 0, &scratch)) != null);
    try std.testing.expect((try multiline.find("x if", 0, &scratch)) != null);
    try std.testing.expect((try extended.find("x cd", 0, &scratch)) != null);
    try std.testing.expect((try flag_negation.find("x IF", 0, &scratch)) != null);
    try std.testing.expect(try flag_negation.find("x if", 0, &scratch) == null);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("(?(1)yes|no)"));
}

test "regex VM requires full literal capture alternation" {
    const P = Program(16);
    const p = try P.compile("(///).*$");
    var scratch = VmScratch(32).init();
    var captures = [_]Capture{.{}} ** max_captures;

    try std.testing.expect(try p.matchAt("// comment", 0, &scratch) == null);
    try std.testing.expect(try p.matchAtCaptures("// comment", 0, &scratch, &captures) == null);
    const m = (try p.matchAt("/// doc", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 7), m.end);
}

test "regex VM handles bounded numbered backreferences" {
    const P = Program(16);
    const p = try P.compile("(ab)\\1");
    var scratch = VmScratch(32).init();

    const m = (try p.find("xxabab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 6), m.end);
    try std.testing.expect(try p.find("xxabac", 0, &scratch) == null);
    try std.testing.expectError(error.UnsupportedRegex, P.compile("\\1(a)"));
}

test "regex VM handles bounded named literal captures" {
    const P = Program(16);
    const p = try P.compile("(?<tag>ab)\\1");
    var scratch = VmScratch(32).init();

    const m = (try p.find("xxabab", 0, &scratch)).?;
    try std.testing.expectEqual(@as(usize, 2), m.start);
    try std.testing.expectEqual(@as(usize, 6), m.end);
}

test "fast regex treats escaped quote markers as literals" {
    const P = Program(32);
    const quote = try P.compile("\\Qliteral\\E");
    const class = try P.compile("[\\Q]");
    var scratch = VmScratch(8).init();

    _ = try P.compile("\\\\Q");
    try std.testing.expectEqual(@as(usize, 9), (try quote.matchAt("QliteralE", 0, &scratch)).?.end);
    try std.testing.expectEqual(@as(usize, 1), (try class.matchAt("Q", 0, &scratch)).?.end);
}
