# Distinguish URL, asset, and trusted-resource values

Dynamic HTML URL attributes accept one of three nominal value classes. `Url`
represents navigation, form, and non-executable resource destinations;
`AssetRef` identifies a Ploof embedded asset with a declared media kind; and
`TrustedResourceUrl` represents an explicitly trusted script, stylesheet,
frame, or other active-resource destination. Plain strings cannot enter URL
attributes, while static literal URLs remain legal template source.

A dynamic URL value must occupy the complete fully quoted attribute value.
Mixed construction such as `href="/users/{{view.id}}"` fails at comptime.
Allocation-free route and query builders construct complete `Url` values, and
runtime parsing validates complete externally supplied destinations before a
view is rendered. Serialization then applies HTML attribute escaping.

The template compiler classifies each URL position from its static element,
attribute, and any security-relevant discriminator such as `link` `rel`.
Dynamic or ambiguous discriminators fail compilation. The position must accept
the supplied value class, and an `AssetRef` media kind must match the resource
position. A normal `Url` can never become a script or stylesheet source merely
because its bytes passed scheme validation.

Legacy HTML `background` attributes are asset URL positions. Dynamic `base
href` is forbidden because it could reinterpret later static relative active
resources. Microdata `itemid`, `itemtype`, and `itemprop` can contain URL tokens
outside Ploof's navigation grammar, so version one permits them only as static
template source.

`attributionsrc` and other whitespace-separated URL sets remain static-only
until a bounded nominal list type exists. For dynamic `link href`, every `rel`
token must be in Ploof's closed navigation, asset-fetch, or trusted-resource
table; an unknown or future relation fails compilation instead of defaulting to
navigation. Manifest, search-description, pingback, module-preload, stylesheet,
and compression-dictionary relations require `TrustedResourceUrl`.

This is stricter than Gin's inherited Go `html/template` URL filtering and the
engine-dependent Express model. The additional types make executable-resource
trust visible in code and let most invalid placements fail during compilation.
Allowed URL forms, schemes, builders, and trusted-resource construction are
separate decisions.

Source: [Go `html/template`](https://pkg.go.dev/html/template).
