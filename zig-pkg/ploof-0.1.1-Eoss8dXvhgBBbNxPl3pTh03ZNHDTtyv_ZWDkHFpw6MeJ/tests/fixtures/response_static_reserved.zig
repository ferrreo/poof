const ploof = @import("ploof_compile").ploof;

const Response = ploof.response.Response(ploof.response.standard_head_limits);
const Workspace = ploof.response.Workspace(ploof.response.standard_head_limits);

export fn invalidStaticReservedHeader() void {
    var workspace = Workspace{};
    var value = Response.empty(&workspace, .ok);
    value.setHeaderStatic("content-length", "1") catch unreachable;
}
