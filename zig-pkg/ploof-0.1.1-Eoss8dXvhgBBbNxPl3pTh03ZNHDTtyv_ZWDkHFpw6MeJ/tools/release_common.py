"""Shared fail-closed primitives for Ploof release host tools."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess


ROOT = Path(__file__).resolve().parent.parent
GENERATED_PARTS = {
    ".git",
    ".pytest_cache",
    ".zig-cache",
    "__pycache__",
    "zig-cache",
    "zig-out",
    "zig-pkg",
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-f]{40,64}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 100_000
ZON_RE = re.compile(
    r'''\A\.\{\s*\.name\s*=\s*\.([A-Za-z0-9_]+),\s*'''
    r'''\.version\s*=\s*"([^"\\\r\n]+)",\s*'''
    r'''\.fingerprint\s*=\s*0x[0-9a-fA-F]+,\s*'''
    r'''\.minimum_zig_version\s*=\s*"([^"\\\r\n]+)",\s*'''
    r'''\.dependencies\s*=\s*\.\{(.*?)^\s{4}\},\s*'''
    r'''\.paths\s*=\s*\.\{(.*?)^\s{4}\},\s*\}\s*\Z''',
    re.MULTILINE | re.DOTALL,
)
ZON_DEPENDENCY_RE = re.compile(
    r"\s*\.([A-Za-z][A-Za-z0-9_]*)\s*=\s*\.\{\s*"
    r"\.url\s*=\s*\"([^\"\\\r\n]+)\",\s*"
    r"\.hash\s*=\s*\"([^\"\\\r\n]+)\",\s*"
    r"\.lazy\s*=\s*(true|false),\s*\},",
    re.DOTALL,
)
ZON_PATH_RE = re.compile(r'\s*"([^"\\\r\n]+)",')


class ReleaseError(Exception):
    pass


def fail(message: str) -> None:
    raise ReleaseError(message)


def read_json(path: Path) -> dict:
    descriptor = open_regular_nofollow(path, "JSON input")
    try:
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            contents = stream.read(MAX_JSON_BYTES + 1)
        if len(contents) > MAX_JSON_BYTES:
            fail(f"{path}: JSON exceeds byte limit")
        text = contents.decode("utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"{path}: invalid JSON: {error}")
    finally:
        os.close(descriptor)
    return parse_json(text, str(path))


def open_directory_nofollow(path: Path, create: bool = False) -> int:
    absolute = Path(os.path.abspath(path))
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    current = -1
    try:
        current = os.open("/", directory_flags)
        for part in absolute.parts[1:]:
            try:
                child = os.open(part, directory_flags, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, mode=0o755, dir_fd=current)
                except FileExistsError:
                    pass
                child = os.open(part, directory_flags, dir_fd=current)
            os.close(current)
            current = child
        return current
    except OSError as error:
        if current >= 0:
            os.close(current)
        fail(f"{path}: cannot open directory without symlinks: {error}")


def ensure_directory_nofollow(path: Path) -> None:
    descriptor = open_directory_nofollow(path, create=True)
    os.close(descriptor)


def open_regular_nofollow(path: Path, label: str = "input") -> int:
    parent = open_directory_nofollow(path.parent)
    descriptor = -1
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
        descriptor = os.open(path.name, flags, dir_fd=parent)
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            descriptor = -1
            fail(f"{path}: {label} is not a regular file")
        return descriptor
    except OSError as error:
        fail(f"{path}: cannot open {label} without symlinks: {error}")
    finally:
        os.close(parent)


def create_exclusive_nofollow(path: Path) -> int:
    parent = open_directory_nofollow(path.parent, create=True)
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
        return os.open(path.name, flags, 0o644, dir_fd=parent)
    except OSError as error:
        fail(f"{path}: cannot create exclusive output without symlinks: {error}")
    finally:
        os.close(parent)


def sha256_descriptor(descriptor: int) -> str:
    digest = hashlib.sha256()
    for _ in range(1 << 30):
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)
    fail("file exceeds supported copy size")


def sha256_regular_nofollow(path: Path, label: str = "input") -> str:
    descriptor = open_regular_nofollow(path, label)
    try:
        return sha256_descriptor(descriptor)
    except OSError as error:
        fail(f"{path}: cannot hash {label}: {error}")
    finally:
        os.close(descriptor)


def copy_descriptor(source: int, destination: int) -> str:
    digest = hashlib.sha256()
    for _ in range(1 << 30):
        chunk = os.read(source, 1024 * 1024)
        if not chunk:
            os.fsync(destination)
            return digest.hexdigest()
        digest.update(chunk)
        remaining = memoryview(chunk)
        while remaining:
            written = os.write(destination, remaining)
            if written == 0:
                raise OSError("zero-byte evidence output write")
            remaining = remaining[written:]
    fail("evidence artifact exceeds supported copy size")


def copy_regular_nofollow(
    source: Path,
    destination: Path,
    *,
    allow_identical: bool = False,
) -> str:
    source_descriptor = open_regular_nofollow(source, "copy source")
    try:
        parent = open_directory_nofollow(destination.parent, create=True)
    except ReleaseError:
        os.close(source_descriptor)
        raise
    destination_descriptor = -1
    destination_created = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
        try:
            destination_descriptor = os.open(
                destination.name, flags, 0o644, dir_fd=parent,
            )
            destination_created = True
        except FileExistsError:
            if not allow_identical:
                fail(f"evidence output already exists: {destination}")
            existing_flags = (
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
            )
            destination_descriptor = os.open(
                destination.name, existing_flags, dir_fd=parent,
            )
            if not stat.S_ISREG(os.fstat(destination_descriptor).st_mode):
                fail(f"conflicting evidence artifact: {destination}")
            source_hash = sha256_descriptor(source_descriptor)
            destination_hash = sha256_descriptor(destination_descriptor)
            if source_hash != destination_hash:
                fail(f"conflicting evidence artifact: {destination}")
            return source_hash

        return copy_descriptor(source_descriptor, destination_descriptor)
    except ReleaseError:
        if destination_created:
            try:
                os.unlink(destination.name, dir_fd=parent)
            except OSError:
                pass
        raise
    except OSError as error:
        if destination_created:
            try:
                os.unlink(destination.name, dir_fd=parent)
            except OSError:
                pass
        fail(f"cannot copy evidence artifact {source} to {destination}: {error}")
    finally:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
        os.close(parent)
        os.close(source_descriptor)


def parse_json(text: str, label: str) -> dict:
    if len(text) > MAX_JSON_BYTES:
        fail(f"{label}: JSON exceeds byte limit")

    def unique_object(pairs: list[tuple[str, object]]) -> dict:
        value: dict = {}
        for key, item in pairs:
            if key in value:
                fail(f"{label}: duplicate JSON field: {key}")
            value[key] = item
        return value

    def reject_constant(value: str) -> None:
        fail(f"{label}: non-finite JSON number is forbidden: {value}")

    def bounded_integer(value: str) -> int:
        if len(value) > 128:
            fail(f"{label}: JSON integer exceeds digit limit")
        return int(value)

    def finite_float(value: str) -> float:
        if len(value) > 128:
            fail(f"{label}: JSON float exceeds digit limit")
        result = float(value)
        if not math.isfinite(result):
            fail(f"{label}: non-finite JSON number is forbidden: {value}")
        return result

    try:
        value = json.loads(
            text,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
            parse_int=bounded_integer,
            parse_float=finite_float,
        )
    except ReleaseError:
        raise
    except (json.JSONDecodeError, RecursionError, ValueError) as error:
        fail(f"{label}: invalid JSON: {error}")
    validate_json_bounds(value, label)
    if not isinstance(value, dict):
        fail(f"{label}: expected a JSON object")
    return value


def validate_json_bounds(value: object, label: str) -> None:
    pending: list[tuple[object, int]] = [(value, 1)]
    nodes = 0
    while pending:
        item, depth = pending.pop()
        nodes += 1
        if depth > MAX_JSON_DEPTH:
            fail(f"{label}: JSON nesting exceeds depth limit")
        if nodes > MAX_JSON_NODES:
            fail(f"{label}: JSON value count exceeds limit")
        if isinstance(item, dict):
            children = item.values()
        elif isinstance(item, list):
            children = item
        else:
            continue
        if len(item) > MAX_JSON_NODES - nodes - len(pending):
            fail(f"{label}: JSON value count exceeds limit")
        pending.extend((nested, depth + 1) for nested in children)


def canonical_json_bytes(value: dict) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def write_bytes_atomic_nofollow(path: Path, contents: bytes) -> None:
    parent = open_directory_nofollow(path.parent, create=True)
    temporary = path.name + ".tmp"
    descriptor = -1
    temporary_created = False
    succeeded = False
    operation_error: OSError | None = None
    cleanup_error: OSError | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
        descriptor = os.open(temporary, flags, 0o644, dir_fd=parent)
        temporary_created = True
        remaining = memoryview(contents)
        for _ in range(len(contents) + 1):
            if not remaining:
                break
            written = os.write(descriptor, remaining)
            if written == 0:
                raise OSError("zero-byte atomic output write")
            remaining = remaining[written:]
        else:
            raise OSError("atomic output write exceeded byte bound")
        os.fsync(descriptor)
        closed_descriptor = descriptor
        descriptor = -1
        os.close(closed_descriptor)
        os.replace(
            temporary,
            path.name,
            src_dir_fd=parent,
            dst_dir_fd=parent,
        )
        succeeded = True
    except OSError as error:
        operation_error = error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_created and not succeeded:
            try:
                os.unlink(temporary, dir_fd=parent)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_error = error
        os.close(parent)
    if operation_error is not None:
        suffix = f"; temporary cleanup failed: {cleanup_error}" if cleanup_error else ""
        fail(f"{path}: cannot write atomic output without symlinks: {operation_error}{suffix}")
    if cleanup_error is not None:
        fail(f"{path}: temporary cleanup failed: {cleanup_error}")


def write_json(path: Path, value: dict) -> None:
    try:
        contents = canonical_json_bytes(value)
        write_bytes_atomic_nofollow(path, contents)
    except ReleaseError:
        raise
    except (OSError, TypeError, UnicodeError, ValueError) as error:
        fail(f"{path}: cannot write canonical JSON: {error}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"{path}: cannot hash file: {error}")
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def run(
    command: list[str],
    cwd: Path,
    *,
    check: bool = True,
    text: bool = True,
) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True, text=text)
    except (OSError, ValueError) as error:
        fail(f"cannot execute command {' '.join(command)}: {error}")
    if check and result.returncode != 0:
        stderr = result.stderr.strip() if text else ""
        fail(f"command failed ({result.returncode}): {' '.join(command)}\n{stderr}")
    return result


def git(root: Path, *arguments: str, text: bool = True) -> str | bytes:
    result = run(["git", *arguments], root, text=text)
    return result.stdout


def git_file(root: Path, revision: str, path: str) -> bytes:
    return bytes(git(root, "show", f"{revision}:{path}", text=False))


def git_json(root: Path, revision: str, path: str) -> dict:
    try:
        text = git_file(root, revision, path).decode("utf-8")
    except UnicodeError as error:
        fail(f"{revision}:{path}: invalid UTF-8: {error}")
    return parse_json(text, f"{revision}:{path}")


def canonical_revision(root: Path, revision: str) -> str:
    invalid = not isinstance(revision, str) or not revision or revision.startswith("-")
    invalid = invalid or any(ord(character) < 32 or ord(character) == 127 for character in revision)
    if invalid:
        fail(f"unsafe Git revision: {revision!r}")
    value = str(git(
        root, "rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}",
    )).strip()
    if not REVISION_RE.fullmatch(value):
        fail(f"git returned invalid revision: {value!r}")
    return value


def release_version(value: object) -> str:
    if not isinstance(value, str) or not VERSION_RE.fullmatch(value):
        fail(f"invalid release version: {value!r}")
    return value


def parse_zon(text: str) -> dict:
    clean = strip_zig_comments(text)
    document = ZON_RE.fullmatch(clean)
    if document is None:
        fail("build.zig.zon: document is not canonical")
    dependencies = parse_zon_dependencies(document.group(4))
    paths = parse_zon_paths(document.group(5))
    dependency_names = [str(dependency["name"]) for dependency in dependencies]
    if len(dependency_names) != len(set(dependency_names)):
        fail("build.zig.zon: duplicate dependency name")
    return {
        "name": document.group(1),
        "version": document.group(2),
        "minimum_zig_version": document.group(3),
        "paths": paths,
        "dependency_names": dependency_names,
        "dependencies": dependencies,
        "text": text,
    }


def parse_zon_dependencies(body: str) -> list[dict[str, object]]:
    dependencies: list[dict[str, object]] = []
    position = 0
    while body[position:].strip():
        match = ZON_DEPENDENCY_RE.match(body, position)
        if match is None:
            fail("build.zig.zon: dependency entries are not canonical")
        dependencies.append({
            "name": match.group(1),
            "url": match.group(2),
            "hash": match.group(3),
            "lazy": match.group(4) == "true",
        })
        position = match.end()
    return dependencies


def parse_zon_paths(body: str) -> list[str]:
    paths: list[str] = []
    position = 0
    while body[position:].strip():
        match = ZON_PATH_RE.match(body, position)
        if match is None:
            fail("build.zig.zon: paths are not canonical")
        paths.append(match.group(1))
        position = match.end()
    if len(paths) != len(set(paths)):
        fail("build.zig.zon: duplicate package path")
    return paths


def strip_zig_comments(text: str) -> str:
    output = list(text)
    quote = ""
    block_depth = 0
    index = 0
    while index < len(text):
        pair = text[index:index + 2]
        if block_depth:
            if pair == "/*":
                block_depth += 1
                output[index:index + 2] = "  "
                index += 2
            elif pair == "*/":
                block_depth -= 1
                output[index:index + 2] = "  "
                index += 2
            else:
                if text[index] != "\n":
                    output[index] = " "
                index += 1
            continue
        if quote:
            if text[index] == "\\":
                index += 2
            else:
                if text[index] == quote:
                    quote = ""
                index += 1
            continue
        if pair == "//":
            end = text.find("\n", index)
            end = len(text) if end < 0 else end
            output[index:end] = " " * (end - index)
            index = end
        elif pair == "/*":
            block_depth = 1
            output[index:index + 2] = "  "
            index += 2
        elif text[index] in {'"', "'"}:
            quote = text[index]
            index += 1
        else:
            index += 1
    if block_depth or quote:
        fail("build.zig.zon: unterminated comment or string")
    return "".join(output)


def safe_relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    invalid_bytes = "\\" in value or any(
        ord(character) < 32 or ord(character) == 127 for character in value
    )
    invalid = invalid_bytes or path.is_absolute() or not path.parts
    invalid = invalid or any(part in {"", ".", ".."} for part in path.parts)
    invalid = invalid or str(path) != value
    if invalid:
        fail(f"unsafe relative path: {value!r}")
    if any(part in GENERATED_PARTS for part in path.parts):
        fail(f"generated path is forbidden: {value!r}")
    if path.suffix in {".pyc", ".pyo"}:
        fail(f"generated path is forbidden: {value!r}")
    return path
