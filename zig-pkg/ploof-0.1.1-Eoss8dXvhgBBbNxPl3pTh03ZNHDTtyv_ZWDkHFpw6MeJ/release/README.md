# Release contracts

These JSON files are reviewed source inputs:

- `support-matrix.json`: exact compiler, cumulative CPU feature aliases,
  gate-to-host bindings, kernels, CPU vendors, proxy image digests, deployment
  profiles, protocol support, and soak duration.
- `dependencies.json`: empty production dependency set and exact lazy build
  dependencies.
- `release-notes.json`: version-bound human-authored changes, migration,
  security, and performance statements used by deterministic note rendering;
  renderer adds exact candidate benchmark report/tar identities from retained
  evidence and fails if any required result is missing or stale.
- `gates.json`: complete mandatory gate inventory and retained-artifact minima.
- `evidence.schema.json`: one immutable pass report from one gate execution.
- `external-evidence.schema.json`: semantic manifest inside each external gate tar.
- `artifact-manifest.schema.json`: deterministic source artifact set.
- `release-notes.schema.json`: reviewed release-note source shape.

Schemas document interchange. `tools/release.py` remains authoritative
fail-closed validator because release hosts install no JSON Schema dependency.
Unknown gates, missing gates, skips, failed reports, conflicting merge inputs,
manifest drift, missing files, symlinks, unsafe paths, and hash mismatch fail.
External tar validation also rejects identity, mode, case, budget, interval,
host operating-system/kernel/CPU capability, pinned proxy image, topology,
workload, resource, load-driver, and Sigbench contract drift. Its path-sorted
artifact records must hash every other regular tar member.

See [release procedure](../docs/RELEASING.md).
