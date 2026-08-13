const std = @import("std");
const regex_classes = @import("classes.zig");
const regex_match = @import("match.zig");
const unicode_ranges = @import("unicode_ranges.zig");
const unicode_scripts = @import("unicode_scripts.zig");

pub const ScalarRange = unicode_ranges.ScalarRange;

pub const PropertyToken = struct {
    name: []const u8,
    consumed: usize,
};

pub const PropertyOptions = struct {
    ascii_digit: bool = false,
    ascii_word: bool = false,
    ascii_space: bool = false,
    ascii_posix: bool = false,
};

const AsciiProperty = struct {
    mask: [4]u64,
    negated: bool,
};

const letter_ranges = [_]ScalarRange{
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 0x00c0, .hi = 0x00d6 },
    .{ .lo = 0x00d8, .hi = 0x00f6 },
    .{ .lo = 0x00f8, .hi = 0x02af },
    .{ .lo = 0x0370, .hi = 0x03ff },
    .{ .lo = 0x0400, .hi = 0x052f },
    .{ .lo = 0x3400, .hi = 0x4dbf },
    .{ .lo = 0x4e00, .hi = 0x9fff },
    .{ .lo = 0x3040, .hi = 0x309f },
    .{ .lo = 0x30a0, .hi = 0x30ff },
};

const lowercase_letter_ranges = [_]ScalarRange{
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 0x00df, .hi = 0x00f6 },
    .{ .lo = 0x00f8, .hi = 0x00ff },
    .{ .lo = 0x03ac, .hi = 0x03ce },
    .{ .lo = 0x0430, .hi = 0x045f },
};

const uppercase_letter_ranges = [_]ScalarRange{
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = 0x00c0, .hi = 0x00d6 },
    .{ .lo = 0x00d8, .hi = 0x00de },
    .{ .lo = 0x0391, .hi = 0x03ab },
    .{ .lo = 0x0400, .hi = 0x042f },
};

const titlecase_letter_ranges = [_]ScalarRange{
    .{ .lo = 0x01c5, .hi = 0x01c5 },
    .{ .lo = 0x01c8, .hi = 0x01c8 },
    .{ .lo = 0x01cb, .hi = 0x01cb },
    .{ .lo = 0x01f2, .hi = 0x01f2 },
};
const cased_letter_ranges = lowercase_letter_ranges ++ uppercase_letter_ranges ++ titlecase_letter_ranges;

const modifier_letter_ranges = [_]ScalarRange{
    .{ .lo = 0x02b0, .hi = 0x02c1 },
    .{ .lo = 0x02c6, .hi = 0x02d1 },
    .{ .lo = 0x02e0, .hi = 0x02e4 },
};

const other_letter_ranges = [_]ScalarRange{
    .{ .lo = 0x3400, .hi = 0x4dbf },
    .{ .lo = 0x4e00, .hi = 0x9fff },
    .{ .lo = 0x3040, .hi = 0x309f },
    .{ .lo = 0x30a0, .hi = 0x30ff },
};

const number_ranges = [_]ScalarRange{
    .{ .lo = '0', .hi = '9' },
    .{ .lo = 0x0966, .hi = 0x096f },
    .{ .lo = 0x0660, .hi = 0x0669 },
    .{ .lo = 0x06f0, .hi = 0x06f9 },
};

const letter_number_ranges = [_]ScalarRange{
    .{ .lo = 0x16ee, .hi = 0x16f0 },
    .{ .lo = 0x2160, .hi = 0x2182 },
    .{ .lo = 0x2185, .hi = 0x2188 },
    .{ .lo = 0x3007, .hi = 0x3007 },
    .{ .lo = 0x3021, .hi = 0x3029 },
    .{ .lo = 0x3038, .hi = 0x303a },
    .{ .lo = 0xa6e6, .hi = 0xa6ef },
    .{ .lo = 0x10140, .hi = 0x10174 },
    .{ .lo = 0x10341, .hi = 0x10341 },
    .{ .lo = 0x1034a, .hi = 0x1034a },
    .{ .lo = 0x103d1, .hi = 0x103d5 },
    .{ .lo = 0x12400, .hi = 0x1246e },
};

const nonspacing_mark_ranges = [_]ScalarRange{
    .{ .lo = 0x0300, .hi = 0x036f },
    .{ .lo = 0x1ab0, .hi = 0x1aff },
    .{ .lo = 0x1dc0, .hi = 0x1dff },
    .{ .lo = 0xfe20, .hi = 0xfe2f },
    .{ .lo = 0xe0100, .hi = 0xe01ef },
};

const spacing_mark_ranges = [_]ScalarRange{
    .{ .lo = 0x0903, .hi = 0x0903 },
    .{ .lo = 0x093e, .hi = 0x0940 },
    .{ .lo = 0x0949, .hi = 0x094c },
    .{ .lo = 0x0982, .hi = 0x0983 },
};

const enclosing_mark_ranges = [_]ScalarRange{
    .{ .lo = 0x20dd, .hi = 0x20e0 },
    .{ .lo = 0x20e2, .hi = 0x20e4 },
};

const mark_ranges = nonspacing_mark_ranges ++ spacing_mark_ranges ++ enclosing_mark_ranges;

const connector_ranges = [_]ScalarRange{
    .{ .lo = '_', .hi = '_' },
    .{ .lo = 0x203f, .hi = 0x2040 },
    .{ .lo = 0x2054, .hi = 0x2054 },
    .{ .lo = 0xfe33, .hi = 0xfe34 },
    .{ .lo = 0xfe4d, .hi = 0xfe4f },
    .{ .lo = 0xff3f, .hi = 0xff3f },
};

const currency_symbol_ranges = [_]ScalarRange{
    .{ .lo = '$', .hi = '$' },
    .{ .lo = 0x00a2, .hi = 0x00a5 },
    .{ .lo = 0x058f, .hi = 0x058f },
    .{ .lo = 0x060b, .hi = 0x060b },
    .{ .lo = 0x07fe, .hi = 0x07ff },
    .{ .lo = 0x09f2, .hi = 0x09f3 },
    .{ .lo = 0x09fb, .hi = 0x09fb },
    .{ .lo = 0x0af1, .hi = 0x0af1 },
    .{ .lo = 0x0bf9, .hi = 0x0bf9 },
    .{ .lo = 0x0e3f, .hi = 0x0e3f },
    .{ .lo = 0x17db, .hi = 0x17db },
    .{ .lo = 0x20a0, .hi = 0x20c0 },
    .{ .lo = 0xa838, .hi = 0xa838 },
    .{ .lo = 0xfdfc, .hi = 0xfdfc },
    .{ .lo = 0xfe69, .hi = 0xfe69 },
    .{ .lo = 0xff04, .hi = 0xff04 },
    .{ .lo = 0xffe0, .hi = 0xffe1 },
    .{ .lo = 0xffe5, .hi = 0xffe6 },
    .{ .lo = 0x11fdd, .hi = 0x11fe0 },
    .{ .lo = 0x1e2ff, .hi = 0x1e2ff },
    .{ .lo = 0x1ecb0, .hi = 0x1ecb0 },
};

const modifier_symbol_ranges = [_]ScalarRange{
    .{ .lo = '^', .hi = '^' },
    .{ .lo = '`', .hi = '`' },
    .{ .lo = 0x00a8, .hi = 0x00a8 },
    .{ .lo = 0x00af, .hi = 0x00af },
    .{ .lo = 0x00b4, .hi = 0x00b4 },
    .{ .lo = 0x00b8, .hi = 0x00b8 },
    .{ .lo = 0x02c2, .hi = 0x02c5 },
    .{ .lo = 0x02d2, .hi = 0x02df },
    .{ .lo = 0x02e5, .hi = 0x02eb },
    .{ .lo = 0x02ed, .hi = 0x02ed },
    .{ .lo = 0x02ef, .hi = 0x02ff },
    .{ .lo = 0x0375, .hi = 0x0375 },
    .{ .lo = 0x0384, .hi = 0x0385 },
    .{ .lo = 0x1fbd, .hi = 0x1fbd },
    .{ .lo = 0x1fbf, .hi = 0x1fc1 },
    .{ .lo = 0x1fcd, .hi = 0x1fcf },
    .{ .lo = 0x1fdd, .hi = 0x1fdf },
    .{ .lo = 0x1fed, .hi = 0x1fef },
    .{ .lo = 0x1ffd, .hi = 0x1ffe },
    .{ .lo = 0x309b, .hi = 0x309c },
    .{ .lo = 0xa700, .hi = 0xa716 },
    .{ .lo = 0xa720, .hi = 0xa721 },
    .{ .lo = 0xa789, .hi = 0xa78a },
    .{ .lo = 0xab5b, .hi = 0xab5b },
    .{ .lo = 0xfbb2, .hi = 0xfbc2 },
    .{ .lo = 0xff3e, .hi = 0xff3e },
    .{ .lo = 0xff40, .hi = 0xff40 },
    .{ .lo = 0xffe3, .hi = 0xffe3 },
};

const math_symbol_ranges = [_]ScalarRange{
    .{ .lo = 0x002b, .hi = 0x002b },
    .{ .lo = 0x003c, .hi = 0x003e },
    .{ .lo = 0x007c, .hi = 0x007c },
    .{ .lo = 0x007e, .hi = 0x007e },
    .{ .lo = 0x00ac, .hi = 0x00ac },
    .{ .lo = 0x00b1, .hi = 0x00b1 },
    .{ .lo = 0x00d7, .hi = 0x00d7 },
    .{ .lo = 0x00f7, .hi = 0x00f7 },
    .{ .lo = 0x03f6, .hi = 0x03f6 },
    .{ .lo = 0x0606, .hi = 0x0608 },
    .{ .lo = 0x2044, .hi = 0x2044 },
    .{ .lo = 0x2052, .hi = 0x2052 },
    .{ .lo = 0x207a, .hi = 0x207c },
    .{ .lo = 0x208a, .hi = 0x208c },
    .{ .lo = 0x2118, .hi = 0x2118 },
    .{ .lo = 0x2140, .hi = 0x2144 },
    .{ .lo = 0x214b, .hi = 0x214b },
    .{ .lo = 0x2190, .hi = 0x2194 },
    .{ .lo = 0x219a, .hi = 0x219b },
    .{ .lo = 0x21a0, .hi = 0x21a0 },
    .{ .lo = 0x21a3, .hi = 0x21a3 },
    .{ .lo = 0x21a6, .hi = 0x21a6 },
    .{ .lo = 0x21ae, .hi = 0x21ae },
    .{ .lo = 0x21ce, .hi = 0x21cf },
    .{ .lo = 0x21d2, .hi = 0x21d2 },
    .{ .lo = 0x21d4, .hi = 0x21d4 },
    .{ .lo = 0x21f4, .hi = 0x22ff },
    .{ .lo = 0x2320, .hi = 0x2321 },
    .{ .lo = 0x237c, .hi = 0x237c },
    .{ .lo = 0x239b, .hi = 0x23b3 },
    .{ .lo = 0x23dc, .hi = 0x23e1 },
    .{ .lo = 0x25b7, .hi = 0x25b7 },
    .{ .lo = 0x25c1, .hi = 0x25c1 },
    .{ .lo = 0x25f8, .hi = 0x25ff },
    .{ .lo = 0x266f, .hi = 0x266f },
    .{ .lo = 0x27c0, .hi = 0x27c4 },
    .{ .lo = 0x27c7, .hi = 0x27e5 },
    .{ .lo = 0x27f0, .hi = 0x27ff },
    .{ .lo = 0x2900, .hi = 0x2982 },
    .{ .lo = 0x2999, .hi = 0x29d7 },
    .{ .lo = 0x29dc, .hi = 0x29fb },
    .{ .lo = 0x29fe, .hi = 0x2aff },
    .{ .lo = 0x2b30, .hi = 0x2b44 },
    .{ .lo = 0x2b47, .hi = 0x2b4c },
    .{ .lo = 0xfb29, .hi = 0xfb29 },
    .{ .lo = 0xfe62, .hi = 0xfe62 },
    .{ .lo = 0xfe64, .hi = 0xfe66 },
    .{ .lo = 0xff0b, .hi = 0xff0b },
    .{ .lo = 0xff1c, .hi = 0xff1e },
    .{ .lo = 0xff5c, .hi = 0xff5c },
    .{ .lo = 0xff5e, .hi = 0xff5e },
    .{ .lo = 0xffe2, .hi = 0xffe2 },
    .{ .lo = 0xffe9, .hi = 0xffec },
    .{ .lo = 0x1d6c1, .hi = 0x1d6c1 },
    .{ .lo = 0x1d6db, .hi = 0x1d6db },
    .{ .lo = 0x1d6fb, .hi = 0x1d6fb },
    .{ .lo = 0x1d715, .hi = 0x1d715 },
    .{ .lo = 0x1d735, .hi = 0x1d735 },
    .{ .lo = 0x1d74f, .hi = 0x1d74f },
    .{ .lo = 0x1d76f, .hi = 0x1d76f },
    .{ .lo = 0x1d789, .hi = 0x1d789 },
    .{ .lo = 0x1d7a9, .hi = 0x1d7a9 },
    .{ .lo = 0x1d7c3, .hi = 0x1d7c3 },
    .{ .lo = 0x1eef0, .hi = 0x1eef1 },
};

const other_symbol_ranges = [_]ScalarRange{
    .{ .lo = 0x00a6, .hi = 0x00a6 },
    .{ .lo = 0x00a9, .hi = 0x00a9 },
    .{ .lo = 0x00ae, .hi = 0x00ae },
    .{ .lo = 0x00b0, .hi = 0x00b0 },
    .{ .lo = 0x0482, .hi = 0x0482 },
    .{ .lo = 0x058d, .hi = 0x058e },
    .{ .lo = 0x060e, .hi = 0x060f },
    .{ .lo = 0x06de, .hi = 0x06de },
    .{ .lo = 0x06e9, .hi = 0x06e9 },
    .{ .lo = 0x06fd, .hi = 0x06fe },
    .{ .lo = 0x07f6, .hi = 0x07f6 },
    .{ .lo = 0x09fa, .hi = 0x09fa },
    .{ .lo = 0x0b70, .hi = 0x0b70 },
    .{ .lo = 0x0bf3, .hi = 0x0bf8 },
    .{ .lo = 0x0bfa, .hi = 0x0bfa },
    .{ .lo = 0x0c7f, .hi = 0x0c7f },
    .{ .lo = 0x0d4f, .hi = 0x0d4f },
    .{ .lo = 0x0d79, .hi = 0x0d79 },
    .{ .lo = 0x0f01, .hi = 0x0f03 },
    .{ .lo = 0x0f13, .hi = 0x0f13 },
    .{ .lo = 0x0f15, .hi = 0x0f17 },
    .{ .lo = 0x0f1a, .hi = 0x0f1f },
    .{ .lo = 0x0f34, .hi = 0x0f34 },
    .{ .lo = 0x0f36, .hi = 0x0f36 },
    .{ .lo = 0x0f38, .hi = 0x0f38 },
    .{ .lo = 0x0fbe, .hi = 0x0fc5 },
    .{ .lo = 0x0fc7, .hi = 0x0fcc },
    .{ .lo = 0x0fce, .hi = 0x0fcf },
    .{ .lo = 0x0fd5, .hi = 0x0fd8 },
    .{ .lo = 0x109e, .hi = 0x109f },
    .{ .lo = 0x1390, .hi = 0x1399 },
    .{ .lo = 0x166d, .hi = 0x166d },
    .{ .lo = 0x1940, .hi = 0x1940 },
    .{ .lo = 0x19de, .hi = 0x19ff },
    .{ .lo = 0x1b61, .hi = 0x1b6a },
    .{ .lo = 0x1b74, .hi = 0x1b7c },
    .{ .lo = 0x2100, .hi = 0x2101 },
    .{ .lo = 0x2103, .hi = 0x2106 },
    .{ .lo = 0x2108, .hi = 0x2109 },
    .{ .lo = 0x2114, .hi = 0x2114 },
    .{ .lo = 0x2116, .hi = 0x2117 },
    .{ .lo = 0x211e, .hi = 0x2123 },
    .{ .lo = 0x2125, .hi = 0x2125 },
    .{ .lo = 0x2127, .hi = 0x2127 },
    .{ .lo = 0x2129, .hi = 0x2129 },
    .{ .lo = 0x212e, .hi = 0x212e },
    .{ .lo = 0x213a, .hi = 0x213b },
    .{ .lo = 0x214a, .hi = 0x214a },
    .{ .lo = 0x214c, .hi = 0x214d },
    .{ .lo = 0x214f, .hi = 0x214f },
    .{ .lo = 0x218a, .hi = 0x218b },
    .{ .lo = 0x2195, .hi = 0x2199 },
    .{ .lo = 0x219c, .hi = 0x219f },
    .{ .lo = 0x21a1, .hi = 0x21a2 },
    .{ .lo = 0x21a4, .hi = 0x21a5 },
    .{ .lo = 0x21a7, .hi = 0x21ad },
    .{ .lo = 0x21af, .hi = 0x21cd },
    .{ .lo = 0x21d0, .hi = 0x21d1 },
    .{ .lo = 0x21d3, .hi = 0x21d3 },
    .{ .lo = 0x21d5, .hi = 0x21f3 },
    .{ .lo = 0x2300, .hi = 0x2307 },
    .{ .lo = 0x230c, .hi = 0x231f },
    .{ .lo = 0x2322, .hi = 0x2328 },
    .{ .lo = 0x232b, .hi = 0x237b },
    .{ .lo = 0x237d, .hi = 0x239a },
    .{ .lo = 0x23b4, .hi = 0x23db },
    .{ .lo = 0x23e2, .hi = 0x2426 },
    .{ .lo = 0x2440, .hi = 0x244a },
    .{ .lo = 0x249c, .hi = 0x24e9 },
    .{ .lo = 0x2500, .hi = 0x25b6 },
    .{ .lo = 0x25b8, .hi = 0x25c0 },
    .{ .lo = 0x25c2, .hi = 0x25f7 },
    .{ .lo = 0x2600, .hi = 0x266e },
    .{ .lo = 0x2670, .hi = 0x2767 },
    .{ .lo = 0x2794, .hi = 0x27bf },
    .{ .lo = 0x2800, .hi = 0x28ff },
    .{ .lo = 0x2b00, .hi = 0x2b2f },
    .{ .lo = 0x2b45, .hi = 0x2b46 },
    .{ .lo = 0x2b4d, .hi = 0x2b73 },
    .{ .lo = 0x2b76, .hi = 0x2b95 },
    .{ .lo = 0x2b97, .hi = 0x2bff },
    .{ .lo = 0x2ce5, .hi = 0x2cea },
    .{ .lo = 0x2e50, .hi = 0x2e51 },
    .{ .lo = 0x2e80, .hi = 0x2e99 },
    .{ .lo = 0x2e9b, .hi = 0x2ef3 },
    .{ .lo = 0x2f00, .hi = 0x2fd5 },
    .{ .lo = 0x2ff0, .hi = 0x2fff },
    .{ .lo = 0x3004, .hi = 0x3004 },
    .{ .lo = 0x3012, .hi = 0x3013 },
    .{ .lo = 0x3020, .hi = 0x3020 },
    .{ .lo = 0x3036, .hi = 0x3037 },
    .{ .lo = 0x303e, .hi = 0x303f },
    .{ .lo = 0x3190, .hi = 0x3191 },
    .{ .lo = 0x3196, .hi = 0x319f },
    .{ .lo = 0x31c0, .hi = 0x31e3 },
    .{ .lo = 0x31ef, .hi = 0x31ef },
    .{ .lo = 0x3200, .hi = 0x321e },
    .{ .lo = 0x322a, .hi = 0x3247 },
    .{ .lo = 0x3250, .hi = 0x3250 },
    .{ .lo = 0x3260, .hi = 0x327f },
    .{ .lo = 0x328a, .hi = 0x32b0 },
    .{ .lo = 0x32c0, .hi = 0x33ff },
    .{ .lo = 0x4dc0, .hi = 0x4dff },
    .{ .lo = 0xa490, .hi = 0xa4c6 },
    .{ .lo = 0xa828, .hi = 0xa82b },
    .{ .lo = 0xa836, .hi = 0xa837 },
    .{ .lo = 0xa839, .hi = 0xa839 },
    .{ .lo = 0xaa77, .hi = 0xaa79 },
    .{ .lo = 0xfd40, .hi = 0xfd4f },
    .{ .lo = 0xfdcf, .hi = 0xfdcf },
    .{ .lo = 0xfdfd, .hi = 0xfdff },
    .{ .lo = 0xffe4, .hi = 0xffe4 },
    .{ .lo = 0xffe8, .hi = 0xffe8 },
    .{ .lo = 0xffed, .hi = 0xffee },
    .{ .lo = 0xfffc, .hi = 0xfffd },
    .{ .lo = 0x10137, .hi = 0x1013f },
    .{ .lo = 0x10179, .hi = 0x10189 },
    .{ .lo = 0x1018c, .hi = 0x1018e },
    .{ .lo = 0x10190, .hi = 0x1019c },
    .{ .lo = 0x101a0, .hi = 0x101a0 },
    .{ .lo = 0x101d0, .hi = 0x101fc },
    .{ .lo = 0x10877, .hi = 0x10878 },
    .{ .lo = 0x10ac8, .hi = 0x10ac8 },
    .{ .lo = 0x1173f, .hi = 0x1173f },
    .{ .lo = 0x11fd5, .hi = 0x11fdc },
    .{ .lo = 0x11fe1, .hi = 0x11ff1 },
    .{ .lo = 0x16b3c, .hi = 0x16b3f },
    .{ .lo = 0x16b45, .hi = 0x16b45 },
    .{ .lo = 0x1bc9c, .hi = 0x1bc9c },
    .{ .lo = 0x1cf50, .hi = 0x1cfc3 },
    .{ .lo = 0x1d000, .hi = 0x1d0f5 },
    .{ .lo = 0x1d100, .hi = 0x1d126 },
    .{ .lo = 0x1d129, .hi = 0x1d164 },
    .{ .lo = 0x1d16a, .hi = 0x1d16c },
    .{ .lo = 0x1d183, .hi = 0x1d184 },
    .{ .lo = 0x1d18c, .hi = 0x1d1a9 },
    .{ .lo = 0x1d1ae, .hi = 0x1d1ea },
    .{ .lo = 0x1d200, .hi = 0x1d241 },
    .{ .lo = 0x1d245, .hi = 0x1d245 },
    .{ .lo = 0x1d300, .hi = 0x1d356 },
    .{ .lo = 0x1d800, .hi = 0x1d9ff },
    .{ .lo = 0x1da37, .hi = 0x1da3a },
    .{ .lo = 0x1da6d, .hi = 0x1da74 },
    .{ .lo = 0x1da76, .hi = 0x1da83 },
    .{ .lo = 0x1da85, .hi = 0x1da86 },
    .{ .lo = 0x1e14f, .hi = 0x1e14f },
    .{ .lo = 0x1ecac, .hi = 0x1ecac },
    .{ .lo = 0x1ed2e, .hi = 0x1ed2e },
    .{ .lo = 0x1f000, .hi = 0x1f02b },
    .{ .lo = 0x1f030, .hi = 0x1f093 },
    .{ .lo = 0x1f0a0, .hi = 0x1f0ae },
    .{ .lo = 0x1f0b1, .hi = 0x1f0bf },
    .{ .lo = 0x1f0c1, .hi = 0x1f0cf },
    .{ .lo = 0x1f0d1, .hi = 0x1f0f5 },
    .{ .lo = 0x1f10d, .hi = 0x1f1ad },
    .{ .lo = 0x1f1e6, .hi = 0x1f202 },
    .{ .lo = 0x1f210, .hi = 0x1f23b },
    .{ .lo = 0x1f240, .hi = 0x1f248 },
    .{ .lo = 0x1f250, .hi = 0x1f251 },
    .{ .lo = 0x1f260, .hi = 0x1f265 },
    .{ .lo = 0x1f300, .hi = 0x1f3fa },
    .{ .lo = 0x1f400, .hi = 0x1f6d7 },
    .{ .lo = 0x1f6dc, .hi = 0x1f6ec },
    .{ .lo = 0x1f6f0, .hi = 0x1f6fc },
    .{ .lo = 0x1f700, .hi = 0x1f776 },
    .{ .lo = 0x1f77b, .hi = 0x1f7d9 },
    .{ .lo = 0x1f7e0, .hi = 0x1f7eb },
    .{ .lo = 0x1f7f0, .hi = 0x1f7f0 },
    .{ .lo = 0x1f800, .hi = 0x1f80b },
    .{ .lo = 0x1f810, .hi = 0x1f847 },
    .{ .lo = 0x1f850, .hi = 0x1f859 },
    .{ .lo = 0x1f860, .hi = 0x1f887 },
    .{ .lo = 0x1f890, .hi = 0x1f8ad },
    .{ .lo = 0x1f8b0, .hi = 0x1f8b1 },
    .{ .lo = 0x1f900, .hi = 0x1fa53 },
    .{ .lo = 0x1fa60, .hi = 0x1fa6d },
    .{ .lo = 0x1fa70, .hi = 0x1fa7c },
    .{ .lo = 0x1fa80, .hi = 0x1fa88 },
    .{ .lo = 0x1fa90, .hi = 0x1fabd },
    .{ .lo = 0x1fabf, .hi = 0x1fac5 },
    .{ .lo = 0x1face, .hi = 0x1fadb },
    .{ .lo = 0x1fae0, .hi = 0x1fae8 },
    .{ .lo = 0x1faf0, .hi = 0x1faf8 },
    .{ .lo = 0x1fb00, .hi = 0x1fb92 },
    .{ .lo = 0x1fb94, .hi = 0x1fbca },
};

const symbol_ranges = math_symbol_ranges ++ currency_symbol_ranges ++ modifier_symbol_ranges ++ other_symbol_ranges;

const other_number_ranges = [_]ScalarRange{
    .{ .lo = 0x00b2, .hi = 0x00b3 },
    .{ .lo = 0x00b9, .hi = 0x00b9 },
    .{ .lo = 0x00bc, .hi = 0x00be },
    .{ .lo = 0x09f4, .hi = 0x09f9 },
    .{ .lo = 0x0b72, .hi = 0x0b77 },
    .{ .lo = 0x0bf0, .hi = 0x0bf2 },
    .{ .lo = 0x0c78, .hi = 0x0c7e },
    .{ .lo = 0x0d58, .hi = 0x0d5e },
    .{ .lo = 0x0d70, .hi = 0x0d78 },
    .{ .lo = 0x0f2a, .hi = 0x0f33 },
    .{ .lo = 0x1369, .hi = 0x137c },
    .{ .lo = 0x17f0, .hi = 0x17f9 },
    .{ .lo = 0x19da, .hi = 0x19da },
    .{ .lo = 0x2070, .hi = 0x2070 },
    .{ .lo = 0x2074, .hi = 0x2079 },
    .{ .lo = 0x2080, .hi = 0x2089 },
    .{ .lo = 0x2150, .hi = 0x2182 },
    .{ .lo = 0x2185, .hi = 0x2189 },
    .{ .lo = 0x2460, .hi = 0x249b },
    .{ .lo = 0x24ea, .hi = 0x24ff },
    .{ .lo = 0x2776, .hi = 0x2793 },
    .{ .lo = 0x2cfd, .hi = 0x2cfd },
    .{ .lo = 0x3192, .hi = 0x3195 },
    .{ .lo = 0x3220, .hi = 0x3229 },
    .{ .lo = 0x3248, .hi = 0x324f },
    .{ .lo = 0x3251, .hi = 0x325f },
    .{ .lo = 0x3280, .hi = 0x3289 },
    .{ .lo = 0x32b1, .hi = 0x32bf },
};

const space_separator_ranges = [_]ScalarRange{
    .{ .lo = 0x0020, .hi = 0x0020 },
    .{ .lo = 0x00a0, .hi = 0x00a0 },
    .{ .lo = 0x1680, .hi = 0x1680 },
    .{ .lo = 0x2000, .hi = 0x200a },
    .{ .lo = 0x202f, .hi = 0x202f },
    .{ .lo = 0x205f, .hi = 0x205f },
    .{ .lo = 0x3000, .hi = 0x3000 },
};

const line_separator_ranges = [_]ScalarRange{.{ .lo = 0x2028, .hi = 0x2028 }};
const paragraph_separator_ranges = [_]ScalarRange{.{ .lo = 0x2029, .hi = 0x2029 }};
const separator_ranges = space_separator_ranges ++ line_separator_ranges ++ paragraph_separator_ranges;
const newline_ranges = [_]ScalarRange{.{ .lo = '\n', .hi = '\n' }};
const ascii_space_ranges = [_]ScalarRange{
    .{ .lo = 0x0009, .hi = 0x000d },
    .{ .lo = 0x0085, .hi = 0x0085 },
};
const blank_ranges = [_]ScalarRange{.{ .lo = 0x0009, .hi = 0x0009 }} ++ space_separator_ranges;
const white_space_ranges = ascii_space_ranges ++ separator_ranges;

pub fn propertyName(body: []const u8) ?PropertyToken {
    if (body.len == 0 or body[0] != '{') return null;
    const close = std.mem.indexOfScalar(u8, body[1..], '}') orelse return null;
    return .{ .name = body[1 .. close + 1], .consumed = close + 2 };
}

pub fn scalarRangesForProperty(name: []const u8) ?[]const ScalarRange {
    if (propertyValue(name, &.{ "gc", "General_Category" })) |value| return scalarRangesForProperty(value);
    if (propertyValue(name, &.{ "sc", "Script" })) |value| return scriptRangesForProperty(value);
    if (unicodeName(name, "L") or unicodeName(name, "Letter") or unicodeName(name, "Alpha") or unicodeName(name, "Alphabetic")) return &letter_ranges;
    if (unicodeName(name, "Ll") or unicodeName(name, "Lower") or unicodeName(name, "Lowercase") or unicodeName(name, "Lowercase_Letter")) return &lowercase_letter_ranges;
    if (unicodeName(name, "Lu") or unicodeName(name, "Upper") or unicodeName(name, "Uppercase") or unicodeName(name, "Uppercase_Letter")) return &uppercase_letter_ranges;
    if (unicodeName(name, "Lt") or unicodeName(name, "Titlecase_Letter")) return &titlecase_letter_ranges;
    if (unicodeName(name, "LC") or unicodeName(name, "Cased_Letter")) return &cased_letter_ranges;
    if (unicodeName(name, "Lm") or unicodeName(name, "Modifier_Letter")) return &modifier_letter_ranges;
    if (unicodeName(name, "Lo") or unicodeName(name, "Other_Letter")) return &other_letter_ranges;
    if (unicodeName(name, "N") or unicodeName(name, "Number") or unicodeName(name, "Digit") or unicodeName(name, "Nd") or unicodeName(name, "Decimal_Number")) return &number_ranges;
    if (unicodeName(name, "Nl") or unicodeName(name, "Letter_Number")) return &letter_number_ranges;
    if (unicodeName(name, "M") or unicodeName(name, "Mark")) return &mark_ranges;
    if (unicodeName(name, "Mn") or unicodeName(name, "Nonspacing_Mark")) return &nonspacing_mark_ranges;
    if (unicodeName(name, "Mc") or unicodeName(name, "Spacing_Mark")) return &spacing_mark_ranges;
    if (unicodeName(name, "Me") or unicodeName(name, "Enclosing_Mark")) return &enclosing_mark_ranges;
    if (unicodeName(name, "Pc") or unicodeName(name, "Connector_Punctuation")) return &connector_ranges;
    if (unicodeName(name, "P") or unicodeName(name, "Punctuation")) return &unicode_ranges.punctuation;
    if (unicodeName(name, "Pd") or unicodeName(name, "Dash_Punctuation")) return &unicode_ranges.dash_punctuation;
    if (unicodeName(name, "Ps") or unicodeName(name, "Open_Punctuation")) return &unicode_ranges.open_punctuation;
    if (unicodeName(name, "Pe") or unicodeName(name, "Close_Punctuation")) return &unicode_ranges.close_punctuation;
    if (unicodeName(name, "Pi") or unicodeName(name, "Initial_Punctuation")) return &unicode_ranges.initial_punctuation;
    if (unicodeName(name, "Pf") or unicodeName(name, "Final_Punctuation")) return &unicode_ranges.final_punctuation;
    if (unicodeName(name, "Po") or unicodeName(name, "Other_Punctuation")) return &unicode_ranges.other_punctuation;
    if (scriptRangesForProperty(name)) |ranges| return ranges;
    if (blockRangesForProperty(name)) |ranges| return ranges;
    if (unicodeName(name, "C") or unicodeName(name, "Other")) return &unicode_ranges.other;
    if (unicodeName(name, "Cc") or unicodeName(name, "Control")) return &unicode_ranges.control;
    if (unicodeName(name, "Cf") or unicodeName(name, "Format")) return &unicode_ranges.format;
    if (unicodeName(name, "Co") or unicodeName(name, "Private_Use")) return &unicode_ranges.private_use;
    if (unicodeName(name, "S") or unicodeName(name, "Symbol")) return &symbol_ranges;
    if (unicodeName(name, "Sm") or unicodeName(name, "Math_Symbol")) return &math_symbol_ranges;
    if (unicodeName(name, "Sc") or unicodeName(name, "Currency_Symbol")) return &currency_symbol_ranges;
    if (unicodeName(name, "Sk") or unicodeName(name, "Modifier_Symbol")) return &modifier_symbol_ranges;
    if (unicodeName(name, "So") or unicodeName(name, "Other_Symbol")) return &other_symbol_ranges;
    if (unicodeName(name, "No") or unicodeName(name, "Other_Number")) return &other_number_ranges;
    if (isSpaceProperty(name)) return &white_space_ranges;
    if (unicodeName(name, "Blank")) return &blank_ranges;
    if (unicodeName(name, "Z") or unicodeName(name, "Separator")) return &separator_ranges;
    if (unicodeName(name, "Zs") or unicodeName(name, "Space_Separator")) return &space_separator_ranges;
    if (unicodeName(name, "Zl") or unicodeName(name, "Line_Separator")) return &line_separator_ranges;
    if (unicodeName(name, "Zp") or unicodeName(name, "Paragraph_Separator")) return &paragraph_separator_ranges;
    if (unicodeName(name, "Newline")) return &newline_ranges;
    return null;
}

fn propertyValue(name: []const u8, comptime keys: []const []const u8) ?[]const u8 {
    const split = std.mem.indexOfScalar(u8, name, '=') orelse return null;
    inline for (keys) |key| {
        if (unicodeName(name[0..split], key)) return name[split + 1 ..];
    }
    return null;
}

fn scriptRangesForProperty(name: []const u8) ?[]const ScalarRange {
    for (unicode_scripts.scripts) |script| {
        for (script.names) |alias| {
            if (unicodeName(name, alias)) return script.ranges;
        }
    }
    return null;
}

fn blockRangesForProperty(name: []const u8) ?[]const ScalarRange {
    for (unicode_ranges.blocks) |block| {
        for (block.names) |alias| {
            if (unicodeName(name, alias)) return block.ranges;
        }
    }
    return null;
}

pub fn isWordProperty(name: []const u8) bool {
    return unicodeName(name, "Word");
}

pub fn isSpaceProperty(name: []const u8) bool {
    return unicodeName(name, "Space") or unicodeName(name, "White_Space") or unicodeName(name, "Whitespace");
}

pub fn matchScalarRanges(text: []const u8, pos: usize, ranges: []const ScalarRange) ?bool {
    const scalar = scalarAt(text, pos) orelse return null;
    for (ranges) |range| {
        if (scalar >= range.lo and scalar <= range.hi) return true;
    }
    return false;
}

pub fn matchPropertyEscape(body: []const u8, text: []const u8, pos: usize, negated: bool, options: PropertyOptions) ?usize {
    if (propertyName(body)) |property| {
        if (asciiProperty(property.name, negated, options)) |ascii| {
            return if (pos < text.len and regex_classes.contains(ascii.mask, text[pos]) != ascii.negated) pos + 1 else null;
        }
        if (unicodeName(property.name, "Alnum")) {
            const matched = (matchScalarRanges(text, pos, &letter_ranges) orelse false) or
                (matchScalarRanges(text, pos, &number_ranges) orelse false);
            return if (matched != negated) scalarEnd(text, pos) else null;
        }
        if (isWordProperty(property.name)) {
            if (regex_match.wordAt(text, pos)) |next| return if (negated) null else next;
            return if (negated and pos < text.len) scalarEnd(text, pos) else null;
        }
        if (scalarRangesForProperty(property.name)) |ranges| {
            const matched = matchScalarRanges(text, pos, ranges) orelse return null;
            return if (matched != negated) scalarEnd(text, pos) else null;
        }
    }
    var mask = [_]u64{0} ** 4;
    _ = (if (options.ascii_space or options.ascii_posix)
        regex_classes.addUnicodePropertyTokenAsciiSpace(&mask, body, false)
    else
        regex_classes.addUnicodePropertyToken(&mask, body, false)) orelse return null;
    return if (pos < text.len and regex_classes.contains(mask, text[pos]) != negated) scalarEnd(text, pos) else null;
}

fn asciiProperty(name_raw: []const u8, negated_raw: bool, options: PropertyOptions) ?AsciiProperty {
    var name = name_raw;
    var negated = negated_raw;
    if (name.len != 0 and name[0] == '^') {
        name = name[1..];
        negated = !negated;
    }
    var mask = [_]u64{0} ** 4;
    const ascii = if (options.ascii_posix and regex_classes.addPosix(&mask, name))
        true
    else if (options.ascii_digit and (unicodeName(name, "Digit") or unicodeName(name, "Nd") or unicodeName(name, "Decimal_Number"))) blk: {
        _ = regex_classes.addPosix(&mask, "digit");
        break :blk true;
    } else if (options.ascii_word and isWordProperty(name)) blk: {
        _ = regex_classes.addPosix(&mask, "word");
        break :blk true;
    } else if (options.ascii_space and isSpaceProperty(name)) blk: {
        regex_classes.addAsciiSpace(&mask);
        break :blk true;
    } else false;
    if (!ascii) return null;
    return .{ .mask = mask, .negated = negated };
}

pub fn scalarEnd(text: []const u8, pos: usize) usize {
    return regex_match.scalarEnd(text, pos);
}

fn scalarAt(text: []const u8, pos: usize) ?u21 {
    if (pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + len > text.len) return null;
    return std.unicode.utf8Decode(text[pos..][0..len]) catch null;
}

fn unicodeName(actual: []const u8, expected: []const u8) bool {
    var ai: usize = 0;
    var ei: usize = 0;
    while (true) {
        while (ai < actual.len and isNameSeparator(actual[ai])) ai += 1;
        while (ei < expected.len and isNameSeparator(expected[ei])) ei += 1;
        if (ai == actual.len or ei == expected.len) return ai == actual.len and ei == expected.len;
        if (std.ascii.toLower(actual[ai]) != std.ascii.toLower(expected[ei])) return false;
        ai += 1;
        ei += 1;
    }
}

fn isNameSeparator(byte: u8) bool {
    return byte == '_' or byte == '-' or byte == ' ';
}

test "Unicode property matcher handles Greek script ranges" {
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Greek}", "α", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Greek}", "a", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Greek}", "a", 0, true, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Latin}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Cyrillic}", "Ж", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Han}", "漢", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hiragana}", "あ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Katakana}", "ア", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Hebrew}", "א", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Arabic}", "ش", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Grek}", "α", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Latn}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Cyrl}", "Ж", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hani}", "漢", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hira}", "あ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Kana}", "ア", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Hebr}", "א", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Arab}", "ش", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Common}", "!", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Zyyy}", "€", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Inherited}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Zinh}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Common}", "α", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Devanagari}", "अ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Deva}", "अ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Thai}", "ก", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hangul}", "가", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hang}", "가", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bopomofo}", "ㄅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bopo}", "ㄅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Armenian}", "Ա", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Armn}", "Ա", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Georgian}", "ა", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Geor}", "ა", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Runic}", "ᚠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Ethi}", "ሀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Khmer}", "ក", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Khmr}", "ក", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Lao}", "ກ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Laoo}", "ກ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Myanmar}", "က", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Sinh}", "අ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tamil}", "அ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Taml}", "அ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Telugu}", "అ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Kannada}", "ಅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Malayalam}", "അ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Malayalam}", "ᰀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bengali}", "অ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Beng}", "অ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Gurmukhi}", "ਅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Gujarati}", "અ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Oriya}", "ଅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tibetan}", "ཀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Balinese}", "ᬅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bali}", "ᬅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Batak}", "ᯀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Batk}", "ᯀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Buginese}", "ᨀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bugi}", "ᨀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Cham}", "ꨀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Javanese}", "ꦄ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Java}", "ꦄ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Lepcha}", "ᰀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Lepc}", "ᰀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Limbu}", "ᤀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Limb}", "ᤀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{New_Tai_Lue}", "ᦀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Talu}", "ᦀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tai_Le}", "ᥐ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tale}", "ᥐ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Rejang}", "ꤰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Rjng}", "ꤰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Adlam}", "𞤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Adlm}", "𞤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Ahom}", "𑜀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Avestan}", "𐬀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Avst}", "𐬀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Bassa_Vah}", "𖫐", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Bass}", "𖫐", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Bhaiksuki}", "𑰀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Bhks}", "𑰀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Brahmi}", "𑀅", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Brah}", "𑀅", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Carian}", "𐊠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Cari}", "𐊠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Caucasian_Albanian}", "𐔰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Aghb}", "𐔰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Chakma}", "𑄃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Cakm}", "𑄃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Cuneiform}", "𒀀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Xsux}", "𒀀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Dives_Akuru}", "𑤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Diak}", "𑤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Dogra}", "𑠀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Dogr}", "𑠀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Duployan}", "𛱰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Dupl}", "𛱰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Egyptian_Hieroglyphs}", "𓀀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Egyp}", "𓀀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Elbasan}", "𐔀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Elba}", "𐔀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Elymaic}", "𐿠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Elym}", "𐿠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Glagolitic}", "Ⰰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Glag}", "Ⰰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Grantha}", "𑌅", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Gran}", "𑌅", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Gunjala_Gondi}", "𑵠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Gong}", "𑵠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Hanifi_Rohingya}", "𐴀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Rohg}", "𐴀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Imperial_Aramaic}", "𐡀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Armi}", "𐡀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Inscriptional_Parthian}", "𐭀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Prti}", "𐭀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Inscriptional_Pahlavi}", "𐭠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Phli}", "𐭠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Kaithi}", "𑂃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Kthi}", "𑂃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Khojki}", "𑈀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Khoj}", "𑈀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Khitan_Small_Script}", "𘬀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Kits}", "𘬀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Lycian}", "𐊀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Lyci}", "𐊀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Lydian}", "𐤠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Lydi}", "𐤠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mahajani}", "𑅐", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mahj}", "𑅐", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Makasar}", "𑻠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Maka}", "𑻠", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Mandaic}", "ࡀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Mand}", "ࡀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Manichaean}", "\u{10ac0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mani}", "\u{10ac0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Marchen}", "\u{11c70}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Marc}", "\u{11c70}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Masaram_Gondi}", "\u{11d00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Gonm}", "\u{11d00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Medefaidrin}", "\u{16e40}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Medf}", "\u{16e40}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mende_Kikakui}", "\u{1e800}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mend}", "\u{1e800}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Meroitic_Cursive}", "\u{109a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Merc}", "\u{109a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Meroitic_Hieroglyphs}", "\u{10980}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mero}", "\u{10980}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Miao}", "\u{16f00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Plrd}", "\u{16f00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Modi}", "\u{11600}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Multani}", "\u{11280}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Mult}", "\u{11280}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nabataean}", "\u{10880}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nbat}", "\u{10880}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nandinagari}", "\u{119a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nand}", "\u{119a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Newa}", "\u{11400}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nushu}", "\u{1b170}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Nshu}", "\u{1b170}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Old_North_Arabian}", "\u{10a80}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Narb}", "\u{10a80}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Old_Permic}", "\u{10350}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Perm}", "\u{10350}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Old_Persian}", "\u{103a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Xpeo}", "\u{103a0}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Old_Sogdian}", "\u{10f00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Sogo}", "\u{10f00}", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Syriac}", "ܐ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Thaana}", "ހ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Nko}", "ߊ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Cherokee}", "Ꭰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Canadian_Aboriginal}", "ᐁ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Ogham}", "ᚁ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Mongolian}", "ᠠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Coptic}", "Ⲁ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Gothic}", "𐌰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Deseret}", "𐐀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 4), matchPropertyEscape("{Old_Italic}", "𐌀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tagalog}", "ᜀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Hanunoo}", "ᜠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Buhid}", "ᝀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tagbanwa}", "ᝠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Yi}", "ꀀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Yiii}", "ꀀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Braille}", "⠀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Brai}", "⠀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tifinagh}", "ⴰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Tfng}", "ⴰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Vai}", "ꔀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Vaii}", "ꔀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Lisu}", "ꓐ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bamum}", "ꚠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Bamu}", "ꚠ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Syloti_Nagri}", "ꠀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Sylo}", "ꠀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Phags_Pa}", "ꡀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Phag}", "ꡀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Saurashtra}", "ꢂ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Saur}", "ꢂ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Kayah_Li}", "꤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Kali}", "꤀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{In_Basic_Latin}", "A", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{InBasicLatin}", "A", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Latin_1_Supplement}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Latin_Extended_A}", "Ā", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Latin_Extended_B}", "ƀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_IPA_Extensions}", "ɐ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Spacing_Modifier_Letters}", "ʰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Combining_Diacritical_Marks}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Greek_and_Coptic}", "α", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Cyrillic}", "Ж", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Hebrew}", "א", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{In_Arabic}", "ش", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Devanagari}", "अ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Thai}", "ก", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Hangul_Jamo}", "ᄀ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Hiragana}", "あ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Katakana}", "ア", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Bopomofo}", "ㄅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Hangul_Compatibility_Jamo}", "ㄱ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Katakana_Phonetic_Extensions}", "ㇰ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_CJK_Symbols_and_Punctuation}", "、", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_CJK_Compatibility}", "㌀", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_CJK_Unified_Ideographs}", "漢", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Hangul_Syllables}", "가", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_CJK_Compatibility_Ideographs}", "豈", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_CJK_Compatibility_Forms}", "︰", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{In_Halfwidth_and_Fullwidth_Forms}", "Ａ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Lower}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{gc=Ll}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{General_Category=Lowercase_Letter}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Lowercase}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Upper}", "É", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Uppercase}", "É", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{LC}", "ǅ", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Cased_Letter}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Word}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Script=Latin}", "é", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{sc=Hani}", "漢", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Word}", "é", 0, true, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Word}", "!", 0, true, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Cf}", "\xe2\x80\x8c", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Cf}", "a", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Cc}", "\xc2\x85", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Control}", "\xc2\x85", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Co}", "\xee\x80\x80", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Private_Use}", "\xee\x80\x80", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{C}", "\xc2\x85", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{C}", "\xee\x80\x80", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{S}", "€", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Symbol}", "☃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Sm}", "≤", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{So}", "☃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Sm}", "☃", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Sc}", "€", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Sk}", "^", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{No}", "²", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Space}", "\xc2\xa0", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{White_Space}", "\xc2\xa0", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Whitespace}", "\xc2\xa0", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Blank}", "\xc2\xa0", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Space}", "\xc2\xa0", 0, false, .{ .ascii_space = true }));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Space}", "\xc2\xa0", 0, true, .{ .ascii_space = true }));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Zs}", "\xc2\xa0", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Space_Separator}", "\xe2\x80\x87", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Zl}", "\xe2\x80\xa8", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Zp}", "\xe2\x80\xa9", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Z}", "\xe2\x80\xa9", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Z}", "A", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 1), matchPropertyEscape("{Newline}", "\n", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Newline}", "\r", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{P}", "—", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Punctuation}", "。", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Pd}", "—", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Ps}", "（", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Pe}", "）", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Pi}", "«", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Pf}", "»", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Po}", "。", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Mn}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 2), matchPropertyEscape("{Nonspacing_Mark}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Mc}", "ः", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Spacing_Mark}", "ः", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Me}", "⃝", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, 3), matchPropertyEscape("{Enclosing_Mark}", "⃝", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Mc}", "́", 0, false, .{}));
    try std.testing.expectEqual(@as(?usize, null), matchPropertyEscape("{Mn}", "ः", 0, false, .{}));
}
