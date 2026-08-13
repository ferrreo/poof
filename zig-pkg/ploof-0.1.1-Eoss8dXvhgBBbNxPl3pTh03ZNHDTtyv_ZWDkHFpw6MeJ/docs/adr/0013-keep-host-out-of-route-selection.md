# Keep host out of route selection

Ploof version one will select behavior from HTTP method and path only. The
request's effective host will be validated once under the listener's explicit
proxy-trust policy and exposed as typed request metadata. Deployments needing
virtual-host separation should route domains at the edge proxy or onto separate
listeners or processes. This keeps the comptime route graph smaller and avoids
host checks on every request while leaving room for a later outer comptime
domain scope if applications demonstrate the need.

An absolute-form request target is accepted only when its normalized authority
agrees with this validated effective host, as recorded in ADR 0038.
