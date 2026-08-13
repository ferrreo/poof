const std = @import("std");
const request_head = @import("request_head.zig");

pub const coding_members_max: u8 = 64;
pub const empty_members_max: u8 = 32;

pub const Preferences = struct {
    gzip: u16,
    identity: u16,
};

pub const Result = union(enum) {
    accepted: Preferences,
    rejected,
};

const Seen = struct {
    name: []const u8,
    weight: u16,
};

const State = struct {
    seen: [coding_members_max]Seen = undefined,
    members: u8 = 0,
    unique: u8 = 0,
    empty_members: u8 = 0,
    gzip: ?u16 = null,
    identity: ?u16 = null,
    wildcard: ?u16 = null,
};

pub fn analyze(fields: []const request_head.Field, bytes: []const u8) Result {
    var state = State{};
    for (fields) |field| {
        if (!equalIgnoreCase(field.name.slice(bytes), "accept-encoding")) continue;
        if (!parseValue(&state, field.value.slice(bytes))) return .rejected;
    }
    const gzip: u16 = state.gzip orelse state.wildcard orelse 0;
    const identity: u16 = state.identity orelse if (state.wildcard == 0) 0 else 1000;
    return .{ .accepted = .{ .gzip = gzip, .identity = identity } };
}

fn parseValue(state: *State, value: []const u8) bool {
    for (value) |byte| {
        if (!fieldValueByte(byte)) return false;
    }
    var start: usize = 0;
    var end: usize = 0;
    while (end <= value.len) : (end += 1) {
        if (end != value.len and value[end] != ',') continue;
        const member = trimOws(value[start..end]);
        if (member.len == 0) {
            if (state.empty_members == empty_members_max) return false;
            state.empty_members += 1;
        } else {
            const parsed = parseMember(member) orelse return false;
            if (!record(state, parsed.name, parsed.weight)) return false;
        }
        start = end + 1;
    }
    return true;
}

const Member = struct {
    name: []const u8,
    weight: u16,
};

fn parseMember(member: []const u8) ?Member {
    const semicolon = std.mem.indexOfScalar(u8, member, ';');
    const name = trimOws(if (semicolon) |index| member[0..index] else member);
    if (!token(name)) return null;
    if (semicolon == null) return .{ .name = name, .weight = 1000 };

    const weight_text = trimOws(member[semicolon.? + 1 ..]);
    if (weight_text.len < 3) return null;
    if (asciiLower(weight_text[0]) != 'q' or weight_text[1] != '=') return null;
    const qvalue = trimTrailingOws(weight_text[2..]);
    const weight = parseQvalue(qvalue) orelse return null;
    return .{ .name = name, .weight = weight };
}

fn parseQvalue(value: []const u8) ?u16 {
    if (value.len == 0 or (value[0] != '0' and value[0] != '1')) return null;
    if (value.len == 1) return if (value[0] == '1') 1000 else 0;
    if (value[1] != '.' or value.len > 5) return null;

    var weight: u16 = if (value[0] == '1') 1000 else 0;
    var place: u16 = 100;
    for (value[2..]) |byte| {
        if (byte < '0' or byte > '9') return null;
        if (value[0] == '1' and byte != '0') return null;
        if (value[0] == '0') weight += @as(u16, byte - '0') * place;
        place /= 10;
    }
    return weight;
}

fn record(state: *State, name: []const u8, weight: u16) bool {
    if (state.members == coding_members_max) return false;
    state.members += 1;
    for (state.seen[0..state.unique]) |seen| {
        if (!equalIgnoreCase(seen.name, name)) continue;
        return seen.weight == weight;
    }
    state.seen[state.unique] = .{ .name = name, .weight = weight };
    state.unique += 1;
    if (equalIgnoreCase(name, "gzip")) state.gzip = weight;
    if (equalIgnoreCase(name, "identity")) state.identity = weight;
    if (std.mem.eql(u8, name, "*")) state.wildcard = weight;
    return true;
}

fn token(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!tokenByte(byte)) return false;
    }
    return true;
}

fn tokenByte(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z') or
        std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null;
}

fn fieldValueByte(byte: u8) bool {
    return byte == '\t' or (byte >= 0x20 and byte != 0x7f);
}

fn equalIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (asciiLower(left_byte) != asciiLower(right_byte)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn trimOws(value: []const u8) []const u8 {
    var start: usize = 0;
    while (start < value.len and (value[start] == ' ' or value[start] == '\t')) start += 1;
    return trimTrailingOws(value[start..]);
}

fn trimTrailingOws(value: []const u8) []const u8 {
    var end = value.len;
    while (end != 0 and (value[end - 1] == ' ' or value[end - 1] == '\t')) end -= 1;
    return value[0..end];
}
