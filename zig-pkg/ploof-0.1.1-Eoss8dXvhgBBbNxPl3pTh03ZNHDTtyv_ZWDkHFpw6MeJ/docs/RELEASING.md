# Releasing Ploof

Ploof releases one deterministic source archive. It does not publish an
official binary or container. Release is valid only when every gate in
`release/gates.json` has exact-candidate evidence and no failed, skipped,
pending, flaky, or unexplained result remains.

## Fixed release inputs

- Compiler: Zig 0.16.0 exactly.
- Production target: Linux x86_64-v3, ReleaseSafe, no libc or liburing.
- Package version and allowlist: `build.zig.zon`.
- Supported hosts, proxies, and protocols: `release/support-matrix.json`.
- Dependency boundary: `release/dependencies.json`.
- Mandatory gates: `release/gates.json`.

Support matrix is versioned source, not a live query during a release. It binds
each hardware-sensitive gate to a minimum numeric kernel release and CPU-vendor
case and records cumulative Linux feature aliases required by x86-64-v3. Host
checks compare the leading `major.minor.patch` tuple, ignore distribution
suffixes such as `-pikaos`, reject upstream `-rcN` prereleases, and accept newer
kernels. Active io_uring capability probes remain authoritative. Before a candidate is cut, update policy from
upstream primary sources and review change.
Matrix dated 2026-07-19 sets minimums at Linux 6.1.177, 6.6.144, 6.12.95,
6.18.38, and 7.1.3; Caddy 2.11.4; and nginx stable 1.30.4. A newer kernel may
satisfy an existing minimum; changing a minimum or proxy pin requires a new
reviewed candidate commit and complete matrix evidence. Minimums do not move
merely because upstream publishes a newer patch.

## Candidate preparation

1. Choose version and update `.version` in `build.zig.zon`.
2. Complete [migration notes](MIGRATIONS.md) and the reviewed human-authored
   fields in `release/release-notes.json`. Keep its version equal to
   `build.zig.zon`; state security changes even when none. Do not add artifact,
   platform, protocol, or candidate identities by hand: archive generation
   derives those from exact candidate inputs.
3. Run local structural and release-tool tests:

   ```sh
   sh tools/check-release-tooling.sh
   zig build test
   ```

4. Commit every source input. Evidence may target only full commit SHA.
5. Run untrusted, trusted, scheduled, and release-budget/soak jobs on same SHA.

Hosted pull-request jobs never run on self-hosted or performance machines and
receive no secrets. Trusted, performance, evidence, and release workflows use
protected environments and reviewed source only.

## GitHub control-plane requirements

Repository files cannot enforce GitHub organization and repository settings.
Release owners must configure and periodically audit all of these assumptions:

- default-branch rules require reviewed, status-checked changes for workflows,
  release contracts, and tools; direct pushes and force pushes are disabled;
- `trusted`, `performance`, and `release` environments require independent
  reviewers, disallow administrator bypass, and restrict deployment refs;
- self-hosted runners are repository-scoped; organization-owned deployments
  may instead use runner groups restricted to this repository. Trust classes
  use distinct machines, each machine is reset after every job, and none is
  assigned to pull requests from forks;
- tag rules make `v*` tags immutable, and the release runner's GPG trust store
  contains only approved release keys used by `git verify-tag`;
- Actions policy allows only reviewed SHA-pinned actions, artifact retention
  covers the release window, and GitHub's immutable artifact service remains
  the artifact transport;
- only the hosted, action-only `attest` job grants OIDC and attestation write
  permissions; release `build` and `finalize` jobs and every other workflow
  retain read-only repository permissions;
- release runner image supplies an official GitHub CLI version supporting
  offline bundle verification, signer workflow, source digest and ref, and
  self-hosted-runner denial policy.

Workflow dispatches must select the exact candidate ref and repeat that same
full commit SHA in the `revision` input. Inline checks compare checkout `HEAD`
with the input before candidate-owned tools run. Scheduled jobs use the exact
workflow SHA when no revision is supplied. Environment approval is still the
authorization boundary for executing reviewed candidate code on protected
runners.

Release dispatch is stricter: select the signed `vVERSION` tag as workflow ref
and provide that same tag as the `tag` input. Both candidate jobs require
`GITHUB_REF` to equal that tag ref and `GITHUB_SHA` to equal its verified commit
before candidate tools run. This also binds the hosted attestation job's OIDC
source identity to candidate tag instead of default branch.

## External runner commands

Workflows use `tools/run-external-gate.sh` for hardware, soak, proxy, and load
driver work which repository alone cannot supply. Runner defines variable made
from gate ID by uppercasing and replacing dots or hyphens with underscores. For
example, `scheduled.deployment-caddy` uses
`PLOOF_SCHEDULED_DEPLOYMENT_CADDY_COMMAND`.

Command must:

- fail on any invalid output, allocation, leak, sanitizer finding, fuzz crash,
  timeout, regression, or missing counter;
- verify `PLOOF_GATE_ARTIFACT` is its requested candidate and not stale data;
- write one regular tar file at `PLOOF_GATE_ARTIFACT` containing raw samples,
  traces, configurations, manifests, host identity, and reports;
- put exactly one regular `external-evidence-manifest.json` at tar root and
  populate every field required by the gate profile in `release/gates.json`;
- never label an unavailable measurement as measured.

Wrapper refuses an unset command, stale output, missing output, or symlink.
It also rejects unreadable, unsafe, duplicate-path, empty, or trivial tar
output. External evidence uses uncompressed tar; compressed input is rejected
before expansion. Versioned limits allow at most 100,000 members, 4 GiB per
member, 32 GiB unpacked in aggregate, a 35,000,000,000-byte tar, and a 1 MiB
root manifest. The root manifest schema is
`release/external-evidence.schema.json`. The recorder exports the canonical
candidate as `PLOOF_CANDIDATE_REVISION`; an external command copies that value
without resolving a branch or tag itself. Evidence recorder hashes command log
and tar. Artifact policy in
`release/gates.json` requires both for scheduled and other data-heavy gates.

Release verification reopens each contracted tar and compares the manifest to
the candidate's versioned gate profile. It requires candidate and, for
comparisons, distinct baseline revisions; exact optimization modes and equal
case identities; exact fuzz process, generated-case, timeout, and target-family
budgets; exact topology and workload coverage; and pinned Sigbench and in-tree
load-driver identities where applicable. Proxy profiles bind exact candidate
matrix repository, tag, and digest records. Every host entry must declare Linux,
meet the global kernel floor, and contain the cumulative x86-64-v3 CPU flags;
entries also include SHA-256 values for stable OS machine ID and the protected
runner inventory record. Two-machine deployment roles must be physical, distinct in
both identities, and include the recorder runner. This detects a repeated or
cloned OS identity and records the reviewed physical-inventory assertion; it is
not cryptographic proof that two machines are physically separate. Protected
runner administration remains part of the release trust boundary.
Load-driver profiles hash the sorted candidate blobs for all seven
`tools/load_driver*.zig` source files and retain executable
`bin/ploof-load-driver`; its path and SHA-256 must match the manifest's complete
artifact list. This binds results to candidate source and measured binary
without assuming compiler output is reproducible.
The source digest feeds each UTF-8 path, NUL, unsigned 64-bit big-endian blob
length, and blob bytes to SHA-256 in the fixed sorted path order.
Resource campaigns declare
zero post-start framework allocations and descriptor delta plus stable RSS,
workspace, and operation high-water marks. Each release soak has an exact
86,400-second internal interval contained by the recorder's own UTC interval,
so a short command cannot submit a nominal 24-hour manifest.
Manifest artifact records are path-sorted and hash every other regular file in
the tar. Missing, extra, empty-only, duplicate, unsafe, or hash-mismatched raw
evidence fails before any semantic declaration is accepted.

## Evidence reports

Create evidence only by running command through recorder:

```sh
python3 tools/release.py record \
  --gate untrusted.structure \
  --revision "$candidate_sha" \
  --output zig-out/evidence \
  -- python3 tools/release.py structure
```

Recorder writes pass report only after command exits zero. Failure writes a
`.failed.json` report and exits nonzero. Before and after command, recorder
requires `HEAD` to equal canonical candidate commit and rejects tracked changes
plus untracked or ignored source inputs. Evidence output must be under
`zig-out`; known generated cache/output directories are excluded from source
dirt. A command which changes source cannot produce a pass report. Report binds
gate, canonical revision, command, UTC interval, runner identity, candidate gate
and support-manifest hashes, and SHA-256 of retained files. It has no skip state.

Merge artifacts downloaded from lane runs, then validate pre-release set:

```sh
python3 tools/release.py merge-evidence \
  --input zig-out/incoming \
  --output zig-out/evidence
python3 tools/release.py verify-evidence \
  --revision "$candidate_sha" \
  --evidence zig-out/evidence \
  --exclude-gate release.signed-tag \
  --exclude-gate release.archive \
  --exclude-gate release.documentation \
  --exclude-gate release.provenance
```

`evidence.yml` performs this merge using explicit GitHub run IDs and publishes
one `candidate-evidence` artifact. Conflicting reports or artifact hashes fail.
Release workflow later adds four tag/archive/documentation/provenance reports
and requires complete set with no exclusions.

Evidence collection requires exactly three unique run IDs and one unique source
workflow per ID: `untrusted.yml` from a same-repository `push`, `trusted.yml`
from `workflow_dispatch`, and `scheduled.yml` from `schedule` or
`workflow_dispatch`. Before any artifact download, the GitHub API response must
show the exact repository and head repository, candidate SHA, workflow path,
allowed event, successful conclusion, completed state, and requested numeric
run ID. Fork pull-request runs and workflow/event cross-products are rejected.
Only first attempts are accepted; after a failed or cancelled attempt, dispatch
a new run ID instead of rerunning it, avoiding artifacts from prior attempts.
After each run's artifacts download, the collector fetches fresh run metadata
and repeats the same first-attempt authentication before merge. A rerun racing
the download therefore invalidates the collection instead of changing its
authenticated artifact subjects.
Runs download into ID-specific directories; merge validation rejects missing,
extra, failed, conflicting, stale, or hash-mismatched gate reports.
Collector requests only versioned artifact names expected from each
authenticated source workflow. GitHub tokens exist only in metadata-fetch and
artifact-download/refetch steps; candidate validator runs separately with
token variables explicitly removed.

## Tag and source artifacts

Create signed annotated tag only after candidate evidence is complete:

```sh
git tag -s "v${version}" "$candidate_sha" -m "Ploof ${version}"
git verify-tag "v${version}"
git push origin "v${version}"
```

Release tool rejects lightweight, unsigned, wrong-version, or wrong-revision
tag. Protected release runner must contain trusted signing public key.

To reproduce artifact generation without publishing:

```sh
python3 tools/release.py verify-tag \
  --tag "v${version}" \
  --revision "$candidate_sha"
manifest=$(python3 tools/release.py archive \
  --revision "$candidate_sha" \
  --output zig-out/release \
  --evidence zig-out/evidence)
python3 tools/release.py verify-artifacts \
  --manifest "$manifest" \
  --evidence zig-out/evidence \
  --reproduce
python3 tools/release.py verify-consumer \
  --manifest "$manifest" \
  --evidence zig-out/evidence
```

The evidence directory must contain passing, exact-candidate reports and
contracted result tars for Sigbench regression, runtime benchmarks, and direct,
Caddy, and nginx two-machine deployments. Note rendering verifies each report's
candidate, result, source contract profile, support/gate hashes, every retained
artifact hash, and the semantic external-tar contract. Generated notes list the
report and tar path plus SHA-256 for all five gates. Missing or stale benchmark
evidence prevents artifact generation.

Archive reads only allowlisted blobs from exact Git commit. Working-tree files
cannot enter it. Entries are path-sorted, regular files only, rooted at
`ploof-VERSION`, use commit timestamp, uid/gid zero, fixed modes, and USTAR.
Generated caches, outputs, symlinks, submodules, and paths outside allowlist are
rejected at any depth. Package includes complete `tests` tree, so archive
consumer executes full test graph rather than selected fixtures. Consumer uses
local and global caches outside extracted source, then runs `zig build test` and
compiles both lazy ReleaseSafe and ReleaseFast benchmark graphs through
sigbench's `--list` path. Uncompressed tar avoids compressor-version drift.

Generated set:

- `ploof-VERSION.tar`: deterministic source package.
- `ploof-VERSION.sha256`: source archive SHA-256.
- `ploof-VERSION.zig-hash`: Zig 0.16.0 package hash.
- `ploof-VERSION.spdx.json`: SPDX 2.3 package SBOM.
- `ploof-VERSION.provenance.json`: deterministic in-toto/SLSA statement.
- `ploof-VERSION.release-notes.md`: deterministic candidate notes with exact
  platform, protocol, benchmark-result, and artifact identities.
- `ploof-VERSION.manifest.json`: hashes and exact source/matrix/gate identities.

Generated notes are a sibling release artifact, not a source-tar member,
because they bind the source tar's digest. `verify-consumer` regenerates and
byte-compares the notes before extracting or building the tar, then validates
the manifest hash for the notes themselves. This avoids a recursive self-hash.

Local provenance statement is unsigned build description. Release workflow's
GitHub artifact attestation is separate signed provenance and mandatory. Do not
describe local JSON alone as attested provenance.

## Final release workflow

Run `release.yml` at signed tag with same tag input and evidence workflow run
ID. Three protected jobs keep candidate code away from OIDC credentials:

1. `build` verifies workflow ref, workflow SHA, signed tag, and checkout `HEAD`
   using system Git before candidate tools;
2. it installs checksum-pinned Zig 0.16.0, fetches evidence-run metadata in a
   token-only step, then authenticates repository, head repository, workflow,
   event, candidate revision, success state, first attempt, and run ID without
   token access;
3. it downloads only `candidate-evidence` from authenticated run, refetches and
   re-authenticates run metadata before using those bytes, records tag verification,
   generates artifacts twice, builds clean archive consumer, byte-compares notes,
   and verifies release documentation;
4. it uploads release plus evidence once under run-and-attempt-unique name and
   exports immutable artifact ID;
5. hosted `attest` downloads exact artifact ID and runs only pinned GitHub
   download, build-provenance, and upload actions; no checkout, shell, or
   candidate code can access its OIDC and attestation-write permissions;
6. `finalize` re-verifies workflow ref, workflow SHA, tag, and checkout, then
   downloads pre-attestation release and bundle by exact artifact IDs;
7. it re-verifies every downloaded release artifact against manifest, then a
   token-only system-command step verifies bundle against archive, repository,
   signer workflow, candidate digest, tag ref, and hosted-runner policy;
8. without token access, candidate recorder retains bundle and verification
   result, requires complete evidence, and uploads run-and-attempt-unique
   candidate artifacts without creating release automatically.

Each job needs release-environment approval. Cross-job artifacts use immutable
GitHub artifact IDs; names also include workflow run and attempt IDs. Runner
reset between `build` and `finalize` is required even if scheduler assigns same
physical release host.

Human publisher compares candidate manifest with workflow output, attaches the
generated notes and exact artifacts, then creates immutable GitHub release.
Any rerun after source, matrix, gate, note, or retained benchmark-evidence
change is a new candidate artifact set. Never edit or replace an existing
release archive.
