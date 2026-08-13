const ploof = @import("ploof_compile").ploof;

const Response = ploof.response.Response(ploof.response.standard_head_limits);
const Workspace = ploof.response.Workspace(ploof.response.standard_head_limits);

export fn invalidStaticResponseHeader() void {
    var workspace = Workspace{};
    var response = Response.empty(&workspace, .ok);
    response.setHeaderStatic("bad header", "value") catch unreachable;
}
