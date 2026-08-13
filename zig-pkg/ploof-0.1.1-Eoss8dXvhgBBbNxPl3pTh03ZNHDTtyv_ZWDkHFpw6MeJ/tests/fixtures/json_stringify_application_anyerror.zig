const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub const JsonApplicationError = anyerror;

    pub fn jsonStringify(_: @This(), _: anytype) ploof.Json.Error!void {}
};

pub fn main() void {
    _ = ploof.Json.EncodeError(Value);
}
