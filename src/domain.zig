const std = @import("std");

pub const title_bytes_max = 160;
pub const issue_body_bytes_max = 16 * 1024;
pub const comment_body_bytes_max = 4 * 1024;
pub const diagnostic_bytes_max = 8 * 1024;
pub const evidence_url_bytes_max = 512;
pub const page_size_max = 50;
pub const list_page_size: u8 = 20;
pub const group_preview_size: u8 = 8;

pub const Role = enum {
    member,
    admin,
};

pub const IssueKind = enum {
    feature,
    improvement,
    bug,

    pub fn label(self: IssueKind) []const u8 {
        return switch (self) {
            .feature => "Feature",
            .improvement => "Improvement",
            .bug => "Bug",
        };
    }
};

pub const IssueStatus = enum {
    pending,
    reviewing,
    planned,
    in_progress,
    completed,
    closed,

    pub fn label(self: IssueStatus) []const u8 {
        return switch (self) {
            .pending => "Pending",
            .reviewing => "Reviewing",
            .planned => "Planned",
            .in_progress => "In progress",
            .completed => "Completed",
            .closed => "Closed",
        };
    }

    pub fn appearsOnRoadmap(self: IssueStatus) bool {
        return switch (self) {
            .planned, .in_progress, .completed => true,
            .pending, .reviewing, .closed => false,
        };
    }

    pub fn groupOpenByDefault(self: IssueStatus) bool {
        return switch (self) {
            .pending, .reviewing, .planned, .in_progress => true,
            .completed, .closed => false,
        };
    }
};

pub const Priority = enum {
    none,
    low,
    medium,
    high,
    urgent,

    pub fn label(self: Priority) []const u8 {
        return switch (self) {
            .none => "None",
            .low => "Low",
            .medium => "Medium",
            .high => "High",
            .urgent => "Urgent",
        };
    }
};

pub const Scope = enum(u6) {
    read = 0,
    issues_write = 1,
    comments_write = 2,
    admin_issues = 3,
    admin_boards = 4,
    admin_changelog = 5,

    pub fn name(self: Scope) []const u8 {
        return switch (self) {
            .read => "poof:read",
            .issues_write => "issues:write",
            .comments_write => "comments:write",
            .admin_issues => "admin:issues",
            .admin_boards => "admin:boards",
            .admin_changelog => "admin:changelog",
        };
    }

    pub fn requiresAdmin(self: Scope) bool {
        return switch (self) {
            .admin_issues, .admin_boards, .admin_changelog => true,
            .read, .issues_write, .comments_write => false,
        };
    }
};

pub const ScopeSet = packed struct(u64) {
    bits: u64 = 0,

    pub fn insert(self: *ScopeSet, scope: Scope) void {
        self.bits |= @as(u64, 1) << @intFromEnum(scope);
    }

    pub fn contains(self: ScopeSet, scope: Scope) bool {
        return self.bits & (@as(u64, 1) << @intFromEnum(scope)) != 0;
    }

    pub fn hasAdmin(self: ScopeSet) bool {
        return self.bits & admin_scope_bits != 0;
    }

    pub fn allowedFor(self: ScopeSet, role: Role) bool {
        if (self.hasAdmin() and role != .admin) return false;
        return self.bits & ~valid_scope_bits == 0;
    }

    pub fn effectiveFor(self: ScopeSet, role: Role) ScopeSet {
        if (role == .admin) return self;
        return .{ .bits = self.bits & ~admin_scope_bits };
    }
};

const valid_scope_bits: u64 = blk: {
    var bits: u64 = 0;
    for (std.meta.tags(Scope)) |scope| bits |= @as(u64, 1) << @intFromEnum(scope);
    break :blk bits;
};

pub const admin_scope_bits: u64 = blk: {
    var bits: u64 = 0;
    for (std.meta.tags(Scope)) |scope| {
        if (scope.requiresAdmin()) bits |= @as(u64, 1) << @intFromEnum(scope);
    }
    break :blk bits;
};

pub const CreateIssue = struct {
    board_id: i64,
    kind: IssueKind,
    title: []const u8,
    body: []const u8,
    reproduction_steps: ?[]const u8 = null,
    expected_behavior: ?[]const u8 = null,
    actual_behavior: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    evidence_url: ?[]const u8 = null,
    project_id: ?i64 = null,
};

pub const ValidationError = error{
    InvalidBoard,
    InvalidProject,
    InvalidTitle,
    InvalidBody,
    MissingBugDetails,
    InvalidDiagnostic,
    InvalidEvidenceUrl,
    InvalidUtf8,
};

pub fn validateCreateIssue(input: CreateIssue) ValidationError!void {
    if (input.board_id <= 0) return error.InvalidBoard;
    if (input.project_id) |project_id| if (project_id <= 0) return error.InvalidProject;
    try validateText(input.title, 5, title_bytes_max, error.InvalidTitle);
    try validateText(input.body, 20, issue_body_bytes_max, error.InvalidBody);

    inline for (.{
        input.reproduction_steps,
        input.expected_behavior,
        input.actual_behavior,
        input.environment,
    }) |value| {
        if (value) |text| {
            if (text.len == 0 or text.len > diagnostic_bytes_max) {
                return error.InvalidDiagnostic;
            }
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        }
    }

    if (input.kind == .bug) {
        const steps = input.reproduction_steps orelse return error.MissingBugDetails;
        const actual = input.actual_behavior orelse return error.MissingBugDetails;
        if (std.mem.trim(u8, steps, whitespace).len < 10 or
            std.mem.trim(u8, actual, whitespace).len < 10)
        {
            return error.MissingBugDetails;
        }
    }

    if (input.evidence_url) |url| try validateEvidenceUrl(url);
}

pub fn validateComment(body: []const u8) ValidationError!void {
    try validateText(body, 1, comment_body_bytes_max, error.InvalidBody);
}

fn validateText(
    value: []const u8,
    minimum: usize,
    maximum: usize,
    comptime invalid: ValidationError,
) ValidationError!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    const trimmed = std.mem.trim(u8, value, whitespace);
    if (trimmed.len < minimum or value.len > maximum) return invalid;
    for (value) |byte| {
        if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') return invalid;
    }
}

pub fn canEditIssue(role: Role, editor_id: i64, author_id: i64) bool {
    return role == .admin or editor_id == author_id;
}

pub fn validateEvidenceUrl(value: []const u8) ValidationError!void {
    if (value.len == 0 or value.len > evidence_url_bytes_max) {
        return error.InvalidEvidenceUrl;
    }
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    if (std.mem.startsWith(u8, value, "/media/")) {
        const key = value["/media/".len..];
        if (key.len == 0) return error.InvalidEvidenceUrl;
        for (key) |byte| {
            const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-';
            if (!ok) return error.InvalidEvidenceUrl;
        }
        return;
    }
    const uri = std.Uri.parse(value) catch return error.InvalidEvidenceUrl;
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) {
        return error.InvalidEvidenceUrl;
    }
    if (uri.host == null or uri.user != null or uri.password != null) {
        return error.InvalidEvidenceUrl;
    }
}

pub fn validateGitUrl(value: []const u8) ValidationError!void {
    try validateEvidenceUrl(value);
    if (std.mem.startsWith(u8, value, "/media/")) return error.InvalidEvidenceUrl;
}

pub fn slugify(input: []const u8, output: []u8) error{NoSpaceLeft}![]const u8 {
    var used: usize = 0;
    var pending_dash = false;
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (pending_dash and used != 0) {
                if (used == output.len) return error.NoSpaceLeft;
                output[used] = '-';
                used += 1;
            }
            pending_dash = false;
            if (used == output.len) return error.NoSpaceLeft;
            output[used] = std.ascii.toLower(byte);
            used += 1;
        } else if (used != 0) {
            pending_dash = true;
        }
    }
    if (used == 0) {
        if (output.len < "issue".len) return error.NoSpaceLeft;
        @memcpy(output[0.."issue".len], "issue");
        used = "issue".len;
    }
    return output[0..used];
}

const whitespace = " \t\r\n";

test "roadmap statuses are explicit" {
    try std.testing.expect(IssueStatus.planned.appearsOnRoadmap());
    try std.testing.expect(IssueStatus.in_progress.appearsOnRoadmap());
    try std.testing.expect(IssueStatus.completed.appearsOnRoadmap());
    try std.testing.expect(!IssueStatus.pending.appearsOnRoadmap());
    try std.testing.expect(!IssueStatus.closed.appearsOnRoadmap());
    try std.testing.expect(IssueStatus.pending.groupOpenByDefault());
    try std.testing.expect(!IssueStatus.completed.groupOpenByDefault());
    try std.testing.expect(!IssueStatus.closed.groupOpenByDefault());
    try std.testing.expectEqualStrings("Urgent", Priority.urgent.label());
}

test "admin scopes cannot be granted to a member" {
    var member = ScopeSet{};
    member.insert(.read);
    member.insert(.issues_write);
    try std.testing.expect(member.allowedFor(.member));
    member.insert(.admin_issues);
    try std.testing.expect(!member.allowedFor(.member));
    try std.testing.expect(member.allowedFor(.admin));
    const effective = member.effectiveFor(.member);
    try std.testing.expect(effective.contains(.read));
    try std.testing.expect(effective.contains(.issues_write));
    try std.testing.expect(!effective.contains(.admin_issues));
    try std.testing.expect(!effective.hasAdmin());
    try std.testing.expectEqual(@as(u64, 56), admin_scope_bits);
}

test "bug reports require useful reproduction and actual behavior" {
    const base = CreateIssue{
        .board_id = 1,
        .kind = .bug,
        .title = "The save button does nothing",
        .body = "Saving a draft leaves the editor in a pending state.",
    };
    try std.testing.expectError(error.MissingBugDetails, validateCreateIssue(base));

    var complete = base;
    complete.reproduction_steps = "Open a draft and press the Save button.";
    complete.actual_behavior = "The spinner remains visible and nothing is saved.";
    complete.expected_behavior = "The draft should save.";
    complete.evidence_url = "https://example.com/reproduction";
    try validateCreateIssue(complete);
}

test "evidence URLs reject executable and credential-bearing locations" {
    var input = CreateIssue{
        .board_id = 1,
        .kind = .feature,
        .title = "Add an export button",
        .body = "A JSON export would make backups easier for self-hosters.",
        .evidence_url = "javascript:alert(1)",
    };
    try std.testing.expectError(error.InvalidEvidenceUrl, validateCreateIssue(input));
    input.evidence_url = "https://user:password@example.com/private";
    try std.testing.expectError(error.InvalidEvidenceUrl, validateCreateIssue(input));
    input.evidence_url = "/media/deadbeef.png";
    try validateCreateIssue(input);
}

test "git URLs reject media paths and executable schemes" {
    try std.testing.expectError(error.InvalidEvidenceUrl, validateGitUrl("/media/deadbeef.png"));
    try std.testing.expectError(error.InvalidEvidenceUrl, validateGitUrl("javascript:alert(1)"));
    try validateGitUrl("https://github.com/PikaOS-Linux/welcome");
}

test "authors and admins can edit issues" {
    try std.testing.expect(canEditIssue(.admin, 9, 3));
    try std.testing.expect(canEditIssue(.member, 3, 3));
    try std.testing.expect(!canEditIssue(.member, 9, 3));
}

test "slugify produces stable URL components" {
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "save-drafts-faster",
        try slugify("  Save drafts — faster! ", &output),
    );
    try std.testing.expectEqualStrings("issue", try slugify("✨", &output));
}

test "create issue rejects a non-positive project id" {
    var input = CreateIssue{
        .board_id = 1,
        .kind = .feature,
        .title = "Add an export button",
        .body = "A JSON export would make backups easier for self-hosters.",
        .project_id = 0,
    };
    try std.testing.expectError(error.InvalidProject, validateCreateIssue(input));
    input.project_id = 4;
    try validateCreateIssue(input);
}
