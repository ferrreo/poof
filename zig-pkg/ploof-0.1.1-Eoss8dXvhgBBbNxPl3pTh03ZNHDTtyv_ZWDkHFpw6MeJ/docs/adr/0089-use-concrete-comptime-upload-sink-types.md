# Use concrete comptime upload sink types

Every `.file` multipart schema entry names one concrete sink type and its
comptime configuration. Route generation verifies the ADR 0083 lifecycle
surface and computes the type's size, alignment, and maximum occurrence count.
The request workspace contains fixed storage for every sink instance that can
remain staged until the upload transaction ends.

The public sink contract has no boxed interface, allocator, runtime registry,
`anyopaque` state, or application-facing vtable. Runtime resources such as file
descriptors, service clients, destination identifiers, and policy values remain
ordinary fields in the concrete configuration or request-local sink state.

An application that must choose a backend at runtime defines one concrete
wrapper sink with a tagged union and explicit dispatch. Ploof does not discover
plugins or erase backend types. This keeps runtime selection possible while
making its memory and branch cost visible in application code.

How generated framework code dispatches among schema entries is an internal,
benchmark-selected implementation detail. A dense switch, specialized table,
or another representation can change without changing the public sink API.
Compilation time, binary text size, and instruction-cache behavior are measured
alongside request throughput before changing that representation.

Version one generates one request-only tagged adapter per multipart schema. Its
state variants contain exact pointers into typed per-entry arrays, and its
write variants contain one exact sink `WriteState` payload per window slot. The
adapter dispatches inline to a worker-owned registry of already-started concrete
sink runtimes. It does not fake `runtimeStart` or `runtimeStop`; every underlying
public sink is validated against the complete contract before adapter
generation. The registry and adapter remain internal implementation details,
not a boxed public extension surface.

This trades compile time, generated code size, and explicit union code for
known memory, comptime diagnostics, specialization, and no hot-path polymorphic
allocation.

The concrete type's asynchronous method contract follows ADR 0092.
The built-in `FileSink` follows this same public contract under ADR 0094.

## Bound generated multipart-file dispatch

The overall application graph still permits 4,096 routes. At most 512 of those
routes may declare a multipart `File` variant, including discard-only and
synchronous file sinks. The public bound is
`Multipart.multipart_file_routes_hard_max`. Applications above it fail at
comptime with `PLOOF-E3536 multipart file route count exceeds 512`.

Route generation flattens multipart file route IDs and handler types once. The
typed operation dispatcher uses a balanced decision tree, giving at most nine
split branches plus one leaf identity check at the 512-route bound. Multipart
classification remains independent: dense storage uses one byte per application
route, while sparse storage uses sorted route/class pairs and binary search. Its
comptime evaluation quota is 256 branches per overall route, derived from the
4,096-route hard bound as 1,048,576 rather than copied as an unrelated magic
value.

The following Zig 0.16.0 ReleaseFast x86_64-v3 measurements predate the
`completeCanceledSubmission` hook. They used the previous sixteen typed upload
operations plus combined multipart classification unless the row says
otherwise; they remain representation-selection evidence, not a current
seventeen-operation release gate:

| Shape | Compile | Peak RSS | `.text` | Object |
| --- | ---: | ---: | ---: | ---: |
| 1 route, shared handler | 1.193 s | 198,060 KiB | 20,706 B | 562,864 B |
| 512 routes, shared handler | 14.798 s | 607,080 KiB | 111,344 B | 8,010,400 B |
| 4,096 routes, shared handler | 126.217 s | 3,488,180 KiB | 617,809 B | 70,538,208 B |
| 512 routes, unique handlers | 108.190 s | 2,411,948 KiB | 1,596,978 B | 63,640,848 B |
| 4,096 unique handlers, two operations only | 77.344 s | 2,178,948 KiB | 101,346 B | 12,968,392 B |

The 4,096-route shared-handler result proves the classifier scale, not a
4,096-unique-handler all-operation intersection. That unmeasured combination
extrapolates poorly from the exact 512 intersection, so version one exposes the
512 multipart-file-route bound instead of claiming unsupported compile and
binary-size behavior. Retained sigbench cases measure dense classification at
1, 512, and 4,096 overall routes. Current typed `peekSubmission` cases use
volatile runtime route IDs at the first, middle, and last positions of a
512-file-route graph, plus a stride-257 case that visits all 512 IDs. Both
ReleaseSafe and ReleaseFast run the same cases.

A local unpinned 100-sample sigbench run produced these point estimates. They
validate the retained cases and ReleaseSafe/ReleaseFast parity; they are not a
dedicated-host regression baseline:

| Current case | ReleaseSafe | ReleaseFast |
| --- | ---: | ---: |
| Dense classification, 1 route | 0.181 ns | 0.180 ns |
| Dense classification, 512 routes | 1.652 ns | 1.619 ns |
| Dense classification, 4,096 routes | 1.617 ns | 1.620 ns |
| Typed operation, first route | 31.681 ns | 32.563 ns |
| Typed operation, middle route | 31.253 ns | 31.523 ns |
| Typed operation, last route | 31.523 ns | 31.641 ns |
| Typed operation, all routes | 32.530 ns | 32.191 ns |

The raw samples, estimates, reports, and plots are emitted by the standard
benchmark commands under `zig-out/sigbench/m9-dispatch-final/release-safe` and
the corresponding `release-fast` directory when that output is selected.
