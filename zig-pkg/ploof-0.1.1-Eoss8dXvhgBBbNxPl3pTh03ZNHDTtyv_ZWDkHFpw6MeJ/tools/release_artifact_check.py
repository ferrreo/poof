"""Build and verify deterministic Ploof release subjects."""

from __future__ import annotations

import datetime
import io
from pathlib import Path
import re
import tarfile
import tempfile

from release_common import (
    canonical_json_bytes,
    fail,
    git,
    safe_relative,
    sha256_file,
)


REQUIRED_PACKAGE_PATHS = {
    "build.zig", "build.zig.zon", "src", "tools", "tests", "docs", "release",
    "LICENSE", "README.md", "SECURITY.md",
}
SIGBENCH_DEPENDENCY = {
    "name": "sigbench",
    "version": "0.0.5",
    "url": "https://github.com/ferrreo/sigbench/archive/refs/tags/0.0.5.tar.gz",
    "zig_hash": "sigbench-0.0.5-nAqBoOaRBQD-9MxV5v2pdn7wQwsmvZN8ggUVnC56b9Qh",
    "sha256": "56ae60cf542ac6a550866dc443072033df1716f96ac96b55739c28a1bc49196d",
    "license": "BSD-3-Clause",
    "lazy": True,
    "scope": "benchmark",
}


def package_files(
    root: Path,
    revision: str,
    paths: list[str],
    git_command=git,
) -> list[tuple[str, str, str]]:
    if not isinstance(paths, list) or any(not isinstance(path, str) for path in paths):
        fail("package allowlist must be a string list")
    if len(paths) != len(set(paths)):
        fail("package allowlist contains duplicate paths")
    missing_paths = sorted(REQUIRED_PACKAGE_PATHS - set(paths))
    if missing_paths:
        fail(f"package allowlist is incomplete: {', '.join(missing_paths)}")
    if any(path.startswith("tests/") for path in paths):
        fail("package allowlist must include the complete tests tree")
    for value in paths:
        safe_relative(value)
        if value.startswith(":"):
            fail(f"package allowlist path resembles Git pathspec magic: {value!r}")
    output = git_command(
        root,
        "--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree",
        revision, "--", *paths, text=False,
    )
    entries: list[tuple[str, str, str]] = []
    try:
        for raw in bytes(output).split(b"\0"):
            if not raw:
                continue
            metadata, raw_path = raw.split(b"\t", 1)
            mode, kind, object_id = metadata.decode("ascii").split()
            path = raw_path.decode("utf-8")
            safe_relative(path)
            if kind != "blob" or mode not in {"100644", "100755"}:
                fail(f"unsupported package entry {mode} {kind}: {path}")
            entries.append((path, mode, object_id))
    except (UnicodeError, ValueError) as error:
        fail(f"Git package tree is malformed or not UTF-8: {error}")
    entries.sort(key=lambda item: item[0].encode("utf-8"))
    if len({entry[0] for entry in entries}) != len(entries):
        fail("duplicate package entry")
    required = {"build.zig", "build.zig.zon", "src/ploof.zig", "LICENSE"}
    missing = sorted(required - {entry[0] for entry in entries})
    if missing:
        fail(f"package is missing required files: {', '.join(missing)}")
    return entries


def create_source_tar(
    root: Path,
    revision: str,
    zon: dict,
    destination: Path,
    source_date_epoch: int,
) -> None:
    entries = package_files(root, revision, zon["paths"])
    prefix = f"{zon['name']}-{zon['version']}"
    temporary = destination.with_name(destination.name + ".tmp")
    try:
        with tarfile.open(temporary, "w", format=tarfile.USTAR_FORMAT) as archive:
            for path, mode, object_id in entries:
                data = bytes(git(root, "cat-file", "blob", object_id, text=False))
                info = tarfile.TarInfo(f"{prefix}/{path}")
                info.size = len(data)
                info.mode = 0o755 if mode == "100755" else 0o644
                info.mtime = source_date_epoch
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                archive.addfile(info, io.BytesIO(data))
        temporary.replace(destination)
    except (OSError, OverflowError, tarfile.TarError, UnicodeError, ValueError) as error:
        fail(f"source archive cannot be encoded as deterministic USTAR: {error}")
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError as error:
            fail(f"source archive temporary file cannot be removed: {error}")


def timestamp(epoch: int) -> str:
    try:
        value = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    except (OSError, OverflowError, ValueError) as error:
        fail(f"source date epoch is outside supported UTC range: {error}")
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def spdx_document(
    version: str,
    revision: str,
    archive_name: str,
    archive_sha256: str,
    epoch: int,
    dependencies: dict,
) -> dict:
    build_only = validate_dependency_policy(dependencies)
    packages = [{
        "SPDXID": "SPDXRef-Package-ploof",
        "name": "ploof",
        "versionInfo": version,
        "downloadLocation": "NOASSERTION",
        "filesAnalyzed": False,
        "licenseConcluded": "BSD-3-Clause",
        "licenseDeclared": "BSD-3-Clause",
        "checksums": [{"algorithm": "SHA256", "checksumValue": archive_sha256}],
        "sourceInfo": f"Deterministic source archive {archive_name} at {revision}",
    }]
    relationships = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": "SPDXRef-Package-ploof",
    }]
    for dependency in build_only:
        identifier = "SPDXRef-Package-" + re.sub(
            r"[^A-Za-z0-9.-]", "-", dependency["name"],
        )
        packages.append({
            "SPDXID": identifier,
            "name": dependency["name"],
            "versionInfo": dependency["version"],
            "downloadLocation": dependency["url"],
            "filesAnalyzed": False,
            "licenseConcluded": dependency["license"],
            "licenseDeclared": dependency["license"],
            "checksums": [{"algorithm": "SHA256", "checksumValue": dependency["sha256"]}],
            "comment": "Lazy benchmark-only dependency; not linked into production.",
        })
        relationships.append({
            "spdxElementId": identifier,
            "relationshipType": "BUILD_DEPENDENCY_OF",
            "relatedSpdxElement": "SPDXRef-Package-ploof",
        })
    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "name": f"ploof-{version}",
        "documentNamespace": f"https://github.com/ferrreo/ploof/sbom/{revision}",
        "creationInfo": {"created": timestamp(epoch), "creators": ["Tool: ploof-release-v1"]},
        "packages": packages,
        "relationships": relationships,
    }


def validate_dependency_policy(policy: dict) -> list[dict]:
    required = {"schema_version", "production", "build_only"}
    if not isinstance(policy, dict):
        fail("release dependency policy has unexpected shape or version")
    if set(policy) != required or type(policy.get("schema_version")) is not int:
        fail("release dependency policy has unexpected shape or version")
    if policy["schema_version"] != 1 or policy["production"] != []:
        fail("release dependency policy has unsupported production dependencies")
    build_only = policy["build_only"]
    if not isinstance(build_only, list) or len(build_only) != 1:
        fail("release dependency policy requires exact Sigbench build dependency")
    dependency = build_only[0]
    fields = {
        "name", "version", "url", "zig_hash", "sha256", "license", "lazy", "scope",
    }
    if not isinstance(dependency, dict) or set(dependency) != fields:
        fail("release build dependency has unexpected shape")
    if dependency != SIGBENCH_DEPENDENCY or dependency["lazy"] is not True:
        fail("release build dependency pin is unsupported")
    return build_only


def provenance_document(
    revision: str,
    archive_name: str,
    archive_sha256: str,
    epoch: int,
    paths: list[str],
) -> dict:
    instant = timestamp(epoch)
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": archive_name, "digest": {"sha256": archive_sha256}}],
        "predicateType": "https://slsa.dev/provenance/v1",
        "predicate": {
            "buildDefinition": {
                "buildType": "https://github.com/ferrreo/ploof/source-archive/v1",
                "externalParameters": {"revision": revision, "package_paths": paths},
                "internalParameters": {},
                "resolvedDependencies": [{
                    "uri": "git+https://github.com/ferrreo/ploof.git",
                    "digest": {"gitCommit": revision},
                }],
            },
            "runDetails": {
                "builder": {"id": "https://github.com/ferrreo/ploof/tools/release.py@v1"},
                "metadata": {
                    "invocationId": revision,
                    "startedOn": instant,
                    "finishedOn": instant,
                },
            },
        },
    }


def verify_metadata(
    root: Path,
    directory: Path,
    manifest: dict,
    dependency_policy: dict,
    zon: dict,
) -> None:
    version = manifest["version"]
    archive = directory / f"ploof-{version}.tar"
    archive_hash = next(
        item["sha256"] for item in manifest["artifacts"] if item["path"] == archive.name
    )
    verify_archive(root, archive, manifest, zon)
    expected_spdx = spdx_document(
        version, manifest["revision"], archive.name, archive_hash,
        manifest["source_date_epoch"], dependency_policy,
    )
    verify_canonical_json(
        directory / f"ploof-{version}.spdx.json", expected_spdx, "SPDX document",
    )
    expected_provenance = provenance_document(
        manifest["revision"], archive.name, archive_hash, manifest["source_date_epoch"],
        zon["paths"],
    )
    verify_canonical_json(
        directory / f"ploof-{version}.provenance.json",
        expected_provenance,
        "local provenance",
    )


def verify_archive(root: Path, path: Path, manifest: dict, zon: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="ploof-source-verify-") as directory:
        expected = Path(directory) / path.name
        create_source_tar(
            root,
            manifest["revision"],
            zon,
            expected,
            manifest["source_date_epoch"],
        )
        if sha256_file(path) != sha256_file(expected):
            fail("source archive does not exactly match candidate Git package allowlist")


def verify_canonical_json(path: Path, expected: dict, label: str) -> None:
    try:
        actual = path.read_bytes()
    except OSError as error:
        fail(f"{label} is unreadable: {error}")
    if actual != canonical_json_bytes(expected):
        fail(f"{label} does not match canonical candidate content")
