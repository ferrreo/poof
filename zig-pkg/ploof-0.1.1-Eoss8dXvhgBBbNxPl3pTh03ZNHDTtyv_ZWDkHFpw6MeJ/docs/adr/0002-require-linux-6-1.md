# Require Linux 6.1 or newer

Ploof requires Linux 6.1 or newer so its reactor can rely on multishot receive,
provided-buffer rings, single-issuer operation, and deferred task work. We will
not add older-kernel single-shot or non-deferred compatibility paths without
demonstrated deployment demand, because they would enlarge and branch the
hottest, most security-sensitive part of the server.

The version check provides an immediate diagnostic, not proof of suitability.
ADR 0123 defines the authoritative capability and active-operation checks.
