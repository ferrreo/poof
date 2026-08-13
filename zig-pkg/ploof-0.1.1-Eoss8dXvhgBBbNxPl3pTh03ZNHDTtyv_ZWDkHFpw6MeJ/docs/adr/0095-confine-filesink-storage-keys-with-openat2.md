# Confine FileSink storage keys with openat2

`FileSink` accepts a non-empty `StorageKey` with a finite sink-configured byte
maximum from one through 4,095 bytes, leaving the required NUL inside Linux's
4,096-byte syscall pathname bound. Construction validates UTF-8 and rejects
Unicode C0/C1 controls,
absolute paths, NUL, empty path components, repeated or trailing slashes, and
components exactly equal to `.` or `..`. Other bytes, including non-ASCII text
and leading dots inside a longer component, are preserved exactly. Ploof does
not normalize Unicode or rewrite components.

The key is copied into fixed sink state during file start because its source can
be callback-borrowed. Ploof never logs the raw value or adds it to metrics. A
`ClientFilename` does not implicitly convert to `StorageKey`; application code
must construct a key through the validating API.

Zig struct fields are publicly mutable, so type identity is not accepted as
proof that a key still contains constructor-validated bytes. `FileSink.begin`
revalidates the exact current length and bytes, copies them into its own fixed
state, and writes a fresh NUL sentinel before returning any I/O request.

For a nested key, `FileSink` opens the parent relative to its startup root FD
with io_uring `openat2` and `RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`,
`RESOLVE_NO_MAGICLINKS`, and `RESOLVE_NO_XDEV`. It keeps that resolved parent
directory FD through staging finalization. Flat keys use the already-open root.
Final commit addresses only the validated basename relative to that FD.
The worker opens that root once from the explicit working-directory bootstrap
base; request-time key resolution never falls back to the process directory.

All directories must already exist. Symlinks, magic links, bind mounts, and
other nested mount crossings are rejected; an application configures another
`FileSink` root when it intends to use another mounted filesystem. This keeps
staging and destination on one validated filesystem and prevents path lookup
races or root escape even if a key was derived from untrusted application data.

Nested keys cost one additional open operation and retained directory FD. The
kernel still enforces filesystem-specific component and path limits in addition
to Ploof's memory bound.

File staging remains on this validated filesystem under ADR 0096.

Source: [`openat2(2)`](https://www.man7.org/linux/man-pages/man2/openat2.2.html).
