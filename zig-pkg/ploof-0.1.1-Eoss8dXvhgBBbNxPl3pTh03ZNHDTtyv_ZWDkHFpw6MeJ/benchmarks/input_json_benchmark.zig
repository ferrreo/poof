const std = @import("std");
const sigbench = @import("sigbench");
const body = @import("../src/body.zig");
const endpoint = @import("../src/endpoint.zig");
const form = @import("../src/form.zig");
const input_body = @import("../src/input_body.zig");
const json = @import("../src/json.zig");
const query = @import("../src/query.zig");
const application_body = @import("../src/internal/application/body.zig");
const application_input = @import("../src/internal/application/input.zig");
const flat_schema = @import("../src/internal/flat/schema.zig");
const flat_wire = @import("../src/internal/flat/wire.zig");
const json_decode = @import("../src/internal/json/decode.zig");
const json_validate = @import("../src/internal/json/validate.zig");

const hash_key = [_]u8{
    0x91, 0x26, 0xd8, 0x43, 0x5b, 0xae, 0x70, 0x1f,
    0x0d, 0xe4, 0x39, 0xc7, 0x68, 0xb2, 0x54, 0xfa,
};

const flat_query_wire = "page=42&active=true&tag=3&tag=5&label=ploof%20bench";
const flat_form_wire = "page=7&active=1&tag=11&tag=13&label=ploof+form";
const flat_segments_max = 8;
const flat_binding_bytes = 64;

const FlatInput = struct {
    page: u16,
    active: bool,
    tag: []const u16,
    label: []const u8,
};

const FlatExpected = struct {
    page: u16,
    first_tag: u16,
    second_tag: u16,
    label: []const u8,
};

const JsonRole = enum { reader, admin };

const TypedJson = struct {
    id: u64,
    active: bool,
    name: []const u8,
    scores: []const u16,
    profile: struct {
        role: JsonRole,
        note: ?[]const u8,
    },
};

const typed_json_wire =
    "{\"id\":42,\"active\":true,\"name\":\"ploof\",\"scores\":[3,5,8]," ++
    "\"profile\":{\"role\":\"admin\",\"note\":null}}";
const dynamic_json_wire =
    "{\"kind\":\"event\",\"sequence\":9001," ++
    "\"payload\":{\"name\":\"ploof\",\"ok\":true}," ++
    "\"tags\":[\"zig\",\"http\",\"json\"]}";

const EncodeValue = struct {
    id: u64,
    active: bool,
    name: []const u8,
    tags: []const []const u8,
    note: ?[]const u8,
};

const encode_value = EncodeValue{
    .id = 42,
    .active = true,
    .name = "ploof",
    .tags = &.{ "zig", "http" },
    .note = null,
};
const encoded_json =
    "{\"id\":42,\"active\":true,\"name\":\"ploof\",\"tags\":[\"zig\",\"http\"],\"note\":null}";

const EndpointQuery = struct {
    trace: []const u8,
    page: u16,
};

const EndpointJson = struct {
    name: []const u8,
    count: u16,
    tags: []const u16,
};

const EndpointForm = struct {
    name: []const u8,
    count: u16,
};

const endpoint_query_wire = "trace=request-7&page=3";
const endpoint_json_wire = "{\"name\":\"ploof\",\"count\":9,\"tags\":[2,4,8]}";
const EndpointDefinition = endpoint.Endpoint(.{
    .query = query.typed(EndpointQuery, .{
        .segments_max = 4,
        .unknown_fields = .reject,
    }),
    .body = input_body.oneOf(.{
        .form = form.typed(EndpointForm, .{
            .encoded_wire_bytes_max = 128,
            .decoded_bytes_max = 128,
            .segments_max = 4,
            .unknown_fields = .reject,
        }),
        .json = json.typed(EndpointJson, .{
            .encoded_wire_bytes_max = endpoint_json_wire.len,
            .decoded_bytes_max = endpoint_json_wire.len,
            .parse_memory_bytes_max = 4096,
            .depth_max = 8,
            .unknown_fields = .reject,
        }),
    }),
    .response_json_bytes_max = 256,
});
const endpoint_handler = EndpointDefinition.handle(struct {
    fn call(_: *u8, _: EndpointDefinition.InputType) void {}
}.call);
const EndpointHandler = @TypeOf(endpoint_handler);
const endpoint_layout = application_input.workspaceLayout(EndpointHandler);
const endpoint_json_selection = application_input.plan(EndpointHandler).selectMedia(1) orelse
    @compileError("Endpoint benchmark JSON media selection failed");
const endpoint_json_decoder = endpoint_json_selection.selected_decoder orelse
    @compileError("Endpoint benchmark JSON decoder selection failed");

comptime {
    if (endpoint_json_selection.decoderKind() != .json or endpoint_json_decoder == 0) {
        @compileError("Endpoint benchmark must select a nonzero JSON alternative");
    }
}

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof input/JSON benchmark validity check failed");
}

fn parseFlat(
    source: flat_wire.Source,
    fragments: []const flat_wire.Fragment,
    pairs: []flat_wire.Pair,
    decoded: []u8,
    binding: []u8,
) FlatInput {
    const table = flat_wire.parse(
        flat_segments_max,
        source,
        fragments,
        pairs,
        decoded,
    ) catch benchmarkFailure();
    var arena = flat_schema.Arena.init(binding);
    return switch (flat_schema.bind(FlatInput, table, &arena, .{
        .unknown_fields = .reject,
    })) {
        .ready => |value| value,
        .rejected => benchmarkFailure(),
    };
}

fn runFlat(
    iterations: u64,
    comptime source: flat_wire.Source,
    comptime wire: []const u8,
    comptime expected: FlatExpected,
) u64 {
    if (iterations == 0) benchmarkFailure();
    var runtime_wire: []const u8 = wire;
    std.mem.doNotOptimizeAway(&runtime_wire);
    const fragments = [_]flat_wire.Fragment{flat_wire.Fragment.init(runtime_wire)};
    var pairs: [flat_segments_max]flat_wire.Pair = undefined;
    var decoded: [wire.len]u8 = undefined;
    var binding: [flat_binding_bytes]u8 align(8) = undefined;
    var last: FlatInput = undefined;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        last = parseFlat(source, &fragments, &pairs, &decoded, &binding);
        std.mem.doNotOptimizeAway(&last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (last.page != expected.page or !last.active or last.tag.len != 2 or
        last.tag[0] != expected.first_tag or last.tag[1] != expected.second_tag or
        !std.mem.eql(u8, last.label, expected.label))
    {
        benchmarkFailure();
    }
    return elapsed_ns;
}

fn benchFlatQuery(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runFlat(iterations, .query, flat_query_wire, .{
                .page = 42,
                .first_tag = 3,
                .second_tag = 5,
                .label = "ploof bench",
            });
        }
    }.run);
}

fn benchFlatForm(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runFlat(iterations, .form, flat_form_wire, .{
                .page = 7,
                .first_tag = 11,
                .second_tag = 13,
                .label = "ploof form",
            });
        }
    }.run);
}

fn runTypedJson(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    const chunks = [_]body.Chunk{body.Chunk.init(typed_json_wire)};
    var input = body.Bytes.init(&chunks) catch benchmarkFailure();
    var runtime_hash_key = hash_key;
    var workspace: [4096]u8 align(json_validate.scratch_alignment) = undefined;
    var last: *TypedJson = undefined;
    std.mem.doNotOptimizeAway(&input);
    std.mem.doNotOptimizeAway(&runtime_hash_key);
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        const result = json_decode.decode(TypedJson, input, &workspace, .{
            .hash_key = runtime_hash_key,
            .depth_max = 8,
            .unknown_fields = .reject,
        }) catch benchmarkFailure();
        last = result.value;
        std.mem.doNotOptimizeAway(last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (last.id != 42 or !last.active or !std.mem.eql(u8, last.name, "ploof") or
        last.scores.len != 3 or last.scores[2] != 8 or last.profile.role != .admin or
        last.profile.note != null)
    {
        benchmarkFailure();
    }
    return elapsed_ns;
}

fn benchTypedJson(b: *sigbench.Bencher) void {
    b.iterCustom(runTypedJson);
}

fn runDynamicJson(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    const chunks = [_]body.Chunk{body.Chunk.init(dynamic_json_wire)};
    var input = body.Bytes.init(&chunks) catch benchmarkFailure();
    var runtime_hash_key = hash_key;
    var workspace: [8192]u8 align(json_validate.scratch_alignment) = undefined;
    var last: *json.Value = undefined;
    std.mem.doNotOptimizeAway(&input);
    std.mem.doNotOptimizeAway(&runtime_hash_key);
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        const result = json_decode.decodeValue(input, &workspace, .{
            .hash_key = runtime_hash_key,
            .depth_max = 8,
            .unknown_fields = .reject,
        }) catch benchmarkFailure();
        last = result.value;
        std.mem.doNotOptimizeAway(last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    const kind = last.get("kind") catch benchmarkFailure();
    const sequence = last.get("sequence") catch benchmarkFailure();
    const payload = last.get("payload") catch benchmarkFailure();
    const tags = last.get("tags") catch benchmarkFailure();
    const kind_text = switch (kind.*) {
        .string => |value| value,
        else => benchmarkFailure(),
    };
    const sequence_number = switch (sequence.*) {
        .number => |number| number,
        else => benchmarkFailure(),
    };
    const payload_ok = (payload.get("ok") catch benchmarkFailure()).*;
    const tag_values = switch (tags.*) {
        .array => |values| values,
        else => benchmarkFailure(),
    };
    const last_tag = if (tag_values.len == 3) switch (tag_values[2]) {
        .string => |value| value,
        else => benchmarkFailure(),
    } else benchmarkFailure();
    if (!std.mem.eql(u8, kind_text, "event") or
        !std.mem.eql(u8, sequence_number.bytes(), "9001") or
        payload_ok != .boolean or !payload_ok.boolean or
        !std.mem.eql(u8, last_tag, "json"))
    {
        benchmarkFailure();
    }
    return elapsed_ns;
}

fn benchDynamicJson(b: *sigbench.Bencher) void {
    b.iterCustom(runDynamicJson);
}

fn runJsonEncode(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var output: [256]u8 = undefined;
    var runtime_value = encode_value;
    var last: []const u8 = &.{};
    std.mem.doNotOptimizeAway(&runtime_value);
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        last = json.encodeWith(
            .{ .encoded_bytes_max = output.len },
            runtime_value,
            &output,
        ) catch benchmarkFailure();
        std.mem.doNotOptimizeAway(last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (!std.mem.eql(u8, last, encoded_json)) benchmarkFailure();
    return elapsed_ns;
}

fn benchJsonEncode(b: *sigbench.Bencher) void {
    b.iterCustom(runJsonEncode);
}

fn materializeEndpoint(
    decoded: body.Bytes,
    selected_decoder: ?u8,
    raw_query: ?[]const u8,
    runtime_hash_key: [16]u8,
    workspace: []align(endpoint_layout.alignment) u8,
) EndpointDefinition.InputType {
    return application_body.materializeSelected(
        endpoint_handler,
        .{ .bytes = decoded },
        selected_decoder,
        raw_query,
        workspace,
        runtime_hash_key,
    ) catch benchmarkFailure();
}

fn runEndpointMaterialize(iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var workspace: [endpoint_layout.total_bytes_max]u8 align(endpoint_layout.alignment) =
        undefined;
    const body_region = endpoint_layout.body_decoders[endpoint_json_decoder].body;
    if (endpoint_json_wire.len > body_region.bytes) benchmarkFailure();
    const retained = workspace[body_region.offset..][0..endpoint_json_wire.len];
    @memcpy(retained, endpoint_json_wire);
    const chunks = [_]body.Chunk{body.Chunk.init(retained)};
    var decoded = body.Bytes.init(&chunks) catch benchmarkFailure();
    var selected_decoder: ?u8 = endpoint_json_decoder;
    var raw_query: ?[]const u8 = endpoint_query_wire;
    var runtime_hash_key = hash_key;
    var last: EndpointDefinition.InputType = undefined;
    std.mem.doNotOptimizeAway(&decoded);
    std.mem.doNotOptimizeAway(&selected_decoder);
    std.mem.doNotOptimizeAway(&raw_query);
    std.mem.doNotOptimizeAway(&runtime_hash_key);
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        last = materializeEndpoint(
            decoded,
            selected_decoder,
            raw_query,
            runtime_hash_key,
            &workspace,
        );
        std.mem.doNotOptimizeAway(&last);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (last.query.page != 3 or !std.mem.eql(u8, last.query.trace, "request-7")) {
        benchmarkFailure();
    }
    const selected = switch (last.body) {
        .json => |value| value,
        .form => benchmarkFailure(),
    };
    if (selected.count != 9 or !std.mem.eql(u8, selected.name, "ploof") or
        selected.tags.len != 3 or selected.tags[2] != 8)
    {
        benchmarkFailure();
    }
    return elapsed_ns;
}

fn benchEndpointMaterialize(b: *sigbench.Bencher) void {
    b.iterCustom(runEndpointMaterialize);
}

pub const group = sigbench.groupWithId("m6-input-json", "M6 query, form, and JSON", .{
    sigbench.benchWithThroughput(
        "flat-query-typed-bind",
        "flat query parse and typed bind",
        .{ .bytes = flat_query_wire.len },
        benchFlatQuery,
    ),
    sigbench.benchWithThroughput(
        "flat-form-typed-bind",
        "flat form parse and typed bind",
        .{ .bytes = flat_form_wire.len },
        benchFlatForm,
    ),
    sigbench.benchWithThroughput(
        "strict-typed-json-decode",
        "strict typed JSON decode",
        .{ .bytes = typed_json_wire.len },
        benchTypedJson,
    ),
    sigbench.benchWithThroughput(
        "dynamic-json-decode",
        "dynamic JSON decode",
        .{ .bytes = dynamic_json_wire.len },
        benchDynamicJson,
    ),
    sigbench.benchWithThroughput(
        "json-encode",
        "typed JSON encode",
        .{ .bytes = encoded_json.len },
        benchJsonEncode,
    ),
    sigbench.benchWithThroughput(
        "endpoint-materialize-json",
        "Endpoint query and selected JSON alternative materialization",
        .{ .bytes = endpoint_query_wire.len + endpoint_json_wire.len },
        benchEndpointMaterialize,
    ),
});
