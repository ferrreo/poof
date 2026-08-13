# Use head, body, and after middleware

Status: Superseded by [ADR 0043](0043-use-four-phase-middleware.md).

Ploof middleware may implement three explicit phases. `head` runs after route
selection but before body intake and can inspect headers, cookies, path and
query values, proxy identity, and application state. `body` receives bounded
decoded input: a complete view for buffered routes or borrowed events for
streaming routes. `after` receives the final result and runs in reverse
declaration order for all middleware whose state was initialized.

A streaming body ends with one terminal event carrying the completed request
trailers view. Buffered handlers begin only after the same trailer validation
has completed. Applicable `after` phases can therefore inspect trailers without
making them visible to earlier `head` decisions.

Each middleware declares a fixed-size `State` type. The compiler lays out one
state instance per composed middleware in the route's request record and passes
the same typed pointer to every phase. `State = void` consumes no space. The
compiler rejects chains above the configured state bound; the runtime clears
state before reusing a request slot. No dynamic context map, downcast, or heap
allocation participates in phase communication.

This lifecycle supports early header-only rejection without preventing body-
aware concerns such as CSRF, webhook signatures, audit policy, and streaming
upload validation. Unused phases disappear at comptime. Borrowed streaming
chunks may not be retained in middleware state.

This decision supersedes ADR 0022's two-phase contract.
