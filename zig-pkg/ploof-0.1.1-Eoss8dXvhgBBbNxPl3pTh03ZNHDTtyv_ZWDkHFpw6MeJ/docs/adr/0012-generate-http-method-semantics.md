# Generate HTTP method semantics

Ploof will derive method behavior from the comptime route graph rather than
copy Gin's defaults. A GET route also serves HEAD with response content
suppressed unless an explicit HEAD route overrides it; OPTIONS and `Allow` are
generated; a known path with a disallowed implemented method returns 405; and
an unimplemented method returns 501. This follows HTTP semantics without
runtime route discovery.

ADR 0045 defines HEAD suppression and bodyless status validation.

Server-wide `OPTIONS *` uses the generated capability behavior defined with the
request-target forms in ADR 0038; it is not a wildcard application route.

Version one's declared route methods are GET, HEAD, POST, PUT, PATCH, and
DELETE. OPTIONS is generated and cannot be registered explicitly; CONNECT and
TRACE remain unsupported. Any other admitted method receives 501 before path
lookup. Request-target admission still owns its earlier special cases, so an
invalid asterisk form receives 400 and CONNECT authority-form receives 501 and
closes before the route graph.

Selection first tries the requested method; HEAD tries an explicit HEAD route
and then the corresponding GET route. It next tries the same selection against
the alternate trailing-slash path. OPTIONS then derives path capabilities;
otherwise a path accepted by another implemented method receives 405, and an
unknown path receives 404. Deterministic `Allow` order is `GET, HEAD, POST, PUT,
PATCH, DELETE, OPTIONS`; GET contributes implicit HEAD and every known path
contributes OPTIONS. `OPTIONS *` returns the union present in the graph in that
same order. Generated OPTIONS responses are empty 204 responses.
