# Require an explicit FileSink durability mode

Every `FileSink` configuration must select `.buffered` or `.crash_durable`;
there is no default. Route composition fails at comptime when the choice is
absent, and the startup memory/configuration report names the selected mode for
each sink.

Each compiled `Application` exposes the fixed
`upload_file_sink_configurations` array. Records follow unique sink-registry
order and contain the registry index plus the sink's `FileSinkReport`.
`startup.configurationReport(App)` returns a borrowed slice over that array; it
does not allocate or copy sink records. Custom sinks without a
`FileSinkReport` remain valid registry entries and are omitted from this
FileSink-specific view, so later reported FileSinks retain their actual registry
indexes.

The public configuration represents that requirement as an optional field only
so omission can produce Ploof's stable compile diagnostic. A resolved
`FileSink` type never retains an optional durability mode.

`.buffered` waits for complete io_uring writes and atomic no-replace publication
but issues no `fsync`. Successful response means the file was logically
committed and visible through the filesystem. It does not mean recent file data
or namespace changes survive a machine crash or power loss. This is the fast
behavior closest to Gin and Multer disk helpers.

`.crash_durable` runs `fsync` on the staged file before publication, publishes
it, then runs `fsync` on every directory whose entries changed. Anonymous
staging changes only the destination parent. Named staging can require both its
configured staging directory and a distinct destination parent. Response
commitment waits for the complete sequence.

Abort and compensation in crash-durable mode also synchronize every directory
after removing a named staging or destination entry. Any synchronization error
is a sink failure and follows ADR 0093 cleanup and central 500 handling. Ploof
does not offer a file-only or `fdatasync` middle mode because a synchronized
inode does not by itself guarantee persistence of its directory entry.

Buffered and crash-durable upload benchmarks, latency histograms, and failure
tests remain separate. This prevents fast buffered numbers from being reported
as durable storage performance and makes the latency/data-loss tradeoff an
application decision.

Source: [`fsync(2)`](https://www.man7.org/linux/man-pages/man2/fsync.2.html).
