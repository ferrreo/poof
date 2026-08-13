const std = @import("std");
const engine = @import("../../runtime/engine.zig");
const anchor = @import("anchor.zig");
const class = @import("class.zig");
const regex_escape = @import("../../regex/escape.zig");
const layout = @import("layout.zig");
const line_start = @import("line_start.zig");
const literal = @import("literal.zig");
const prefix_dynamic = @import("prefix.zig");
const storage_mod = @import("storage.zig");
const max_bytes = storage_mod.max_bytes;
pub const Pattern = struct {
    slot: u8 = 0,
    anchor_start: bool = false,
    anchor_end: bool = false,
    allow_tab_prefix: bool = false,
    allow_whitespace_prefix: bool = false,
    terminator_boundary: bool = false,
    line_end_alt: bool = false,
    comment_end_alt: bool = false,
    unescaped_line_end_alt: bool = false,
    negative_line_start_blank_alt: bool = false,
    g_anchor_negative_suffix_alt: bool = false,
    fence_line_end: bool = false,
    fence_line_negate: bool = false,
    optional_keyword_semicolon: bool = false,
    negative_line_start_space_text: bool = false,
    negative_line_start_indent_or_blank: bool = false,
    negative_line_start_blank_or_indent_text: bool = false,
    negative_line_start_marker_text: bool = false,
    negative_line_start_marker_space_text: bool = false,
    line_start_marker_space_or_empty_lookahead: bool = false,
    negative_line_start_marker_space_or_empty: bool = false,
    negative_line_start_marker_space_or_newline: bool = false,
    negative_line_start_comment_marker_two_space_or_blank: bool = false,
    line_start_marker_whitespace_or_blank: bool = false,
    negative_line_start_marker_horizontal_space_or_empty: bool = false,
    negative_line_start_marker_whitespace_or_blank: bool = false,
    negative_line_start_blank_comment_or_marker_space: bool = false,
    negative_line_start_four_space: bool = false,
    negative_line_start_block_quote_four_space: bool = false,
    negative_tag_on_line: bool = false,
    whitespace_before_suffix: bool = false,
    whitespace_before_marker: bool = false,
    horizontal_space_tail: bool = false,
    line_contains_marker: bool = false,
    case_insensitive: bool = false,
    lookbehind_end: bool = false,
    prefixed_lookbehind_alt: bool = false,
    no_escape_behind: bool = false,
    zero_width: bool = false,
    marker_word_boundary: bool = false,
    optional_semicolon_lookahead: bool = false,
    line_start_or_semicolon_marker_lookahead: bool = false,
    layout_continuation_end: bool = false,
    layout_comment_guard_end: bool = false,
    line_start_guarded_whitespace_marker: bool = false,
    repeat_count: u8 = 1,
    not_followed_by: u8 = 0,
    not_followed_by_identifier: bool = false,
    not_prefixed_by_len: u8 = 0,
    not_prefixed_by: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    line_start_whitespace_marker_boundary: bool = false,
    lookahead_suffix_len: u8 = 0,
    lookahead_suffix: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    alt_slot: u8 = 0,
    concat_slot: u8 = 0,
    guard_slot: u8 = 0,
    prefix_len: u8 = 0,
    prefix: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    suffix_len: u8 = 0,
    suffix: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    optional_suffix_prefix: u8 = 0,
    literal_alt_len: u8 = 0,
    literal_alt: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    class_tail_lookahead: bool = false,
    class_tail_required: u8 = 0,
    class_tail_len: u8 = 0,
    class_tail: [max_bytes]u8 = [_]u8{0} ** max_bytes,
    pub fn enabled(self: Pattern) bool {
        return self.slot != 0;
    }
};
pub const Storage = storage_mod.Storage;
pub fn parse(pattern: []const u8) ?Pattern {
    if (anchoredGroupedBackrefSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .anchor_end = true };
    if (groupedBackrefSlot(pattern, ")")) |slot| return .{ .slot = slot };
    if (groupedBackrefSlot(pattern, ")|(\\n)")) |slot| return .{ .slot = slot, .line_end_alt = true };
    if (groupedBackrefSlot(pattern, ")|((?<!\\\\)\n)")) |slot| return .{ .slot = slot, .unescaped_line_end_alt = true };
    if (groupedBackrefSlot(pattern, ")|((?<!\\\\)\\n)")) |slot| return .{ .slot = slot, .unescaped_line_end_alt = true };
    if (groupedBackrefSlot(pattern, ")|(?=$|\\*/)")) |slot| return .{ .slot = slot, .comment_end_alt = true };
    if (anchor.parseGNegativeSuffixSlot(pattern)) |slot| return .{ .slot = slot, .g_anchor_negative_suffix_alt = true };
    if (anchor.parseFenceLine(pattern)) |fence| return .{ .slot = fence.slot, .fence_line_end = true, .fence_line_negate = fence.negate };
    if (anchoredBackrefBoundaryLineTail(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .marker_word_boundary = true, .line_contains_marker = true };
    if (anchoredGroupedBackrefOptionalSemicolonEnd(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .optional_semicolon_lookahead = true };
    if (lookbehindBackrefSlot(pattern)) |slot| return .{ .slot = slot, .lookbehind_end = true };
    if (noEscapeBehindBackref(pattern)) |slot| return .{ .slot = slot, .no_escape_behind = true };
    if (lookaheadNoEscapeBehindBackref(pattern)) |slot| return .{ .slot = slot, .no_escape_behind = true, .zero_width = true };
    if (line_start.anchoredBackrefTerminator(pattern)) |parsed| return .{ .slot = parsed.slot, .anchor_start = true, .allow_tab_prefix = parsed.allow_tab_prefix, .terminator_boundary = true };
    if (line_start.whitespaceMarkerLookaheadSlot(pattern)) |slot| return .{ .slot = slot, .line_start_whitespace_marker_boundary = true, .zero_width = true };
    if (line_start.semicolonMarkerLookaheadSlot(pattern)) |slot| return .{ .slot = slot, .line_start_or_semicolon_marker_lookahead = true, .case_insensitive = true, .zero_width = true };
    if (anchoredBackrefLookaheadSuffix(pattern)) |out| return out;
    if (backrefGroupedLiteralSuffix(pattern)) |out| return out;
    if (backrefLiteralSuffix(pattern)) |out| return out;
    if (lineContainsBackref(pattern)) |out| return out;
    if (lineStartGroupedWhitespaceBackref(pattern)) |out| return out;
    if (line_start.groupedWhitespaceIdentifierBoundarySlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .allow_whitespace_prefix = true, .not_followed_by_identifier = true };
    if (line_start.optionalGuardedWhitespaceBackref(pattern)) |parsed| return .{ .slot = parsed.slot, .guard_slot = parsed.guard_slot, .anchor_start = true, .anchor_end = true, .line_start_guarded_whitespace_marker = true };
    if (layout.parseContinuation(pattern)) |parsed| {
        var out = Pattern{ .slot = parsed.slot, .layout_continuation_end = true };
        out.prefix_len = @intCast(parsed.keyword.len);
        @memcpy(out.prefix[0..parsed.keyword.len], parsed.keyword);
        return out;
    }
    if (layout.parseCommentGuard(pattern)) |slot| return .{ .slot = slot, .layout_comment_guard_end = true };
    if (whitespaceBackrefSuffix(pattern)) |out| return out;
    if (twoBackrefs(pattern)) |slots| return .{ .slot = slots[0], .concat_slot = slots[1] };
    if (optionalKeywordSemicolon(pattern)) |out| return out;
    if (prefix_dynamic.parseLookbehindAlt(pattern)) |parsed| {
        var out = Pattern{ .slot = parsed.slot, .prefixed_lookbehind_alt = true, .prefix_len = parsed.prefix_len, .suffix_len = parsed.suffix_len, .literal_alt_len = parsed.literal_alt_len };
        @memcpy(out.prefix[0..parsed.prefix_len], parsed.prefix[0..parsed.prefix_len]);
        @memcpy(out.suffix[0..parsed.suffix_len], parsed.suffix[0..parsed.suffix_len]);
        @memcpy(out.literal_alt[0..parsed.literal_alt_len], parsed.literal_alt[0..parsed.literal_alt_len]);
        return out;
    }
    if (prefixedBackrefWithSuffixAlt(pattern)) |out| return out;
    if (prefixedBackrefWithSuffix(pattern)) |out| return out;
    if (prefixedBackref(pattern)) |out| return out;
    if (line_start.negativeSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_blank_alt = true };
    if (line_start.negativeSpaceTextSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_space_text = true };
    if (line_start.negativeIndentOrBlankSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_indent_or_blank = true };
    if (line_start.negativeBlankOrIndentTextSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_blank_or_indent_text = true };
    if (line_start.negativeMarkerTextSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_text = true };
    if (line_start.negativeMarkerSpaceTextSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_space_text = true };
    if (line_start.markerSpaceOrEmptyLookaheadSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .line_start_marker_space_or_empty_lookahead = true, .zero_width = true };
    if (line_start.negativeMarkerSpaceOrEmptySlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_space_or_empty = true };
    if (line_start.negativeMarkerSpaceOrNewlineSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_space_or_newline = true };
    if (line_start.negativeCommentMarkerTwoSpaceOrBlankSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_comment_marker_two_space_or_blank = true };
    if (line_start.markerWhitespaceOrBlankSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .line_start_marker_whitespace_or_blank = true };
    if (line_start.negativeMarkerHorizontalSpaceOrEmptySlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_horizontal_space_or_empty = true };
    if (line_start.negativeMarkerWhitespaceOrBlankSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_marker_whitespace_or_blank = true };
    if (negativeLineStartBlankCommentOrMarkerSpace(pattern)) |out| return out;
    if (line_start.negativeFourSpaceSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_four_space = true };
    if (line_start.negativeBlockQuoteFourSpaceSlot(pattern)) |slot| return .{ .slot = slot, .anchor_start = true, .negative_line_start_block_quote_four_space = true };
    if (negativeTagOnLineSlot(pattern)) |slot| return .{ .slot = slot, .negative_tag_on_line = true };
    if (backrefNotFollowedBy(pattern)) |out| return out;
    if (backrefNotPrefixedBy(pattern)) |out| return out;
    if (class.parseLookahead(pattern)) |tail| {
        var parsed = Pattern{ .slot = tail.slot, .marker_word_boundary = true, .class_tail_lookahead = true, .class_tail_required = tail.required, .class_tail_len = tail.len };
        @memcpy(parsed.class_tail[0..tail.len], tail.bytes[0..tail.len]);
        return parsed;
    }
    var rest = pattern;
    var out = Pattern{};
    if (std.mem.startsWith(u8, rest, "^")) {
        out.anchor_start = true;
        rest = rest[1..];
    }
    if (std.mem.startsWith(u8, rest, "\\t*")) {
        out.allow_tab_prefix = true;
        rest = rest[3..];
    }
    if (std.mem.startsWith(u8, rest, "\\s*")) {
        out.allow_whitespace_prefix = true;
        rest = rest[3..];
    }
    if (rest.len < 2 or rest[0] != '\\' or rest[1] < '1' or rest[1] > '9') return null;
    out.slot = rest[1] - '0';
    rest = rest[2..];
    if (exactRepeat(rest)) |repeat| {
        out.repeat_count = repeat.count;
        rest = rest[repeat.len..];
    }
    if (class.parseStar(rest, &out)) |len| rest = rest[len..];
    if (rest.len == 0) return out;
    if (std.mem.eql(u8, rest, "\\b")) {
        out.marker_word_boundary = true;
        return out;
    }
    if (std.mem.eql(u8, rest, "\\s*$")) {
        out.whitespace_before_suffix = true;
        out.anchor_end = true;
        return out;
    }
    if (std.mem.eql(u8, rest, "$")) {
        out.anchor_end = true;
        return out;
    }
    if (std.mem.eql(u8, rest, "(?=[\\&;\\s]|$)") or std.mem.eql(u8, rest, "(?=\\s|;|&|$)")) {
        out.terminator_boundary = true;
        return out;
    }
    return null;
}
pub fn store(pattern: Pattern, captures: []const engine.CaptureSlot, line: []const u8) engine.HighlightError!Storage {
    return storage_mod.store(pattern, captures, line);
}
pub fn storeVm(pattern: Pattern, captures: anytype, line: []const u8) engine.HighlightError!?Storage {
    return storage_mod.storeVm(pattern, captures, line);
}
pub fn match(storage: Storage, pattern: Pattern, line: []const u8, index: usize) ?usize {
    if (pattern.anchor_start and index != 0) return null;
    const marker = storage.bytes[0..storage.len];
    if (pattern.negative_line_start_blank_alt) return line_start.negativeEnd(marker, line, index);
    if (pattern.negative_line_start_space_text) return line_start.negativeSpaceTextEnd(marker, line, index);
    if (pattern.negative_line_start_indent_or_blank) return line_start.negativeIndentOrBlankEnd(marker, line, index);
    if (pattern.negative_line_start_blank_or_indent_text) return line_start.negativeBlankOrIndentTextEnd(marker, line, index);
    if (pattern.negative_line_start_marker_text) return line_start.negativeMarkerTextEnd(marker, line, index);
    if (pattern.negative_line_start_marker_space_text) return line_start.negativeMarkerSpaceTextEnd(marker, line, index);
    if (pattern.line_start_marker_space_or_empty_lookahead) return line_start.markerSpaceOrEmptyLookaheadEnd(marker, line, index);
    if (pattern.negative_line_start_marker_space_or_empty) return line_start.negativeMarkerSpaceOrEmptyEnd(marker, line, index);
    if (pattern.negative_line_start_marker_space_or_newline) return line_start.negativeMarkerSpaceOrNewlineEnd(marker, line, index);
    if (pattern.negative_line_start_comment_marker_two_space_or_blank) return line_start.negativeCommentMarkerTwoSpaceOrBlankEnd(marker, line, index);
    if (pattern.line_start_marker_whitespace_or_blank) return line_start.markerWhitespaceOrBlankEnd(marker, line, index);
    if (pattern.negative_line_start_marker_horizontal_space_or_empty) return line_start.negativeMarkerHorizontalSpaceOrEmptyEnd(marker, line, index);
    if (pattern.negative_line_start_marker_whitespace_or_blank) return line_start.negativeMarkerWhitespaceOrBlankEnd(marker, line, index);
    if (pattern.negative_line_start_blank_comment_or_marker_space) return line_start.negativeBlankCommentOrMarkerSpaceEnd(marker, pattern.literal_alt[0..pattern.literal_alt_len], line, index);
    if (pattern.negative_line_start_four_space) return line_start.negativeFourSpaceEnd(marker, line, index);
    if (pattern.negative_line_start_block_quote_four_space) return line_start.negativeBlockQuoteFourSpaceEnd(marker, line, index);
    if (pattern.negative_tag_on_line) return prefix_dynamic.matchTagOnLine(marker, line, index);
    if (storage.len == 0 and pattern.prefix_len == 0) return null;
    if (pattern.line_end_alt and index == line.len) return index;
    if (pattern.unescaped_line_end_alt and index == line.len and (index == 0 or line[index - 1] != '\\')) return index;
    if (pattern.comment_end_alt and (index == line.len or std.mem.startsWith(u8, line[index..], "*/"))) return index;
    if (pattern.g_anchor_negative_suffix_alt) return anchor.matchGNegativeSuffix(marker, line, index);
    if (pattern.fence_line_end) return anchor.matchFenceLine(marker, pattern.fence_line_negate, line, index);
    if (pattern.lookbehind_end) return lookbehindEnd(storage, line, index);
    if (pattern.line_start_whitespace_marker_boundary) return line_start.whitespaceMarkerEnd(marker, line, index);
    if (pattern.line_start_or_semicolon_marker_lookahead) return line_start.semicolonMarkerEnd(marker, pattern.case_insensitive, line, index);
    if (pattern.layout_continuation_end) return layout.matchContinuation(marker, pattern.prefix[0..pattern.prefix_len], line, index);
    if (pattern.layout_comment_guard_end) return layout.matchCommentGuard(marker, line, index);
    if (pattern.line_start_guarded_whitespace_marker) return line_start.guardedWhitespaceMarkerEnd(storage.guard_bytes[0..storage.guard_len], marker, line, index);
    if (pattern.line_contains_marker) return lineContainsMarkerEnd(storage, pattern, line, index);
    if (pattern.optional_keyword_semicolon) return optionalKeywordSemicolonEnd(storage, pattern, line, index);
    if (pattern.prefix_len != 0 or pattern.literal_alt_len != 0) return prefixedSuffixAltEnd(storage, pattern, line, index);
    var start = index;
    if (pattern.whitespace_before_marker and (index == 0 or !std.ascii.isWhitespace(line[index - 1]))) return null;
    if (pattern.allow_tab_prefix) {
        while (start < line.len and line[start] == '\t') : (start += 1) {}
    }
    if (pattern.allow_whitespace_prefix) {
        while (start < line.len and std.ascii.isWhitespace(line[start])) : (start += 1) {}
    }
    if (pattern.prefix_len != 0) {
        const prefix = pattern.prefix[0..pattern.prefix_len];
        if (!std.mem.startsWith(u8, line[start..], prefix)) return null;
        start += prefix.len;
    }
    if (pattern.not_prefixed_by_len != 0 and std.mem.startsWith(u8, line[start..], pattern.not_prefixed_by[0..pattern.not_prefixed_by_len])) return null;
    var end = storage_mod.matchRepeated(storage, pattern.repeat_count, line, start) orelse return null;
    if (pattern.optional_semicolon_lookahead and !(end == line.len or (end + 1 == line.len and line[end] == ';'))) return null;
    if (pattern.class_tail_len != 0 and pattern.class_tail_lookahead) {
        if (!class.lookaheadContains(pattern.class_tail[0..pattern.class_tail_len], pattern.class_tail_required, line[end..])) return null;
    } else if (pattern.class_tail_len != 0) while (end < line.len and class.contains(pattern.class_tail[0..pattern.class_tail_len], line[end])) : (end += 1) {};
    if (pattern.marker_word_boundary and !wordBoundary(line, end)) return null;
    if (pattern.no_escape_behind and !passesNoEscapeBehind(line, start)) return null;
    if (pattern.zero_width) return index;
    if (pattern.lookahead_suffix_len != 0 and !std.mem.startsWith(u8, line[end..], pattern.lookahead_suffix[0..pattern.lookahead_suffix_len])) return null;
    if (pattern.not_followed_by != 0 and end < line.len and line[end] == pattern.not_followed_by) return null;
    if (pattern.not_followed_by_identifier and end < line.len and isIdentifierTailByte(line[end])) return null;
    if (pattern.terminator_boundary and end < line.len and !isTerminatorBoundary(line[end])) return null;
    if (pattern.whitespace_before_suffix) while (end < line.len and std.ascii.isWhitespace(line[end])) : (end += 1) {};
    if (pattern.optional_suffix_prefix != 0 and end < line.len and line[end] == pattern.optional_suffix_prefix) {
        end += 1;
        while (end < line.len and std.ascii.isWhitespace(line[end])) : (end += 1) {}
    }
    if (pattern.suffix_len != 0) {
        const suffix = pattern.suffix[0..pattern.suffix_len];
        if (!std.mem.startsWith(u8, line[end..], suffix)) return null;
        end += suffix.len;
    }
    if (pattern.horizontal_space_tail) while (end < line.len and (line[end] == ' ' or line[end] == '\t')) : (end += 1) {};
    if (pattern.anchor_end and end != line.len) return null;
    return end;
}
fn isTerminatorBoundary(byte: u8) bool {
    return byte == '&' or byte == ';' or std.ascii.isWhitespace(byte);
}
fn exactRepeat(pattern: []const u8) ?struct { count: u8, len: usize } {
    if (pattern.len < 3 or pattern[0] != '{') return null;
    const close = std.mem.indexOfScalar(u8, pattern, '}') orelse return null;
    if (close == 1) return null;
    const count = std.fmt.parseInt(u8, pattern[1..close], 10) catch return null;
    return if (count == 0) null else .{ .count = count, .len = close + 1 };
}
fn anchoredGroupedBackrefSlot(pattern: []const u8) ?u8 {
    if (pattern.len != 6 or !std.mem.startsWith(u8, pattern, "^(\\") or !std.mem.endsWith(u8, pattern, ")$")) return null;
    const slot = pattern[3];
    return if (slot >= '1' and slot <= '9') slot - '0' else null;
}
fn anchoredBackrefBoundaryLineTail(pattern: []const u8) ?u8 {
    return if (pattern.len == 11 and std.mem.startsWith(u8, pattern, "^(\\") and std.mem.endsWith(u8, pattern, ")\\b(.*)") and pattern[3] >= '1' and pattern[3] <= '9') pattern[3] - '0' else null;
}
fn anchoredGroupedBackrefOptionalSemicolonEnd(pattern: []const u8) ?u8 {
    return if (pattern.len == 12 and std.mem.startsWith(u8, pattern, "^(\\") and std.mem.endsWith(u8, pattern, ")(?=;?$)") and pattern[3] >= '1' and pattern[3] <= '9') pattern[3] - '0' else null;
}
fn twoBackrefs(pattern: []const u8) ?[2]u8 {
    return if (pattern.len == 4 and pattern[0] == '\\' and pattern[2] == '\\' and pattern[1] >= '1' and pattern[1] <= '9' and pattern[3] >= '1' and pattern[3] <= '9') .{ pattern[1] - '0', pattern[3] - '0' } else null;
}
fn groupedBackrefSlot(pattern: []const u8, tail: []const u8) ?u8 {
    if (pattern.len != 3 + tail.len or pattern[0] != '(' or pattern[1] != '\\') return null;
    if (pattern[2] < '1' or pattern[2] > '9') return null;
    return if (std.mem.eql(u8, pattern[3..], tail)) pattern[2] - '0' else null;
}
fn prefixedBackref(pattern: []const u8) ?Pattern {
    var out = Pattern{};
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '\\' and i + 1 < pattern.len and pattern[i + 1] >= '1' and pattern[i + 1] <= '9') {
            if (i + 2 != pattern.len) return null;
            out.slot = pattern[i + 1] - '0';
            return if (out.prefix_len == 0) null else out;
        }
        var byte = pattern[i];
        if (byte == '\\') {
            i += 1;
            if (i >= pattern.len) return null;
            byte = regex_escape.byte(pattern[i]);
        } else if (std.mem.indexOfScalar(u8, ".^$*+?[]()|{}", byte) != null) return null;
        if (out.prefix_len == out.prefix.len) return null;
        out.prefix[out.prefix_len] = byte;
        out.prefix_len += 1;
    }
    return null;
}
fn prefixedBackrefWithSuffixAlt(pattern: []const u8) ?Pattern {
    var out = Pattern{};
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '\\' and i + 1 < pattern.len and pattern[i + 1] >= '1' and pattern[i + 1] <= '9') {
            out.slot = pattern[i + 1] - '0';
            i += 2;
            break;
        }
        const byte = literal.literalByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.prefix, &out.prefix_len, byte) orelse return null;
    }
    if (out.slot == 0 or out.prefix_len == 0) return null;
    if (std.mem.startsWith(u8, pattern[i..], "\\s*")) {
        out.whitespace_before_suffix = true;
        i += 3;
    }
    while (i < pattern.len and pattern[i] != '|') {
        const byte = literal.literalByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.suffix, &out.suffix_len, byte) orelse return null;
    }
    if (i >= pattern.len or pattern[i] != '|' or out.suffix_len == 0) return null;
    i += 1;
    while (i < pattern.len) {
        const byte = literal.literalByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.literal_alt, &out.literal_alt_len, byte) orelse return null;
    }
    return if (out.literal_alt_len == 0) null else out;
}
fn prefixedBackrefWithSuffix(pattern: []const u8) ?Pattern {
    var body = pattern;
    var horizontal_space_tail = false;
    if (horizontalSpaceTailLen(body)) |tail_len| {
        horizontal_space_tail = true;
        body = body[0 .. body.len - tail_len];
    }
    if (body.len >= 2 and body[0] == '(' and body[body.len - 1] == ')') body = body[1 .. body.len - 1];
    body = stripOptionalWhitespaceNewlineTail(body);
    var out = Pattern{};
    var i: usize = 0;
    while (i < body.len) {
        if (body[i] == '\\' and i + 1 < body.len and body[i + 1] >= '1' and body[i + 1] <= '9') {
            out.slot = body[i + 1] - '0';
            i += 2;
            break;
        }
        const byte = literal.dynamicSuffixByte(body, &i) orelse return null;
        literal.appendFixed(u8, &out.prefix, &out.prefix_len, byte) orelse return null;
    }
    if (out.slot == 0 or out.prefix_len == 0) return null;
    while (i < body.len) {
        const byte = literal.dynamicSuffixByte(body, &i) orelse return null;
        literal.appendFixed(u8, &out.suffix, &out.suffix_len, byte) orelse return null;
    }
    out.horizontal_space_tail = horizontal_space_tail;
    return if (out.suffix_len == 0) null else out;
}

fn horizontalSpaceTailLen(pattern: []const u8) ?usize {
    inline for (.{ "[\\t ]*", "[ \\t]*" }) |tail| {
        if (std.mem.endsWith(u8, pattern, tail)) return tail.len;
    }
    return null;
}

fn stripOptionalWhitespaceNewlineTail(pattern: []const u8) []const u8 {
    const tail = "(?:\\s*\\n)?";
    return if (std.mem.endsWith(u8, pattern, tail)) pattern[0 .. pattern.len - tail.len] else pattern;
}
fn lineContainsBackref(pattern: []const u8) ?Pattern {
    const prefix = "^.*?\\";
    const suffix = ".*?$";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, suffix)) return null;
    if (pattern.len != prefix.len + 1 + suffix.len) return null;
    const slot = pattern[prefix.len];
    return if (slot >= '1' and slot <= '9') .{ .slot = slot - '0', .anchor_start = true, .anchor_end = true, .line_contains_marker = true } else null;
}
fn lineStartGroupedWhitespaceBackref(pattern: []const u8) ?Pattern {
    const prefix = "^(\\s*(\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    if (pattern.len <= prefix.len or pattern[prefix.len] < '1' or pattern[prefix.len] > '9') return null;
    var out = Pattern{ .slot = pattern[prefix.len] - '0', .anchor_start = true, .allow_whitespace_prefix = true };
    const rest = pattern[prefix.len + 1 ..];
    if (std.mem.startsWith(u8, rest, "))(?!")) {
        var index: usize = 5;
        if (index >= rest.len) return null;
        var guard = rest[index];
        if (guard == '\\') {
            index += 1;
            if (index >= rest.len) return null;
            guard = regex_escape.byte(rest[index]);
        }
        index += 1;
        if (index == rest.len - 1 and rest[index] == ')') {
            out.not_followed_by = guard;
            return out;
        }
        return null;
    }
    if (std.mem.eql(u8, rest, "))\\s*(\\)\\s*)?(\\.)")) {
        out.whitespace_before_suffix = true;
        out.optional_suffix_prefix = ')';
        out.suffix[0] = '.';
        out.suffix_len = 1;
        return out;
    }
    return null;
}
fn whitespaceBackrefSuffix(pattern: []const u8) ?Pattern {
    const prefix = "(?<=\\s)(\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or !std.mem.endsWith(u8, pattern, ")")) return null;
    var i: usize = prefix.len;
    if (i >= pattern.len or pattern[i] < '1' or pattern[i] > '9') return null;
    var out = Pattern{ .slot = pattern[i] - '0', .whitespace_before_marker = true };
    i += 1;
    while (i + 1 < pattern.len) {
        const byte = literal.dynamicSuffixByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.suffix, &out.suffix_len, byte) orelse return null;
    }
    return if (out.suffix_len == 0) null else out;
}
fn negativeLineStartBlankCommentOrMarkerSpace(pattern: []const u8) ?Pattern {
    const prefix = "^(?!\\s*(?:";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    var out = Pattern{ .anchor_start = true, .negative_line_start_blank_comment_or_marker_space = true };
    var index: usize = prefix.len;
    while (index < pattern.len and !std.mem.startsWith(u8, pattern[index..], "|$)|\\")) {
        const byte = literal.literalByte(pattern, &index) orelse return null;
        literal.appendFixed(u8, &out.literal_alt, &out.literal_alt_len, byte) orelse return null;
    }
    if (out.literal_alt_len == 0 or !std.mem.startsWith(u8, pattern[index..], "|$)|\\")) return null;
    index += "|$)|\\".len;
    if (index >= pattern.len or pattern[index] < '1' or pattern[index] > '9') return null;
    out.slot = pattern[index] - '0';
    index += 1;
    if (!std.mem.eql(u8, pattern[index..], "\\s)")) return null;
    return out;
}
fn negativeTagOnLineSlot(pattern: []const u8) ?u8 {
    const prefix = "(?!</?\\";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    return if (pattern.len == prefix.len + 3 and pattern[prefix.len] >= '1' and pattern[prefix.len] <= '9' and std.mem.eql(u8, pattern[prefix.len + 1 ..], ">)")) pattern[prefix.len] - '0' else null;
}
fn backrefNotFollowedBy(pattern: []const u8) ?Pattern {
    if (pattern.len < 7 or pattern[0] != '\\' or pattern[1] < '1' or pattern[1] > '9') return null;
    if (!std.mem.startsWith(u8, pattern[2..], "(?!") or pattern[pattern.len - 1] != ')') return null;
    const guard = pattern[5 .. pattern.len - 1];
    return if (guard.len == 1 and !regex_escape.isMeta(guard[0])) .{ .slot = pattern[1] - '0', .not_followed_by = guard[0] } else null;
}
fn backrefNotPrefixedBy(pattern: []const u8) ?Pattern {
    if (!std.mem.startsWith(u8, pattern, "(?!")) return null;
    const close = std.mem.indexOfScalarPos(u8, pattern, 3, ')') orelse return null;
    if (close + 3 != pattern.len or pattern[close + 1] != '\\') return null;
    const slot = pattern[close + 2];
    if (slot < '1' or slot > '9') return null;
    var out = Pattern{ .slot = slot - '0' };
    var index: usize = 3;
    while (index < close) {
        const byte = literal.literalByte(pattern, &index) orelse return null;
        literal.appendFixed(u8, &out.not_prefixed_by, &out.not_prefixed_by_len, byte) orelse return null;
    }
    return if (out.not_prefixed_by_len == 0) null else out;
}
fn lookbehindBackrefSlot(pattern: []const u8) ?u8 {
    const prefix = "(?<!\\G)(?<=\\";
    if (std.mem.startsWith(u8, pattern, prefix) and pattern.len == prefix.len + 2 and pattern[pattern.len - 1] == ')') {
        const slot = pattern[prefix.len];
        return if (slot >= '1' and slot <= '9') slot - '0' else null;
    }
    const grouped_prefix = "(?<!\\G)(?<=(?:\\";
    if (!std.mem.startsWith(u8, pattern, grouped_prefix) or pattern.len != grouped_prefix.len + 3) return null;
    const slot = pattern[grouped_prefix.len];
    return if (slot >= '1' and slot <= '9' and std.mem.eql(u8, pattern[grouped_prefix.len + 1 ..], "))")) slot - '0' else null;
}
fn noEscapeBehindBackref(pattern: []const u8) ?u8 {
    const prefix = "(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or pattern.len != prefix.len + 1) return null;
    const slot = pattern[prefix.len];
    return if (slot >= '1' and slot <= '9') slot - '0' else null;
}
fn lookaheadNoEscapeBehindBackref(pattern: []const u8) ?u8 {
    const prefix = "(?=(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or pattern.len != prefix.len + 2 or pattern[pattern.len - 1] != ')') return null;
    const slot = pattern[prefix.len];
    return if (slot >= '1' and slot <= '9') slot - '0' else null;
}
fn anchoredBackrefLookaheadSuffix(pattern: []const u8) ?Pattern {
    const prefix = "^\\";
    if (!std.mem.startsWith(u8, pattern, prefix) or pattern.len <= prefix.len or pattern[prefix.len] < '1' or pattern[prefix.len] > '9') return null;
    var rest = pattern[prefix.len + 1 ..];
    if (!std.mem.startsWith(u8, rest, "(?=") or !std.mem.endsWith(u8, rest, ")\\b")) return null;
    rest = rest[3 .. rest.len - 3];
    if (rest.len == 0 or rest.len > max_bytes) return null;
    var out = Pattern{ .slot = pattern[prefix.len] - '0', .anchor_start = true };
    var i: usize = 0;
    while (i < rest.len) {
        const byte = literal.literalByte(rest, &i) orelse return null;
        literal.appendFixed(u8, &out.lookahead_suffix, &out.lookahead_suffix_len, byte) orelse return null;
    }
    return out;
}
fn backrefGroupedLiteralSuffix(pattern: []const u8) ?Pattern {
    if (pattern.len < 5 or pattern[0] != '\\' or pattern[1] < '1' or pattern[1] > '9' or pattern[2] != '(' or pattern[pattern.len - 1] != ')') return null;
    var out = Pattern{ .slot = pattern[1] - '0' };
    var i: usize = 3;
    while (i + 1 < pattern.len) {
        const byte = literal.literalByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.suffix, &out.suffix_len, byte) orelse return null;
    }
    return if (out.suffix_len == 0) null else out;
}
fn backrefLiteralSuffix(pattern: []const u8) ?Pattern {
    if (pattern.len < 3 or pattern[0] != '\\' or pattern[1] < '1' or pattern[1] > '9') return null;
    var out = Pattern{ .slot = pattern[1] - '0' };
    var i: usize = 2;
    while (i < pattern.len) {
        const byte = literal.dynamicSuffixByte(pattern, &i) orelse return null;
        literal.appendFixed(u8, &out.suffix, &out.suffix_len, byte) orelse return null;
    }
    return if (out.suffix_len == 0) null else out;
}
fn passesNoEscapeBehind(line: []const u8, index: usize) bool {
    if (index >= 2 and line[index - 1] == '\\' and line[index - 2] != '\\') return false;
    if (index >= 4 and line[index - 1] == '\\' and line[index - 2] == '\\' and line[index - 3] == '\\' and line[index - 4] != '\\') return false;
    return true;
}
fn optionalKeywordSemicolon(pattern: []const u8) ?Pattern {
    const prefix = "(?i)(?:\\b(";
    if (!std.mem.startsWith(u8, pattern, prefix)) return null;
    const keyword_end = std.mem.indexOf(u8, pattern[prefix.len..], ")\\s+(\\") orelse return null;
    const keyword = pattern[prefix.len..][0..keyword_end];
    if (keyword.len == 0 or keyword.len > max_bytes) return null;
    for (keyword) |byte| if (!std.ascii.isAlphabetic(byte)) return null;
    var rest = pattern[prefix.len + keyword_end + ")\\s+(\\".len ..];
    if (rest.len < 1 or rest[0] < '1' or rest[0] > '9') return null;
    const slot = rest[0] - '0';
    rest = rest[1..];
    var alt_slot: u8 = 0;
    if (std.mem.startsWith(u8, rest, "|\\")) {
        rest = rest[2..];
        if (rest.len < 1 or rest[0] < '1' or rest[0] > '9') return null;
        alt_slot = rest[0] - '0';
        rest = rest[1..];
    }
    if (!std.mem.eql(u8, rest, ")\\s*)?(;)")) return null;
    var out = Pattern{ .slot = slot, .alt_slot = alt_slot, .optional_keyword_semicolon = true, .case_insensitive = true };
    out.prefix_len = @intCast(keyword.len);
    @memcpy(out.prefix[0..keyword.len], keyword);
    return out;
}
fn lookbehindEnd(storage: Storage, line: []const u8, index: usize) ?usize {
    const len: usize = storage.len;
    if (len == 0 or index == 0 or index < len) return null;
    return if (std.mem.eql(u8, storage.bytes[0..len], line[index - len .. index])) index else null;
}
fn lineContainsMarkerEnd(storage: Storage, pattern: Pattern, line: []const u8, index: usize) ?usize {
    if (index != 0 or storage.len == 0) return null;
    const marker = storage.bytes[0..storage.len];
    if (!pattern.marker_word_boundary) return if (std.mem.indexOf(u8, line, marker) != null) line.len else null;
    return if (std.mem.startsWith(u8, line, marker) and wordBoundary(line, marker.len)) line.len else null;
}
fn optionalKeywordSemicolonEnd(storage: Storage, pattern: Pattern, line: []const u8, index: usize) ?usize {
    if (index < line.len and line[index] == ';') return index + 1;
    const keyword = pattern.prefix[0..pattern.prefix_len];
    if (!startsWith(line[index..], keyword, pattern.case_insensitive)) return null;
    var cursor = index + keyword.len;
    if (cursor >= line.len or !std.ascii.isWhitespace(line[cursor])) return null;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    const marker = storage.bytes[0..storage.len];
    if (!startsWith(line[cursor..], marker, pattern.case_insensitive)) return null;
    cursor += marker.len;
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor >= line.len or line[cursor] != ';') return null;
    return cursor + 1;
}
fn wordBoundary(line: []const u8, index: usize) bool {
    const before = index != 0 and isWordByte(line[index - 1]);
    return before != (index < line.len and isWordByte(line[index]));
}
fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
fn isIdentifierTailByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x7f;
}
fn prefixedSuffixAltEnd(storage: Storage, pattern: Pattern, line: []const u8, index: usize) ?usize {
    const alt = pattern.literal_alt[0..pattern.literal_alt_len];
    if (alt.len != 0 and std.mem.startsWith(u8, line[index..], alt)) return index + alt.len;
    if (pattern.prefixed_lookbehind_alt and prefix_dynamic.matchLookbehindAlt(pattern.prefix[0..pattern.prefix_len], pattern.suffix[0..pattern.suffix_len], storage.bytes[0..storage.len], line, index)) return index;
    if (pattern.whitespace_before_marker and (index == 0 or !std.ascii.isWhitespace(line[index - 1]))) return null;
    const prefix = pattern.prefix[0..pattern.prefix_len];
    if (!std.mem.startsWith(u8, line[index..], prefix)) return null;
    var cursor = index + prefix.len;
    const marker = storage.bytes[0..storage.len];
    if (!std.mem.startsWith(u8, line[cursor..], marker)) return null;
    cursor += marker.len;
    if (pattern.whitespace_before_suffix) {
        while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
    }
    const suffix = pattern.suffix[0..pattern.suffix_len];
    if (!std.mem.startsWith(u8, line[cursor..], suffix)) return null;
    cursor += suffix.len;
    if (pattern.horizontal_space_tail) while (cursor < line.len and (line[cursor] == ' ' or line[cursor] == '\t')) : (cursor += 1) {};
    return cursor;
}
fn startsWith(haystack: []const u8, needle: []const u8, case_insensitive: bool) bool {
    if (needle.len > haystack.len) return false;
    if (!case_insensitive) return std.mem.startsWith(u8, haystack, needle);
    for (needle, 0..) |byte, index| if (std.ascii.toLower(haystack[index]) != std.ascii.toLower(byte)) return false;
    return true;
}
test "dynamic end parses anchored backref terminators" {
    const pattern = parse("^\\t*\\3(?=[\\&;\\s]|$)").?;
    try std.testing.expectEqual(@as(u8, 3), pattern.slot);
    try std.testing.expect(pattern.anchor_start);
    try std.testing.expect(pattern.allow_tab_prefix);
    try std.testing.expect(pattern.terminator_boundary);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "EOF");
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "\tEOF;", 0));
    try std.testing.expect(match(storage, pattern, "\tEOFX", 0) == null);

    const wrapped = parse("(?:(?:^\\t*)(?:\\3)(?=\\s|;|&|$))").?;
    try std.testing.expectEqual(@as(u8, 3), wrapped.slot);
    try std.testing.expect(wrapped.anchor_start);
    try std.testing.expect(wrapped.allow_tab_prefix);
    try std.testing.expect(wrapped.terminator_boundary);
}

test "dynamic end parses grouped quote or newline" {
    const pattern = parse("(\\1)|(\\n)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.line_end_alt);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '"';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "abc\"", 3));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "abc", 3));
}

test "dynamic end parses grouped backref" {
    const pattern = parse("(\\1)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "'''");
    try std.testing.expectEqual(@as(?usize, 6), match(storage, pattern, "abc'''", 3));
    try std.testing.expect(match(storage, pattern, "abc\"", 3) == null);
}

test "dynamic end parses exact repeated backref" {
    const pattern = parse("\\1{4}").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expectEqual(@as(u8, 4), pattern.repeat_count);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '-';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "---- tail", 0));
    try std.testing.expect(match(storage, pattern, "--- tail", 0) == null);
}

test "dynamic end stores concatenated backrefs" {
    const pattern = parse("\\2\\1").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expectEqual(@as(u8, 1), pattern.concat_slot);
    const captures = [_]engine.CaptureSlot{ .{}, .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 2 } };
    const storage = try store(pattern, &captures, "[]");
    try std.testing.expectEqualStrings("][", storage.bytes[0..storage.len]);
    try std.testing.expectEqual(@as(?usize, 2), match(storage, pattern, "][", 0));
}

test "dynamic end parses line-start guarded whitespace backrefs" {
    const pattern = parse("^((?!\\5)\\s+)?((\\6))$").?;
    try std.testing.expectEqual(@as(u8, 6), pattern.slot);
    try std.testing.expectEqual(@as(u8, 5), pattern.guard_slot);
    try std.testing.expect(pattern.line_start_guarded_whitespace_marker);

    const captures = [_]engine.CaptureSlot{
        .{},                       .{},                       .{}, .{}, .{},
        .{ .start = 0, .end = 2 }, .{ .start = 2, .end = 5 },
    };
    const storage = try store(pattern, &captures, "XXEND");
    try std.testing.expectEqualStrings("END", storage.bytes[0..storage.len]);
    try std.testing.expectEqualStrings("XX", storage.guard_bytes[0..storage.guard_len]);
    try std.testing.expectEqual(@as(?usize, 5), match(storage, pattern, "  END", 0));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "END", 0));
    try std.testing.expect(match(storage, pattern, "XXEND", 0) == null);
    try std.testing.expect(match(storage, pattern, "  END tail", 0) == null);
    try std.testing.expect(match(storage, pattern, "  END", 1) == null);
}

test "dynamic end parses backref with trailing class star" {
    const pattern = parse("\\1[eimnosux]*").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expectEqualStrings("eimnosux", pattern.class_tail[0..pattern.class_tail_len]);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '/';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "/mix tail", 0));
    try std.testing.expectEqual(@as(?usize, 1), match(storage, pattern, "/ tail", 0));
    try std.testing.expect(match(storage, pattern, "xmix", 0) == null);
}

test "dynamic end parses backrefs with required class lookahead" {
    const pattern = parse("\\1(?=[acdegilmoprsu]*x[acdegilmoprsu]*)\\b").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.class_tail_lookahead);
    try std.testing.expectEqual(@as(u8, 'x'), pattern.class_tail_required);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '/';
    try std.testing.expectEqual(@as(?usize, 1), match(storage, pattern, "/mix tail", 0));
    try std.testing.expect(match(storage, pattern, "/mi tail", 0) == null);
}

test "dynamic end parses guarded backrefs" {
    const pattern = parse("(?!<\\\\)\\2").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expectEqualStrings("<\\", pattern.not_prefixed_by[0..pattern.not_prefixed_by_len]);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '"';
    try std.testing.expectEqual(@as(?usize, 1), match(storage, pattern, "\"", 0));
    try std.testing.expect(match(storage, pattern, "<\\\"", 0) == null);
}

test "dynamic end parses grouped quote or comment terminator" {
    const pattern = parse("(\\3)|(?=$|\\*/)").?;
    try std.testing.expectEqual(@as(u8, 3), pattern.slot);
    try std.testing.expect(pattern.comment_end_alt);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '"';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "abc\"", 3));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "abc", 3));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "abc*/", 3));
}

test "dynamic end parses G-anchor negative suffix alternatives" {
    const pattern = parse("\\G((?<!\\5[^-\\w]))|}|$").?;
    try std.testing.expectEqual(@as(u8, 5), pattern.slot);
    try std.testing.expect(pattern.g_anchor_negative_suffix_alt);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "tag");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "tag.name", 0));
    try std.testing.expect(match(storage, pattern, "tag.name", 4) == null);
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "tag-name", 4));
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "tag}", 3));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "tag", 3));
}

test "dynamic end parses marker fence lines" {
    const positive = parse("^(?: {0,3}\\1-*[\\t ]*|[\\t ]*\\.{3})$").?;
    try std.testing.expectEqual(@as(u8, 1), positive.slot);
    try std.testing.expect(positive.fence_line_end);

    const negative = parse("^(?!(?: {0,3}\\1-*[\\t ]*|[\\t ]*\\.{3})$)").?;
    try std.testing.expectEqual(@as(u8, 1), negative.slot);
    try std.testing.expect(negative.fence_line_negate);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "---");
    try std.testing.expectEqual(@as(?usize, 5), match(storage, positive, " --- ", 0));
    try std.testing.expectEqual(@as(?usize, 4), match(storage, positive, "\t...", 0));
    try std.testing.expect(match(storage, positive, "value", 0) == null);
    try std.testing.expectEqual(@as(?usize, 5), match(storage, negative, "value", 0));
    try std.testing.expect(match(storage, negative, "---", 0) == null);
}

test "dynamic end parses grouped quote or unescaped newline" {
    const patterns = [_][]const u8{ "(\\4)|((?<!\\\\)\n)", "(\\4)|((?<!\\\\)\\n)" };

    for (patterns) |source| {
        const pattern = parse(source).?;
        try std.testing.expectEqual(@as(u8, 4), pattern.slot);
        try std.testing.expect(pattern.unescaped_line_end_alt);

        var storage = Storage{ .len = 1 };
        storage.bytes[0] = '"';
        try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "abc\"", 3));
        try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "abc", 3));
        try std.testing.expect(match(storage, pattern, "abc\\", 4) == null);
    }
}

test "dynamic end parses negative line-start backref" {
    const pattern = parse("^(?!\\1|\\s*$)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_blank_alt);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expect(match(storage, pattern, "  item", 0) == null);
    try std.testing.expect(match(storage, pattern, "", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "item", 0));
}

test "dynamic end parses negative line-start indent or blank" {
    const pattern = parse("^(?!\\1[\\t ]|[\\t ]*$)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_indent_or_blank);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expect(match(storage, pattern, "   item", 0) == null);
    try std.testing.expect(match(storage, pattern, "  \titem", 0) == null);
    try std.testing.expect(match(storage, pattern, "", 0) == null);
    try std.testing.expect(match(storage, pattern, " \t", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, " item", 0));
}

test "dynamic end parses negative line-start marker text" {
    const pattern = parse("^(?!\\1(?=\\S))").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_marker_text);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expect(match(storage, pattern, "  item", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, " item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "", 0));

    const empty = Storage{};
    try std.testing.expect(match(empty, pattern, "item", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(empty, pattern, " item", 0));
}

test "dynamic end parses negative line-start marker space text" {
    const pattern = parse("^(?!\\1\\s+)(?=\\s*\\S+)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_marker_space_text);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '>';
    try std.testing.expect(match(storage, pattern, "> item", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, ">item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "item", 0));
    try std.testing.expect(match(storage, pattern, "   ", 0) == null);
}

test "dynamic end parses line-start marker space or empty lookahead" {
    const pattern = parse("^(?=\\1\\s+|$\\n*)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.line_start_marker_space_or_empty_lookahead);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "   item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "", 0));
    try std.testing.expect(match(storage, pattern, "  item", 0) == null);
    try std.testing.expect(match(storage, pattern, " item", 0) == null);
}

test "dynamic end parses negative line-start marker space or empty" {
    const patterns = [_][]const u8{
        "^(?!\\1\\s+|$\\n*)",
        "(?m:(?<=\\n)(?!\\1\\s+|$\\n*))",
    };

    for (patterns) |source| {
        const pattern = parse(source).?;
        try std.testing.expectEqual(@as(u8, 1), pattern.slot);
        try std.testing.expect(pattern.negative_line_start_marker_space_or_empty);

        var storage = Storage{ .len = 2 };
        @memcpy(storage.bytes[0..2], "  ");
        try std.testing.expect(match(storage, pattern, "   item", 0) == null);
        try std.testing.expect(match(storage, pattern, "", 0) == null);
        try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  item", 0));
        try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, " item", 0));
    }
}

test "dynamic end parses negative line-start marker space or newline" {
    const pattern = parse("^(?!\\1\\s+|\\n)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_marker_space_or_newline);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expect(match(storage, pattern, "   item", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, " item", 0));
}

test "dynamic end parses negative line-start comment marker two-space or blank" {
    const pattern = parse("^(?!\\s*#\\3\\s{2,}|\\s*#\\s*$)").?;
    try std.testing.expectEqual(@as(u8, 3), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_comment_marker_two_space_or_blank);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "=>");
    try std.testing.expect(match(storage, pattern, "#=>  doc", 0) == null);
    try std.testing.expect(match(storage, pattern, "  #=>   doc", 0) == null);
    try std.testing.expect(match(storage, pattern, "  #   ", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "#=> doc", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "# other", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "text", 0));
}

test "dynamic end parses line-start marker whitespace or blank" {
    const pattern = parse("^(?:\\1(?=\\s)|\\s*$)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.line_start_marker_whitespace_or_blank);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "..");
    try std.testing.expectEqual(@as(?usize, 2), match(storage, pattern, ".. item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "", 0));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "   ", 0));
    try std.testing.expect(match(storage, pattern, "..item", 0) == null);
    try std.testing.expect(match(storage, pattern, "item", 0) == null);
}

test "dynamic end parses negative line-start marker horizontal space or empty" {
    const pattern = parse("^(?!\\1[\\t ]|$)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_marker_horizontal_space_or_empty);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "..");
    try std.testing.expect(match(storage, pattern, ".. item", 0) == null);
    try std.testing.expect(match(storage, pattern, "..\titem", 0) == null);
    try std.testing.expect(match(storage, pattern, "", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "..item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "item", 0));
}

test "dynamic end parses negative line-start marker whitespace or blank" {
    const pattern = parse("^(?!\\1\\s|\\s*$)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_marker_whitespace_or_blank);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "..");
    try std.testing.expect(match(storage, pattern, ".. item", 0) == null);
    try std.testing.expect(match(storage, pattern, "..\titem", 0) == null);
    try std.testing.expect(match(storage, pattern, "", 0) == null);
    try std.testing.expect(match(storage, pattern, "   ", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "..item", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "item", 0));
}

test "dynamic end parses negative line-start comment or marker space" {
    const pattern = parse("^(?!\\s*(?:--|$)|\\1\\s)").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.negative_line_start_blank_comment_or_marker_space);
    try std.testing.expectEqualStrings("--", pattern.literal_alt[0..pattern.literal_alt_len]);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  value", 0));
    try std.testing.expect(match(storage, pattern, "   value", 0) == null);
    try std.testing.expect(match(storage, pattern, "  -- comment", 0) == null);
    try std.testing.expect(match(storage, pattern, "", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "value", 0));
}

test "dynamic end parses shell quoted command terminator" {
    const pattern = parse("(?<!\\G)(?<=\\2)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.lookbehind_end);

    const grouped = parse("(?<!\\G)(?<=(?:\\2))").?;
    try std.testing.expectEqual(@as(u8, 2), grouped.slot);
    try std.testing.expect(grouped.lookbehind_end);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '"';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "abc\"", 4));
    try std.testing.expect(match(storage, pattern, "\"", 0) == null);
    try std.testing.expect(match(storage, pattern, "abc'", 4) == null);
}

test "dynamic end parses unescaped backrefs" {
    const pattern = parse("(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\1").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.no_escape_behind);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '/';
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "abc/", 3));
    try std.testing.expect(match(storage, pattern, "abc\\/", 4) == null);
    try std.testing.expect(match(storage, pattern, "abc\\\\\\/", 6) == null);
}

test "dynamic end parses lookahead unescaped backrefs" {
    const pattern = parse("(?=(?<![^\\\\]\\\\)(?<![^\\\\][\\\\]{3})\\2)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.no_escape_behind);
    try std.testing.expect(pattern.zero_width);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '/';
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "abc/", 3));
    try std.testing.expect(match(storage, pattern, "abc\\/", 4) == null);
}

test "dynamic end parses line-start whitespace marker lookaheads" {
    const pattern = parse("(?=^\\s*\\2\\b)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.zero_width);
    try std.testing.expect(pattern.line_start_whitespace_marker_boundary);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "TAG");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  TAG", 0));
    try std.testing.expect(match(storage, pattern, "  TAGX", 0) == null);
    try std.testing.expect(match(storage, pattern, "  TAG", 1) == null);
}

test "dynamic end parses line-start or semicolon marker lookaheads" {
    const pattern = parse("(?i)(?:^|(?<=;))(?=\\s*\\b\\2\\b)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.zero_width);
    try std.testing.expect(pattern.line_start_or_semicolon_marker_lookahead);
    try std.testing.expect(pattern.case_insensitive);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "END");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  end do", 0));
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "x=1; END do", 4));
    try std.testing.expect(match(storage, pattern, "x END", 2) == null);
    try std.testing.expect(match(storage, pattern, "  ending", 0) == null);
}

test "dynamic end parses anchored marker lookahead suffixes" {
    const pattern = parse("^\\1(?=end)\\b").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.anchor_start);
    try std.testing.expectEqualStrings("end", pattern.lookahead_suffix[0..pattern.lookahead_suffix_len]);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expectEqual(@as(?usize, 2), match(storage, pattern, "  end", 0));
    try std.testing.expect(match(storage, pattern, "  stop", 0) == null);
    try std.testing.expect(match(storage, pattern, "x  end", 1) == null);
}

test "dynamic end parses anchored grouped backref optional semicolon lookahead" {
    const pattern = parse("^(\\2)(?=;?$)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.anchor_start);
    try std.testing.expect(pattern.optional_semicolon_lookahead);
    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "END");
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "END;", 0));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "END", 0));
    try std.testing.expect(match(storage, pattern, "END;tail", 0) == null);
}

test "dynamic end parses backrefs with grouped literal suffixes" {
    const pattern = parse("\\2(==)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expectEqualStrings("==", pattern.suffix[0..pattern.suffix_len]);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '=';
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "===", 0));
    try std.testing.expect(match(storage, pattern, "==", 0) == null);
}

test "dynamic end parses backrefs with literal suffixes" {
    const pattern = parse("\\1\"").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expectEqualStrings("\"", pattern.suffix[0..pattern.suffix_len]);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "q#");
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "q#\"", 0));
    try std.testing.expect(match(storage, pattern, "q#", 0) == null);
}

test "dynamic end parses whitespace-prefixed backref boundaries" {
    const pattern = parse("\\s*\\2\\b").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.allow_whitespace_prefix);
    try std.testing.expect(pattern.marker_word_boundary);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "end");
    try std.testing.expectEqual(@as(?usize, 6), match(storage, pattern, "   end", 0));
    try std.testing.expect(match(storage, pattern, "   endif", 0) == null);
}

test "dynamic end parses line-start grouped whitespace backrefs" {
    const guarded = parse("^(\\s*(\\3))(?!\")").?;
    try std.testing.expectEqual(@as(u8, 3), guarded.slot);
    try std.testing.expect(guarded.anchor_start);
    try std.testing.expect(guarded.allow_whitespace_prefix);
    try std.testing.expectEqual(@as(u8, '"'), guarded.not_followed_by);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "end");
    try std.testing.expectEqual(@as(?usize, 5), match(storage, guarded, "  end", 0));
    try std.testing.expect(match(storage, guarded, "  end\"", 0) == null);

    const suffixed = parse("^(\\s*(\\7))\\s*(\\)\\s*)?(\\.)").?;
    try std.testing.expectEqual(@as(u8, 7), suffixed.slot);
    try std.testing.expectEqual(@as(?usize, 7), match(storage, suffixed, "  end).", 0));
    try std.testing.expectEqual(@as(?usize, 7), match(storage, suffixed, "  end .", 0));

    const identifier_boundary = parse("^\\s*(\\3)(?![0-9A-Z_a-z\\x7F-\\x{10FFFF}])").?;
    try std.testing.expectEqual(@as(u8, 3), identifier_boundary.slot);
    try std.testing.expect(identifier_boundary.anchor_start);
    try std.testing.expect(identifier_boundary.allow_whitespace_prefix);
    try std.testing.expect(identifier_boundary.not_followed_by_identifier);
    try std.testing.expectEqual(@as(?usize, 5), match(storage, identifier_boundary, "  end", 0));
    try std.testing.expectEqual(@as(?usize, 5), match(storage, identifier_boundary, "  end;", 0));
    try std.testing.expect(match(storage, identifier_boundary, "  endif", 0) == null);
    try std.testing.expect(match(storage, identifier_boundary, "  end\x7f", 0) == null);
}

test "dynamic end parses layout continuation guards" {
    const base = parse("(?=[;}])|^(?!\\1\\s+\\S|\\s*(?:$|\\{-[^@]|--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]]).*$))").?;
    try std.testing.expectEqual(@as(u8, 1), base.slot);
    try std.testing.expect(base.layout_continuation_end);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expectEqual(@as(?usize, 0), match(storage, base, ";", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, base, "}", 0));
    try std.testing.expect(match(storage, base, "   child", 0) == null);
    try std.testing.expect(match(storage, base, "  -- comment", 0) == null);
    try std.testing.expect(match(storage, base, "  {- block", 0) == null);
    try std.testing.expect(match(storage, base, "  ", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, base, "  --%", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, base, " value", 0));

    const keyword = parse("(?=(?<!')\\bwhere\\b(?!'))|(?=[;}])|^(?!\\1\\s+\\S|\\s*(?:$|\\{-[^@]|--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]]).*$))").?;
    try std.testing.expectEqualStrings("where", keyword.prefix[0..keyword.prefix_len]);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, keyword, "where x", 0));
    try std.testing.expect(match(storage, keyword, "'where x", 1) == null);

    const odd_keyword = parse("(?=\\b(?<!'')deriving\\b(?!'))|(?=[;}])|^(?!\\1\\s+\\S|\\s*(?:$|\\{-[^@]|--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]]).*$))").?;
    try std.testing.expectEqualStrings("deriving", odd_keyword.prefix[0..odd_keyword.prefix_len]);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, odd_keyword, "deriving stock", 0));
}

test "dynamic end parses layout comment guards" {
    const pattern = parse("(?=^(?!\\1--+(?![[\\p{S}\\p{P}]&&[^]\"'(),;\\[_`{}]])))").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expect(pattern.layout_comment_guard_end);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "  ");
    try std.testing.expect(match(storage, pattern, "  -- comment", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "  --%", 0));
    try std.testing.expectEqual(@as(?usize, 0), match(storage, pattern, "value", 0));
}

test "dynamic end parses lines containing backrefs" {
    const pattern = parse("^.*?\\2.*?$").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.line_contains_marker);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "END");
    try std.testing.expectEqual(@as(?usize, 9), match(storage, pattern, "xx END yy", 0));
    try std.testing.expect(match(storage, pattern, "xx END yy", 1) == null);
    try std.testing.expect(match(storage, pattern, "xx STOP yy", 0) == null);
}

test "dynamic end parses whitespace-prefixed backref suffixes" {
    const pattern = parse("(?<=\\s)(\\2>)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.whitespace_before_marker);
    try std.testing.expectEqualStrings(">", pattern.suffix[0..pattern.suffix_len]);

    var storage = Storage{ .len = 1 };
    storage.bytes[0] = '%';
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, " %>", 1));
    try std.testing.expect(match(storage, pattern, "%>", 0) == null);
    try std.testing.expect(match(storage, pattern, " #>", 1) == null);
}

test "dynamic end parses literal-prefixed backrefs" {
    const pattern = parse("\"\\2").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expectEqual(@as(u8, 1), pattern.prefix_len);
    try std.testing.expectEqual(@as(u8, '"'), pattern.prefix[0]);

    var hashes = Storage{ .len = 2 };
    @memcpy(hashes.bytes[0..2], "##");
    try std.testing.expectEqual(@as(?usize, 3), match(hashes, pattern, "\"##", 0));
    try std.testing.expect(match(hashes, pattern, "\"#", 0) == null);

    const empty = Storage{};
    try std.testing.expectEqual(@as(?usize, 1), match(empty, pattern, "\"", 0));
}

test "dynamic end parses prefixed backref with suffix alt" {
    const pattern = parse("</\\1\\s*>|/>").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expectEqualStrings("</", pattern.prefix[0..pattern.prefix_len]);
    try std.testing.expectEqualStrings(">", pattern.suffix[0..pattern.suffix_len]);
    try std.testing.expectEqualStrings("/>", pattern.literal_alt[0..pattern.literal_alt_len]);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "div");
    try std.testing.expectEqual(@as(?usize, 9), match(storage, pattern, "</div   >", 0));
    try std.testing.expectEqual(@as(?usize, 2), match(storage, pattern, "/>", 0));
    try std.testing.expect(match(storage, pattern, "</span>", 0) == null);
}

test "dynamic end parses prefixed backref lookbehind alts" {
    const pattern = parse("/>|(?<=</>)|(?<=</\\2>)").?;
    try std.testing.expectEqual(@as(u8, 2), pattern.slot);
    try std.testing.expect(pattern.prefixed_lookbehind_alt);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "tag");
    try std.testing.expectEqual(@as(?usize, 2), match(storage, pattern, "/>", 0));
    try std.testing.expectEqual(@as(?usize, 6), match(storage, pattern, "</tag>", 6));
    try std.testing.expectEqual(@as(?usize, 3), match(storage, pattern, "</>", 3));
    try std.testing.expect(match(storage, pattern, "</span>", 7) == null);
}

test "dynamic end parses prefixed backref with suffix" {
    const pattern = parse("}\\1\"").?;
    try std.testing.expectEqual(@as(u8, 1), pattern.slot);
    try std.testing.expectEqualStrings("}", pattern.prefix[0..pattern.prefix_len]);
    try std.testing.expectEqualStrings("\"", pattern.suffix[0..pattern.suffix_len]);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "--");
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "}--\"", 0));

    const empty = Storage{};
    try std.testing.expectEqual(@as(?usize, 2), match(empty, pattern, "}\"", 0));
    try std.testing.expect(match(storage, pattern, "}-\"", 0) == null);
}

test "dynamic end parses prefixed backref with optional whitespace newline tail" {
    const plain = parse("\\\\end\\{\\1}(?:\\s*\\n)?").?;
    try std.testing.expectEqual(@as(u8, 1), plain.slot);
    try std.testing.expectEqualStrings("\\end{", plain.prefix[0..plain.prefix_len]);
    try std.testing.expectEqualStrings("}", plain.suffix[0..plain.suffix_len]);

    const grouped = parse("(\\\\end\\{\\2}(?:\\s*\\n)?)").?;
    try std.testing.expectEqual(@as(u8, 2), grouped.slot);
    try std.testing.expectEqualStrings("\\end{", grouped.prefix[0..grouped.prefix_len]);
    try std.testing.expectEqualStrings("}", grouped.suffix[0..grouped.suffix_len]);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "env");
    try std.testing.expectEqual(@as(?usize, 9), match(storage, plain, "\\end{env}", 0));
    try std.testing.expectEqual(@as(?usize, 9), match(storage, grouped, "\\end{env}", 0));
    try std.testing.expect(match(storage, plain, "\\end{other}", 0) == null);
}

test "dynamic end parses prefixed backrefs with horizontal space tails" {
    const grouped = parse("(]\\2])[\\t ]*").?;
    try std.testing.expectEqual(@as(u8, 2), grouped.slot);
    try std.testing.expectEqualStrings("]", grouped.prefix[0..grouped.prefix_len]);
    try std.testing.expectEqualStrings("]", grouped.suffix[0..grouped.suffix_len]);
    try std.testing.expect(grouped.horizontal_space_tail);

    var storage = Storage{ .len = 2 };
    @memcpy(storage.bytes[0..2], "==");
    try std.testing.expectEqual(@as(?usize, 6), match(storage, grouped, "]==] \t", 0));
    try std.testing.expect(match(storage, grouped, "]=]", 0) == null);

    const plain = parse("]\\1][\\t ]*").?;
    try std.testing.expectEqual(@as(u8, 1), plain.slot);
    try std.testing.expect(plain.horizontal_space_tail);
    try std.testing.expectEqual(@as(?usize, 5), match(storage, plain, "]==] ", 0));

    const escaped = parse("\\]\\1\\][ \\t]*").?;
    try std.testing.expectEqual(@as(u8, 1), escaped.slot);
    try std.testing.expectEqualStrings("]", escaped.prefix[0..escaped.prefix_len]);
    try std.testing.expectEqualStrings("]", escaped.suffix[0..escaped.suffix_len]);
    try std.testing.expect(escaped.horizontal_space_tail);
    try std.testing.expectEqual(@as(?usize, 5), match(storage, escaped, "]==] ", 0));
}

test "dynamic end parses anchored grouped backrefs" {
    const pattern = parse("^(\\1)$").?;
    try std.testing.expect(pattern.anchor_start);
    try std.testing.expect(pattern.anchor_end);

    var storage = Storage{ .len = 4 };
    @memcpy(storage.bytes[0..4], "|===");
    try std.testing.expectEqual(@as(?usize, 4), match(storage, pattern, "|===", 0));
    try std.testing.expect(match(storage, pattern, " |===", 1) == null);
}

test "dynamic end parses optional keyword semicolon with alternate capture" {
    const pattern = parse("(?i)(?:\\b(end)\\s+(\\3|\\4)\\s*)?(;)").?;
    try std.testing.expectEqual(@as(u8, 3), pattern.slot);
    try std.testing.expectEqual(@as(u8, 4), pattern.alt_slot);
    try std.testing.expect(pattern.optional_keyword_semicolon);

    var storage = Storage{ .len = 3 };
    @memcpy(storage.bytes[0..3], "Foo");
    try std.testing.expectEqual(@as(?usize, 8), match(storage, pattern, "end foo;", 0));
    try std.testing.expectEqual(@as(?usize, 1), match(storage, pattern, ";", 0));
    try std.testing.expect(match(storage, pattern, "end bar;", 0) == null);
}
