const asset = @import("asset_runtime");
const options = @import("contract_options");
const source = @import("asset_bundle");

const Shape = struct {
    pub const format_version: u16 = 1;
};

const Version = Wrapper(.version);
const Count = Wrapper(.count);
const Prefix = Wrapper(.prefix);
const Order = Wrapper(.order);
const Path = Wrapper(.path);
const Media = Wrapper(.media);
const Etag = Wrapper(.etag);
const Gzip = Wrapper(.gzip);
const IdentityDigest = Wrapper(.identity_digest);
const GzipDigest = Wrapper(.gzip_digest);

const MediaTable = struct {
    pub const format_version: u16 = source.format_version;
    pub const route_prefix = source.route_prefix;
    pub const MediaKind = enum(u8) { css };
    pub const Representation = source.Representation;
    pub const Asset = source.Asset;
    pub const assets = source.assets;
};

const Mutation = enum {
    version,
    count,
    prefix,
    order,
    path,
    media,
    etag,
    gzip,
    identity_digest,
    gzip_digest,
};

fn Wrapper(comptime mutation: Mutation) type {
    return struct {
        pub const format_version: u16 = if (mutation == .version) 2 else source.format_version;
        pub const route_prefix = if (mutation == .prefix) "/Assets/" else source.route_prefix;
        pub const MediaKind = source.MediaKind;
        pub const Representation = source.Representation;
        pub const Asset = source.Asset;
        pub const assets = mutatedAssets(mutation);
    };
}

fn mutatedAssets(
    comptime mutation: Mutation,
) if (mutation == .count) [0]source.Asset else @TypeOf(source.assets) {
    if (mutation == .count) return .{};
    var values = source.assets;
    switch (mutation) {
        .order => {
            values[1].logical_name = "a.bin";
            values[1].path = "/assets/f543d842926a8800f88f37d3334e7a93/a.bin";
        },
        .path => values[0].path = "/assets/not-content-addressed/app.css",
        .media => values[0].media_type = "text/plain; charset=utf-8",
        .etag => values[0].identity.etag = "invalid",
        .gzip => values[0].gzip = null,
        .identity_digest => values[0].identity.bytes = "forged identity bytes",
        .gzip_digest => {
            var gzip = values[0].gzip.?;
            gzip.bytes = gzip.bytes[0 .. gzip.bytes.len - 1];
            values[0].gzip = gzip;
        },
        else => {},
    }
    return values;
}

const Generated = switch (options.case) {
    0 => Shape,
    1 => Version,
    2 => Count,
    3 => Prefix,
    4 => MediaTable,
    5 => Order,
    6 => Path,
    7 => Media,
    8 => Etag,
    9 => Gzip,
    11...13 => source,
    14 => IdentityDigest,
    15 => GzipDigest,
    else => @compileError("invalid asset contract failure case"),
};

const Assets = asset.Bundle(Generated);

comptime {
    switch (options.case) {
        11 => _ = Assets.local("missing.bin"),
        12 => _ = Assets.References(&.{}, .{ .origin_bytes_max = 0 }),
        13 => _ = Assets.References(&.{"http://cdn.example"}, .{}),
        else => _ = Assets,
    }
}
