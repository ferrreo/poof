const std = @import("std");
const upload = @import("../../multipart/upload.zig");

pub const OccurrenceError = error{
    InvalidOccurrence,
    OccurrenceOutOfOrder,
    VariantMismatch,
};

pub fn Layout(comptime Spec: type) type {
    requireFiles(Spec);
    const schema = Spec.configured_schema;

    return struct {
        const Self = @This();

        pub const StateStorage = stateStorageType(schema);
        pub const SummaryStorage = summaryStorageType(schema);
        pub const SummaryLengths = summaryLengthsType(schema);
        pub const State = StatePointer(Spec);
        pub const Summary = SummaryValue(Spec);

        pub const file_field_count = fileFieldCount(schema);
        pub const total_maximum = totalMaximum(schema);
        pub const non_discard_total_maximum = nonDiscardTotalMaximum(schema);
        pub const request_handles_maximum = requestHandlesMaximum(schema);

        states: StateStorage,
        summaries: SummaryStorage,
        summary_lengths: SummaryLengths,

        pub fn init() Self {
            var result: Self = undefined;
            inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
                const Part = @TypeOf(@field(schema, field.name));
                if (Part.kind != .file) continue;
                @field(result.summary_lengths, field.name) = 0;
            }
            return result;
        }

        pub fn beginState(
            self: *Self,
            tag: Spec.File,
            occurrence: u16,
        ) OccurrenceError!State {
            return switch (tag) {
                inline else => |selected| selected: {
                    const name = @tagName(selected);
                    const Sink = @TypeOf(@field(schema, name)).SinkType;
                    const values = &@field(self.states, name);
                    const maximum: u16 = values.len;
                    if (occurrence == 0 or occurrence > maximum) {
                        return error.InvalidOccurrence;
                    }
                    values[occurrence - 1] = Sink.initial_state;
                    break :selected @unionInit(State, name, &values[occurrence - 1]);
                },
            };
        }

        pub fn storeSummary(
            self: *Self,
            tag: Spec.File,
            occurrence: u16,
            summary: Summary,
        ) OccurrenceError!void {
            return switch (tag) {
                inline else => |selected| self.storeSummaryFor(
                    @tagName(selected),
                    occurrence,
                    summary,
                ),
            };
        }

        pub fn summaryViews(self: *const Self) Spec.Summaries {
            var result: Spec.Summaries = undefined;
            inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
                const Part = @TypeOf(@field(schema, field.name));
                if (Part.kind != .file) continue;
                @field(result, field.name) = .{
                    .values = &@field(self.summaries, field.name),
                    .len = @field(self.summary_lengths, field.name),
                };
            }
            return result;
        }

        fn storeSummaryFor(
            self: *Self,
            comptime name: []const u8,
            occurrence: u16,
            summary: Summary,
        ) OccurrenceError!void {
            const values = &@field(self.summaries, name);
            const maximum: u16 = values.len;
            if (occurrence == 0 or occurrence > maximum) {
                return error.InvalidOccurrence;
            }
            if (std.meta.activeTag(summary) != @field(Spec.File, name)) {
                return error.VariantMismatch;
            }
            const length = &@field(self.summary_lengths, name);
            if (length.* == maximum or occurrence != length.* + 1) {
                return error.OccurrenceOutOfOrder;
            }
            values[occurrence - 1] = @field(summary, name);
            length.* += 1;
        }
    };
}

pub fn StatePointer(comptime Spec: type) type {
    requireFiles(Spec);
    const schema = Spec.configured_schema;
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = *Part.SinkType.State;
        index += 1;
    }
    return @Union(.auto, Spec.File, &names, &types, &@splat(.{}));
}

pub fn SummaryValue(comptime Spec: type) type {
    requireFiles(Spec);
    const schema = Spec.configured_schema;
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = Part.SinkType.Summary;
        index += 1;
    }
    return @Union(.auto, Spec.File, &names, &types, &@splat(.{}));
}

fn stateStorageType(comptime schema: anytype) type {
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    fillStorageFields(schema, .state, &names, &types);
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn summaryStorageType(comptime schema: anytype) type {
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    fillStorageFields(schema, .summary, &names, &types);
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

fn summaryLengthsType(comptime schema: anytype) type {
    const count = fileFieldCount(schema);
    var names: [count][]const u8 = undefined;
    var types: [count]type = undefined;
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        names[index] = field.name;
        types[index] = std.math.IntFittingRange(0, Part.cardinality.maximum());
        index += 1;
    }
    return @Struct(.auto, null, &names, &types, &@splat(.{}));
}

const StorageKind = enum { state, summary };

fn fillStorageFields(
    comptime schema: anytype,
    comptime kind: StorageKind,
    names: anytype,
    types: anytype,
) void {
    var index: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        const Element = switch (kind) {
            .state => Part.SinkType.State,
            .summary => Part.SinkType.Summary,
        };
        names[index] = field.name;
        types[index] = [Part.cardinality.maximum()]Element;
        index += 1;
    }
}

fn fileFieldCount(comptime schema: anytype) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        count += @intFromBool(Part.kind == .file);
    }
    return count;
}

fn totalMaximum(comptime schema: anytype) u32 {
    var total: u32 = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind == .file) total += Part.cardinality.maximum();
    }
    return total;
}

fn nonDiscardTotalMaximum(comptime schema: anytype) u32 {
    var total: u32 = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind == .file and Part.SinkType != upload.DiscardSink) {
            total += Part.cardinality.maximum();
        }
    }
    return total;
}

fn requestHandlesMaximum(comptime schema: anytype) u32 {
    var total: u32 = 0;
    inline for (@typeInfo(@TypeOf(schema)).@"struct".fields) |field| {
        const Part = @TypeOf(@field(schema, field.name));
        if (Part.kind != .file) continue;
        const maximum: u32 = Part.cardinality.maximum();
        total += maximum * Part.SinkType.request_handles_max;
    }
    return total;
}

fn requireFiles(comptime Spec: type) void {
    if (!@hasDecl(Spec, "configured_schema") or !@hasDecl(Spec, "File") or
        !@hasDecl(Spec, "Summaries"))
    {
        @compileError("multipart upload layout requires a multipart decoder spec");
    }
    if (fileFieldCount(Spec.configured_schema) == 0) {
        @compileError("multipart upload layout requires at least one file field");
    }
}

test {
    std.testing.refAllDecls(@This());
}
