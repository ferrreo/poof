# Create trusted resource URLs only from application input

`TrustedResourceUrl.literal` accepts a comptime root-relative or absolute HTTPS
resource that satisfies ADR 0103's strict grammar. Applications may instead
declare a finite startup resource table, but each entry must match a comptime
origin allowlist, is validated once before listeners start, and is retained in
startup-owned memory. Failure names the configured resource and validation
reason and stops startup.

There is no per-request constructor or conversion from `Url`. Request,
database, and template-view values cannot choose or append an active-resource
path, authority, query, or fragment. `AssetRef` remains the ordinary mechanism
for Ploof-hosted CSS and JavaScript. An HTTP active resource requires an
explicit development policy; production external resources use HTTPS.

The startup table is keyed by one exhaustive enum with at most 256 members and
accepts at most 64 exact HTTPS origins. Each entry has an explicit comptime
byte limit no larger than the 64 KiB URL hard ceiling. The table owns fixed
storage and exposes an opaque pointer capability, so copying public fields or
constructing a runtime struct cannot forge trusted-resource provenance.

This type records application control, not merely valid URL syntax. A URL safe
for navigation can still return attacker-controlled JavaScript or CSS, so
syntax validation can never promote it. The boundary means external resource
configuration changes require restart and user-selected themes cannot inject
active resources, but request data cannot become browser-loaded code.

Source: [Google SafeHTML `URL` and `TrustedResourceURL`](https://pkg.go.dev/github.com/google/safehtml).
