"""Render and verify deterministic Ploof release notes."""

from __future__ import annotations

import os
from pathlib import Path
import re

from release_common import (
    SHA256_RE,
    fail,
    git_file,
    git_json,
    open_directory_nofollow,
    parse_json,
    read_json,
    safe_relative,
    sha256_bytes,
    sha256_file,
    sha256_regular_nofollow,
)
from release_external_evidence import external_contract, verify_external_artifact


SOURCE_PATH = "release/release-notes.json"
SOURCE_FIELDS = {
    "schema_version", "version", "changes", "migration", "security", "performance",
}
PROTOCOL_SUPPORT = {
    "application": ["HTTP/1.1"],
    "listener_transport": "cleartext TCP",
    "tls_termination": "upstream reverse proxy",
    "proxy_metadata": ["Forwarded", "X-Forwarded-*", "PROXY protocol v2"],
    "not_implemented": ["HTTP/2", "HTTP/3", "TLS", "QUIC"],
}
SUBJECTS = (
    (".tar", "Source archive"),
    (".sha256", "Archive checksum file"),
    (".zig-hash", "Zig package hash file"),
    (".spdx.json", "SPDX 2.3 SBOM"),
    (".provenance.json", "Local in-toto/SLSA provenance"),
)
BENCHMARK_GATES = (
    ("trusted.sigbench-regression", "sigbench-regression"),
    ("scheduled.runtime-benchmarks", "runtime-benchmarks"),
    ("scheduled.deployment-direct", "deployment-direct"),
    ("scheduled.deployment-caddy", "deployment-caddy"),
    ("scheduled.deployment-nginx", "deployment-nginx"),
)
REPORT_FIELDS = {
    "schema_version", "gate_id", "revision", "result", "started_at", "finished_at",
    "command", "runner", "gate_manifest_sha256", "support_matrix_sha256", "artifacts",
}
PLACEHOLDER_RE = re.compile(
    r"(?i:\b(todo|tbd|fixme|full_commit_sha|replace[- ]?me)\b)|\bVERSION\b|{{|}}|\$\{",
)


def source_document(root: Path, revision: str, version: str) -> tuple[dict, str, str]:
    raw = git_file(root, revision, SOURCE_PATH)
    try:
        text = raw.decode("utf-8")
    except UnicodeError as error:
        fail(f"{revision}:{SOURCE_PATH}: invalid UTF-8: {error}")
    document = parse_json(text, f"{revision}:{SOURCE_PATH}")
    validate_source_document(document, version)
    migration_raw = git_file(root, revision, "docs/MIGRATIONS.md")
    try:
        migration = migration_raw.decode("utf-8")
    except UnicodeError as error:
        fail(f"{revision}:docs/MIGRATIONS.md: invalid UTF-8: {error}")
    if f"## {version}\n" not in migration:
        fail("migration notes have no exact release version section")
    return document, sha256_bytes(raw), sha256_bytes(migration_raw)


def validate_source_document(document: dict, version: str) -> None:
    if set(document) != SOURCE_FIELDS or type(document.get("schema_version")) is not int:
        fail("release notes source has unexpected shape or version")
    if document["schema_version"] != 1:
        fail("release notes source has unexpected shape or version")
    if document.get("version") != version:
        fail("release notes source version does not match package version")
    validate_text(document.get("migration"), "migration")
    validate_text(document.get("security"), "security")
    validate_text(document.get("performance"), "performance")
    changes = document.get("changes")
    if not isinstance(changes, list) or not 1 <= len(changes) <= 32:
        fail("release notes changes must contain 1 to 32 entries")
    if len(changes) != len(set(change for change in changes if isinstance(change, str))):
        fail("release notes changes must be unique")
    for index, change in enumerate(changes):
        validate_text(change, f"changes[{index}]")


def validate_text(value: object, label: str) -> None:
    if not isinstance(value, str) or value != value.strip() or not 1 <= len(value) <= 600:
        fail(f"release notes {label} must be a bounded, trimmed string")
    controls = any(ord(character) < 32 or ord(character) == 127 for character in value)
    if controls or PLACEHOLDER_RE.search(value):
        fail(f"release notes {label} contains a placeholder or newline")


def subject_records(version: str, artifacts: list[dict]) -> list[tuple[str, str, str]]:
    records: dict[str, str] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}:
            fail("release notes artifact record is malformed")
        path = artifact["path"]
        digest = artifact["sha256"]
        if not isinstance(path, str) or not isinstance(digest, str):
            fail("release notes artifact identity is malformed")
        if not SHA256_RE.fullmatch(digest):
            fail("release notes artifact identity is malformed")
        if path in records:
            fail("release notes artifact identity is duplicated")
        records[path] = str(digest)
    base = f"ploof-{version}"
    expected = {base + suffix for suffix, _ in SUBJECTS}
    if set(records) != expected:
        fail("release notes subject set is incomplete or unexpected")
    return [(role, base + suffix, records[base + suffix]) for suffix, role in SUBJECTS]


def compatibility_lines(matrix: dict) -> list[str]:
    if type(matrix.get("schema_version")) is not int or matrix["schema_version"] != 1:
        fail("release support matrix has unsupported schema version")
    target = matrix.get("production_target")
    compiler = matrix.get("compiler")
    if not isinstance(target, dict) or not isinstance(compiler, dict):
        fail("release support matrix target or compiler is malformed")
    if matrix.get("protocol_support") != PROTOCOL_SUPPORT:
        fail("release support matrix protocol contract is missing or changed")
    kernels = matrix.get("kernels")
    proxies = matrix.get("proxies")
    profiles = matrix.get("deployment_profiles")
    if not isinstance(kernels, list) or not isinstance(proxies, list):
        fail("release support matrix hosts or proxies are malformed")
    kernel_fields = all(
        isinstance(case, dict)
        and isinstance(case.get("minimum_version"), str)
        and isinstance(case.get("cpu_vendor"), str)
        for case in kernels
    )
    proxy_fields = all(
        isinstance(proxy, dict)
        and isinstance(proxy.get("name"), str)
        and isinstance(proxy.get("version"), str)
        for proxy in proxies
    )
    target_string_fields = (
        "operating_system", "architecture", "cpu_level", "minimum_kernel_version",
        "optimization",
    )
    target_fields = all(
        isinstance(target.get(key), str) and target[key]
        for key in target_string_fields
    ) and target.get("libc") is False and target.get("liburing") is False
    if not kernel_fields or not proxy_fields or not target_fields:
        fail("release support matrix compatibility fields are malformed")
    expected_target = ("linux", "x86_64", "x86-64-v3", "6.1.0", "ReleaseSafe")
    if tuple(target[key] for key in target_string_fields) != expected_target:
        fail("release support matrix production target is unsupported")
    if compiler.get("version") != "0.16.0":
        fail("release support matrix compiler version is malformed")
    if not isinstance(profiles, list) or not all(
        isinstance(item, str) and item for item in profiles
    ) or len(profiles) != len(set(profiles)):
        fail("release support matrix deployment profiles are malformed")
    kernel_text = ", ".join(
        f">= {case['minimum_version']} ({case['cpu_vendor']})" for case in kernels
    )
    proxy_text = ", ".join(f"{proxy['name']} {proxy['version']}" for proxy in proxies)
    protocol = matrix["protocol_support"]
    return [
        f"- Compiler: Zig `{compiler['version']}` exactly.",
        "- Production platform: "
        f"`{target['operating_system']} {target['architecture']} ({target['cpu_level']})`, "
        f"`{target['optimization']}`; libc: `{str(target['libc']).lower()}`; "
        f"liburing: `{str(target['liburing']).lower()}`.",
        f"- Minimum kernel/CPU cases: {kernel_text}.",
        f"- Application protocol: {', '.join(protocol['application'])}.",
        f"- Listener: {protocol['listener_transport']}; TLS termination: "
        f"{protocol['tls_termination']}.",
        f"- Accepted proxy metadata: {', '.join(protocol['proxy_metadata'])}.",
        f"- Not implemented in this release: {', '.join(protocol['not_implemented'])}.",
        f"- Tested reverse proxies: {proxy_text}.",
        f"- Deployment profiles: {', '.join(profiles)}.",
        f"- Runtime: Linux `{target['minimum_kernel_version']}` or newer plus the "
        "mandatory `io_uring` capability probe; no fallback reactor.",
    ]


def evidence_lines(
    root: Path,
    revision: str,
    source: dict,
    package_hash: str,
) -> list[str]:
    dependencies = git_json(root, revision, "release/dependencies.json")
    build_only = dependencies.get("build_only")
    if not isinstance(build_only, list) or len(build_only) != 1:
        fail("release notes require one exact benchmark dependency")
    benchmark = build_only[0]
    required = {"name", "version", "sha256", "zig_hash"}
    if not isinstance(benchmark, dict) or not required <= set(benchmark):
        fail("release notes benchmark dependency is malformed")
    return [
        str(source["performance"]),
        "",
        "- Headline/gated mode: `ReleaseSafe`; `ReleaseFast` is diagnostic.",
        f"- Benchmark dependency: `{benchmark['name']} {benchmark['version']}`; "
        f"source SHA-256 `{benchmark['sha256']}`; Zig hash `{benchmark['zig_hash']}`.",
        f"- Candidate Zig package identity: `{package_hash}`.",
        "- Numeric results are valid only in retained evidence whose candidate revision, "
        "support-matrix hash, and gate-manifest hash equal the identities above.",
    ]


def evidence_artifacts(evidence: Path, gate_id: str, report: dict) -> tuple[str, str]:
    records = report.get("artifacts")
    if not isinstance(records, list) or not records:
        fail(f"{gate_id}: benchmark report has no retained artifacts")
    seen: set[str] = set()
    tar_records: list[tuple[str, str]] = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
            fail(f"{gate_id}: benchmark artifact record is malformed")
        if not isinstance(record["path"], str) or not isinstance(record["sha256"], str):
            fail(f"{gate_id}: benchmark artifact identity is malformed")
        relative = str(safe_relative(record["path"]))
        digest = record["sha256"]
        if relative in seen or not SHA256_RE.fullmatch(digest):
            fail(f"{gate_id}: benchmark artifact identity is malformed")
        path = evidence / relative
        if sha256_regular_nofollow(path, "benchmark artifact") != digest:
            fail(f"{gate_id}: benchmark artifact is missing or hash-mismatched")
        seen.add(relative)
        if relative.endswith(".tar"):
            tar_records.append((relative, digest))
    expected = f"artifacts/{gate_id}/{gate_id}.tar"
    if len(tar_records) != 1 or tar_records[0][0] != expected:
        fail(f"{gate_id}: exact contracted benchmark tar is missing")
    return tar_records[0]


def load_benchmark_report(
    root: Path,
    revision: str,
    evidence: Path,
    gate_id: str,
    profile: str,
) -> tuple[str, str, str, str]:
    report_path = evidence / f"{gate_id}.json"
    report = read_json(report_path)
    if set(report) != REPORT_FIELDS or type(report.get("schema_version")) is not int:
        fail(f"{gate_id}: benchmark report has unexpected shape or version")
    if report["schema_version"] != 1:
        fail(f"{gate_id}: benchmark report has unexpected shape or version")
    if report.get("gate_id") != gate_id or report.get("revision") != revision:
        fail(f"{gate_id}: benchmark report candidate identity mismatch")
    if report.get("result") != "pass":
        fail(f"{gate_id}: benchmark report result is not pass")
    if not isinstance(report.get("runner"), dict):
        fail(f"{gate_id}: benchmark report runner identity is malformed")
    command = report.get("command")
    if not isinstance(command, list) or not command:
        fail(f"{gate_id}: benchmark report command is missing")
    gates = git_json(root, revision, "release/gates.json")
    policy = gates.get("external_evidence_policy")
    contracts = policy.get("contracts") if isinstance(policy, dict) else None
    if not isinstance(contracts, dict) or contracts.get(gate_id) != profile:
        fail(f"{gate_id}: benchmark evidence profile mismatch")
    selected = external_contract(gates, gate_id)
    if selected is None:
        fail(f"{gate_id}: benchmark evidence contract is missing")
    gate_hash = sha256_bytes(git_file(root, revision, "release/gates.json"))
    support_hash = sha256_bytes(git_file(root, revision, "release/support-matrix.json"))
    if report.get("gate_manifest_sha256") != gate_hash:
        fail(f"{gate_id}: benchmark report gate-manifest hash mismatch")
    if report.get("support_matrix_sha256") != support_hash:
        fail(f"{gate_id}: benchmark report support-matrix hash mismatch")
    tar_path, tar_hash = evidence_artifacts(evidence, gate_id, report)
    verify_external_artifact(
        evidence / tar_path,
        gate_id,
        revision,
        gates,
        git_json(root, revision, "release/dependencies.json"),
        git_json(root, revision, "release/support-matrix.json"),
        report,
        root,
    )
    report_hash = sha256_regular_nofollow(report_path, "benchmark report")
    return report_path.name, report_hash, tar_path, tar_hash


def benchmark_evidence_rows(
    root: Path,
    revision: str,
    evidence: Path,
) -> list[tuple[str, str, str, str, str, str]]:
    descriptor = open_directory_nofollow(evidence)
    os.close(descriptor)
    rows = []
    for gate_id, profile in BENCHMARK_GATES:
        report_path, report_hash, tar_path, tar_hash = load_benchmark_report(
            root, revision, evidence, gate_id, profile,
        )
        rows.append((gate_id, profile, report_path, report_hash, tar_path, tar_hash))
    return rows


def render_release_notes(
    root: Path,
    revision: str,
    version: str,
    artifacts: list[dict],
    package_hash: str,
    evidence: Path,
) -> bytes:
    source, source_hash, migration_hash = source_document(root, revision, version)
    matrix = git_json(root, revision, "release/support-matrix.json")
    matrix_hash = sha256_bytes(git_file(root, revision, "release/support-matrix.json"))
    gates_hash = sha256_bytes(git_file(root, revision, "release/gates.json"))
    rows = subject_records(version, artifacts)
    benchmark_rows = benchmark_evidence_rows(root, revision, evidence)
    lines = [
        f"# Ploof {version}", "", f"Candidate revision: `{revision}`.",
        f"Release-notes input SHA-256: `{source_hash}`.", "", "## Compatibility", "",
        *compatibility_lines(matrix), "", "## Changes", "",
        *(f"- {change}" for change in source["changes"]), "", "## Migration", "",
        str(source["migration"]), "",
        f"Exact source: `docs/MIGRATIONS.md#{version.replace('.', '')}` "
        f"(`sha256:{migration_hash}`).",
        "", "## Security", "", str(source["security"]), "", "## Performance evidence",
        "", f"Candidate identity: `{revision}`.",
        f"Support matrix: `release/support-matrix.json` (`sha256:{matrix_hash}`).",
        f"Gate/evidence contract: `release/gates.json` (`sha256:{gates_hash}`).", "",
        *evidence_lines(root, revision, source, package_hash), "",
        "### Exact benchmark result evidence", "",
        "| Gate | Profile | Report (SHA-256) | Contracted result tar (SHA-256) |",
        "| --- | --- | --- | --- |",
        *(
            f"| `{gate}` | `{profile}` | `{report}` (`{report_hash}`) | "
            f"`{tar}` (`{tar_hash}`) |"
            for gate, profile, report, report_hash, tar, tar_hash in benchmark_rows
        ), "", "## Artifact identities",
        "", "| Role | File | SHA-256 |", "| --- | --- | --- |",
        *(f"| {role} | `{path}` | `{digest}` |" for role, path, digest in rows), "",
        f"Artifact manifest: `ploof-{version}.manifest.json`.",
        "GitHub build provenance is separate signed evidence and must attest the source "
        f"archive subject `{rows[0][1]}` with digest `{rows[0][2]}`.", "",
    ]
    rendered = "\n".join(lines)
    if PLACEHOLDER_RE.search(rendered):
        fail("rendered release notes contain an unresolved placeholder")
    return rendered.encode("utf-8")


def write_release_notes(
    root: Path,
    revision: str,
    version: str,
    artifacts: list[Path],
    package_hash: str,
    evidence: Path,
    destination: Path,
) -> None:
    records = [{"path": path.name, "sha256": sha256_file(path)}
               for path in artifacts]
    try:
        destination.write_bytes(
            render_release_notes(root, revision, version, records, package_hash, evidence),
        )
    except OSError as error:
        fail(f"release notes cannot be written: {error}")


def verify_release_notes(
    root: Path,
    directory: Path,
    manifest: dict,
    evidence: Path,
) -> None:
    version = manifest["version"]
    name = f"ploof-{version}.release-notes.md"
    records = [artifact for artifact in manifest["artifacts"] if artifact["path"] != name]
    expected = render_release_notes(
        root, manifest["revision"], version, records, manifest["zig_package_hash"], evidence,
    )
    try:
        actual = (directory / name).read_bytes()
    except OSError as error:
        fail(f"release notes are unreadable: {error}")
    if actual != expected:
        fail("release notes do not match deterministic candidate content")
