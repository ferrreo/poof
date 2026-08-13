# Ship a first-party filesystem upload sink

Ploof version one ships a concrete `FileSink` for staged filesystem uploads. It
implements the same ADR 0092 poll contract exposed to applications; built-in
code gets no private sink interface or raw-ring escape. Unit, integration,
failure-injection, and sigbench upload cases exercise this sink so the public
extension seam remains production-tested.

The public construction is one comptime configuration:

```zig
const Uploads = ploof.Multipart.FileSink(.{
    .root = "/var/lib/example/uploads",
    .durability = .buffered,
});
```

`root` and `durability` are required. `durability` has no default. The storage
key maximum defaults to 256 bytes and remains directly configurable with
`storage_key_bytes_max` up to Linux's 4,095-byte pathname payload; staging
defaults to `.anonymous_required`; and the created-file mode defaults to
`0600`. Named compatibility staging is selected with
`.staging = .{ .named_staging = "relative/pre-existing-directory" }`.
Configuration is validated at comptime and materialized as sentinel-terminated
static paths.

`FileSink` opens and validates its configured root directory during startup. A
file-start application function supplies a bounded server-side `StorageKey`.
The type does not accept `ClientFilename` as a destination, and Ploof never
converts client filename metadata into a path or extension automatically.

The sink stages bytes on the destination filesystem, submits writes through
Ploof's io_uring-backed normalized I/O seam, and participates in ADR 0083
commit and abort. Commit does not overwrite an existing destination. Abort
removes staging state. New files use mode `0600` unless sink configuration
explicitly chooses another mode.

`FileSink.BeginInput` is its bounded `StorageKey`. Its completion summary is a
request-scoped view of the canonical key plus the exact byte count. The view
borrows the address-stable sink state instead of copying the maximum-sized key
into a second fixed buffer; it must not outlive the request workspace.

Destination directories must exist before request handling. `FileSink` does not
create directories, allocate paths, or invoke a general allocator on the hot
path. Storage-key syntax, secure path resolution, staging fallback, and crash
durability are defined separately.

Storage-key syntax and beneath-root resolution follow ADR 0095.
Anonymous and named staging behavior follows ADR 0096.
Crash-durability behavior follows ADR 0097.

This provides the disk-upload convenience expected by Gin and Multer users
without copying Gin's application-path write or requiring every application to
reimplement asynchronous staging and rollback.

Sources: [Gin `SaveUploadedFile`](https://github.com/gin-gonic/gin/blob/v1.12.0/context.go)
and [Multer `DiskStorage`](https://expressjs.com/en/resources/middleware/multer/#diskstorage).
