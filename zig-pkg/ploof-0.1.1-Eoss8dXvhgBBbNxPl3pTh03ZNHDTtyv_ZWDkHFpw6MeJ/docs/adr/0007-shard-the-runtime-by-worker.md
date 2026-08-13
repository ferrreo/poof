# Shard the runtime by worker

Ploof will use a fixed number of worker shards chosen at startup. Each worker
owns one OS thread, one `io_uring`, its connections, and its preallocated
buffers; workers share only immutable application metadata. Listeners use
`SO_REUSEPORT`, and version one will not add work stealing or shared hot-path
queues. Rings sleep when idle rather than using `SQPOLL` by default, preserving
low idle CPU usage.

Per-worker workspace exhaustion follows ADR 0073 and does not add stealing.
