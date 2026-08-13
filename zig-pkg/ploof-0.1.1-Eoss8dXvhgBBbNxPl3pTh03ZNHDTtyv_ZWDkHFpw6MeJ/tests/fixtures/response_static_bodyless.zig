const ploof = @import("ploof_compile").ploof;

const Response = ploof.response.Response(ploof.response.standard_head_limits);
const Workspace = ploof.response.Workspace(ploof.response.standard_head_limits);

export fn invalidStaticBodylessResponse() void {
    var workspace = Workspace{};
    _ = Response.textStatic(&workspace, .no_content, "forbidden");
}
