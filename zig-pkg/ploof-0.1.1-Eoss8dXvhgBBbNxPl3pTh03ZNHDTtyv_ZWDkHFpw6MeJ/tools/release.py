#!/usr/bin/env python3
"""Fail-closed release checks and deterministic source artifact generation."""

from __future__ import annotations

import argparse
import datetime
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
sys.dont_write_bytecode = True

from release_common import (
    ROOT,
    ReleaseError,
    REVISION_RE,
    SHA256_RE,
    canonical_revision,
    copy_regular_nofollow,
    create_exclusive_nofollow,
    ensure_directory_nofollow,
    fail,
    git,
    git_file,
    git_json,
    parse_zon,
    read_json,
    release_version,
    run,
    safe_relative,
    sha256_bytes,
    sha256_file,
    sha256_regular_nofollow,
    write_json,
)
from release_artifact_check import (
    create_source_tar,
    package_files as checked_package_files,
    provenance_document,
    spdx_document,
    verify_metadata,
)
from release_environment import (
    check_host,
    evidence_environment,
    missing_cpu_features,
    require_evidence_checkout,
    require_kernel_minimum,
    runner_info,
    runner_case_id,
)
from release_external_evidence import verify_report_external_artifact
from release_evidence_tree import bounded_evidence_reports, bounded_regular_entries
from release_gate_commands import canonical_gate_command
from release_gate_artifacts import verify_gate_artifact_policy
from release_notes import verify_release_notes, write_release_notes
from release_structure import check_structure


def package_files(root: Path, revision: str, paths: list[str]) -> list[tuple[str, str, str]]:
    return checked_package_files(root, revision, paths, git)

def zig_package_hash(zig: str, root: Path, archive: Path) -> str:
    version = run([zig, "version"], root).stdout.strip()
    if version != "0.16.0":
        fail(f"release requires Zig 0.16.0 exactly, found {version!r}")
    with tempfile.TemporaryDirectory(prefix="ploof-zig-hash-") as directory:
        result = run(
            [zig, "fetch", "--global-cache-dir", directory, "--debug-hash", str(archive)],
            root,
        )
    lines = [line for line in result.stdout.splitlines() if line and not line.startswith("file: ")]
    if len(lines) != 1 or not lines[0].startswith("ploof-"):
        fail("Zig package hash output was incomplete or ambiguous")
    return lines[0]

def candidate_hash(root: Path, revision: str, path: str) -> str:
    return sha256_bytes(git_file(root, revision, path))


def prepare_output(output: Path) -> None:
    if output.is_symlink():
        fail("release output directory must not be a symlink")
    if output.exists():
        if not output.is_dir():
            fail("release output must be a directory")
        try:
            if next(output.iterdir(), None) is not None:
                fail("release output directory must be empty")
        except OSError as error:
            fail(f"release output directory is unreadable: {error}")
        return
    try:
        output.mkdir(parents=True)
    except OSError as error:
        fail(f"release output directory cannot be created: {error}")


def candidate_zon(root: Path, revision: str) -> dict:
    try:
        text = git_file(root, revision, "build.zig.zon").decode("utf-8")
    except UnicodeError as error:
        fail(f"candidate build.zig.zon is not UTF-8: {error}")
    zon = parse_zon(text)
    if zon["name"] != "ploof" or zon["minimum_zig_version"] != "0.16.0":
        fail("candidate package name or minimum Zig version is unsupported")
    release_version(zon["version"])
    return zon


def validate_artifact_manifest(root: Path, manifest: dict) -> tuple[str, str, dict]:
    required = {
        "schema_version", "name", "version", "revision", "source_date_epoch",
        "zig_version", "zig_package_hash", "support_matrix_sha256",
        "gate_manifest_sha256", "artifacts",
    }
    if set(manifest) != required or type(manifest["schema_version"]) is not int:
        fail("artifact manifest has unexpected shape or version")
    if manifest["schema_version"] != 1:
        fail("artifact manifest has unexpected shape or version")
    if manifest["name"] != "ploof" or manifest["zig_version"] != "0.16.0":
        fail("artifact manifest has unsupported package or Zig version")
    version = release_version(manifest["version"])
    raw_revision = manifest["revision"]
    if not isinstance(raw_revision, str) or not REVISION_RE.fullmatch(raw_revision):
        fail("artifact manifest revision must be a full canonical Git commit ID")
    revision = canonical_revision(root, raw_revision)
    if revision != raw_revision:
        fail("artifact manifest revision is not canonical")
    epoch = manifest["source_date_epoch"]
    if type(epoch) is not int or epoch < 1:
        fail("artifact manifest source date epoch is invalid")
    actual_epoch = int(str(git(root, "show", "-s", "--format=%ct", revision)).strip())
    if epoch != actual_epoch:
        fail("artifact manifest source date epoch does not match candidate commit")
    hashes = (manifest["support_matrix_sha256"], manifest["gate_manifest_sha256"])
    if any(not isinstance(value, str) or not SHA256_RE.fullmatch(value) for value in hashes):
        fail("artifact manifest candidate source hash is malformed")
    package_hash = manifest["zig_package_hash"]
    valid_package_hash = isinstance(package_hash, str) and re.fullmatch(
        r"ploof-[A-Za-z0-9._-]{14,194}", package_hash,
    )
    if not valid_package_hash:
        fail("artifact manifest Zig package hash is malformed")
    if not isinstance(manifest["artifacts"], list) or len(manifest["artifacts"]) != 6:
        fail("artifact manifest must contain exactly six artifacts")
    zon = candidate_zon(root, revision)
    if zon["version"] != version:
        fail("artifact manifest version does not match candidate package")
    return revision, version, zon


def verify_directory_subjects(directory: Path, expected: set[str]) -> None:
    entries = bounded_regular_entries(directory, len(expected) + 1)
    actual = {entry.name for entry in entries}
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"release directory subject set mismatch; missing={missing}, extra={extra}")


def read_ascii(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        fail(f"{label} is unreadable or not ASCII: {error}")

def generate_release(root: Path, revision: str, output: Path, zig: str, evidence: Path) -> Path:
    revision = canonical_revision(root, revision)
    zon = candidate_zon(root, revision)
    version = release_version(zon["version"])
    dependencies = git_json(root, revision, "release/dependencies.json")
    epoch = int(str(git(root, "show", "-s", "--format=%ct", revision)).strip())
    prepare_output(output)
    base = f"ploof-{version}"
    archive = output / f"{base}.tar"
    create_source_tar(root, revision, zon, archive, epoch)
    archive_hash = sha256_file(archive)
    package_hash = zig_package_hash(zig, root, archive)
    checksum = output / f"{base}.sha256"
    checksum.write_text(f"{archive_hash}  {archive.name}\n", encoding="ascii")
    zig_hash_path = output / f"{base}.zig-hash"
    zig_hash_path.write_text(package_hash + "\n", encoding="ascii")
    sbom = output / f"{base}.spdx.json"
    write_json(sbom, spdx_document(version, revision, archive.name, archive_hash,
                                   epoch, dependencies))
    provenance = output / f"{base}.provenance.json"
    write_json(provenance, provenance_document(revision, archive.name, archive_hash,
                                               epoch, zon["paths"]))
    artifacts = [archive, checksum, zig_hash_path, sbom, provenance]
    notes = output / f"{base}.release-notes.md"
    write_release_notes(root, revision, version, artifacts, package_hash, evidence, notes)
    artifacts.append(notes)
    manifest = {
        "schema_version": 1,
        "name": "ploof",
        "version": version,
        "revision": revision,
        "source_date_epoch": epoch,
        "zig_version": "0.16.0",
        "zig_package_hash": package_hash,
        "support_matrix_sha256": candidate_hash(root, revision, "release/support-matrix.json"),
        "gate_manifest_sha256": candidate_hash(root, revision, "release/gates.json"),
        "artifacts": [
            {"path": path.name, "sha256": sha256_file(path)} for path in artifacts
        ],
    }
    manifest_path = output / f"{base}.manifest.json"
    write_json(manifest_path, manifest)
    return manifest_path

def verify_release(root: Path, manifest_path: Path, reproduce: bool, zig: str,
                   evidence: Path) -> None:
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail("release artifact manifest must be a regular file")
    manifest = read_json(manifest_path)
    revision, version, zon = validate_artifact_manifest(root, manifest)
    support_hash = candidate_hash(root, revision, "release/support-matrix.json")
    gate_hash = candidate_hash(root, revision, "release/gates.json")
    if manifest["support_matrix_sha256"] != support_hash:
        fail("artifact manifest support matrix does not match source")
    if manifest["gate_manifest_sha256"] != gate_hash:
        fail("artifact manifest gate set does not match source")
    directory = manifest_path.parent
    seen: set[str] = set()
    for artifact in manifest["artifacts"]:
        verify_artifact_record(directory, artifact, seen)
    base = f"ploof-{version}"
    expected = {f"{base}{suffix}" for suffix in (
        ".tar", ".sha256", ".zig-hash", ".spdx.json", ".provenance.json",
        ".release-notes.md",
    )}
    if seen != expected:
        fail("artifact manifest is missing or adds release subjects")
    if manifest_path.name != f"{base}.manifest.json":
        fail("release artifact manifest filename is not canonical")
    verify_directory_subjects(directory, expected | {manifest_path.name})
    checksum = read_ascii(directory / f"{base}.sha256", "source checksum file")
    archive_hash = sha256_file(directory / f"{base}.tar")
    if checksum != f"{archive_hash}  {base}.tar\n":
        fail("source archive checksum file does not match archive")
    if read_ascii(directory / f"{base}.zig-hash", "Zig package hash file").strip() != \
            manifest["zig_package_hash"]:
        fail("Zig package hash file does not match manifest")
    dependency_policy = git_json(root, revision, "release/dependencies.json")
    verify_metadata(root, directory, manifest, dependency_policy, zon)
    verify_release_notes(root, directory, manifest, evidence)
    if reproduce:
        reproduce_release(root, manifest, directory, zig, evidence)

def verify_artifact_record(directory: Path, artifact: object, seen: set[str]) -> None:
    if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}:
        fail("artifact record has unexpected shape")
    if not isinstance(artifact["path"], str) or not isinstance(artifact["sha256"], str):
        fail("artifact record path and SHA-256 must be strings")
    path = safe_relative(artifact["path"])
    if len(path.parts) != 1 or str(path) in seen:
        fail(f"duplicate or nested release artifact: {path}")
    if not SHA256_RE.fullmatch(artifact["sha256"]):
        fail(f"invalid SHA-256 for {path}")
    resolved = directory / str(path)
    if not resolved.is_file() or resolved.is_symlink():
        fail(f"release artifact is missing or not a regular file: {path}")
    if sha256_file(resolved) != artifact["sha256"]:
        fail(f"release artifact hash mismatch: {path}")
    seen.add(str(path))

def reproduce_release(root: Path, manifest: dict, directory: Path, zig: str,
                      evidence: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="ploof-reproduce-") as temporary:
        generated = generate_release(root, manifest["revision"], Path(temporary), zig, evidence)
        regenerated = read_json(generated)
        expected_hashes = {item["path"]: item["sha256"] for item in manifest["artifacts"]}
        actual_hashes = {item["path"]: item["sha256"] for item in regenerated["artifacts"]}
        if actual_hashes != expected_hashes:
            fail("release artifacts are not reproducible from candidate revision")
        if generated.read_bytes() != (directory / generated.name).read_bytes():
            fail("release artifact manifest is not reproducible")

def verify_tag(root: Path, tag: str, revision: str) -> None:
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        fail(f"invalid release tag: {tag!r}")
    kind = str(git(root, "cat-file", "-t", f"refs/tags/{tag}")).strip()
    if kind != "tag":
        fail("release tag must be annotated")
    run(["git", "verify-tag", tag], root)
    actual = canonical_revision(root, tag)
    expected = canonical_revision(root, revision)
    if actual != expected:
        fail(f"tag resolves to {actual}, expected {expected}")
    zon = parse_zon(str(git(root, "show", f"{expected}:build.zig.zon")))
    version = release_version(zon["version"])
    if tag != f"v{version}":
        fail(f"tag {tag} does not match package version {zon['version']}")

def gate_manifest(root: Path, revision: str | None = None) -> dict:
    if revision is None:
        return read_json(root / "release/gates.json")
    return git_json(root, revision, "release/gates.json")

def gate_ids(root: Path, revision: str | None = None) -> list[str]:
    manifest = gate_manifest(root, revision)
    valid_version = type(manifest.get("schema_version")) is int
    if not valid_version or manifest["schema_version"] != 1:
        fail("gate manifest has unsupported shape or version")
    if not isinstance(manifest.get("gates"), list):
        fail("gate manifest has unsupported shape or version")
    values = [gate.get("id") for gate in manifest["gates"] if isinstance(gate, dict)]
    if any(not isinstance(value, str) or not value for value in values):
        fail("gate manifest contains invalid gate ID")
    if len(values) != len(set(values)):
        fail("gate manifest contains duplicate gate ID")
    return values


def minimum_artifacts(root: Path, gate_id: str, revision: str) -> int:
    manifest = gate_manifest(root, revision)
    policy = manifest.get("artifact_policy", {})
    minimum = policy.get("default_minimum", 1)
    by_prefix = policy.get("minimum_by_prefix", {})
    by_gate = policy.get("minimum_by_gate", {})
    if type(minimum) is not int or minimum < 1:
        fail("gate artifact policy has invalid default minimum")
    if not isinstance(by_prefix, dict) or not isinstance(by_gate, dict):
        fail("gate artifact policy has invalid mappings")
    mappings = (*by_prefix.items(), *by_gate.items())
    if any(
        not isinstance(key, str) or not key or type(value) is not int or value < 1
        for key, value in mappings
    ):
        fail("gate artifact policy has invalid mapping entry")
    matches = [value for prefix, value in by_prefix.items() if gate_id.startswith(prefix)]
    if matches:
        minimum = max(matches)
    minimum = by_gate.get(gate_id, minimum)
    if type(minimum) is not int or minimum < 1:
        fail(f"gate artifact policy is invalid for {gate_id}")
    return minimum


def copy_evidence_artifacts(output: Path, gate_id: str, paths: list[str]) -> list[dict]:
    records: list[dict] = []
    target = output / "artifacts" / gate_id
    names: set[str] = set()
    for value in paths:
        source = Path(value)
        if source.name in names:
            fail(f"duplicate evidence artifact name: {source.name}")
        names.add(source.name)
        destination = target / source.name
        digest = copy_regular_nofollow(source, destination)
        relative = destination.relative_to(output).as_posix()
        records.append({"path": relative, "sha256": digest})
    return records


def record_gate(
    root: Path,
    output: Path,
    gate_id: str,
    revision: str,
    command: list[str],
    artifacts: list[str],
) -> None:
    if not command:
        fail("gate command is required after --")
    revision = canonical_revision(root, revision)
    if gate_id not in gate_ids(root, revision):
        fail(f"unknown release gate: {gate_id}")
    expected_command = canonical_gate_command(root, revision, gate_id)
    if command != expected_command:
        fail(f"{gate_id}: command does not match canonical gate policy")
    require_evidence_checkout(root, revision, output)
    ensure_directory_nofollow(output)
    log = output / f"{gate_id}.log"
    started = datetime.datetime.now(datetime.timezone.utc)
    with os.fdopen(create_exclusive_nofollow(log), "wb") as stream:
        result = subprocess.run(
            command, cwd=root, stdout=stream, stderr=subprocess.STDOUT,
            env=evidence_environment(revision, gate_id),
        )
        returncode = result.returncode
        if returncode == 0:
            try:
                require_evidence_checkout(root, revision, output)
            except ReleaseError as error:
                stream.seek(0, os.SEEK_END)
                stream.write(f"\nrelease check: {error}\n".encode("utf-8"))
                returncode = 1
    finished = datetime.datetime.now(datetime.timezone.utc)
    records = [{
        "path": log.name,
        "sha256": sha256_regular_nofollow(log, "evidence log"),
    }]
    if returncode == 0:
        records.extend(copy_evidence_artifacts(output, gate_id, artifacts))
    report = {
        "schema_version": 1,
        "gate_id": gate_id,
        "revision": revision,
        "result": "pass" if returncode == 0 else "fail",
        "started_at": started.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "finished_at": finished.isoformat(timespec="seconds").replace("+00:00", "Z"),
        "command": command,
        "runner": runner_info(root),
        "gate_manifest_sha256": candidate_hash(root, revision, "release/gates.json"),
        "support_matrix_sha256": candidate_hash(
            root, revision, "release/support-matrix.json",
        ),
        "artifacts": records,
    }
    suffix = ".json" if returncode == 0 else ".failed.json"
    write_json(output / f"{gate_id}{suffix}", report)
    if returncode != 0:
        fail(f"gate {gate_id} failed with exit code {returncode}; see {log}")


def verify_evidence(
    root: Path,
    evidence: Path,
    revision: str,
    excluded: set[str] | None = None,
) -> None:
    revision = canonical_revision(root, revision)
    all_gates = set(gate_ids(root, revision))
    excluded = excluded or set()
    unknown = excluded - all_gates
    if unknown:
        fail(f"cannot exclude unknown gates: {sorted(unknown)}")
    expected = sorted(all_gates - excluded)
    root_entries = bounded_regular_entries(
        evidence, len(all_gates) * 3 + 1, {"artifacts"},
    )
    failed = sorted(path for path in root_entries if path.name.endswith(".failed.json"))
    if failed:
        fail("failed gate reports are present: " + ", ".join(path.name for path in failed))
    reports = [path for path in root_entries if path.name.endswith(".json")]
    actual = {path.name[:-5] for path in reports}
    missing = sorted(set(expected) - actual)
    extra = sorted(actual - set(expected))
    if missing or extra:
        fail(f"evidence set mismatch; missing={missing}, extra={extra}")
    for gate_id in expected:
        verify_gate_report(root, evidence, gate_id, revision)


def merge_evidence(root: Path, inputs: list[Path], output: Path) -> None:
    known = set(gate_ids(root))
    ensure_directory_nofollow(output)
    reports = 0
    for input_root in inputs:
        if not input_root.is_dir():
            fail(f"evidence input is not a directory: {input_root}")
        for report in bounded_evidence_reports(input_root, max(64, len(known) * 16)):
            relative = report.relative_to(input_root)
            if "artifacts" in relative.parts[:-1]:
                continue
            name = report.name
            gate_id = name[:-12] if name.endswith(".failed.json") else name[:-5]
            if gate_id not in known:
                fail(f"unknown release gate report: {relative}")
            copy_evidence_report(report, output)
            reports += 1
    if reports == 0:
        fail("no release gate reports found in evidence inputs")


def copy_evidence_report(report_path: Path, output: Path) -> None:
    if not report_path.is_file() or report_path.is_symlink():
        fail(f"evidence report must be a regular file: {report_path}")
    report = read_json(report_path)
    destination = output / report_path.name
    copy_identical(report_path, destination)
    artifacts = report.get("artifacts")
    if not isinstance(artifacts, list):
        fail(f"{report_path}: missing artifacts")
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}:
            fail(f"{report_path}: malformed artifact record")
        if not isinstance(artifact["path"], str) or not isinstance(artifact["sha256"], str):
            fail(f"{report_path}: malformed artifact record")
        relative = safe_relative(artifact["path"])
        source = report_path.parent / str(relative)
        if sha256_regular_nofollow(source, "evidence artifact") != artifact["sha256"]:
            fail(f"{report_path}: artifact hash mismatch {relative}")
        destination = output / str(relative)
        copy_identical(source, destination)


def copy_identical(source: Path, destination: Path) -> None:
    copy_regular_nofollow(source, destination, allow_identical=True)


def verify_gate_report(root: Path, evidence: Path, gate_id: str, revision: str) -> None:
    report = read_json(evidence / f"{gate_id}.json")
    required = {
        "schema_version", "gate_id", "revision", "result", "started_at", "finished_at",
        "command", "runner", "gate_manifest_sha256", "support_matrix_sha256", "artifacts",
    }
    if set(report) != required or type(report["schema_version"]) is not int:
        fail(f"{gate_id}: report has unexpected shape or version")
    if report["schema_version"] != 1:
        fail(f"{gate_id}: report has unexpected shape or version")
    if report["gate_id"] != gate_id or report["revision"] != revision:
        fail(f"{gate_id}: identity or revision mismatch")
    if report["result"] != "pass":
        fail(f"{gate_id}: result is not pass")
    command = report["command"]
    if not isinstance(command, list) or not command or any(
        not isinstance(value, str) or not value for value in command
    ):
        fail(f"{gate_id}: command is missing")
    if command != canonical_gate_command(root, revision, gate_id):
        fail(f"{gate_id}: command does not match canonical gate policy")
    gate_hash = candidate_hash(root, revision, "release/gates.json")
    support_hash = candidate_hash(root, revision, "release/support-matrix.json")
    if report["gate_manifest_sha256"] != gate_hash:
        fail(f"{gate_id}: gate manifest hash mismatch")
    if report["support_matrix_sha256"] != support_hash:
        fail(f"{gate_id}: support matrix hash mismatch")
    parse_report_times(report, gate_id)
    runner = report["runner"]
    runner_fields = {
        "name", "architecture", "kernel", "cpu_vendor", "cpu_model", "cpu_flags", "zig",
        "machine_id_sha256", "microcode",
    }
    if not isinstance(runner, dict) or set(runner) != runner_fields:
        fail(f"{gate_id}: runner identity has unexpected shape")
    string_fields = runner_fields - {"cpu_flags"}
    valid_strings = all(
        isinstance(runner[field], str) and bool(runner[field]) for field in string_fields
    )
    if not valid_strings or not isinstance(runner["cpu_flags"], str):
        fail(f"{gate_id}: runner identity is malformed")
    if not SHA256_RE.fullmatch(runner["machine_id_sha256"]):
        fail(f"{gate_id}: runner machine identity is malformed")
    verify_runner_identity(root, revision, gate_id, runner)
    records = report["artifacts"]
    minimum = minimum_artifacts(root, gate_id, revision)
    if not isinstance(records, list) or len(records) < minimum:
        fail(f"{gate_id}: requires at least {minimum} retained evidence artifacts")
    seen: set[str] = set()
    for record in records:
        verify_evidence_artifact(evidence, record, seen, gate_id)
    verify_gate_artifact_policy(root, revision, gate_id, seen)
    verify_report_external_artifact(root, evidence, gate_id, revision, report)


def verify_runner_identity(root: Path, revision: str, gate_id: str, runner: dict) -> None:
    matrix = git_json(root, revision, "release/support-matrix.json")
    target = matrix["production_target"]
    if runner["architecture"] != target["architecture"]:
        fail(f"{gate_id}: evidence runner is not {target['architecture']}")
    require_kernel_minimum(
        runner["kernel"], target["minimum_kernel_version"], f"{gate_id}: evidence",
    )
    if runner["zig"] != matrix["compiler"]["version"]:
        fail(f"{gate_id}: evidence runner used Zig {runner['zig']}")
    flags = runner["cpu_flags"]
    if not isinstance(flags, str):
        fail(f"{gate_id}: evidence CPU flags are malformed")
    missing = missing_cpu_features(matrix, set(flags.split()))
    if missing:
        fail(f"{gate_id}: evidence CPU lacks x86-64-v3 features: {', '.join(missing)}")
    case_id = runner_case_id(matrix, gate_id)
    if case_id is None:
        return
    cases = {case["id"]: case for case in matrix["kernels"]}
    if case_id not in cases:
        fail(f"{gate_id}: no matching support-matrix case")
    case = cases[case_id]
    require_kernel_minimum(
        runner["kernel"], case["minimum_version"], f"{gate_id}: evidence",
    )
    if runner["cpu_vendor"] != case["cpu_vendor"]:
        fail(f"{gate_id}: evidence CPU vendor is {runner['cpu_vendor']}")


def parse_report_times(report: dict, gate_id: str) -> None:
    try:
        started = datetime.datetime.fromisoformat(report["started_at"].replace("Z", "+00:00"))
        finished = datetime.datetime.fromisoformat(report["finished_at"].replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        fail(f"{gate_id}: invalid evidence timestamp")
    if started.tzinfo is None or finished.tzinfo is None or finished < started:
        fail(f"{gate_id}: invalid evidence time interval")


def verify_evidence_artifact(
    evidence: Path,
    record: object,
    seen: set[str],
    gate_id: str,
) -> None:
    if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
        fail(f"{gate_id}: malformed artifact record")
    if not isinstance(record["path"], str) or not isinstance(record["sha256"], str):
        fail(f"{gate_id}: malformed artifact record")
    path = safe_relative(record["path"])
    if str(path) in seen or not SHA256_RE.fullmatch(record["sha256"]):
        fail(f"{gate_id}: duplicate artifact or invalid hash: {path}")
    gate_log = str(path) == f"{gate_id}.log"
    gate_artifact = len(path.parts) == 3 and path.parts[:2] == ("artifacts", gate_id)
    if not gate_log and not gate_artifact:
        fail(f"{gate_id}: artifact is outside its gate namespace: {path}")
    resolved = evidence / str(path)
    if sha256_regular_nofollow(resolved, "evidence artifact") != record["sha256"]:
        fail(f"{gate_id}: evidence artifact hash mismatch: {path}")
    seen.add(str(path))


def extract_consumer(root: Path, manifest_path: Path, zig: str, reproduce: bool,
                     evidence: Path) -> None:
    verify_release(root, manifest_path, reproduce, zig, evidence)
    manifest = read_json(manifest_path)
    archive = manifest_path.parent / f"ploof-{manifest['version']}.tar"
    with tempfile.TemporaryDirectory(prefix="ploof-consumer-") as temporary, \
            tempfile.TemporaryDirectory(prefix="ploof-consumer-cache-") as cache:
        destination = Path(temporary)
        with tarfile.open(archive, "r") as source:
            for member in source.getmembers():
                safe_relative(member.name)
                if not member.isfile():
                    fail(f"source archive contains non-file entry: {member.name}")
            source.extractall(destination, filter="data")
        package = destination / f"ploof-{manifest['version']}"
        cache_root = Path(cache)
        cache_args = [
            "--cache-dir", str(cache_root / "local"),
            "--global-cache-dir", str(cache_root / "global"),
        ]
        run([zig, "build", "test", *cache_args], package)
        for mode in ("safe", "fast"):
            command = [
                zig, "build", "-Dbenchmarks=true", f"bench-release-{mode}",
                *cache_args, "--", "--list",
            ]
            run(command, package)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--root", type=Path, default=ROOT)
    commands = value.add_subparsers(dest="subcommand", required=True)
    commands.add_parser("structure")
    archive = commands.add_parser("archive")
    archive.add_argument("--revision", required=True)
    archive.add_argument("--output", required=True, type=Path)
    archive.add_argument("--zig", default="zig")
    verify = commands.add_parser("verify-artifacts")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--reproduce", action="store_true")
    verify.add_argument("--zig", default="zig")
    consumer = commands.add_parser("verify-consumer")
    consumer.add_argument("--manifest", required=True, type=Path)
    consumer.add_argument("--reproduce", action="store_true")
    consumer.add_argument("--zig", default="zig")
    for command in (archive, verify, consumer):
        command.add_argument("--evidence", required=True, type=Path)
    tag = commands.add_parser("verify-tag")
    tag.add_argument("--tag", required=True)
    tag.add_argument("--revision", required=True)
    host = commands.add_parser("check-host")
    host.add_argument("--case", required=True)
    record = commands.add_parser("record")
    record.add_argument("--gate", required=True)
    record.add_argument("--revision", required=True)
    record.add_argument("--output", required=True, type=Path)
    record.add_argument("--artifact", action="append", default=[])
    record.add_argument("command", nargs=argparse.REMAINDER)
    evidence = commands.add_parser("verify-evidence")
    evidence.add_argument("--revision", required=True)
    evidence.add_argument("--evidence", required=True, type=Path)
    evidence.add_argument("--exclude-gate", action="append", default=[])
    merge = commands.add_parser("merge-evidence")
    merge.add_argument("--input", required=True, type=Path, action="append")
    merge.add_argument("--output", required=True, type=Path)
    return value


def main() -> int:
    arguments = parser().parse_args()
    root = arguments.root.resolve()
    try:
        if arguments.subcommand == "structure":
            check_structure(root)
        elif arguments.subcommand == "archive":
            manifest = generate_release(
                root, arguments.revision, arguments.output, arguments.zig, arguments.evidence,
            )
            print(manifest)
        elif arguments.subcommand == "verify-artifacts":
            verify_release(root, arguments.manifest, arguments.reproduce,
                           arguments.zig, arguments.evidence)
        elif arguments.subcommand == "verify-consumer":
            extract_consumer(root, arguments.manifest, arguments.zig,
                             arguments.reproduce, arguments.evidence)
        elif arguments.subcommand == "verify-tag":
            verify_tag(root, arguments.tag, arguments.revision)
        elif arguments.subcommand == "check-host":
            check_host(root, arguments.case)
        elif arguments.subcommand == "record":
            command = arguments.command
            if command[:1] == ["--"]:
                command = command[1:]
            record_gate(root, arguments.output, arguments.gate, arguments.revision,
                        command, arguments.artifact)
        elif arguments.subcommand == "verify-evidence":
            verify_evidence(
                root,
                arguments.evidence,
                arguments.revision,
                set(arguments.exclude_gate),
            )
        elif arguments.subcommand == "merge-evidence":
            merge_evidence(root, arguments.input, arguments.output)
    except ReleaseError as error:
        print(f"release check: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
