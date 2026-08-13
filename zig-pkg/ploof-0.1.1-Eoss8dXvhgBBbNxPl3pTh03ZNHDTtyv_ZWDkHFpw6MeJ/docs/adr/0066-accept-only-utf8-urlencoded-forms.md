# Accept only UTF-8 URL-encoded forms

An `application/x-www-form-urlencoded` body with no charset parameter is
interpreted as UTF-8. An explicit `charset=utf-8` is accepted with
case-insensitive charset matching. Any other declared charset receives 415;
Ploof does not transcode legacy encodings.

After plus and percent decoding, every form name and value must be valid UTF-8.
One invalid sequence rejects the complete form with 400 before middleware or a
handler can observe a partial collection. This applies to raw form access as
well as typed binding. Applications needing arbitrary request bytes declare a
raw body rather than a form.

The conventional `_charset_` name is an ordinary form field and cannot select
or override decoding. URI queries retain ADR 0039's byte-oriented raw view;
typed query text and text codec hooks still require UTF-8 under ADR 0064.

This keeps one form interpretation and avoids transcoding branches and copy
storage. It deliberately omits Express's legacy ISO-8859-1 options and differs
from Gin's charset-agnostic byte strings.

Sources: [WHATWG URL-encoded format](https://url.spec.whatwg.org/#application/x-www-form-urlencoded)
and [Express body-parser URL-encoded implementation](https://github.com/expressjs/body-parser/blob/v2.3.0/lib/types/urlencoded.js).
