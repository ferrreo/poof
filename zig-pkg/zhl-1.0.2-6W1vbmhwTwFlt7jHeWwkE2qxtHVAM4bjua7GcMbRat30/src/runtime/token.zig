const style = @import("../theme/style.zig");

pub const StyleId = style.StyleId;
pub const ScopeStackId = style.ScopeStackId;
pub const LanguageId = u16;
pub const no_language: LanguageId = 0;

pub const Token = struct {
    start: u32,
    end: u32,
    style_id: StyleId,
    scope_stack_id: ScopeStackId = .none,
    language_id: LanguageId = no_language,

    pub fn len(self: Token) u32 {
        return self.end - self.start;
    }
};

pub const PackedToken = packed struct(u64) {
    start: u32,
    style_id: u16,
    flags: u16,
};
