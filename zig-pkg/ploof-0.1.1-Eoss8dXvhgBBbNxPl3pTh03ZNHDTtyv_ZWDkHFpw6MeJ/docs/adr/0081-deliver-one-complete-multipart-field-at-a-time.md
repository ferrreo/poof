# Deliver one complete multipart field at a time

Ploof accumulates one ordinary multipart field through its closing boundary
before invoking the route consumer. A text-field callback receives one complete
validated UTF-8 slice; a byte-field callback receives one complete arbitrary-
byte slice. An empty field invokes its callback once with an empty slice, and
repeated names invoke ordered callbacks.

The callback slice is borrowed only for that synchronous callback. Ploof then
reuses the storage for the next ordinary field. The multipart request workspace
therefore needs capacity for the largest declared field limit, not the sum of
all field limits. The runtime may borrow already contiguous input or write into
that one startup-allocated buffer; it performs no request-time allocation.

Crossing the field limit receives 413 without a partial field callback. Version
one has no chunked ordinary-field API. Data that must be large or streamed is a
route-declared file. A consumer that needs a value later parses it into declared
request state or transfers it to explicit application-owned storage during the
callback.

This supports immediate CSRF and typed-scalar processing while preserving fixed
multipart memory independent of ordinary-field count.

Typed-scalar grammar and callback-result lifetimes follow ADR 0088.
