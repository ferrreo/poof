const std = @import("std");
const domain = @import("../domain.zig");
const protocol = @import("protocol.zig");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    scope: domain.Scope,
    admin: bool = false,
    schema: []const u8,
};

pub const all = [_]Tool{
    .{
        .name = "poof_get_overview",
        .description = "Get product feedback counts and the single-company Poof overview.",
        .scope = .read,
        .schema = empty_schema,
    },
    .{
        .name = "poof_list_boards",
        .description = "List active feedback boards.",
        .scope = .read,
        .schema = empty_schema,
    },
    .{
        .name = "poof_list_issues",
        .description = "Search and filter feedback with bounded pagination.",
        .scope = .read,
        .schema =
        \\{"type":"object","properties":{"query":{"type":"string","maxLength":200},"status":{"type":"string","enum":["pending","reviewing","planned","in_progress","completed","closed"]},"kind":{"type":"string","enum":["feature","improvement","bug"]},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_get_issue",
        .description = "Get one issue including status, report fields, votes, and comments.",
        .scope = .read,
        .schema = id_schema,
    },
    .{
        .name = "poof_get_roadmap",
        .description = "List planned, in-progress, and completed roadmap feedback.",
        .scope = .read,
        .schema = empty_schema,
    },
    .{
        .name = "poof_list_changelogs",
        .description = "List published changelog entries.",
        .scope = .read,
        .schema = empty_schema,
    },
    .{
        .name = "poof_create_issue",
        .description = "Create a feature, improvement, or structured bug report.",
        .scope = .issues_write,
        .schema =
        \\{"type":"object","required":["idempotency_key","board_id","kind","title","body"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"board_id":{"type":"integer","minimum":1},"kind":{"type":"string","enum":["feature","improvement","bug"]},"title":{"type":"string","minLength":5,"maxLength":160},"body":{"type":"string","minLength":20,"maxLength":16384},"reproduction_steps":{"type":"string","maxLength":8192},"expected_behavior":{"type":"string","maxLength":8192},"actual_behavior":{"type":"string","maxLength":8192},"environment":{"type":"string","maxLength":8192},"evidence_url":{"type":"string","maxLength":512}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_set_vote",
        .description = "Add or remove the token owner's vote on an issue.",
        .scope = .issues_write,
        .schema =
        \\{"type":"object","required":["idempotency_key","issue_id","selected"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"issue_id":{"type":"integer","minimum":1},"selected":{"type":"boolean"}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_add_comment",
        .description = "Add a comment or one-level reply to an unlocked issue.",
        .scope = .comments_write,
        .schema =
        \\{"type":"object","required":["idempotency_key","issue_id","body"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"issue_id":{"type":"integer","minimum":1},"parent_id":{"type":"integer","minimum":1},"body":{"type":"string","minLength":1,"maxLength":4096}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_update_issue",
        .description = "Triage an issue. Requires an admin owner and admin issue scope.",
        .scope = .admin_issues,
        .admin = true,
        .schema =
        \\{"type":"object","required":["idempotency_key","issue_id","status","priority","board_id","pinned","locked"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"issue_id":{"type":"integer","minimum":1},"status":{"type":"string","enum":["pending","reviewing","planned","in_progress","completed","closed"]},"priority":{"type":"string","enum":["none","low","medium","high","urgent"]},"board_id":{"type":"integer","minimum":1},"pinned":{"type":"boolean"},"locked":{"type":"boolean"},"duplicate_of_id":{"type":"integer","minimum":1}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_create_board",
        .description = "Create a feedback board.",
        .scope = .admin_boards,
        .admin = true,
        .schema =
        \\{"type":"object","required":["idempotency_key","name","slug"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"name":{"type":"string","minLength":1,"maxLength":80},"slug":{"type":"string","minLength":1,"maxLength":80,"pattern":"^[a-z0-9]+(?:-[a-z0-9]+)*$"},"description":{"type":"string","maxLength":500},"color":{"type":"string","enum":["violet","blue","green","amber","rose","gray"]}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_create_changelog",
        .description = "Create a changelog draft. Publishing is a separate confirmed tool.",
        .scope = .admin_changelog,
        .admin = true,
        .schema =
        \\{"type":"object","required":["idempotency_key","title","slug","summary","body"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"title":{"type":"string","minLength":3,"maxLength":160},"slug":{"type":"string","minLength":1,"maxLength":180,"pattern":"^[a-z0-9]+(?:-[a-z0-9]+)*$"},"summary":{"type":"string","minLength":1,"maxLength":500},"body":{"type":"string","minLength":1,"maxLength":65536},"version":{"type":"string","maxLength":64},"issue_ids":{"type":"array","maxItems":100,"uniqueItems":true,"items":{"type":"integer","minimum":1}}},"additionalProperties":false}
        ,
    },
    .{
        .name = "poof_publish_changelog",
        .description = "Publish or revert a changelog. Requires explicit confirmation.",
        .scope = .admin_changelog,
        .admin = true,
        .schema =
        \\{"type":"object","required":["idempotency_key","changelog_id","published","confirm"],"properties":{"idempotency_key":{"type":"string","minLength":8,"maxLength":128},"changelog_id":{"type":"integer","minimum":1},"published":{"type":"boolean"},"confirm":{"const":true}},"additionalProperties":false}
        ,
    },
};

pub fn find(name: []const u8) ?*const Tool {
    for (&all) |*tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

pub fn allowed(tool: Tool, scopes: domain.ScopeSet, role: domain.Role) bool {
    if (!scopes.contains(tool.scope)) return false;
    return !tool.admin or role == .admin;
}

pub fn writeList(
    writer: *std.Io.Writer,
    scopes: domain.ScopeSet,
    role: domain.Role,
) std.Io.Writer.Error!void {
    try writer.writeAll("{\"tools\":[");
    var first = true;
    for (all) |tool| {
        if (!allowed(tool, scopes, role)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"name\":");
        try protocol.writeJsonString(writer, tool.name);
        try writer.writeAll(",\"description\":");
        try protocol.writeJsonString(writer, tool.description);
        try writer.writeAll(",\"inputSchema\":");
        try writer.writeAll(tool.schema);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

const empty_schema =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

const id_schema =
    \\{"type":"object","required":["issue_id"],"properties":{"issue_id":{"type":"integer","minimum":1}},"additionalProperties":false}
;

test "tool list excludes admin capabilities from member tokens" {
    var scopes = domain.ScopeSet{};
    scopes.insert(.read);
    scopes.insert(.admin_issues);
    var storage: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeList(&writer, scopes, .member);
    const output = storage[0..writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "poof_list_issues") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "poof_update_issue") == null);
}
