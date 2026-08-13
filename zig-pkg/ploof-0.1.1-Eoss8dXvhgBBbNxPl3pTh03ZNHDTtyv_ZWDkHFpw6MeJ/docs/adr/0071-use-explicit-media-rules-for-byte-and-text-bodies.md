# Use explicit media rules for byte and text bodies

The standard `Body.Bytes` decoder accepts `application/octet-stream`; the
standard `Body.Text` decoder accepts `text/plain`. A route can replace either
with a finite comptime list of validated exact media types or explicit type and
global wildcard patterns. Any overlap with another body decoder is rejected
during route composition under ADR 0069.

A wildcard still requires a present, syntactically valid `Content-Type`; it does
not match an absent field. Byte bodies validate the media field but attach no
meaning to a charset parameter and preserve every content-decoded representation
byte. They perform no content sniffing.

Text bodies interpret a missing charset parameter as UTF-8 and accept an
explicit UTF-8 label case-insensitively. Any other declared charset receives
415. A duplicate charset parameter receives 400. Quoted charset values use the
normal HTTP quoted-pair interpretation before comparison. Invalid UTF-8 in the
complete representation receives 400 before handler entry. Ploof performs no
text transcoding.

These defaults match the conventional Express raw and text media types while
making broader matching an explicit route contract.

Source: [Express raw and text parsers](https://expressjs.com/en/5x/api.html#express.raw).
