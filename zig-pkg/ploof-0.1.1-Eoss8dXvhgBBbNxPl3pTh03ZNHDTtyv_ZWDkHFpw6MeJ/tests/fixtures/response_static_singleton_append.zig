const ploof = @import("ploof_compile").ploof;

const Response = ploof.response.Response(ploof.response.standard_head_limits);
const Workspace = ploof.response.Workspace(ploof.response.standard_head_limits);

export fn invalidStaticSingletonAppend() void {
    var workspace = Workspace{};
    var value = Response.textStatic(&workspace, .ok, "body");
    value.appendHeaderStatic("content-type", "text/plain") catch unreachable;
}
