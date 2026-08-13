# Render finite HTML once into shared response chunks

A finite HTML response renders exactly once into the same startup-allocated,
worker-owned response chunks used by ADR 0051 JSON. Chunks are leased
incrementally and linked in output order; rendering performs no contiguous-body
allocation, growth copy, counting pass, socket write, cross-worker steal, or
general allocator call. The completed chain becomes the finite `Response` seen
by response middleware.

The standard encoded HTML limit is 1 MiB per route and is replaceable at
comptime. Raising it does not reserve that amount for every request. Every
literal, escaped value, helper result, partial, inline asset, and browser data
block counts toward the checked total. Crossing the route limit discards the
complete partial chain and returns `ResponseBodyTooLarge` before commitment.

ADR 0109's render-operation counter is allocated as one stack `u32`; it adds no
workspace, heap allocation, or per-node state. Every directive and `each`
iteration checks and decrements that shared counter before doing its work.
`RenderWorkExhausted` is a reserved framework render failure, not an
application helper error. Production rendering aborts and clears every staged
chunk, bypasses the application-error mapper, and emits the closed framework
500 before any HTML is committed.

If the worker response-chunk pool is exhausted, Ploof discards the partial
chain, returns its preallocated 503 with connection closure, and records the
route, required chunks, and pool high-water mark. It never falls back to the
heap, waits in a userspace queue, or sends partial HTML. Written chunk ranges
are cleared before another request leases them.

Successful identity output sums chunk lengths for an exact `Content-Length`.
Gzip remains the existing post-middleware response-coding stage. Chunk size and
pool capacity belong to the comptime runtime-capacity profile selected with
representative benchmarks; both appear in the startup memory report. Large or
incremental HTML requires a separate explicit streaming response rather than
an automatic mode change.

M11 Sigbench cases cover static-heavy, escape-heavy, loop and partial,
JSON-block, and the exact 1 MiB default boundary under identity and gzip. M12
extends the same matrix with real `AssetRef` inline-asset paths after ADR 0099
and ADR 0120 land; M11 does not fabricate an asset substitute. Sigbench records
throughput, tail latency, cycles and instructions per byte, branches, cache
misses, and process memory. Its deterministic companion records chunk count,
copied bytes, reserved gzip chunks, pool high-water, rejection rate, framework
allocations, and gzip peak memory. Contiguous and two-pass prototypes remain
benchmark baselines, not alternate public behaviors.
The typed loop-and-partial case also records the per-operation budget-check
cost in both ReleaseSafe and ReleaseFast.
