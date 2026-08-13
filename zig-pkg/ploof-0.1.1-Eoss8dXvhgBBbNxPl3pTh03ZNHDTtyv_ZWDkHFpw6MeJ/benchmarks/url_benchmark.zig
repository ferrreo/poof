const std = @import("std");
const sigbench = @import("sigbench");
const inline_text = @import("../src/inline_text.zig");
const trusted_resource = @import("../src/trusted_resource_url.zig");
const url = @import("../src/url.zig");

const local_input = "/users/42/events?q=ploof%20bench#latest";
const web_input = "https://api.example.com:8443/users/42?q=ploof%20bench";
const allowed_hosts = buildAllowedHosts();
const allowlist_policy = url.WebPolicy{
    .https = .{ .allowlist = &allowed_hosts },
};
const Resource = enum { script };
const ShortResourceTable = trusted_resource.ResourceTable(
    Resource,
    &.{"https://cdn.example"},
    64,
);
const short_resource_config: ShortResourceTable.Configuration =
    .{"https://cdn.example/app.js"};
const max_resource_input = "https://cdn.example/" ++
    "a" ** (url.url_bytes_standard_max - "https://cdn.example/".len);
const MaxResourceTable = trusted_resource.ResourceTable(
    Resource,
    &.{"https://cdn.example"},
    url.url_bytes_standard_max,
);
const max_resource_config: MaxResourceTable.Configuration = .{max_resource_input};
const allowed_origins = buildAllowedOrigins();
const AllowlistResourceTable = trusted_resource.ResourceTable(
    Resource,
    &allowed_origins,
    64,
);
const allowlist_resource_config: AllowlistResourceTable.Configuration =
    .{"https://h63.example/app.js"};

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof URL benchmark validity check failed");
}

fn benchLocalValidation(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var input: []const u8 = local_input;
            std.mem.doNotOptimizeAway(&input);
            var parsed: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                parsed = url.Url.local(input) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&parsed);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (!std.mem.eql(u8, parsed.bytes(), local_input)) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchWebValidation(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var input: []const u8 = web_input;
            std.mem.doNotOptimizeAway(&input);
            var parsed: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                parsed = url.Url.web(input, url.WebPolicy.anyHttps()) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&parsed);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (parsed.kind() != .https) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchWebAllowlist(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var input: []const u8 = "https://h63.example/path";
            std.mem.doNotOptimizeAway(&input);
            var parsed: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                parsed = url.Url.web(input, allowlist_policy) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&parsed);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (parsed.kind() != .https) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchLocalBuilder(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var output: [256]u8 = undefined;
            var result: url.Url = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                var builder = url.LocalBuilder.init(&output) catch benchmarkFailure();
                builder.segment("users") catch benchmarkFailure();
                builder.segment("caf\xc3\xa9") catch benchmarkFailure();
                builder.query("next", "/events?a=b") catch benchmarkFailure();
                result = builder.finish() catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&result);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (result.bytes().len == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchInlineText(bencher: *sigbench.Bencher) void {
    const Text = inline_text.InlineText(64);
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var result: Text = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |iteration| {
                result = Text.print("item-{d}", .{iteration}) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&result);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if ((result.bytes() catch benchmarkFailure()).len == 0) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchResourceIssuedShort(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResourceIssued(ShortResourceTable, short_resource_config, iterations);
        }
    }.run);
}

fn benchResourceGetShort(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResourceGet(ShortResourceTable, short_resource_config, iterations);
        }
    }.run);
}

fn benchResourceIssuedMax(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResourceIssued(MaxResourceTable, max_resource_config, iterations);
        }
    }.run);
}

fn benchResourceGetMax(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResourceGet(MaxResourceTable, max_resource_config, iterations);
        }
    }.run);
}

fn benchResourceGetAllowlist64(bencher: *sigbench.Bencher) void {
    bencher.iterCustom(struct {
        fn run(iterations: u64) u64 {
            return runResourceGet(
                AllowlistResourceTable,
                allowlist_resource_config,
                iterations,
            );
        }
    }.run);
}

fn runResourceIssued(comptime Table: type, comptime configuration: anytype, iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var table: Table = undefined;
    var configured: Table.Configuration = configuration;
    if (table.init(&configured) != null) benchmarkFailure();
    const resource = table.get(.script) catch benchmarkFailure();
    var bytes: []const u8 = undefined;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        bytes = resource.validatedBytes() catch benchmarkFailure();
        std.mem.doNotOptimizeAway(&bytes);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (!std.mem.eql(u8, bytes, configuration[0])) benchmarkFailure();
    return elapsed_ns;
}

fn runResourceGet(comptime Table: type, comptime configuration: anytype, iterations: u64) u64 {
    if (iterations == 0) benchmarkFailure();
    var table: Table = undefined;
    var configured: Table.Configuration = configuration;
    if (table.init(&configured) != null) benchmarkFailure();
    var resource: *const trusted_resource.TrustedResourceUrl = undefined;
    const start_ns = sigbench.nowNs();
    for (0..iterations) |_| {
        resource = table.get(.script) catch benchmarkFailure();
        std.mem.doNotOptimizeAway(&resource);
    }
    const elapsed_ns = sigbench.nowNs() - start_ns;
    if (!std.mem.eql(u8, resource.bytes(), configuration[0])) benchmarkFailure();
    return elapsed_ns;
}

fn buildAllowedHosts() [64][]const u8 {
    comptime var hosts: [64][]const u8 = undefined;
    inline for (0..hosts.len) |index| {
        hosts[index] = std.fmt.comptimePrint("h{d}.example", .{index});
    }
    return hosts;
}

fn buildAllowedOrigins() [64][]const u8 {
    comptime var origins: [64][]const u8 = undefined;
    inline for (0..origins.len) |index| {
        origins[index] = std.fmt.comptimePrint("https://h{d}.example", .{index});
    }
    return origins;
}

pub const group = sigbench.groupWithId("m11-url-safety", "M11 URL safety", .{
    sigbench.benchWithThroughput(
        "local-validate",
        "strict same-origin raw URL validation",
        .{ .bytes = local_input.len },
        benchLocalValidation,
    ),
    sigbench.benchWithThroughput(
        "web-validate-any-https",
        "strict absolute web URL validation with any HTTPS host",
        .{ .bytes = web_input.len },
        benchWebValidation,
    ),
    sigbench.benchWithThroughput(
        "web-validate-allowlist-64",
        "strict web URL validation with a last-match 64-host allowlist",
        .{ .bytes = "https://h63.example/path".len },
        benchWebAllowlist,
    ),
    sigbench.benchWithThroughput(
        "local-component-builder",
        "bounded local URL component encoding",
        .{ .elements = 1 },
        benchLocalBuilder,
    ),
    sigbench.benchWithThroughput(
        "inline-text-format",
        "bounded inline presentation text formatting",
        .{ .elements = 1 },
        benchInlineText,
    ),
    sigbench.benchWithThroughput(
        "trusted-resource-issued-short",
        "validate issued startup resource capability",
        .{ .bytes = short_resource_config[0].len },
        benchResourceIssuedShort,
    ),
    sigbench.benchWithThroughput(
        "trusted-resource-get-short",
        "lookup and validate short startup resource",
        .{ .bytes = short_resource_config[0].len },
        benchResourceGetShort,
    ),
    sigbench.benchWithThroughput(
        "trusted-resource-issued-8192",
        "validate maximum standard startup resource capability",
        .{ .bytes = max_resource_input.len },
        benchResourceIssuedMax,
    ),
    sigbench.benchWithThroughput(
        "trusted-resource-get-8192",
        "lookup and validate maximum standard startup resource",
        .{ .bytes = max_resource_input.len },
        benchResourceGetMax,
    ),
    sigbench.benchWithThroughput(
        "trusted-resource-get-origins-64",
        "lookup startup resource from 64-origin table",
        .{ .bytes = allowlist_resource_config[0].len },
        benchResourceGetAllowlist64,
    ),
});
