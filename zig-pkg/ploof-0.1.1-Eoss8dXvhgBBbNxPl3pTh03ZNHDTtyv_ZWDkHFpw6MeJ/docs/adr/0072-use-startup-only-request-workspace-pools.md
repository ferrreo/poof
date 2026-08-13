# Use startup-only request workspace pools

After successful startup, Ploof's request path makes no general allocator,
reallocation, or virtual-memory calls. The closed route graph computes the
maximum framework workspace required by each body decoder and typed binder.
Startup creates finite per-worker size-class pools and maps each route to a
sufficient class. Body chunks, transformed values, collection backing, pair
tables requested by raw views, contiguous-body variants, JSON parse storage,
and transformed flat-input values all come from these pools.

Concrete staged upload-sink state and its maximum occurrence layout follow ADR
0089 and are included in each multipart route's workspace class.
Poller and pending-write state follow ADR 0092.

A request leases a workspace slot and resets it as a unit. Scalars and fixed
layouts occupy generated offsets. Binders borrow unchanged contiguous input
where possible and write unavoidable percent-decoded or cross-chunk copies
directly into the slot. A scalar-only flat schema can bind in one pass. A schema
with variable collections or transformed slices first counts and computes
offsets, then performs a second bounded pass; it does not allocate per value.
Custom text hooks receive only borrowed input under ADR 0065.

Workspace slots exist only for active operations that need them, not for every
open connection, and a route maximum is not reserved independently for every
request. Pool capacities and byte bounds belong to one explicit comptime
runtime-capacity profile. Startup creates or accepts the corresponding concrete
storage, reports its per-worker and process-wide memory budget for the selected
worker count, and fails with a clear error when that fixed budget cannot be
created. Changing capacities recompiles the application; request-time data and
startup flags cannot resize a typed slab or ring.

The standard M4 profile has 128 connection slots, 64 request slots, and 64
16 KiB provided receive buffers. It reserves 16 KiB of pipeline storage per
connection and 72 KiB of response storage per request. That response capacity
holds the checked gzip bound for a 48 KiB body after the standard maximum head.
On Linux x86_64 with the standard `/ping` application, the exact report is
16,299,864 bytes (15.54 MiB) per worker, including page-rounded framework
mappings. Response-trailer negotiation adds eight aligned bytes to each of the
64 request records, accounting for 512 bytes of that report. These are
defaults, not hidden limits: an application replaces any field in its comptime
profile and the same report and validation apply to the resulting concrete
types.

The standard M5 profile has one decoded-body workspace slot and one separate
chunked-decoder workspace slot per worker. A body-enabled Zig 0.16 x86_64 build
uses 9,736 bytes for each chunked slot by reusing one union across chunk and
trailer phases; a bodyless application instantiates neither storage region, so
the `/ping` report above remains unchanged. Both capacities are explicit
comptime limits and cannot exceed request or body-workspace capacity.

Pool exhaustion never falls back to the heap and follows ADR 0073. Before a slot
can serve another request, Ploof clears every used request-owned byte range and
resets all cursors and descriptors.

Any phase that exposes the complete route workspace sets a sticky full-slot
taint. Later body-prefix commits cannot narrow that taint; rejection, abort,
normal completion, and unused-lease release all clear the complete slot before
pool reuse. A body-only writer that never receives the full workspace may keep
the narrower committed-prefix clear policy.

This trades baseline RSS, fixed burst capacity, possible size-class
fragmentation, and occasional two-pass binding for predictable memory, normal
slice ergonomics, and zero framework allocator calls on the hot path. A strict
zero-copy API would instead require segmented decoded-text types throughout
handlers and dependencies.
