const std = @import("std");
const asset = @import("../../asset.zig");
const diagnostic = @import("template_diagnostic.zig");
const capability = @import("value_capability.zig");
const html_render = @import("../../html/render.zig");
const inline_text = @import("../../inline_text.zig");
const trusted_resource = @import("../../trusted_resource_url.zig");
const url = @import("../../url.zig");

pub const ValueError = html_render.Error || url.ValidationError || asset.AccessError ||
    trusted_resource.AccessError || error{ InvalidUrlKind, RenderWorkExhausted };

pub const EmptyScope = struct {};

pub fn Binding(
    comptime binding_name: []const u8,
    comptime Value: type,
    comptime Parent: type,
) type {
    return struct {
        value: Value,
        parent: Parent,

        pub const name = binding_name;
        pub const ValueType = Value;
        pub const ParentType = Parent;
    };
}

pub const ControlLink = struct {
    else_index: ?usize = null,
    close_index: usize = 0,
};

pub const OutputKind = enum(u3) {
    text,
    trusted_html,
    url,
    trusted_resource_url,
    asset_ref,
    unsupported,
};

pub fn outputKind(comptime T: type) OutputKind {
    if (T == url.Url) return .url;
    if (T == *const trusted_resource.TrustedResourceUrl) return .trusted_resource_url;
    if (asset.isAssetRef(T)) return .asset_ref;
    if (isTrustedHtml(T)) return .trusted_html;
    if (isText(T)) return .text;
    return .unsupported;
}

pub fn hasFormatText(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "formatText");
}

pub fn isInlineText(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "ploof_inline_text") or
        !@hasDecl(T, "bytes_maximum"))
    {
        return false;
    }
    const marker = @field(T, "ploof_inline_text");
    if (@TypeOf(marker) != bool) return false;
    if (!marker) return false;
    const maximum = @field(T, "bytes_maximum");
    if (!validMaximum(@TypeOf(maximum), maximum, inline_text.bytes_hard_max)) return false;
    return T == inline_text.InlineText(@intCast(maximum));
}

pub fn collectionChild(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |array| array.child,
        .pointer => |pointer| if (pointer.size == .slice) pointer.child else null,
        else => null,
    };
}

pub fn runtimeType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .type,
        .void,
        .noreturn,
        .undefined,
        .null,
        .comptime_float,
        .comptime_int,
        .enum_literal,
        .@"fn",
        .@"opaque",
        => false,
        else => true,
    };
}

fn isText(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .@"enum" => true,
        .array => |array| array.child == u8,
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        .@"struct" => isInlineText(T) or hasFormatText(T),
        else => false,
    };
}

fn isTrustedHtml(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "ploof_trusted_html") or
        !@hasDecl(T, "bytes_maximum"))
    {
        return false;
    }
    const marker = @field(T, "ploof_trusted_html");
    if (@TypeOf(marker) != bool) return false;
    if (!marker) return false;
    const maximum = @field(T, "bytes_maximum");
    if (!validMaximum(@TypeOf(maximum), maximum, html_render.trusted_html_bytes_hard_max)) {
        return false;
    }
    return T == html_render.TrustedHtml(@intCast(maximum));
}

fn validMaximum(comptime T: type, comptime value: anytype, comptime hard_max: u32) bool {
    switch (@typeInfo(T)) {
        .int, .comptime_int => {},
        else => return false,
    }
    return value > 0 and value <= hard_max;
}

pub fn WriterError(comptime Writer: type) type {
    const Base = writerBase(Writer);
    if (@typeInfo(Base) != .@"struct" or !@hasDecl(Base, "write")) {
        diagnostic.failConfig(.invalid_writer, "writer must expose write([]const u8)");
    }
    const function = @TypeOf(@field(Base, "write"));
    const info = switch (@typeInfo(function)) {
        .@"fn" => |value| value,
        else => diagnostic.failConfig(.invalid_writer, "writer write member must be a function"),
    };
    if (info.is_var_args or hasComptimeParameter(function)) {
        diagnostic.failConfig(.invalid_writer, "writer write parameters must be runtime values");
    }
    if (info.params.len != 2 or info.params[0].type == null or
        info.params[0].type.? != Writer)
    {
        diagnostic.failConfig(.invalid_writer, "writer write receiver must match writer exactly");
    }
    if (info.params[1].type == null or info.params[1].type.? != []const u8) {
        diagnostic.failConfig(.invalid_writer, "writer write requires []const u8 input");
    }
    const Return = info.return_type orelse {
        diagnostic.failConfig(.invalid_writer, "writer write requires an explicit return type");
    };
    return switch (@typeInfo(Return)) {
        .error_union => |error_union| finiteWriterReturn(error_union),
        else => diagnostic.failConfig(.invalid_writer, "writer write must return finite E!void"),
    };
}

pub const hasComptimeParameter = capability.hasComptimeParameter;

fn writerBase(comptime Writer: type) type {
    return switch (@typeInfo(Writer)) {
        .pointer => |pointer| if (pointer.size == .one) pointer.child else Writer,
        else => Writer,
    };
}

fn finiteWriterReturn(comptime error_union: std.builtin.Type.ErrorUnion) type {
    if (error_union.payload != void) {
        diagnostic.failConfig(.invalid_writer, "writer write must return finite E!void");
    }
    if (@typeInfo(error_union.error_set).error_set == null) {
        diagnostic.failConfig(.invalid_writer, "writer write requires a finite error set");
    }
    return error_union.error_set;
}

pub fn errorSet(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.error_set,
        else => error{},
    };
}

pub fn payloadType(comptime Return: type) type {
    return switch (@typeInfo(Return)) {
        .error_union => |error_union| error_union.payload,
        else => Return,
    };
}

comptime {
    std.debug.assert(@typeInfo(ValueError).error_set != null);
}
