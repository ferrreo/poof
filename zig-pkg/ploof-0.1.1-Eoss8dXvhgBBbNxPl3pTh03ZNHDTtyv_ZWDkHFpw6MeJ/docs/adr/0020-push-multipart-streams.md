# Push multipart streams

Multipart routes use a push-based consumer rather than exposing a blocking
body reader or introducing per-request fibers. The parser will invoke bounded
callbacks for fields, file starts, file chunks, file ends, and completion. The
completion callback returns the ADR 0083 upload decision and the route's typed
Response.

Ordinary fields are delivered complete under ADR 0081; only files use chunk
callbacks.

The first shipped consumer surface initializes one concrete typed State,
delivers each complete declared field synchronously, and invokes `complete`
only after the final multipart delimiter and any outer gzip footer validate.
The synchronous `DiscardSink` consumes declared file bytes without retaining
them. M9 adds the general file-start, file-chunk, file-end, and transactional
decision surface; custom sinks remain a compile-time diagnostic until then.

M9 generates one `FileStart` tagged union whose variants are schema file names
and one matching `BeginInput` union whose payloads are each concrete sink's
input. The synchronous `fileStart` consumer receives context, state, and the
borrowed metadata event, then returns either an exactly matching accepted input,
a typed rejection response, or a declared application error. A mismatched
accepted tag is an application invariant failure, never runtime sink selection.

Chunk memory is borrowed from fixed worker-owned pools and is valid only for
the callback. A consumer may process it synchronously or submit bounded
asynchronous sink work that transfers chunk ownership to the runtime. Input is
paused when the ADR 0082 sink window is full, propagating backpressure to the
socket. Consumers may not block, retain unclaimed slices, or create unbounded
work.

Ploof does not create implicit temporary files. Client filenames remain
untrusted metadata and will never be interpreted as filesystem paths. This
preserves the run-to-completion worker model while supporting uploads larger
than available application memory.

File-versus-field classification and cardinality come from the route schema
under ADR 0075 rather than client filename metadata.
Unknown-name behavior follows ADR 0076.
Empty browser file markers follow ADR 0079.
Durable sink staging, commit, and abort follow ADR 0083.
Nested multipart payloads remain opaque under ADR 0085.
Requiredness and occurrence maxima follow ADR 0087.
