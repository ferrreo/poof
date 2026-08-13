# Support negotiated streaming response trailers

Ploof supports response trailers only for streaming HTTP/1.1 responses framed
with chunked transfer coding. A streaming response declares every possible
trailer name before committing its response head and supplies the corresponding
values when body production completes. Buffered responses put metadata in
ordinary response headers instead.

Ploof emits declared trailers only when the request validly advertises
`TE: trailers`. The handler can inspect this negotiated capability before
choosing its response metadata. Without it, Ploof omits trailers; applications
must put information required to interpret or validate a response in its
headers or body because an edge proxy or other intermediary can discard
trailers.

Ploof parses every physical `TE` field as one combined RFC list. The bare,
case-insensitive `trailers` member negotiates trailers; parameters on that
reserved member and malformed coding preferences receive 400 and close.
Syntactically valid unsupported coding preferences are ignored. A missing
`Connection: TE` does not invalidate the capability: that connection option is
a sender and forwarding obligation which an edge proxy can consume before
origin delivery.

The standard response-trailer limits are 8 KiB for the complete trailer
section, 4 KiB for one field line, 32 declared names, and 32 physical fields.
They are configurable at comptime up to the response-head ceilings. Field names
whose semantics forbid trailer placement are rejected at comptime when static
and before the terminal chunk when supplied dynamically. If body production
does not complete, Ploof cannot send a successful terminal trailer section.

The same trailer profile validates the declaration count before response-head
commitment and the physical field, line, and section limits before the terminal
chunk. Without negotiation, head commitment returns an empty, non-emitting
`TrailerPlan` that permits no terminal trailer fields. When the declaration is
emitted, the returned bounded plan borrows declaration storage through stream
completion; storage remains immutable, and terminal emission rechecks its
canonical fingerprint instead of accepting replacement names. Version one's
forbidden-name table is `Content-Length`,
`Transfer-Encoding`, `Trailer`, `Connection`, `Keep-Alive`,
`Proxy-Connection`, `TE`, `Upgrade`, `Date`, `Server`, `Via`, `Alt-Svc`,
`Content-Type`, `Content-Encoding`, `Content-Range`, `Set-Cookie`,
`WWW-Authenticate`, `Proxy-Authenticate`, `Authentication-Info`, `Location`,
`Retry-After`, `Vary`, `Cache-Control`, and `Expires`. Known singleton fields
such as `ETag` and `Last-Modified` cannot occur twice; list-based and unknown
extension fields retain ordered physical duplicates.

The erased stream retains the response's borrowed declaration slice through
completion. Producer completion returns an ordered borrowed slice of terminal
fields; the transport consumes it before producer join and Workspace clearing.
Exact-length streams expose neither declarations nor terminal fields.

Sources: [RFC 9110 trailer fields][rfc-trailers], [RFC 9110 TE][rfc-te], and
[nginx response-trailer forwarding][nginx-trailers].

[rfc-trailers]: https://www.rfc-editor.org/rfc/rfc9110.html#section-6.5.1
[rfc-te]: https://www.rfc-editor.org/rfc/rfc9110.html#section-10.1.4
[nginx-trailers]: https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_pass_trailers
