# Map typed application failures centrally

Expected HTTP outcomes such as validation rejection, failed authorization,
missing resources, and conflicts will be returned as Responses. Unexpected
operational failures will propagate through each handler's error union into a
single application error mapper. Applications will declare a closed error set,
and custom mapping will be checked against that type at compile time.

The default mapping will produce a generic 500 response and will never expose
error names or internal detail to the client. HTTP parser and framework limit
failures remain separate and receive precise built-in responses such as 400,
413, and 431. This gives Gin and Express users a familiar central error boundary
without dynamic error lists, exceptions, or per-request allocation.

Body framing, content decoding, media admission, and framework limit failures
remain on that built-in path even when discovered after middleware `head`.
They bypass the application mapper and `response` phases, while initialized
`after` phases still observe the final transport outcome exactly once.

The mapper is a non-failing function from the application's exact finite error
set and Context to Response. Handlers and fallible middleware phases may return
subsets of that set; `anyerror` and undeclared members fail composition. Native
Zig switch exhaustiveness checks custom mapping. If a response phase fails, its
mapped replacement continues through only the remaining outer response phases;
already-run phases are not repeated and the mapper cannot recurse through
another error.
