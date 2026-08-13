# Use phased middleware

Status: Superseded by [ADR 0023](0023-use-head-body-and-after-middleware.md).

Ploof middleware will expose optional `before` and `after` phases rather than a
call-stack continuation. Application, group, and route `before` phases run in
declaration order. A phase may short-circuit with a Response. For phases that
completed, `after` runs in reverse order with the route result, including when a
later phase short-circuits or the route fails.

Middleware may carry fixed-size typed state from `before` to `after`. The
compiler calculates each composed route's total state size and rejects chains
above the configured bound; request slots hold this state without heap
allocation.

This preserves observable onion ordering for ordinary handlers while also
working across multipart streams and other operations spanning multiple
io_uring completions. A continuation API would require a suspended call stack,
a fiber, or separate middleware semantics for streaming routes. The phased
contract avoids all three and permits authentication or other guards before
request bodies are accepted.

This decision supersedes ADR 0015's continuation-based middleware contract.
