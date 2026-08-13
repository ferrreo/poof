# Use fixed continuations for JSON traversal

Framework-owned JSON traversal never uses input-driven recursion. Planning and
typed decoding use monomorphized direct calls only when comptime analysis proves
the type graph acyclic and no more than 16 structural levels deep. The static
call graph is then bounded independently of input. Recursive or deeper type
graphs use fixed-capacity, comptime-specialized continuation frames.

Typed encoding uses a narrower direct rule. Only a top-level, non-hook record
whose fields reduce to scalars, strings, optionals, arrays, or bounded sequences
is eligible, and its wrapper graph is capped at four levels. Nested records,
unions, one-pointers, hooks, dynamic values, recursive graphs, and deeper graphs
use fixed continuation frames. Runtime sequence length changes loop iterations,
not call depth, so the accepted direct call graph is statically finite. Dynamic
values and unknown-value skipping remain iterative, with frame capacity selected
from the configured depth limit.

We chose these hybrids because recursive typed input at the supported depth of
256 used about 40 KiB while planning and 49 KiB while decoding in ReleaseSafe,
too close to the supported 64 KiB worker stack. Conversely, frame-array poison
initialization regressed the shallow `m6-input-json/json-encode` DTO from its
208.147 ns ReleaseSafe median baseline. The shallow record path measured
149.930 ns, a 28.524% improvement over that baseline; ReleaseFast measured
148.767 ns, 22.135% faster than its 189.543 ns baseline. A broader acyclic
encode path was rejected even though it was fast: it drove each release-mode
encoder test compile above 20 GiB RSS through duplicated monomorphization.
Narrowing the rule restored a sequential ReleaseSafe encoder-test compile to
376,780 KiB RSS. Matched JSON benchmarks and compile-resource checks therefore
gate both paths.

Validation, dynamic decoding, and unknown-value skipping select the smallest
fixed frame capacity that covers the configured depth: 8, 16, 32, 64, 128, or
256. This avoids poisoning the 256-frame maximum on shallow ReleaseSafe work
while retaining one hard bound. After the decoder was split into focused core,
dynamic traversal, token, and error-map modules, a single matched ReleaseSafe
run measured typed decode at 1,204.088 ns (+1.76%), dynamic decode at 1,123.200
ns (-0.11%), and encode at 147.247 ns (-29.25%) against their preserved
ReleaseSafe baselines. ReleaseFast measurements remain separate diagnostics.

Typed decoding writes through type-erased pointers and therefore requires
addressable runtime fields. Packed structs and comptime fields are rejected at
compile time with `PLOOF-E3272` and `PLOOF-E3273`; applications use an
auto-layout request DTO for those wire values. Encoding remains able to read
packed and comptime fields by value.

Synchronous `jsonParse` and `jsonStringify` hooks are the narrow exception. A
hook observes each nested parse or write result immediately and may branch or
catch on it, so deferring that call would change API semantics and value
lifetimes. Hook-to-hook calls and recursive parser or cursor typed conversion
therefore have an independent hard depth limit of 64 even when document depth
is configured to its hard maximum of 256. They share framework-owned fixed
storage where possible and are exercised on the minimum worker stack in Debug,
ReleaseSafe, and ReleaseFast.
