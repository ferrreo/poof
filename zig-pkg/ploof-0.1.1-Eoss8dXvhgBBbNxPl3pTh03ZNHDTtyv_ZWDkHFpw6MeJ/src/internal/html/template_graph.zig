const std = @import("std");
const diagnostic = @import("template_diagnostic.zig");
const types = @import("template_types.zig");

pub const nodes_hard_max: usize = 4096;
pub const edges_hard_max: usize = 16_384;

pub fn validateHardLimits(comptime Root: type, comptime Resolver: type) void {
    if (nodeCount(Root, Resolver) > nodes_hard_max) {
        diagnostic.fail(
            .graph_node_limit,
            Root.SourceType,
            0,
            "template graph exceeds 4096 nodes",
        );
    }
    if (edgeCount(Root, Resolver) > edges_hard_max) {
        diagnostic.fail(
            .graph_edge_limit,
            Root.SourceType,
            0,
            "template graph exceeds 16384 edges",
        );
    }
}

pub fn validateSourceLimit(comptime Current: type, comptime Resolver: type) void {
    const total = sourceBytes(Current, Resolver);
    if (total <= Current.profile_value.graph_source_bytes_max) return;
    diagnostic.fail(
        .graph_source_limit,
        Current.SourceType,
        0,
        std.fmt.comptimePrint(
            "graph source uses {d} bytes; configured limit is {d}",
            .{ total, Current.profile_value.graph_source_bytes_max },
        ),
    );
}

pub fn browserJsonScratchBytes(comptime Root: type, comptime Resolver: type) usize {
    var maximum: usize = 0;
    inline for (Root.SourceType.directives) |directive| {
        if (directive.kind == .json_data) {
            maximum = Root.browser_json_value.encoded_bytes_max;
            break;
        }
    }
    inline for (partialFields(Root)) |field| {
        maximum = @max(
            maximum,
            browserJsonScratchBytes(child(Root, Resolver, field.name), Resolver),
        );
    }
    return maximum;
}

pub fn validateAncestry(comptime Source: type, comptime ancestors: anytype) void {
    inline for (ancestors, 0..) |Ancestor, ancestor_index| {
        const distance = ancestors.len - ancestor_index;
        if (distance > Ancestor.profile_value.partial_call_depth_max) {
            diagnostic.fail(
                .partial_depth,
                Source,
                0,
                "partial call depth exceeds an ancestor's configured limit",
            );
        }
        if (std.mem.eql(u8, Source.graph_name, Ancestor.SourceType.graph_name) and
            std.mem.eql(u8, Source.file_path, Ancestor.SourceType.file_path))
        {
            diagnostic.fail(.partial_cycle, Source, 0, "partial graph contains a cycle");
        }
    }
}

pub fn makeControlLinks(comptime Source: type) [Source.directives.len]types.ControlLink {
    var links = [_]types.ControlLink{.{}} ** Source.directives.len;
    for (Source.directives, 0..) |directive, index| {
        if (!control(directive.kind)) continue;
        var depth: usize = 0;
        for (Source.directives[index + 1 ..], index + 1..) |candidate, candidate_index| {
            if (control(candidate.kind)) {
                depth += 1;
            } else if (candidate.kind == .block_close) {
                if (depth == 0) {
                    links[index].close_index = candidate_index;
                    break;
                }
                depth -= 1;
            } else if (candidate.kind == .else_branch and depth == 0) {
                links[index].else_index = candidate_index;
            }
        }
    }
    return links;
}

fn nodeCount(comptime Current: type, comptime Resolver: type) usize {
    const fields = partialFields(Current);
    if (fields.len >= nodes_hard_max) return nodes_hard_max + 1;
    var total: usize = 1;
    inline for (fields) |field| {
        total += nodeCount(child(Current, Resolver, field.name), Resolver);
        if (total > nodes_hard_max) return total;
    }
    return total;
}

fn edgeCount(comptime Current: type, comptime Resolver: type) usize {
    var total: usize = 0;
    inline for (Current.SourceType.directives) |directive| {
        if (directive.kind != .partial) continue;
        total += 1;
        if (total > edges_hard_max) return total;
        const Child = Resolver.child(
            Current,
            directive.name.bytes(Current.SourceType.source),
            Current.SourceType,
            directive.name.start,
        );
        total += edgeCount(Child, Resolver);
        if (total > edges_hard_max) return total;
    }
    return total;
}

fn sourceBytes(comptime Current: type, comptime Resolver: type) usize {
    var total = Current.SourceType.source.len;
    inline for (partialFields(Current)) |field| {
        total += sourceBytes(child(Current, Resolver, field.name), Resolver);
    }
    return total;
}

fn partialFields(comptime Current: type) []const std.builtin.Type.StructField {
    return @typeInfo(@TypeOf(Current.partials_value)).@"struct".fields;
}

fn child(comptime Parent: type, comptime Resolver: type, comptime name: []const u8) type {
    return Resolver.child(Parent, name, Parent.SourceType, 0);
}

fn control(kind: anytype) bool {
    return kind == .if_open or kind == .with_open or kind == .each_open;
}
