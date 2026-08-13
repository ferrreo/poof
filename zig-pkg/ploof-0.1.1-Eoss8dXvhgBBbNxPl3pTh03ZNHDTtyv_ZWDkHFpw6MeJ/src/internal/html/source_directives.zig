const types = @import("source_types.zig");
const tables = @import("source_tables.zig");

pub const Lexed = struct {
    source: types.SourceRange,
    name: types.SourceRange = empty_range,
    expression: types.SourceRange = empty_range,
    auxiliary: types.SourceRange = empty_range,
    kind: types.DirectiveKind,
    block_kind: ?types.BlockKind = null,
    argument_count: u32 = 0,
    trim_before: bool,
    trim_after: bool,
};

pub const Failure = struct {
    code: types.ProblemCode,
    offset: u32,
    actual: u32 = 0,
    limit: u32 = 0,
};

pub const Result = union(enum) {
    directive: Lexed,
    failure: Failure,
};

const empty_range = types.SourceRange{ .start = 0, .end = 0 };

pub fn lex(
    source: []const u8,
    start: usize,
    profile: types.TemplateSourceProfile,
) Result {
    const bounds = directiveBounds(source, start) orelse return fail(
        .malformed_directive,
        start,
    );
    const content = trimSpace(source, bounds.content);
    if (content.start == content.end) return fail(.malformed_directive, start);
    const first = source[content.start];
    if (first == '{') return fail(.unsupported_directive, content.start);
    if (first == '!') return success(.{
        .source = bounds.source,
        .expression = range(content.start + 1, content.end),
        .kind = .comment,
        .trim_before = bounds.trim_before,
        .trim_after = bounds.trim_after,
    });
    if (first == '#') return lexOpenBlock(source, content, bounds, profile);
    if (first == '/') return lexCloseBlock(source, content, bounds);
    if (first == '>') return lexPartial(source, content, bounds, profile);
    if (first == '@') return lexCompilerDirective(source, content, bounds, profile);
    return lexInterpolationOrHelper(source, content, bounds, profile);
}

pub fn isExactVerbatimOpen(source: []const u8, start: usize) bool {
    const result = lex(source, start, .{});
    return switch (result) {
        .directive => |directive| directive.kind == .verbatim_open,
        .failure => false,
    };
}

pub fn isExactVerbatimClose(source: []const u8, start: usize) bool {
    const result = lex(source, start, .{});
    return switch (result) {
        .directive => |directive| directive.kind == .verbatim_close,
        .failure => false,
    };
}

pub fn validateFieldPath(
    source: []const u8,
    field: types.SourceRange,
    component_limit: u32,
) ?Failure {
    if (field.start == field.end) return failure(.field_path, field.start);
    var index: usize = field.start;
    var components: u32 = 0;
    while (index < field.end) {
        const component_start = index;
        if (!isIdentifierStart(source[index])) return failure(.field_path, index);
        index += 1;
        while (index < field.end and isIdentifierContinue(source[index])) index += 1;
        components += 1;
        if (components > component_limit) return .{
            .code = .field_path_limit,
            .offset = @intCast(component_start),
            .actual = components,
            .limit = component_limit,
        };
        if (index == field.end) break;
        if (source[index] != '.') return failure(.field_path, index);
        index += 1;
        if (index == field.end) return failure(.field_path, index - 1);
    }
    return null;
}

pub fn fieldRoot(field: types.SourceRange, source: []const u8) types.SourceRange {
    var end: usize = field.start;
    while (end < field.end and source[end] != '.') end += 1;
    return range(field.start, end);
}

pub fn validIdentifier(bytes: []const u8) bool {
    if (bytes.len == 0 or !isIdentifierStart(bytes[0])) return false;
    for (bytes[1..]) |byte| if (!isIdentifierContinue(byte)) return false;
    return true;
}

pub fn validStaticName(name: []const u8) bool {
    if (name.len == 0 or !isAsciiLetter(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isIdentifierContinue(byte) and byte != '-') return false;
    }
    return true;
}

fn isAsciiLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

const Bounds = struct {
    source: types.SourceRange,
    content: types.SourceRange,
    trim_before: bool,
    trim_after: bool,
};

fn directiveBounds(source: []const u8, start: usize) ?Bounds {
    if (start + 3 >= source.len or source[start] != '{' or source[start + 1] != '{') {
        return null;
    }
    var content_start = start + 2;
    const trim_before = source[content_start] == '-';
    if (trim_before) content_start += 1;
    var close = content_start;
    while (close + 1 < source.len) : (close += 1) {
        if (source[close] != '}' or source[close + 1] != '}') continue;
        var content_end = close;
        const trim_after = content_end > content_start and source[content_end - 1] == '-';
        if (trim_after) content_end -= 1;
        return .{
            .source = range(start, close + 2),
            .content = range(content_start, content_end),
            .trim_before = trim_before,
            .trim_after = trim_after,
        };
    }
    return null;
}

fn lexOpenBlock(
    source: []const u8,
    content: types.SourceRange,
    bounds: Bounds,
    profile: types.TemplateSourceProfile,
) Result {
    var tokens = TokenList.init(source, content);
    const marker = tokens.next() orelse return fail(.malformed_directive, content.start);
    if (marker.end - marker.start < 2) return fail(.malformed_directive, marker.start);
    const name = range(marker.start + 1, marker.end);
    const name_bytes = name.bytes(source);
    if (equal(name_bytes, "verbatim")) {
        if (tokens.next() != null) return fail(.malformed_directive, marker.end);
        return blockSuccess(bounds, name, empty_range, empty_range, .verbatim_open, .verbatim);
    }
    if (equal(name_bytes, "if")) {
        const expression = tokens.next() orelse return fail(.malformed_directive, marker.end);
        if (tokens.next() != null) return fail(.malformed_directive, expression.end);
        if (validateFieldPath(source, expression, profile.field_path_components_max)) |problem| {
            return .{ .failure = problem };
        }
        return blockSuccess(bounds, name, expression, empty_range, .if_open, .if_block);
    }
    if (equal(name_bytes, "with")) {
        return lexBindingBlock(source, &tokens, bounds, name, profile, .with_block);
    }
    if (equal(name_bytes, "each")) {
        return lexBindingBlock(source, &tokens, bounds, name, profile, .each_block);
    }
    return fail(.unsupported_directive, name.start);
}

fn lexBindingBlock(
    source: []const u8,
    tokens: *TokenList,
    bounds: Bounds,
    block_name: types.SourceRange,
    profile: types.TemplateSourceProfile,
    block_kind: types.BlockKind,
) Result {
    const expression = tokens.next() orelse return fail(.malformed_directive, block_name.end);
    const as_token = tokens.next() orelse return fail(.malformed_directive, expression.end);
    if (!equal(as_token.bytes(source), "as")) return fail(.malformed_directive, as_token.start);
    var local = tokens.next() orelse return fail(.malformed_directive, as_token.end);
    var auxiliary = empty_range;
    if (block_kind == .each_block) {
        const comma = findByte(local.bytes(source), ',');
        if (comma) |relative| {
            const original_end = local.end;
            local.end = local.start + @as(u32, @intCast(relative));
            if (relative + 1 < original_end - local.start) {
                auxiliary = range(local.end + 1, original_end);
            } else {
                auxiliary = tokens.next() orelse {
                    return fail(.malformed_directive, original_end - 1);
                };
            }
        }
    }
    if (!validIdentifier(local.bytes(source)) or reservedLocal(local.bytes(source))) {
        return fail(.reserved_local, local.start);
    }
    if (auxiliary.start != auxiliary.end) {
        if (!validIdentifier(auxiliary.bytes(source)) or
            reservedLocal(auxiliary.bytes(source)) or
            equal(auxiliary.bytes(source), local.bytes(source)))
        {
            return fail(.reserved_local, auxiliary.start);
        }
    }
    if (tokens.next() != null) return fail(.malformed_directive, local.end);
    if (validateFieldPath(source, expression, profile.field_path_components_max)) |problem| {
        return .{ .failure = problem };
    }
    const kind: types.DirectiveKind = if (block_kind == .with_block)
        .with_open
    else
        .each_open;
    return blockSuccess(bounds, local, expression, auxiliary, kind, block_kind);
}

fn lexCloseBlock(
    source: []const u8,
    content: types.SourceRange,
    bounds: Bounds,
) Result {
    var tokens = TokenList.init(source, content);
    const marker = tokens.next() orelse return fail(.malformed_directive, content.start);
    if (marker.end - marker.start < 2 or tokens.next() != null) {
        return fail(.malformed_directive, marker.start);
    }
    const name = range(marker.start + 1, marker.end);
    const kind: types.DirectiveKind = if (equal(name.bytes(source), "verbatim"))
        .verbatim_close
    else
        .block_close;
    return success(.{
        .source = bounds.source,
        .name = name,
        .kind = kind,
        .trim_before = bounds.trim_before,
        .trim_after = bounds.trim_after,
    });
}

fn lexPartial(
    source: []const u8,
    content: types.SourceRange,
    bounds: Bounds,
    profile: types.TemplateSourceProfile,
) Result {
    var tokens = TokenList.init(source, content);
    const marker = tokens.next() orelse return fail(.malformed_directive, content.start);
    if (!equal(marker.bytes(source), ">")) return fail(.malformed_directive, marker.start);
    const name = tokens.next() orelse return fail(.malformed_directive, marker.end);
    const expression = tokens.next() orelse return fail(.malformed_directive, name.end);
    if (tokens.next() != null or !validIdentifier(name.bytes(source))) {
        return fail(.malformed_directive, name.start);
    }
    if (validateFieldPath(source, expression, profile.field_path_components_max)) |problem| {
        return .{ .failure = problem };
    }
    return plainSuccess(bounds, name, expression, .partial, 1);
}

fn lexCompilerDirective(
    source: []const u8,
    content: types.SourceRange,
    bounds: Bounds,
    profile: types.TemplateSourceProfile,
) Result {
    var tokens = TokenList.init(source, content);
    const name = tokens.next() orelse return fail(.malformed_directive, content.start);
    if (equal(name.bytes(source), "@body")) {
        if (tokens.next() != null) return fail(.malformed_directive, name.end);
        return plainSuccess(bounds, name, empty_range, .body_slot, 0);
    }
    if (equal(name.bytes(source), "@inlineCss")) {
        return lexInlineAsset(source, &tokens, bounds, name, .inline_css);
    }
    if (equal(name.bytes(source), "@inlineJavaScript")) {
        return lexInlineAsset(source, &tokens, bounds, name, .inline_javascript);
    }
    if (!equal(name.bytes(source), "@jsonData")) {
        return fail(.unsupported_directive, name.start);
    }
    const static_name = tokens.next() orelse return fail(.malformed_directive, name.end);
    const expression = tokens.next() orelse return fail(.malformed_directive, static_name.end);
    if (tokens.next() != null) return fail(.malformed_directive, expression.end);
    if (validateFieldPath(source, expression, profile.field_path_components_max)) |problem| {
        return .{ .failure = problem };
    }
    return plainSuccess(bounds, static_name, expression, .json_data, 1);
}

fn lexInlineAsset(
    source: []const u8,
    tokens: *TokenList,
    bounds: Bounds,
    marker: types.SourceRange,
    kind: types.DirectiveKind,
) Result {
    const name = tokens.next() orelse return fail(.malformed_directive, marker.end);
    if (tokens.next() != null or !validIdentifier(name.bytes(source))) {
        return fail(.malformed_directive, name.start);
    }
    return plainSuccess(bounds, name, empty_range, kind, 0);
}

fn lexInterpolationOrHelper(
    source: []const u8,
    content: types.SourceRange,
    bounds: Bounds,
    profile: types.TemplateSourceProfile,
) Result {
    var tokens = TokenList.init(source, content);
    const first = tokens.next() orelse return fail(.malformed_directive, content.start);
    const second = tokens.next();
    if (second == null) {
        if (equal(first.bytes(source), "else")) {
            return plainSuccess(bounds, first, empty_range, .else_branch, 0);
        }
        if (validateFieldPath(source, first, profile.field_path_components_max)) |problem| {
            return .{ .failure = problem };
        }
        return plainSuccess(bounds, empty_range, first, .interpolation, 0);
    }
    if (!validIdentifier(first.bytes(source))) return fail(.malformed_directive, first.start);
    var argument_count: u32 = 1;
    var last = second.?;
    if (validateFieldPath(source, last, profile.field_path_components_max)) |problem| {
        return .{ .failure = problem };
    }
    while (tokens.next()) |argument| {
        argument_count += 1;
        if (argument_count > profile.helper_arguments_max) return .{
            .failure = .{
                .code = .helper_argument_limit,
                .offset = argument.start,
                .actual = argument_count,
                .limit = profile.helper_arguments_max,
            },
        };
        if (validateFieldPath(source, argument, profile.field_path_components_max)) |problem| {
            return .{ .failure = problem };
        }
        last = argument;
    }
    return plainSuccess(
        bounds,
        first,
        range(second.?.start, last.end),
        .helper,
        @intCast(argument_count),
    );
}

fn blockSuccess(
    bounds: Bounds,
    name: types.SourceRange,
    expression: types.SourceRange,
    auxiliary: types.SourceRange,
    kind: types.DirectiveKind,
    block_kind: types.BlockKind,
) Result {
    return success(.{
        .source = bounds.source,
        .name = name,
        .expression = expression,
        .auxiliary = auxiliary,
        .kind = kind,
        .block_kind = block_kind,
        .trim_before = bounds.trim_before,
        .trim_after = bounds.trim_after,
    });
}

fn plainSuccess(
    bounds: Bounds,
    name: types.SourceRange,
    expression: types.SourceRange,
    kind: types.DirectiveKind,
    argument_count: u32,
) Result {
    return success(.{
        .source = bounds.source,
        .name = name,
        .expression = expression,
        .kind = kind,
        .argument_count = argument_count,
        .trim_before = bounds.trim_before,
        .trim_after = bounds.trim_after,
    });
}

fn success(directive: Lexed) Result {
    return .{ .directive = directive };
}

fn fail(code: types.ProblemCode, offset: usize) Result {
    return .{ .failure = failure(code, offset) };
}

fn failure(code: types.ProblemCode, offset: usize) Failure {
    return .{ .code = code, .offset = @intCast(offset) };
}

const TokenList = struct {
    source: []const u8,
    end: usize,
    index: usize,

    fn init(source: []const u8, content: types.SourceRange) TokenList {
        return .{ .source = source, .index = content.start, .end = content.end };
    }

    fn next(tokens: *TokenList) ?types.SourceRange {
        while (tokens.index < tokens.end and tables.isHtmlSpace(tokens.source[tokens.index])) {
            tokens.index += 1;
        }
        if (tokens.index == tokens.end) return null;
        const start = tokens.index;
        while (tokens.index < tokens.end and !tables.isHtmlSpace(tokens.source[tokens.index])) {
            tokens.index += 1;
        }
        return range(start, tokens.index);
    }
};

fn trimSpace(source: []const u8, input: types.SourceRange) types.SourceRange {
    var result = input;
    while (result.start < result.end and tables.isHtmlSpace(source[result.start])) {
        result.start += 1;
    }
    while (result.end > result.start and tables.isHtmlSpace(source[result.end - 1])) {
        result.end -= 1;
    }
    return result;
}

fn findByte(bytes: []const u8, needle: u8) ?usize {
    for (bytes, 0..) |byte, index| if (byte == needle) return index;
    return null;
}

fn isIdentifierStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or (byte >= '0' and byte <= '9');
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn reservedLocal(name: []const u8) bool {
    return equal(name, "view") or equal(name, "if") or equal(name, "with") or
        equal(name, "each") or equal(name, "else") or equal(name, "verbatim");
}

fn range(start: usize, end: usize) types.SourceRange {
    return .{ .start = @intCast(start), .end = @intCast(end) };
}
