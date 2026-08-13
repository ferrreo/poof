const response_stream = @import("../../response/stream.zig");

pub fn validate(comptime Producer: type) void {
    validateContainer(Producer);
    validateProtocol(Producer);
}

pub fn validateWorkspace(
    comptime Producer: type,
    comptime bytes_max: usize,
    comptime alignment_max: comptime_int,
) void {
    validateContainer(Producer);
    if (@sizeOf(Producer) > bytes_max) {
        @compileError("PLOOF-E3104 stream producer exceeds workspace byte limit");
    }
    if (@alignOf(Producer) > alignment_max) {
        @compileError("PLOOF-E3105 stream producer exceeds workspace alignment limit");
    }
    validateProtocol(Producer);
}

fn validateContainer(comptime Producer: type) void {
    switch (@typeInfo(Producer)) {
        .@"struct", .@"union", .@"enum" => {},
        else => @compileError("PLOOF-E3103 stream producer must be a value container"),
    }
}

fn validateProtocol(comptime Producer: type) void {
    if (!@hasDecl(Producer, "poll") or @TypeOf(Producer.poll) != ProducerPoll(Producer)) {
        @compileError("PLOOF-E3106 invalid stream producer poll signature");
    }
    validateLifecycle(Producer, "abort");
    validateLifecycle(Producer, "join");
}

fn validateLifecycle(comptime Producer: type, comptime name: []const u8) void {
    if (!@hasDecl(Producer, name)) return;
    if (@TypeOf(@field(Producer, name)) != fn (*Producer) void) {
        @compileError("PLOOF-E3527 invalid stream producer lifecycle signature");
    }
}

fn ProducerPoll(comptime Producer: type) type {
    return fn (
        *Producer,
        []u8,
        response_stream.Wake,
    ) response_stream.PollError!response_stream.PollResult;
}
