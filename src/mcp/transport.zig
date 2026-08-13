const std = @import("std");
const ploof = @import("ploof");
const app_state = @import("../app_state.zig");
const api_token = @import("../auth/api_token.zig");
const domain = @import("../domain.zig");
const models = @import("../store.zig");
const request_workspace = @import("../web/request.zig");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");

pub const Definition = ploof.Endpoint(.{
    .body = ploof.Json.dynamic(.{
        .encoded_wire_bytes_max = 256 * 1024,
        .decoded_bytes_max = 256 * 1024,
        .parse_memory_bytes_max = 1024 * 1024,
        .depth_max = 32,
    }),
});

pub fn handle(
    context: *app_state.Context,
    input: Definition.InputType,
) app_state.Context.ResponseType {
    var workspace = request_workspace.Workspace.init(context) catch
        return context.empty(.service_unavailable);
    const allocator = workspace.allocator();
    const principal = authenticate(context, allocator) catch |problem| return switch (problem) {
        error.RateLimited => rateLimited(context),
        error.Forbidden => forbidden(context),
        else => unauthorized(context),
    };
    const root = &input.body;
    const jsonrpc = protocol.string(root, "jsonrpc") orelse
        return rpcError(context, &workspace, null, -32600, "Invalid Request");
    if (!std.mem.eql(u8, jsonrpc, "2.0")) {
        return rpcError(context, &workspace, null, -32600, "Invalid Request");
    }
    const method = protocol.string(root, "method") orelse
        return rpcError(context, &workspace, protocol.field(root, "id"), -32600, "Invalid Request");
    const id = protocol.field(root, "id");
    if (!validMirroredHeader(context, "mcp-method", method)) {
        return rpcError(context, &workspace, id, -32020, "MCP header mismatch");
    }

    var writer = workspace.writer();
    if (std.mem.eql(u8, method, "initialize")) {
        const params = protocol.object(root, "params") orelse
            return rpcError(context, &workspace, id, -32602, "Invalid initialize params");
        const requested = protocol.string(params, "protocolVersion") orelse
            return rpcError(context, &workspace, id, -32602, "Missing protocol version");
        const selected = selectVersion(requested) orelse
            return rpcError(context, &workspace, id, -32602, "Unsupported protocol version");
        protocol.beginResult(&writer, id) catch return context.empty(.internal_server_error);
        writer.writeAll("{\"protocolVersion\":") catch
            return context.empty(.internal_server_error);
        protocol.writeJsonString(&writer, selected) catch
            return context.empty(.internal_server_error);
        writer.writeAll(
            ",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"poof\",\"version\":\"0.1.0\"}}}",
        ) catch return context.empty(.internal_server_error);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        context.state.database.?.recordAutomation(
            principal.token.id,
            principal.owner.id,
            method,
            null,
            "success",
            "",
        );
        return context.empty(.accepted);
    } else if (std.mem.eql(u8, method, "ping")) {
        protocol.beginResult(&writer, id) catch return context.empty(.internal_server_error);
        writer.writeAll("{}}") catch return context.empty(.internal_server_error);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        protocol.beginResult(&writer, id) catch return context.empty(.internal_server_error);
        tools.writeList(&writer, principal.token.scopes, principal.owner.role) catch
            return context.empty(.internal_server_error);
        writer.writeByte('}') catch return context.empty(.internal_server_error);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = protocol.object(root, "params") orelse
            return rpcError(context, &workspace, id, -32602, "Invalid tool params");
        const name = protocol.string(params, "name") orelse
            return rpcError(context, &workspace, id, -32602, "Missing tool name");
        if (!validMirroredHeader(context, "mcp-name", name)) {
            return rpcError(context, &workspace, id, -32020, "MCP header mismatch");
        }
        const descriptor = tools.find(name) orelse
            return rpcError(context, &workspace, id, -32601, "Unknown tool");
        if (!tools.allowed(descriptor.*, principal.token.scopes, principal.owner.role)) {
            context.state.database.?.recordAutomation(
                principal.token.id,
                principal.owner.id,
                method,
                name,
                "denied",
                "insufficient scope",
            );
            return rpcError(context, &workspace, id, -32003, "Insufficient scope");
        }
        const arguments = protocol.object(params, "arguments") orelse
            return rpcError(context, &workspace, id, -32602, "Missing tool arguments");
        const mutating = descriptor.scope != .read;
        const key = if (mutating)
            idempotencyKey(arguments) catch
                return rpcError(context, &workspace, id, -32602, "Missing idempotency key")
        else
            null;
        const request_digest = if (mutating) digestArguments(name, arguments) else null;
        if (key) |request_key| {
            const claim = context.state.database.?.claimIdempotency(
                allocator,
                principal.token.id,
                name,
                request_key,
                request_digest.?,
            ) catch |problem| return rpcError(
                context,
                &workspace,
                id,
                -32009,
                if (problem == error.Conflict)
                    "Idempotency key reused with different input"
                else
                    "Idempotency lookup failed",
            );
            switch (claim) {
                .acquired => {},
                .pending => return rpcError(
                    context,
                    &workspace,
                    id,
                    -32010,
                    "An operation with this idempotency key is still in progress",
                ),
                .replay => |prior_result| {
                    protocol.beginResult(&writer, id) catch
                        return context.empty(.internal_server_error);
                    writer.writeAll(prior_result) catch
                        return context.empty(.internal_server_error);
                    writer.writeByte('}') catch return context.empty(.internal_server_error);
                    context.state.database.?.recordAutomation(
                        principal.token.id,
                        principal.owner.id,
                        method,
                        name,
                        "success",
                        "idempotent replay",
                    );
                    var response = context.jsonBorrowed(.ok, workspace.rendered(&writer));
                    response.setHeaderStatic("cache-control", "no-store") catch {};
                    return response;
                },
            }
        }
        protocol.beginResult(&writer, id) catch return context.empty(.internal_server_error);
        const result_start = writer.end;
        callTool(
            &writer,
            context.state.database.?,
            allocator,
            principal,
            name,
            arguments,
        ) catch |problem| {
            if (key) |request_key| context.state.database.?.releaseIdempotency(
                principal.token.id,
                name,
                request_key,
                request_digest.?,
            );
            context.state.database.?.recordAutomation(
                principal.token.id,
                principal.owner.id,
                method,
                name,
                "error",
                @errorName(problem),
            );
            return rpcError(context, &workspace, id, -32000, toolMessage(problem));
        };
        const result_end = writer.end;
        if (key) |request_key| {
            context.state.database.?.saveIdempotency(
                principal.token.id,
                name,
                request_key,
                request_digest.?,
                workspace.output[result_start..result_end],
            ) catch return rpcError(
                context,
                &workspace,
                id,
                -32000,
                "Unable to save idempotent result",
            );
        }
        writer.writeByte('}') catch return context.empty(.internal_server_error);
        context.state.database.?.recordAutomation(
            principal.token.id,
            principal.owner.id,
            method,
            name,
            "success",
            "",
        );
    } else {
        return rpcError(context, &workspace, id, -32601, "Method not found");
    }

    context.state.database.?.recordAutomation(
        principal.token.id,
        principal.owner.id,
        method,
        null,
        "success",
        "",
    );
    var response = context.jsonBorrowed(.ok, workspace.rendered(&writer));
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn callTool(
    writer: *std.Io.Writer,
    database: anytype,
    allocator: std.mem.Allocator,
    principal: models.ApiPrincipal,
    name: []const u8,
    arguments: *const protocol.Value,
) !void {
    if (std.mem.eql(u8, name, "poof_get_overview")) {
        try requireFields(arguments, &.{});
        var items: [1]models.IssueSummary = undefined;
        const issues = try database.listIssues(allocator, .{ .limit = 1 }, &items);
        var boards_storage: [32]models.Board = undefined;
        const boards = try database.listBoards(allocator, &boards_storage, false);
        try protocol.writeToolText(writer, "Poof overview loaded.");
        try writer.print(
            ",\"structuredContent\":{{\"issues\":{d},\"boards\":{d}}}}}",
            .{ issues.total, boards.len },
        );
        return;
    }
    if (std.mem.eql(u8, name, "poof_list_boards")) {
        try requireFields(arguments, &.{});
        var storage: [32]models.Board = undefined;
        const boards = try database.listBoards(allocator, &storage, false);
        try protocol.writeToolText(writer, "Active boards loaded.");
        try writer.writeAll(",\"structuredContent\":{\"boards\":[");
        for (boards, 0..) |board, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"id\":{d},\"slug\":", .{board.id});
            try protocol.writeJsonString(writer, board.slug);
            try writer.writeAll(",\"name\":");
            try protocol.writeJsonString(writer, board.name);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_list_issues")) {
        try requireFields(arguments, &.{ "query", "status", "kind", "limit" });
        const status = if (protocol.string(arguments, "status")) |value|
            try parseStatus(value)
        else
            null;
        const kind = if (protocol.string(arguments, "kind")) |value|
            try parseKind(value)
        else
            null;
        const limit_value = protocol.integer(arguments, "limit") orelse 20;
        if (limit_value < 1 or limit_value > 50) return error.InvalidArguments;
        var storage: [50]models.IssueSummary = undefined;
        const result = try database.listIssues(allocator, .{
            .status = status,
            .kind = kind,
            .query = protocol.string(arguments, "query"),
            .limit = @intCast(limit_value),
        }, &storage);
        try protocol.writeToolText(writer, "Feedback loaded.");
        try writer.print(",\"structuredContent\":{{\"total\":{d},\"issues\":[", .{result.total});
        for (result.items, 0..) |issue, index| {
            if (index != 0) try writer.writeByte(',');
            try writeIssueSummary(writer, issue);
        }
        try writer.writeAll("]}}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_get_issue")) {
        try requireFields(arguments, &.{"issue_id"});
        const issue_id = try positiveId(arguments, "issue_id");
        const issue = try database.getIssue(allocator, issue_id);
        var comment_storage: [100]models.Comment = undefined;
        const comments = try database.listComments(allocator, issue_id, &comment_storage);
        try protocol.writeToolText(writer, "Issue loaded.");
        try writer.writeAll(",\"structuredContent\":{\"issue\":");
        try writeIssue(writer, issue);
        try writer.writeAll(",\"comments\":[");
        for (comments, 0..) |comment, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"id\":{d},\"author\":", .{comment.id});
            try protocol.writeJsonString(writer, comment.author_name);
            try writer.writeAll(",\"body\":");
            try protocol.writeJsonString(writer, comment.body_markdown);
            try writer.writeAll(",\"parent_id\":");
            if (comment.parent_id) |parent_id| {
                try writer.print("{d}", .{parent_id});
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("]}}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_get_roadmap")) {
        try requireFields(arguments, &.{});
        try protocol.writeToolText(writer, "Roadmap loaded.");
        try writer.writeAll(",\"structuredContent\":{");
        inline for (.{ domain.IssueStatus.planned, .in_progress, .completed }, 0..) |status, section| {
            if (section != 0) try writer.writeByte(',');
            try protocol.writeJsonString(writer, @tagName(status));
            try writer.writeAll(":[");
            var storage: [50]models.IssueSummary = undefined;
            const result = try database.listIssues(allocator, .{
                .status = status,
                .limit = 50,
            }, &storage);
            for (result.items, 0..) |issue, index| {
                if (index != 0) try writer.writeByte(',');
                try writeIssueSummary(writer, issue);
            }
            try writer.writeByte(']');
        }
        try writer.writeAll("}}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_list_changelogs")) {
        try requireFields(arguments, &.{});
        var storage: [100]models.Changelog = undefined;
        const entries = try database.listChangelogs(allocator, true, &storage);
        try protocol.writeToolText(writer, "Published changelogs loaded.");
        try writer.writeAll(",\"structuredContent\":{\"changelogs\":[");
        for (entries, 0..) |entry, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print("{{\"id\":{d},\"slug\":", .{entry.id});
            try protocol.writeJsonString(writer, entry.slug);
            try writer.writeAll(",\"title\":");
            try protocol.writeJsonString(writer, entry.title);
            try writer.writeAll(",\"summary\":");
            try protocol.writeJsonString(writer, entry.summary);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_create_issue")) {
        try requireFields(arguments, &.{
            "idempotency_key",    "board_id",          "kind",            "title",       "body",
            "reproduction_steps", "expected_behavior", "actual_behavior", "environment", "evidence_url",
        });
        _ = try idempotencyKey(arguments);
        const issue_id = try database.createIssue(principal.owner.id, .{
            .board_id = try positiveId(arguments, "board_id"),
            .kind = try parseKind(protocol.string(arguments, "kind") orelse
                return error.InvalidArguments),
            .title = protocol.string(arguments, "title") orelse
                return error.InvalidArguments,
            .body = protocol.string(arguments, "body") orelse
                return error.InvalidArguments,
            .reproduction_steps = protocol.string(arguments, "reproduction_steps"),
            .expected_behavior = protocol.string(arguments, "expected_behavior"),
            .actual_behavior = protocol.string(arguments, "actual_behavior"),
            .environment = protocol.string(arguments, "environment"),
            .evidence_url = protocol.string(arguments, "evidence_url"),
        });
        try protocol.writeToolText(writer, "Feedback created.");
        try writer.print(",\"structuredContent\":{{\"issue_id\":{d}}}}}", .{issue_id});
        return;
    }
    if (std.mem.eql(u8, name, "poof_set_vote")) {
        try requireFields(arguments, &.{ "idempotency_key", "issue_id", "selected" });
        _ = try idempotencyKey(arguments);
        const issue_id = try positiveId(arguments, "issue_id");
        const selected = protocol.boolean(arguments, "selected") orelse
            return error.InvalidArguments;
        try database.setVote(issue_id, principal.owner.id, selected);
        try protocol.writeToolText(writer, if (selected) "Vote added." else "Vote removed.");
        try writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_add_comment")) {
        try requireFields(arguments, &.{ "idempotency_key", "issue_id", "parent_id", "body" });
        _ = try idempotencyKey(arguments);
        const comment_id = try database.addComment(
            try positiveId(arguments, "issue_id"),
            principal.owner.id,
            protocol.integer(arguments, "parent_id"),
            protocol.string(arguments, "body") orelse return error.InvalidArguments,
        );
        try protocol.writeToolText(writer, "Comment created.");
        try writer.print(",\"structuredContent\":{{\"comment_id\":{d}}}}}", .{comment_id});
        return;
    }
    if (std.mem.eql(u8, name, "poof_update_issue")) {
        try requireFields(arguments, &.{
            "idempotency_key", "issue_id", "status",          "priority", "board_id",
            "pinned",          "locked",   "duplicate_of_id",
        });
        _ = try idempotencyKey(arguments);
        const issue_id = try positiveId(arguments, "issue_id");
        try database.adminUpdateIssue(issue_id, principal.owner.id, .{
            .status = try parseStatus(protocol.string(arguments, "status") orelse
                return error.InvalidArguments),
            .priority = try parsePriority(protocol.string(arguments, "priority") orelse
                return error.InvalidArguments),
            .board_id = try positiveId(arguments, "board_id"),
            .pinned = protocol.boolean(arguments, "pinned") orelse
                return error.InvalidArguments,
            .locked = protocol.boolean(arguments, "locked") orelse
                return error.InvalidArguments,
            .duplicate_of_id = protocol.integer(arguments, "duplicate_of_id"),
        });
        try protocol.writeToolText(writer, "Issue updated.");
        try writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_create_board")) {
        try requireFields(arguments, &.{
            "idempotency_key", "name", "slug", "description", "color",
        });
        _ = try idempotencyKey(arguments);
        const board_id = try database.createBoard(
            protocol.string(arguments, "name") orelse return error.InvalidArguments,
            protocol.string(arguments, "slug") orelse return error.InvalidArguments,
            protocol.string(arguments, "description") orelse "",
            protocol.string(arguments, "color") orelse "violet",
        );
        try protocol.writeToolText(writer, "Board created.");
        try writer.print(",\"structuredContent\":{{\"board_id\":{d}}}}}", .{board_id});
        return;
    }
    if (std.mem.eql(u8, name, "poof_archive_board")) {
        try requireFields(arguments, &.{ "idempotency_key", "board_id", "confirm" });
        _ = try idempotencyKey(arguments);
        if (protocol.boolean(arguments, "confirm") != true) {
            return error.ConfirmationRequired;
        }
        try database.archiveBoard(try positiveId(arguments, "board_id"));
        try protocol.writeToolText(writer, "Board archived.");
        try writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_update_board")) {
        try requireFields(arguments, &.{
            "idempotency_key", "board_id", "name",       "slug",
            "description",     "color",    "sort_order",
        });
        _ = try idempotencyKey(arguments);
        const sort_order = protocol.integer(arguments, "sort_order") orelse
            return error.InvalidArguments;
        if (sort_order < 0 or sort_order > 10_000) return error.InvalidArguments;
        try database.updateBoard(
            try positiveId(arguments, "board_id"),
            protocol.string(arguments, "name") orelse return error.InvalidArguments,
            protocol.string(arguments, "slug") orelse return error.InvalidArguments,
            protocol.string(arguments, "description") orelse "",
            protocol.string(arguments, "color") orelse "violet",
            @intCast(sort_order),
        );
        try protocol.writeToolText(writer, "Board updated.");
        try writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_create_changelog")) {
        try requireFields(arguments, &.{
            "idempotency_key", "title", "slug", "summary", "body", "version", "issue_ids",
        });
        _ = try idempotencyKey(arguments);
        var linked_storage: [100]i64 = undefined;
        const linked = try parseIdArray(arguments, "issue_ids", &linked_storage);
        const changelog_id = try database.createChangelogWithIssues(principal.owner.id, .{
            .title = protocol.string(arguments, "title") orelse return error.InvalidArguments,
            .slug = protocol.string(arguments, "slug") orelse return error.InvalidArguments,
            .summary = protocol.string(arguments, "summary") orelse
                return error.InvalidArguments,
            .body_markdown = protocol.string(arguments, "body") orelse
                return error.InvalidArguments,
            .version = protocol.string(arguments, "version"),
        }, linked);
        try protocol.writeToolText(writer, "Changelog draft created.");
        try writer.print(",\"structuredContent\":{{\"changelog_id\":{d}}}}}", .{changelog_id});
        return;
    }
    if (std.mem.eql(u8, name, "poof_publish_changelog")) {
        try requireFields(arguments, &.{
            "idempotency_key", "changelog_id", "published", "confirm",
        });
        _ = try idempotencyKey(arguments);
        if (protocol.boolean(arguments, "confirm") != true) return error.ConfirmationRequired;
        const published = protocol.boolean(arguments, "published") orelse
            return error.InvalidArguments;
        try database.publishChangelog(
            try positiveId(arguments, "changelog_id"),
            published,
        );
        try protocol.writeToolText(
            writer,
            if (published) "Changelog published." else "Changelog reverted to draft.",
        );
        try writer.writeAll("}");
        return;
    }
    if (std.mem.eql(u8, name, "poof_update_changelog")) {
        try requireFields(arguments, &.{
            "idempotency_key", "changelog_id", "title",     "slug", "summary",
            "body",            "version",      "issue_ids",
        });
        _ = try idempotencyKey(arguments);
        const changelog_id = try positiveId(arguments, "changelog_id");
        var linked_storage: [100]i64 = undefined;
        const linked = try parseIdArray(arguments, "issue_ids", &linked_storage);
        try database.updateChangelogWithIssues(changelog_id, .{
            .title = protocol.string(arguments, "title") orelse return error.InvalidArguments,
            .slug = protocol.string(arguments, "slug") orelse return error.InvalidArguments,
            .summary = protocol.string(arguments, "summary") orelse
                return error.InvalidArguments,
            .body_markdown = protocol.string(arguments, "body") orelse
                return error.InvalidArguments,
            .version = protocol.string(arguments, "version"),
        }, linked);
        try protocol.writeToolText(writer, "Changelog updated.");
        try writer.writeAll("}");
        return;
    }
    return error.UnknownTool;
}

fn authenticate(
    context: *app_state.Context,
    allocator: std.mem.Allocator,
) models.Error!models.ApiPrincipal {
    const settings = app_state.config(context) orelse return error.Forbidden;
    const database = app_state.database(context) orelse return error.DatabaseUnavailable;
    if (context.request.raw_query != null or
        context.request.headers.all("cookie").count() != 0)
    {
        return error.Forbidden;
    }
    const origin_values = context.request.headers.all("origin");
    if (origin_values.count() != 0) {
        const origin = origin_values.one() catch return error.Forbidden;
        if (!std.mem.eql(u8, origin, settings.public_url)) return error.Forbidden;
    }
    const authorization_values = context.request.headers.all("authorization");
    if (authorization_values.count() == 0) return error.NotFound;
    const authorization = authorization_values.one() catch return error.Forbidden;
    if (!std.mem.startsWith(u8, authorization, "Bearer ")) return error.NotFound;
    const encoded = authorization["Bearer ".len..];
    const parsed = api_token.parse(encoded, settings.api_token_pepper) catch
        return error.NotFound;
    const principal = try database.apiPrincipal(
        allocator,
        &parsed.lookup,
        parsed.digest,
    );
    if (!try database.apiRateAllowed(principal.token.id, 240)) {
        database.recordAutomation(
            principal.token.id,
            principal.owner.id,
            "rate-limit",
            null,
            "rate_limited",
            "",
        );
        return error.RateLimited;
    }
    return principal;
}

fn unauthorized(context: *app_state.Context) app_state.Context.ResponseType {
    var response = context.jsonStatic(
        .unauthorized,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,\"message\":\"Unauthorized\"}}",
    );
    response.setHeaderStatic(
        "www-authenticate",
        "Bearer realm=\"poof-mcp\"",
    ) catch {};
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn forbidden(context: *app_state.Context) app_state.Context.ResponseType {
    var response = context.jsonStatic(
        .forbidden,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32003,\"message\":\"Forbidden\"}}",
    );
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn rateLimited(context: *app_state.Context) app_state.Context.ResponseType {
    var response = context.jsonStatic(
        .too_many_requests,
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32029,\"message\":\"Rate limit exceeded\"}}",
    );
    response.setHeaderStatic("retry-after", "60") catch {};
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn rpcError(
    context: *app_state.Context,
    workspace: *request_workspace.Workspace,
    id: ?*const protocol.Value,
    code: i32,
    message: []const u8,
) app_state.Context.ResponseType {
    var writer = workspace.writer();
    protocol.writeError(&writer, id, code, message) catch
        return context.empty(.internal_server_error);
    var response = context.jsonBorrowed(.ok, workspace.rendered(&writer));
    response.setHeaderStatic("cache-control", "no-store") catch {};
    return response;
}

fn selectVersion(requested: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, requested, "2025-06-18")) return "2025-06-18";
    return null;
}

fn validMirroredHeader(
    context: *app_state.Context,
    name: []const u8,
    expected: []const u8,
) bool {
    const values = context.request.headers.all(name);
    if (values.count() == 0) return true;
    const value = values.one() catch return false;
    return std.mem.eql(u8, value, expected);
}

fn requireFields(arguments: *const protocol.Value, allowed: []const []const u8) !void {
    const members = switch (arguments.*) {
        .object => |value| value,
        else => return error.InvalidArguments,
    };
    for (members) |member| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, member.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidArguments;
    }
}

fn positiveId(arguments: *const protocol.Value, name: []const u8) !i64 {
    const value = protocol.integer(arguments, name) orelse return error.InvalidArguments;
    return if (value > 0) value else error.InvalidArguments;
}

fn idempotencyKey(arguments: *const protocol.Value) ![]const u8 {
    const value = protocol.string(arguments, "idempotency_key") orelse
        return error.InvalidArguments;
    if (value.len < 8 or value.len > 128) return error.InvalidArguments;
    return value;
}

fn parseKind(value: []const u8) !domain.IssueKind {
    return models.parseKind(value) catch error.InvalidArguments;
}

fn parseStatus(value: []const u8) !domain.IssueStatus {
    return models.parseStatus(value) catch error.InvalidArguments;
}

fn parsePriority(value: []const u8) !domain.Priority {
    return models.parsePriority(value) catch error.InvalidArguments;
}

fn parseIdArray(
    arguments: *const protocol.Value,
    name: []const u8,
    output: *[100]i64,
) ![]const i64 {
    const value = protocol.field(arguments, name) orelse return &.{};
    const items = switch (value.*) {
        .array => |array| array,
        else => return error.InvalidArguments,
    };
    if (items.len > output.len) return error.InvalidArguments;
    for (items, 0..) |*item, index| {
        const id = switch (item.*) {
            .number => |number| number.asInt(i64) catch return error.InvalidArguments,
            else => return error.InvalidArguments,
        };
        if (id <= 0) return error.InvalidArguments;
        for (output[0..index]) |existing| if (existing == id) return error.InvalidArguments;
        output[index] = id;
    }
    return output[0..items.len];
}

fn writeIssueSummary(writer: *std.Io.Writer, issue: models.IssueSummary) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{issue.id});
    try protocol.writeJsonString(writer, issue.title);
    try writer.writeAll(",\"status\":");
    try protocol.writeJsonString(writer, @tagName(issue.status));
    try writer.writeAll(",\"kind\":");
    try protocol.writeJsonString(writer, @tagName(issue.kind));
    try writer.print(
        ",\"votes\":{d},\"comments\":{d}}}",
        .{ issue.vote_count, issue.comment_count },
    );
}

fn writeIssue(writer: *std.Io.Writer, issue: models.Issue) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{issue.id});
    try protocol.writeJsonString(writer, issue.title);
    try writer.writeAll(",\"body\":");
    try protocol.writeJsonString(writer, issue.body_markdown);
    try writer.writeAll(",\"status\":");
    try protocol.writeJsonString(writer, @tagName(issue.status));
    try writer.writeAll(",\"priority\":");
    try protocol.writeJsonString(writer, @tagName(issue.priority));
    try writer.writeAll(",\"author\":");
    try protocol.writeJsonString(writer, issue.author_name);
    try writer.writeAll(",\"board\":");
    try protocol.writeJsonString(writer, issue.board_name);
    try writer.print(
        ",\"board_id\":{d},\"votes\":{d},\"comments\":{d},\"locked\":{s}",
        .{
            issue.board_id,
            issue.vote_count,
            issue.comment_count,
            if (issue.locked) "true" else "false",
        },
    );
    try writeOptionalStringField(writer, "reproduction_steps", issue.reproduction_steps);
    try writeOptionalStringField(writer, "expected_behavior", issue.expected_behavior);
    try writeOptionalStringField(writer, "actual_behavior", issue.actual_behavior);
    try writeOptionalStringField(writer, "environment", issue.environment);
    try writeOptionalStringField(writer, "evidence_url", issue.evidence_url);
    try writer.writeAll(",\"duplicate_of_id\":");
    if (issue.duplicate_of_id) |target| {
        try writer.print("{d}", .{target});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeOptionalStringField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
) !void {
    try writer.writeAll(",");
    try protocol.writeJsonString(writer, name);
    try writer.writeAll(":");
    if (value) |text| {
        try protocol.writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn toolMessage(problem: anyerror) []const u8 {
    return switch (problem) {
        error.InvalidArguments => "Invalid tool arguments",
        error.ConfirmationRequired => "Explicit confirmation is required",
        error.NotFound => "Resource not found",
        error.Conflict => "The operation conflicts with current state",
        error.Locked => "The issue is locked",
        error.CapacityExceeded => "The result exceeds a bounded limit",
        else => "Tool execution failed",
    };
}

fn digestArguments(tool_name: []const u8, arguments: *const protocol.Value) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashBytes(&hasher, tool_name);
    hashValue(&hasher, arguments);
    var output: [32]u8 = undefined;
    hasher.final(&output);
    return output;
}

fn hashValue(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: *const protocol.Value,
) void {
    switch (value.*) {
        .null => hasher.update(&.{0}),
        .boolean => |selected| hasher.update(&.{ 1, @intFromBool(selected) }),
        .number => |number| {
            hasher.update(&.{2});
            hashBytes(hasher, number.bytes());
        },
        .string => |text| {
            hasher.update(&.{3});
            hashBytes(hasher, text);
        },
        .array => |items| {
            hasher.update(&.{4});
            hashLength(hasher, items.len);
            for (items) |*item| hashValue(hasher, item);
        },
        .object => |members| {
            hasher.update(&.{5});
            hashLength(hasher, members.len);
            for (members) |*member| {
                hashBytes(hasher, member.name);
                hashValue(hasher, &member.value);
            }
        },
    }
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    hashLength(hasher, bytes.len);
    hasher.update(bytes);
}

fn hashLength(hasher: *std.crypto.hash.sha2.Sha256, length: usize) void {
    const value: u64 = @intCast(length);
    hasher.update(std.mem.asBytes(&value));
}
