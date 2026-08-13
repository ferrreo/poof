# Keep route matching structural

Ploof version one will match literal segments, `:name` non-empty segments, and
terminal `*name` remainders with deterministic precedence and compile-time
conflict rejection. Handlers may convert captured values directly to Zig types,
but conversion success will not participate in route selection. Optional
segments, regex constraints, typed route alternatives, and mid-path wildcards
stay outside version one, avoiding backtracking and ambiguous fallback rules.

Precedence is lexicographic by segment: literal, then parameter, then catch-all.
Those shapes may overlap; only routes with the same method and structurally
equivalent complete pattern conflict. Parameter spelling does not distinguish
structures, so `/:id` and `/:name` conflict. Parameter names are unique within
one complete pattern and use ASCII letters, digits, and underscore, beginning
with a letter or underscore.

Patterns begin with `/`. Repeated and terminal slashes are exact empty literal
segments and are never cleaned. A group prefix is empty or begins with `/` and
does not end with `/`; child route paths begin with `/`, so composition is byte
concatenation rather than path normalization. `:` and `*` are metacharacters
only as the first byte of a complete segment. Version one has no escape for a
literal segment beginning with either byte; ambiguous or malformed spellings
fail composition.
