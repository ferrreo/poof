const unicode_ranges = @import("unicode_ranges.zig");
const ScalarRange = unicode_ranges.ScalarRange;
const extended = @import("unicode_scripts_extended.zig");

pub const greek = [_]ScalarRange{
    .{ .lo = 0x0370, .hi = 0x03ff },
    .{ .lo = 0x1f00, .hi = 0x1fff },
};

pub const latin = [_]ScalarRange{
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = 'a', .hi = 'z' },
    .{ .lo = 0x00c0, .hi = 0x00d6 },
    .{ .lo = 0x00d8, .hi = 0x00f6 },
    .{ .lo = 0x00f8, .hi = 0x02af },
    .{ .lo = 0x1d00, .hi = 0x1d7f },
    .{ .lo = 0x1e00, .hi = 0x1eff },
};

pub const cyrillic = [_]ScalarRange{
    .{ .lo = 0x0400, .hi = 0x052f },
    .{ .lo = 0x1c80, .hi = 0x1c8f },
    .{ .lo = 0x2de0, .hi = 0x2dff },
    .{ .lo = 0xa640, .hi = 0xa69f },
};

pub const han = [_]ScalarRange{
    .{ .lo = 0x3400, .hi = 0x4dbf },
    .{ .lo = 0x4e00, .hi = 0x9fff },
    .{ .lo = 0xf900, .hi = 0xfaff },
    .{ .lo = 0x20000, .hi = 0x2a6df },
    .{ .lo = 0x2a700, .hi = 0x2b73f },
    .{ .lo = 0x2b740, .hi = 0x2b81f },
    .{ .lo = 0x2b820, .hi = 0x2ceaf },
    .{ .lo = 0x2ceb0, .hi = 0x2ebef },
    .{ .lo = 0x30000, .hi = 0x3134f },
};

pub const hiragana = [_]ScalarRange{
    .{ .lo = 0x3040, .hi = 0x309f },
    .{ .lo = 0x1b001, .hi = 0x1b11f },
    .{ .lo = 0x1b132, .hi = 0x1b132 },
    .{ .lo = 0x1b150, .hi = 0x1b152 },
};

pub const katakana = [_]ScalarRange{
    .{ .lo = 0x30a0, .hi = 0x30ff },
    .{ .lo = 0x31f0, .hi = 0x31ff },
    .{ .lo = 0x32d0, .hi = 0x32fe },
    .{ .lo = 0x3300, .hi = 0x3357 },
    .{ .lo = 0xff66, .hi = 0xff9f },
    .{ .lo = 0x1b000, .hi = 0x1b000 },
    .{ .lo = 0x1b120, .hi = 0x1b122 },
    .{ .lo = 0x1b155, .hi = 0x1b155 },
};

pub const hebrew = [_]ScalarRange{
    .{ .lo = 0x0590, .hi = 0x05ff },
    .{ .lo = 0xfb1d, .hi = 0xfb4f },
};

pub const arabic = [_]ScalarRange{
    .{ .lo = 0x0600, .hi = 0x06ff },
    .{ .lo = 0x0750, .hi = 0x077f },
    .{ .lo = 0x0870, .hi = 0x089f },
    .{ .lo = 0x08a0, .hi = 0x08ff },
    .{ .lo = 0xfb50, .hi = 0xfdff },
    .{ .lo = 0xfe70, .hi = 0xfeff },
    .{ .lo = 0x10ec0, .hi = 0x10eff },
    .{ .lo = 0x1ee00, .hi = 0x1eeff },
};

pub const common = [_]ScalarRange{
    .{ .lo = 0x0009, .hi = 0x000d },
    .{ .lo = 0x0020, .hi = 0x0040 },
    .{ .lo = 0x005b, .hi = 0x0060 },
    .{ .lo = 0x007b, .hi = 0x007e },
    .{ .lo = 0x00a0, .hi = 0x00a9 },
    .{ .lo = 0x00ab, .hi = 0x00ae },
    .{ .lo = 0x00b0, .hi = 0x00b1 },
    .{ .lo = 0x00b6, .hi = 0x00bb },
    .{ .lo = 0x00bf, .hi = 0x00bf },
    .{ .lo = 0x00d7, .hi = 0x00d7 },
    .{ .lo = 0x00f7, .hi = 0x00f7 },
    .{ .lo = 0x2000, .hi = 0x206f },
    .{ .lo = 0x20a0, .hi = 0x20cf },
    .{ .lo = 0x2100, .hi = 0x214f },
    .{ .lo = 0x2190, .hi = 0x23ff },
};

pub const inherited = [_]ScalarRange{
    .{ .lo = 0x0300, .hi = 0x036f },
    .{ .lo = 0x1ab0, .hi = 0x1aff },
    .{ .lo = 0x1dc0, .hi = 0x1dff },
    .{ .lo = 0x20d0, .hi = 0x20ff },
    .{ .lo = 0xfe20, .hi = 0xfe2f },
    .{ .lo = 0xe0100, .hi = 0xe01ef },
};

pub const devanagari = [_]ScalarRange{
    .{ .lo = 0x0900, .hi = 0x097f },
    .{ .lo = 0xa8e0, .hi = 0xa8ff },
    .{ .lo = 0x11b00, .hi = 0x11b5f },
};

pub const thai = [_]ScalarRange{.{ .lo = 0x0e00, .hi = 0x0e7f }};

pub const hangul = [_]ScalarRange{
    .{ .lo = 0x1100, .hi = 0x11ff },
    .{ .lo = 0x3130, .hi = 0x318f },
    .{ .lo = 0xa960, .hi = 0xa97f },
    .{ .lo = 0xac00, .hi = 0xd7af },
    .{ .lo = 0xd7b0, .hi = 0xd7ff },
};

pub const bopomofo = [_]ScalarRange{
    .{ .lo = 0x3100, .hi = 0x312f },
    .{ .lo = 0x31a0, .hi = 0x31bf },
};

pub const armenian = [_]ScalarRange{
    .{ .lo = 0x0530, .hi = 0x058f },
    .{ .lo = 0xfb13, .hi = 0xfb17 },
};

pub const georgian = [_]ScalarRange{
    .{ .lo = 0x10a0, .hi = 0x10ff },
    .{ .lo = 0x1c90, .hi = 0x1cbf },
    .{ .lo = 0x2d00, .hi = 0x2d2f },
};

pub const runic = [_]ScalarRange{.{ .lo = 0x16a0, .hi = 0x16ff }};

pub const ethiopic = [_]ScalarRange{
    .{ .lo = 0x1200, .hi = 0x137f },
    .{ .lo = 0x1380, .hi = 0x139f },
    .{ .lo = 0x2d80, .hi = 0x2ddf },
    .{ .lo = 0xab00, .hi = 0xab2f },
};

pub const khmer = [_]ScalarRange{
    .{ .lo = 0x1780, .hi = 0x17ff },
    .{ .lo = 0x19e0, .hi = 0x19ff },
};

pub const lao = [_]ScalarRange{.{ .lo = 0x0e80, .hi = 0x0eff }};

pub const myanmar = [_]ScalarRange{
    .{ .lo = 0x1000, .hi = 0x109f },
    .{ .lo = 0xaa60, .hi = 0xaa7f },
    .{ .lo = 0xa9e0, .hi = 0xa9ff },
};

pub const sinhala = [_]ScalarRange{
    .{ .lo = 0x0d80, .hi = 0x0dff },
    .{ .lo = 0x111e0, .hi = 0x111ff },
};

pub const tamil = [_]ScalarRange{
    .{ .lo = 0x0b80, .hi = 0x0bff },
    .{ .lo = 0x11fc0, .hi = 0x11fff },
};

pub const telugu = [_]ScalarRange{.{ .lo = 0x0c00, .hi = 0x0c7f }};

pub const kannada = [_]ScalarRange{.{ .lo = 0x0c80, .hi = 0x0cff }};

pub const malayalam = [_]ScalarRange{.{ .lo = 0x0d00, .hi = 0x0d7f }};

pub const bengali = [_]ScalarRange{
    .{ .lo = 0x0980, .hi = 0x0983 },
    .{ .lo = 0x0985, .hi = 0x098c },
    .{ .lo = 0x098f, .hi = 0x0990 },
    .{ .lo = 0x0993, .hi = 0x09a8 },
    .{ .lo = 0x09aa, .hi = 0x09b0 },
    .{ .lo = 0x09b2, .hi = 0x09b2 },
    .{ .lo = 0x09b6, .hi = 0x09b9 },
    .{ .lo = 0x09bc, .hi = 0x09c4 },
    .{ .lo = 0x09c7, .hi = 0x09c8 },
    .{ .lo = 0x09cb, .hi = 0x09ce },
    .{ .lo = 0x09d7, .hi = 0x09d7 },
    .{ .lo = 0x09dc, .hi = 0x09dd },
    .{ .lo = 0x09df, .hi = 0x09e3 },
    .{ .lo = 0x09e6, .hi = 0x09fe },
};

pub const gurmukhi = [_]ScalarRange{
    .{ .lo = 0x0a01, .hi = 0x0a03 },
    .{ .lo = 0x0a05, .hi = 0x0a0a },
    .{ .lo = 0x0a0f, .hi = 0x0a10 },
    .{ .lo = 0x0a13, .hi = 0x0a28 },
    .{ .lo = 0x0a2a, .hi = 0x0a30 },
    .{ .lo = 0x0a32, .hi = 0x0a33 },
    .{ .lo = 0x0a35, .hi = 0x0a36 },
    .{ .lo = 0x0a38, .hi = 0x0a39 },
    .{ .lo = 0x0a3c, .hi = 0x0a3c },
    .{ .lo = 0x0a3e, .hi = 0x0a42 },
    .{ .lo = 0x0a47, .hi = 0x0a48 },
    .{ .lo = 0x0a4b, .hi = 0x0a4d },
    .{ .lo = 0x0a51, .hi = 0x0a51 },
    .{ .lo = 0x0a59, .hi = 0x0a5c },
    .{ .lo = 0x0a5e, .hi = 0x0a5e },
    .{ .lo = 0x0a66, .hi = 0x0a76 },
};

pub const gujarati = [_]ScalarRange{
    .{ .lo = 0x0a81, .hi = 0x0a83 },
    .{ .lo = 0x0a85, .hi = 0x0a8d },
    .{ .lo = 0x0a8f, .hi = 0x0a91 },
    .{ .lo = 0x0a93, .hi = 0x0aa8 },
    .{ .lo = 0x0aaa, .hi = 0x0ab0 },
    .{ .lo = 0x0ab2, .hi = 0x0ab3 },
    .{ .lo = 0x0ab5, .hi = 0x0ab9 },
    .{ .lo = 0x0abc, .hi = 0x0ac5 },
    .{ .lo = 0x0ac7, .hi = 0x0ac9 },
    .{ .lo = 0x0acb, .hi = 0x0acd },
    .{ .lo = 0x0ad0, .hi = 0x0ad0 },
    .{ .lo = 0x0ae0, .hi = 0x0ae3 },
    .{ .lo = 0x0ae6, .hi = 0x0af1 },
    .{ .lo = 0x0af9, .hi = 0x0aff },
};

pub const oriya = [_]ScalarRange{
    .{ .lo = 0x0b01, .hi = 0x0b03 },
    .{ .lo = 0x0b05, .hi = 0x0b0c },
    .{ .lo = 0x0b0f, .hi = 0x0b10 },
    .{ .lo = 0x0b13, .hi = 0x0b28 },
    .{ .lo = 0x0b2a, .hi = 0x0b30 },
    .{ .lo = 0x0b32, .hi = 0x0b33 },
    .{ .lo = 0x0b35, .hi = 0x0b39 },
    .{ .lo = 0x0b3c, .hi = 0x0b44 },
    .{ .lo = 0x0b47, .hi = 0x0b48 },
    .{ .lo = 0x0b4b, .hi = 0x0b4d },
    .{ .lo = 0x0b55, .hi = 0x0b57 },
    .{ .lo = 0x0b5c, .hi = 0x0b5d },
    .{ .lo = 0x0b5f, .hi = 0x0b63 },
    .{ .lo = 0x0b66, .hi = 0x0b77 },
};

pub const tibetan = [_]ScalarRange{
    .{ .lo = 0x0f00, .hi = 0x0f47 },
    .{ .lo = 0x0f49, .hi = 0x0f6c },
    .{ .lo = 0x0f71, .hi = 0x0f97 },
    .{ .lo = 0x0f99, .hi = 0x0fbc },
    .{ .lo = 0x0fbe, .hi = 0x0fcc },
    .{ .lo = 0x0fce, .hi = 0x0fd4 },
    .{ .lo = 0x0fd9, .hi = 0x0fda },
};

pub const balinese = [_]ScalarRange{.{ .lo = 0x1b00, .hi = 0x1b7f }};
pub const batak = [_]ScalarRange{.{ .lo = 0x1bc0, .hi = 0x1bff }};
pub const buginese = [_]ScalarRange{.{ .lo = 0x1a00, .hi = 0x1a1f }};
pub const cham = [_]ScalarRange{.{ .lo = 0xaa00, .hi = 0xaa5f }};
pub const javanese = [_]ScalarRange{.{ .lo = 0xa980, .hi = 0xa9df }};
pub const lepcha = [_]ScalarRange{.{ .lo = 0x1c00, .hi = 0x1c4f }};
pub const limbu = [_]ScalarRange{.{ .lo = 0x1900, .hi = 0x194f }};
pub const new_tai_lue = [_]ScalarRange{.{ .lo = 0x1980, .hi = 0x19df }};
pub const tai_le = [_]ScalarRange{.{ .lo = 0x1950, .hi = 0x197f }};
pub const rejang = [_]ScalarRange{.{ .lo = 0xa930, .hi = 0xa95f }};

pub const syriac = [_]ScalarRange{
    .{ .lo = 0x0700, .hi = 0x070d },
    .{ .lo = 0x070f, .hi = 0x074a },
    .{ .lo = 0x074d, .hi = 0x074f },
    .{ .lo = 0x0860, .hi = 0x086a },
};

pub const thaana = [_]ScalarRange{.{ .lo = 0x0780, .hi = 0x07b1 }};

pub const nko = [_]ScalarRange{
    .{ .lo = 0x07c0, .hi = 0x07fa },
    .{ .lo = 0x07fd, .hi = 0x07ff },
};

pub const cherokee = [_]ScalarRange{
    .{ .lo = 0x13a0, .hi = 0x13f5 },
    .{ .lo = 0x13f8, .hi = 0x13fd },
    .{ .lo = 0xab70, .hi = 0xabbf },
};

pub const canadian_aboriginal = [_]ScalarRange{
    .{ .lo = 0x1400, .hi = 0x167f },
    .{ .lo = 0x18b0, .hi = 0x18f5 },
    .{ .lo = 0x11ab0, .hi = 0x11abf },
};

pub const ogham = [_]ScalarRange{.{ .lo = 0x1680, .hi = 0x169c }};

pub const mongolian = [_]ScalarRange{
    .{ .lo = 0x1800, .hi = 0x1801 },
    .{ .lo = 0x1804, .hi = 0x1804 },
    .{ .lo = 0x1806, .hi = 0x1819 },
    .{ .lo = 0x1820, .hi = 0x1878 },
    .{ .lo = 0x1880, .hi = 0x18aa },
    .{ .lo = 0x11660, .hi = 0x1166c },
};

pub const coptic = [_]ScalarRange{
    .{ .lo = 0x03e2, .hi = 0x03ef },
    .{ .lo = 0x2c80, .hi = 0x2cf3 },
    .{ .lo = 0x2cf9, .hi = 0x2cff },
};

pub const gothic = [_]ScalarRange{.{ .lo = 0x10330, .hi = 0x1034a }};

pub const deseret = [_]ScalarRange{.{ .lo = 0x10400, .hi = 0x1044f }};

pub const old_italic = [_]ScalarRange{
    .{ .lo = 0x10300, .hi = 0x10323 },
    .{ .lo = 0x1032d, .hi = 0x1032f },
};

pub const tagalog = [_]ScalarRange{
    .{ .lo = 0x1700, .hi = 0x1715 },
    .{ .lo = 0x171f, .hi = 0x171f },
};

pub const hanunoo = [_]ScalarRange{.{ .lo = 0x1720, .hi = 0x1734 }};

pub const buhid = [_]ScalarRange{.{ .lo = 0x1740, .hi = 0x1753 }};

pub const tagbanwa = [_]ScalarRange{
    .{ .lo = 0x1760, .hi = 0x176c },
    .{ .lo = 0x176e, .hi = 0x1770 },
    .{ .lo = 0x1772, .hi = 0x1773 },
};

pub const yi = [_]ScalarRange{
    .{ .lo = 0xa000, .hi = 0xa48c },
    .{ .lo = 0xa490, .hi = 0xa4c6 },
};

pub const braille = [_]ScalarRange{.{ .lo = 0x2800, .hi = 0x28ff }};
pub const tifinagh = [_]ScalarRange{ .{ .lo = 0x2d30, .hi = 0x2d67 }, .{ .lo = 0x2d6f, .hi = 0x2d70 }, .{ .lo = 0x2d7f, .hi = 0x2d7f } };
pub const vai = [_]ScalarRange{.{ .lo = 0xa500, .hi = 0xa63f }};
pub const lisu = [_]ScalarRange{ .{ .lo = 0xa4d0, .hi = 0xa4ff }, .{ .lo = 0x11fb0, .hi = 0x11fb0 } };
pub const bamum = [_]ScalarRange{ .{ .lo = 0xa6a0, .hi = 0xa6f7 }, .{ .lo = 0x16800, .hi = 0x16a38 } };
pub const syloti_nagri = [_]ScalarRange{.{ .lo = 0xa800, .hi = 0xa82c }};
pub const phags_pa = [_]ScalarRange{.{ .lo = 0xa840, .hi = 0xa877 }};
pub const saurashtra = [_]ScalarRange{.{ .lo = 0xa880, .hi = 0xa8d9 }};
pub const kayah_li = [_]ScalarRange{.{ .lo = 0xa900, .hi = 0xa92f }};

pub const ScriptProperty = struct {
    names: []const []const u8,
    ranges: []const ScalarRange,
};
pub const scripts = [_]ScriptProperty{
    .{ .names = &.{ "Greek", "Grek", "Script=Greek", "sc=Grek" }, .ranges = &greek },
    .{ .names = &.{ "Latin", "Latn" }, .ranges = &latin },
    .{ .names = &.{ "Cyrillic", "Cyrl" }, .ranges = &cyrillic },
    .{ .names = &.{ "Han", "Hani" }, .ranges = &han },
    .{ .names = &.{ "Hiragana", "Hira" }, .ranges = &hiragana },
    .{ .names = &.{ "Katakana", "Kana" }, .ranges = &katakana },
    .{ .names = &.{ "Hebrew", "Hebr" }, .ranges = &hebrew },
    .{ .names = &.{ "Arabic", "Arab" }, .ranges = &arabic },
    .{ .names = &.{ "Common", "Zyyy" }, .ranges = &common },
    .{ .names = &.{ "Inherited", "Zinh" }, .ranges = &inherited },
    .{ .names = &.{ "Devanagari", "Deva" }, .ranges = &devanagari },
    .{ .names = &.{"Thai"}, .ranges = &thai },
    .{ .names = &.{ "Hangul", "Hang" }, .ranges = &hangul },
    .{ .names = &.{ "Bopomofo", "Bopo" }, .ranges = &bopomofo },
    .{ .names = &.{ "Armenian", "Armn" }, .ranges = &armenian },
    .{ .names = &.{ "Georgian", "Geor" }, .ranges = &georgian },
    .{ .names = &.{ "Runic", "Runr" }, .ranges = &runic },
    .{ .names = &.{ "Ethiopic", "Ethi" }, .ranges = &ethiopic },
    .{ .names = &.{ "Khmer", "Khmr" }, .ranges = &khmer },
    .{ .names = &.{ "Lao", "Laoo" }, .ranges = &lao },
    .{ .names = &.{ "Myanmar", "Mymr" }, .ranges = &myanmar },
    .{ .names = &.{ "Sinhala", "Sinh" }, .ranges = &sinhala },
    .{ .names = &.{ "Tamil", "Taml" }, .ranges = &tamil },
    .{ .names = &.{ "Telugu", "Telu" }, .ranges = &telugu },
    .{ .names = &.{ "Kannada", "Knda" }, .ranges = &kannada },
    .{ .names = &.{ "Malayalam", "Mlym" }, .ranges = &malayalam },
    .{ .names = &.{ "Bengali", "Beng" }, .ranges = &bengali },
    .{ .names = &.{ "Gurmukhi", "Guru" }, .ranges = &gurmukhi },
    .{ .names = &.{ "Gujarati", "Gujr" }, .ranges = &gujarati },
    .{ .names = &.{ "Oriya", "Orya" }, .ranges = &oriya },
    .{ .names = &.{ "Tibetan", "Tibt" }, .ranges = &tibetan },
    .{ .names = &.{ "Balinese", "Bali" }, .ranges = &balinese },
    .{ .names = &.{ "Batak", "Batk" }, .ranges = &batak },
    .{ .names = &.{ "Buginese", "Bugi" }, .ranges = &buginese },
    .{ .names = &.{"Cham"}, .ranges = &cham },
    .{ .names = &.{ "Javanese", "Java" }, .ranges = &javanese },
    .{ .names = &.{ "Lepcha", "Lepc" }, .ranges = &lepcha },
    .{ .names = &.{ "Limbu", "Limb" }, .ranges = &limbu },
    .{ .names = &.{ "New_Tai_Lue", "Talu" }, .ranges = &new_tai_lue },
    .{ .names = &.{ "Tai_Le", "Tale" }, .ranges = &tai_le },
    .{ .names = &.{ "Rejang", "Rjng" }, .ranges = &rejang },
    .{ .names = &.{ "Adlam", "Adlm" }, .ranges = &extended.adlam },
    .{ .names = &.{"Ahom"}, .ranges = &extended.ahom },
    .{ .names = &.{ "Avestan", "Avst" }, .ranges = &extended.avestan },
    .{ .names = &.{ "Bassa_Vah", "Bass" }, .ranges = &extended.bassa_vah },
    .{ .names = &.{ "Bhaiksuki", "Bhks" }, .ranges = &extended.bhaiksuki },
    .{ .names = &.{ "Brahmi", "Brah" }, .ranges = &extended.brahmi },
    .{ .names = &.{ "Carian", "Cari" }, .ranges = &extended.carian },
    .{ .names = &.{ "Caucasian_Albanian", "Aghb" }, .ranges = &extended.caucasian_albanian },
    .{ .names = &.{ "Chakma", "Cakm" }, .ranges = &extended.chakma },
    .{ .names = &.{ "Cuneiform", "Xsux" }, .ranges = &extended.cuneiform },
    .{ .names = &.{ "Dives_Akuru", "Diak" }, .ranges = &extended.dives_akuru },
    .{ .names = &.{ "Dogra", "Dogr" }, .ranges = &extended.dogra },
    .{ .names = &.{ "Duployan", "Dupl" }, .ranges = &extended.duployan },
    .{ .names = &.{ "Egyptian_Hieroglyphs", "Egyp" }, .ranges = &extended.egyptian_hieroglyphs },
    .{ .names = &.{ "Elbasan", "Elba" }, .ranges = &extended.elbasan },
    .{ .names = &.{ "Elymaic", "Elym" }, .ranges = &extended.elymaic },
    .{ .names = &.{ "Glagolitic", "Glag" }, .ranges = &extended.glagolitic },
    .{ .names = &.{ "Grantha", "Gran" }, .ranges = &extended.grantha },
    .{ .names = &.{ "Gunjala_Gondi", "Gong" }, .ranges = &extended.gunjala_gondi },
    .{ .names = &.{ "Hanifi_Rohingya", "Rohg" }, .ranges = &extended.hanifi_rohingya },
    .{ .names = &.{ "Imperial_Aramaic", "Armi" }, .ranges = &extended.imperial_aramaic },
    .{ .names = &.{ "Inscriptional_Parthian", "Prti" }, .ranges = &extended.inscriptional_parthian },
    .{ .names = &.{ "Inscriptional_Pahlavi", "Phli" }, .ranges = &extended.inscriptional_pahlavi },
    .{ .names = &.{ "Kaithi", "Kthi" }, .ranges = &extended.kaithi },
    .{ .names = &.{ "Khojki", "Khoj" }, .ranges = &extended.khojki },
    .{ .names = &.{ "Khitan_Small_Script", "Kits" }, .ranges = &extended.khitan_small_script },
    .{ .names = &.{ "Lycian", "Lyci" }, .ranges = &extended.lycian },
    .{ .names = &.{ "Lydian", "Lydi" }, .ranges = &extended.lydian },
    .{ .names = &.{ "Mahajani", "Mahj" }, .ranges = &extended.mahajani },
    .{ .names = &.{ "Makasar", "Maka" }, .ranges = &extended.makasar },
    .{ .names = &.{ "Mandaic", "Mand" }, .ranges = &extended.mandaic },
    .{ .names = &.{ "Manichaean", "Mani" }, .ranges = &extended.manichaean },
    .{ .names = &.{ "Marchen", "Marc" }, .ranges = &extended.marchen },
    .{ .names = &.{ "Masaram_Gondi", "Gonm" }, .ranges = &extended.masaram_gondi },
    .{ .names = &.{ "Medefaidrin", "Medf" }, .ranges = &extended.medefaidrin },
    .{ .names = &.{ "Mende_Kikakui", "Mend" }, .ranges = &extended.mende_kikakui },
    .{ .names = &.{ "Meroitic_Cursive", "Merc" }, .ranges = &extended.meroitic_cursive },
    .{ .names = &.{ "Meroitic_Hieroglyphs", "Mero" }, .ranges = &extended.meroitic_hieroglyphs },
    .{ .names = &.{ "Miao", "Plrd" }, .ranges = &extended.miao },
    .{ .names = &.{"Modi"}, .ranges = &extended.modi },
    .{ .names = &.{ "Multani", "Mult" }, .ranges = &extended.multani },
    .{ .names = &.{ "Nabataean", "Nbat" }, .ranges = &extended.nabataean },
    .{ .names = &.{ "Nandinagari", "Nand" }, .ranges = &extended.nandinagari },
    .{ .names = &.{"Newa"}, .ranges = &extended.newa },
    .{ .names = &.{ "Nushu", "Nshu" }, .ranges = &extended.nushu },
    .{ .names = &.{ "Old_North_Arabian", "Narb" }, .ranges = &extended.old_north_arabian },
    .{ .names = &.{ "Old_Permic", "Perm" }, .ranges = &extended.old_permic },
    .{ .names = &.{ "Old_Persian", "Xpeo" }, .ranges = &extended.old_persian },
    .{ .names = &.{ "Old_Sogdian", "Sogo" }, .ranges = &extended.old_sogdian },
    .{ .names = &.{ "Syriac", "Syrc" }, .ranges = &syriac },
    .{ .names = &.{ "Thaana", "Thaa" }, .ranges = &thaana },
    .{ .names = &.{ "Nko", "Nkoo" }, .ranges = &nko },
    .{ .names = &.{ "Cherokee", "Cher" }, .ranges = &cherokee },
    .{ .names = &.{ "Canadian_Aboriginal", "Cans" }, .ranges = &canadian_aboriginal },
    .{ .names = &.{ "Ogham", "Ogam" }, .ranges = &ogham },
    .{ .names = &.{ "Mongolian", "Mong" }, .ranges = &mongolian },
    .{ .names = &.{ "Coptic", "Copt" }, .ranges = &coptic },
    .{ .names = &.{ "Gothic", "Goth" }, .ranges = &gothic },
    .{ .names = &.{ "Deseret", "Dsrt" }, .ranges = &deseret },
    .{ .names = &.{ "Old_Italic", "Ital" }, .ranges = &old_italic },
    .{ .names = &.{ "Tagalog", "Tglg" }, .ranges = &tagalog },
    .{ .names = &.{ "Hanunoo", "Hano" }, .ranges = &hanunoo },
    .{ .names = &.{ "Buhid", "Buhd" }, .ranges = &buhid },
    .{ .names = &.{ "Tagbanwa", "Tagb" }, .ranges = &tagbanwa },
    .{ .names = &.{ "Yi", "Yiii" }, .ranges = &yi },
    .{ .names = &.{ "Braille", "Brai" }, .ranges = &braille },
    .{ .names = &.{ "Tifinagh", "Tfng" }, .ranges = &tifinagh },
    .{ .names = &.{ "Vai", "Vaii" }, .ranges = &vai },
    .{ .names = &.{"Lisu"}, .ranges = &lisu },
    .{ .names = &.{ "Bamum", "Bamu" }, .ranges = &bamum },
    .{ .names = &.{ "Syloti_Nagri", "Sylo" }, .ranges = &syloti_nagri },
    .{ .names = &.{ "Phags_Pa", "Phag" }, .ranges = &phags_pa },
    .{ .names = &.{ "Saurashtra", "Saur" }, .ranges = &saurashtra },
    .{ .names = &.{ "Kayah_Li", "Kali" }, .ranges = &kayah_li },
};
