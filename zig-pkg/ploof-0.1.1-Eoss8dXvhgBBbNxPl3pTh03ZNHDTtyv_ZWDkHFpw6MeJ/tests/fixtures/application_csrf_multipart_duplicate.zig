const ploof = @import("ploof_compile").ploof;
const support = @import("csrf_application_support.zig");

const Definition = ploof.Endpoint(.{ .body = ploof.Multipart.decode(.{
    .first = ploof.Csrf.multipartField(),
    .second = ploof.Csrf.multipartField(),
}, .{}) });

const Consumer = struct {
    pub const State = void;

    pub fn complete(
        _: Consumer,
        context: *support.Context,
        _: *State,
        _: Definition.InputType,
        _: Definition.MultipartBodySpec.Summaries,
    ) ploof.Multipart.Decision(support.Response) {
        return ploof.Multipart.commit(context.empty(.no_content));
    }
};

const BrokenApplication = ploof.Application(.{
    .State = support.State,
    .middleware = .{support.policy},
    .routes = .{ploof.route.post("/", Definition.handle(Consumer{}))},
});

export fn forceCsrfMultipartDuplicate() void {
    _ = @sizeOf(BrokenApplication.Workspace);
}
