# Migration notes

## 0.1.1

No migration is required. This patch release preserves documented 0.1.0
source API, observable behavior, Linux and CPU floors, and proxy requirements.

## 0.1.0

Initial public release. No earlier supported Ploof API exists to migrate.

Before 1.0, patch releases preserve documented source API and observable
behavior except when security correction cannot be made safely without break.
Minor releases may break public APIs. Every later breaking minor release adds:

- before and after public-only consumer fixtures;
- exact renamed or removed declarations and changed defaults;
- operational changes to kernel, CPU, proxy, or io_uring requirements;
- bounded migration procedure and rollback point.

Raising Linux 6.1 or x86-64-v3 floor requires minor release before 1.0 and
major release after 1.0. Such change must never appear only as startup error or
matrix edit.
