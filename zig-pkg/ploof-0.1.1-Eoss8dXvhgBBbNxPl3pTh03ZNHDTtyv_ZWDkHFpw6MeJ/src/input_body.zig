const std = @import("std");

pub const decoders_hard_max: usize = 4;

pub const DecoderKind = enum(u8) {
    bytes,
    text,
    json,
    form,
    multipart,
};

pub fn oneOf(comptime decoders: anytype) Alternatives(decoders) {
    return .{};
}

pub fn Alternatives(comptime decoders: anytype) type {
    comptime validateAlternatives(decoders);
    return struct {
        pub const ploof_body_alternatives = true;
        pub const configured_decoders = decoders;
        pub const Input = inputUnion(decoders);
        pub const decoder_count: u8 = @typeInfo(@TypeOf(decoders)).@"struct".fields.len;
    };
}

pub fn isDecoder(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_body_decoder_spec") and T.ploof_body_decoder_spec;
}

pub fn isAlternatives(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        @hasDecl(T, "ploof_body_alternatives") and T.ploof_body_alternatives;
}

pub fn Input(comptime Spec: type) type {
    if (isDecoder(Spec)) return Spec.Target;
    if (isAlternatives(Spec)) return Spec.Input;
    @compileError("PLOOF-E3239 invalid body decoder declaration");
}

fn validateAlternatives(comptime decoders: anytype) void {
    const info = switch (@typeInfo(@TypeOf(decoders))) {
        .@"struct" => |value| value,
        else => @compileError("PLOOF-E3240 body decoders must be a named struct literal"),
    };
    if (info.is_tuple) @compileError("PLOOF-E3528 body decoders must use named tags");
    if (info.fields.len == 0) @compileError("PLOOF-E3241 body decoder table is empty");
    if (info.fields.len > decoders_hard_max) {
        @compileError("PLOOF-E3242 body decoder table exceeds four alternatives");
    }
    inline for (info.fields) |field| {
        const Spec = @TypeOf(@field(decoders, field.name));
        if (!isDecoder(Spec)) @compileError("PLOOF-E3243 invalid body decoder");
    }
}

fn inputUnion(comptime decoders: anytype) type {
    const fields = @typeInfo(@TypeOf(decoders)).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    var values: [fields.len]u8 = undefined;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        names[index] = field.name;
        values[index] = @intCast(index);
        types[index] = @TypeOf(@field(decoders, field.name)).Target;
    }
    const Tag = @Enum(u8, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &@splat(.{}));
}

test "alternatives generate an exact tagged input union" {
    const Json = struct {
        pub const ploof_body_decoder_spec = true;
        pub const Target = struct { id: u8 };
    };
    const Form = struct {
        pub const ploof_body_decoder_spec = true;
        pub const Target = struct { name: []const u8 };
    };
    const spec = oneOf(.{ .json = Json{}, .form = Form{} });
    const Spec = @TypeOf(spec);
    const value = Spec.Input{ .json = .{ .id = 7 } };
    try std.testing.expectEqual(@as(u8, 7), value.json.id);
    try std.testing.expectEqual(@as(u8, 2), Spec.decoder_count);
}
