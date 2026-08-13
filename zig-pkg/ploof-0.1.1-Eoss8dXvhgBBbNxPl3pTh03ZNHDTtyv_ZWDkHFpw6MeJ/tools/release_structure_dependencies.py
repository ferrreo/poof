"""Dependency-boundary checks for release structure validation."""

from __future__ import annotations

from itertools import chain
from pathlib import Path
import re

from release_artifact_check import validate_dependency_policy
from release_common import ReleaseError, parse_zon
from release_structure_io import (
    MAX_STRUCTURE_TOTAL_BYTES,
    bounded_paths,
    bounded_tree_files,
    local_zig_import,
    read_bounded_json,
    read_bounded_text,
)


IMPORT_RE = re.compile(r'@import\s*\(\s*"((?:\\.|[^"\\])*)"\s*,?\s*\)')
BUILD_IMPORTS_RE = re.compile(
    r'''^\s*\.imports\s*=\s*&\.\{\.\{\s*\.name\s*=\s*"(harness_options|'''
    r'''ploof|sigbench)",\s*'''
    r'''\.module\s*=\s*[^{}\r\n]+\s*\}\},\s*$''',
)


def benchmark_source(path: Path) -> bool:
    return path.name == "benchmark.zig" or path.name.endswith("_benchmark.zig")


def check_dependencies(root: Path, errors: list[str]) -> None:
    policy = read_bounded_json(root / "release/dependencies.json", root, errors)
    if policy is None:
        return
    try:
        build_only = validate_dependency_policy(policy)
    except ReleaseError as error:
        errors.append(f"release/dependencies.json: {error}")
        return
    zon_text = read_bounded_text(root / "build.zig.zon", root, errors)
    if zon_text is None:
        return
    zon = parse_zon(zon_text)
    expected = {dependency["name"]: dependency for dependency in build_only}
    if set(zon["dependency_names"]) != set(expected):
        errors.append("build.zig.zon: dependency names do not match release/dependencies.json")
    actual = {dependency["name"]: dependency for dependency in zon["dependencies"]}
    for name, dependency in expected.items():
        required = {
            "name": name,
            "url": dependency["url"],
            "hash": dependency["zig_hash"],
            "lazy": True,
        }
        if actual.get(name) != required:
            errors.append(f"build.zig.zon: {name} pin or lazy boundary does not match policy")
    scan_sources(root, set(expected), errors)
    check_build_wiring(root, errors)


def scan_sources(root: Path, build_only: set[str], errors: list[str]) -> None:
    paths = bounded_paths(
        chain(
            root.glob("*.zig"),
            bounded_tree_files(root, "build", "dependency scan", errors, suffixes={".zig"}),
            bounded_tree_files(root, "benchmarks", "dependency scan", errors, suffixes={".zig"}),
            bounded_tree_files(root, "fuzz", "dependency scan", errors, suffixes={".zig"}),
            bounded_tree_files(root, "src", "dependency scan", errors, suffixes={".zig"}),
            bounded_tree_files(root, "tools", "dependency scan", errors, suffixes={".zig"}),
        ),
        "dependency scan",
        errors,
    )
    total_bytes = 0
    for path in paths:
        text = read_bounded_text(path, root, errors)
        if text is None:
            continue
        total_bytes += len(text.encode("utf-8"))
        if total_bytes > MAX_STRUCTURE_TOTAL_BYTES:
            errors.append("dependency scan: source bytes exceed aggregate limit")
            return
        scan_imports(path, text, root, build_only, errors)


def scan_imports(
    path: Path,
    text: str,
    root: Path,
    build_only: set[str],
    errors: list[str],
) -> None:
    position = 0
    while True:
        start = text.find("@import", position)
        if start < 0:
            return
        number = text.count("\n", 0, start) + 1
        match = IMPORT_RE.match(text, start)
        if match is None:
            errors.append(f"{path.relative_to(root)}:{number}: import syntax is not canonical")
            position = start + len("@import")
            continue
        value = match.group(1)
        position = match.end()
        if local_zig_import(path, value, root):
            target = (path.parent / value).resolve()
            if benchmark_source(target) and not benchmark_source(path):
                errors.append(
                    f"{path.relative_to(root)}:{number}: production import reaches "
                    "benchmark-only source"
                )
            continue
        relative = path.relative_to(root).as_posix()
        seam = relative == "src/testing/facade.zig" and value == "ploof"
        harness_seam = relative == "fuzz.zig" and (
            value == "harness_options"
        )
        allowed = value in {"std", "builtin"} or value in build_only and benchmark_source(path)
        if "\\" in value or not (allowed or seam or harness_seam):
            errors.append(f"{path.relative_to(root)}:{number}: production import is not local")


def check_build_wiring(root: Path, errors: list[str]) -> None:
    texts: dict[str, str] = {}
    paths = chain(
        root.glob("build*.zig"),
        bounded_tree_files(root, "build", "build dependency scan", errors, suffixes={".zig"}),
    )
    for path in bounded_paths(paths, "build dependency scan", errors):
        text = read_bounded_text(path, root, errors)
        if text is not None:
            texts[path.name] = text
            check_module_tables(path, text, root, errors)
    text = texts.get("build.zig")
    if text is None:
        return
    expected = [
        (False, 'const benchmarks = b.option(bool, "benchmarks", '
         '"Enable lazy sigbench steps") orelse false;'),
        (True, 'const dependency = b.lazyDependency("sigbench", .{'),
        (True, '.imports = &.{.{ .name = "sigbench", '
         '.module = dependency.module("sigbench") }},'),
    ]
    actual: list[tuple[bool, str]] = []
    in_benchmark_function = False
    for line in text.splitlines():
        if line.startswith("fn addBenchmarkSteps("):
            in_benchmark_function = True
        elif in_benchmark_function and line.startswith("fn "):
            in_benchmark_function = False
        if "sigbench" in line:
            actual.append((in_benchmark_function, line.strip()))
    if actual != expected:
        errors.append("build.zig: sigbench wiring escapes benchmark-only graph")
    guards = [
        line.strip() for line in text.splitlines()
        if "addBenchmarkSteps" in line and line.lstrip().startswith("if (")
    ]
    if len(guards) != 1 or re.fullmatch(
        r"if \(benchmarks\) addBenchmarkSteps\(b(?:, target)?\);",
        guards[0],
    ) is None:
        errors.append("build.zig: benchmark activation guard changed")


def check_module_tables(path: Path, text: str, root: Path, errors: list[str]) -> None:
    forbidden = (
        "addImport",
        "addAnonymousImport",
        "import_table",
        '@"',
        "@field",
        ".dependency(",
    )
    for number, line in enumerate(text.splitlines(), 1):
        if "addOptions" in line and line.strip() != "const options = b.addOptions();":
            errors.append(
                f"{path.relative_to(root)}:{number}: dynamic build options are not allowed"
            )
        if ".imports" in line and BUILD_IMPORTS_RE.fullmatch(line) is None:
            errors.append(f"{path.relative_to(root)}:{number}: module import table is not allowed")
        if "lazyDependency" in line and line.strip() != (
            'const dependency = b.lazyDependency("sigbench", .{'
        ):
            errors.append(f"{path.relative_to(root)}:{number}: lazy dependency is not allowed")
        if any(token in line for token in forbidden):
            errors.append(
                f"{path.relative_to(root)}:{number}: dynamic module import is not allowed"
            )
