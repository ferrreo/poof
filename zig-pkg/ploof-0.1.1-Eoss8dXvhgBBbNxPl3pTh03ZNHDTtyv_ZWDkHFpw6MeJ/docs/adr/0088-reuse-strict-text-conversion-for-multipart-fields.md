# Reuse strict text conversion for multipart fields

A multipart `.field(T)` applies the same comptime-specialized conversion grammar
as typed query and URL-encoded form values under ADR 0064. Built-in integers,
floats, booleans, enums, and text accept exactly the same spellings, and custom
domain values use the single `parseText` hook from ADR 0065. Ploof validates the
field's ADR 0080 text media and UTF-8 rules before conversion.

Conversion completes before the field callback. Failure receives the standard
safe typed-binding 400 response without invoking that callback or trying another
interpretation. Repeated fields invoke one typed callback per admitted
occurrence in global wire order.

Inline results can be copied directly into the consumer's fixed request state.
A text slice or custom value that borrows its input remains valid only for the
synchronous callback because ADR 0081 then reuses the ordinary-field buffer.
Ploof does not construct a retained multipart DTO or copy borrowed values behind
the application.

A `.bytes_field` remains one arbitrary borrowed byte slice and performs no text
or custom scalar conversion. Applications needing a byte-domain parser call it
explicitly during the callback.

This gives query, URL-encoded form, and multipart text fields one conversion
language without increasing multipart workspace from the largest field to the
sum of all fields.
