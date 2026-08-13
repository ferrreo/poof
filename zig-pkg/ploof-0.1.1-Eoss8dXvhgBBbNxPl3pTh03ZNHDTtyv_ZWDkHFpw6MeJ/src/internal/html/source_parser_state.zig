const std = @import("std");
const tables = @import("source_tables.zig");
const types = @import("source_types.zig");

pub const ElementFrame = struct {
    name: types.SourceRange,
    namespace: tables.Namespace,
    open_at: u32,
};

pub const DocumentStage = enum(u4) {
    fragment,
    need_doctype,
    need_html,
    need_head,
    in_head,
    need_body,
    in_body,
    need_html_close,
    closed,
};

pub const ContextSnapshot = struct {
    context: types.ParserContext,
    region: types.Region,
    document_stage: DocumentStage,
    element_depth: usize,
    tag_separator: bool,
};

pub const ControlFrame = struct {
    kind: types.BlockKind,
    name: types.SourceRange,
    auxiliary: types.SourceRange,
    snapshot: ContextSnapshot,
    id: u32,
    open_at: u32,
    parent_path: u32,
    first_branch_separator: bool = false,
    had_else: bool = false,
    else_branch: bool = false,
};

pub const no_path = std.math.maxInt(u32);

pub const PathNode = struct {
    parent: u32,
    block_id: u32,
    else_branch: bool,
};

pub const AttributeSeen = struct {
    name: types.SourceRange,
    value: types.SourceRange,
    path: u32,
    first_directive: u32,
    directive_count: u32,
    has_value: bool,
};

pub fn appendPath(
    paths: []PathNode,
    count: *usize,
    parent: u32,
    block_id: u32,
    else_branch: bool,
) u32 {
    std.debug.assert(count.* < paths.len);
    const result: u32 = @intCast(count.*);
    paths[count.*] = .{
        .parent = parent,
        .block_id = block_id,
        .else_branch = else_branch,
    };
    count.* += 1;
    return result;
}

pub fn pathsOverlap(left_start: u32, right_start: u32, paths: []const PathNode) bool {
    var left = left_start;
    while (left != no_path) : (left = paths[left].parent) {
        var right = right_start;
        while (right != no_path) : (right = paths[right].parent) {
            if (paths[left].block_id == paths[right].block_id and
                paths[left].else_branch != paths[right].else_branch) return false;
        }
    }
    return true;
}
