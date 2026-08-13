const std = @import("std");
const body = @import("../../body.zig");
const token_source = @import("token_source.zig");

const SipHash = std.crypto.auth.siphash.SipHash64(1, 3);

pub const RootKind = enum(u8) {
    null,
    boolean,
    number,
    string,
    array,
    object,
};

pub const Options = struct {
    hash_key: [16]u8,
    depth_max: u16 = token_source.depth_standard_max,
};

pub const Result = struct {
    input_bytes: usize,
    root_kind: RootKind,
    values: u32 = 0,
    objects: u32 = 0,
    arrays: u32 = 0,
    object_members: u32 = 0,
    array_items: u32 = 0,
    string_values: u32 = 0,
    number_values: u32 = 0,
    copied_string_bytes: usize = 0,
    copied_number_bytes: usize = 0,
    copied_key_bytes: usize = 0,
    token_bytes_max: usize = 0,
    number_bytes_max: usize = 0,
    key_bytes_max: usize = 0,
    copied_key_bytes_max: usize = 0,
    duplicate_scratch_bytes: usize = 0,
};

const NameRecord = struct {
    name: []const u8,
    object_id: u32,
};

pub const scratch_alignment = @alignOf(NameRecord);

pub const Error = token_source.Error || error{
    CountOverflow,
    DuplicateName,
};

pub fn validate(
    input: body.Bytes,
    scratch: []align(scratch_alignment) u8,
    options: Options,
) Error!Result {
    var result = try scanCounts(input, options.depth_max);
    result.duplicate_scratch_bytes = try scratchBytes(result);
    if (scratch.len < result.duplicate_scratch_bytes) {
        return error.ScratchTooSmall;
    }
    if (result.object_members != 0) {
        try rejectDuplicates(
            input,
            scratch[0..result.duplicate_scratch_bytes],
            result,
            options,
        );
    }
    return result;
}

pub fn scratchBytes(result: Result) error{CountOverflow}!usize {
    return (try scratchLayout(result)).total;
}

const ScratchLayout = struct {
    record_bytes: usize = 0,
    slot_count: usize = 0,
    names_start: usize = 0,
    token_start: usize = 0,
    total: usize = 0,
};

fn scratchLayout(result: Result) error{CountOverflow}!ScratchLayout {
    if (result.object_members == 0) return .{};
    const members: usize = result.object_members;
    if (members == std.math.maxInt(u32)) return error.CountOverflow;
    const doubled = std.math.mul(usize, members, 2) catch {
        return error.CountOverflow;
    };
    const slot_count = std.math.ceilPowerOfTwo(usize, @max(2, doubled)) catch {
        return error.CountOverflow;
    };
    const record_bytes = std.math.mul(usize, members, @sizeOf(NameRecord)) catch {
        return error.CountOverflow;
    };
    const slot_bytes = std.math.mul(usize, slot_count, @sizeOf(u32)) catch {
        return error.CountOverflow;
    };
    const names_start = add(record_bytes, slot_bytes) catch return error.CountOverflow;
    const token_start = add(names_start, result.copied_key_bytes) catch {
        return error.CountOverflow;
    };
    return .{
        .record_bytes = record_bytes,
        .slot_count = slot_count,
        .names_start = names_start,
        .token_start = token_start,
        .total = add(token_start, result.copied_key_bytes_max) catch {
            return error.CountOverflow;
        },
    };
}

const ContainerKind = enum(u8) {
    array,
    object,
};

const Frame = struct {
    object_id: u32 = 0,
    kind: ContainerKind,
    expects_name: bool,
};

const Structure = struct {
    frames: []Frame,
    depth: u16 = 0,
    object_id_next: u32 = 1,
    root_kind: RootKind = undefined,
    root_seen: bool = false,

    fn isName(self: *const Structure) bool {
        if (self.depth == 0) return false;
        const frame = self.frames[self.depth - 1];
        return frame.kind == .object and frame.expects_name;
    }

    fn objectId(self: *const Structure) Error!u32 {
        if (!self.isName()) return error.Syntax;
        return self.frames[self.depth - 1].object_id;
    }

    fn nameDone(self: *Structure) Error!void {
        if (!self.isName()) return error.Syntax;
        self.frames[self.depth - 1].expects_name = false;
    }

    fn beginValue(self: *Structure, kind: RootKind) Error!bool {
        if (self.depth == 0) {
            if (self.root_seen) return error.Syntax;
            self.root_kind = kind;
            self.root_seen = true;
            return false;
        }
        const frame = &self.frames[self.depth - 1];
        if (frame.kind == .array) return true;
        if (frame.expects_name) return error.Syntax;
        frame.expects_name = true;
        return false;
    }

    fn beginContainer(self: *Structure, kind: ContainerKind) Error!bool {
        const in_array = try self.beginValue(switch (kind) {
            .array => .array,
            .object => .object,
        });
        if (self.depth == self.frames.len) return error.DepthLimitExceeded;
        const object_id = if (kind == .object) try self.takeObjectId() else 0;
        self.frames[self.depth] = .{
            .kind = kind,
            .expects_name = kind == .object,
            .object_id = object_id,
        };
        self.depth += 1;
        return in_array;
    }

    fn endContainer(self: *Structure, kind: ContainerKind) Error!void {
        if (self.depth == 0) return error.Syntax;
        const frame = self.frames[self.depth - 1];
        if (frame.kind != kind) return error.Syntax;
        if (kind == .object and !frame.expects_name) return error.Syntax;
        self.depth -= 1;
    }

    fn finish(self: *const Structure) Error!void {
        if (!self.root_seen or self.depth != 0) return error.Syntax;
    }

    fn takeObjectId(self: *Structure) Error!u32 {
        const value = self.object_id_next;
        self.object_id_next = std.math.add(u32, value, 1) catch {
            return error.CountOverflow;
        };
        return value;
    }
};

const Counter = struct {
    structure: Structure,
    result: Result,

    fn init(input_bytes: usize, frames: []Frame) Counter {
        return .{
            .structure = .{ .frames = frames },
            .result = .{ .input_bytes = input_bytes, .root_kind = undefined },
        };
    }

    fn container(self: *Counter, kind: ContainerKind) Error!void {
        const in_array = try self.structure.beginContainer(kind);
        try increment(&self.result.values);
        if (in_array) try increment(&self.result.array_items);
        switch (kind) {
            .object => try increment(&self.result.objects),
            .array => try increment(&self.result.arrays),
        }
    }

    fn scalar(self: *Counter, kind: RootKind) Error!void {
        const in_array = try self.structure.beginValue(kind);
        try increment(&self.result.values);
        if (in_array) try increment(&self.result.array_items);
    }

    fn string(self: *Counter, measured: token_source.Measure) Error!void {
        self.result.token_bytes_max = @max(self.result.token_bytes_max, measured.bytes);
        if (self.structure.isName()) {
            try increment(&self.result.object_members);
            self.result.key_bytes_max = @max(self.result.key_bytes_max, measured.bytes);
            if (measured.copied) {
                self.result.copied_key_bytes = try add(
                    self.result.copied_key_bytes,
                    measured.bytes,
                );
                self.result.copied_key_bytes_max = @max(
                    self.result.copied_key_bytes_max,
                    measured.bytes,
                );
            }
            return self.structure.nameDone();
        }
        try self.scalar(.string);
        try increment(&self.result.string_values);
        if (measured.copied) {
            self.result.copied_string_bytes = try add(
                self.result.copied_string_bytes,
                measured.bytes,
            );
        }
    }

    fn number(self: *Counter, measured: token_source.Measure) Error!void {
        try self.scalar(.number);
        try increment(&self.result.number_values);
        self.result.token_bytes_max = @max(self.result.token_bytes_max, measured.bytes);
        self.result.number_bytes_max = @max(self.result.number_bytes_max, measured.bytes);
        if (measured.copied) {
            self.result.copied_number_bytes = try add(
                self.result.copied_number_bytes,
                measured.bytes,
            );
        }
    }

    fn finish(self: *Counter) Error!Result {
        try self.structure.finish();
        self.result.root_kind = self.structure.root_kind;
        return self.result;
    }
};

fn scanCounts(input: body.Bytes, depth_max: u16) Error!Result {
    if (depth_max <= 8) return scanCountsCapacity(8, input, depth_max);
    if (depth_max <= 16) return scanCountsCapacity(16, input, depth_max);
    if (depth_max <= 32) return scanCountsCapacity(32, input, depth_max);
    if (depth_max <= 64) return scanCountsCapacity(64, input, depth_max);
    if (depth_max <= 128) return scanCountsCapacity(128, input, depth_max);
    return scanCountsCapacity(token_source.depth_hard_max, input, depth_max);
}

fn scanCountsCapacity(
    comptime capacity: usize,
    input: body.Bytes,
    depth_max: u16,
) Error!Result {
    var source: token_source.Source = undefined;
    try source.init(input, depth_max);
    defer source.deinit();
    var frames: [capacity]Frame = undefined;
    var counter = Counter.init(input.len(), &frames);
    while (true) {
        const token = try source.nextRaw();
        switch (token) {
            .object_begin => try counter.container(.object),
            .array_begin => try counter.container(.array),
            .object_end => try counter.structure.endContainer(.object),
            .array_end => try counter.structure.endContainer(.array),
            .true, .false => try counter.scalar(.boolean),
            .null => try counter.scalar(.null),
            .number, .partial_number => {
                try counter.number(try source.measureNumber(token));
            },
            .string,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => try counter.string(try source.measureString(token)),
            .allocated_number, .allocated_string => unreachable,
            .end_of_document => break,
        }
    }
    return counter.finish();
}

const Scratch = struct {
    records: []NameRecord,
    slots: []u32,
    owned_names: []u8,
    token: []u8,
    records_used: usize = 0,
    owned_used: usize = 0,

    fn init(bytes: []align(scratch_alignment) u8, result: Result) Error!Scratch {
        const layout = try scratchLayout(result);
        if (bytes.len < layout.total) return error.ScratchTooSmall;
        const records = std.mem.bytesAsSlice(
            NameRecord,
            bytes[0..layout.record_bytes],
        );
        const slot_bytes: []align(@alignOf(u32)) u8 = @alignCast(
            bytes[layout.record_bytes..layout.names_start],
        );
        const slots = std.mem.bytesAsSlice(u32, slot_bytes);
        if (slots.len != layout.slot_count) return error.ScratchTooSmall;
        @memset(slots, 0);
        return .{
            .records = records,
            .slots = slots,
            .owned_names = bytes[layout.names_start..layout.token_start],
            .token = bytes[layout.token_start..layout.total],
        };
    }

    fn insert(
        self: *Scratch,
        object_id: u32,
        text: token_source.Text,
        hash_key: *const [16]u8,
    ) Error!void {
        const mask = self.slots.len - 1;
        var slot_index = nameHash(object_id, text.bytes, hash_key) & mask;
        var probes: usize = 0;
        while (probes < self.slots.len) : (probes += 1) {
            const stored = self.slots[slot_index];
            if (stored == 0) return self.store(slot_index, object_id, text);
            const record = self.records[stored - 1];
            if (record.object_id == object_id and
                std.mem.eql(u8, record.name, text.bytes))
            {
                return error.DuplicateName;
            }
            slot_index = (slot_index + 1) & mask;
        }
        return error.ScratchTooSmall;
    }

    fn store(
        self: *Scratch,
        slot_index: usize,
        object_id: u32,
        text: token_source.Text,
    ) Error!void {
        if (self.records_used >= self.records.len) return error.ScratchTooSmall;
        const name = if (text.copied) try self.copyName(text.bytes) else text.bytes;
        self.records[self.records_used] = .{ .name = name, .object_id = object_id };
        self.slots[slot_index] = @intCast(self.records_used + 1);
        self.records_used += 1;
    }

    fn copyName(self: *Scratch, name: []const u8) Error![]const u8 {
        const end = add(self.owned_used, name.len) catch {
            return error.ScratchTooSmall;
        };
        if (end > self.owned_names.len) return error.ScratchTooSmall;
        @memcpy(self.owned_names[self.owned_used..end], name);
        defer self.owned_used = end;
        return self.owned_names[self.owned_used..end];
    }
};

fn rejectDuplicates(
    input: body.Bytes,
    scratch_bytes: []align(scratch_alignment) u8,
    result: Result,
    options: Options,
) Error!void {
    if (options.depth_max <= 8) {
        return rejectDuplicatesCapacity(8, input, scratch_bytes, result, options);
    }
    if (options.depth_max <= 16) {
        return rejectDuplicatesCapacity(16, input, scratch_bytes, result, options);
    }
    if (options.depth_max <= 32) {
        return rejectDuplicatesCapacity(32, input, scratch_bytes, result, options);
    }
    if (options.depth_max <= 64) {
        return rejectDuplicatesCapacity(64, input, scratch_bytes, result, options);
    }
    if (options.depth_max <= 128) {
        return rejectDuplicatesCapacity(128, input, scratch_bytes, result, options);
    }
    return rejectDuplicatesCapacity(
        token_source.depth_hard_max,
        input,
        scratch_bytes,
        result,
        options,
    );
}

fn rejectDuplicatesCapacity(
    comptime capacity: usize,
    input: body.Bytes,
    scratch_bytes: []align(scratch_alignment) u8,
    result: Result,
    options: Options,
) Error!void {
    var source: token_source.Source = undefined;
    try source.init(input, options.depth_max);
    defer source.deinit();
    var scratch = try Scratch.init(scratch_bytes, result);
    var frames: [capacity]Frame = undefined;
    var structure = Structure{ .frames = &frames };
    while (true) {
        const token = try source.nextRaw();
        switch (token) {
            .object_begin => _ = try structure.beginContainer(.object),
            .array_begin => _ = try structure.beginContainer(.array),
            .object_end => try structure.endContainer(.object),
            .array_end => try structure.endContainer(.array),
            .true, .false => _ = try structure.beginValue(.boolean),
            .null => _ = try structure.beginValue(.null),
            .number, .partial_number => {
                try source.discardNumber(token);
                _ = try structure.beginValue(.number);
            },
            .string,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => try handleDuplicateString(
                &source,
                &scratch,
                &structure,
                token,
                &options.hash_key,
            ),
            .allocated_number, .allocated_string => unreachable,
            .end_of_document => break,
        }
    }
    try structure.finish();
    if (scratch.records_used != result.object_members) return error.Syntax;
}

fn handleDuplicateString(
    source: *token_source.Source,
    scratch: *Scratch,
    structure: *Structure,
    first: token_source.RawToken,
    hash_key: *const [16]u8,
) Error!void {
    if (!structure.isName()) {
        try source.discardString(first);
        _ = try structure.beginValue(.string);
        return;
    }
    const name = try source.completeString(first, scratch.token);
    try scratch.insert(try structure.objectId(), name, hash_key);
    try structure.nameDone();
}

fn nameHash(object_id: u32, name: []const u8, key: *const [16]u8) usize {
    var hash = SipHash.init(key);
    hash.update(std.mem.asBytes(&object_id));
    hash.update(name);
    return @intCast(hash.finalInt());
}

fn increment(value: *u32) error{CountOverflow}!void {
    value.* = std.math.add(u32, value.*, 1) catch return error.CountOverflow;
}

fn add(left: usize, right: usize) error{CountOverflow}!usize {
    return std.math.add(usize, left, right) catch error.CountOverflow;
}

test {
    std.testing.refAllDecls(@This());
}
