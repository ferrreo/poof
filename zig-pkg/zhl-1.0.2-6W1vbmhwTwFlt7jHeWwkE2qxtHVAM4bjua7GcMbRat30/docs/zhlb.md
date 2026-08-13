# zhlb v4 Binary Grammar Pack

`zhlb` is the stable binary metadata format emitted by `zhlc pack-native`.
Runtime highlighting still uses generated/static Zig modules for speed; this
format gives tools a compact grammar artifact they can inspect, cache, or ship.
`zhlc check-zhlb` validates the full payload, including rule kinds, rule string
lengths, truncation, and trailing bytes.

Layout is little-endian:

```text
u8[4] magic              "ZHLB"
u16   version            4
u16   flags              0
u32   rule_count
str16 grammar_scope
str16 display_name
str16 root_scope
rule[rule_count]
```

Each rule is:

```text
u8    kind
str16 value
str16 escape
str16 scope
u8    flags              bit 0 = nested block comment
```

`str16` fields are length-prefixed byte strings. Strings are UTF-8 by
convention; the format stores bytes and leaves validation to the compiler layer.
v4 uses 16-bit rule strings and includes dotted prefix identifier rules so
offline TextMate/Sublime conversion can retain supported regex patterns larger
than 255 bytes while native packs can encode qualified annotations.
