"""Canonical commands allowed to produce release-gate evidence."""

from __future__ import annotations

from collections import Counter
from pathlib import Path

from release_common import fail, git_file, parse_zon, release_version


STATIC_COMMANDS = {
    "untrusted.structure": ("tools/check-release-tooling.sh",),
    "untrusted.correctness": ("zig", "build", "test-untrusted"),
    "untrusted.fuzz-smoke": (
        "zig", "build", "test-fuzz-driver", "fuzz-http1",
        "-Dfuzz-runs=10000", "-Dfuzz-timeout-seconds=600",
    ),
    "trusted.real-io-floor": ("zig", "build", "test"),
    "trusted.real-io-current": ("zig", "build", "test"),
    "trusted.proxy-matrix": (
        "zig", "build", "test-proxy-interop", "-Dproxy-interop-required=true",
    ),
    "trusted.thread-sanitizer": ("zig", "build", "test-thread-sanitizer"),
    "release.provenance": ("test", "-s", "zig-out/attestation/verification.json"),
}

EXTERNAL_GATES = {
    "trusted.sigbench-regression",
    "scheduled.kernel-linux-6.1-intel",
    "scheduled.kernel-linux-6.1-amd",
    "scheduled.kernel-linux-6.6-intel",
    "scheduled.kernel-linux-6.12-amd",
    "scheduled.kernel-linux-6.18-intel",
    "scheduled.kernel-linux-7.1-intel",
    "scheduled.kernel-linux-7.1-amd",
    "scheduled.security-fuzz",
    "scheduled.resource-plateau",
    "scheduled.runtime-benchmarks",
    "scheduled.deployment-direct",
    "scheduled.deployment-caddy",
    "scheduled.deployment-nginx",
    "release.fuzz-budget",
    "release.soak-floor",
    "release.soak-current",
}

RELEASE_COMMAND_GATES = {
    "release.signed-tag",
    "release.archive",
    "release.documentation",
}

CANONICAL_GATE_IDS = frozenset(STATIC_COMMANDS) | EXTERNAL_GATES | RELEASE_COMMAND_GATES

WORKFLOW_RECORD_POLICY = {
    ".github/workflows/untrusted.yml": (
        "-- tools/check-release-tooling.sh",
        "-- zig build test-untrusted",
        "-- zig build test-fuzz-driver fuzz-http1",
    ),
    ".github/workflows/trusted.yml": (
        "-- zig build test",
        "-- zig build test-proxy-interop -Dproxy-interop-required=true",
        "-- zig build test-thread-sanitizer",
        "-- tools/run-external-gate.sh trusted.sigbench-regression",
    ),
    ".github/workflows/scheduled.yml": (
        '-- tools/run-external-gate.sh "scheduled.kernel-${{ matrix.case }}"',
        '-- tools/run-external-gate.sh "${{ matrix.gate }}"',
        '-- tools/run-external-gate.sh "${{ matrix.gate }}"',
    ),
    ".github/workflows/release.yml": (
        "-- python3 tools/release.py verify-tag",
        "-- python3 tools/release.py verify-consumer \\",
        "-- python3 tools/release.py verify-artifacts \\",
        '-- test -s "$verification"',
    ),
}

WORKFLOW_ARTIFACT_POLICY = {
    ".github/workflows/trusted.yml": (
        "--artifact zig-out/external/trusted.sigbench-regression.tar",
    ),
    ".github/workflows/scheduled.yml": (
        '--artifact "zig-out/external/scheduled.kernel-${{ matrix.case }}.tar"',
        '--artifact "zig-out/external/${{ matrix.gate }}.tar"',
        '--artifact "zig-out/external/${{ matrix.gate }}.tar"',
    ),
    ".github/workflows/release.yml": (
        '--artifact "$manifest" \\',
        '--artifact "$base.tar" \\',
        '--artifact "$base.sha256" \\',
        '--artifact "$base.zig-hash" \\',
        '--artifact "$base.spdx.json" \\',
        '--artifact "$base.provenance.json" \\',
        '--artifact "$base.release-notes.md" \\',
        '--artifact "$base.release-notes.md" \\',
        '--artifact "$bundle" \\',
        '--artifact "$verification" \\',
    ),
}


def canonical_gate_command(root: Path, revision: str, gate_id: str) -> list[str]:
    command = STATIC_COMMANDS.get(gate_id)
    if command is not None:
        return list(command)
    if gate_id in EXTERNAL_GATES:
        artifact = f"zig-out/external/{gate_id}.tar"
        return ["tools/run-external-gate.sh", gate_id, artifact]
    version = candidate_version(root, revision)
    base = f"zig-out/release/ploof-{version}"
    release_commands = {
        "release.signed-tag": (
            "python3", "tools/release.py", "verify-tag",
            "--tag", f"v{version}", "--revision", "HEAD",
        ),
        "release.archive": (
            "python3", "tools/release.py", "verify-consumer",
            "--manifest", f"{base}.manifest.json",
            "--evidence", "zig-out/evidence", "--reproduce",
        ),
        "release.documentation": (
            "python3", "tools/release.py", "verify-artifacts",
            "--manifest", f"{base}.manifest.json", "--evidence", "zig-out/evidence",
        ),
    }
    command = release_commands.get(gate_id)
    if command is None:
        fail(f"{gate_id}: no canonical gate command is defined")
    return list(command)


def candidate_version(root: Path, revision: str) -> str:
    try:
        text = git_file(root, revision, "build.zig.zon").decode("utf-8")
    except UnicodeError as error:
        fail(f"candidate build.zig.zon is not UTF-8: {error}")
    return release_version(parse_zon(text)["version"])


def check_workflow_command_policy(
    root: Path,
    paths: list[Path],
    texts: dict[Path, str],
    errors: list[str],
) -> None:
    workflow_paths = {
        path.relative_to(root).as_posix() for path in paths
        if path.parent == root / ".github/workflows"
    }
    missing = sorted(set(WORKFLOW_RECORD_POLICY) - workflow_paths)
    if missing:
        errors.append(f".github/workflows: canonical gate workflows are missing: {missing}")
    for path, text in texts.items():
        relative = path.relative_to(root).as_posix()
        expected = WORKFLOW_RECORD_POLICY.get(relative)
        record_count = text.count("python3 tools/release.py record")
        if expected is None:
            if record_count:
                errors.append(f"{relative}: gate recorder is outside canonical workflow")
            continue
        tails = Counter(
            line.strip() for line in text.splitlines() if line.strip().startswith("-- ")
        )
        if record_count != len(expected) or tails != Counter(expected):
            errors.append(f"{relative}: canonical gate command wiring changed")
        artifacts = Counter(
            line.strip() for line in text.splitlines()
            if line.strip().startswith("--artifact ")
        )
        if artifacts != Counter(WORKFLOW_ARTIFACT_POLICY.get(relative, ())):
            errors.append(f"{relative}: canonical gate artifact wiring changed")
