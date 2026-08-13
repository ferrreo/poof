# Use bounded onion middleware

Status: Superseded by [ADR 0022](0022-use-phased-middleware.md).

Ploof will support application, group, and route middleware as a compile-time-
closed chain. Middleware explicitly invokes the next continuation to descend;
code after that call runs while the chain unwinds. Completing a response
without invoking next short-circuits the chain. Each composed route will have a
fixed compile-time maximum depth and will allocate no middleware state per
request.

The implementation may use direct comptime composition or a bounded dispatch
representation. Assembly inspection and sigbench measurements on Zig 0.16 will
choose between them before the public API freezes; the execution semantics do
not depend on that choice.
