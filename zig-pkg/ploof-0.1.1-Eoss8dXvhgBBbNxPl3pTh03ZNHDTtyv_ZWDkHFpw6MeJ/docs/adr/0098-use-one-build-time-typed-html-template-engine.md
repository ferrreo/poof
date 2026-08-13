# Use one build-time typed HTML template engine

Ploof ships one HTML template engine with a familiar typed response helper.
Each template is included through an explicit comptime path such as
`@embedFile`, parsed at comptime, and bound to one concrete view type. Template
field references, helper calls, and the static partial graph are checked during
compilation; diagnostics identify the template path, line, and column.

The built-in engine has a closed template graph. It has no runtime filesystem
reads, parser, cache, dynamic template names, interchangeable-engine registry,
or string-keyed locals. Applications needing runtime-authored or CMS templates
can use an external renderer and return its bounded bytes or explicit stream
through the ordinary response contracts; it does not plug into a hidden Ploof
engine abstraction.

This deliberately differs from Express's runtime-selected third-party engines
and moves Gin's template loading from startup to compilation. Handlers retain
the recognizable render-template-with-data workflow, while Ploof removes
startup and request-time parsing, lookup, and allocation and catches view
contract mistakes before execution. Template changes require a rebuild and can
increase compile time and binary size, so benchmarks track compilation cost,
emitted size, render latency, and render workspace.

Sources: [Express template engines](https://expressjs.com/en/5x/guide/using-template-engines/),
[Gin HTML rendering](https://gin-gonic.com/en/docs/rendering/).
