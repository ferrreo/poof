"""Mechanically enforceable package and TigerStyle release checks."""

from __future__ import annotations

import ast
import datetime
from itertools import chain
from pathlib import Path
import re

from release_common import (
    GENERATED_PARTS,
    ReleaseError,
    canonical_json_bytes,
    fail,
    parse_zon,
    safe_relative,
    sha256_bytes,
)
from release_artifact_check import validate_dependency_policy
from release_external_evidence import external_contract
from release_gate_commands import CANONICAL_GATE_IDS
from release_notes import PROTOCOL_SUPPORT, validate_source_document
from release_structure_dependencies import check_dependencies
from release_structure_fuzz import (
    check_fuzz_selector,
    check_test_roots,
    fuzz_filter_reachable,
)
from release_structure_profiles import (
    EXPECTED_ARTIFACT_POLICY,
    EXPECTED_CONTRACTS,
    EXPECTED_FUZZ_FAMILIES,
    check_profiles,
)
from release_structure_workflows import check_workflows
from release_structure_io import (
    MAX_STRUCTURE_TOTAL_BYTES,
    bounded_paths,
    bounded_tree_files,
    excluded_source,
    read_bounded_json,
    read_bounded_text,
)


MARKER_RE = re.compile(r"\b(TODO|FIXME|HACK|XXX)\b")
ROOT_MANIFESTS = {
    "benchmark.zig",
    "compile_failure_api.zig",
    "fuzz.zig",
    "proxy_origin.zig",
    "test.zig",
    "tsan.zig",
}
TYPE_FACTORY_LENGTH_EXCEPTIONS = {
    ("src/application.zig", "Application"),
    ("src/internal/runtime/worker/live_static.zig", "Enabled"),
    ("src/internal/runtime/worker/storage.zig", "Storage"),
}
EXPECTED_KERNEL_MINIMUMS = {
    "linux-6.1-intel": "6.1.177",
    "linux-6.1-amd": "6.1.177",
    "linux-6.6-intel": "6.6.144",
    "linux-6.12-amd": "6.12.95",
    "linux-6.18-intel": "6.18.38",
    "linux-7.1-intel": "7.1.3",
    "linux-7.1-amd": "7.1.3",
}
EXPECTED_SCHEMA_HASHES = {
    "evidence.schema.json": "c06012a694733862595b91752037fb78fe6db48a00b3f11756139e7d96972336",
    "external-evidence.schema.json": (
        "2cd9b048a726e039d99d061fced7cf8c8f08206f794700631003df1937e7d619"
    ),
    "artifact-manifest.schema.json": (
        "4c555a35e1c1de9aed92b9f666c1c719202f1e3e37e25d2efc3a5b258f7c9788"
    ),
    "release-notes.schema.json": (
        "ca7717716ee0c825865db6f49ba8b4833655e49fce4ddc7165866f71d20b8da4"
    ),
}
EXPECTED_PROXY_SCRIPT_SHA256 = "645fd84341587ab3a95f1d36183c32dc6f7a529e08bb606606b3bcc7adb10b09"


def zig_function_lengths(text: str) -> list[tuple[int, str, int]]:
    clean = sanitize_zig(text.splitlines())
    violations: list[tuple[int, str, int]] = []
    pending: dict | None = None
    active: list[dict] = []
    depth = 0
    for number, code in enumerate(clean, 1):
        match = re.search(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", code)
        if match:
            pending = {"start": number, "name": match.group(1), "signature": code}
        elif pending:
            pending["signature"] += " " + code
        opening = code.find("{") if pending else -1
        if pending and opening >= 0:
            factory = re.search(r"\)\s*type\s*\{", pending["signature"]) is not None
            active.append({
                "start": pending["start"],
                "name": pending["name"],
                "depth": depth + 1,
                "count": 0,
                "factory": factory,
                "namespace_depth": None,
            })
            pending = None
        if active:
            function = active[-1]
            body = re.sub(r"[{};,]", "", code).strip()
            namespace = function["factory"] and re.search(r"\breturn\s+struct\b", code)
            if body and number > function["start"] and function["namespace_depth"] is None:
                function["count"] += 1
            if namespace:
                function["namespace_depth"] = depth + 1
        depth += code.count("{") - code.count("}")
        for function in active:
            namespace_depth = function["namespace_depth"]
            if namespace_depth is not None and depth < namespace_depth:
                function["namespace_depth"] = None
        while active and depth < active[-1]["depth"]:
            function = active.pop()
            if function["count"] > 70:
                violations.append((function["start"], function["name"], function["count"]))
        if pending and ";" in code:
            pending = None
    return violations


def sanitize_zig(lines: list[str]) -> list[str]:
    result: list[str] = []
    in_block = False
    for line in lines:
        if line.lstrip().startswith("\\\\"):
            result.append("")
            continue
        output: list[str] = []
        index = 0
        quote = ""
        while index < len(line):
            pair = line[index:index + 2]
            if in_block:
                if pair == "*/":
                    in_block = False
                    index += 2
                else:
                    index += 1
                continue
            if not quote and pair == "/*":
                in_block = True
                index += 2
                continue
            if not quote and pair == "//":
                break
            character = line[index]
            if quote:
                if character == "\\":
                    index += 2
                    continue
                if character == quote:
                    quote = ""
                index += 1
                continue
            if character in {'"', "'"}:
                quote = character
            else:
                output.append(character)
            index += 1
        result.append("".join(output))
    return result


def check_package(root: Path, errors: list[str]) -> None:
    zon_text = read_bounded_text(root / "build.zig.zon", root, errors)
    if zon_text is None:
        return
    zon = parse_zon(zon_text)
    valid_version = re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", zon["version"])
    if not valid_version or zon["name"] != "ploof" or zon["minimum_zig_version"] != "0.16.0":
        errors.append("build.zig.zon: package name or exact minimum Zig version is wrong")
    for value in zon["paths"]:
        try:
            path = safe_relative(value)
        except ReleaseError as error:
            errors.append(f"build.zig.zon: {error}")
            continue
        if not (root / str(path)).exists():
            errors.append(f"build.zig.zon: allowlisted path does not exist: {path}")
    required = ROOT_MANIFESTS | {
        "benchmarks",
        "fuzz",
        "src",
        "tools",
        "tests",
        "docs",
        "release",
        "LICENSE",
        "SECURITY.md",
    }
    missing = required - set(zon["paths"])
    if missing:
        errors.append(f"build.zig.zon: missing package paths: {sorted(missing)}")
    granular_tests = [value for value in zon["paths"] if value.startswith("tests/")]
    if granular_tests:
        errors.append("build.zig.zon: package the complete tests tree, not selected fixtures")
    build_helpers = {path.name for path in root.glob("build*.zig")}
    missing_helpers = sorted(build_helpers - set(zon["paths"]))
    if missing_helpers:
        errors.append(f"build.zig.zon: missing build helpers: {missing_helpers}")


def check_structure(root: Path) -> None:
    errors: list[str] = []
    check_release_manifests(root, errors)
    check_dependencies(root, errors)
    check_package(root, errors)
    check_test_roots(root, errors)
    check_fuzz_selector(root, errors)
    check_test_skips(root, errors)
    source_paths = bounded_paths(chain(
        root.glob("*.zig"),
        bounded_tree_files(root, "build", "structure scan", errors, suffixes={".zig"}),
        bounded_tree_files(root, "benchmarks", "structure scan", errors, suffixes={".zig"}),
        bounded_tree_files(root, "fuzz", "structure scan", errors, suffixes={".zig"}),
        bounded_tree_files(root, "src", "structure scan", errors, suffixes={".zig"}),
        bounded_tree_files(root, "tests", "structure scan", errors, suffixes={".zig"}),
        bounded_tree_files(
            root,
            "tools",
            "structure scan",
            errors,
            suffixes={".zig", ".py", ".sh"},
        ),
    ), "structure scan", errors)
    total_bytes = 0
    for path in source_paths:
        if (excluded_source(path, root) or path.suffix not in {".zig", ".py", ".sh"}):
            continue
        total_bytes += check_source(path, root, errors)
        if total_bytes > MAX_STRUCTURE_TOTAL_BYTES:
            errors.append("structure scan: source bytes exceed aggregate limit")
            break
    check_workflows(root, errors)
    check_docs(root, errors)
    if errors:
        fail("structural checks failed:\n" + "\n".join(f"- {error}" for error in errors))


def check_test_skips(root: Path, errors: list[str]) -> None:
    paths = chain(
        root.glob("*.zig"),
        bounded_tree_files(root, "build", "test-skip scan", errors, suffixes={".zig"}),
        *(bounded_tree_files(
            root,
            directory,
            "test-skip scan",
            errors,
            suffixes={".zig"},
        ) for directory in ("benchmarks", "fuzz", "src", "tools", "tests")),
    )
    total_bytes = 0
    for path in bounded_paths(paths, "test-skip scan", errors):
        if set(path.relative_to(root).parts[:-1]) & GENERATED_PARTS:
            continue
        text = read_bounded_text(path, root, errors)
        if text is None:
            continue
        total_bytes += len(text.encode("utf-8"))
        if total_bytes > MAX_STRUCTURE_TOTAL_BYTES:
            errors.append("test-skip scan: source bytes exceed aggregate limit")
            return
        for number, line in enumerate(text.splitlines(), 1):
            if "SkipZigTest" in line:
                relative = path.relative_to(root)
                errors.append(f"{relative}:{number}: release tests may not skip")


def check_release_manifests(root: Path, errors: list[str]) -> None:
    matrix = read_bounded_json(root / "release/support-matrix.json", root, errors)
    gates = read_bounded_json(root / "release/gates.json", root, errors)
    dependencies = read_bounded_json(root / "release/dependencies.json", root, errors)
    notes = read_bounded_json(root / "release/release-notes.json", root, errors)
    if any(value is None for value in (matrix, gates, dependencies, notes)):
        return
    check_matrix(matrix, errors)
    check_proxy_script(root, matrix, errors)
    check_gates(matrix, gates, errors)
    zon_text = read_bounded_text(root / "build.zig.zon", root, errors)
    if zon_text is not None:
        zon = parse_zon(zon_text)
        try:
            validate_source_document(notes, zon["version"])
        except ReleaseError as error:
            errors.append(f"release/release-notes.json: {error}")
    check_external_invariants(root, gates, errors)
    try:
        validate_dependency_policy(dependencies)
    except ReleaseError as error:
        errors.append(f"release/dependencies.json: {error}")
    for name in (
        "evidence.schema.json", "external-evidence.schema.json",
        "artifact-manifest.schema.json", "release-notes.schema.json",
    ):
        schema = read_bounded_json(root / "release" / name, root, errors)
        if schema is None:
            continue
        if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append(f"release/{name}: unsupported JSON Schema version")
        if sha256_bytes(canonical_json_bytes(schema)) != EXPECTED_SCHEMA_HASHES[name]:
            errors.append(f"release/{name}: canonical schema contract changed")


def check_matrix(matrix: dict, errors: list[str]) -> None:
    check_matrix_target(matrix, errors)
    kernels = matrix.get("kernels", [])
    if not isinstance(kernels, list) or any(not isinstance(case, dict) for case in kernels):
        errors.append("release/support-matrix.json: kernel cases are malformed")
        kernels = []
    ids = [case.get("id") for case in kernels]
    ids_valid = all(isinstance(value, str) and value for value in ids)
    if not ids_valid or len(ids) != len(set(ids)):
        errors.append("release/support-matrix.json: duplicate or empty kernel case")
    raw_series = [case.get("series") for case in kernels]
    series = set(raw_series) if all(isinstance(value, str) for value in raw_series) else set()
    if series != {"6.1", "6.6", "6.12", "6.18", "7.1"}:
        errors.append("release/support-matrix.json: kernel thresholds are incomplete")
    check_cpu_features(matrix, errors)
    check_kernel_hosts(matrix, kernels, errors)
    check_kernel_cases(kernels, errors)
    check_proxy_policy(matrix, errors)
    if matrix.get("protocol_support") != PROTOCOL_SUPPORT:
        errors.append("release/support-matrix.json: protocol contract is incomplete")
    case_ids = {case.get("id") for case in kernels if isinstance(case.get("id"), str)}
    check_gate_hosts(matrix, case_ids, errors)
    profiles = matrix.get("deployment_profiles")
    valid_profiles = isinstance(profiles, list) and all(
        isinstance(profile, str) for profile in profiles
    )
    if not valid_profiles or set(profiles) != {
        "direct-http1", "caddy-http1", "nginx-http1",
    }:
        errors.append("release/support-matrix.json: deployment profiles are incomplete")
    soaks = matrix.get("release_soaks")
    valid_soaks = isinstance(soaks, list) and all(
        isinstance(item, dict)
        and set(item) == {"minimum_version", "duration_seconds"}
        and isinstance(item["minimum_version"], str)
        and type(item["duration_seconds"]) is int
        for item in soaks
    )
    actual_soaks = {
        (item.get("minimum_version"), item.get("duration_seconds")) for item in soaks
    } if valid_soaks else set()
    role_minimums = {
        role: {
            case.get("minimum_version") for case in kernels if case.get("role") == role
        }
        for role in ("floor", "current")
    }
    soak_minimums = role_minimums["floor"] | role_minimums["current"]
    expected_soaks = {(minimum, 86400) for minimum in soak_minimums}
    if any(len(values) != 1 for values in role_minimums.values()) or \
            actual_soaks != expected_soaks:
        errors.append("release/support-matrix.json: minimum-threshold soaks are required")


def check_matrix_target(matrix: dict, errors: list[str]) -> None:
    compiler = matrix.get("compiler")
    valid_schema = type(matrix.get("schema_version")) is int and matrix["schema_version"] == 1
    if not valid_schema or compiler != {"name": "zig", "version": "0.16.0"}:
        errors.append("release/support-matrix.json: unsupported schema or compiler")
    target = matrix.get("production_target")
    required_target = {
        "architecture": "x86_64", "cpu_level": "x86-64-v3",
        "operating_system": "linux", "minimum_kernel_version": "6.1.0",
        "optimization": "ReleaseSafe",
        "libc": False, "liburing": False,
    }
    valid_target = isinstance(target, dict) and set(target) == set(required_target)
    if valid_target:
        valid_target = all(target[key] == value for key, value in required_target.items())
        valid_target = valid_target and type(target["libc"]) is bool
        valid_target = valid_target and type(target["liburing"]) is bool
    if not valid_target:
        errors.append("release/support-matrix.json: production target changed")
    try:
        datetime.date.fromisoformat(matrix.get("as_of", ""))
    except (TypeError, ValueError):
        errors.append("release/support-matrix.json: as_of is not an ISO date")


def check_kernel_cases(kernels: list[dict], errors: list[str]) -> None:
    actual_minimums = {
        case.get("id"): case.get("minimum_version") for case in kernels
        if isinstance(case.get("id"), str)
    }
    if actual_minimums != EXPECTED_KERNEL_MINIMUMS:
        errors.append("release/support-matrix.json: kernel minimum policy changed")
    for case in kernels:
        vendor = case.get("cpu_vendor")
        if not isinstance(vendor, str) or vendor not in {"GenuineIntel", "AuthenticAMD"}:
            errors.append("release/support-matrix.json: unsupported CPU vendor")
        suffix = "intel" if vendor == "GenuineIntel" else "amd"
        expected_id = f"linux-{case.get('series')}-{suffix}"
        minimum = case.get("minimum_version", "")
        exact_minimum = isinstance(minimum, str) and re.fullmatch(
            r"[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}", minimum,
        )
        series_matches = isinstance(minimum, str) and minimum.startswith(
            f"{case.get('series')}.",
        )
        if case.get("id") != expected_id or not exact_minimum or not series_matches:
            errors.append("release/support-matrix.json: invalid kernel case or minimum")
    for role in ("floor", "current"):
        vendors = {
            case.get("cpu_vendor") for case in kernels
            if case.get("role") == role and isinstance(case.get("cpu_vendor"), str)
        }
        if vendors != {"GenuineIntel", "AuthenticAMD"}:
            errors.append(f"release/support-matrix.json: {role} lacks both CPU vendors")


def check_cpu_features(matrix: dict, errors: list[str]) -> None:
    expected = {
        "cx16": ("cx16",),
        "lahf_sahf": ("lahf_lm",),
        "popcnt": ("popcnt",),
        "sse3": ("pni", "sse3"),
        "ssse3": ("ssse3",),
        "sse4_1": ("sse4_1",),
        "sse4_2": ("sse4_2",),
        "avx": ("avx",),
        "avx2": ("avx2",),
        "bmi1": ("bmi1",),
        "bmi2": ("bmi2",),
        "f16c": ("f16c",),
        "fma": ("fma",),
        "lzcnt": ("lzcnt", "abm"),
        "movbe": ("movbe",),
        "xsave": ("xsave",),
    }
    features = matrix.get("cpu_features")
    if not isinstance(features, list):
        errors.append("release/support-matrix.json: CPU feature policy is malformed")
        return
    actual: dict[str, tuple] = {}
    for feature in features:
        if not isinstance(feature, dict) or set(feature) != {"name", "linux_flags"}:
            errors.append("release/support-matrix.json: CPU feature policy is malformed")
            return
        name = feature["name"]
        aliases = feature["linux_flags"]
        if not isinstance(name, str) or not isinstance(aliases, list):
            errors.append("release/support-matrix.json: CPU feature policy is malformed")
            return
        if not aliases or any(not isinstance(alias, str) or not alias for alias in aliases):
            errors.append("release/support-matrix.json: CPU feature policy is malformed")
            return
        actual[name] = tuple(aliases)
    if len(actual) != len(features) or actual != expected:
        errors.append("release/support-matrix.json: cumulative x86-64-v3 proof is incomplete")


def check_kernel_hosts(matrix: dict, kernels: list[dict], errors: list[str]) -> None:
    for case in kernels:
        labels = case.get("runner_labels")
        vendor = case.get("cpu_vendor")
        vendor_label = "intel" if vendor == "GenuineIntel" else "amd"
        expected = {
            "ploof-trusted", f"kernel-min-{case.get('minimum_version')}", vendor_label,
        }
        valid = isinstance(labels, list) and all(isinstance(label, str) for label in labels)
        if not valid or not expected <= set(labels):
            errors.append("release/support-matrix.json: kernel runner labels are incomplete")


def check_proxy_policy(matrix: dict, errors: list[str]) -> None:
    values = matrix.get("proxies", [])
    if not isinstance(values, list) or any(not isinstance(proxy, dict) for proxy in values):
        errors.append("release/support-matrix.json: proxy policy is malformed")
        return
    if any(not isinstance(proxy.get("id"), str) for proxy in values):
        errors.append("release/support-matrix.json: proxy policy is malformed")
        return
    proxies = {proxy["id"]: proxy for proxy in values}
    if set(proxies) != {"caddy", "nginx"}:
        errors.append("release/support-matrix.json: proxy set is incomplete")
    for proxy in proxies.values():
        version = proxy.get("version", "")
        image = proxy.get("image")
        image_valid = isinstance(image, dict) and set(image) == {
            "repository", "tag", "digest",
        }
        repository = image.get("repository") if image_valid else None
        tag = image.get("tag") if image_valid else None
        digest = image.get("digest") if image_valid else ""
        exact = isinstance(version, str) and re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+", version,
        )
        expected_repository = f"docker.io/library/{proxy.get('id')}"
        valid = exact and repository == expected_repository and tag == f"{version}-alpine"
        valid = valid and isinstance(digest, str)
        valid = valid and re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
        source = proxy.get("source")
        if not valid or not isinstance(source, str) or not source.startswith("https://"):
            errors.append("release/support-matrix.json: proxy pin is not exact")


def check_proxy_script(root: Path, matrix: dict, errors: list[str]) -> None:
    path = root / "tools/test-proxy-interop.sh"
    text = read_bounded_text(path, root, errors)
    if text is None:
        return
    if sha256_bytes(text.encode("utf-8")) != EXPECTED_PROXY_SCRIPT_SHA256:
        errors.append("tools/test-proxy-interop.sh: canonical proxy execution changed")
    collapsed = text.replace("\\\n", "")
    actual = {
        name: first + second for name, first, second in re.findall(
            r'^readonly (CADDY|NGINX)_IMAGE="([^"\r\n]+)""([^"\r\n]+)"$',
            collapsed,
            re.MULTILINE,
        )
    }
    proxies = matrix.get("proxies")
    if not isinstance(proxies, list):
        return
    expected: dict[str, str] = {}
    for proxy in proxies:
        if not isinstance(proxy, dict) or not isinstance(proxy.get("image"), dict):
            continue
        image = proxy["image"]
        proxy_id = proxy.get("id")
        if proxy_id not in {"caddy", "nginx"}:
            continue
        expected[proxy_id.upper()] = (
            f"{image.get('repository')}:{image.get('tag')}@{image.get('digest')}"
        )
    if actual != expected:
        errors.append("tools/test-proxy-interop.sh: proxy images do not match support matrix")


def check_gate_hosts(matrix: dict, case_ids: set, errors: list[str]) -> None:
    expected = {
        "release.soak-current": "linux-7.1-amd",
        "release.soak-floor": "linux-6.1-intel",
        "trusted.proxy-matrix": "linux-7.1-intel",
        "trusted.real-io-current": "linux-7.1-amd",
        "trusted.real-io-floor": "linux-6.1-intel",
        "trusted.sigbench-regression": "linux-7.1-amd",
        "trusted.thread-sanitizer": "linux-7.1-intel",
    }
    hosts = matrix.get("gate_hosts")
    if hosts != expected:
        errors.append("release/support-matrix.json: trusted gate hosts are incomplete")
    values_valid = isinstance(hosts, dict) and all(
        isinstance(case_id, str) for case_id in hosts.values()
    )
    if values_valid and not set(hosts.values()) <= case_ids:
        errors.append("release/support-matrix.json: trusted gate host case is unknown")


def check_gates(matrix: dict, manifest: dict, errors: list[str]) -> None:
    gates = manifest.get("gates")
    if not isinstance(gates, list) or any(not isinstance(gate, dict) for gate in gates):
        errors.append("release/gates.json: gate policy is malformed")
        return
    gate_ids = [gate.get("id") for gate in gates]
    valid_ids = all(isinstance(gate_id, str) and gate_id for gate_id in gate_ids)
    valid_schema = type(manifest.get("schema_version")) is int
    if not valid_ids or not valid_schema or manifest["schema_version"] != 1:
        errors.append("release/gates.json: unsupported schema or invalid gate")
        return
    if len(gate_ids) != len(set(gate_ids)):
        errors.append("release/gates.json: unsupported schema or duplicate gate")
        return
    if set(gate_ids) != CANONICAL_GATE_IDS:
        errors.append("release/gates.json: canonical gate command set changed")
    required = {
        "untrusted.structure", "untrusted.correctness", "untrusted.fuzz-smoke",
        "trusted.real-io-floor", "trusted.real-io-current", "trusted.proxy-matrix",
        "trusted.thread-sanitizer", "trusted.sigbench-regression",
        "scheduled.security-fuzz", "scheduled.resource-plateau",
        "scheduled.runtime-benchmarks", "scheduled.deployment-direct",
        "scheduled.deployment-caddy", "scheduled.deployment-nginx",
        "release.fuzz-budget", "release.soak-floor", "release.soak-current",
        "release.signed-tag", "release.archive", "release.documentation",
        "release.provenance",
    }
    kernels = matrix.get("kernels")
    if isinstance(kernels, list):
        required |= {
            f"scheduled.kernel-{case['id']}" for case in kernels
            if isinstance(case, dict) and isinstance(case.get("id"), str)
        }
    missing = sorted(required - set(gate_ids))
    if missing:
        errors.append(f"release/gates.json: missing mandatory gates: {missing}")
    lanes = {gate.get("lane") for gate in gates}
    if lanes != {"untrusted", "trusted", "scheduled", "release"}:
        errors.append("release/gates.json: lane set is incomplete")
    policy = manifest.get("artifact_policy")
    exact_policy = isinstance(policy, dict) and (
        canonical_json_bytes(policy) == canonical_json_bytes(EXPECTED_ARTIFACT_POLICY)
    )
    if not exact_policy:
        errors.append("release/gates.json: exact artifact policy changed")
    check_external_contracts(matrix, manifest, set(gate_ids), errors)


def check_external_contracts(
    matrix: dict,
    manifest: dict,
    gate_ids: set[str],
    errors: list[str],
) -> None:
    expected = {
        "trusted.sigbench-regression", "scheduled.security-fuzz",
        "scheduled.resource-plateau", "scheduled.runtime-benchmarks",
        "scheduled.deployment-direct", "scheduled.deployment-caddy",
        "scheduled.deployment-nginx", "release.fuzz-budget",
        "release.soak-floor", "release.soak-current",
    }
    kernels = matrix.get("kernels", [])
    expected |= {
        f"scheduled.kernel-{case['id']}" for case in kernels
        if isinstance(case, dict) and isinstance(case.get("id"), str)
    }
    policy = manifest.get("external_evidence_policy")
    contracts = policy.get("contracts") if isinstance(policy, dict) else None
    if not isinstance(contracts, dict) or set(contracts) != expected:
        errors.append("release/gates.json: external evidence gate set is incomplete")
        return
    if contracts != EXPECTED_CONTRACTS:
        errors.append("release/gates.json: exact external contract mapping changed")
    if not set(contracts) <= gate_ids:
        errors.append("release/gates.json: external evidence names unknown gate")
        return
    try:
        for gate_id in sorted(expected):
            external_contract(manifest, gate_id)
    except ReleaseError as error:
        errors.append(f"release/gates.json: {error}")


def check_external_invariants(root: Path, manifest: dict, errors: list[str]) -> None:
    policy = manifest.get("external_evidence_policy", {})
    if not isinstance(policy, dict):
        errors.append("release/gates.json: external evidence policy is malformed")
        return
    profiles = policy.get("profiles", {})
    if not isinstance(profiles, dict):
        errors.append("release/gates.json: external evidence profiles are malformed")
        return
    expected_limits = {
        "max_members": 100_000,
        "max_member_bytes": 4_294_967_296,
        "max_total_unpacked_bytes": 34_359_738_368,
        "max_tar_bytes": 35_000_000_000,
        "max_manifest_bytes": 1_048_576,
    }
    if policy.get("archive_limits") != expected_limits:
        errors.append("release/gates.json: external tar safety limits changed")
    fuzz_script = read_bounded_text(root / "tools/run-fuzz-matrix.sh", root, errors)
    if fuzz_script is None:
        return
    match = re.search(
        r"^families='([^']+)'$",
        fuzz_script,
        re.MULTILINE,
    )
    families = match.group(1).split() if match else []
    if families != EXPECTED_FUZZ_FAMILIES:
        errors.append("fuzz family policy changed")
    build_text = read_bounded_text(root / "build.zig", root, errors)
    if build_text is None:
        return
    build_fuzz = root / "build_fuzz.zig"
    if '@import("build_fuzz.zig")' in build_text:
        if not build_fuzz.is_file():
            errors.append("build_fuzz.zig: imported fuzz wiring is missing")
        else:
            build_fuzz_text = read_bounded_text(build_fuzz, root, errors)
            if build_fuzz_text is None:
                return
            build_families = re.findall(r'\.base = "fuzz-([^\"]+)"', build_fuzz_text)
            if families != build_families:
                errors.append("fuzz family matrix does not match build_fuzz.zig")
    check_profiles(profiles, families, errors)


def check_source(path: Path, root: Path, errors: list[str]) -> int:
    text = read_bounded_text(path, root, errors)
    if text is None:
        return 0
    lines = text.splitlines()
    relative = path.relative_to(root)
    if len(lines) > 750:
        errors.append(f"{relative}: {len(lines)} lines exceeds 750")
    if path.suffix == ".zig":
        for number, line in enumerate(lines, 1):
            if len(line) > 100:
                errors.append(f"{relative}:{number}: line width {len(line)} exceeds 100")
            if MARKER_RE.search(line):
                errors.append(f"{relative}:{number}: forbidden debt marker")
        for number, name, length in zig_function_lengths(text):
            if (relative.as_posix(), name) in TYPE_FACTORY_LENGTH_EXCEPTIONS:
                continue
            errors.append(f"{relative}:{number}: {name} body has {length} lines, limit is 70")
    if path.suffix == ".py":
        check_python_lengths(path, root, errors, text)
    return len(text.encode("utf-8"))


def check_python_lengths(path: Path, root: Path, errors: list[str], text: str) -> None:
    try:
        tree = ast.parse(text)
    except SyntaxError as error:
        errors.append(f"{path.relative_to(root)}:{error.lineno}: invalid Python")
        return
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            length = (node.end_lineno or node.lineno) - node.lineno + 1
            if length > 70:
                errors.append(
                    f"{path.relative_to(root)}:{node.lineno}: {node.name} spans {length} lines"
                )


def check_docs(root: Path, errors: list[str]) -> None:
    paths = bounded_paths(chain(
        bounded_tree_files(root, "docs", "docs scan", errors, suffixes={".md"}),
        [root / "README.md", root / "SECURITY.md"],
    ), "docs scan", errors)
    total_bytes = 0
    for path in paths:
        text = read_bounded_text(path, root, errors)
        if text is None:
            continue
        total_bytes += len(text.encode("utf-8"))
        if total_bytes > MAX_STRUCTURE_TOTAL_BYTES:
            errors.append("docs scan: source bytes exceed aggregate limit")
            return
        for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
            target = target.strip("<>").split("#", 1)[0]
            if not target or re.match(r"^[a-z][a-z0-9+.-]*:", target):
                continue
            if not (path.parent / target).resolve().exists():
                errors.append(f"{path.relative_to(root)}: broken local link: {target}")
