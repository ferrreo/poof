const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub fn jsonStringify(_: @This(), _: anytype) (ploof.Json.Error || error{Denied})!void {
        return error.Denied;
    }
};

pub fn main() void {
    _ = ploof.Json.EncodeError(Value);
}
