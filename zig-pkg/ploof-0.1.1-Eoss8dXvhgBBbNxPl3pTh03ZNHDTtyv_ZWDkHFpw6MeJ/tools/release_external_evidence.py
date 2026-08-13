"""Semantic validation for retained external release-gate evidence."""

from __future__ import annotations

import datetime
import hashlib
import os
from pathlib import Path, PurePosixPath
import tarfile

from release_artifact_check import validate_dependency_policy
from release_common import (
    ROOT,
    REVISION_RE,
    SHA256_RE,
    canonical_revision,
    fail,
    git_file,
    git_json,
    open_regular_nofollow,
    parse_json,
)
from release_environment import missing_cpu_features, require_kernel_minimum


LOAD_DRIVER_BINARY_PATH = "bin/ploof-load-driver"
LOAD_DRIVER_SOURCE_PATHS = (
    "tools/load_driver.zig",
    "tools/load_driver_config.zig",
    "tools/load_driver_engine.zig",
    "tools/load_driver_histogram.zig",
    "tools/load_driver_http.zig",
    "tools/load_driver_linux.zig",
    "tools/load_driver_report.zig",
)


MANIFEST_FIELDS = {
    "schema_version", "gate_id", "candidate_revision", "baseline_revision",
    "optimization_modes", "cases_by_mode", "fuzz_budget", "soak", "hosts",
    "resource_plateau", "topologies", "workloads", "sigbench", "load_driver",
    "proxy_images", "artifacts",
}
CONTRACT_FIELDS = {
    "baseline_required", "optimization_modes", "case_parity", "fuzz_budget",
    "soak_seconds", "host_roles", "physical_host_roles", "distinct_host_roles",
    "resource_plateau_seconds", "topologies", "workloads", "sigbench",
    "load_driver", "proxy_ids",
}
HOST_FIELDS = {
    "role", "kind", "machine_id_sha256", "architecture", "kernel",
    "operating_system", "cpu_vendor", "cpu_model", "cpu_flags",
    "inventory_id_sha256",
}
LIMIT_FIELDS = {
    "max_members", "max_member_bytes", "max_total_unpacked_bytes",
    "max_tar_bytes", "max_manifest_bytes",
}
PLATEAU_FIELDS = {
    "measurement_seconds", "samples", "post_start_framework_allocations",
    "descriptor_delta", "rss_stable", "workspace_stable", "operation_stable",
}
TAR_BLOCK_BYTES = 512
TAR_REGULAR_TYPES = {b"\0", b"0", b"5"}


def external_contract(gates: dict, gate_id: str) -> tuple[str, dict, dict] | None:
    policy = gates.get("external_evidence_policy")
    if policy is None:
        return None
    required = {
        "schema_version", "manifest_path", "archive_limits", "profiles", "contracts",
    }
    if not isinstance(policy, dict) or set(policy) != required:
        fail("external evidence policy has unexpected shape")
    if type(policy["schema_version"]) is not int or policy["schema_version"] != 1:
        fail("external evidence policy has unsupported version")
    manifest_path = policy["manifest_path"]
    limits = policy["archive_limits"]
    profiles = policy["profiles"]
    contracts = policy["contracts"]
    if manifest_path != "external-evidence-manifest.json":
        fail("external evidence manifest path is unsupported")
    if not isinstance(limits, dict) or set(limits) != LIMIT_FIELDS:
        fail("external evidence archive limits are malformed")
    if any(type(value) is not int or value <= 0 for value in limits.values()):
        fail("external evidence archive limits are invalid")
    if not isinstance(profiles, dict) or not isinstance(contracts, dict):
        fail("external evidence contracts are malformed")
    profile_name = contracts.get(gate_id)
    if profile_name is None:
        return None
    if not isinstance(profile_name, str) or profile_name not in profiles:
        fail(f"{gate_id}: external evidence profile is unknown")
    contract = profiles[profile_name]
    if not isinstance(contract, dict) or set(contract) != CONTRACT_FIELDS:
        fail(f"{gate_id}: external evidence contract has unexpected shape")
    validate_contract(contract, gate_id)
    return manifest_path, contract, limits


def validate_contract(contract: dict, gate_id: str) -> None:
    for key in ("baseline_required", "case_parity", "sigbench", "load_driver"):
        if not isinstance(contract[key], bool):
            fail(f"{gate_id}: external evidence contract has invalid {key}")
    for key in (
        "optimization_modes", "host_roles", "physical_host_roles",
        "distinct_host_roles", "topologies", "workloads", "proxy_ids",
    ):
        if not valid_unique_strings(contract[key], allow_empty=True):
            fail(f"{gate_id}: external evidence contract has invalid {key}")
    roles = set(contract["host_roles"])
    if not set(contract["physical_host_roles"]) <= roles:
        fail(f"{gate_id}: physical host role is undeclared")
    if not set(contract["distinct_host_roles"]) <= roles:
        fail(f"{gate_id}: distinct host role is undeclared")
    for key in ("soak_seconds", "resource_plateau_seconds"):
        value = contract[key]
        if value is not None and (type(value) is not int or value <= 0):
            fail(f"{gate_id}: external evidence contract has invalid {key}")
    budget = contract["fuzz_budget"]
    budget_fields = {
        "target_families", "processes_per_target", "generated_cases_per_process",
        "timeout_seconds_per_process",
    }
    if budget is None:
        return
    if not isinstance(budget, dict) or set(budget) != budget_fields:
        fail(f"{gate_id}: fuzz budget contract has unexpected shape")
    if not valid_unique_strings(budget["target_families"], allow_empty=False):
        fail(f"{gate_id}: fuzz target-family contract is malformed")
    for key in budget_fields - {"target_families"}:
        if type(budget[key]) is not int or budget[key] <= 0:
            fail(f"{gate_id}: fuzz budget contract has invalid {key}")


def verify_external_artifact(
    artifact: Path,
    gate_id: str,
    revision: str,
    gates: dict,
    dependencies: dict,
    support_matrix: dict,
    report: dict | None = None,
    source_root: Path | None = None,
) -> dict:
    if not REVISION_RE.fullmatch(revision):
        fail(f"{gate_id}: candidate revision is malformed")
    if not isinstance(support_matrix, dict):
        fail(f"{gate_id}: support matrix is malformed")
    selected = external_contract(gates, gate_id)
    if selected is None:
        fail(f"{gate_id}: gate has no external evidence contract")
    manifest_path, contract, limits = selected
    if artifact.name != f"{gate_id}.tar":
        fail(f"{gate_id}: external evidence tar has unexpected name")
    manifest = load_external_manifest(artifact, manifest_path, limits)
    verify_manifest_identity(manifest, gate_id, revision, contract)
    verify_modes_and_cases(manifest, gate_id, contract)
    verify_hosts(manifest, gate_id, contract, support_matrix, report)
    verify_fuzz_budget(manifest, gate_id, contract)
    verify_soak(manifest, gate_id, contract, report)
    verify_resource_plateau(manifest, gate_id, contract)
    verify_exact_list(manifest, contract, "topologies", gate_id)
    verify_exact_list(manifest, contract, "workloads", gate_id)
    verify_proxy_images(manifest, gate_id, contract, support_matrix)
    verify_sigbench(manifest, gate_id, contract, dependencies)
    verify_load_driver(manifest, gate_id, contract, source_root, revision)
    return manifest


def verify_report_external_artifact(
    root: Path,
    evidence: Path,
    gate_id: str,
    revision: str,
    report: dict,
) -> None:
    gates = git_json(root, revision, "release/gates.json")
    if external_contract(gates, gate_id) is None:
        return
    expected = f"artifacts/{gate_id}/{gate_id}.tar"
    tar_paths = [
        item.get("path") for item in report["artifacts"]
        if str(item.get("path", "")).endswith(".tar")
    ]
    if tar_paths != [expected]:
        fail(f"{gate_id}: exactly one contracted external evidence tar is required")
    manifest = verify_external_artifact(
        evidence / expected,
        gate_id,
        revision,
        gates,
        git_json(root, revision, "release/dependencies.json"),
        git_json(root, revision, "release/support-matrix.json"),
        report,
        root,
    )
    baseline = manifest["baseline_revision"]
    if baseline is not None and canonical_revision(root, baseline) != baseline:
        fail(f"{gate_id}: baseline revision is not canonical")


def load_external_manifest(artifact: Path, manifest_path: str, limits: dict) -> dict:
    descriptor = open_regular_nofollow(artifact, "external evidence artifact")
    try:
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            encoded_size = os.fstat(descriptor).st_size
            if encoded_size > limits["max_tar_bytes"]:
                fail("external evidence tar exceeds encoded-size limit")
            validate_raw_tar_headers(stream, encoded_size, limits["max_members"])
            with tarfile.open(fileobj=stream, mode="r:") as archive:
                members: list[tarfile.TarInfo] = []
                for member in archive:
                    if len(members) >= limits["max_members"]:
                        fail("external evidence tar exceeds member-count limit")
                    members.append(member)
                validate_tar_members(members, manifest_path, limits)
                member = next(item for item in members if item.name == manifest_path)
                if member.size <= 0 or member.size > limits["max_manifest_bytes"]:
                    fail("external evidence manifest size is invalid")
                source = archive.extractfile(member)
                if source is None:
                    fail("external evidence manifest is unreadable")
                contents = source.read(member.size + 1)
                if len(contents) != member.size:
                    fail("external evidence manifest length mismatch")
                manifest = parse_strict_json(contents, manifest_path)
                verify_internal_artifacts(archive, members, manifest_path, manifest)
    except (OSError, tarfile.TarError) as error:
        fail(f"external evidence tar is unreadable: {error}")
    finally:
        os.close(descriptor)
    return manifest


def validate_raw_tar_headers(stream, encoded_size: int, max_members: int) -> None:
    offset = 0
    members = 0
    zero_block = bytes(TAR_BLOCK_BYTES)
    while offset + TAR_BLOCK_BYTES <= encoded_size:
        stream.seek(offset)
        header = stream.read(TAR_BLOCK_BYTES)
        if len(header) != TAR_BLOCK_BYTES:
            fail("external evidence tar has a truncated raw header")
        if header == zero_block:
            stream.seek(0)
            return
        members += 1
        if members > max_members:
            fail("external evidence tar exceeds member-count limit")
        if header[156:157] not in TAR_REGULAR_TYPES:
            fail("external evidence tar has extended or special metadata")
        raw_size = header[124:136]
        if raw_size[0] & 0x80:
            fail("external evidence tar has noncanonical size metadata")
        digits = raw_size.strip(b" \0")
        if digits and any(byte < ord("0") or byte > ord("7") for byte in digits):
            fail("external evidence tar has malformed size metadata")
        size = int(digits or b"0", 8)
        blocks = (size + TAR_BLOCK_BYTES - 1) // TAR_BLOCK_BYTES
        offset += TAR_BLOCK_BYTES + blocks * TAR_BLOCK_BYTES
        if offset > encoded_size:
            fail("external evidence tar member exceeds encoded input")
    fail("external evidence tar has no canonical end marker")


def validate_tar_members(
    members: list[tarfile.TarInfo],
    manifest_path: str,
    limits: dict,
) -> None:
    if len(members) > limits["max_members"]:
        fail("external evidence tar exceeds member-count limit")
    seen: set[str] = set()
    manifests = 0
    unpacked = 0
    for member in members:
        canonical_name = member.name[:-1] if member.isdir() and member.name.endswith("/") \
            else member.name
        path = PurePosixPath(canonical_name)
        controls = any(ord(character) < 32 or ord(character) == 127 for character in member.name)
        unsafe = path.is_absolute() or not path.parts or "\\" in member.name or controls
        unsafe = unsafe or any(part in {"", ".", ".."} for part in path.parts)
        unsafe = unsafe or str(path) != canonical_name
        if unsafe or canonical_name in seen:
            fail(f"external evidence tar has unsafe or duplicate path: {member.name!r}")
        if not member.isfile() and not member.isdir():
            fail(f"external evidence tar has non-file entry: {member.name!r}")
        if member.size < 0 or member.size > limits["max_member_bytes"]:
            fail(f"external evidence tar member exceeds size limit: {member.name!r}")
        unpacked += member.size
        if unpacked > limits["max_total_unpacked_bytes"]:
            fail("external evidence tar exceeds aggregate unpacked-size limit")
        seen.add(canonical_name)
        manifests += int(member.name == manifest_path and member.isfile())
    if manifests != 1:
        fail("external evidence tar must contain one root manifest")


def parse_strict_json(contents: bytes, label: str) -> dict:
    try:
        text = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"{label}: invalid JSON: {error}")
    return parse_json(text, label)


def verify_internal_artifacts(
    archive: tarfile.TarFile,
    members: list[tarfile.TarInfo],
    manifest_path: str,
    manifest: dict,
) -> None:
    records = manifest.get("artifacts")
    if not isinstance(records, list) or not records:
        fail("external evidence manifest has no retained artifacts")
    expected: dict[str, str] = {}
    for record in records:
        if not isinstance(record, dict) or set(record) != {"path", "sha256"}:
            fail("external evidence manifest has malformed artifact record")
        path = record["path"]
        digest = record["sha256"]
        if not isinstance(path, str) or path in expected or not SHA256_RE.fullmatch(str(digest)):
            fail("external evidence manifest has duplicate or malformed artifact")
        expected[path] = digest
    retained = [member for member in members if member.isfile() and member.name != manifest_path]
    if [record["path"] for record in records] != sorted(expected):
        fail("external evidence artifact records are not path-sorted")
    if set(expected) != {member.name for member in retained}:
        fail("external evidence manifest does not cover every retained file")
    if not any(member.size > 0 for member in retained):
        fail("external evidence tar has no nonempty retained file")
    driver = manifest.get("load_driver")
    if isinstance(driver, dict):
        binary = next(
            (member for member in retained if member.name == driver.get("binary_path")),
            None,
        )
        if binary is None or binary.mode & 0o111 == 0:
            fail("external evidence load-driver binary is missing or not executable")
    for member in retained:
        if hash_tar_member(archive, member) != expected[member.name]:
            fail(f"external evidence retained-file hash mismatch: {member.name}")


def hash_tar_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> str:
    source = archive.extractfile(member)
    if source is None:
        fail(f"external evidence retained file is unreadable: {member.name}")
    digest = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def verify_manifest_identity(
    manifest: dict,
    gate_id: str,
    revision: str,
    contract: dict,
) -> None:
    if set(manifest) != MANIFEST_FIELDS or type(manifest.get("schema_version")) is not int:
        fail(f"{gate_id}: external manifest has unexpected shape or version")
    if manifest["schema_version"] != 1:
        fail(f"{gate_id}: external manifest has unexpected shape or version")
    if manifest["gate_id"] != gate_id or manifest["candidate_revision"] != revision:
        fail(f"{gate_id}: external manifest candidate identity mismatch")
    baseline = manifest["baseline_revision"]
    if contract["baseline_required"]:
        if not isinstance(baseline, str) or not REVISION_RE.fullmatch(baseline):
            fail(f"{gate_id}: valid baseline revision is required")
        if baseline == revision:
            fail(f"{gate_id}: baseline and candidate revisions are identical")
    elif baseline is not None:
        fail(f"{gate_id}: baseline revision is forbidden")


def verify_modes_and_cases(manifest: dict, gate_id: str, contract: dict) -> None:
    modes = manifest["optimization_modes"]
    if modes != contract["optimization_modes"]:
        fail(f"{gate_id}: optimization mode set or order mismatch")
    cases = manifest["cases_by_mode"]
    if not isinstance(cases, dict) or set(cases) != set(modes):
        fail(f"{gate_id}: benchmark case modes mismatch")
    values: list[list[str]] = []
    for mode in modes:
        case_ids = cases[mode]
        if not valid_unique_strings(case_ids, allow_empty=False):
            fail(f"{gate_id}: {mode} case identities are malformed")
        values.append(case_ids)
    if contract["case_parity"] and any(value != values[0] for value in values[1:]):
        fail(f"{gate_id}: optimization modes do not have case parity")


def verify_hosts(
    manifest: dict,
    gate_id: str,
    contract: dict,
    support_matrix: dict,
    report: dict | None,
) -> None:
    hosts = manifest["hosts"]
    if not isinstance(hosts, list) or len(hosts) != len(contract["host_roles"]):
        fail(f"{gate_id}: host identity set is incomplete")
    target = support_matrix.get("production_target")
    if not isinstance(target, dict):
        fail(f"{gate_id}: production host contract is malformed")
    operating_system = target.get("operating_system")
    architecture = target.get("architecture")
    minimum_kernel = target.get("minimum_kernel_version")
    if not all(isinstance(value, str) and value for value in (
        operating_system, architecture, minimum_kernel,
    )):
        fail(f"{gate_id}: production host contract is malformed")
    roles: list[str] = []
    identities: dict[str, str] = {}
    inventories: dict[str, str] = {}
    for host in hosts:
        if not isinstance(host, dict) or set(host) != HOST_FIELDS:
            fail(f"{gate_id}: host identity has unexpected shape")
        role = host["role"]
        kind = host["kind"]
        identity = host["machine_id_sha256"]
        inventory = host["inventory_id_sha256"]
        facts = [
            host[key] for key in (
                "operating_system", "kernel", "cpu_vendor", "cpu_model", "cpu_flags",
            )
        ]
        valid = isinstance(role, str) and bool(role)
        valid = valid and isinstance(kind, str) and kind in {"physical", "virtual"}
        valid = valid and isinstance(identity, str) and SHA256_RE.fullmatch(identity)
        valid = valid and isinstance(inventory, str) and SHA256_RE.fullmatch(inventory)
        valid = valid and host["architecture"] == architecture
        valid = valid and host["operating_system"] == operating_system
        if not valid or any(not isinstance(value, str) or not value for value in facts):
            fail(f"{gate_id}: host identity is malformed")
        require_kernel_minimum(host["kernel"], minimum_kernel, f"{gate_id}: {role}")
        missing = missing_cpu_features(support_matrix, set(host["cpu_flags"].split()))
        if missing:
            fail(f"{gate_id}: {role} CPU lacks x86-64-v3 features: {', '.join(missing)}")
        roles.append(role)
        identities[role] = identity
        inventories[role] = inventory
    if roles != contract["host_roles"] or len(identities) != len(roles):
        fail(f"{gate_id}: host roles mismatch")
    for role in contract["physical_host_roles"]:
        if hosts[roles.index(role)]["kind"] != "physical":
            fail(f"{gate_id}: {role} must be a physical host")
    distinct = [identities[role] for role in contract["distinct_host_roles"]]
    if len(distinct) != len(set(distinct)):
        fail(f"{gate_id}: required physical hosts are not distinct")
    inventory_ids = [inventories[role] for role in contract["distinct_host_roles"]]
    if len(inventory_ids) != len(set(inventory_ids)):
        fail(f"{gate_id}: protected physical inventory identities are not distinct")
    if report is not None:
        verify_report_host(hosts, identities, report, gate_id)


def verify_report_host(
    hosts: list[dict],
    identities: dict[str, str],
    report: dict,
    gate_id: str,
) -> None:
    runner = report["runner"]
    identity = runner["machine_id_sha256"]
    if identity not in identities.values():
        fail(f"{gate_id}: recorder runner is absent from external host identities")
    host = next(item for item in hosts if item["machine_id_sha256"] == identity)
    facts = ("architecture", "kernel", "cpu_vendor", "cpu_model", "cpu_flags")
    if any(host[key] != runner[key] for key in facts):
        fail(f"{gate_id}: external host facts do not match recorder runner")


def verify_proxy_images(
    manifest: dict,
    gate_id: str,
    contract: dict,
    support_matrix: dict,
) -> None:
    proxies = support_matrix.get("proxies")
    if not isinstance(proxies, list) or any(not isinstance(proxy, dict) for proxy in proxies):
        fail(f"{gate_id}: proxy support matrix is malformed")
    if any(not isinstance(proxy.get("id"), str) or not proxy["id"] for proxy in proxies):
        fail(f"{gate_id}: proxy support matrix is malformed")
    by_id = {proxy.get("id"): proxy for proxy in proxies}
    if len(by_id) != len(proxies):
        fail(f"{gate_id}: proxy support matrix is malformed")
    expected = []
    for proxy_id in contract["proxy_ids"]:
        proxy = by_id.get(proxy_id)
        image = proxy.get("image") if isinstance(proxy, dict) else None
        if not isinstance(image, dict):
            fail(f"{gate_id}: proxy pin is missing: {proxy_id}")
        record = {
            "id": proxy_id,
            "version": proxy.get("version"),
            "repository": image.get("repository"),
            "tag": image.get("tag"),
            "digest": image.get("digest"),
        }
        if any(not isinstance(value, str) or not value for value in record.values()):
            fail(f"{gate_id}: proxy pin is malformed: {proxy_id}")
        expected.append(record)
    if manifest["proxy_images"] != expected:
        fail(f"{gate_id}: proxy image identity mismatch")


def verify_fuzz_budget(manifest: dict, gate_id: str, contract: dict) -> None:
    expected = contract["fuzz_budget"]
    budget = manifest["fuzz_budget"]
    if expected is not None:
        numeric = (
            "processes_per_target",
            "generated_cases_per_process",
            "timeout_seconds_per_process",
        )
        valid = isinstance(budget, dict) and set(budget) == set(expected)
        valid = valid and all(type(budget[key]) is int for key in numeric)
        valid = valid and valid_unique_strings(budget["target_families"], allow_empty=False)
        if not valid:
            fail(f"{gate_id}: fuzz budget is malformed")
    if budget != expected:
        fail(f"{gate_id}: fuzz budget or target-family set mismatch")
    if expected is None:
        return
    cases = manifest["cases_by_mode"]
    if any(cases[mode] != expected["target_families"] for mode in cases):
        fail(f"{gate_id}: fuzz target families and case identities mismatch")


def verify_soak(manifest: dict, gate_id: str, contract: dict, report: dict | None) -> None:
    expected = contract["soak_seconds"]
    soak = manifest["soak"]
    if expected is None:
        if soak is not None:
            fail(f"{gate_id}: soak declaration is forbidden")
        return
    fields = {"started_at", "finished_at", "duration_seconds"}
    if not isinstance(soak, dict) or set(soak) != fields:
        fail(f"{gate_id}: soak declaration has unexpected shape")
    started = parse_time(soak["started_at"], gate_id)
    finished = parse_time(soak["finished_at"], gate_id)
    duration = datetime.timedelta(seconds=expected)
    if type(soak["duration_seconds"]) is not int:
        fail(f"{gate_id}: soak duration must be an integer")
    if soak["duration_seconds"] != expected or finished - started != duration:
        fail(f"{gate_id}: soak interval must be exactly {expected} seconds")
    if report is not None:
        report_start = parse_time(report["started_at"], gate_id)
        report_finish = parse_time(report["finished_at"], gate_id)
        if started < report_start or finished > report_finish:
            fail(f"{gate_id}: soak interval is outside recorder interval")


def verify_resource_plateau(manifest: dict, gate_id: str, contract: dict) -> None:
    expected = contract["resource_plateau_seconds"]
    plateau = manifest["resource_plateau"]
    if expected is None:
        if plateau is not None:
            fail(f"{gate_id}: resource plateau declaration is forbidden")
        return
    if not isinstance(plateau, dict) or set(plateau) != PLATEAU_FIELDS:
        fail(f"{gate_id}: resource plateau declaration has unexpected shape")
    exact = {
        "measurement_seconds": expected,
        "post_start_framework_allocations": 0,
        "descriptor_delta": 0,
        "rss_stable": True,
        "workspace_stable": True,
        "operation_stable": True,
    }
    numeric = ("measurement_seconds", "post_start_framework_allocations", "descriptor_delta")
    if any(type(plateau[key]) is not int for key in numeric):
        fail(f"{gate_id}: resource plateau numeric field is malformed")
    booleans = ("rss_stable", "workspace_stable", "operation_stable")
    if any(type(plateau[key]) is not bool for key in booleans):
        fail(f"{gate_id}: resource plateau boolean field is malformed")
    if any(plateau[key] != value for key, value in exact.items()):
        fail(f"{gate_id}: resource plateau invariant failed")
    if type(plateau["samples"]) is not int or plateau["samples"] < 2:
        fail(f"{gate_id}: resource plateau needs at least two samples")


def verify_exact_list(manifest: dict, contract: dict, key: str, gate_id: str) -> None:
    value = manifest[key]
    if not valid_unique_strings(value, allow_empty=True) or value != contract[key]:
        fail(f"{gate_id}: {key} coverage mismatch")


def verify_sigbench(manifest: dict, gate_id: str, contract: dict, dependencies: dict) -> None:
    value = manifest["sigbench"]
    if not contract["sigbench"]:
        if value is not None:
            fail(f"{gate_id}: Sigbench identity is forbidden")
        return
    build_only = validate_dependency_policy(dependencies)
    matches = [item for item in build_only if item.get("name") == "sigbench"]
    if len(matches) != 1:
        fail(f"{gate_id}: exact Sigbench dependency is missing")
    dependency = matches[0]
    expected = {
        "name": "sigbench", "version": dependency.get("version"),
        "source_sha256": dependency.get("sha256"),
        "zig_hash": dependency.get("zig_hash"),
    }
    if value != expected:
        fail(f"{gate_id}: Sigbench identity mismatch")


def verify_load_driver(
    manifest: dict,
    gate_id: str,
    contract: dict,
    source_root: Path | None,
    revision: str,
) -> None:
    value = manifest["load_driver"]
    if not contract["load_driver"]:
        if value is not None:
            fail(f"{gate_id}: load-driver identity is forbidden")
        return
    fields = {
        "name", "schema_version", "source_sha256", "binary_path", "binary_sha256",
    }
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{gate_id}: load-driver identity has unexpected shape")
    root = source_root or ROOT
    source_hash = load_driver_source_sha256(root, revision if source_root else None)
    valid = value["name"] == "ploof-load-driver"
    valid = valid and type(value["schema_version"]) is int
    valid = valid and value["schema_version"] == 1
    valid = valid and value["source_sha256"] == source_hash
    valid = valid and value["binary_path"] == LOAD_DRIVER_BINARY_PATH
    records = {record["path"]: record["sha256"] for record in manifest["artifacts"]}
    valid = valid and records.get(LOAD_DRIVER_BINARY_PATH) == value["binary_sha256"]
    if not valid:
        fail(f"{gate_id}: load-driver source or retained binary identity mismatch")


def load_driver_source_sha256(root: Path, revision: str | None = None) -> str:
    digest = hashlib.sha256()
    for path in LOAD_DRIVER_SOURCE_PATHS:
        contents = git_file(root, revision, path) if revision else (root / path).read_bytes()
        encoded_path = path.encode("utf-8")
        digest.update(encoded_path)
        digest.update(b"\0")
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def parse_time(value: object, gate_id: str) -> datetime.datetime:
    try:
        parsed = datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        fail(f"{gate_id}: invalid external evidence timestamp")
    if parsed.tzinfo is None or parsed.utcoffset() != datetime.timedelta(0):
        fail(f"{gate_id}: external evidence timestamp must be UTC")
    return parsed


def valid_unique_strings(value: object, allow_empty: bool) -> bool:
    if not isinstance(value, list) or (not allow_empty and not value):
        return False
    return all(isinstance(item, str) and item for item in value) and len(value) == len(set(value))
