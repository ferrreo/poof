const regex_classes = @import("classes.zig");
const regex_types = @import("types.zig");
const regex_unicode = @import("unicode.zig");

pub const Error = error{UnsupportedRegex};

pub fn parseFastAtom(pattern: []const u8, index: *usize, negated: bool) Error!regex_types.Atom {
    var atom = regex_types.Atom{ .kind = .byte_class, .class_negated = negated };
    if (regex_unicode.propertyName(pattern[index.* + 1 ..])) |property| {
        if (regex_unicode.isWordProperty(property.name)) {
            atom.class_negated = false;
            if (negated) {
                regex_classes.addInverseEscape(&atom.class_mask, 'W');
                regex_classes.clearHighBytes(&atom.class_mask);
            } else {
                regex_classes.addEscape(&atom.class_mask, 'w');
                atom.class_scalar_high = true;
            }
            index.* += property.consumed;
            return atom;
        }
    }
    try addUnicodeProperty(&atom.class_mask, pattern, index, false);
    index.* -= 1;
    return atom;
}

fn addUnicodeProperty(mask: *[4]u64, pattern: []const u8, index: *usize, negated: bool) Error!void {
    const consumed = regex_classes.addUnicodePropertyToken(mask, pattern[index.* + 1 ..], negated) orelse return error.UnsupportedRegex;
    index.* += consumed + 1;
}
