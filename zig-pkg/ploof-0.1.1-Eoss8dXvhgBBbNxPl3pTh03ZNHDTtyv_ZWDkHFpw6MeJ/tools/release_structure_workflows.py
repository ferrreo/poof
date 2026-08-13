"""Bounded GitHub workflow and composite-action pin checks."""

from __future__ import annotations

import ast
from itertools import chain
import os
from pathlib import Path, PurePosixPath
import re

from release_gate_commands import check_workflow_command_policy
from release_structure_io import (
    MAX_STRUCTURE_TOTAL_BYTES,
    WORKFLOW_USES_RE,
    bounded_paths,
    bounded_tree_files,
    read_bounded_text,
)


YAML_DOUBLE_KEY_RE = re.compile(r'"((?:\\.|[^"\\])*)"\s*:')


def line_has_uses_key(line: str) -> bool:
    if re.search(r'''(?:\buses\b|"uses"|'uses')\s*:''', line):
        return True
    for match in YAML_DOUBLE_KEY_RE.finditer(line):
        try:
            if ast.literal_eval(f'"{match.group(1)}"') == "uses":
                return True
        except (SyntaxError, ValueError):
            continue
    explicit = re.fullmatch(
        r'''\s*(?:-\s*)?\?\s*"((?:\\.|[^"\\])*)"\s*(?:#.*)?''', line,
    )
    if explicit is None:
        return re.fullmatch(
            r'''\s*(?:-\s*)?\?\s*(?:uses|'uses')\s*(?:#.*)?''', line,
        ) is not None
    try:
        return ast.literal_eval(f'"{explicit.group(1)}"') == "uses"
    except (SyntaxError, ValueError):
        return False


def noncanonical_mapping_key(line: str) -> bool:
    explicit = re.match(r"^\s*(?:-\s*)?\?", line) is not None
    alias = re.match(r"^\s*(?:-\s*)?\*[^\s:]+\s*:", line) is not None
    flow = re.match(r"^\s*(?:-\s*)?\{", line) is not None
    return explicit or alias or flow


def local_action_valid(root: Path, value: str) -> bool:
    if not value.startswith("./"):
        return False
    relative = PurePosixPath(value[2:])
    if str(relative) != value[2:] or any(part in {"", ".", ".."} for part in relative.parts):
        return False
    required_prefix = (".github", "actions")
    if relative.parts[:2] != required_prefix or len(relative.parts) < 3:
        return False
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            return False
    if not current.is_dir():
        return False
    descriptors = [
        path for path in (current / "action.yml", current / "action.yaml")
        if path.is_file() and not path.is_symlink()
    ]
    return len(descriptors) == 1


def check_workflows(root: Path, errors: list[str]) -> None:
    directory = root / ".github/workflows"
    actions = root / ".github/actions"
    workflow_paths = bounded_tree_files(
        root,
        ".github/workflows",
        "workflow/action scan",
        errors,
        suffixes={".yml", ".yaml"},
    )
    action_paths = bounded_tree_files(
        root,
        ".github/actions",
        "workflow/action scan",
        errors,
        names={"action.yml", "action.yaml"},
    ) if os.path.lexists(actions) else []
    paths = bounded_paths(
        chain(workflow_paths, action_paths),
        "workflow/action scan",
        errors,
    )
    if sum(path.parent == directory for path in paths) < 4:
        errors.append(".github/workflows: four release lanes are required")
    scan_workflow_paths(root, paths, errors)


def scan_workflow_paths(
    root: Path,
    paths: list[Path],
    errors: list[str],
) -> None:
    total_bytes = 0
    texts: dict[Path, str] = {}
    for path in paths:
        text = read_bounded_text(path, root, errors)
        if text is None:
            continue
        texts[path] = text
        total_bytes += len(text.encode("utf-8"))
        if total_bytes > MAX_STRUCTURE_TOTAL_BYTES:
            errors.append("workflow/action scan: source bytes exceed aggregate limit")
            return
        scan_uses(root, path, text, errors)
    check_workflow_command_policy(root, paths, texts, errors)


def scan_uses(root: Path, path: Path, text: str, errors: list[str]) -> None:
    for number, line in enumerate(text.splitlines(), 1):
        match = WORKFLOW_USES_RE.fullmatch(line)
        if match is None:
            if line_has_uses_key(line) or noncanonical_mapping_key(line):
                errors.append(f"{path.relative_to(root)}:{number}: uses syntax is not canonical")
            continue
        value = next(group for group in match.groups() if group is not None)
        if value.startswith("./"):
            if not local_action_valid(root, value):
                errors.append(
                    f"{path.relative_to(root)}:{number}: local action path is not allowed"
                )
            continue
        revision = value.rsplit("@", 1)[-1]
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            errors.append(f"{path.relative_to(root)}:{number}: action is not SHA-pinned")
