const ploof = @import("ploof_compile").ploof;

const Producer = struct {
    bytes: [32]u8 = [_]u8{0} ** 32,

    pub fn poll(
        _: *@This(),
        _: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        return .pending;
    }
};

export fn forceStreamWorkspaceSize() void {
    const Erased = ploof.__responseStreamErased(16, 8);
    var erased: Erased = undefined;
    erased.init(ploof.response_stream.unknown(Producer{}, &.{}));
}
