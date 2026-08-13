"""Bounded regular-file access for release structure checks."""

from __future__ import annotations

from collections.abc import Iterable
import os
from pathlib import Path
import re
import stat

from release_common import ReleaseError, parse_json


MAX_STRUCTURE_FILES = 20_000
MAX_STRUCTURE_FILE_BYTES = 1024 * 1024
MAX_STRUCTURE_TOTAL_BYTES = 64 * 1024 * 1024
EXCLUDED_SOURCE_TREES = {
    ".cache", ".zig-cache", "cache", "generated", "third-party", "third_party",
    "vendor", "zig-cache", "zig-out", "zig-pkg",
}
WORKFLOW_USES_RE = re.compile(
    r'''^\s*(?:-\s*)?(?:uses|"uses"|'uses')\s*:\s*'''
    r'''(?:"([^"]+)"|'([^']+)'|([^\s#]+))\s*(?:#.*)?$''',
)


def read_bounded_text(path: Path, root: Path, errors: list[str]) -> str | None:
    relative = path.relative_to(root)
    descriptor = open_beneath(path, root, errors, directory=False)
    if descriptor is None:
        return None
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            errors.append(f"{relative}: source is not a regular file")
            return None
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(MAX_STRUCTURE_FILE_BYTES + 1)
        if len(contents) > MAX_STRUCTURE_FILE_BYTES:
            errors.append(f"{relative}: source exceeds byte limit")
            return None
        try:
            return contents.decode("utf-8")
        except UnicodeDecodeError as error:
            errors.append(f"{relative}: invalid UTF-8 at byte {error.start}")
            return None
    finally:
        os.close(descriptor)


def open_beneath(
    path: Path,
    root: Path,
    errors: list[str],
    *,
    directory: bool,
) -> int | None:
    relative = path.relative_to(root)
    parents: list[int] = []
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        current = os.open(root, directory_flags)
        parents.append(current)
        for part in relative.parts[:-1]:
            current = os.open(part, directory_flags, dir_fd=current)
            parents.append(current)
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        if directory:
            flags |= os.O_DIRECTORY
        return os.open(relative.name, flags, dir_fd=current)
    except OSError as error:
        kind = "directory" if directory else "regular source"
        errors.append(f"{relative}: cannot open {kind}: {error.strerror}")
        return None
    finally:
        for descriptor in reversed(parents):
            os.close(descriptor)


def read_bounded_json(path: Path, root: Path, errors: list[str]) -> dict | None:
    text = read_bounded_text(path, root, errors)
    if text is None:
        return None
    try:
        return parse_json(text, str(path.relative_to(root)))
    except ReleaseError as error:
        errors.append(str(error))
        return None


def bounded_paths(paths: Iterable[Path], label: str, errors: list[str]) -> list[Path]:
    unique: set[Path] = set()
    for path in paths:
        unique.add(path)
        if len(unique) > MAX_STRUCTURE_FILES:
            errors.append(f"{label}: source file count exceeds {MAX_STRUCTURE_FILES}")
            return []
    return sorted(unique)


def bounded_tree_files(
    root: Path,
    directory: str,
    label: str,
    errors: list[str],
    *,
    suffixes: set[str] | None = None,
    names: set[str] | None = None,
) -> list[Path]:
    base = root / directory
    first = open_beneath(base, root, errors, directory=True)
    if first is None:
        return []
    pending = [(first, base)]
    paths: list[Path] = []
    entries = 0
    while pending:
        descriptor, parent = pending.pop()
        try:
            with os.scandir(descriptor) as iterator:
                for entry in iterator:
                    entries += 1
                    if entries > MAX_STRUCTURE_FILES:
                        errors.append(f"{label}: source entry count exceeds {MAX_STRUCTURE_FILES}")
                        close_pending(pending)
                        return []
                    path = parent / entry.name
                    if entry.is_symlink():
                        errors.append(f"{path.relative_to(root)}: source symlink is forbidden")
                    elif entry.is_dir(follow_symlinks=False):
                        child = os.open(
                            entry.name,
                            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                            dir_fd=descriptor,
                        )
                        pending.append((child, path))
                    elif matches_file(path, suffixes, names):
                        paths.append(path)
        except OSError as error:
            errors.append(f"{parent.relative_to(root)}: cannot enumerate source: {error}")
            close_pending(pending)
            return []
        finally:
            os.close(descriptor)
    return sorted(paths)


def matches_file(path: Path, suffixes: set[str] | None, names: set[str] | None) -> bool:
    return (suffixes is None or path.suffix in suffixes) and (
        names is None or path.name in names
    )


def close_pending(pending: list[tuple[int, Path]]) -> None:
    for descriptor, _ in pending:
        os.close(descriptor)
    pending.clear()


def local_zig_import(path: Path, value: str, root: Path) -> bool:
    if not value.endswith(".zig"):
        return False
    candidate = path.parent / value
    try:
        candidate.resolve(strict=True).relative_to(root.resolve())
    except (OSError, ValueError):
        return False
    return candidate.is_file() and not candidate.is_symlink()


def production_zig(path: Path, root: Path) -> bool:
    relative = path.relative_to(root).as_posix()
    name = path.name
    if not relative.startswith("src/"):
        build_helper = relative.startswith("build/") or (
            path.parent == root and name.startswith("build")
        )
        return build_helper or relative.startswith("tools/") and not name.startswith("test")
    excluded = ("_test.zig", "_benchmark.zig", "_fuzz_check.zig")
    return not name.endswith(excluded) and relative not in {
        "src/testing.zig",
        "src/testing/facade.zig",
    }


def excluded_source(path: Path, root: Path) -> bool:
    return bool(set(path.relative_to(root).parts[:-1]) & EXCLUDED_SOURCE_TREES)
