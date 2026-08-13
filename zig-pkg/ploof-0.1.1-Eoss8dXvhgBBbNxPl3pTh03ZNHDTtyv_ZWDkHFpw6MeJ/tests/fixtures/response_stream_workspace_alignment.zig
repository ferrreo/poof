const ploof = @import("ploof_compile").ploof;

const Producer = struct {
    lanes: @Vector(4, u64) = @splat(0),

    pub fn poll(
        _: *@This(),
        _: []u8,
        _: ploof.response_stream.Wake,
    ) ploof.response_stream.PollError!ploof.response_stream.PollResult {
        return .pending;
    }
};

export fn forceStreamWorkspaceAlignment() void {
    const Erased = ploof.__responseStreamErased(64, 8);
    var erased: Erased = undefined;
    erased.init(ploof.response_stream.unknown(Producer{}, &.{}));
}
