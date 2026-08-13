const std = @import("std");
const events = @import("events.zig");

pub const StartError = error{ InvalidEntry, InvalidOccurrence, VariantMismatch };

pub fn validateStart(
    comptime Spec: type,
    occurrences: []const u16,
    event: events.FileStart,
    begin_input: Spec.BeginInput,
) StartError!Spec.File {
    const tag = tagForEntry(Spec, event.entry_index) orelse return error.InvalidEntry;
    if (std.meta.activeTag(begin_input) != tag) return error.VariantMismatch;
    const maximum = maximumForEntry(Spec, event.entry_index) orelse {
        return error.InvalidEntry;
    };
    const previous = occurrences[event.entry_index];
    if (!occurrenceValid(previous, event.occurrence, maximum)) {
        return error.InvalidOccurrence;
    }
    return tag;
}

pub fn tagForEntry(comptime Spec: type, entry_index: u16) ?Spec.File {
    const fields = @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (entry_index == index) {
            if (Part.kind != .file) return null;
            return @field(Spec.File, field.name);
        }
    }
    return null;
}

pub fn maximumForEntry(comptime Spec: type, entry_index: u16) ?u16 {
    const fields = @typeInfo(@TypeOf(Spec.configured_schema)).@"struct".fields;
    inline for (fields, 0..) |field, index| {
        const Part = @TypeOf(@field(Spec.configured_schema, field.name));
        if (entry_index == index) {
            if (Part.kind != .file) return null;
            return Part.cardinality.maximum();
        }
    }
    return null;
}

pub fn occurrenceValid(previous: u16, current: u16, maximum: u16) bool {
    return current != 0 and current <= maximum and previous < maximum and
        current - 1 == previous;
}

test "occurrence validation cannot overflow at the u16 maximum" {
    const maximum = std.math.maxInt(u16);
    try std.testing.expect(occurrenceValid(maximum - 1, maximum, maximum));
    try std.testing.expect(!occurrenceValid(maximum, maximum, maximum));
    try std.testing.expect(!occurrenceValid(maximum, 1, maximum));
}
