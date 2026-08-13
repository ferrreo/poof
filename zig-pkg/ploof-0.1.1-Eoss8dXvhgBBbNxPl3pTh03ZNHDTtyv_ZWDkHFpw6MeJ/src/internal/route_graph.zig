const std = @import("std");
const route = @import("../route.zig");
const route_graph_index = @import("route_graph/index.zig");
const route_graph_method = @import("route_graph/method.zig");
const route_graph_materialize = @import("route_graph/materialize.zig");
const route_graph_search = @import("route_graph/search.zig");

pub const Method = route.Method;
pub const GraphLimits = route.GraphLimits;
pub const RoutePlanMaterializeError = route_graph_materialize.Error;

pub const PatternIssue = enum(u8) {
    not_absolute,
    bytes_limit,
    segments_limit,
    captures_limit,
    empty_capture_name,
    invalid_capture_name,
    nonterminal_catch_all,
    duplicate_capture_name,

    pub fn diagnostic(issue: PatternIssue) []const u8 {
        return switch (issue) {
            .not_absolute => "PLOOF-E3021 route pattern must begin with '/'",
            .bytes_limit => "PLOOF-E3022 route pattern exceeds configured byte limit",
            .segments_limit => "PLOOF-E3023 route pattern exceeds configured segment limit",
            .captures_limit => "PLOOF-E3024 route pattern exceeds configured capture limit",
            .empty_capture_name => "PLOOF-E3025 route capture name must not be empty",
            .invalid_capture_name => "PLOOF-E3026 route capture name is invalid",
            .nonterminal_catch_all => "PLOOF-E3027 route catch-all must be terminal",
            .duplicate_capture_name => "PLOOF-E3028 route capture names must be unique",
        };
    }
};

pub const CaptureKind = enum(u8) {
    parameter,
    catch_all,
};

pub const Capture = struct {
    name: []const u8,
    start: u32,
    end: u32,
    kind: CaptureKind,

    pub fn value(capture: Capture, path: []const u8) []const u8 {
        std.debug.assert(capture.start <= capture.end);
        std.debug.assert(capture.end <= path.len);
        return path[capture.start..capture.end];
    }
};

pub const RouteMetadata = struct {
    method: Method,
    pattern: []const u8,
    route_id: u16,
    segment_count: u16,
    capture_count: u16,
};

pub const RedirectStatus = enum(u16) {
    moved_permanently = 301,
    temporary_redirect = 307,
};

pub const SlashChange = enum(u8) {
    add,
    remove,
};

pub const Redirect = struct {
    /// Matched route for method redirects; generated OPTIONS redirects have none.
    route_id: ?u16,
    status: RedirectStatus,
    slash_change: SlashChange,
};

pub const Allow = @import("route_graph/allow.zig").Allow;

pub const SelectInput = struct {
    method: []const u8,
    path: []const u8,
    terminal_slash_is_literal: bool = true,
};

pub const RouteMatch = struct {
    route_id: u16,
    declared_method: Method,
    head_uses_get: bool,
    captures: []const Capture,

    pub fn param(match: RouteMatch, path: []const u8, name: []const u8) ?[]const u8 {
        for (match.captures) |capture| {
            if (std.mem.eql(u8, capture.name, name)) return capture.value(path);
        }
        return null;
    }
};

pub const Selection = union(enum) {
    selected: RouteMatch,
    redirect: Redirect,
    options: Allow,
    method_not_allowed: Allow,
    not_implemented,
    not_found,
};

const RoutePlanMatch = struct {
    route_index: u16,
    route_id: u16,
    declared_method: Method,
    head_uses_get: bool,
    capture_count: u16,
};

const RoutePlanSelection = union(enum) {
    selected: RoutePlanMatch,
    redirect: Redirect,
    options: Allow,
    method_not_allowed: Allow,
    not_implemented,
    not_found,
};

const SegmentKind = enum(u8) {
    literal,
    parameter,
    catch_all,
};

const PatternStats = struct {
    segments: u16,
    captures: u16,
};

const Found = struct {
    index: u16,
    head_uses_get: bool,
};

const PathView = route_graph_search.PathView;

const Search = struct {
    found: ?Found = null,
    allow: Allow = .{},
};

const Alternate = struct {
    view: PathView,
    change: SlashChange,
};

pub fn Graph(comptime definitions: anytype, comptime requested_limits: GraphLimits) type {
    @setEvalBranchQuota(100_000);
    @setEvalBranchQuota(graphEvaluationQuota(definitions));
    const limits = requested_limits.validate();
    const route_count = definitions.len;
    if (route_count == 0) {
        @compileError("PLOOF-E3029 route graph must contain at least one route");
    }
    if (route_count > limits.routes_max) {
        @compileError("PLOOF-E3020 route graph exceeds configured route limit");
    }
    const pattern_bytes_total = comptime routePatternBytesTotal(definitions);
    if (pattern_bytes_total > limits.route_pattern_bytes_total_max) {
        compileComputedLimit(
            "PLOOF-E3121 route graph pattern bytes exceed configured aggregate limit",
            pattern_bytes_total,
            limits.route_pattern_bytes_total_max,
        );
    }
    const segments_total = comptime routeSegmentsTotal(definitions);
    if (segments_total > limits.route_segments_total_max) {
        compileComputedLimit(
            "PLOOF-E3120 route graph segments exceed configured aggregate limit",
            segments_total,
            limits.route_segments_total_max,
        );
    }
    const built_routes = comptime buildRoutes(definitions, limits);
    const BuiltIndex = route_graph_index.Index(built_routes, limits.index_nodes_max);
    if (BuiltIndex.search_visits_bound > limits.search_visits_max) {
        compileComputedLimit(
            "PLOOF-E3123 route graph search visits exceed configured limit",
            BuiltIndex.search_visits_bound,
            limits.search_visits_max,
        );
    }
    if (BuiltIndex.search_compare_bytes_bound > limits.search_compare_bytes_max) {
        compileComputedLimit(
            "PLOOF-E3124 route graph search compared bytes exceed configured limit",
            BuiltIndex.search_compare_bytes_bound,
            limits.search_compare_bytes_max,
        );
    }
    const capture_slots = comptime maximumCaptures(built_routes);

    return struct {
        pub const routes = built_routes;
        pub const limits_profile = limits;
        pub const maximum_captures = capture_slots;
        pub const CaptureBuffer = [capture_slots]Capture;
        pub const SearchWorkspace = route_graph_search.Workspace(BuiltIndex);
        pub const PlannedMatch = RoutePlanMatch;
        pub const PlannedSelection = RoutePlanSelection;
        pub const MaterializeError = RoutePlanMaterializeError;
        pub const index_node_count = BuiltIndex.nodes.len;
        pub const index_literal_count = BuiltIndex.literals.len;
        pub const index_static_bytes = BuiltIndex.static_bytes;
        pub const search_visits_bound = BuiltIndex.search_visits_bound;
        pub const search_compare_bytes_bound = BuiltIndex.search_compare_bytes_bound;
        pub const select_searches_bound: u8 = 3;
        pub const select_visits_bound =
            @as(u32, select_searches_bound) * search_visits_bound;
        pub const select_compare_bytes_bound =
            @as(u64, select_searches_bound) * search_compare_bytes_bound;
        pub const search_workspace_bytes = @sizeOf(SearchWorkspace);

        pub fn plan(
            input: SelectInput,
            workspace: *SearchWorkspace,
        ) PlannedSelection {
            return planRoutes(routes, BuiltIndex, input, workspace);
        }

        pub fn materialize(
            planned: PlannedSelection,
            path: []const u8,
            capture_output: *CaptureBuffer,
        ) MaterializeError!Selection {
            return route_graph_materialize.materialize(
                routes,
                Selection,
                planned,
                path,
                capture_output,
            );
        }

        pub fn select(
            input: SelectInput,
            workspace: *SearchWorkspace,
            capture_output: *CaptureBuffer,
        ) Selection {
            return materialize(plan(input, workspace), input.path, capture_output) catch {
                @panic("route plan did not match its selected path");
            };
        }

        pub fn serverAllow() Allow {
            return serverAllowRoutes(routes);
        }
    };
}

fn planRoutes(
    comptime routes: anytype,
    comptime Index: type,
    input: SelectInput,
    workspace: *route_graph_search.Workspace(Index),
) RoutePlanSelection {
    const parsed = route_graph_method.parse(input.method) orelse return .not_implemented;
    if (parsed == .options and std.mem.eql(u8, input.path, "*")) {
        return .{ .options = serverAllowRoutes(routes) };
    }
    const view = PathView{ .bytes = input.path };
    if (parsed.declared()) |method| {
        const exact = findRequested(Index, method, view, workspace);
        if (exact.found) |found| {
            return plannedRoute(routes, found);
        }
        if (alternate(input)) |other| {
            if (findRequested(Index, method, other.view, workspace).found) |found| {
                return redirectFor(method, other.change, routes[found.index].route_id);
            }
        }
        if (!exact.allow.isEmpty()) return .{ .method_not_allowed = exact.allow };
        return .not_found;
    }
    const allow = searchPath(Index, null, view, workspace).allow;
    if (!allow.isEmpty()) return .{ .options = allow };
    if (alternate(input)) |other| {
        if (!searchPath(Index, null, other.view, workspace).allow.isEmpty()) {
            return redirectForOptions(other.change);
        }
    }
    return .not_found;
}

fn plannedRoute(
    comptime routes: anytype,
    found: Found,
) RoutePlanSelection {
    const metadata = routes[found.index];
    return .{ .selected = .{
        .route_index = found.index,
        .route_id = metadata.route_id,
        .declared_method = metadata.method,
        .head_uses_get = found.head_uses_get,
        .capture_count = metadata.capture_count,
    } };
}

fn findRequested(
    comptime Index: type,
    method: Method,
    path: PathView,
    workspace: *route_graph_search.Workspace(Index),
) Search {
    var direct = searchPath(Index, method, path, workspace);
    if (direct.found) |*found| {
        found.head_uses_get = false;
        return direct;
    }
    if (method != .head or !direct.allow.contains(.get)) return direct;
    const fallback = searchPath(Index, .get, path, workspace);
    std.debug.assert(fallback.found != null);
    direct.found = fallback.found;
    direct.found.?.head_uses_get = true;
    return direct;
}

fn searchPath(
    comptime Index: type,
    target: ?Method,
    path: PathView,
    workspace: *route_graph_search.Workspace(Index),
) Search {
    const result = route_graph_search.search(Index, target, path, workspace);
    return .{
        .found = if (result.found) |index| .{
            .index = index,
            .head_uses_get = false,
        } else null,
        .allow = .{ .mask = result.allow_mask },
    };
}

fn serverAllowRoutes(comptime routes: anytype) Allow {
    var allow = Allow{};
    for (routes) |metadata| addMethod(&allow, metadata.method);
    if (!allow.isEmpty()) allow.mask |= Allow.options_bit;
    return allow;
}

fn graphEvaluationQuota(comptime definitions: anytype) u32 {
    var quota: u64 = 100_000;
    for (definitions) |definition| {
        quota +|= @as(u64, definition.path.len) * 32 + 1024;
    }
    return @intCast(@min(quota, std.math.maxInt(u32)));
}

fn routePatternBytesTotal(comptime definitions: anytype) u64 {
    var total: u64 = 0;
    for (definitions) |definition| total += @as(u64, definition.path.len);
    return total;
}

fn routeSegmentsTotal(comptime definitions: anytype) u64 {
    var total: u64 = 0;
    for (definitions) |definition| {
        for (definition.path) |byte| total += @intFromBool(byte == '/');
    }
    return total;
}

fn compileComputedLimit(
    comptime message: []const u8,
    comptime computed: anytype,
    comptime configured: anytype,
) noreturn {
    @compileError(std.fmt.comptimePrint(
        "{s}: computed={d} configured={d}",
        .{ message, computed, configured },
    ));
}

fn buildRoutes(
    comptime definitions: anytype,
    comptime limits: GraphLimits,
) [definitions.len]RouteMetadata {
    var result: [definitions.len]RouteMetadata = undefined;
    var seen_ids = [_]bool{false} ** definitions.len;
    inline for (definitions, 0..) |definition, index| {
        if (patternIssue(definition.path, limits)) |issue| {
            @compileError(issue.diagnostic());
        }
        if (!validRouteId(definition.route_id, definitions.len)) {
            @compileError("PLOOF-E3031 route id is outside the closed graph");
        }
        const route_id: u16 = @intCast(definition.route_id);
        if (seen_ids[route_id]) @compileError("PLOOF-E3032 route ids must be unique");
        seen_ids[route_id] = true;
        const stats = patternStats(definition.path);
        result[index] = .{
            .method = definition.method,
            .pattern = definition.path,
            .route_id = route_id,
            .segment_count = stats.segments,
            .capture_count = stats.captures,
        };
    }
    if (!routesSorted(&result)) sortRoutes(&result);
    validateConflicts(&result);
    return result;
}

fn validRouteId(comptime value: anytype, comptime route_count: usize) bool {
    return switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => value >= 0 and value < route_count,
        .int => |integer| if (integer.signedness == .signed)
            value >= 0 and value < route_count
        else
            value < route_count,
        else => false,
    };
}

fn validateConflicts(comptime routes: []const RouteMetadata) void {
    for (routes[1..], routes[0 .. routes.len - 1]) |current, previous| {
        if (previous.method == current.method and
            structuralEqual(previous.pattern, current.pattern))
        {
            @compileError("PLOOF-E3030 structurally equivalent routes conflict");
        }
    }
}

pub fn patternIssue(path: []const u8, limits: GraphLimits) ?PatternIssue {
    if (path.len == 0 or path[0] != '/') return .not_absolute;
    if (path.len > limits.pattern_bytes_max) return .bytes_limit;
    var capture_slots = [_]u16{0} ** (route.captures_hard_max * 2);
    var capture_names: [route.captures_hard_max][]const u8 = undefined;
    var segment_start: usize = 1;
    var segment_count: usize = 0;
    var capture_count: usize = 0;
    while (true) {
        segment_count += 1;
        if (segment_count > limits.segments_max) return .segments_limit;
        const segment_end = nextSlashBytes(path, segment_start);
        const kind = segmentKind(path[segment_start..segment_end]);
        if (kind != .literal) {
            if (capture_count >= limits.captures_max) return .captures_limit;
            const name = path[segment_start + 1 .. segment_end];
            if (name.len == 0) return .empty_capture_name;
            if (!validCaptureName(name)) return .invalid_capture_name;
            if (kind == .catch_all and segment_end != path.len) {
                return .nonterminal_catch_all;
            }
            if (!insertCaptureName(&capture_slots, &capture_names, capture_count, name)) {
                return .duplicate_capture_name;
            }
            capture_count += 1;
        }
        if (segment_end == path.len) return null;
        segment_start = segment_end + 1;
    }
}

fn patternStats(path: []const u8) PatternStats {
    var segments: u16 = 0;
    var captures: u16 = 0;
    var start: usize = 1;
    while (true) {
        segments += 1;
        const end = nextSlashBytes(path, start);
        if (segmentKind(path[start..end]) != .literal) captures += 1;
        if (end == path.len) return .{ .segments = segments, .captures = captures };
        start = end + 1;
    }
}

fn insertCaptureName(
    slots: *[route.captures_hard_max * 2]u16,
    names: *[route.captures_hard_max][]const u8,
    count: usize,
    name: []const u8,
) bool {
    var slot = captureNameHash(name) & (slots.len - 1);
    var probes: usize = 0;
    while (probes < slots.len) : (probes += 1) {
        const entry = slots[slot];
        if (entry == 0) {
            names[count] = name;
            slots[slot] = @intCast(count + 1);
            return true;
        }
        if (std.mem.eql(u8, names[entry - 1], name)) return false;
        slot = (slot + 1) & (slots.len - 1);
    }
    unreachable;
}

fn captureNameHash(name: []const u8) usize {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    return @truncate(hash);
}

fn validCaptureName(name: []const u8) bool {
    if (!isNameStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isNameStart(byte) and !(byte >= '0' and byte <= '9')) return false;
    }
    return true;
}

fn isNameStart(byte: u8) bool {
    return byte == '_' or byte >= 'A' and byte <= 'Z' or byte >= 'a' and byte <= 'z';
}

fn segmentKind(segment: []const u8) SegmentKind {
    if (segment.len == 0) return .literal;
    return switch (segment[0]) {
        ':' => .parameter,
        '*' => .catch_all,
        else => .literal,
    };
}

fn structuralEqual(left: []const u8, right: []const u8) bool {
    var left_start: usize = 1;
    var right_start: usize = 1;
    while (true) {
        const left_end = nextSlashBytes(left, left_start);
        const right_end = nextSlashBytes(right, right_start);
        const left_segment = left[left_start..left_end];
        const right_segment = right[right_start..right_end];
        const left_kind = segmentKind(left_segment);
        const right_kind = segmentKind(right_segment);
        if (left_kind != right_kind) return false;
        if (left_kind == .literal and !std.mem.eql(u8, left_segment, right_segment)) {
            return false;
        }
        const left_done = left_end == left.len;
        const right_done = right_end == right.len;
        if (left_done or right_done) return left_done and right_done;
        left_start = left_end + 1;
        right_start = right_end + 1;
    }
}

fn routesSorted(routes: []const RouteMetadata) bool {
    for (routes[1..], routes[0 .. routes.len - 1]) |current, previous| {
        if (routeLess(current, previous)) return false;
    }
    return true;
}

fn sortRoutes(routes: []RouteMetadata) void {
    std.mem.sortUnstable(RouteMetadata, routes, {}, struct {
        fn lessThan(_: void, left: RouteMetadata, right: RouteMetadata) bool {
            return routeLess(left, right);
        }
    }.lessThan);
}

fn routeLess(left: RouteMetadata, right: RouteMetadata) bool {
    if (patternLess(left.pattern, right.pattern)) return true;
    if (patternLess(right.pattern, left.pattern)) return false;
    return methodOrder(left.method) < methodOrder(right.method);
}

fn patternLess(left: []const u8, right: []const u8) bool {
    var left_start: usize = 1;
    var right_start: usize = 1;
    while (true) {
        const left_end = nextSlashBytes(left, left_start);
        const right_end = nextSlashBytes(right, right_start);
        const left_segment = left[left_start..left_end];
        const right_segment = right[right_start..right_end];
        const left_kind = segmentKind(left_segment);
        const right_kind = segmentKind(right_segment);
        if (left_kind != right_kind) return @intFromEnum(left_kind) < @intFromEnum(right_kind);
        if (left_kind == .literal) {
            const order = std.mem.order(u8, left_segment, right_segment);
            if (order != .eq) return order == .lt;
        }
        const left_done = left_end == left.len;
        const right_done = right_end == right.len;
        if (left_done or right_done) return left_done and !right_done;
        left_start = left_end + 1;
        right_start = right_end + 1;
    }
}

fn maximumCaptures(routes: anytype) u16 {
    var maximum: u16 = 0;
    for (routes) |metadata| maximum = @max(maximum, metadata.capture_count);
    return maximum;
}

fn nextSlashBytes(bytes: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, bytes, start, '/') orelse bytes.len;
}

fn alternate(input: SelectInput) ?Alternate {
    if (input.path.len == 0 or std.mem.eql(u8, input.path, "/")) return null;
    if (input.path[input.path.len - 1] == '/') {
        if (!input.terminal_slash_is_literal) return null;
        return .{
            .view = .{ .bytes = input.path[0 .. input.path.len - 1] },
            .change = .remove,
        };
    }
    return .{ .view = .{ .bytes = input.path, .append_slash = true }, .change = .add };
}

fn redirectFor(method: Method, change: SlashChange, route_id: u16) RoutePlanSelection {
    const status: RedirectStatus = if (method == .get) .moved_permanently else .temporary_redirect;
    return .{ .redirect = .{
        .route_id = route_id,
        .status = status,
        .slash_change = change,
    } };
}

fn redirectForOptions(change: SlashChange) RoutePlanSelection {
    return .{ .redirect = .{
        .route_id = null,
        .status = .temporary_redirect,
        .slash_change = change,
    } };
}

fn addMethod(allow: *Allow, method: Method) void {
    allow.mask |= methodBit(method);
    if (method == .get) allow.mask |= methodBit(.head);
}

fn methodBit(method: Method) u8 {
    return @as(u8, 1) << @intCast(methodOrder(method));
}

fn methodOrder(method: Method) i8 {
    return switch (method) {
        .get => 0,
        .head => 1,
        .post => 2,
        .put => 3,
        .patch => 4,
        .delete => 5,
    };
}
