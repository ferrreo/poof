const application = @import("../../../application.zig");

pub fn scrub(
    comptime App: type,
    workspace: anytype,
    prepared: application.Prepared,
) void {
    if (comptime !@hasDecl(App, "__scrubPreparedHead")) return;
    switch (prepared.source) {
        .finite_chain => |finite| App.__scrubPreparedHead(workspace, finite.head),
        .contiguous_wire, .borrowed_static, .live_static, .live_static_file => {},
    }
}
