# Use a custom io_uring reactor

Ploof will use a fixed-capacity Linux reactor built directly on
`std.os.linux.IoUring` with Zig 0.16.0. Server code above the reactor will use a
narrow internal contract for accepting, receiving, sending, timing out, and
canceling work so a production-ready `std.Io.Evented` backend can replace it
later. We are not using `std.Io.Evented` initially because its `Io.Uring`
backend does not yet implement networking and lacks the error handling, test
coverage, and small task stacks required by Ploof.

`io_uring` is required. Startup will probe every required capability and stop
with an actionable diagnostic when setup, policy, or opcode support is missing;
Ploof will not silently select another reactor.
