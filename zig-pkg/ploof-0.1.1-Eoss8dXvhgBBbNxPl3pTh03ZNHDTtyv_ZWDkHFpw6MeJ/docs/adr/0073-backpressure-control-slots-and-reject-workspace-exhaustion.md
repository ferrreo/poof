# Backpressure control slots and reject workspace exhaustion

Each worker has finite startup-created connection and request-control slots. If
those base slots are exhausted, the worker stops submitting accepts or further
request-head reads as applicable and leaves the kernel listen and socket queues
to apply backpressure. It resumes only when a slot returns.

Each worker has at most one single-shot accept in flight, submitted only while
a connection slot is available. A multishot accept can create accepted file
descriptors for an entire burst before userspace observes that capacity is
full, so cancellation cannot enforce the configured descriptor bound. Ploof
will use multishot accept in production only if accepted descriptors first land
in a connection-sized registered direct-descriptor table.

After a complete request head selects a route, Ploof reserves its base
application workspace. A typed endpoint also reserves its route workspace
before head middleware because that class owns the endpoint's bounded JSON
response region in every middleware phase. Legacy byte and text body routes
still defer their body-workspace lease until head processing chooses intake.
Any required chunked-decoder slot is reserved after head processing and before
intake or `100 Continue`. If a required pool has no slot, acquisition rolls
back every earlier request-specific lease, aborts the pending application
lifecycle when it began, releases the base request slot, sends a preallocated
minimal 503 response with `Connection: close`, does not send 100, does not
intake or drain the body, and closes the connection.

A prepared typed-endpoint head response that borrows this route workspace keeps
the lease through transport completion or abort. Release securely clears the
complete slot after any full-workspace exposure before returning it. That taint
is sticky across partial body commits, malformed-body rejection, and abort.
Response replacement does not shorten the lease because initialized middleware
state may retain route-workspace views through its `after` phase.

Once the full route workspace is exposed to application code, its full-clear
obligation remains sticky until release. A later partial body commit cannot
narrow that obligation, including on malformed-body rejection or abort.

Version one has no userspace workspace wait queue, cross-worker stealing, heap
fallback, or fabricated retry delay. Every worker reserves independent emergency
send descriptors and immutable overload-response bytes so a 503 never depends
on the exhausted workspace class. If even transport completion becomes
impossible, the worker closes the connection.

Counters identify worker, workspace class, and route for every rejection;
control-slot pauses and current free capacity are separately observable. Pool
capacity remains part of the comptime runtime-capacity profile and is benchmarked
under burst as well as steady load.

This uses kernel backpressure before request admission but chooses bounded
failure after a route-specific shortage is known. It prevents queued bodies
from holding scarce connection state and keeps overload work allocation-free.
