const ploof = @import("ploof_compile").ploof;

const maximum = ploof.response.HeadLimits.validate(.{
    .head_bytes_max = 64,
    .field_line_bytes_max = 32,
    .fields_max = 2,
});
const Workspace = ploof.response.Workspace(maximum);

export fn oversizedLogicalResponseLimits() void {
    var workspace = Workspace{};
    workspace.reset(.{
        .head_bytes_max = 65,
        .field_line_bytes_max = 32,
        .fields_max = 2,
    });
}
