const std = @import("std");

pub const KeywordAlt = struct {
    words: [][]u8,

    pub fn deinit(self: *KeywordAlt, allocator: std.mem.Allocator) void {
        for (self.words) |word| allocator.free(word);
        allocator.free(self.words);
    }

    pub fn match(self: *const KeywordAlt, text: []const u8) ?usize {
        for (self.words) |word| {
            if (text.len >= word.len and std.mem.eql(u8, text[0..word.len], word) and (text.len == word.len or !isWord(text[word.len]))) {
                return word.len;
            }
        }
        return null;
    }
};

pub const CompileError = error{UnsupportedKeywordAlt};

pub fn canCompile(pattern: []const u8) bool {
    if (!std.mem.startsWith(u8, pattern, "\\b(") or !std.mem.endsWith(u8, pattern, ")\\b")) return false;
    const inner = pattern[3 .. pattern.len - 3];
    var saw_pipe = false;
    var word_len: usize = 0;
    for (inner) |byte| switch (byte) {
        '|' => {
            if (word_len == 0) return false;
            saw_pipe = true;
            word_len = 0;
        },
        '0'...'9', 'A'...'Z', '_', 'a'...'z' => word_len += 1,
        else => return false,
    };
    return saw_pipe and word_len != 0;
}

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !KeywordAlt {
    if (!canCompile(pattern)) return error.UnsupportedKeywordAlt;
    const inner = pattern[3 .. pattern.len - 3];
    var words = std.ArrayList([]u8).empty;
    errdefer {
        for (words.items) |word| allocator.free(word);
        words.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |word| try words.append(allocator, try allocator.dupe(u8, word));
    return .{ .words = try words.toOwnedSlice(allocator) };
}

fn isWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "TextMate keyword alternation validates shape" {
    try std.testing.expect(canCompile("\\b(if|while|return)\\b"));
    try std.testing.expect(!canCompile("\\b(if|)\\b"));
    try std.testing.expect(!canCompile("if|while"));
}
