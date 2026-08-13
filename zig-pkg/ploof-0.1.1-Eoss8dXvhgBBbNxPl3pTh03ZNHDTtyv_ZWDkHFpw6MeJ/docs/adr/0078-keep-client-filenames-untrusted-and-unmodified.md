# Keep client filenames untrusted and unmodified

A file part can supply either one `filename` parameter or one `filename*`
parameter, never both. Supplying both is ambiguous and receives 400. Absence and
an explicitly empty filename remain distinct valid metadata states; ADR 0079
defines the empty marker.

After quoted-string decoding, `filename` must be valid UTF-8. Percent signs in
that form remain literal. `filename*` uses strict RFC 8187 extended-value
syntax, accepts only the UTF-8 charset, validates its optional language token,
and percent-decodes every encoded octet. Malformed encoding or invalid UTF-8
receives 400. The decoded filename limit from ADR 0021 is 255 bytes by default;
crossing the configured limit receives 413.

The application receives a request-scoped `ClientFilename` wrapper with source
provenance, not a filesystem path or a value advertised as safe. Ploof does not
normalize Unicode, strip directories, take a platform basename, rewrite slash
or backslash, infer an extension, or open a file from this value. Applications
generate their own storage identifiers and can retain the client value only as
untrusted display metadata.

RFC 7578 tells senders not to use `filename*`, but deployed Busboy-based
receivers parse it. Strict receiver support improves interoperability without
adopting Busboy's filename-star precedence when both forms appear.

Sources: [RFC 7578 filenames](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2),
[RFC 8187 extended values](https://www.rfc-editor.org/rfc/rfc8187.html), and
[Busboy multipart parser](https://github.com/mscdex/busboy/blob/v1.6.0/lib/types/multipart.js).
