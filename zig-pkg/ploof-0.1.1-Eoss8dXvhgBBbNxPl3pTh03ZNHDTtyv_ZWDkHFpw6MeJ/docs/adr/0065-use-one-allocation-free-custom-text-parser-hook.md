# Use one allocation-free custom text parser hook

A destination type can define one comptime-checked `parseText` hook for custom
query, URL-encoded form, and multipart text-field scalar conversion:

```zig
pub fn parseText(input: []const u8) TextDecodeError!@This()
```

The source-neutral hook consumes exactly one already decoded and UTF-8 validated
value. Query and URL-encoded input storage is stable for the request lifetime;
multipart input and borrowed results use ADR 0088's callback-only lifetime. The
result must be inline or contain slices that borrow that input; the hook receives
no allocator, scratch span, request, I/O, or mutable application context.

`TextDecodeError` is a closed framework error set. Invalid syntax,
representation, or range produces the same safe 400 response as built-in
conversion. The hook cannot return application failures. Semantic validation
and transformations requiring owned or expanded bytes remain explicit handler
or middleware work.

Hook presence, signature, error set, and result type are verified at comptime.
Ploof does not discover arbitrary similarly named functions or expose an
unchecked raw-parser path. An application wraps an external type it cannot
modify. Each occurrence in a slice or array invokes the same specialization;
borrowed results expire with the request workspace.

This supports UUIDs, timestamps, hashes, and domain identifiers without runtime
registration, custom scratch capacity, or request-time allocation.
