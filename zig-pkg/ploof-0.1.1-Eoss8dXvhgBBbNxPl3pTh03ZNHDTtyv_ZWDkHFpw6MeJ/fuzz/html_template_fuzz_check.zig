const std = @import("std");
const fuzz_support = @import("../src/internal/http1/testing/smith.zig");
const html_render = @import("../src/html/render.zig");
const html_source = @import("../src/html/source.zig");
const html_template = @import("../src/html/template.zig");

const View = struct {
    value: []const u8,
    show: bool,
    marker: ?u8,
    numbers: []const u16,
};

fn doubled(value: u16) u32 {
    return @as(u32, value) * 2;
}

const Page = html_template.Template(.{
    .View = View,
    .source = html_source.SourceSpec{
        .kind = .fragment,
        .graph_name = "template-fuzz",
        .file_path = "fuzz/template.html",
        .bytes = "{{#if view.show}}T{{else}}F{{/if}}" ++
            "{{#with view.marker as marker}}U{{else}}N{{/with}}" ++
            "{{#each view.numbers as number,index}}" ++
            "[{{index}}={{number}}/{{doubled number}}]{{else}}E{{/each}}" ++
            "|{{view.value}}|<textarea>{{view.value}}</textarea>" ++
            "<div title=\"x='{{view.value}}'\" data-label='y=\"{{view.value}}\"'></div>",
    },
    .helpers = .{ .doubled = doubled },
});

test "typed template rendering differential fuzz" {
    try std.testing.fuzz({}, fuzzTemplate, .{ .corpus = &corpus });
}

const corpus = struct {
    const empty = fuzz_support.smithInput("");
    const xss = fuzz_support.smithInput("<&>\"'</script>");
    const lanes = fuzz_support.smithInput(("a" ** 31) ++ "<&" ++ ("b" ** 32) ++ ">");
    const unicode = fuzz_support.smithInput("Ploof € 𝄞");
    const invalid = fuzz_support.smithInput("\xff\xc0\x80");
    const values = [_][]const u8{ &empty, &xss, &lanes, &unicode, &invalid };
}.values;

const Writer = struct {
    storage: []u8,
    length: usize = 0,

    pub fn write(writer: *Writer, chunk: []const u8) error{NoSpaceLeft}!void {
        if (chunk.len > writer.storage.len - writer.length) return error.NoSpaceLeft;
        @memcpy(writer.storage[writer.length..][0..chunk.len], chunk);
        writer.length += chunk.len;
    }

    fn bytes(writer: *const Writer) []const u8 {
        return writer.storage[0..writer.length];
    }
};

fn fuzzTemplate(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [1024]u8 = undefined;
    const input = input_storage[0..smith.slice(&input_storage)];
    var numbers_storage: [8]u16 = undefined;
    const number_count: usize = smith.valueRangeAtMost(u8, 0, numbers_storage.len);
    for (numbers_storage[0..number_count]) |*number| number.* = smith.value(u16);
    const view = View{
        .value = input,
        .show = smith.value(bool),
        .marker = if (smith.value(bool)) smith.value(u8) else null,
        .numbers = numbers_storage[0..number_count],
    };
    try compareWithOracle(view);
}

fn compareWithOracle(view: View) !void {
    var actual_storage: [16 * 1024]u8 = undefined;
    var expected_storage: [16 * 1024]u8 = undefined;
    var actual = Writer{ .storage = &actual_storage };
    var expected = Writer{ .storage = &expected_storage };
    const result = Page.render(&actual, view, &.{});
    try oraclePrefix(&expected, view);
    if (!std.unicode.utf8ValidateSlice(view.value)) {
        try std.testing.expectError(error.InvalidUtf8, result);
        try std.testing.expectEqualStrings(expected.bytes(), actual.bytes());
        return;
    }
    try result;
    try html_render.writeValue(&expected, .html_data, view.value);
    try expected.write("|<textarea>");
    try html_render.writeValue(&expected, .rcdata, view.value);
    try expected.write("</textarea><div title=\"x='");
    try html_render.writeValue(&expected, .attribute_double_quoted, view.value);
    try expected.write("'\" data-label='y=\"");
    try html_render.writeValue(&expected, .attribute_single_quoted, view.value);
    try expected.write("\"'></div>");
    try std.testing.expectEqualStrings(expected.bytes(), actual.bytes());
}

fn oraclePrefix(writer: *Writer, view: View) !void {
    try writer.write(if (view.show) "T" else "F");
    try writer.write(if (view.marker != null) "U" else "N");
    if (view.numbers.len == 0) try writer.write("E");
    for (view.numbers, 0..) |number, index| {
        try writer.write("[");
        try html_render.writeValue(writer, .html_data, index);
        try writer.write("=");
        try html_render.writeValue(writer, .html_data, number);
        try writer.write("/");
        try html_render.writeValue(writer, .html_data, doubled(number));
        try writer.write("]");
    }
    try writer.write("|");
}
