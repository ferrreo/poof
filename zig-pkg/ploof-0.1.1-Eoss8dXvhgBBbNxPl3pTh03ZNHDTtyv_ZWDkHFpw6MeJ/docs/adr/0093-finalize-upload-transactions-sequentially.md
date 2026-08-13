# Finalize upload transactions sequentially

After the completion handler selects `.commit(response)` and every pre-commit
response phase succeeds, Ploof commits staged sinks one at a time in original
file-start order. Version one does not submit parallel sink commits. This needs
only one lifecycle poller and gives tests and external systems deterministic
observable ordering.

The first commit failure stops further commits. After all active I/O is
quiescent, Ploof invokes `abort` on every sink whose `begin` was entered, in
reverse file-start order. This includes uncommitted sinks, the sink whose commit
failed, and already committed sinks that must attempt compensation. The ADR
0083 sink contract must tolerate each of those states.

An abort failure is recorded but does not stop remaining reverse-order cleanup.
Any commit or cleanup failure before response commitment discards the selected
response and reaches the central 500 failure path after every sink has received
its cleanup attempt. Metrics retain each bounded failure class and sink identity
without client data.

Once the application has selected `.commit`, a client disconnect does not
cancel finalization. Ploof finishes the commit sequence or its compensation so
durable side effects do not depend on whether response delivery raced with the
peer. A disconnect before that explicit decision follows the normal abort path.

This can add one remote round trip per file and cannot make independent systems
atomic. It favors deterministic bounded recovery in version one; parallel
commit would require a new decision backed by multi-file remote-sink benchmarks
and failure-injection evidence.

Filesystem commit and compensation can include the explicit ADR 0097 durability
sequence.
