const domain = @import("domain.zig");

pub const User = struct {
    id: i64,
    discord_id: []const u8,
    username: []const u8,
    display_name: ?[]const u8,
    avatar_hash: ?[]const u8,
    role: domain.Role,
    disabled: bool,
    created_at_us: i64,
    last_login_at_us: i64,
};

pub const DiscordProfile = struct {
    discord_id: []const u8,
    username: []const u8,
    display_name: ?[]const u8,
    avatar_hash: ?[]const u8,
    role: domain.Role,
};

pub const OAuthState = struct {
    return_to: []const u8,
};

pub const SessionPrincipal = struct {
    user: User,
    session_id: [16]u8,
};

pub const Board = struct {
    id: i64,
    slug: []const u8,
    name: []const u8,
    description: []const u8,
    color: []const u8,
    sort_order: i32,
    archived: bool,
};

pub const Issue = struct {
    id: i64,
    slug: []const u8,
    board_id: i64,
    board_name: []const u8,
    author_id: i64,
    author_name: []const u8,
    kind: domain.IssueKind,
    status: domain.IssueStatus,
    priority: domain.Priority,
    title: []const u8,
    body_markdown: []const u8,
    reproduction_steps: ?[]const u8,
    expected_behavior: ?[]const u8,
    actual_behavior: ?[]const u8,
    environment: ?[]const u8,
    evidence_url: ?[]const u8,
    duplicate_of_id: ?i64,
    pinned: bool,
    locked: bool,
    vote_count: i64,
    comment_count: i64,
    created_at_us: i64,
    updated_at_us: i64,
};

pub const IssueSummary = struct {
    id: i64,
    slug: []const u8,
    board_name: []const u8,
    board_id: i64,
    author_name: []const u8,
    kind: domain.IssueKind,
    status: domain.IssueStatus,
    priority: domain.Priority,
    title: []const u8,
    pinned: bool,
    locked: bool,
    vote_count: i64,
    comment_count: i64,
    created_at_us: i64,
};

pub const IssueSort = enum {
    top,
    newest,
};

pub const IssueFilter = struct {
    board_id: ?i64 = null,
    kind: ?domain.IssueKind = null,
    status: ?domain.IssueStatus = null,
    query: ?[]const u8 = null,
    sort: IssueSort = .top,
    limit: u8 = 20,
    offset: u32 = 0,
};

pub const ListResult = struct {
    items: []IssueSummary,
    total: i64,
};

pub const Comment = struct {
    id: i64,
    issue_id: i64,
    author_id: i64,
    author_name: []const u8,
    parent_id: ?i64,
    body_markdown: []const u8,
    created_at_us: i64,
};

pub const Changelog = struct {
    id: i64,
    slug: []const u8,
    author_name: []const u8,
    title: []const u8,
    summary: []const u8,
    body_markdown: []const u8,
    version: ?[]const u8,
    published_at_us: ?i64,
};

pub const ChangelogInput = struct {
    title: []const u8,
    slug: []const u8,
    summary: []const u8,
    body_markdown: []const u8,
    version: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

pub const AdminIssueUpdate = struct {
    status: domain.IssueStatus,
    priority: domain.Priority,
    board_id: i64,
    pinned: bool,
    locked: bool,
    duplicate_of_id: ?i64 = null,
};

pub const Error = error{
    DatabaseUnavailable,
    InvalidDatabaseData,
    NotFound,
    Conflict,
    Locked,
    Forbidden,
    CapacityExceeded,
    MigrationMismatch,
    UnknownMigration,
};

pub fn parseRole(value: []const u8) Error!domain.Role {
    if (@import("std").mem.eql(u8, value, "member")) return .member;
    if (@import("std").mem.eql(u8, value, "admin")) return .admin;
    return error.InvalidDatabaseData;
}

pub fn parseKind(value: []const u8) Error!domain.IssueKind {
    if (@import("std").mem.eql(u8, value, "feature")) return .feature;
    if (@import("std").mem.eql(u8, value, "improvement")) return .improvement;
    if (@import("std").mem.eql(u8, value, "bug")) return .bug;
    return error.InvalidDatabaseData;
}

pub fn parseStatus(value: []const u8) Error!domain.IssueStatus {
    if (@import("std").mem.eql(u8, value, "pending")) return .pending;
    if (@import("std").mem.eql(u8, value, "reviewing")) return .reviewing;
    if (@import("std").mem.eql(u8, value, "planned")) return .planned;
    if (@import("std").mem.eql(u8, value, "in_progress")) return .in_progress;
    if (@import("std").mem.eql(u8, value, "completed")) return .completed;
    if (@import("std").mem.eql(u8, value, "closed")) return .closed;
    return error.InvalidDatabaseData;
}

pub fn parsePriority(value: []const u8) Error!domain.Priority {
    if (@import("std").mem.eql(u8, value, "none")) return .none;
    if (@import("std").mem.eql(u8, value, "low")) return .low;
    if (@import("std").mem.eql(u8, value, "medium")) return .medium;
    if (@import("std").mem.eql(u8, value, "high")) return .high;
    if (@import("std").mem.eql(u8, value, "urgent")) return .urgent;
    return error.InvalidDatabaseData;
}

test "database enums reject unknown values" {
    const std = @import("std");
    try std.testing.expectEqual(domain.Role.admin, try parseRole("admin"));
    try std.testing.expectEqual(domain.IssueStatus.in_progress, try parseStatus("in_progress"));
    try std.testing.expectError(error.InvalidDatabaseData, parseKind("question"));
}
