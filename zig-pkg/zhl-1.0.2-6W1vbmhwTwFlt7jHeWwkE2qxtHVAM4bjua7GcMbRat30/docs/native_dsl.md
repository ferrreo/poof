# Native zhl Grammar DSL

`zhlc` native grammars are line-oriented declarations. The v1 grammar compiler
maps them to native runtime matchers, not interpreted TextMate/Sublime files at
highlight time. Simple regex rules are compiled up front; regex-VM
rules stay in native `.zhl` when they cannot be lowered without changing
semantics.

```zhl
grammar "source.zig" {
    name "Zig 0.16";
    scope root = "source.zig";

    context main {
        line_comment "///" scope "comment.line.documentation.zig";
        block_comment "/*" "*/" nested scope "comment.block.zig";
        line_comment "//!" scope "comment.line.documentation.container.zig";
        line_comment "//" scope "comment.line.double-slash.zig";
        string "\"" escape "\\" scope "string.quoted.double.zig";
        char "'" escape "\\" scope "constant.character.zig";
        multiline_prefix "\\\\" scope "string.quoted.multiline.zig";
        dotted_prefix_identifier "@" scope "entity.name.function.decorator.zig";
        builtin_prefix "@" scope "support.function.builtin.zig";
        number generic scope "constant.numeric.zig";
        keywords "const var fn return" scope "keyword.control.zig";
        regex "@[A-Za-z_][A-Za-z0-9_]*" scope "support.function.builtin.zig";
        regex_vm "(?<!\\w)(?:void|int)(?!\\w)" scope "storage.type.zig";
        regex_capture "(const) (name)" capture 2 scope "variable.other.zig";
        regex_vm_after_line_block "^#if 0\\b" "(?=^#endif\\b)" scope "comment.block.zig";
        dynamic_block "<<([A-Z]+)" "^\\1$" scope "string.unquoted.heredoc.zig";
        operators "== != => = + - * / ; , ( ) { }" scope "keyword.operator.zig";
        function_call scope "entity.name.function.zig";
    }
}
```

Supported core declarations:

- `grammar "scope.name" {`
- `name "Display Name";`
- `scope root = "scope.name";`
- `context name {`
- `line_comment "prefix" scope "scope.name";`
- `regex_line_comment "open_regex" scope "scope.name";`
- `regex_vm_line_comment "open_regex" scope "scope.name";`
- `block_comment "open" "close" scope "scope.name";`
- `block_comment "open" "close" nested scope "scope.name";`
- `regex_block_comment "open_regex" "close" scope "scope.name";`
- `regex_vm_after_line_block "open_regex" "end_regex" scope "scope.name";`
- `dynamic_block "open_regex" "dynamic_end" scope "scope.name";`
- `string "open" escape "\\" scope "scope.name";`
- `delimited "open" "close" escape "\\" scope "scope.name";`
- `marker_string "prefix" escape "\"#" scope "scope.name";`
- `char "'" escape "\\" scope "scope.name";`
- `multiline_prefix "prefix" scope "scope.name";`
- `builtin_prefix "prefix" scope "scope.name";`
- `prefix_identifier "prefix" scope "scope.name";`
- `dotted_prefix_identifier "prefix" scope "scope.name";`
- `number profile_name scope "scope.name";`
- `keywords "word list" scope "scope.name";`
- `regex "pattern" scope "scope.name";`
- `regex_vm "pattern" scope "scope.name";`
- `regex_capture "pattern" capture N scope "scope.name";`
- `regex_vm_capture "pattern" capture N scope "scope.name";`
- `operators "op list" scope "scope.name";`
- `function_call scope "scope.name";`
- `capitalized_identifier scope "scope.name";`
- `identifier_before "delimiter" scope "scope.name";`
- `identifier_after "delimiter" scope "scope.name";`
- `quoted_key_before "delimiter" scope "scope.name";`

Escapes in quoted strings: `\\`, `\"`, `\'`, `\n`, `\t`.

Keyword and operator sets are stored in the `.zhl` grammar. The runtime has no
language-named keyword tables or language-specific execution paths.

`dotted_prefix_identifier` matches a literal prefix plus an ASCII identifier
path separated by dots, for annotation-like names such as `@pkg.Name`.

`regex_line_comment` and `regex_vm_line_comment` match an opener at the current
byte, then highlight through the end of the line. The VM form is for supported
regex patterns that cannot compile to the fast native matcher.

`delimited` matches an asymmetric single-line string-like span with distinct
open and close delimiters plus an escape marker.

`marker_string` matches strings that start with `prefix`, followed by zero or
more marker bytes and a delimiter byte, then close on the same delimiter plus
the same marker count. In `escape "\"#"`, `"` is the delimiter and `#` is the
marker.

`regex_block_comment` matches a native-regex opener at the current byte, then
uses a literal close marker and the same multiline state as `block_comment`.

`regex_capture` and `regex_vm_capture` match the full pattern but emit only the
requested capture group with the rule scope. Bytes before and after the capture
inside the match are emitted as plain text.

`regex_vm_after_line_block` matches an opener on the current line, leaves that
line to ordinary rules, then emits following lines with the rule scope until the
end regex matches.

`dynamic_block` matches a regex opener, stores one captured delimiter marker,
then closes on supported TextMate-style dynamic end patterns such as `^\1$`.
