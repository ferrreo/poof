# Keep form bodies and queries separate

Ploof never merges URI query fields with an
`application/x-www-form-urlencoded` request body. `Query(T)` and the raw query
collection consume only the request target. `Form(T)` and the raw form
collection consume only the decoded request body. Each source preserves its own
ordered repeated values and enforces its own limits.

A route that needs both declares both inputs and combines them explicitly in
application code. Neither source has implicit precedence. This prevents a body
field from overriding a query filter, a query field from supplying a missing
form or CSRF value, and later middleware from observing a merged interpretation
different from earlier middleware.

Gin's default form binding passes Go's merged `Request.Form`, where body values
take precedence over query values. Express exposes `req.body` and `req.query`
separately. Ploof chooses the explicit boundary while keeping dedicated typed
helpers for both sources.

Sources: [Gin 1.12 form binding](https://github.com/gin-gonic/gin/blob/v1.12.0/binding/form.go),
[Go `Request.ParseForm`](https://pkg.go.dev/net/http#Request.ParseForm), and
[Express request API](https://expressjs.com/en/5x/api.html#req.body).
