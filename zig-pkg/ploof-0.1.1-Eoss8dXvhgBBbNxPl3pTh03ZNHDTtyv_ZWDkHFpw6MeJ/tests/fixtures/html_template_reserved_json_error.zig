const ploof = @import("ploof_compile").ploof;

const Value = struct {
    pub const JsonApplicationError = error{ResponseChunksExhausted};

    pub fn jsonStringify(
        _: @This(),
        _: anytype,
    ) (ploof.Json.Error || JsonApplicationError)!void {
        return error.ResponseChunksExhausted;
    }
};

const Page = ploof.HtmlTemplate.Template(.{
    .View = struct { value: Value },
    .source = ploof.HtmlSource.SourceSpec{
        .kind = .fragment,
        .graph_name = "reserved-json-error",
        .file_path = "views/reserved-json-error.html",
        .bytes = "{{@jsonData state view.value}}",
    },
});

comptime {
    _ = Page;
}
