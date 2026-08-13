# Reject URL input that requires browser repair

Raw `Url.local` and `Url.web` constructors accept only a strict ASCII URL
subset. Input must be non-empty and follow the relevant RFC 3986 component
grammar; every percent sign must begin one complete hexadecimal byte escape.
Validation rejects whitespace, C0 controls, DEL, non-ASCII bytes, backslashes,
invalid URL characters, and malformed percent escapes. Existing escapes are
never decoded, normalized, or encoded again.

`Url.web` requires an exact supported scheme and `//` authority form. Its host
must be a valid ASCII DNS or punycode name without a trailing dot, strict dotted
IPv4, or bracketed IPv6. Empty hosts, credentials, legacy numeric-IP forms,
invalid ports, and inputs that browsers repair, such as `https:example.com`, are
rejected. HTTP remains subject to ADR 0102's explicit opt-in.

Route, query, contact, and web-component builders accept valid UTF-8 component
data and percent-encode its bytes into caller-provided bounded storage. They
emit structural delimiters themselves, so component data cannot change URL
structure. Raw `/café` is therefore invalid while a builder supplied
`café` emits `/caf%C3%A9`.

Validation returns a closed error and preserves the input on success; it never
repairs, substitutes a sentinel, or silently drops a destination. This differs
from the WHATWG parser, which records many validation errors while continuing
with a repaired URL. The smaller grammar supports one allocation-free scan and
reduces browser/server parser disagreement.

The standard complete URL limit is 8 KiB, matching Ploof's standard request
target bound, and the hard comptime ceiling is 64 KiB. Web host allowlists
contain at most 64 exact validated hosts. Applications may select a tighter or
larger complete-URL limit at comptime without introducing unbounded storage.

Verification includes the WHATWG adversarial cases, mixed-case schemes,
whitespace and control insertion, raw and encoded backslashes, malformed
escapes, credentials, legacy IP spellings, IPv6 and port boundaries, exhaustive
ASCII classification, and parse/build/render fuzzing.

Sources: [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986),
[WHATWG URL parsing](https://url.spec.whatwg.org/#url-parsing).
