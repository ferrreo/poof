const unicode_ranges = @import("unicode_ranges.zig");
const ScalarRange = unicode_ranges.ScalarRange;

pub const adlam = [_]ScalarRange{
    .{ .lo = 0x1e900, .hi = 0x1e94b },
    .{ .lo = 0x1e950, .hi = 0x1e959 },
    .{ .lo = 0x1e95e, .hi = 0x1e95f },
};

pub const ahom = [_]ScalarRange{
    .{ .lo = 0x11700, .hi = 0x1171a },
    .{ .lo = 0x1171d, .hi = 0x1172b },
    .{ .lo = 0x11730, .hi = 0x11746 },
};

pub const avestan = [_]ScalarRange{
    .{ .lo = 0x10b00, .hi = 0x10b35 },
    .{ .lo = 0x10b39, .hi = 0x10b3f },
};

pub const bassa_vah = [_]ScalarRange{
    .{ .lo = 0x16ad0, .hi = 0x16aed },
    .{ .lo = 0x16af0, .hi = 0x16af5 },
};

pub const bhaiksuki = [_]ScalarRange{
    .{ .lo = 0x11c00, .hi = 0x11c08 },
    .{ .lo = 0x11c0a, .hi = 0x11c36 },
    .{ .lo = 0x11c38, .hi = 0x11c45 },
    .{ .lo = 0x11c50, .hi = 0x11c6c },
};

pub const brahmi = [_]ScalarRange{
    .{ .lo = 0x11000, .hi = 0x1104d },
    .{ .lo = 0x11052, .hi = 0x11075 },
    .{ .lo = 0x1107f, .hi = 0x1107f },
};

pub const carian = [_]ScalarRange{.{ .lo = 0x102a0, .hi = 0x102d0 }};

pub const caucasian_albanian = [_]ScalarRange{
    .{ .lo = 0x10530, .hi = 0x10563 },
    .{ .lo = 0x1056f, .hi = 0x1056f },
};

pub const chakma = [_]ScalarRange{
    .{ .lo = 0x11100, .hi = 0x11134 },
    .{ .lo = 0x11136, .hi = 0x11147 },
};

pub const cuneiform = [_]ScalarRange{
    .{ .lo = 0x12000, .hi = 0x12399 },
    .{ .lo = 0x12400, .hi = 0x1246e },
    .{ .lo = 0x12470, .hi = 0x12474 },
    .{ .lo = 0x12480, .hi = 0x12543 },
};

pub const dives_akuru = [_]ScalarRange{
    .{ .lo = 0x11900, .hi = 0x11906 },
    .{ .lo = 0x11909, .hi = 0x11909 },
    .{ .lo = 0x1190c, .hi = 0x11913 },
    .{ .lo = 0x11915, .hi = 0x11916 },
    .{ .lo = 0x11918, .hi = 0x11935 },
    .{ .lo = 0x11937, .hi = 0x11938 },
    .{ .lo = 0x1193b, .hi = 0x11946 },
    .{ .lo = 0x11950, .hi = 0x11959 },
};

pub const dogra = [_]ScalarRange{.{ .lo = 0x11800, .hi = 0x1183b }};

pub const duployan = [_]ScalarRange{
    .{ .lo = 0x1bc00, .hi = 0x1bc6a },
    .{ .lo = 0x1bc70, .hi = 0x1bc7c },
    .{ .lo = 0x1bc80, .hi = 0x1bc88 },
    .{ .lo = 0x1bc90, .hi = 0x1bc99 },
    .{ .lo = 0x1bc9c, .hi = 0x1bc9f },
};

pub const egyptian_hieroglyphs = [_]ScalarRange{
    .{ .lo = 0x13000, .hi = 0x13455 },
    .{ .lo = 0x13460, .hi = 0x143fa },
};

pub const elbasan = [_]ScalarRange{.{ .lo = 0x10500, .hi = 0x10527 }};

pub const elymaic = [_]ScalarRange{.{ .lo = 0x10fe0, .hi = 0x10ff6 }};

pub const glagolitic = [_]ScalarRange{
    .{ .lo = 0x2c00, .hi = 0x2c5f },
    .{ .lo = 0x1e000, .hi = 0x1e006 },
    .{ .lo = 0x1e008, .hi = 0x1e018 },
    .{ .lo = 0x1e01b, .hi = 0x1e021 },
    .{ .lo = 0x1e023, .hi = 0x1e024 },
    .{ .lo = 0x1e026, .hi = 0x1e02a },
};

pub const grantha = [_]ScalarRange{
    .{ .lo = 0x11300, .hi = 0x11303 },
    .{ .lo = 0x11305, .hi = 0x1130c },
    .{ .lo = 0x1130f, .hi = 0x11310 },
    .{ .lo = 0x11313, .hi = 0x11328 },
    .{ .lo = 0x1132a, .hi = 0x11330 },
    .{ .lo = 0x11332, .hi = 0x11333 },
    .{ .lo = 0x11335, .hi = 0x11339 },
    .{ .lo = 0x1133c, .hi = 0x11340 },
    .{ .lo = 0x11341, .hi = 0x11344 },
    .{ .lo = 0x11347, .hi = 0x11348 },
    .{ .lo = 0x1134b, .hi = 0x1134d },
    .{ .lo = 0x11350, .hi = 0x11350 },
    .{ .lo = 0x11357, .hi = 0x11357 },
    .{ .lo = 0x1135d, .hi = 0x11363 },
    .{ .lo = 0x11366, .hi = 0x1136c },
    .{ .lo = 0x11370, .hi = 0x11374 },
};

pub const gunjala_gondi = [_]ScalarRange{
    .{ .lo = 0x11d60, .hi = 0x11d65 },
    .{ .lo = 0x11d67, .hi = 0x11d68 },
    .{ .lo = 0x11d6a, .hi = 0x11d8e },
    .{ .lo = 0x11d90, .hi = 0x11d91 },
    .{ .lo = 0x11d93, .hi = 0x11d98 },
    .{ .lo = 0x11da0, .hi = 0x11da9 },
};

pub const hanifi_rohingya = [_]ScalarRange{
    .{ .lo = 0x10d00, .hi = 0x10d27 },
    .{ .lo = 0x10d30, .hi = 0x10d39 },
};

pub const imperial_aramaic = [_]ScalarRange{
    .{ .lo = 0x10840, .hi = 0x10855 },
    .{ .lo = 0x10857, .hi = 0x1085f },
};

pub const inscriptional_parthian = [_]ScalarRange{
    .{ .lo = 0x10b40, .hi = 0x10b55 },
    .{ .lo = 0x10b58, .hi = 0x10b5f },
};

pub const inscriptional_pahlavi = [_]ScalarRange{
    .{ .lo = 0x10b60, .hi = 0x10b72 },
    .{ .lo = 0x10b78, .hi = 0x10b7f },
};

pub const kaithi = [_]ScalarRange{
    .{ .lo = 0x11080, .hi = 0x110c2 },
    .{ .lo = 0x110cd, .hi = 0x110cd },
};

pub const khojki = [_]ScalarRange{
    .{ .lo = 0x11200, .hi = 0x11211 },
    .{ .lo = 0x11213, .hi = 0x11241 },
};

pub const khitan_small_script = [_]ScalarRange{
    .{ .lo = 0x16fe4, .hi = 0x16fe4 },
    .{ .lo = 0x18b00, .hi = 0x18cd5 },
    .{ .lo = 0x18cff, .hi = 0x18cff },
};

pub const lycian = [_]ScalarRange{.{ .lo = 0x10280, .hi = 0x1029c }};

pub const lydian = [_]ScalarRange{
    .{ .lo = 0x10920, .hi = 0x10939 },
    .{ .lo = 0x1093f, .hi = 0x1093f },
};

pub const mahajani = [_]ScalarRange{.{ .lo = 0x11150, .hi = 0x11176 }};

pub const makasar = [_]ScalarRange{.{ .lo = 0x11ee0, .hi = 0x11ef8 }};

pub const mandaic = [_]ScalarRange{
    .{ .lo = 0x0840, .hi = 0x085b },
    .{ .lo = 0x085e, .hi = 0x085e },
};

pub const manichaean = [_]ScalarRange{
    .{ .lo = 0x10ac0, .hi = 0x10ae6 },
    .{ .lo = 0x10aeb, .hi = 0x10af6 },
};

pub const marchen = [_]ScalarRange{
    .{ .lo = 0x11c70, .hi = 0x11c8f },
    .{ .lo = 0x11c92, .hi = 0x11ca7 },
    .{ .lo = 0x11ca9, .hi = 0x11cb6 },
};

pub const masaram_gondi = [_]ScalarRange{
    .{ .lo = 0x11d00, .hi = 0x11d06 },
    .{ .lo = 0x11d08, .hi = 0x11d09 },
    .{ .lo = 0x11d0b, .hi = 0x11d36 },
    .{ .lo = 0x11d3a, .hi = 0x11d3a },
    .{ .lo = 0x11d3c, .hi = 0x11d3d },
    .{ .lo = 0x11d3f, .hi = 0x11d47 },
    .{ .lo = 0x11d50, .hi = 0x11d59 },
};

pub const medefaidrin = [_]ScalarRange{
    .{ .lo = 0x16e40, .hi = 0x16e9a },
};

pub const mende_kikakui = [_]ScalarRange{
    .{ .lo = 0x1e800, .hi = 0x1e8c4 },
    .{ .lo = 0x1e8c7, .hi = 0x1e8d6 },
};

pub const meroitic_cursive = [_]ScalarRange{
    .{ .lo = 0x109a0, .hi = 0x109b7 },
    .{ .lo = 0x109bc, .hi = 0x109cf },
    .{ .lo = 0x109d2, .hi = 0x109ff },
};

pub const meroitic_hieroglyphs = [_]ScalarRange{.{ .lo = 0x10980, .hi = 0x1099f }};

pub const miao = [_]ScalarRange{
    .{ .lo = 0x16f00, .hi = 0x16f4a },
    .{ .lo = 0x16f4f, .hi = 0x16f87 },
    .{ .lo = 0x16f8f, .hi = 0x16f9f },
};

pub const modi = [_]ScalarRange{
    .{ .lo = 0x11600, .hi = 0x11644 },
    .{ .lo = 0x11650, .hi = 0x11659 },
};

pub const multani = [_]ScalarRange{
    .{ .lo = 0x11280, .hi = 0x11286 },
    .{ .lo = 0x11288, .hi = 0x11288 },
    .{ .lo = 0x1128a, .hi = 0x1128d },
    .{ .lo = 0x1128f, .hi = 0x1129d },
    .{ .lo = 0x1129f, .hi = 0x112a9 },
};

pub const nabataean = [_]ScalarRange{
    .{ .lo = 0x10880, .hi = 0x1089e },
    .{ .lo = 0x108a7, .hi = 0x108af },
};

pub const nandinagari = [_]ScalarRange{
    .{ .lo = 0x119a0, .hi = 0x119a7 },
    .{ .lo = 0x119aa, .hi = 0x119d7 },
    .{ .lo = 0x119da, .hi = 0x119e4 },
};

pub const newa = [_]ScalarRange{
    .{ .lo = 0x11400, .hi = 0x1145b },
    .{ .lo = 0x1145d, .hi = 0x11461 },
};

pub const nushu = [_]ScalarRange{
    .{ .lo = 0x16fe1, .hi = 0x16fe1 },
    .{ .lo = 0x1b170, .hi = 0x1b2fb },
};

pub const old_north_arabian = [_]ScalarRange{.{ .lo = 0x10a80, .hi = 0x10a9f }};

pub const old_permic = [_]ScalarRange{.{ .lo = 0x10350, .hi = 0x1037a }};

pub const old_persian = [_]ScalarRange{
    .{ .lo = 0x103a0, .hi = 0x103c3 },
    .{ .lo = 0x103c8, .hi = 0x103d5 },
};

pub const old_sogdian = [_]ScalarRange{.{ .lo = 0x10f00, .hi = 0x10f27 }};
