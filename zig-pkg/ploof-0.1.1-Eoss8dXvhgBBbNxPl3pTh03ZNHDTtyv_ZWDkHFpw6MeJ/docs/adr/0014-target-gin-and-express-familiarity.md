# Target Gin and Express familiarity

Ploof will be easy to learn for developers who would otherwise choose Gin or
Express for an HTTP application. Route declaration, grouping, middleware,
request access, response production, and common framework facilities should
remain conceptually recognizable. The public API will still be idiomatic,
strongly typed Zig and may deliberately differ for safety, performance, or
clearer semantics. Ploof therefore promises familiar workflows and sufficient
capability, not source compatibility or universal behavioral parity with either
framework.

Gin with Go and Express with Node are also Ploof's comparison baseline for
public defaults and semantics. Exact parity is neither possible nor desired
when those stacks disagree. Each deliberate divergence must be identified and
justified by safety, measured performance, HTTP semantics, or an idiomatic Zig
contract; configuration must remain easy where applications legitimately need
different policy. This prevents unexplained outliers without copying unsafe or
unbounded defaults.
