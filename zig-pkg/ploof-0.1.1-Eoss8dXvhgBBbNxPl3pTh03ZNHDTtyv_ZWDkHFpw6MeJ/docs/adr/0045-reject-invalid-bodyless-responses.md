# Reject invalid bodyless responses

Ploof handlers cannot return an informational status as a final Response.
Version one emits `100 Continue` only through its protocol runtime. A Response
with status 204, 205, or 304 cannot contain a finite body, stream, or response
trailers. Static invalid combinations fail at comptime; dynamically selected
ones return `InvalidResponse` before commitment so the central failure mapper
can produce a safe final response.

Responses with status 204 or 304 emit no `Content-Length`, `Transfer-Encoding`,
or `Trailer`. RFC 9110 permits a correct hypothetical length on 304, but
version one omits it to remove a mismatch class. A 205 emits
`Content-Length: 0`; unlike 204 and 304, its status does not delimit the message,
so omitting framing would make a persistent HTTP/1.1 response close-delimited.
Other end-to-end metadata remains available where its field semantics permit
it.

HEAD is method-level suppression rather than an invalid handler result. An
implicit HEAD runs the selected GET handler and all applicable response
middleware; an explicit HEAD route follows the same wire rule. Ploof sends no
body or trailers and does not invoke a stream producer. It emits
`Content-Length` only when the final hypothetical wire length is already exact,
and never emits `Transfer-Encoding`. Middleware `after` receives an explicit
HEAD-suppressed transport outcome after the response head is transmitted.

Gin and Express normally suppress forbidden content rather than report the
handler mistake. Ploof retains their ordinary HEAD and empty-response workflows
but rejects invalid status/body construction before bytes make recovery
impossible.

Sources: [RFC 9110 HEAD](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.2),
[RFC 9110 status semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-15),
[Go HTTP server](https://go.dev/src/net/http/server.go),
[Gin response rendering](https://github.com/gin-gonic/gin/blob/v1.12.0/context.go),
[Node HTTP response writes](https://nodejs.org/api/http.html#responsewritechunk-encoding-callback),
and [Express response helpers](https://github.com/expressjs/express/blob/v5.2.1/lib/response.js).
