"""Bounded no-follow enumeration for retained release evidence."""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath

from release_common import fail, open_directory_nofollow


DIRECTORY_FLAGS = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
MAX_EVIDENCE_DEPTH = 8


def bounded_regular_entries(
    root: Path,
    max_entries: int,
    allowed_directories: set[str] | None = None,
) -> list[Path]:
    allowed_directories = allowed_directories or set()
    descriptor = open_directory_nofollow(root)
    paths: list[Path] = []
    count = 0
    try:
        with os.scandir(descriptor) as entries:
            for entry in entries:
                count += 1
                if count > max_entries:
                    fail(f"{root}: directory entry limit exceeded")
                if entry.is_file(follow_symlinks=False):
                    paths.append(root / entry.name)
                elif entry.is_dir(follow_symlinks=False) and entry.name in allowed_directories:
                    continue
                else:
                    fail(f"{root}: unexpected or symlinked directory entry: {entry.name}")
    except OSError as error:
        fail(f"{root}: cannot enumerate directory safely: {error}")
    finally:
        os.close(descriptor)
    return paths


def bounded_evidence_reports(root: Path, max_entries: int) -> list[Path]:
    root_descriptor = open_directory_nofollow(root)
    stack = [(root_descriptor, PurePosixPath(), 0)]
    reports: list[Path] = []
    count = 0
    try:
        while stack:
            descriptor, relative, depth = stack.pop()
            try:
                with os.scandir(descriptor) as entries:
                    for entry in entries:
                        count += 1
                        if count > max_entries:
                            fail(f"{root}: evidence tree entry limit exceeded")
                        path = relative / entry.name
                        if entry.is_file(follow_symlinks=False):
                            if entry.name.endswith(".json") and "artifacts" not in relative.parts:
                                reports.append(root / str(path))
                            continue
                        if not entry.is_dir(follow_symlinks=False):
                            fail(f"{root}: evidence tree entry is not regular: {path}")
                        if depth >= MAX_EVIDENCE_DEPTH:
                            fail(f"{root}: evidence tree depth limit exceeded")
                        child = os.open(entry.name, DIRECTORY_FLAGS, dir_fd=descriptor)
                        stack.append((child, path, depth + 1))
            finally:
                os.close(descriptor)
    except OSError as error:
        fail(f"{root}: cannot enumerate evidence safely: {error}")
    finally:
        for descriptor, _, _ in stack:
            os.close(descriptor)
    return sorted(reports, key=lambda path: path.relative_to(root).as_posix())
