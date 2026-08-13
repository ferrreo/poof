pub const max_captures = 64;

pub const Flags = struct {
    ignore_case: bool = false,
    dot_matches_line_break: bool = false,
    extended: bool = false,
    ascii_digit: bool = false,
    ascii_word: bool = false,
    ascii_space: bool = false,
    ascii_posix: bool = false,
};

pub const MatchState = struct { pos: usize, limit: usize };
pub const Capture = struct { start: usize = 0, end: usize = 0, set: bool = false };
pub const Match = struct { start: usize, end: usize };
pub const CompileError = error{ PatternTooLarge, UnsupportedRegex };
pub const MatchError = error{RegexStepLimitExceeded};
