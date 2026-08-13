"""Host and checkout policy shared by release evidence commands."""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import socket

from release_common import fail, git, read_json, run, sha256_bytes


EVIDENCE_GENERATED_ROOTS = {".zig-cache", "zig-cache", "zig-out", "zig-pkg"}
MAX_CPU_INFO_BYTES = 16 * 1024 * 1024
KERNEL_RELEASE_RE = re.compile(
    r"^([0-9]+)\.([0-9]+)\.([0-9]+)((?:[-+._][\x21-\x7e]*)?)$",
)
KERNEL_PRERELEASE_RE = re.compile(r"^-rc[0-9]+(?:$|[-+._])")


def require_evidence_checkout(root: Path, revision: str, output: Path) -> None:
    require_generated_output(root, output)
    head = str(git(root, "rev-parse", "--verify", "HEAD^{commit}")).strip()
    if head != revision:
        fail(f"evidence checkout is {head}, expected {revision}")
    issues = checkout_issues(root)
    if issues:
        preview = ", ".join(issues[:8])
        suffix = " ..." if len(issues) > 8 else ""
        fail(f"evidence checkout is not clean: {preview}{suffix}")


def evidence_environment(revision: str, gate_id: str) -> dict[str, str]:
    environment = os.environ.copy()
    environment["PLOOF_CANDIDATE_REVISION"] = revision
    environment["PLOOF_GATE_ID"] = gate_id
    return environment


def require_generated_output(root: Path, output: Path) -> None:
    try:
        relative = output.resolve().relative_to(root.resolve())
    except ValueError:
        fail("evidence output must be inside the checkout's zig-out directory")
    if not relative.parts or relative.parts[0] != "zig-out":
        fail("evidence output must be inside the checkout's zig-out directory")


def checkout_issues(root: Path) -> list[str]:
    raw = git(
        root,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
        "--ignored=matching",
        "--ignore-submodules=none",
        "--no-renames",
        text=False,
    )
    issues: list[str] = []
    for entry in bytes(raw).split(b"\0"):
        if not entry:
            continue
        status = entry[:2].decode("ascii", errors="replace")
        name = entry[3:].decode("utf-8", errors="surrogateescape")
        path = PurePosixPath(name)
        generated = bool(path.parts) and path.parts[0] in EVIDENCE_GENERATED_ROOTS
        if status in {"??", "!!"} and generated:
            continue
        issues.append(f"{status} {name}")
    return issues


def missing_cpu_features(matrix: dict, flags: set[str]) -> list[str]:
    missing: list[str] = []
    features = matrix.get("cpu_features")
    if not isinstance(features, list):
        fail("support matrix CPU feature policy is malformed")
    for feature in features:
        if not isinstance(feature, dict):
            fail("support matrix CPU feature policy is malformed")
        name = feature.get("name")
        aliases = feature.get("linux_flags")
        valid = isinstance(name, str) and isinstance(aliases, list) and aliases
        if not valid or any(not isinstance(alias, str) or not alias for alias in aliases):
            fail("support matrix CPU feature policy is malformed")
        if not any(alias in flags for alias in aliases):
            missing.append(name)
    return missing


def kernel_release(value: object) -> tuple[int, int, int]:
    if not isinstance(value, str) or not 1 <= len(value) <= 128:
        fail("kernel release is malformed")
    match = KERNEL_RELEASE_RE.fullmatch(value)
    if match is None:
        fail(f"kernel release is malformed: {value!r}")
    suffix = match.group(4)
    if KERNEL_PRERELEASE_RE.match(suffix) is not None:
        fail(f"kernel release is a prerelease: {value!r}")
    return tuple(int(match.group(index)) for index in range(1, 4))


def require_kernel_minimum(actual: object, minimum: object, context: str) -> None:
    if kernel_release(actual) < kernel_release(minimum):
        fail(f"{context} kernel {actual} is below required minimum {minimum}")


def runner_case_id(matrix: dict, gate_id: str) -> str | None:
    prefix = "scheduled.kernel-"
    if gate_id.startswith(prefix):
        return gate_id[len(prefix):]
    hosts = matrix.get("gate_hosts", {})
    if not isinstance(hosts, dict):
        fail("support matrix gate host policy is malformed")
    case_id = hosts.get(gate_id)
    if case_id is not None and not isinstance(case_id, str):
        fail("support matrix gate host policy is malformed")
    return case_id


def cpu_info() -> dict[str, str]:
    try:
        with Path("/proc/cpuinfo").open("rb") as stream:
            raw = stream.read(MAX_CPU_INFO_BYTES + 1)
    except OSError:
        return {}
    if len(raw) > MAX_CPU_INFO_BYTES:
        return {}
    return parse_cpu_info(raw.decode("utf-8", errors="replace"))


def parse_cpu_info(text: str) -> dict[str, str]:
    records: list[dict[str, str]] = []
    for block in text.split("\n\n"):
        fields: dict[str, str] = {}
        for line in block.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
        if fields:
            records.append(fields)
    if not records:
        return {}
    result = records[0].copy()
    flags = set(records[0].get("flags", "").split())
    for record in records[1:]:
        flags &= set(record.get("flags", "").split())
    result["flags"] = " ".join(sorted(flags))
    for key in ("vendor_id", "model name", "microcode"):
        values = {record.get(key, "unknown") for record in records}
        if len(values) != 1:
            result[key] = "mixed"
    return result


def runner_info(root: Path) -> dict[str, str]:
    cpu = cpu_info()
    zig = shutil.which("zig")
    zig_version = run([zig, "version"], root).stdout.strip() if zig else "missing"
    return {
        "name": os.environ.get("RUNNER_NAME", socket.gethostname()),
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "cpu_vendor": cpu.get("vendor_id", "unknown"),
        "cpu_model": cpu.get("model name", "unknown"),
        "cpu_flags": " ".join(sorted(cpu.get("flags", "").split())),
        "microcode": cpu.get("microcode", "unknown"),
        "machine_id_sha256": machine_identity(),
        "zig": zig_version,
    }


def machine_identity() -> str:
    for path in (Path("/etc/machine-id"), Path("/var/lib/dbus/machine-id")):
        try:
            value = path.read_text(encoding="ascii").strip()
        except OSError:
            continue
        if value:
            return sha256_bytes(value.encode("ascii"))
    fail("host has no stable machine identity")


def check_host(root: Path, case_id: str) -> None:
    matrix = read_json(root / "release/support-matrix.json")
    cases = {case["id"]: case for case in matrix["kernels"]}
    if case_id not in cases:
        fail(f"unknown support-matrix case: {case_id}")
    case = cases[case_id]
    info = runner_info(root)
    if info["architecture"] != "x86_64":
        fail(f"host architecture is {info['architecture']}, expected x86_64")
    require_kernel_minimum(
        info["kernel"], matrix["production_target"]["minimum_kernel_version"], "host",
    )
    require_kernel_minimum(info["kernel"], case["minimum_version"], "host")
    if info["cpu_vendor"] != case["cpu_vendor"]:
        fail(f"CPU vendor is {info['cpu_vendor']}, expected {case['cpu_vendor']}")
    if info["zig"] != matrix["compiler"]["version"]:
        fail(f"Zig is {info['zig']}, expected {matrix['compiler']['version']}")
    flags = set(info["cpu_flags"].split())
    missing = missing_cpu_features(matrix, flags)
    if missing:
        fail(f"CPU is missing x86-64-v3 features: {', '.join(missing)}")
