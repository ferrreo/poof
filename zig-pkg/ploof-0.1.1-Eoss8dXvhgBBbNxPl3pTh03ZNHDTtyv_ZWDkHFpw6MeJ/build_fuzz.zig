const std = @import("std");

const correctness_modes = [_]std.builtin.OptimizeMode{
    .Debug,
    .ReleaseSafe,
    .ReleaseFast,
};

const FamilyId = enum {
    http1,
    multipart,
    csrf,
    html,
    upload,
    upload_worker,
    routing,
    url,
    static,
    assets,
    observability,
    runtime,
    stream_wake,
    stream_lifecycle,
    stream_response,
    stream_driver,
};

const FuzzTarget = struct {
    name: []const u8,
    file: []const u8,
    filter: []const u8,
    secondary_family: ?FamilyId = null,
};

const Family = struct {
    id: FamilyId,
    base: []const u8,
    description: []const u8,
    shards: u8 = 4,
};

const families = [_]Family{
    .{ .id = .http1, .base = "fuzz-http1", .description = "Fuzz pure HTTP/1.1 boundaries" },
    .{
        .id = .multipart,
        .base = "fuzz-multipart",
        .description = "Fuzz bounded multipart parsing",
    },
    .{
        .id = .csrf,
        .base = "fuzz-csrf",
        .description = "Fuzz CSRF parsing and admission",
    },
    .{
        .id = .html,
        .base = "fuzz-html",
        .description = "Fuzz bounded HTML rendering",
    },
    .{
        .id = .upload,
        .base = "fuzz-upload",
        .description = "Fuzz multipart upload and worker transport schedules",
    },
    .{
        .id = .upload_worker,
        .base = "fuzz-upload-worker",
        .description = "Fuzz worker upload transport schedules",
    },
    .{
        .id = .routing,
        .base = "fuzz-routing",
        .description = "Fuzz closed route selection",
    },
    .{
        .id = .url,
        .base = "fuzz-url",
        .description = "Fuzz typed URL construction",
    },
    .{
        .id = .static,
        .base = "fuzz-static",
        .description = "Fuzz live static-file policy",
    },
    .{
        .id = .assets,
        .base = "fuzz-assets",
        .description = "Fuzz embedded-asset HTTP policy",
    },
    .{
        .id = .observability,
        .base = "fuzz-observability",
        .description = "Fuzz bounded observability state",
    },
    .{
        .id = .runtime,
        .base = "fuzz-runtime",
        .description = "Fuzz bounded runtime state transitions",
    },
    .{
        .id = .stream_wake,
        .base = "fuzz-stream-wake",
        .description = "Fuzz stream wake schedules",
    },
    .{
        .id = .stream_lifecycle,
        .base = "fuzz-stream-lifecycle",
        .description = "Fuzz stream lifecycle ownership",
    },
    .{
        .id = .stream_response,
        .base = "fuzz-stream-response",
        .description = "Fuzz stream response heads",
    },
    .{
        .id = .stream_driver,
        .base = "fuzz-stream-driver",
        .description = "Fuzz stream driver schedules",
    },
};

comptime {
    var seen = [_]bool{false} ** families.len;
    for (families) |family| {
        const index = @intFromEnum(family.id);
        if (seen[index]) @compileError("duplicate fuzz family id");
        seen[index] = true;
    }
    for (seen) |present| {
        if (!present) @compileError("missing fuzz family id");
    }
}

const http1_targets = [_]FuzzTarget{
    .{
        .name = "request_accept_encoding",
        .file = "src/internal/http1/request_accept_encoding.zig",
        .filter = "Accept-Encoding parser fuzzes differentially against independent grammar",
    },
    .{
        .name = "response_content_coding",
        .file = "src/internal/http1/response_content_coding.zig",
        .filter = "finite response content coding decision fuzz",
    },
    .{
        .name = "response_coding_fields",
        .file = "src/internal/http1/response_coding_fields.zig",
        .filter = "response coding field overlay fuzz preserves source and tail invariants",
    },
    .{
        .name = "request_head",
        .file = "src/internal/http1/request_head.zig",
        .filter = "request head fragmentation differential fuzz",
    },
    .{
        .name = "request_target",
        .file = "src/internal/http1/request_target.zig",
        .filter = "request target parser fuzz invariants",
    },
    .{
        .name = "request_te",
        .file = "src/internal/http1/request_te.zig",
        .filter = "TE parser fuzzes differentially against independent grammar",
    },
    .{
        .name = "request_trailers_fuzz",
        .file = "fuzz/internal/http1/request_trailers_fuzz.zig",
        .filter = "request trailer declaration and fragmentation fuzz",
    },
    .{
        .name = "response_fuzz",
        .file = "fuzz/internal/http1/response_fuzz.zig",
        .filter = "response serialization invariants fuzz",
    },
    .{
        .name = "chunked",
        .file = "src/internal/http1/chunked.zig",
        .filter = "chunk decoder fragmentation differential fuzz",
    },
    .{
        .name = "query",
        .file = "src/internal/http1/query.zig",
        .filter = "query validator and decoded iterators fuzz differentially",
    },
    .{
        .name = "flat_binding",
        .file = "tests/unit/flat_binding_test.zig",
        .filter = "flat parser fragmentation fuzz is result-equivalent",
    },
    .{
        .name = "json_validate",
        .file = "tests/unit/json_validate_test.zig",
        .filter = "strict JSON fragmentation fuzz has one semantic outcome",
    },
    .{
        .name = "json_decode",
        .file = "tests/unit/json_decode_test.zig",
        .filter = "dynamic decode fragmentation fuzz has one semantic outcome",
    },
    .{
        .name = "json_parse",
        .file = "tests/unit/json_decode_test.zig",
        .filter = "jsonParse fragmentation fuzz has one semantic outcome",
    },
    .{
        .name = "json_parse_structured",
        .file = "fuzz/json_parse_fuzz_check.zig",
        .filter = "structured jsonParse fuzz is fragmentation and memory-bound equivalent",
    },
    .{
        .name = "json_encode",
        .file = "fuzz/json_encode_fuzz_check.zig",
        .filter = "JSON string encoder fuzz emits one strict document or invalid UTF-8",
    },
    .{
        .name = "request_content",
        .file = "src/internal/http1/request_content.zig",
        .filter = "content value parsers have bounded deterministic fuzz invariants",
    },
    .{
        .name = "request_expect",
        .file = "src/internal/http1/request_expect.zig",
        .filter = "Expect boundary fuzzes differentially against independent strict oracle",
    },
    .{
        .name = "body_text",
        .file = "src/body.zig",
        .filter = "body text fragmentation differential fuzz",
    },
    .{
        .name = "proxy_protocol_v2",
        .file = "fuzz/proxy_protocol_v2_fuzz_check.zig",
        .filter = "PROXY v2 fragmentation fuzz is result and consumed-count equivalent",
    },
    // Zig test filters use substring matching. Separate roots keep Forwarded from
    // selecting X-Forwarded and fighting over the same fuzz corpus lock.
    .{
        .name = "authority",
        .file = "fuzz/authority_fuzz_check.zig",
        .filter = "authority parser has deterministic variable-length outcomes",
    },
    .{
        .name = "request_forwarded",
        .file = "fuzz/request_forwarded_fuzz_check.zig",
        .filter = "Forwarded parser variable-length fuzz is deterministic and bounded",
    },
    .{
        .name = "request_x_forwarded",
        .file = "fuzz/request_x_forwarded_fuzz_check.zig",
        .filter = "X-Forwarded parser variable-length fuzz is deterministic and bounded",
    },
    .{
        .name = "forwarding_resolver",
        .file = "fuzz/forwarding_resolver_fuzz_check.zig",
        .filter = "forwarding resolver structured fuzz preserves trusted suffix identity",
    },
    .{
        .name = "request_cors",
        .file = "fuzz/cors_fuzz_check.zig",
        .filter = "CORS origin and header grammar fuzz is deterministic and bounded",
    },
    .{
        .name = "response_cors_fields",
        .file = "fuzz/cors_fuzz_check.zig",
        .filter = "CORS decisions fuzz never reflect invalid origin or header bytes",
    },
};

const multipart_targets = [_]FuzzTarget{
    .{
        .name = "multipart-boundary",
        .file = "fuzz/multipart_fuzz_check.zig",
        .filter = "multipart boundary extraction is deterministic and bounded",
    },
    .{
        .name = "multipart-part-headers",
        .file = "fuzz/multipart_fuzz_check.zig",
        .filter = "multipart part-header parsing is deterministic and bounded",
    },
    .{
        .name = "multipart-parser",
        .file = "fuzz/multipart_fuzz_check.zig",
        .filter = "multipart streaming parser fuzz preserves fragmentation and state invariants",
    },
};

const csrf_targets = [_]FuzzTarget{
    .{
        .name = "csrf-core",
        .file = "fuzz/csrf_fuzz_check.zig",
        .filter = "CSRF token cookie and origin parsers are deterministic and canonical",
    },
    .{
        .name = "csrf-multipart",
        .file = "fuzz/multipart_csrf_fuzz_check.zig",
        .filter = "multipart CSRF parser fuzz preserves token admission invariants",
    },
};

const html_targets = [_]FuzzTarget{
    .{
        .name = "html-render",
        .file = "fuzz/html_render_fuzz_check.zig",
        .filter = "HTML rendering differential and browser-boundary fuzz",
    },
    .{
        .name = "html-template",
        .file = "fuzz/html_template_fuzz_check.zig",
        .filter = "typed template rendering differential fuzz",
    },
};

const url_targets = [_]FuzzTarget{
    .{
        .name = "url",
        .file = "fuzz/url_fuzz_check.zig",
        .filter = "URL parsing and trust tables have deterministic bounded outcomes",
    },
    .{
        .name = "url-for",
        .file = "fuzz/url_for_fuzz_check.zig",
        .filter = "urlFor path and query encoding has deterministic bounded outcomes",
    },
};

const upload_targets = [_]FuzzTarget{
    .{
        .name = "storage-key",
        .file = "fuzz/multipart_storage_key_fuzz_check.zig",
        .filter = "multipart StorageKey fuzz is canonical deterministic and bounded",
    },
    .{
        .name = "transaction",
        .file = "fuzz/multipart_upload_transaction_fuzz_check.zig",
        .filter = "multipart upload transaction structured schedules are deterministic and bounded",
    },
    .{
        .name = "worker-transport",
        .file = "fuzz/worker_upload_transport_fuzz_check.zig",
        .filter = "worker upload controller structured ownership schedule fuzz",
        .secondary_family = .upload_worker,
    },
};

const runtime_targets = [_]FuzzTarget{
    .{
        .name = "server-lifecycle",
        .file = "fuzz/server_lifecycle_fuzz_check.zig",
        .filter = "server lifecycle Smith preserves irreversible transitions and exact reports",
    },
    .{
        .name = "response-chunks",
        .file = "fuzz/worker_response_chunks_fuzz_check.zig",
        .filter = "response chunk transaction structured differential fuzz",
    },
    .{
        .name = "runtime",
        .file = "fuzz/runtime_fuzz_check.zig",
        .filter = "worker bounded state machine fuzz drains every valid schedule",
    },
    .{
        .name = "fixed-identity",
        .file = "src/internal/runtime/connection/body.zig",
        .filter = "fixed identity fragmentation differential fuzz",
    },
    .{
        .name = "chunked-identity",
        .file = "fuzz/chunked_body_fuzz_check.zig",
        .filter = "chunked identity orchestration fragmentation differential fuzz",
    },
    .{
        .name = "gzip",
        .file = "fuzz/internal/runtime/gzip_decoder_fuzz_check.zig",
        .filter = "strict gzip framing differential and security fuzz",
    },
    .{
        .name = "gzip-encoder",
        .file = "fuzz/gzip_encoder_fuzz_check.zig",
        .filter = "finite gzip encoder bound and roundtrip fuzz",
    },
    .{
        .name = "response-gzip-serializer",
        .file = "fuzz/application_response_gzip_fuzz_check.zig",
        .filter = "finite response gzip serializer bounded composition fuzz",
    },
    .{
        .name = "stream-response-head",
        .file = "fuzz/application_stream_output_fuzz_check.zig",
        .filter = "stream response head serializer bounded composition fuzz",
        .secondary_family = .stream_response,
    },
    .{
        .name = "gzip-input-queue",
        .file = "src/internal/runtime/gzip/input_queue.zig",
        .filter = "gzip input queue bounded wrap and terminal invariants fuzz",
    },
    .{
        .name = "gzip-decoder-pool",
        .file = "fuzz/internal/runtime/gzip_decoder_pool_fuzz_check.zig",
        .filter = "gzip decoder pool persistent-thread structured differential fuzz",
    },
    .{
        .name = "fixed-body-driver",
        .file = "fuzz/body_driver_fuzz_check.zig",
        .filter = "fixed body driver bounded state transitions fuzz",
    },
    .{
        .name = "gzip-transport",
        .file = "fuzz/gzip_transport_fuzz_check.zig",
        .filter = "gzip transport structured fragmentation and security fuzz",
    },
    .{
        .name = "gzip-driver-schedule",
        .file = "fuzz/gzip_schedule_fuzz_check.zig",
        .filter = "gzip production driver bounded completion schedule fuzz",
    },
    .{
        .name = "stream-wake-schedule",
        .file = "fuzz/stream_wake_fuzz_check.zig",
        .filter = "stream wake bounded publication schedule fuzz",
        .secondary_family = .stream_wake,
    },
    .{
        .name = "stream-lifecycle-schedule",
        .file = "fuzz/stream_lifecycle_fuzz_check.zig",
        .filter = "stream lifecycle bounded ownership schedule fuzz",
        .secondary_family = .stream_lifecycle,
    },
    .{
        .name = "stream-suppression-lifecycle",
        .file = "fuzz/stream_lifecycle_fuzz_check.zig",
        .filter = "suppression lifecycle fuzz",
        .secondary_family = .stream_lifecycle,
    },
    .{
        .name = "stream-driver-schedule",
        .file = "fuzz/stream_driver_fuzz_check.zig",
        .filter = "stream driver bounded send wake cancellation schedule fuzz",
        .secondary_family = .stream_driver,
    },
};

const routing_targets = [_]FuzzTarget{
    .{
        .name = "routing",
        .file = "fuzz/route_graph_check.zig",
        .filter = "route graph bounded differential fuzz",
    },
};

const static_targets = [_]FuzzTarget{
    .{
        .name = "live",
        .file = "fuzz/live_static_schedule_fuzz_check.zig",
        .filter = "live static",
    },
    .{
        .name = "static-path",
        .file = "fuzz/static_file_fuzz_check.zig",
        .filter = "static path",
    },
};
const asset_targets = [_]FuzzTarget{
    .{
        .name = "embedded-assets",
        .file = "fuzz/asset_http_fuzz_check.zig",
        .filter = "embedded asset negotiation and conditional policy fuzz is bounded",
    },
};

const observability_targets = [_]FuzzTarget{
    .{
        .name = "observability",
        .file = "fuzz/observability_fuzz_check.zig",
        .filter = "observability pressure Smith preserves bounded queue and complete epochs",
    },
};

pub fn addSteps(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
) void {
    const driver = b.option(bool, "fuzz-driver", "Internal raw Zig fuzz driver") orelse false;
    addCrashGateTest(b, test_step, target, driver);
    if (driver) {
        addRawSteps(b, target);
    } else {
        const runs = b.option(u64, "fuzz-runs", "Generated cases per fuzz target") orelse
            1_000_000;
        if (runs == 0) @panic("-Dfuzz-runs must be positive");
        const timeout_seconds = b.option(
            u32,
            "fuzz-timeout-seconds",
            "External deadline for one fuzz-family campaign",
        ) orelse 3600;
        if (timeout_seconds == 0 or timeout_seconds > 86_400) {
            @panic("-Dfuzz-timeout-seconds must be between 1 and 86400");
        }
        addWrapperSteps(b, runs, timeout_seconds);
    }
}

fn addRawSteps(b: *std.Build, target: std.Build.ResolvedTarget) void {
    inline for (correctness_modes) |optimize| {
        const steps = initFamilySteps(b, optimize);
        attachTargets(b, target, optimize, &steps, .http1, &http1_targets);
        attachTargets(b, target, optimize, &steps, .multipart, &multipart_targets);
        attachTargets(b, target, optimize, &steps, .csrf, &csrf_targets);
        attachTargets(b, target, optimize, &steps, .html, &html_targets);
        attachTargets(b, target, optimize, &steps, .upload, &upload_targets);
        attachTargets(b, target, optimize, &steps, .routing, &routing_targets);
        attachTargets(b, target, optimize, &steps, .url, &url_targets);
        attachTargets(b, target, optimize, &steps, .static, &static_targets);
        attachTargets(b, target, optimize, &steps, .assets, &asset_targets);
        attachTargets(
            b,
            target,
            optimize,
            &steps,
            .observability,
            &observability_targets,
        );
        attachTargets(b, target, optimize, &steps, .runtime, &runtime_targets);
    }
}

fn addWrapperSteps(b: *std.Build, runs: u64, timeout_seconds: u32) void {
    inline for (correctness_modes) |optimize| {
        inline for (families) |family| addWrapperStep(
            b,
            family.base,
            family.description,
            optimize,
            runs,
            timeout_seconds,
            family.shards,
        );
    }
}

fn addWrapperStep(
    b: *std.Build,
    comptime base: []const u8,
    comptime description: []const u8,
    optimize: std.builtin.OptimizeMode,
    runs: u64,
    timeout_seconds: u32,
    shards: u8,
) void {
    const name = b.fmt("{s}{s}", .{ base, modeSuffix(optimize) });
    const step = b.step(name, b.fmt("{s} in {s}", .{ description, @tagName(optimize) }));
    const command = b.addSystemCommand(&.{"bash"});
    command.addFileArg(b.path("tools/run-fuzz.sh"));
    command.addArgs(&.{
        b.graph.zig_exe,
        b.cache_root.path orelse ".zig-cache",
        name,
        b.fmt("{d}", .{runs}),
        b.fmt("{d}", .{timeout_seconds}),
        b.fmt("{d}", .{shards}),
    });
    command.setCwd(b.path("."));
    step.dependOn(&command.step);
}

fn initFamilySteps(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
) [families.len]*std.Build.Step {
    var steps: [families.len]*std.Build.Step = undefined;
    inline for (families) |family| {
        steps[@intFromEnum(family.id)] = addAggregateStep(
            b,
            family.base,
            family.description,
            optimize,
        );
    }
    return steps;
}

fn attachTargets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    steps: *const [families.len]*std.Build.Step,
    comptime primary: FamilyId,
    comptime targets: []const FuzzTarget,
) void {
    inline for (targets) |case| {
        const run = addFuzzRun(b, target, optimize, case);
        steps[@intFromEnum(primary)].dependOn(run);
        if (case.secondary_family) |secondary| {
            steps[@intFromEnum(secondary)].dependOn(run);
        }
    }
}

fn addAggregateStep(
    b: *std.Build,
    comptime base: []const u8,
    comptime description: []const u8,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    return b.step(
        b.fmt("{s}{s}", .{ base, modeSuffix(optimize) }),
        b.fmt("{s} in {s}", .{ description, @tagName(optimize) }),
    );
}

fn modeSuffix(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "",
        .ReleaseSafe => "-release-safe",
        .ReleaseFast => "-release-fast",
        else => unreachable,
    };
}

fn addCrashGateTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    driver: bool,
) void {
    const tests = b.addTest(.{
        .name = "fuzz-crash-gate-fixture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/fuzz_crash_gate.zig"),
            .target = target,
            .optimize = .Debug,
            .link_libc = false,
            .error_tracing = false,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    const run = &b.addRunArtifact(tests).step;
    if (driver) {
        const step = b.step(
            "fuzz-crash-gate-fixture",
            "Internal deliberate fuzz crash fixture",
        );
        step.dependOn(run);
        return;
    }

    const step = b.step("test-fuzz-driver", "Test fail-closed Zig fuzz driver");
    step.dependOn(run);
    const check = b.addSystemCommand(&.{"sh"});
    check.addFileArg(b.path("tools/test-fuzz-driver.sh"));
    check.addArgs(&.{b.graph.zig_exe});
    check.addFileArg(b.path("tools/run-fuzz.sh"));
    check.addFileArg(b.path("tests/fixtures/fuzz_hang_gate.sh"));
    check.setCwd(b.path("."));
    step.dependOn(&check.step);
    test_step.dependOn(step);
}

fn addFuzzRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    comptime case: FuzzTarget,
) *std.Build.Step {
    const options = b.addOptions();
    options.addOption([]const u8, "target", case.file);
    const module = b.createModule(.{
        .root_source_file = b.path("fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{.{ .name = "harness_options", .module = options.createModule() }},
        // Zig 0.16's fuzz runner mismatches its stack-trace types.
        .error_tracing = false,
    });
    // The self-hosted backend omits the coverage table fuzzing needs.
    const tests = b.addTest(.{
        .name = b.fmt("fuzz-{s}-{s}", .{ case.name, @tagName(optimize) }),
        .root_module = module,
        .filters = &.{case.filter},
        .use_llvm = true,
        .use_lld = true,
    });
    return &b.addRunArtifact(tests).step;
}
