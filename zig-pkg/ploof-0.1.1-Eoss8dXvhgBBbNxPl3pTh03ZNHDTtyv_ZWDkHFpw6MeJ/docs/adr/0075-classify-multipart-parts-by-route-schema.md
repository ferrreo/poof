# Classify multipart parts by route schema

Every typed multipart route declares a comptime part schema. Each exact decoded
part name has one fixed kind, ordinary field or streamed file, and one fixed
cardinality expressed as required or optional plus a declared finite maximum
under ADR 0087. Schema construction rejects empty or duplicate names,
impossible counts, and totals exceeding the route's multipart limits profile.

Ordinary field text and byte representations follow ADR 0080.

The route schema, not `filename` or part `Content-Type`, selects buffering and
callback behavior. A declared file uses the upload stream even when filename is
absent. A declared field carrying filename metadata is a kind mismatch and
receives 400 rather than changing to a stream. A file's media type remains
untrusted metadata and does not change its declared kind. An ADR 0090 policy can
accept or reject that claim without reclassifying the part.

Nested multipart media types do not override this classification or create an
inner part graph; ADR 0085 defines their opaque handling.

Filename is optional metadata, never a path, storage destination, or file
classifier. The generated schema fixes callback state and storage needs before
startup. Unknown and explicitly dynamic parts are separate policy decisions.

Part metadata is parsed under ADR 0077.
Filename representation follows ADR 0078.
Empty filename markers follow ADR 0079.
Nested multipart handling follows ADR 0085.
Requiredness and repeated-part maxima follow ADR 0087.
Concrete file-sink types and state layout follow ADR 0089.
File-start media acceptance and content verification follow ADR 0090.
Declared file rejection never silently changes schema shape under ADR 0091.

RFC 7578 makes filename optional and warns receivers not to use supplied path
information blindly. Route-declared kinds also resemble Multer's `single`,
`array`, and `fields` APIs while preventing a client header from selecting a
different memory path.

Sources: [RFC 7578 file parts](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2)
and [Multer field declarations](https://expressjs.com/en/resources/middleware/multer/#fields).
