# Close the route graph at compile time

A Ploof application's methods, path patterns, handlers, and middleware
composition will form a closed comptime route graph. Startup may initialize
application state but will not register or mutate routes. This lets the
compiler reject conflicts, generate compact dispatch data, and establish exact
memory bounds; applications needing dynamic behavior can place it behind a
declared catch-all route.

Each route's closed body decoder table is part of this graph under ADR 0069.

Graph limits are explicit comptime application data. The standard profile
permits 512 routes, an 8 KiB complete route pattern, 256 path segments, 64
captures, 32 middleware instances per composed route, and 4 KiB of concrete
middleware state. The hard ceilings are 4,096 routes, a 1 MiB pattern, 4,096
segments, 1,024 captures, 64 middleware instances, and 64 KiB of state. An
application can replace the standard profile without changing the router API.
Only maxima actually present in the closed graph drive generated indexes and
request workspace sizing; configured ceilings do not reserve memory by
themselves.

The profile also caps aggregate graph construction and worst-case selection.
Standard limits are 65,536 total route segments, 4 MiB total pattern bytes,
16,384 index nodes, 1,024 node visits per search, and 256 KiB of literal bytes
compared per search. Hard ceilings are respectively 1,048,576, 64 MiB,
262,144, 16,384, and 8 MiB. Compilation reports both computed and configured
values when an exact graph exceeds one of these bounds. Applications raise or
lower them through `Application(.{ .graph_limits = .{ ... } })`; no runtime
fallback or partial graph is created.

Runtime selection uses one comptime-built structural trie shared by all
methods. Each node owns a fixed method table, sorted literal children, and at
most one parameter and catch-all child. Selection tokenizes the path once,
binary-searches literal siblings, and explores structural overlaps from a
bounded caller-owned frame array. HEAD fallback and trailing-slash handling
perform at most three searches; the application publishes exact single-search
and full-selection visit and compared-byte bounds. The index is sized from the
exact graph and allocates no runtime storage.

Each worker owns one route-search workspace created before readiness. A plan
contains route identity and capture count, not pointers into that workspace, so
another search may reuse it before middleware or body processing continues.
Capture names and path spans are replayed linearly into the request slot only
when the plan is materialized. This keeps maximum-depth search state off the
thread stack and avoids reserving maximum capture storage in the plan. Replay
validates route metadata, literals, path shape, exact consumption, and capture
bounds in every optimization mode; a forged or mismatched plan returns
`InvalidRoutePlan` rather than relying on debug-only assertions.
