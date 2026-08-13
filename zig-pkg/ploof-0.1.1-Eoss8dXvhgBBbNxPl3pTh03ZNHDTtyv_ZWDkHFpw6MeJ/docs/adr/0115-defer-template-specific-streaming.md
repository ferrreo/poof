# Defer template-specific streaming

Ploof version one compiles HTML templates only into finite responses under ADR
0113. A route with a legitimately larger finite page raises its explicit render
limit. Incremental or indefinite HTML uses the existing `StreamingResponse`
contract and does not begin as a finite template that changes mode at runtime.

Version one therefore has no `streamTemplate` API, resumable template
interpreter, suspended loop or partial stack, streaming template-view lifetime,
or second helper contract. A general streaming producer owns its emitted HTML
bytes and accepts the normal streaming rule that a late application failure
after commitment can only terminate transmission and close the connection.

Adding template-specific streaming now would duplicate rendering semantics and
weaken finite templates' pre-commit UTF-8, helper-error, size, middleware, and
gzip guarantees. Reconsider it only when representative benchmarks or real
applications show that the general streaming contract is inadequate; it is not
scaffolded speculatively in version one.
