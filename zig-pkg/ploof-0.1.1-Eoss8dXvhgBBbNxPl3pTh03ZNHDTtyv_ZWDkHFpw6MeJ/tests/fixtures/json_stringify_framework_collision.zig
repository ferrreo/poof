const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub const JsonApplicationError = error{InvalidUtf8};

    pub fn jsonStringify(
        _: @This(),
        _: anytype,
    ) (ploof.Json.Error || JsonApplicationError)!void {
        return error.InvalidUtf8;
    }
};

pub fn main() void {
    _ = ploof.Json.EncodeError(Value);
}
