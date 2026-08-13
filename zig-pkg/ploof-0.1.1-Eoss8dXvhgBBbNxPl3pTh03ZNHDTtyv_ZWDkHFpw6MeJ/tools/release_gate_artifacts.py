"""Canonical retained-artifact subjects for release gates."""

from __future__ import annotations

from pathlib import Path

from release_common import fail
from release_gate_commands import EXTERNAL_GATES, candidate_version


def verify_gate_artifact_policy(
    root: Path,
    revision: str,
    gate_id: str,
    paths: set[str],
) -> None:
    log = f"{gate_id}.log"
    if gate_id in EXTERNAL_GATES:
        expected = {log, f"artifacts/{gate_id}/{gate_id}.tar"}
    elif gate_id == "release.archive":
        base = f"artifacts/{gate_id}/ploof-{candidate_version(root, revision)}"
        expected = {log} | {
            base + suffix for suffix in (
                ".manifest.json",
                ".tar",
                ".sha256",
                ".zig-hash",
                ".spdx.json",
                ".provenance.json",
                ".release-notes.md",
            )
        }
    elif gate_id == "release.documentation":
        version = candidate_version(root, revision)
        expected = {log, f"artifacts/{gate_id}/ploof-{version}.release-notes.md"}
    elif gate_id == "release.provenance":
        verification = f"artifacts/{gate_id}/verification.json"
        bundles = paths - {log, verification}
        prefix = f"artifacts/{gate_id}/"
        valid_bundle = len(bundles) == 1 and next(iter(bundles)).startswith(prefix)
        if paths != {log, verification} | bundles or not valid_bundle:
            fail(f"{gate_id}: retained artifact subject set does not match gate policy")
        return
    else:
        expected = {log}
    if paths != expected:
        fail(f"{gate_id}: retained artifact subject set does not match gate policy")
