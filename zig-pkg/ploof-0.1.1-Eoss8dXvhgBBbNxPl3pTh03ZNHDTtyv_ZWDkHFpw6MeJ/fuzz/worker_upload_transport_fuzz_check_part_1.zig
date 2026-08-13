const source = @import("worker_upload_transport_fuzz_check.zig");
const std = source.std;
const multipart = source.multipart;
const finalization = source.finalization;
const parser = source.parser;
const upload_dispatch = source.upload_dispatch;
const upload_finalizer = source.upload_finalizer;
const upload_sink_driver = source.upload_sink_driver;
const reactor = source.reactor;
const upload_transport = source.upload_transport;
const worker_upload = source.worker_upload;
const upload_metrics = source.upload_metrics;
const runtime_fuzz = source.runtime_fuzz;
const lanes = source.lanes;
const paths = source.paths;
const Behavior = source.Behavior;
const RequestApp = source.RequestApp;
const RequestStorage = source.RequestStorage;
const TestReactor = source.TestReactor;
const RequestController = source.RequestController;
const RequestOutcome = source.RequestOutcome;
const expectParserRejectionTerminal = source.expectParserRejectionTerminal;
const runRequestSchedule = source.runRequestSchedule;
const drainRequestSchedule = source.drainRequestSchedule;
const applyRequestCompletion = source.applyRequestCompletion;
const expectRequestOutcome = source.expectRequestOutcome;
const seedDirectory = source.seedDirectory;
const targetLane = source.targetLane;
const chooseLane = source.chooseLane;
const RuntimeMode = source.RuntimeMode;
const RuntimeSink = source.RuntimeSink;
const SinkA = source.SinkA;
const SinkB = source.SinkB;
const SinkStartFailure = source.SinkStartFailure;
const SinkResumeFailure = source.SinkResumeFailure;
const RuntimeRegistry = source.RuntimeRegistry;
const RuntimeApp = source.RuntimeApp;
const RuntimeStorage = source.RuntimeStorage;
const runRuntimeSchedule = source.runRuntimeSchedule;
const completeRuntimeOpen = source.completeRuntimeOpen;
const stopRuntime = source.stopRuntime;
const fuzzWorkerUpload = source.fuzzWorkerUpload;
const fuzz_corpus = source.fuzz_corpus;
const writeLane = source.writeLane;
const laneBit = source.laneBit;
const requestReport = source.requestReport;

test "parser rejection cancels every active target without a fatal transition" {
    var storage = RequestStorage{};
    storage.requests[0].workspace.behavior = .parser_failure;
    storage.requests[0].workspace.pending = 0b1111;
    var io = TestReactor{};
    var controller = try RequestController.init(3);
    try std.testing.expect(try controller.beginRegistryStart(
        &storage,
        &io,
        &([_]u8{0x5a} ** 32),
    ) == .registry_ready);
    storage.requests[0].workspace.directory = try seedDirectory(&controller, 1);
    try std.testing.expect(try controller.submitParserWorkAt(
        &storage,
        &io,
        0,
        10,
    ) == .none);

    var targets: [lanes]reactor.Submission = undefined;
    for (&targets) |*target| target.* = io.take();
    const rejected = try controller.completeAt(&storage, &io, .{
        .token = targets[0].token,
        .result = .{ .success = .{ .file_unlink = {} } },
        .more = false,
    }, 20);
    try std.testing.expectEqual(
        worker_upload.RejectionStatus.bad_request,
        rejected.request_rejected.status,
    );
    try std.testing.expectEqual(@as(u8, lanes - 1), io.count);

    var cancels: [lanes - 1]reactor.Submission = undefined;
    for (&cancels, 1..) |*cancel, lane| {
        cancel.* = io.take();
        try std.testing.expect(cancel.operation == .upload_cancel);
        try std.testing.expect(cancel.operation.upload_cancel.target.eql(targets[lane].token));
    }
    try RequestApp.__cancelMultipart(&storage.requests[0].workspace, .body);
    try std.testing.expect(try RequestApp.__startMultipartFinalization(
        &storage.requests[0].workspace,
        &storage.body,
    ) == .complete);
    storage.requests[0].flags.upload_finalizing = true;

    for (cancels) |cancel| try std.testing.expect(try controller.completeAt(
        &storage,
        &io,
        .{
            .token = cancel.token,
            .result = .{ .success = .{ .upload_cancel = .canceled } },
            .more = false,
        },
        30,
    ) == .none);
    var terminal: worker_upload.Event = .none;
    for (targets[1..]) |target| terminal = try controller.completeAt(
        &storage,
        &io,
        .{
            .token = target.token,
            .result = .{ .failure = .canceled },
            .more = false,
        },
        40,
    );
    try expectParserRejectionTerminal(&controller, &storage, terminal);
}

test "worker upload controller structured ownership schedule fuzz" {
    try std.testing.fuzz({}, fuzzWorkerUpload, .{ .corpus = &fuzz_corpus });
}

test "worker upload controller replays ownership crash schedule" {
    const input = [_]u8{
        0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x9a, 0xa9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x51, 0xd1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var smith = std.testing.Smith{ .in = &input };
    try fuzzWorkerUpload({}, &smith);
}
