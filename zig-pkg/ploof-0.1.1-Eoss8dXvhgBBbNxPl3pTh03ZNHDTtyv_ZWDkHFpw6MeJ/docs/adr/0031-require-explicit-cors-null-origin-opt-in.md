# Require explicit CORS null-origin opt-in

Every standard CORS mode rejects the opaque `Origin: null` serialization,
including allow-any and allow-any-with-credentials. A policy must enable the
separately named `allow_null` option to permit it. Many unrelated sources,
including sandboxed documents and local files, share this serialization, so it
cannot identify one trusted origin and must not inherit a broad wildcard rule
silently.
