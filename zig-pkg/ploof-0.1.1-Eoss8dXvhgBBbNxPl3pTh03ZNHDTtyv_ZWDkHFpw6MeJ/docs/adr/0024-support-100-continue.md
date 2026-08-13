# Support 100 Continue

Ploof will implement `Expect: 100-continue` for HTTP/1.1 request bodies. After
the header section is complete, the runtime will select the route, validate
framing, content coding, media type, and declared limits, and run middleware
`head` phases. Together these checks form the continue gate.

Body media selection under ADR 0069 is completed in this gate before `100
Continue`.

The route workspace must also be reserved under ADR 0073 before `100 Continue`.

The boundary accepts `Expect` only when exactly one physical `Expect` field is
present and its OWS-trimmed value case-insensitively equals `100-continue`.
Duplicate physical fields, comma lists, empty values, and other values receive
417.

When the gate accepts the request, Ploof will immediately send 100 and begin
bounded body intake. When it rejects the request, Ploof will send the final
response without 100 and close the connection rather than drain an untrusted
body. A request with no remaining wire body receives no interim response, even
when its expectation otherwise matches. Ploof will never wait for body bytes
before sending either 100 or a header-determined final response.

If a `body` phase rejects after intake begins, Ploof will close the connection
when unread body bytes remain; it may reuse the connection only after the whole
request message is consumed. Every sent 100 is followed by a final response
unless the connection fails first. The interim 100 is never recorded as the
request's final status; a pre-final disconnect has no final status.
