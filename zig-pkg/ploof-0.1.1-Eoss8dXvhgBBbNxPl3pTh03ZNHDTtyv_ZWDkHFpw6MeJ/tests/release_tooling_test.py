#!/usr/bin/env python3

from __future__ import annotations

import copy
import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import release
import release_notes
import release_structure
from release_common import ReleaseError, parse_json
from release_environment import missing_cpu_features, parse_cpu_info
from release_external_evidence import (
    LOAD_DRIVER_SOURCE_PATHS,
    external_contract,
    load_external_manifest,
    load_driver_source_sha256,
    verify_external_artifact as _verify_external_artifact,
)
from release_gate_artifacts import verify_gate_artifact_policy
from release_gate_commands import CANONICAL_GATE_IDS, canonical_gate_command


class ReleaseToolingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="ploof-release-test-")
        self.root = Path(self.temporary.name)
        self.create_fixture()
        self.gate_command = mock.patch.object(
            release, "canonical_gate_command", return_value=["/bin/true"],
        )
        self.gate_command.start()

    def tearDown(self) -> None:
        self.gate_command.stop()
        self.temporary.cleanup()

    def create_fixture(self) -> None:
        for directory in (
            "benchmarks", "build", "fuzz", "src", "tools", "tests/unit", "docs",
            "release", ".github/workflows",
        ):
            (self.root / directory).mkdir(parents=True)
        self.write("build.zig", fixture_build())
        for path in (
            "benchmark.zig", "compile_failure_api.zig", "fuzz.zig",
            "proxy_origin.zig",
        ):
            self.write(path, "pub const fixture = true;\n")
        self.write(
            "test.zig",
            'test {\n'
            '    std.testing.refAllDecls(ploof);\n'
            '    _ = @import("tests/root.zig");\n'
            '    _ = @import("fuzz/root.zig");\n'
            '}\n',
        )
        self.write(
            "tsan.zig",
            'test {\n'
            '    _ = @import("tests/unit/runtime_tsan_test.zig");\n'
            '}\n',
        )
        self.write("tests/unit/runtime_tsan_test.zig", "test {}\n")
        self.write("fuzz/root.zig", "test {\n}\n")
        self.write("fuzz/targets.zig", "pub const fixture = true;\n")
        self.write(
            "tests/root.zig",
            'test {\n'
            '    _ = @import("unit/runtime_tsan_test.zig");\n'
            '}\n',
        )
        self.write("src/ploof.zig", "pub const version = \"fixture\";\n")
        self.write("benchmarks/benchmark.zig", 'const dependency = @import("sigbench");\n')
        self.write("tools/fixture.zig", "pub fn main() void {}\n")
        for path in LOAD_DRIVER_SOURCE_PATHS:
            self.write(path, (ROOT / path).read_text(encoding="utf-8"))
        self.write(
            "tools/test-proxy-interop.sh",
            (ROOT / "tools/test-proxy-interop.sh").read_text(encoding="utf-8"),
        )
        self.write("docs/README.md", "# Fixture\n")
        self.write("docs/MIGRATIONS.md", "# Migration notes\n\n## 0.1.1\n\nInitial.\n")
        self.write("README.md", "# Fixture\n")
        self.write("SECURITY.md", "# Security\n")
        self.write("LICENSE", "BSD 3-Clause License\n")
        self.write(
            ".gitignore",
            "src/ignored.zig\ntests/nested/.zig-cache/\n",
        )
        for lane in ("untrusted", "trusted", "scheduled", "release"):
            path = f".github/workflows/{lane}.yml"
            self.write(path, (ROOT / path).read_text(encoding="utf-8"))
        self.write("release/dependencies.json", fixture_dependencies())
        self.write("release/support-matrix.json", fixture_matrix())
        self.write("release/gates.json", fixture_gates())
        self.write("release/release-notes.json", fixture_release_notes())
        self.write("build.zig.zon", fixture_zon())
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "user.name", "Fixture")
        self.git("add", ".")
        environment = os.environ.copy()
        environment["GIT_AUTHOR_DATE"] = "1700000000 +0000"
        environment["GIT_COMMITTER_DATE"] = "1700000000 +0000"
        subprocess.run(
            ["git", "commit", "-q", "-m", "fixture"],
            cwd=self.root,
            env=environment,
            check=True,
        )
        self.evidence = self.root / "zig-out/benchmark-evidence"
        create_benchmark_evidence(
            self.root, self.evidence, self.git("rev-parse", "HEAD"),
        )

    def write(self, path: str, contents: str) -> None:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents, encoding="utf-8")

    def git(self, *arguments: str) -> str:
        return subprocess.check_output(["git", *arguments], cwd=self.root, text=True).strip()

    def commit_path(self, path: str, message: str) -> None:
        self.git("add", path)
        subprocess.run(
            ["git", "commit", "-q", "-m", message], cwd=self.root, check=True,
        )

    def test_archive_is_reproducible_and_tampering_fails(self) -> None:
        first = self.root / "first"
        second = self.root / "second"
        first_manifest = release.generate_release(
            self.root, "HEAD", first, "zig", self.evidence,
        )
        with tarfile.open(first / "ploof-0.1.1.tar", "r") as archive:
            for member in archive.getmembers():
                parts = set(Path(member.name).parts)
                generated = {
                    ".pytest_cache", ".zig-cache", "__pycache__",
                    "zig-cache", "zig-out", "zig-pkg",
                }
                self.assertFalse(generated & parts)
        self.write("release/support-matrix.json", '{"dirty":true}\n')
        self.write("release/dependencies.json", '{"dirty":true}\n')
        self.write("release/release-notes.json", '{"dirty":true}\n')
        second_manifest = release.generate_release(
            self.root, "HEAD", second, "zig", self.evidence,
        )
        self.assertEqual(
            sorted((path.name, path.read_bytes()) for path in first.iterdir()),
            sorted((path.name, path.read_bytes()) for path in second.iterdir()),
        )
        release.verify_release(self.root, first_manifest, True, "zig", self.evidence)
        archive = first / "ploof-0.1.1.tar"
        archive.write_bytes(archive.read_bytes() + b"tamper")
        with self.assertRaises(ReleaseError):
            release.verify_release(self.root, first_manifest, False, "zig", self.evidence)
        sbom = second / "ploof-0.1.1.spdx.json"
        sbom_value = release.read_json(sbom)
        sbom_value["spdxVersion"] = "SPDX-0.0"
        release.write_json(sbom, sbom_value)
        manifest_value = release.read_json(second_manifest)
        for artifact in manifest_value["artifacts"]:
            if artifact["path"] == sbom.name:
                artifact["sha256"] = release.sha256_file(sbom)
        release.write_json(second_manifest, manifest_value)
        with self.assertRaises(ReleaseError):
            release.verify_release(self.root, second_manifest, False, "zig", self.evidence)

    def test_rehashed_archive_mutations_are_rejected_against_candidate_git(self) -> None:
        for mutation in ("bytes", "insert", "remove"):
            with self.subTest(mutation=mutation):
                output = self.root / f"archive-{mutation}"
                manifest_path = release.generate_release(
                    self.root, "HEAD", output, "zig", self.evidence,
                )
                manifest = release.read_json(manifest_path)
                archive = output / "ploof-0.1.1.tar"
                rewrite_source_tar(archive, mutation, manifest["source_date_epoch"])
                rebind_tampered_archive(self.root, manifest_path)
                with self.assertRaisesRegex(
                    ReleaseError, "does not exactly match candidate Git package allowlist",
                ):
                    release.verify_release(
                        self.root, manifest_path, False, "zig", self.evidence,
                    )

    def test_rehashed_canonical_document_tamper_is_rejected(self) -> None:
        mutations = (
            ("spdx.json", ("creationInfo", "creators"), ["Tool: attacker"]),
            (
                "provenance.json",
                ("predicate", "runDetails", "builder", "id"),
                "https://attacker.invalid/builder",
            ),
        )
        for suffix, keys, value in mutations:
            with self.subTest(suffix=suffix):
                output = self.root / f"canonical-{suffix}"
                manifest_path = release.generate_release(
                    self.root, "HEAD", output, "zig", self.evidence,
                )
                path = output / f"ploof-0.1.1.{suffix}"
                document = release.read_json(path)
                target = document
                for key in keys[:-1]:
                    target = target[key]
                target[keys[-1]] = value
                release.write_json(path, document)
                rehash_manifest_artifact(manifest_path, path)
                with self.assertRaisesRegex(ReleaseError, "canonical candidate content"):
                    release.verify_release(
                        self.root, manifest_path, False, "zig", self.evidence,
                    )

    def test_release_output_and_subject_set_are_fail_closed(self) -> None:
        nonempty = self.root / "nonempty-release"
        nonempty.mkdir()
        (nonempty / "stale").write_text("stale\n", encoding="ascii")
        with self.assertRaises(ReleaseError):
            release.generate_release(self.root, "HEAD", nonempty, "zig", self.evidence)
        target = self.root / "real-release-directory"
        target.mkdir()
        symlink = self.root / "symlink-release-directory"
        symlink.symlink_to(target, target_is_directory=True)
        with self.assertRaises(ReleaseError):
            release.generate_release(self.root, "HEAD", symlink, "zig", self.evidence)
        output = self.root / "exact-release"
        manifest_path = release.generate_release(
            self.root, "HEAD", output, "zig", self.evidence,
        )
        (output / "stale-extra").write_text("stale\n", encoding="ascii")
        with self.assertRaisesRegex(ReleaseError, "subject set mismatch"):
            release.verify_release(self.root, manifest_path, False, "zig", self.evidence)
        (output / "stale-extra").unlink()
        checksum = output / "ploof-0.1.1.sha256"
        contents = checksum.read_bytes()
        checksum.unlink()
        outside = self.root / "outside-checksum"
        outside.write_bytes(contents)
        checksum.symlink_to(outside)
        with self.assertRaises(ReleaseError):
            release.verify_release(self.root, manifest_path, False, "zig", self.evidence)

    def test_artifact_manifest_requires_exact_types_and_canonical_revision(self) -> None:
        output = self.root / "typed-manifest"
        manifest_path = release.generate_release(
            self.root, "HEAD", output, "zig", self.evidence,
        )
        original = release.read_json(manifest_path)
        mutations = (
            ("HEAD revision", {"revision": "HEAD"}),
            ("boolean schema", {"schema_version": True}),
            ("boolean epoch", {"source_date_epoch": True}),
            ("mapping artifacts", {"artifacts": {}}),
        )
        for label, fields in mutations:
            with self.subTest(label=label):
                changed = copy.deepcopy(original)
                changed.update(fields)
                release.write_json(manifest_path, changed)
                with self.assertRaises(ReleaseError):
                    release.verify_release(
                        self.root, manifest_path, False, "zig", self.evidence,
                    )
        malformed = copy.deepcopy(original)
        malformed["artifacts"][0]["sha256"] = 7
        release.write_json(manifest_path, malformed)
        with self.assertRaises(ReleaseError):
            release.verify_release(self.root, manifest_path, False, "zig", self.evidence)
        manifest_path.write_bytes(b"{\xff}\n")
        with self.assertRaises(ReleaseError):
            release.verify_release(self.root, manifest_path, False, "zig", self.evidence)

    def test_release_notes_bind_candidate_subjects_and_reject_rehashed_tamper(self) -> None:
        output = self.root / "notes-release"
        manifest_path = release.generate_release(
            self.root, "HEAD", output, "zig", self.evidence,
        )
        manifest = release.read_json(manifest_path)
        notes_path = output / "ploof-0.1.1.release-notes.md"
        notes = notes_path.read_text(encoding="utf-8")
        self.assertIn(self.git("rev-parse", "HEAD"), notes)
        self.assertIn("HTTP/1.1", notes)
        self.assertIn("HTTP/2, HTTP/3, TLS, QUIC", notes)
        migration_hash = release.candidate_hash(
            self.root, self.git("rev-parse", "HEAD"), "docs/MIGRATIONS.md",
        )
        self.assertIn(migration_hash, notes)
        self.assertIsNone(release_notes.PLACEHOLDER_RE.search(notes))
        self.assertNotIn("https://github.com/", notes)
        note_record = next(
            artifact for artifact in manifest["artifacts"]
            if artifact["path"] == notes_path.name
        )
        self.assertNotIn(note_record["path"], notes)
        self.assertNotIn(note_record["sha256"], notes)
        for gate_id, profile in release_notes.BENCHMARK_GATES:
            report = self.evidence / f"{gate_id}.json"
            result_tar = self.evidence / "artifacts" / gate_id / f"{gate_id}.tar"
            self.assertIn(gate_id, notes)
            self.assertIn(profile, notes)
            self.assertIn(report.name, notes)
            self.assertIn(release.sha256_file(report), notes)
            self.assertIn(result_tar.relative_to(self.evidence).as_posix(), notes)
            self.assertIn(release.sha256_file(result_tar), notes)
        for artifact in manifest["artifacts"]:
            if artifact["path"] != notes_path.name:
                self.assertIn(artifact["path"], notes)
                self.assertIn(artifact["sha256"], notes)
        with tarfile.open(output / "ploof-0.1.1.tar", "r") as archive:
            names = {member.name for member in archive.getmembers()}
        self.assertIn("ploof-0.1.1/release/release-notes.json", names)
        self.assertNotIn("ploof-0.1.1/ploof-0.1.1.release-notes.md", names)
        notes_path.write_text(notes.replace("HTTP/1.1", "HTTP/9.9", 1), encoding="utf-8")
        for artifact in manifest["artifacts"]:
            if artifact["path"] == notes_path.name:
                artifact["sha256"] = release.sha256_file(notes_path)
        release.write_json(manifest_path, manifest)
        with self.assertRaises(ReleaseError):
            release.verify_release(
                self.root, manifest_path, False, "zig", self.evidence,
            )

    def test_release_notes_source_rejects_stale_unknown_and_placeholders(self) -> None:
        valid = json.loads(fixture_release_notes())
        stale = copy.deepcopy(valid)
        stale["version"] = "0.2.0"
        unknown = copy.deepcopy(valid)
        unknown["extra"] = "unreviewed"
        placeholder = copy.deepcopy(valid)
        placeholder["changes"][0] = "TBD"
        literal_placeholder = copy.deepcopy(valid)
        literal_placeholder["security"] = "Replace VERSION before publication."
        control = copy.deepcopy(valid)
        control["security"] = "Invalid delete character: \x7f"
        duplicate = copy.deepcopy(valid)
        duplicate["changes"].append(duplicate["changes"][0])
        for document in (
            stale, unknown, placeholder, literal_placeholder, control, duplicate,
        ):
            with self.assertRaises(ReleaseError):
                release_notes.validate_source_document(document, "0.1.1")
        valid["security"] = "This version has no known security correction."
        release_notes.validate_source_document(valid, "0.1.1")

    def test_release_notes_require_complete_benchmark_evidence(self) -> None:
        missing = release_notes.BENCHMARK_GATES[0][0]
        (self.evidence / f"{missing}.json").unlink()
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "missing-notes", "zig", self.evidence,
            )
        empty = self.root / "zig-out/empty-evidence"
        empty.mkdir(parents=True)
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "empty-notes", "zig", empty,
            )

    def test_release_notes_reject_wrong_benchmark_revision_result_and_profile(self) -> None:
        gate_id, profile = release_notes.BENCHMARK_GATES[0]
        report_path = self.evidence / f"{gate_id}.json"
        original = release.read_json(report_path)
        wrong_revision = copy.deepcopy(original)
        wrong_revision["revision"] = "f" * 40
        release.write_json(report_path, wrong_revision)
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "wrong-revision", "zig", self.evidence,
            )
        wrong_result = copy.deepcopy(original)
        wrong_result["result"] = "fail"
        release.write_json(report_path, wrong_result)
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "wrong-result", "zig", self.evidence,
            )
        release.write_json(report_path, original)
        with self.assertRaises(ReleaseError):
            release_notes.load_benchmark_report(
                self.root, self.git("rev-parse", "HEAD"), self.evidence,
                gate_id, profile + "-wrong",
            )

    def test_release_notes_reject_wrong_benchmark_artifact_hash(self) -> None:
        gate_id = release_notes.BENCHMARK_GATES[0][0]
        report_path = self.evidence / f"{gate_id}.json"
        report = release.read_json(report_path)
        tar_path = f"artifacts/{gate_id}/{gate_id}.tar"
        record = next(item for item in report["artifacts"] if item["path"] == tar_path)
        record["sha256"] = "0" * 64
        release.write_json(report_path, report)
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "wrong-hash", "zig", self.evidence,
            )

    def test_release_notes_reject_symlinked_evidence_component(self) -> None:
        gate_id = release_notes.BENCHMARK_GATES[0][0]
        evidence = self.root / "zig-out/release-notes-evidence"
        evidence.mkdir(parents=True)
        victim = self.root / "zig-out/release-notes-victim" / gate_id
        victim.mkdir(parents=True)
        contents = b"attacker-controlled benchmark evidence\n"
        artifact = victim / f"{gate_id}.tar"
        artifact.write_bytes(contents)
        (evidence / "artifacts").symlink_to(
            victim.parent, target_is_directory=True,
        )
        report = {"artifacts": [{
            "path": f"artifacts/{gate_id}/{gate_id}.tar",
            "sha256": release.sha256_bytes(contents),
        }]}

        with self.assertRaises(ReleaseError):
            release_notes.evidence_artifacts(evidence, gate_id, report)
        self.assertEqual(contents, artifact.read_bytes())

    def test_release_workflow_authenticates_before_candidate_tools(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        authenticate = workflow.index("Authenticate signed tag before candidate tools")
        install = workflow.index('tools/install-zig.sh "$RUNNER_TEMP/zig"')
        evidence_auth = workflow.index("Authenticate evidence workflow run")
        download = workflow.index("Download exact-candidate evidence")
        self.assertLess(authenticate, install)
        self.assertLess(authenticate, evidence_auth)
        self.assertLess(evidence_auth, download)
        self.assertIn('git verify-tag "$RELEASE_TAG"', workflow)
        self.assertIn("'^[1-9][0-9]{0,18}$'", workflow)
        self.assertIn('"repos/$GITHUB_REPOSITORY/actions/runs/$EVIDENCE_RUN_ID"', workflow)
        self.assertIn(
            "--source .github/workflows/evidence.yml=workflow_dispatch", workflow,
        )
        self.assertIn('--artifact "$base.release-notes.md"', workflow)
        self.assertIn("--evidence zig-out/evidence", workflow)
        self.assertNotIn("run-external-gate.sh release.documentation", workflow)

    def test_archive_consumer_enables_lazy_benchmark_graph(self) -> None:
        output = self.root / "consumer-release"
        manifest = release.generate_release(
            self.root, "HEAD", output, "zig", self.evidence,
        )
        commands: list[list[str]] = []
        original_run = release.run

        def capture(
            command: list[str],
            cwd: Path,
            *,
            check: bool = True,
            text: bool = True,
        ) -> subprocess.CompletedProcess:
            if command[:2] == ["zig", "build"]:
                commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")
            return original_run(command, cwd, check=check, text=text)

        with mock.patch.object(release, "run", side_effect=capture):
            release.extract_consumer(self.root, manifest, "zig", False, self.evidence)

        self.assertEqual("test", commands[0][2])
        self.assertEqual(
            [
                ["zig", "build", "-Dbenchmarks=true", "bench-release-safe"],
                ["zig", "build", "-Dbenchmarks=true", "bench-release-fast"],
            ],
            [command[:4] for command in commands[1:]],
        )
        for command in commands[1:]:
            self.assertEqual(["--", "--list"], command[-2:])

    def test_evidence_requires_every_pass_and_exact_hash(self) -> None:
        evidence = self.root / "zig-out/basic-evidence"
        release.record_gate(
            self.root, evidence, "fixture.one", "HEAD", ["/bin/true"], [],
        )
        with self.assertRaises(ReleaseError):
            release.verify_evidence(self.root, evidence, "HEAD")

        release.record_gate(
            self.root, evidence, "fixture.two", "HEAD", ["/bin/true"], [],
        )
        release.verify_evidence(self.root, evidence, "HEAD")
        report_path = evidence / "fixture.one.json"
        report = release.read_json(report_path)
        for runner in (
            dict(report["runner"], unexpected="value"),
            {key: value for key, value in report["runner"].items() if key != "microcode"},
            dict(report["runner"], name=7, cpu_model=False, microcode=[]),
        ):
            invalid = copy.deepcopy(report)
            invalid["runner"] = runner
            release.write_json(report_path, invalid)
            with self.assertRaises(ReleaseError):
                release.verify_evidence(self.root, evidence, "HEAD")
        invalid = copy.deepcopy(report)
        invalid["command"] = [1]
        release.write_json(report_path, invalid)
        with self.assertRaises(ReleaseError):
            release.verify_evidence(self.root, evidence, "HEAD")
        invalid["command"] = ["/bin/false"]
        release.write_json(report_path, invalid)
        with self.assertRaisesRegex(ReleaseError, "canonical gate policy"):
            release.verify_evidence(self.root, evidence, "HEAD")
        invalid = copy.deepcopy(report)
        invalid["artifacts"][0] = {
            "path": 123,
            "sha256": release.sha256_bytes(b"typed artifact\n"),
        }
        (evidence / "123").write_bytes(b"typed artifact\n")
        release.write_json(report_path, invalid)
        with self.assertRaises(ReleaseError):
            release.verify_evidence(self.root, evidence, "HEAD")
        release.write_json(report_path, report)
        (evidence / "fixture.one.log").write_text("tampered", encoding="utf-8")
        with self.assertRaises(ReleaseError):
            release.verify_evidence(self.root, evidence, "HEAD")

    def test_evidence_report_cannot_borrow_another_gate_artifact(self) -> None:
        evidence = self.root / "zig-out/cross-gate-evidence"
        for gate_id in ("fixture.one", "fixture.two"):
            release.record_gate(
                self.root, evidence, gate_id, "HEAD", ["/bin/true"], [],
            )
        first_path = evidence / "fixture.one.json"
        first = release.read_json(first_path)
        second_log = evidence / "fixture.two.log"
        first["artifacts"][0] = {
            "path": second_log.name,
            "sha256": release.sha256_file(second_log),
        }
        release.write_json(first_path, first)
        with self.assertRaisesRegex(ReleaseError, "outside its gate namespace"):
            release.verify_evidence(self.root, evidence, "HEAD")

    def test_evidence_artifact_count_includes_canonical_log(self) -> None:
        evidence = self.root / "zig-out/exact-artifact-count"
        release.record_gate(
            self.root, evidence, "fixture.one", "HEAD", ["/bin/true"], [],
        )
        with mock.patch.object(
            release, "minimum_artifacts", return_value=2,
        ), self.assertRaisesRegex(ReleaseError, "requires at least 2"):
            release.verify_gate_report(
                self.root,
                evidence,
                "fixture.one",
                self.git("rev-parse", "HEAD"),
            )

    def test_failed_gate_never_creates_pass_report(self) -> None:
        evidence = self.root / "zig-out/evidence"
        with mock.patch.object(
            release, "canonical_gate_command", return_value=["/bin/false"],
        ), self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, evidence, "fixture.one", "HEAD", ["/bin/false"], [],
            )
        self.assertFalse((evidence / "fixture.one.json").exists())
        self.assertTrue((evidence / "fixture.one.failed.json").exists())

    def test_gate_command_substitution_is_rejected_before_execution(self) -> None:
        evidence = self.root / "zig-out/evidence"
        with self.assertRaisesRegex(ReleaseError, "canonical gate policy"):
            release.record_gate(
                self.root, evidence, "fixture.one", "HEAD", ["/bin/false"], [],
            )
        self.assertFalse(evidence.exists())

    def test_canonical_gate_commands_cover_manifest_and_release_paths(self) -> None:
        gates = release.read_json(ROOT / "release/gates.json")
        self.assertEqual(CANONICAL_GATE_IDS, {gate["id"] for gate in gates["gates"]})
        self.assertEqual(
            canonical_gate_command(self.root, "HEAD", "release.archive"),
            [
                "python3", "tools/release.py", "verify-consumer",
                "--manifest", "zig-out/release/ploof-0.1.1.manifest.json",
                "--evidence", "zig-out/evidence", "--reproduce",
            ],
        )
        with self.assertRaisesRegex(ReleaseError, "no canonical gate command"):
            canonical_gate_command(self.root, "HEAD", "fixture.unknown")

    def test_release_archive_requires_exact_retained_subjects(self) -> None:
        prefix = "artifacts/release.archive/ploof-0.1.1"
        paths = {"release.archive.log"} | {
            prefix + suffix for suffix in (
                ".manifest.json",
                ".tar",
                ".sha256",
                ".zig-hash",
                ".spdx.json",
                ".provenance.json",
                ".release-notes.md",
            )
        }
        verify_gate_artifact_policy(
            self.root, "HEAD", "release.archive", paths,
        )
        paths.remove(prefix + ".spdx.json")
        paths.add("artifacts/release.archive/hosts")
        with self.assertRaisesRegex(ReleaseError, "subject set"):
            verify_gate_artifact_policy(
                self.root, "HEAD", "release.archive", paths,
            )

    def test_atomic_json_write_does_not_follow_attacker_symlinks(self) -> None:
        output = self.root / "zig-out/json-output"
        output.mkdir(parents=True)
        victim = self.root / "zig-out/json-victim"
        victim.write_bytes(b"victim remains unchanged\n")
        report = output / "report.json"
        temporary = output / "report.json.tmp"
        temporary.symlink_to(victim)

        with self.assertRaises(ReleaseError):
            release.write_json(report, {"safe": True})
        self.assertEqual(b"victim remains unchanged\n", victim.read_bytes())

        temporary.unlink()
        report.symlink_to(victim)
        release.write_json(report, {"safe": True})
        self.assertEqual(b"victim remains unchanged\n", victim.read_bytes())
        self.assertFalse(report.is_symlink())
        self.assertEqual({"safe": True}, release.read_json(report))

    def test_evidence_destinations_do_not_follow_attacker_symlinks(self) -> None:
        victim = self.root / "zig-out/evidence-victim"
        victim.parent.mkdir(parents=True, exist_ok=True)
        victim.write_bytes(b"victim remains unchanged\n")

        log_output = self.root / "zig-out/symlinked-log-output"
        log_output.mkdir()
        (log_output / "fixture.one.log").symlink_to(victim)
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, log_output, "fixture.one", "HEAD", ["/bin/true"], [],
            )
        self.assertEqual(b"victim remains unchanged\n", victim.read_bytes())

        artifact = self.root / "zig-out/retained-artifact.bin"
        artifact.write_bytes(b"retained evidence\n")
        artifact_output = self.root / "zig-out/symlinked-artifact-output"
        destination = artifact_output / "artifacts/fixture.one" / artifact.name
        destination.parent.mkdir(parents=True)
        destination.symlink_to(victim)
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root,
                artifact_output,
                "fixture.one",
                "HEAD",
                ["/bin/true"],
                [str(artifact)],
            )
        self.assertEqual(b"victim remains unchanged\n", victim.read_bytes())

        component_output = self.root / "zig-out/symlinked-component-output"
        component_output.mkdir()
        victim_directory = self.root / "zig-out/evidence-victim-directory"
        victim_directory.mkdir()
        (component_output / "artifacts").symlink_to(
            victim_directory, target_is_directory=True,
        )
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root,
                component_output,
                "fixture.one",
                "HEAD",
                ["/bin/true"],
                [str(artifact)],
            )
        self.assertEqual([], list(victim_directory.iterdir()))

    def test_evidence_verification_rejects_symlinked_parent_component(self) -> None:
        evidence = self.root / "zig-out/evidence-input"
        evidence.mkdir(parents=True)
        victim_directory = self.root / "zig-out/evidence-input-victim"
        victim_directory.mkdir()
        victim = victim_directory / "artifact.bin"
        contents = b"attacker-controlled artifact\n"
        victim.write_bytes(contents)
        (evidence / "artifacts").symlink_to(
            victim_directory, target_is_directory=True,
        )
        record = {
            "path": "artifacts/artifact.bin",
            "sha256": release.sha256_bytes(contents),
        }

        with self.assertRaises(ReleaseError):
            release.verify_evidence_artifact(
                evidence, record, set(), "fixture.one",
            )
        self.assertEqual(contents, victim.read_bytes())

    def test_evidence_merge_preserves_reports_and_artifacts(self) -> None:
        first = self.root / "zig-out/evidence-one"
        second = self.root / "zig-out/evidence-two"
        merged = self.root / "zig-out/evidence-merged"
        retained = self.root / "zig-out/retained-input.json"
        retained.parent.mkdir(exist_ok=True)
        retained.write_text('{"retained":true}\n', encoding="ascii")
        release.record_gate(
            self.root, first, "fixture.one", "HEAD", ["/bin/true"], [str(retained)],
        )
        release.record_gate(self.root, second, "fixture.two", "HEAD", ["/bin/true"], [])
        release.merge_evidence(self.root, [first, second], merged)
        with mock.patch.object(release, "verify_gate_artifact_policy"):
            release.verify_evidence(self.root, merged, "HEAD")
        self.assertTrue((merged / "artifacts/fixture.one/retained-input.json").is_file())

        release.write_json(second / "unknown.gate.json", {"gate_id": "unknown.gate"})
        with self.assertRaisesRegex(ReleaseError, "unknown release gate report"):
            release.merge_evidence(
                self.root, [first, second], self.root / "zig-out/evidence-rejected",
            )

    def test_evidence_enumeration_is_bounded(self) -> None:
        evidence = self.root / "zig-out/excess-root-evidence"
        evidence.mkdir(parents=True)
        for index in range(8):
            (evidence / f"junk-{index}").write_bytes(b"x")
        with self.assertRaisesRegex(ReleaseError, "directory entry limit"):
            release.verify_evidence(self.root, evidence, "HEAD")

        incoming = self.root / "zig-out/excess-tree-evidence"
        incoming.mkdir(parents=True)
        for index in range(65):
            (incoming / f"junk-{index}").write_bytes(b"x")
        with self.assertRaisesRegex(ReleaseError, "tree entry limit"):
            release.merge_evidence(
                self.root, [incoming], self.root / "zig-out/excess-merged",
            )

    def test_external_evidence_rejects_trivial_tar(self) -> None:
        gate_id = "scheduled.kernel-linux-6.1-intel"
        artifact = self.root / f"{gate_id}.tar"
        write_external_tar(artifact, None)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest, b"wrong retained evidence\n")
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )
        manifest = valid_external_manifest(gate_id)
        manifest["artifacts"][0]["sha256"] = release.sha256_bytes(b"")
        write_external_tar(artifact, manifest, b"")
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )

    def test_external_fuzz_rejects_mode_case_and_budget_drift(self) -> None:
        gate_id = "release.fuzz-budget"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest)
        verify_external_artifact(
            artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
        )
        mutations = []
        wrong_modes = copy.deepcopy(manifest)
        wrong_modes["optimization_modes"] = ["Debug", "ReleaseSafe"]
        mutations.append(wrong_modes)
        wrong_cases = copy.deepcopy(manifest)
        wrong_cases["cases_by_mode"]["ReleaseFast"] = ["http1"]
        mutations.append(wrong_cases)
        wrong_budget = copy.deepcopy(manifest)
        wrong_budget["fuzz_budget"]["generated_cases_per_process"] -= 1
        mutations.append(wrong_budget)
        for value in mutations:
            write_external_tar(artifact, value)
            with self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE,
                    external_gates(), external_dependencies(),
                )

    def test_external_deployment_requires_distinct_physical_hosts(self) -> None:
        gate_id = "scheduled.deployment-direct"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest)
        verify_external_artifact(
            artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
        )
        manifest["hosts"][1]["machine_id_sha256"] = manifest["hosts"][0][
            "machine_id_sha256"
        ]
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
            )
        manifest = valid_external_manifest(gate_id)
        manifest["hosts"][1]["inventory_id_sha256"] = manifest["hosts"][0][
            "inventory_id_sha256"
        ]
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
            )

    def test_external_hosts_require_linux_floor_and_x86_64_v3(self) -> None:
        gate_id = "scheduled.deployment-direct"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        for mutation in ("old-kernel", "missing-feature", "wrong-os"):
            invalid = copy.deepcopy(manifest)
            remote = invalid["hosts"][1]
            if mutation == "old-kernel":
                remote["kernel"] = "5.15.0"
            elif mutation == "missing-feature":
                remote["cpu_flags"] = " ".join(
                    flag for flag in remote["cpu_flags"].split() if flag != "popcnt"
                )
            else:
                remote["operating_system"] = "freebsd"
            write_external_tar(artifact, invalid)
            with self.subTest(mutation=mutation), self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE,
                    external_gates(), external_dependencies(),
                )

    def test_external_host_kind_type_fails_cleanly(self) -> None:
        gate_id = "scheduled.kernel-linux-6.1-intel"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        manifest["hosts"][0]["kind"] = []
        write_external_tar(artifact, manifest)
        with self.assertRaisesRegex(ReleaseError, "host identity is malformed"):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )

    def test_external_proxy_images_match_candidate_pins(self) -> None:
        gate_id = "scheduled.deployment-caddy"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest)
        verify_external_artifact(
            artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
        )
        for mutation in ("missing", "tag", "digest"):
            invalid = copy.deepcopy(manifest)
            if mutation == "missing":
                invalid["proxy_images"] = []
            elif mutation == "tag":
                invalid["proxy_images"][0]["tag"] = "latest"
            else:
                invalid["proxy_images"][0]["digest"] = "sha256:" + "0" * 64
            write_external_tar(artifact, invalid)
            with self.subTest(mutation=mutation), self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE,
                    external_gates(), external_dependencies(),
                )

    def test_external_soak_requires_real_full_recorder_interval(self) -> None:
        gate_id = "release.soak-current"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        report = external_report(manifest, 86400)
        write_external_tar(artifact, manifest)
        verify_external_artifact(
            artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(), report,
        )
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(),
                external_dependencies(), external_report(manifest, 3600),
            )
        manifest["soak"]["duration_seconds"] = 3600
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(),
                external_dependencies(), report,
            )

    def test_external_identity_resource_and_coverage_are_fail_closed(self) -> None:
        gate_id = "scheduled.runtime-benchmarks"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        mutations = []
        same_revision = copy.deepcopy(manifest)
        same_revision["baseline_revision"] = CANDIDATE
        mutations.append(same_revision)
        wrong_sigbench = copy.deepcopy(manifest)
        wrong_sigbench["sigbench"]["version"] = "0.0.4"
        mutations.append(wrong_sigbench)
        missing_topology = copy.deepcopy(manifest)
        missing_topology["topologies"] = ["in-process"]
        mutations.append(missing_topology)
        missing_workload = copy.deepcopy(manifest)
        missing_workload["workloads"] = manifest["workloads"][:-1]
        mutations.append(missing_workload)
        wrong_driver = copy.deepcopy(manifest)
        wrong_driver["load_driver"]["schema_version"] = 2
        mutations.append(wrong_driver)
        stale_source = copy.deepcopy(manifest)
        stale_source["load_driver"]["source_sha256"] = "0" * 64
        mutations.append(stale_source)
        wrong_binary_path = copy.deepcopy(manifest)
        wrong_binary_path["load_driver"]["binary_path"] = "bin/old-driver"
        mutations.append(wrong_binary_path)
        wrong_binary_hash = copy.deepcopy(manifest)
        wrong_binary_hash["load_driver"]["binary_sha256"] = "0" * 64
        mutations.append(wrong_binary_hash)
        for value in mutations:
            write_external_tar(artifact, value)
            with self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE,
                    external_gates(), external_dependencies(),
                )
        write_external_tar(artifact, manifest, binary=b"stale driver binary\n")
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )

    def test_external_sigbench_rejects_malformed_dependency_policy(self) -> None:
        gate_id = "scheduled.runtime-benchmarks"
        artifact = self.root / f"{gate_id}.tar"
        write_external_tar(artifact, valid_external_manifest(gate_id))
        dependencies = external_dependencies()
        dependencies["build_only"] = [None]
        with self.assertRaisesRegex(ReleaseError, "dependency has unexpected shape"):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(), dependencies,
            )

    def test_external_resource_plateau_rejects_false_declarations(self) -> None:
        gate_id = "scheduled.resource-plateau"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest)
        verify_external_artifact(
            artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
        )
        for key, value in (
            ("rss_stable", False),
            ("post_start_framework_allocations", 1),
            ("descriptor_delta", 1),
        ):
            invalid = copy.deepcopy(manifest)
            invalid["resource_plateau"][key] = value
            write_external_tar(artifact, invalid)
            with self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE,
                    external_gates(), external_dependencies(),
                )

    def test_external_tar_limits_and_uncompressed_format_are_enforced(self) -> None:
        gate_id = "release.fuzz-budget"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        write_external_tar(artifact, manifest, mode="w:gz")
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
            )
        for key in ("max_members", "max_member_bytes", "max_total_unpacked_bytes"):
            gates = external_gates()
            gates["external_evidence_policy"]["archive_limits"][key] = 1
            write_external_tar(artifact, manifest)
            with self.assertRaises(ReleaseError):
                verify_external_artifact(
                    artifact, gate_id, CANDIDATE, gates, external_dependencies(),
                )
        invalid_path = copy.deepcopy(manifest)
        invalid_path["artifacts"][-1]["path"] = "raw//report.txt"
        write_external_tar(artifact, invalid_path, raw_path="raw//report.txt")
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE, external_gates(), external_dependencies(),
            )

    def test_external_tar_member_limit_stops_enumeration(self) -> None:
        artifact = self.root / "bounded.tar"
        artifact.write_bytes(b"tar")
        limits = copy.deepcopy(
            external_gates()["external_evidence_policy"]["archive_limits"],
        )
        limits["max_members"] = 1
        consumed: list[str] = []

        class OverLimitArchive:
            def __enter__(self) -> OverLimitArchive:
                return self

            def __exit__(self, *arguments: object) -> None:
                pass

            def __iter__(self):
                consumed.append("first")
                yield tarfile.TarInfo("first")
                consumed.append("second")
                yield tarfile.TarInfo("second")
                consumed.append("past-limit")
                raise AssertionError("tar enumeration continued past member limit")

        with mock.patch(
            "release_external_evidence.validate_raw_tar_headers",
        ), mock.patch(
            "release_external_evidence.tarfile.open",
            return_value=OverLimitArchive(),
        ), self.assertRaisesRegex(ReleaseError, "member-count limit"):
            load_external_manifest(
                artifact, "external-evidence-manifest.json", limits,
            )
        self.assertEqual(consumed, ["first", "second"])

    def test_external_tar_rejects_pax_and_gnu_metadata_before_iteration(self) -> None:
        artifact = self.root / "extended-metadata.tar"
        limits = external_gates()["external_evidence_policy"]["archive_limits"]
        payload = b"{}\n"
        with tarfile.open(
            artifact,
            "w",
            format=tarfile.PAX_FORMAT,
            pax_headers={"comment": "x" * (1024 * 1024)},
        ) as archive:
            member = tarfile.TarInfo("external-evidence-manifest.json")
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(ReleaseError, "extended or special metadata"):
            load_external_manifest(
                artifact, "external-evidence-manifest.json", limits,
            )

        with tarfile.open(artifact, "w", format=tarfile.GNU_FORMAT) as archive:
            member = tarfile.TarInfo("x" * 200)
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(ReleaseError, "extended or special metadata"):
            load_external_manifest(
                artifact, "external-evidence-manifest.json", limits,
            )

    def test_external_tar_rejects_symlinked_parent_component(self) -> None:
        gate_id = "scheduled.kernel-linux-6.1-intel"
        victim_directory = self.root / "zig-out/external-tar-victim"
        victim_directory.mkdir(parents=True)
        artifact = victim_directory / f"{gate_id}.tar"
        write_external_tar(artifact, valid_external_manifest(gate_id))
        linked_directory = self.root / "zig-out/external-tar-link"
        linked_directory.symlink_to(victim_directory, target_is_directory=True)
        limits = external_gates()["external_evidence_policy"]["archive_limits"]

        with self.assertRaises(ReleaseError):
            load_external_manifest(
                linked_directory / artifact.name,
                "external-evidence-manifest.json",
                limits,
            )

    def test_dirty_source_cannot_create_passing_evidence(self) -> None:
        output = self.root / "zig-out/dirty-evidence"
        original = "pub const version = \"fixture\";\n"
        self.write("src/ploof.zig", "pub const version = \"dirty\";\n")
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, output, "fixture.one", "HEAD", ["/bin/true"], [],
            )
        self.assertFalse((output / "fixture.one.json").exists())
        self.write("src/ploof.zig", original)
        self.write("src/hidden.zig", "pub const hidden = true;\n")
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, output, "fixture.one", "HEAD", ["/bin/true"], [],
            )
        (self.root / "src/hidden.zig").unlink()
        self.write("src/ignored.zig", "pub const ignored = true;\n")
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, output, "fixture.one", "HEAD", ["/bin/true"], [],
            )
        (self.root / "src/ignored.zig").unlink()
        nested_cache = self.root / "tests/nested/.zig-cache/poison.zig"
        self.write("tests/nested/.zig-cache/poison.zig", "pub const poison = true;\n")
        with self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, output, "fixture.one", "HEAD", ["/bin/true"], [],
            )
        nested_cache.unlink()
        nested_cache.parent.rmdir()
        command = ["/bin/sh", "-c", "printf dirty > src/ploof.zig"]
        with mock.patch.object(
            release, "canonical_gate_command", return_value=command,
        ), self.assertRaises(ReleaseError):
            release.record_gate(
                self.root, output, "fixture.one", "HEAD", command, [],
            )
        self.assertFalse((output / "fixture.one.json").exists())
        self.assertTrue((output / "fixture.one.failed.json").exists())

    def test_cpu_aliases_and_declared_runner_identity(self) -> None:
        matrix = release.read_json(ROOT / "release/support-matrix.json")
        flags = {feature["linux_flags"][0] for feature in matrix["cpu_features"]}
        self.assertEqual([], missing_cpu_features(matrix, flags))
        flags.remove("popcnt")
        self.assertEqual(["popcnt"], missing_cpu_features(matrix, flags))
        runner = {
            "architecture": "x86_64",
            "kernel": "6.1.3-pikaos",
            "cpu_vendor": "FixtureVendor",
            "cpu_flags": "",
            "zig": "0.16.0",
        }
        release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)
        runner["kernel"] = "6.1.4"
        release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)
        runner["kernel"] = "6.1.2"
        with self.assertRaises(ReleaseError):
            release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)
        runner["kernel"] = "6.1.3suffix"
        with self.assertRaises(ReleaseError):
            release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)
        runner["kernel"] = "6.1.3-rc1"
        with self.assertRaises(ReleaseError):
            release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)
        runner["kernel"] = "1" * 129
        with self.assertRaises(ReleaseError):
            release.verify_runner_identity(self.root, "HEAD", "mapped.gate", runner)

    def test_cpu_info_uses_features_common_to_every_online_cpu(self) -> None:
        info = parse_cpu_info(
            "processor: 0\nvendor_id: GenuineIntel\nmodel name: Fast\n"
            "flags: avx avx2 popcnt\nmicrocode: 1\n\n"
            "processor: 1\nvendor_id: GenuineIntel\nmodel name: Slow\n"
            "flags: avx popcnt\nmicrocode: 2\n",
        )
        self.assertEqual(info["flags"], "avx popcnt")
        self.assertEqual(info["vendor_id"], "GenuineIntel")
        self.assertEqual(info["model name"], "mixed")
        self.assertEqual(info["microcode"], "mixed")

    def test_package_rejects_generated_paths_at_any_depth(self) -> None:
        generated = (
            ".pytest_cache", ".zig-cache", "__pycache__",
            "zig-cache", "zig-out", "zig-pkg",
        )
        for name in generated:
            with self.subTest(name=name), self.assertRaises(ReleaseError):
                release.safe_relative(f"tests/nested/{name}/sentinel")
        with self.assertRaises(ReleaseError):
            release.safe_relative("tests/nested/cache.pyc")
        for path in (
            "tests\\escape", "tests//escape", "tests/./escape",
            "tests/trailing/", "tests/control\x00", "tests/control\x7f",
        ):
            with self.assertRaises(ReleaseError):
                release.safe_relative(path)
        self.write("tests/nested/zig-pkg/sentinel", "must not ship\n")
        self.git("add", "tests/nested/zig-pkg/sentinel")
        subprocess.run(
            ["git", "commit", "-q", "-m", "add forbidden generated path"],
            cwd=self.root,
            check=True,
        )
        zon = release.parse_zon(self.git("show", "HEAD:build.zig.zon"))
        with self.assertRaises(ReleaseError):
            release.package_files(self.root, "HEAD", zon["paths"])

    def test_package_git_allowlist_uses_literal_pathspecs(self) -> None:
        paths = [
            "build.zig", "build.zig.zon", "src", "tools", "tests", "docs",
            "release", "LICENSE", "README.md", "SECURITY.md",
        ]
        with mock.patch.object(release, "git", return_value=b"") as git_call:
            with self.assertRaises(ReleaseError):
                release.package_files(self.root, "HEAD", paths)
        self.assertEqual("--literal-pathspecs", git_call.call_args.args[1])
        with self.assertRaises(ReleaseError):
            release.package_files(self.root, "HEAD", paths + ["src"])
        with self.assertRaises(ReleaseError):
            release.package_files(self.root, "HEAD", paths + [":(glob)**"])

    def test_boolean_numbers_are_rejected_in_evidence_policies(self) -> None:
        gates = external_gates()
        gates["external_evidence_policy"]["archive_limits"]["max_members"] = True
        with self.assertRaises(ReleaseError):
            external_contract(gates, "release.fuzz-budget")
        gates = external_gates()
        profile = gates["external_evidence_policy"]["contracts"]["release.fuzz-budget"]
        gates["external_evidence_policy"]["profiles"][profile]["fuzz_budget"][
            "generated_cases_per_process"
        ] = True
        with self.assertRaises(ReleaseError):
            external_contract(gates, "release.fuzz-budget")
        gates = external_gates()
        profile = gates["external_evidence_policy"]["contracts"]["release.soak-floor"]
        gates["external_evidence_policy"]["profiles"][profile]["soak_seconds"] = True
        with self.assertRaises(ReleaseError):
            external_contract(gates, "release.soak-floor")
        gate_id = "scheduled.resource-plateau"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        manifest["resource_plateau"]["samples"] = True
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )
        manifest = valid_external_manifest(gate_id)
        manifest["resource_plateau"]["rss_stable"] = 1
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )
        gate_id = "release.fuzz-budget"
        artifact = self.root / f"{gate_id}.tar"
        manifest = valid_external_manifest(gate_id)
        manifest["fuzz_budget"]["processes_per_target"] = True
        write_external_tar(artifact, manifest)
        with self.assertRaises(ReleaseError):
            verify_external_artifact(
                artifact, gate_id, CANDIDATE,
                external_gates(), external_dependencies(),
            )
        with mock.patch.object(release, "gate_manifest") as gate_manifest:
            gate_manifest.return_value = {
                "artifact_policy": {
                    "default_minimum": True, "minimum_by_prefix": {},
                    "minimum_by_gate": {},
                },
            }
            with self.assertRaises(ReleaseError):
                release.minimum_artifacts(self.root, "fixture.one", "HEAD")

    def test_malformed_candidate_dependencies_fail_without_traceback(self) -> None:
        self.write(
            "release/dependencies.json",
            json.dumps({
                "schema_version": 1,
                "production": [],
                "build_only": [{"name": 7}],
            }) + "\n",
        )
        self.commit_path("release/dependencies.json", "malformed dependencies")
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "bad-dependencies", "zig", self.evidence,
            )

    def test_malformed_support_scalars_fail_without_traceback(self) -> None:
        matrix = json.loads(fixture_matrix())
        matrix["production_target"]["libc"] = "false"
        self.write("release/support-matrix.json", json.dumps(matrix) + "\n")
        self.commit_path("release/support-matrix.json", "malformed support matrix")
        revision = self.git("rev-parse", "HEAD")
        create_benchmark_evidence(self.root, self.evidence, revision)
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "bad-support", "zig", self.evidence,
            )

    def test_invalid_candidate_utf8_fails_without_traceback(self) -> None:
        (self.root / "release/release-notes.json").write_bytes(b"{\xff}\n")
        self.commit_path("release/release-notes.json", "invalid release notes UTF-8")
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "bad-utf8", "zig", self.evidence,
            )

    def test_invalid_git_path_and_ustar_path_fail_without_traceback(self) -> None:
        invalid = os.fsencode(self.root / "tests") + b"/invalid-\xff"
        descriptor = os.open(invalid, os.O_WRONLY | os.O_CREAT, 0o644)
        try:
            os.write(descriptor, b"invalid path\n")
        finally:
            os.close(descriptor)
        self.git("add", "-A")
        subprocess.run(
            ["git", "commit", "-q", "-m", "invalid UTF-8 path"],
            cwd=self.root,
            check=True,
        )
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "bad-path", "zig", self.evidence,
            )

    def test_unencodable_ustar_path_fails_without_traceback(self) -> None:
        path = "tests/" + "/".join(["longsegment"] * 30) + "/fixture.txt"
        self.write(path, "too long for USTAR\n")
        self.commit_path(path, "unencodable USTAR path")
        with self.assertRaisesRegex(ReleaseError, "deterministic USTAR"):
            release.generate_release(
                self.root, "HEAD", self.root / "bad-ustar", "zig", self.evidence,
            )

    def test_structure_fixture_and_limits(self) -> None:
        self.write(
            "tools/run-fuzz-matrix.sh",
            (ROOT / "tools/run-fuzz-matrix.sh").read_text(),
        )
        for name in (
            "support-matrix.json", "gates.json", "evidence.schema.json",
            "external-evidence.schema.json", "artifact-manifest.schema.json",
            "release-notes.schema.json",
        ):
            self.write(f"release/{name}", (ROOT / "release" / name).read_text())
        release_structure.check_structure(self.root)
        self.write("tests/unit/unlisted.zig", "test {}\n")
        with (self.root / "tests/root.zig").open("a", encoding="utf-8") as root_file:
            root_file.write(
                '// @import("unit/unlisted.zig")\n'
                '/* _ = @import("unit/unlisted.zig"); */\n'
            )
        with self.assertRaisesRegex(ReleaseError, "tests/root.zig: missing imports"):
            release_structure.check_structure(self.root)
        with (self.root / "tests/root.zig").open("a", encoding="utf-8") as root_file:
            root_file.write(
                'fn never() void { _ = @import("unit/unlisted.zig"); }\n'
            )
        with self.assertRaisesRegex(ReleaseError, "tests/root.zig: root body"):
            release_structure.check_structure(self.root)
        (self.root / "tests/unit/unlisted.zig").unlink()
        self.write(
            "tests/root.zig",
            'test {\n'
            '    _ = @import("unit/runtime_tsan_test.zig");\n'
            '}\n',
        )
        self.write("fuzz/unlisted.zig", "test {}\n")
        with self.assertRaisesRegex(ReleaseError, "fuzz/root.zig: missing imports"):
            release_structure.check_structure(self.root)
        (self.root / "fuzz/unlisted.zig").unlink()
        self.write(
            "test.zig",
            'test { _ = @import("tests/root.zig"); }\n'
            '/* _ = @import("fuzz/root.zig"); */\n'
            'fn never() void { _ = @import("fuzz/root.zig"); }\n',
        )
        with self.assertRaisesRegex(ReleaseError, "test.zig: test root body"):
            release_structure.check_structure(self.root)
        self.write(
            "test.zig",
            'test {\n'
            '    std.testing.refAllDecls(ploof);\n'
            '    _ = @import("tests/root.zig");\n'
            '    _ = @import("fuzz/root.zig");\n'
            '}\n',
        )
        release.write_json(
            self.root / "release/evidence.schema.json",
            {"$schema": "https://json-schema.org/draft/2020-12/schema"},
        )
        with self.assertRaisesRegex(ReleaseError, "canonical schema contract changed"):
            release_structure.check_structure(self.root)
        self.write(
            "release/evidence.schema.json",
            (ROOT / "release/evidence.schema.json").read_text(),
        )
        gates = release.read_json(self.root / "release/gates.json")
        gates["external_evidence_policy"]["profiles"]["release-fuzz"][
            "fuzz_budget"
        ]["generated_cases_per_process"] = 999_999
        release.write_json(self.root / "release/gates.json", gates)
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        self.write("release/gates.json", (ROOT / "release/gates.json").read_text())
        for mutation in ("schema", "artifact", "contract"):
            gates = release.read_json(ROOT / "release/gates.json")
            if mutation == "schema":
                gates["schema_version"] = True
            elif mutation == "artifact":
                gates["artifact_policy"] = {
                    "default_minimum": 1,
                    "minimum_by_prefix": {},
                    "minimum_by_gate": {},
                }
            else:
                gates["external_evidence_policy"]["contracts"][
                    "release.soak-current"
                ] = "kernel-suite"
            release.write_json(self.root / "release/gates.json", gates)
            with self.assertRaises(ReleaseError):
                release_structure.check_structure(self.root)
        self.write("release/gates.json", (ROOT / "release/gates.json").read_text())
        matrix = release.read_json(self.root / "release/support-matrix.json")
        matrix["cpu_features"] = [{"name": [], "linux_flags": "bad"}]
        release.write_json(self.root / "release/support-matrix.json", matrix)
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        self.write(
            "release/support-matrix.json",
            (ROOT / "release/support-matrix.json").read_text(),
        )
        for field in ("schema_version", "libc", "liburing"):
            matrix = release.read_json(ROOT / "release/support-matrix.json")
            if field == "schema_version":
                matrix[field] = True
            else:
                matrix["production_target"][field] = 0
            release.write_json(self.root / "release/support-matrix.json", matrix)
            with self.assertRaises(ReleaseError):
                release_structure.check_structure(self.root)
        self.write(
            "release/support-matrix.json",
            (ROOT / "release/support-matrix.json").read_text(),
        )
        declarations = "".join(f"        const x{index} = {index};\n" for index in range(75))
        self.write(
            "src/factory.zig",
            "fn factory() type {\n    return struct {\n" + declarations +
            "        pub fn value() u8 { return 1; }\n    };\n}\n",
        )
        release_structure.check_structure(self.root)
        prelude = "".join(f"    const y{index} = {index};\n" for index in range(71))
        self.write(
            "src/factory.zig",
            "fn factory() type {\n" + prelude + "    return struct {};\n}\n",
        )
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        self.write(
            "src/factory.zig",
            "fn factory(comptime flag: bool) type {\n" +
            "    if (flag) return struct {};\n" + prelude +
            "    return struct {};\n}\n",
        )
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        self.write("src/factory.zig", "fn factory() type {\n" + prelude + "    return u32;\n}\n")
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        (self.root / "src/factory.zig").unlink()
        self.write("fuzz/large_fuzz_check.zig", "pub const x = 1;\n" * 751)
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        (self.root / "fuzz/large_fuzz_check.zig").unlink()
        self.write("tools/test-helper.zig", "pub const debt = \"TODO\";\n")
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        (self.root / "tools/test-helper.zig").unlink()
        self.write("tests/nested/skip.zig", "test \"skip\" { return error.SkipZigTest; }\n")
        with self.assertRaisesRegex(ReleaseError, "release tests may not skip"):
            release_structure.check_structure(self.root)
        (self.root / "tests/nested/skip.zig").unlink()
        self.write("tests/vendor/skip.zig", "test \"skip\" { return error.SkipZigTest; }\n")
        with self.assertRaisesRegex(ReleaseError, "release tests may not skip"):
            release_structure.check_structure(self.root)
        (self.root / "tests/vendor/skip.zig").unlink()
        self.write("tests/nested/zig-pkg/skip.zig", "return error.SkipZigTest;\n")
        release_structure.check_structure(self.root)
        (self.root / "tests/nested/zig-pkg/skip.zig").unlink()
        self.write("tests/width_test.zig", "pub const value = \"" + "x" * 101 + "\";\n")
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        (self.root / "tests/width_test.zig").unlink()
        body = "".join(f"    const x{index} = {index};\n" for index in range(71))
        self.write("tests/long_test.zig", "fn long() void {\n" + body + "}\n")
        with self.assertRaises(ReleaseError):
            release_structure.check_structure(self.root)
        (self.root / "tests/long_test.zig").unlink()
        self.write("src/.zig-cache/generated.zig", "pub const x = 1;\n" * 751)
        release_structure.check_structure(self.root)

    def test_fuzz_selector_matches_build_targets(self) -> None:
        self.write(
            "build_fuzz.zig",
            'const targets = .{.{\n'
            '    .file = "fuzz/one.zig",\n'
            '    .filter = "one fuzz",\n'
            '}};\n',
        )
        self.write("fuzz/one.zig", 'test "one fuzz target" {}\n')
        self.write(
            "fuzz/targets.zig",
            'pub fn select(comptime target: []const u8) type {\n'
            '    if (select0(target)) |selected| return selected;\n'
            '    @compileError("unknown fuzz target");\n'
            '}\n'
            'fn select0(comptime target: []const u8) ?type {\n'
            '    if (eql(target, "fuzz/one.zig")) return @import(\n'
            '        "../fuzz/one.zig",\n'
            '    );\n'
            '    return null;\n'
            '}\n',
        )
        errors: list[str] = []
        release_structure.check_fuzz_selector(self.root, errors)
        self.assertEqual([], errors)
        self.write(
            "build_fuzz.zig",
            'const targets = .{.{\n'
            '    .file = "fuzz/one.zig",\n'
            '    .filter = "missing fuzz",\n'
            '}};\n',
        )
        errors = []
        release_structure.check_fuzz_selector(self.root, errors)
        self.assertIn(
            "build_fuzz.zig: filter is unreachable from fuzz/one.zig: missing fuzz",
            errors,
        )
        self.write(
            "build_fuzz.zig",
            'const targets = .{.{\n'
            '    .file = "fuzz/one.zig",\n'
            '    .filter = "one fuzz",\n'
            '}};\n',
        )
        self.write(
            "fuzz/targets.zig",
            'pub fn select(comptime target: []const u8) type {\n'
            '    if (select0(target)) |selected| return selected;\n'
            '    @compileError("unknown fuzz target");\n'
            '}\n'
            'fn select0(comptime target: []const u8) ?type {\n'
            '    if (eql(target, "fuzz/two.zig")) return @import(\n'
            '        "../fuzz/two.zig",\n'
            '    );\n'
            '    return null;\n'
            '}\n'
            'fn never(comptime target: []const u8) ?type {\n'
            '    // if (eql(target, "fuzz/one.zig")) return @import(\n'
            '    /* if (eql(target, "fuzz/one.zig")) return @import( */\n'
            '    if (eql(target, "fuzz/one.zig")) return @import(\n'
            '        "../fuzz/one.zig",\n'
            '    );\n'
            '    return null;\n'
            '}\n',
        )
        errors = []
        release_structure.check_fuzz_selector(self.root, errors)
        self.assertEqual(2, len(errors))

    def test_fuzz_filter_reachability_requires_forced_import(self) -> None:
        self.write("fuzz/nested.zig", 'test "nested fuzz target" {}\n')
        self.write(
            "fuzz/wrapper.zig",
            'const nested = @import("nested.zig");\n',
        )
        errors: list[str] = []
        self.assertFalse(release_structure.fuzz_filter_reachable(
            self.root,
            "fuzz/wrapper.zig",
            "nested fuzz",
            errors,
        ))
        self.write(
            "fuzz/wrapper.zig",
            'const text =\n'
            '    \\\\/*\n'
            ';\n'
            'test "real fuzz target" {}\n',
        )
        self.assertTrue(release_structure.fuzz_filter_reachable(
            self.root,
            "fuzz/wrapper.zig",
            "real fuzz",
            errors,
        ))
        self.write(
            "fuzz/wrapper.zig",
            'const text =\n'
            '    \\\\test "nested fuzz target" {}\n'
            ';\n',
        )
        self.assertFalse(release_structure.fuzz_filter_reachable(
            self.root,
            "fuzz/wrapper.zig",
            "nested fuzz",
            errors,
        ))
        self.write(
            "fuzz/wrapper.zig",
            'const nested = @import("nested.zig");\n'
            'test {\n'
            '    _ = nested;\n'
            '}\n',
        )
        self.assertTrue(release_structure.fuzz_filter_reachable(
            self.root,
            "fuzz/wrapper.zig",
            "nested fuzz",
            errors,
        ))

    def test_fuzz_matrix_matches_build_family_wiring(self) -> None:
        self.write("build.zig", 'const fuzz = @import("build_fuzz.zig");\n')
        self.write("build_fuzz.zig", (ROOT / "build_fuzz.zig").read_text())
        self.write(
            "tools/run-fuzz-matrix.sh",
            (ROOT / "tools/run-fuzz-matrix.sh").read_text(),
        )
        gates = release.read_json(ROOT / "release/gates.json")
        errors: list[str] = []
        release_structure.check_external_invariants(self.root, gates, errors)
        self.assertEqual(errors, [])

        build_fuzz = (self.root / "build_fuzz.zig").read_text()
        self.write("build_fuzz.zig", build_fuzz.replace("fuzz-http1", "fuzz-http-one", 1))
        release_structure.check_external_invariants(self.root, gates, errors)
        self.assertIn("fuzz family matrix does not match build_fuzz.zig", errors)

        malformed = copy.deepcopy(gates)
        malformed["external_evidence_policy"] = []
        errors = []
        release_structure.check_external_invariants(self.root, malformed, errors)
        self.assertEqual(
            errors, ["release/gates.json: external evidence policy is malformed"],
        )

        weakened = copy.deepcopy(gates)
        weakened["external_evidence_policy"]["profiles"]["runtime-benchmarks"][
            "workloads"
        ] = []
        errors = []
        release_structure.check_external_invariants(self.root, weakened, errors)
        self.assertTrue(any("exact profiles changed" in error for error in errors))

        script = (ROOT / "tools/run-fuzz-matrix.sh").read_text(encoding="utf-8")
        self.write("tools/run-fuzz-matrix.sh", script.replace(" csrf", "", 1))
        errors = []
        release_structure.check_external_invariants(self.root, gates, errors)
        self.assertIn("fuzz family policy changed", errors)

    def test_structure_reads_candidate_inputs_bounded_without_following_symlinks(self) -> None:
        gates_path = self.root / "release/gates.json"
        gates_text = gates_path.read_text(encoding="utf-8")
        gates_path.unlink()
        gates_path.symlink_to("/dev/zero")
        with self.assertRaisesRegex(ReleaseError, "cannot open regular source"):
            release_structure.check_structure(self.root)
        gates_path.unlink()
        self.write("release/gates.json", gates_text)

        script = self.root / "tools/run-fuzz-matrix.sh"
        script.symlink_to("/dev/zero")
        errors: list[str] = []
        release_structure.check_external_invariants(
            self.root,
            release.read_json(gates_path),
            errors,
        )
        self.assertTrue(any("cannot open regular source" in error for error in errors))

    def test_workflow_pin_scan_covers_yaml_and_quoted_keys(self) -> None:
        workflow = self.root / ".github/workflows/escape.yaml"
        workflow.write_text('steps:\n  - "uses": owner/action@main\n', encoding="ascii")
        errors: list[str] = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("action is not SHA-pinned", errors[0])
        workflow.write_text(
            'steps:\n  - "uses": "owner/action@' + "a" * 40 + '"\n',
            encoding="ascii",
        )
        errors = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(errors, [])

        for source in (
            'steps:\n  - "us\\u0065s": owner/action@main\n',
            'steps:\n  - { uses: owner/action@main }\n',
            'key: &key uses\nsteps:\n  ? *key\n  : owner/action@main\n',
        ):
            workflow.write_text(source, encoding="ascii")
            errors = []
            release_structure.check_workflows(self.root, errors)
            self.assertEqual(len(errors), 1)
            self.assertIn("uses syntax is not canonical", errors[0])

    def test_workflow_gate_command_substitution_is_rejected(self) -> None:
        workflow = self.root / ".github/workflows/untrusted.yml"
        source = workflow.read_text(encoding="utf-8")
        workflow.write_text(
            source.replace("-- zig build test-untrusted\n", "-- /bin/true\n", 1),
            encoding="utf-8",
        )
        errors: list[str] = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(
            errors,
            [".github/workflows/untrusted.yml: canonical gate command wiring changed"],
        )

    def test_workflow_gate_artifact_substitution_is_rejected(self) -> None:
        workflow = self.root / ".github/workflows/release.yml"
        source = workflow.read_text(encoding="utf-8")
        workflow.write_text(
            source.replace('--artifact "$base.spdx.json"', '--artifact /etc/hosts', 1),
            encoding="utf-8",
        )
        errors: list[str] = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(
            errors,
            [".github/workflows/release.yml: canonical gate artifact wiring changed"],
        )

    def test_workflow_pin_scan_covers_composite_actions(self) -> None:
        self.write(
            ".github/workflows/local.yml",
            "steps:\n  - uses: ./.github/actions/bridge\n",
        )
        action = ".github/actions/bridge/action.yml"
        self.write(action, "runs:\n  using: composite\n  steps:\n    - uses: owner/action@main\n")
        errors: list[str] = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn(f"{action}:4: action is not SHA-pinned", errors[0])

        self.write(
            action,
            "runs:\n  using: composite\n  steps:\n    - uses: owner/action@" + "a" * 40 + "\n",
        )
        errors = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(errors, [])

        self.write("tools/bridge/action.yml", self.root.joinpath(action).read_text())
        self.write(
            ".github/workflows/local.yml",
            "steps:\n  - uses: ./tools/bridge\n",
        )
        errors = []
        release_structure.check_workflows(self.root, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("local action path is not allowed", errors[0])

    def test_dependency_policy_rejects_decoys_aliases_and_symlinks(self) -> None:
        zon_path = self.root / "build.zig.zon"
        original = zon_path.read_text(encoding="utf-8")
        attacker = original.replace("https://github.com/ferrreo/sigbench", "https://evil.invalid")
        attacker = attacker.replace("sigbench-0.0.5-nAqBoO", "attacker-0.0.5-nAqBoO")
        attacker = attacker.replace(
            "        .sigbench = .{",
            "        // expected URL, hash, and .lazy = true are decoys\n"
            "        .sigbench = .{",
        )
        zon_path.write_text(attacker, encoding="utf-8")
        errors: list[str] = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("pin or lazy boundary" in error for error in errors))

        live = original.replace(".name = .ploof", ".name = .evil")
        live = live.replace("https://github.com/ferrreo/sigbench", "https://evil.invalid")
        with self.assertRaisesRegex(ReleaseError, "document is not canonical"):
            release.parse_zon("/*\n" + original + "*/\n" + live)

        zon_path.write_text(original, encoding="utf-8")
        self.write("src/ploof.zig", 'const dependency = @import("bench");\n')
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("production import is not local" in error for error in errors))
        self.write("src/ploof.zig", 'const dependency = @import("sig\\x62ench");\n')
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("production import is not local" in error for error in errors))

        self.write("benchmarks/benchmark.zig", 'const dependency = @import("sigbench");\n')
        self.write("src/ploof.zig", 'const helper = @import("../benchmarks/benchmark.zig");\n')
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("benchmark-only source" in error for error in errors))
        self.write("src/ploof.zig", "pub const version = \"fixture\";\n")

        self.write(
            "build.zig",
            'pub fn build(_: anytype) void {}\nconst alias = "sigbench";\n',
        )
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("wiring escapes benchmark-only graph" in error for error in errors))

        alias = fixture_build().replace('.name = "sigbench"', '.name = "application.zig"')
        self.write("build.zig", alias)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("module import table is not allowed" in error for error in errors))

        split = fixture_build().replace('"sigbench", .{', '"sig" ++ "bench", .{')
        self.write("build.zig", split)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("lazy dependency is not allowed" in error for error in errors))

        unguarded = fixture_build().replace(
            "if (benchmarks) addBenchmarkSteps(b);",
            "if (true) addBenchmarkSteps(b);",
        )
        self.write("build.zig", unguarded)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("benchmark activation guard changed" in error for error in errors))

        quoted = fixture_build().replace("b.lazyDependency", 'b.@"lazy\\x44ependency"')
        self.write("build.zig", quoted)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("dynamic module import is not allowed" in error for error in errors))
        self.write("build.zig", fixture_build())

        start = original.index("        .sigbench = .{")
        finish = original.index("    },\n    .paths")
        entry = original[start:finish]
        with self.assertRaisesRegex(ReleaseError, "duplicate dependency name"):
            release.parse_zon(original[:start] + entry + entry + original[finish:])

        (self.root / "src/hang.zig").symlink_to("/dev/zero")
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("source symlink is forbidden" in error for error in errors))

        policy = release.read_json(self.root / "release/dependencies.json")
        policy["build_only"] = [7]
        release.write_json(self.root / "release/dependencies.json", policy)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("unexpected shape" in error for error in errors))

    def test_dependency_scan_rejects_fifo_and_symlinked_source_root(self) -> None:
        fifo = self.root / "src/input.zig"
        os.mkfifo(fifo)
        errors: list[str] = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("source is not a regular file" in error for error in errors))
        fifo.unlink()

        source = self.root / "src"
        stored = self.root / "stored-src"
        source.rename(stored)
        source.symlink_to(stored, target_is_directory=True)
        errors = []
        release_structure.check_dependencies(self.root, errors)
        self.assertTrue(any("cannot open directory" in error for error in errors))

    def test_lightweight_tag_is_rejected(self) -> None:
        self.git("tag", "v0.1.1")
        with self.assertRaises(ReleaseError):
            release.verify_tag(self.root, "v0.1.1", "HEAD")

    def test_release_version_cannot_escape_output(self) -> None:
        zon = (self.root / "build.zig.zon").read_text(encoding="utf-8")
        self.write("build.zig.zon", zon.replace('"0.1.1"', '"../../escape"', 1))
        self.git("add", "build.zig.zon")
        subprocess.run(
            ["git", "commit", "-q", "-m", "invalid version"],
            cwd=self.root,
            check=True,
        )
        with self.assertRaises(ReleaseError):
            release.generate_release(
                self.root, "HEAD", self.root / "output", "zig", self.evidence,
            )
        self.assertFalse((self.root / "output").exists())

    def test_release_json_rejects_duplicates_and_nonfinite_numbers(self) -> None:
        for value in (
            '{"gate":"one","gate":"two"}',
            '{"value":NaN}',
            '{"value":Infinity}',
            '{"value":-Infinity}',
            '{"value":1e999}',
            '{"value":' + "1" * 5_000 + '}',
            '{"value":' + "[" * 2_000 + "0" + "]" * 2_000 + '}',
        ):
            with self.assertRaises(ReleaseError):
                parse_json(value, "fixture")

    def test_shell_fixtures(self) -> None:
        subprocess.run(["sh", str(ROOT / "tools/test-release-tools.sh")], check=True)


def fixture_build() -> str:
    return '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const benchmarks = b.option(bool, "benchmarks", "Enable lazy sigbench steps") orelse false;
    if (benchmarks) addBenchmarkSteps(b);
}
fn addBenchmarkSteps(b: *std.Build) void {
    const dependency = b.lazyDependency("sigbench", .{
        .target = b.graph.host,
    }) orelse return;
    _ = b.createModule(.{
        .root_source_file = b.path("benchmarks/benchmark.zig"),
        .imports = &.{.{ .name = "sigbench", .module = dependency.module("sigbench") }},
    });
}
'''


def fixture_zon() -> str:
    return """.{
    .name = .ploof,
    .version = \"0.1.1\",
    .fingerprint = 0x4b3f6071f0b0dd5a,
    .minimum_zig_version = \"0.16.0\",
    .dependencies = .{
        .sigbench = .{
            .url = "https://github.com/ferrreo/sigbench/archive/refs/tags/0.0.5.tar.gz",
            .hash = "sigbench-0.0.5-nAqBoOaRBQD-9MxV5v2pdn7wQwsmvZN8ggUVnC56b9Qh",
            .lazy = true,
        },
    },
    .paths = .{
        \"build.zig\",
        \"build\",
        \"build.zig.zon\",
        \"benchmark.zig\",
        \"compile_failure_api.zig\",
        \"fuzz.zig\",
        \"proxy_origin.zig\",
        \"test.zig\",
        \"tsan.zig\",
        \"benchmarks\",
        \"fuzz\",
        \"src\",
        \"tools\",
        \"tests\",
        \"docs\",
        \"release\",
        \"LICENSE\",
        \"README.md\",
        \"SECURITY.md\",
    },
}
"""


def fixture_dependencies() -> str:
    return (ROOT / "release/dependencies.json").read_text()


def fixture_matrix() -> str:
    value = {
        "schema_version": 1,
        "compiler": {"version": "0.16.0"},
        "production_target": {
            "architecture": "x86_64",
            "cpu_level": "x86-64-v3",
            "operating_system": "linux",
            "minimum_kernel_version": "6.1.0",
            "optimization": "ReleaseSafe",
            "libc": False,
            "liburing": False,
        },
        "cpu_features": [],
        "kernels": [{
            "id": "fixture-host",
            "minimum_version": "6.1.3",
            "cpu_vendor": "FixtureVendor",
        }],
        "proxies": external_matrix()["proxies"],
        "gate_hosts": {"mapped.gate": "fixture-host"},
        "protocol_support": release_notes.PROTOCOL_SUPPORT,
        "deployment_profiles": ["direct-http1", "caddy-http1", "nginx-http1"],
    }
    return json.dumps(value, sort_keys=True) + "\n"


def fixture_release_notes() -> str:
    return (ROOT / "release/release-notes.json").read_text(encoding="utf-8")


def fixture_gates() -> str:
    value = release.read_json(ROOT / "release/gates.json")
    value["gates"] = [
        {"id": "fixture.one", "lane": "fixture", "description": "one"},
        {"id": "fixture.two", "lane": "fixture", "description": "two"},
    ]
    return json.dumps(value, sort_keys=True) + "\n"


CANDIDATE = "a" * 40
BASELINE = "b" * 40
LOAD_DRIVER_BINARY = b"fixture load driver binary\n"


def external_gates() -> dict:
    return release.read_json(ROOT / "release/gates.json")


def external_dependencies() -> dict:
    return release.read_json(ROOT / "release/dependencies.json")


def external_matrix() -> dict:
    return release.read_json(ROOT / "release/support-matrix.json")


def verify_external_artifact(
    artifact: Path,
    gate_id: str,
    revision: str,
    gates: dict,
    dependencies: dict,
    report: dict | None = None,
    source_root: Path | None = None,
) -> dict:
    return _verify_external_artifact(
        artifact,
        gate_id,
        revision,
        gates,
        dependencies,
        external_matrix(),
        report,
        source_root,
    )


def valid_external_manifest(
    gate_id: str,
    candidate: str = CANDIDATE,
    gates: dict | None = None,
    dependencies: dict | None = None,
    source_root: Path = ROOT,
    source_revision: str | None = None,
) -> dict:
    selected = external_contract(gates or external_gates(), gate_id)
    assert selected is not None
    _, contract, _ = selected
    modes = list(contract["optimization_modes"])
    cases = contract["fuzz_budget"]["target_families"] if contract["fuzz_budget"] else [
        "fixture-case",
    ]
    manifest = {
        "schema_version": 1,
        "gate_id": gate_id,
        "candidate_revision": candidate,
        "baseline_revision": BASELINE if contract["baseline_required"] else None,
        "optimization_modes": modes,
        "cases_by_mode": {mode: list(cases) for mode in modes},
        "fuzz_budget": copy.deepcopy(contract["fuzz_budget"]),
        "soak": valid_soak(contract["soak_seconds"]),
        "hosts": valid_hosts(contract),
        "resource_plateau": valid_plateau(contract["resource_plateau_seconds"]),
        "topologies": list(contract["topologies"]),
        "workloads": list(contract["workloads"]),
        "sigbench": valid_sigbench(dependencies) if contract["sigbench"] else None,
        "load_driver": (
            valid_load_driver(source_root, source_revision)
            if contract["load_driver"] else None
        ),
        "proxy_images": valid_proxy_images(contract),
        "artifacts": valid_external_artifacts(contract["load_driver"]),
    }
    return manifest


def valid_hosts(contract: dict) -> list[dict]:
    hosts = []
    physical = set(contract["physical_host_roles"])
    cpu_flags = " ".join(
        feature["linux_flags"][0] for feature in external_matrix()["cpu_features"]
    )
    for index, role in enumerate(contract["host_roles"]):
        hosts.append({
            "role": role,
            "kind": "physical" if role in physical else "virtual",
            "machine_id_sha256": f"{index + 1:064x}",
            "inventory_id_sha256": f"{index + 101:064x}",
            "architecture": "x86_64",
            "operating_system": "linux",
            "kernel": "7.1.3",
            "cpu_vendor": "FixtureVendor",
            "cpu_model": "Fixture CPU",
            "cpu_flags": cpu_flags,
        })
    return hosts


def valid_proxy_images(contract: dict) -> list[dict]:
    proxies = {proxy["id"]: proxy for proxy in external_matrix()["proxies"]}
    records = []
    for proxy_id in contract["proxy_ids"]:
        proxy = proxies[proxy_id]
        records.append({
            "id": proxy_id,
            "version": proxy["version"],
            "repository": proxy["image"]["repository"],
            "tag": proxy["image"]["tag"],
            "digest": proxy["image"]["digest"],
        })
    return records


def valid_soak(seconds: int | None) -> dict | None:
    if seconds is None:
        return None
    start = datetime.datetime(2026, 7, 16, tzinfo=datetime.timezone.utc)
    finish = start + datetime.timedelta(seconds=seconds)
    return {
        "started_at": start.isoformat().replace("+00:00", "Z"),
        "finished_at": finish.isoformat().replace("+00:00", "Z"),
        "duration_seconds": seconds,
    }


def valid_plateau(seconds: int | None) -> dict | None:
    if seconds is None:
        return None
    return {
        "measurement_seconds": seconds,
        "samples": 25,
        "post_start_framework_allocations": 0,
        "descriptor_delta": 0,
        "rss_stable": True,
        "workspace_stable": True,
        "operation_stable": True,
    }


def valid_sigbench(dependencies: dict | None = None) -> dict:
    dependency = (dependencies or external_dependencies())["build_only"][0]
    return {
        "name": "sigbench",
        "version": dependency["version"],
        "source_sha256": dependency["sha256"],
        "zig_hash": dependency["zig_hash"],
    }


def valid_load_driver(root: Path, revision: str | None) -> dict:
    return {
        "name": "ploof-load-driver",
        "schema_version": 1,
        "source_sha256": load_driver_source_sha256(root, revision),
        "binary_path": "bin/ploof-load-driver",
        "binary_sha256": release.sha256_bytes(LOAD_DRIVER_BINARY),
    }


def valid_external_artifacts(load_driver: bool) -> list[dict]:
    records = [{
        "path": "raw/report.txt",
        "sha256": release.sha256_bytes(b"retained evidence\n"),
    }]
    if load_driver:
        records.append({
            "path": "bin/ploof-load-driver",
            "sha256": release.sha256_bytes(LOAD_DRIVER_BINARY),
        })
    return sorted(records, key=lambda record: record["path"])


def create_benchmark_evidence(root: Path, evidence: Path, revision: str) -> None:
    gates = release.read_json(root / "release/gates.json")
    dependencies = release.read_json(root / "release/dependencies.json")
    gate_hash = release.candidate_hash(root, revision, "release/gates.json")
    support_hash = release.candidate_hash(root, revision, "release/support-matrix.json")
    for gate_id, _ in release_notes.BENCHMARK_GATES:
        manifest = valid_external_manifest(
            gate_id, revision, gates, dependencies, root, revision,
        )
        tar_path = evidence / "artifacts" / gate_id / f"{gate_id}.tar"
        tar_path.parent.mkdir(parents=True, exist_ok=True)
        write_external_tar(tar_path, manifest)
        log_path = evidence / f"{gate_id}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("benchmark gate passed\n", encoding="utf-8")
        interval = external_report(manifest, 1)
        runner = interval["runner"]
        runner.update({
            "name": "fixture",
            "microcode": "fixture",
            "zig": "0.16.0",
        })
        report = {
            "schema_version": 1,
            "gate_id": gate_id,
            "revision": revision,
            "result": "pass",
            "started_at": interval["started_at"],
            "finished_at": interval["finished_at"],
            "command": ["fixture-benchmark"],
            "runner": runner,
            "gate_manifest_sha256": gate_hash,
            "support_matrix_sha256": support_hash,
            "artifacts": [
                {"path": log_path.name, "sha256": release.sha256_file(log_path)},
                {
                    "path": tar_path.relative_to(evidence).as_posix(),
                    "sha256": release.sha256_file(tar_path),
                },
            ],
        }
        release.write_json(evidence / f"{gate_id}.json", report)


def external_report(manifest: dict, seconds: int) -> dict:
    start = datetime.datetime(2026, 7, 16, tzinfo=datetime.timezone.utc)
    runner = dict(manifest["hosts"][0])
    runner.pop("role")
    runner.pop("kind")
    runner.pop("inventory_id_sha256")
    runner.pop("operating_system")
    return {
        "started_at": start.isoformat().replace("+00:00", "Z"),
        "finished_at": (
            start + datetime.timedelta(seconds=seconds)
        ).isoformat().replace("+00:00", "Z"),
        "runner": runner,
    }


def write_external_tar(
    path: Path,
    manifest: dict | None,
    raw: bytes = b"retained evidence\n",
    mode: str = "w",
    binary: bytes = LOAD_DRIVER_BINARY,
    raw_path: str = "raw/report.txt",
) -> None:
    with tarfile.open(path, mode) as archive:
        if manifest is not None:
            contents = (json.dumps(manifest, sort_keys=True) + "\n").encode()
            info = tarfile.TarInfo("external-evidence-manifest.json")
            info.size = len(contents)
            archive.addfile(info, io.BytesIO(contents))
        if manifest is not None and manifest.get("load_driver") is not None:
            info = tarfile.TarInfo("bin/ploof-load-driver")
            info.mode = 0o755
            info.size = len(binary)
            archive.addfile(info, io.BytesIO(binary))
        info = tarfile.TarInfo(raw_path)
        info.size = len(raw)
        archive.addfile(info, io.BytesIO(raw))


def rewrite_source_tar(path: Path, mutation: str, epoch: int) -> None:
    with tarfile.open(path, "r:") as archive:
        entries = []
        for member in archive.getmembers():
            source = archive.extractfile(member)
            assert source is not None
            entries.append((copy.copy(member), source.read()))
    if mutation == "bytes":
        member, contents = entries[0]
        contents += b"tampered\n"
        member.size = len(contents)
        entries[0] = (member, contents)
    elif mutation == "remove":
        entries.pop()
    elif mutation == "insert":
        member = tarfile.TarInfo("ploof-0.1.1/zz-injected")
        contents = b"injected\n"
        member.size = len(contents)
        member.mode = 0o644
        member.mtime = epoch
        member.uid = 0
        member.gid = 0
        member.uname = "root"
        member.gname = "root"
        entries.append((member, contents))
    temporary = path.with_suffix(".tampered")
    with tarfile.open(temporary, "w", format=tarfile.USTAR_FORMAT) as archive:
        for member, contents in entries:
            archive.addfile(member, io.BytesIO(contents))
    temporary.replace(path)


def rehash_manifest_artifact(manifest_path: Path, artifact_path: Path) -> None:
    manifest = release.read_json(manifest_path)
    record = next(
        item for item in manifest["artifacts"] if item["path"] == artifact_path.name
    )
    record["sha256"] = release.sha256_file(artifact_path)
    release.write_json(manifest_path, manifest)


def rebind_tampered_archive(root: Path, manifest_path: Path) -> None:
    manifest = release.read_json(manifest_path)
    directory = manifest_path.parent
    base = f"ploof-{manifest['version']}"
    archive = directory / f"{base}.tar"
    archive_hash = release.sha256_file(archive)
    checksum = directory / f"{base}.sha256"
    checksum.write_text(f"{archive_hash}  {archive.name}\n", encoding="ascii")
    dependencies = release.git_json(
        root, manifest["revision"], "release/dependencies.json",
    )
    zon = release.candidate_zon(root, manifest["revision"])
    spdx = directory / f"{base}.spdx.json"
    release.write_json(spdx, release.spdx_document(
        manifest["version"], manifest["revision"], archive.name, archive_hash,
        manifest["source_date_epoch"], dependencies,
    ))
    provenance = directory / f"{base}.provenance.json"
    release.write_json(provenance, release.provenance_document(
        manifest["revision"], archive.name, archive_hash,
        manifest["source_date_epoch"], zon["paths"],
    ))
    for path in (archive, checksum, spdx, provenance):
        record = next(item for item in manifest["artifacts"] if item["path"] == path.name)
        record["sha256"] = release.sha256_file(path)
    release.write_json(manifest_path, manifest)


if __name__ == "__main__":
    unittest.main()
