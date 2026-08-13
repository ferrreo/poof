const regex_lowered = @import("lowered.zig");

pub const AtomKind = enum {
    literal,
    any,
    any_byte,
    general_newline,
    digit,
    hex,
    word,
    non_word,
    space,
    non_space,
    byte_class,
    text_segment_boundary,
    absolute_start_anchor,
    search_start_anchor,
    absolute_end_anchor,
    final_newline_end_anchor,
    word_boundary,
    non_word_boundary,
    word_start,
    word_end,
    positive_lookahead,
    negative_lookahead,
    positive_lookbehind,
    negative_lookbehind,
    optional_exact_start,
    literal_alt,
    capture_alt,
    backref,
    lowered,
};

pub const max_lookahead_bytes = 16;
pub const max_alt_count = 8;
pub const max_alt_bytes = 16;
pub const max_captures = 10;

pub const Quantifier = enum { one, zero_or_one, zero_or_more, one_or_more };

pub const Atom = struct {
    kind: AtomKind,
    quantifier: Quantifier = .one,
    lazy: bool = false,
    possessive: bool = false,
    byte: u8 = 0,
    class_mask: [4]u64 = [_]u64{0} ** 4,
    class_negated: bool = false,
    class_scalar_high: bool = false,
    lookahead_bytes: [max_lookahead_bytes]u8 = [_]u8{0} ** max_lookahead_bytes,
    lookahead_len: u8 = 0,
    alt_bytes: [max_alt_count][max_alt_bytes]u8 = [_][max_alt_bytes]u8{[_]u8{0} ** max_alt_bytes} ** max_alt_count,
    alt_lens: [max_alt_count]u8 = [_]u8{0} ** max_alt_count,
    alt_count: u8 = 0,
    capture_slot: u8 = 0,
    ignore_case: bool = false,
    extended: bool = false,
    lowered_kind: regex_lowered.Kind = .bounded_literal,
};

pub const Match = struct { start: usize, end: usize };
pub const Capture = struct { start: usize = 0, end: usize = 0, set: bool = false };
