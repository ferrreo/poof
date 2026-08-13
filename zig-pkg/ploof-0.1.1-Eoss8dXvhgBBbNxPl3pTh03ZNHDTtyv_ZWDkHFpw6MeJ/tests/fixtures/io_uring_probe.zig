const ploof = @import("ploof");
const App = struct {
    pub const upload_io_requirements = ploof.Multipart.IoRequirements.none;
    pub const live_static_root_count = 0;
};
pub fn main() void {
    ploof.startup.require(App, .{});
}
