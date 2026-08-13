const std = @import("std");
const sigbench = @import("sigbench");
const csrf = @import("../src/csrf.zig");
const authority = @import("../src/internal/http1/authority.zig");
const csrf_origin = @import("../src/internal/csrf/origin.zig");
const csrf_request = @import("../src/internal/csrf/request.zig");

const raw_token = [_]u8{0x5a} ** csrf.synchronizer_bytes;
const encoded_token = csrf_request.encodeSynchronizer(&raw_token);
const cookie_header =
    "session=0123456789abcdef; __Host-ploof-csrf=" ++ encoded_token ++ "; theme=dark";
const OriginSet = csrf.OriginSet(64, 64);
const origin_values = buildOrigins();

fn benchmarkFailure() noreturn {
    @branchHint(.cold);
    @panic("Ploof CSRF benchmark validity check failed");
}

fn OriginGateRunner(comptime count: usize) type {
    comptime std.debug.assert(count > 0 and count <= origin_values.len);
    return struct {
        fn bench(b: *sigbench.Bencher) void {
            b.iterCustom(run);
        }

        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var origins = OriginSet.init(origin_values[0..count]) catch benchmarkFailure();
            const selected = origin_values[count - 1];
            var effective = authority.parse(selected["https://".len..], .https) catch
                benchmarkFailure();
            std.mem.doNotOptimizeAway(&origins);
            std.mem.doNotOptimizeAway(&effective);
            var last: csrf_origin.GateDecision = undefined;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                last = csrf_origin.gate(&origins, &origins, .https, effective, true, .{
                    .fetch_site = .{ .value = "same-origin" },
                    .origin = .{ .value = selected },
                });
                std.mem.doNotOptimizeAway(&last);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (last != .allow) benchmarkFailure();
            return elapsed_ns;
        }
    };
}

fn buildOrigins() [64][]const u8 {
    comptime var values: [64][]const u8 = undefined;
    inline for (0..values.len) |index| {
        values[index] = std.fmt.comptimePrint("https://o{d}.example", .{index});
    }
    return values;
}

fn benchSynchronizerAdmission(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var expected = raw_token;
            var submitted: []const u8 = &encoded_token;
            std.mem.doNotOptimizeAway(&expected);
            std.mem.doNotOptimizeAway(&submitted);
            var accepted = false;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                var state = csrf.RequestState{};
                state.beginSynchronizer(&expected);
                accepted = state.observe(.header, submitted);
                std.mem.doNotOptimizeAway(&state);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (!accepted) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchCookieScan(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var header: []const u8 = cookie_header;
            std.mem.doNotOptimizeAway(&header);
            var selected: []const u8 = "";
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                var scanner = csrf_request.CookieScanner.init("__Host-ploof-csrf");
                scanner.feed(header);
                selected = switch (scanner.finish()) {
                    .value => |value| value,
                    .absent, .invalid, .duplicate => benchmarkFailure(),
                };
                std.mem.doNotOptimizeAway(&scanner);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (!std.mem.eql(u8, selected, &encoded_token)) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchSignedIssue(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var keyring = benchmarkKeyring();
            var binding = benchmarkBinding();
            var nonce = [_]u8{0x33} ** 32;
            defer keyring.clear();
            defer binding.clear();
            defer std.crypto.secureZero(u8, &nonce);
            std.mem.doNotOptimizeAway(&keyring);
            std.mem.doNotOptimizeAway(&binding);
            std.mem.doNotOptimizeAway(&nonce);
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                var token = keyring.sign(binding, nonce) catch benchmarkFailure();
                std.mem.doNotOptimizeAway(&token);
                token.clear();
            }
            return sigbench.nowNs() - start_ns;
        }
    }.run);
}

fn benchSignedVerify(b: *sigbench.Bencher) void {
    b.iterCustom(struct {
        fn run(iterations: u64) u64 {
            if (iterations == 0) benchmarkFailure();
            var keyring = benchmarkKeyring();
            var binding = benchmarkBinding();
            var nonce = [_]u8{0x33} ** 32;
            var token = keyring.sign(binding, nonce) catch benchmarkFailure();
            defer keyring.clear();
            defer binding.clear();
            defer std.crypto.secureZero(u8, &nonce);
            defer token.clear();
            std.mem.doNotOptimizeAway(&keyring);
            std.mem.doNotOptimizeAway(&binding);
            var accepted = false;
            const start_ns = sigbench.nowNs();
            for (0..iterations) |_| {
                accepted = keyring.verify(binding, token.slice());
                std.mem.doNotOptimizeAway(&accepted);
            }
            const elapsed_ns = sigbench.nowNs() - start_ns;
            if (!accepted) benchmarkFailure();
            return elapsed_ns;
        }
    }.run);
}

fn benchmarkKeyring() csrf.Keyring {
    const key = csrf.Key.init(7, [_]u8{0xa5} ** 32) catch benchmarkFailure();
    return csrf.Keyring.init(key, null) catch benchmarkFailure();
}

fn benchmarkBinding() csrf.LoginBinding {
    return csrf.LoginBinding.fromRandomLoginValue([_]u8{0x6c} ** 32) catch benchmarkFailure();
}

const OriginGate1 = OriginGateRunner(1);
const OriginGate8 = OriginGateRunner(8);
const OriginGate64 = OriginGateRunner(64);

pub const group = sigbench.groupWithId("m10-csrf", "M10 CSRF", .{
    sigbench.benchWithThroughput(
        "origin-gate-1",
        "same-origin unsafe request gate against one allowed origin",
        .{ .elements = 1 },
        OriginGate1.bench,
    ),
    sigbench.benchWithThroughput(
        "origin-gate-8",
        "last-match unsafe request gate against eight allowed origins",
        .{ .elements = 1 },
        OriginGate8.bench,
    ),
    sigbench.benchWithThroughput(
        "origin-gate-64",
        "last-match unsafe request gate against 64 allowed origins",
        .{ .elements = 1 },
        OriginGate64.bench,
    ),
    sigbench.benchWithThroughput(
        "synchronizer-admission",
        "canonical synchronizer token decode and constant-time comparison",
        .{ .bytes = encoded_token.len },
        benchSynchronizerAdmission,
    ),
    sigbench.benchWithThroughput(
        "signed-cookie-scan",
        "strict three-pair signed-token cookie scan",
        .{ .bytes = cookie_header.len },
        benchCookieScan,
    ),
    sigbench.benchWithThroughput(
        "signed-token-issue",
        "bound HMAC-SHA256 token issue and secure clear",
        .{ .bytes = csrf.signed_encoded_bytes },
        benchSignedIssue,
    ),
    sigbench.benchWithThroughput(
        "signed-token-verify",
        "canonical bound HMAC-SHA256 token verification",
        .{ .bytes = csrf.signed_encoded_bytes },
        benchSignedVerify,
    ),
});

pub fn writeMetricsReport(
    init: std.process.Init,
    default_output_root: []const u8,
) !void {
    const output_root = try selectedOutputRoot(init, default_output_root);
    if (output_root == null) return;
    var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try std.fmt.bufPrint(
        &directory_storage,
        "{s}/m10-csrf",
        .{output_root.?},
    );
    try std.Io.Dir.cwd().createDirPath(init.io, directory);

    var json_storage: [1024]u8 = undefined;
    var json = std.Io.Writer.fixed(&json_storage);
    try json.print(
        "{{\n  \"format\":1,\n  \"request_state_bytes\":{},\n" ++
            "  \"standard_origin_set_bytes\":{},\n  \"keyring_bytes\":{},\n" ++
            "  \"session_token_bytes\":{},\n  \"login_binding_bytes\":{},\n" ++
            "  \"encoded_synchronizer_token_bytes\":{},\n" ++
            "  \"encoded_signed_token_bytes\":{}\n}}\n",
        .{
            @sizeOf(csrf.RequestState),
            @sizeOf(csrf.StandardOriginSet),
            @sizeOf(csrf.Keyring),
            @sizeOf(csrf.SessionToken),
            @sizeOf(csrf.LoginBinding),
            @sizeOf(csrf.EncodedSynchronizerToken),
            @sizeOf(csrf.EncodedSignedToken),
        },
    );
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "{s}/metrics.json", .{directory});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = path,
        .data = json.buffered(),
    });
}

fn selectedOutputRoot(
    init: std.process.Init,
    default_output_root: []const u8,
) !?[]const u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var output_root = default_output_root;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sigbench-exact")) return null;
        if (std.mem.eql(u8, arg, "--output-dir")) {
            output_root = args.next() orelse return error.MissingArgument;
        }
    }
    return output_root;
}
