pub const ScalarRange = struct {
    lo: u21,
    hi: u21,
};

const connector_punctuation = [_]ScalarRange{
    .{ .lo = '_', .hi = '_' },
    .{ .lo = 0x203f, .hi = 0x2040 },
    .{ .lo = 0x2054, .hi = 0x2054 },
    .{ .lo = 0xfe33, .hi = 0xfe34 },
    .{ .lo = 0xfe4d, .hi = 0xfe4f },
    .{ .lo = 0xff3f, .hi = 0xff3f },
};

pub const dash_punctuation = [_]ScalarRange{
    .{ .lo = '-', .hi = '-' },
    .{ .lo = 0x058a, .hi = 0x058a },
    .{ .lo = 0x05be, .hi = 0x05be },
    .{ .lo = 0x2010, .hi = 0x2015 },
    .{ .lo = 0x2e3a, .hi = 0x2e3b },
    .{ .lo = 0xfe31, .hi = 0xfe32 },
    .{ .lo = 0xff0d, .hi = 0xff0d },
};

pub const open_punctuation = [_]ScalarRange{
    .{ .lo = '(', .hi = '(' },
    .{ .lo = '[', .hi = '[' },
    .{ .lo = '{', .hi = '{' },
    .{ .lo = 0x2018, .hi = 0x2018 },
    .{ .lo = 0x201c, .hi = 0x201c },
    .{ .lo = 0xff08, .hi = 0xff08 },
};

pub const close_punctuation = [_]ScalarRange{
    .{ .lo = ')', .hi = ')' },
    .{ .lo = ']', .hi = ']' },
    .{ .lo = '}', .hi = '}' },
    .{ .lo = 0x2019, .hi = 0x2019 },
    .{ .lo = 0x201d, .hi = 0x201d },
    .{ .lo = 0xff09, .hi = 0xff09 },
};

pub const other_punctuation = [_]ScalarRange{
    .{ .lo = '!', .hi = '#' },
    .{ .lo = '%', .hi = '*' },
    .{ .lo = ',', .hi = '/' },
    .{ .lo = ':', .hi = ';' },
    .{ .lo = '?', .hi = '@' },
    .{ .lo = '\\', .hi = '\\' },
    .{ .lo = 0x00a1, .hi = 0x00a1 },
    .{ .lo = 0x00bf, .hi = 0x00bf },
    .{ .lo = 0x3001, .hi = 0x3003 },
};

pub const initial_punctuation = [_]ScalarRange{.{ .lo = 0x00ab, .hi = 0x00ab }};
pub const final_punctuation = [_]ScalarRange{.{ .lo = 0x00bb, .hi = 0x00bb }};
pub const punctuation = connector_punctuation ++ dash_punctuation ++ open_punctuation ++ close_punctuation ++ initial_punctuation ++ final_punctuation ++ other_punctuation;

pub const control = [_]ScalarRange{
    .{ .lo = 0x0000, .hi = 0x001f },
    .{ .lo = 0x007f, .hi = 0x009f },
};

pub const format = [_]ScalarRange{
    .{ .lo = 0x00ad, .hi = 0x00ad },
    .{ .lo = 0x0600, .hi = 0x0605 },
    .{ .lo = 0x061c, .hi = 0x061c },
    .{ .lo = 0x06dd, .hi = 0x06dd },
    .{ .lo = 0x070f, .hi = 0x070f },
    .{ .lo = 0x0890, .hi = 0x0891 },
    .{ .lo = 0x08e2, .hi = 0x08e2 },
    .{ .lo = 0x180e, .hi = 0x180e },
    .{ .lo = 0x200b, .hi = 0x200f },
    .{ .lo = 0x202a, .hi = 0x202e },
    .{ .lo = 0x2060, .hi = 0x2064 },
    .{ .lo = 0x2066, .hi = 0x206f },
    .{ .lo = 0xfeff, .hi = 0xfeff },
    .{ .lo = 0xfff9, .hi = 0xfffb },
    .{ .lo = 0x110bd, .hi = 0x110bd },
    .{ .lo = 0x110cd, .hi = 0x110cd },
    .{ .lo = 0x13430, .hi = 0x1343f },
    .{ .lo = 0x1bca0, .hi = 0x1bca3 },
    .{ .lo = 0x1d173, .hi = 0x1d17a },
    .{ .lo = 0xe0001, .hi = 0xe0001 },
    .{ .lo = 0xe0020, .hi = 0xe007f },
};

pub const private_use = [_]ScalarRange{
    .{ .lo = 0xe000, .hi = 0xf8ff },
    .{ .lo = 0xf0000, .hi = 0xffffd },
    .{ .lo = 0x100000, .hi = 0x10fffd },
};

pub const other = control ++ format ++ private_use;

pub const block_basic_latin = [_]ScalarRange{.{ .lo = 0x0000, .hi = 0x007f }};
pub const block_latin_1_supplement = [_]ScalarRange{.{ .lo = 0x0080, .hi = 0x00ff }};
pub const block_latin_extended_a = [_]ScalarRange{.{ .lo = 0x0100, .hi = 0x017f }};
pub const block_latin_extended_b = [_]ScalarRange{.{ .lo = 0x0180, .hi = 0x024f }};
pub const block_ipa_extensions = [_]ScalarRange{.{ .lo = 0x0250, .hi = 0x02af }};
pub const block_spacing_modifier_letters = [_]ScalarRange{.{ .lo = 0x02b0, .hi = 0x02ff }};
pub const block_combining_diacritical_marks = [_]ScalarRange{.{ .lo = 0x0300, .hi = 0x036f }};
pub const block_greek_and_coptic = [_]ScalarRange{.{ .lo = 0x0370, .hi = 0x03ff }};
pub const block_cyrillic = [_]ScalarRange{.{ .lo = 0x0400, .hi = 0x04ff }};
pub const block_hebrew = [_]ScalarRange{.{ .lo = 0x0590, .hi = 0x05ff }};
pub const block_arabic = [_]ScalarRange{.{ .lo = 0x0600, .hi = 0x06ff }};
pub const block_devanagari = [_]ScalarRange{.{ .lo = 0x0900, .hi = 0x097f }};
pub const block_thai = [_]ScalarRange{.{ .lo = 0x0e00, .hi = 0x0e7f }};
pub const block_hangul_jamo = [_]ScalarRange{.{ .lo = 0x1100, .hi = 0x11ff }};
pub const block_cjk_symbols_and_punctuation = [_]ScalarRange{.{ .lo = 0x3000, .hi = 0x303f }};
pub const block_hiragana = [_]ScalarRange{.{ .lo = 0x3040, .hi = 0x309f }};
pub const block_katakana = [_]ScalarRange{.{ .lo = 0x30a0, .hi = 0x30ff }};
pub const block_bopomofo = [_]ScalarRange{.{ .lo = 0x3100, .hi = 0x312f }};
pub const block_hangul_compatibility_jamo = [_]ScalarRange{.{ .lo = 0x3130, .hi = 0x318f }};
pub const block_katakana_phonetic_extensions = [_]ScalarRange{.{ .lo = 0x31f0, .hi = 0x31ff }};
pub const block_cjk_compatibility = [_]ScalarRange{.{ .lo = 0x3300, .hi = 0x33ff }};
pub const block_cjk_unified_ideographs = [_]ScalarRange{.{ .lo = 0x4e00, .hi = 0x9fff }};
pub const block_hangul_syllables = [_]ScalarRange{.{ .lo = 0xac00, .hi = 0xd7af }};
pub const block_cjk_compatibility_ideographs = [_]ScalarRange{.{ .lo = 0xf900, .hi = 0xfaff }};
pub const block_cjk_compatibility_forms = [_]ScalarRange{.{ .lo = 0xfe30, .hi = 0xfe4f }};
pub const block_halfwidth_and_fullwidth_forms = [_]ScalarRange{.{ .lo = 0xff00, .hi = 0xffef }};

pub const BlockProperty = struct {
    names: []const []const u8,
    ranges: []const ScalarRange,
};

pub const blocks = [_]BlockProperty{
    .{ .names = &.{"In_Basic_Latin"}, .ranges = &block_basic_latin },
    .{ .names = &.{"In_Latin_1_Supplement"}, .ranges = &block_latin_1_supplement },
    .{ .names = &.{"In_Latin_Extended_A"}, .ranges = &block_latin_extended_a },
    .{ .names = &.{"In_Latin_Extended_B"}, .ranges = &block_latin_extended_b },
    .{ .names = &.{"In_IPA_Extensions"}, .ranges = &block_ipa_extensions },
    .{ .names = &.{"In_Spacing_Modifier_Letters"}, .ranges = &block_spacing_modifier_letters },
    .{ .names = &.{"In_Combining_Diacritical_Marks"}, .ranges = &block_combining_diacritical_marks },
    .{ .names = &.{"In_Greek_and_Coptic"}, .ranges = &block_greek_and_coptic },
    .{ .names = &.{"In_Cyrillic"}, .ranges = &block_cyrillic },
    .{ .names = &.{"In_Hebrew"}, .ranges = &block_hebrew },
    .{ .names = &.{"In_Arabic"}, .ranges = &block_arabic },
    .{ .names = &.{"In_Devanagari"}, .ranges = &block_devanagari },
    .{ .names = &.{"In_Thai"}, .ranges = &block_thai },
    .{ .names = &.{"In_Hangul_Jamo"}, .ranges = &block_hangul_jamo },
    .{ .names = &.{"In_Hiragana"}, .ranges = &block_hiragana },
    .{ .names = &.{"In_Katakana"}, .ranges = &block_katakana },
    .{ .names = &.{"In_Bopomofo"}, .ranges = &block_bopomofo },
    .{ .names = &.{"In_Hangul_Compatibility_Jamo"}, .ranges = &block_hangul_compatibility_jamo },
    .{ .names = &.{"In_Katakana_Phonetic_Extensions"}, .ranges = &block_katakana_phonetic_extensions },
    .{ .names = &.{"In_CJK_Symbols_and_Punctuation"}, .ranges = &block_cjk_symbols_and_punctuation },
    .{ .names = &.{"In_CJK_Compatibility"}, .ranges = &block_cjk_compatibility },
    .{ .names = &.{"In_CJK_Unified_Ideographs"}, .ranges = &block_cjk_unified_ideographs },
    .{ .names = &.{"In_Hangul_Syllables"}, .ranges = &block_hangul_syllables },
    .{ .names = &.{"In_CJK_Compatibility_Ideographs"}, .ranges = &block_cjk_compatibility_ideographs },
    .{ .names = &.{"In_CJK_Compatibility_Forms"}, .ranges = &block_cjk_compatibility_forms },
    .{ .names = &.{"In_Halfwidth_and_Fullwidth_Forms"}, .ranges = &block_halfwidth_and_fullwidth_forms },
};
