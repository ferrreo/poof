#!/usr/bin/env python3

from __future__ import annotations

import copy
import re
import sys
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from release_common import ReleaseError
from release_structure_io import WORKFLOW_USES_RE
import workflow_run


REVISION = "a" * 40
REPOSITORY = "ferrreo/ploof"
WORKFLOW = ".github/workflows/trusted.yml"
WORKFLOW_ROOT = ROOT / ".github/workflows"


def valid_run() -> dict:
    return {
        "id": 123,
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "head_sha": REVISION,
        "event": "workflow_dispatch",
        "path": f"{WORKFLOW}@main",
        "repository": {"full_name": REPOSITORY},
        "head_repository": {"full_name": REPOSITORY},
    }


def workflow_permissions(source: str) -> dict[str, str]:
    match = re.search(r"^permissions:\n((?:  [^\n]+\n)+)", source, re.MULTILINE)
    if match is None:
        return {}
    return dict(
        line.strip().split(": ", 1)
        for line in match.group(1).splitlines()
    )


class WorkflowRunTest(unittest.TestCase):
    def validate(self, document: dict) -> None:
        workflow_run.validate_run(
            document,
            REPOSITORY,
            REVISION,
            123,
            {WORKFLOW: {"workflow_dispatch"}},
        )

    def test_accepts_exact_successful_candidate_run(self) -> None:
        self.validate(valid_run())

    def test_rejects_wrong_identity_and_state(self) -> None:
        mutations = (
            ("id", 124),
            ("id", True),
            ("run_attempt", 2),
            ("run_attempt", True),
            ("status", "in_progress"),
            ("conclusion", "failure"),
            ("head_sha", "b" * 40),
            ("event", "pull_request_target"),
            ("path", f"{WORKFLOW}.evil@main"),
        )
        for field, value in mutations:
            with self.subTest(field=field, value=value):
                document = valid_run()
                document[field] = value
                with self.assertRaises(ReleaseError):
                    self.validate(document)

    def test_rejects_source_or_head_repository_mismatch(self) -> None:
        for field in ("repository", "head_repository"):
            with self.subTest(field=field):
                document = copy.deepcopy(valid_run())
                document[field]["full_name"] = "attacker/ploof"
                with self.assertRaises(ReleaseError):
                    self.validate(document)

    def test_rejects_missing_or_malformed_repository_objects(self) -> None:
        for value in (None, "ferrreo/ploof", {}):
            with self.subTest(value=value):
                document = valid_run()
                document["head_repository"] = value
                with self.assertRaises(ReleaseError):
                    self.validate(document)

        with self.assertRaises(ReleaseError):
            self.validate([])  # type: ignore[arg-type]

    def test_rejects_disallowed_workflow_event_cross_product(self) -> None:
        document = valid_run()
        document["event"] = "schedule"
        policy = {
            WORKFLOW: {"workflow_dispatch"},
            ".github/workflows/scheduled.yml": {"schedule"},
        }
        with self.assertRaises(ReleaseError):
            workflow_run.validate_run(document, REPOSITORY, REVISION, 123, policy)

    def test_source_policy_rejects_duplicates_and_malformed_pairs(self) -> None:
        valid = workflow_run.parse_sources([
            f"{WORKFLOW}=workflow_dispatch",
            ".github/workflows/scheduled.yml=schedule",
        ])
        self.assertEqual({"workflow_dispatch"}, valid[WORKFLOW])
        for values in (
            [f"{WORKFLOW}=workflow_dispatch", f"{WORKFLOW}=workflow_dispatch"],
            [WORKFLOW],
            [f"../trusted.yml=workflow_dispatch"],
            [f"{WORKFLOW}=PullRequest"],
        ):
            with self.subTest(values=values), self.assertRaises(ReleaseError):
                workflow_run.parse_sources(values)

    def test_revision_policy_accepts_only_full_git_object_formats(self) -> None:
        self.assertIsNotNone(workflow_run.REVISION_RE.fullmatch("a" * 40))
        self.assertIsNotNone(workflow_run.REVISION_RE.fullmatch("b" * 64))
        for value in ("a" * 39, "a" * 41, "A" * 40, "refs/heads/main"):
            with self.subTest(value=value):
                self.assertIsNone(workflow_run.REVISION_RE.fullmatch(value))

    def test_evidence_workflow_authenticates_before_and_after_download(self) -> None:
        source = (ROOT / ".github/workflows/evidence.yml").read_text(encoding="utf-8")
        fetch = source.index("Fetch evidence run metadata")
        authenticate = source.index("Authenticate evidence run provenance")
        download = source.index("Download authenticated evidence runs")
        reauthenticate = source.index("Re-authenticate evidence runs after download")
        merge = source.index("Merge and validate pre-release evidence")
        self.assertLess(fetch, authenticate)
        self.assertLess(authenticate, download)
        self.assertLess(download, reauthenticate)
        self.assertLess(reauthenticate, merge)
        self.assertLess(source.index('gh run download "$run_id"'), source.index(
            "$run_id.post-download.json",
        ))
        self.assertLess(source.index("$run_id.post-download.json"), reauthenticate)
        self.assertIn("--source .github/workflows/untrusted.yml=push", source)
        self.assertIn(
            "--source .github/workflows/trusted.yml=workflow_dispatch", source,
        )
        self.assertIn("--source .github/workflows/scheduled.yml=schedule", source)
        self.assertNotIn("untrusted.yml=pull_request", source)
        self.assertIn('duplicate run ID: $run_id', source)
        self.assertIn('test "$#" -eq 3', source)
        self.assertIn("duplicate source workflow", source)
        self.assertIn("GH_TOKEN: ${{ github.token }}", source)
        self.assertIn("env -u GH_TOKEN -u GITHUB_TOKEN python3", source)
        authenticate_step = source[authenticate:download]
        self.assertNotIn("GH_TOKEN: ${{ github.token }}", authenticate_step)
        reauthenticate_step = source[reauthenticate:merge]
        self.assertNotIn("GH_TOKEN: ${{ github.token }}", reauthenticate_step)
        self.assertIn('--name "$artifact"', source)
        self.assertIn("untrusted-evidence-$CANDIDATE_REVISION", source)
        self.assertIn("trusted.real-io-floor-$CANDIDATE_REVISION", source)
        self.assertIn("scheduled-linux-7.1-amd-$run_id", source)
        self.assertIn("release.soak-current-$run_id", source)
        self.assertIn("test ! -e zig-out/incoming", source)
        self.assertIn("$run_id.post-download.json", source)
        self.assertIn('test "$workflow" = "$expected_workflow"', source)

    def test_evidence_downloads_only_exact_artifact_contract(self) -> None:
        source = (ROOT / ".github/workflows/evidence.yml").read_text(encoding="utf-8")
        expected = {
            "untrusted-evidence-$CANDIDATE_REVISION",
            "trusted.real-io-floor-$CANDIDATE_REVISION",
            "trusted.real-io-current-$CANDIDATE_REVISION",
            "trusted-proxy-tsan-$CANDIDATE_REVISION",
            "trusted-performance-$CANDIDATE_REVISION",
            "scheduled-linux-6.1-intel-$run_id",
            "scheduled-linux-6.1-amd-$run_id",
            "scheduled-linux-6.6-intel-$run_id",
            "scheduled-linux-6.12-amd-$run_id",
            "scheduled-linux-6.18-intel-$run_id",
            "scheduled-linux-7.1-intel-$run_id",
            "scheduled-linux-7.1-amd-$run_id",
            "scheduled.security-fuzz-$run_id",
            "scheduled.resource-plateau-$run_id",
            "scheduled.runtime-benchmarks-$run_id",
            "scheduled.deployment-direct-$run_id",
            "scheduled.deployment-caddy-$run_id",
            "scheduled.deployment-nginx-$run_id",
            "release.fuzz-budget-$run_id",
            "release.soak-floor-$run_id",
            "release.soak-current-$run_id",
        }
        pattern = r"[A-Za-z0-9.]+(?:-[A-Za-z0-9.]+)*-(?:\$CANDIDATE_REVISION|\$run_id)"
        self.assertEqual(expected, set(re.findall(pattern, source)))
        self.assertEqual(1, source.count("gh run download"))
        self.assertEqual(1, source.count('--name "$artifact"'))

    def test_token_steps_do_not_invoke_candidate_python(self) -> None:
        for name in ("evidence.yml", "release.yml"):
            source = (WORKFLOW_ROOT / name).read_text(encoding="utf-8")
            token_steps = [
                step for step in source.split("\n      - ")
                if "GH_TOKEN: ${{ github.token }}" in step
            ]
            self.assertTrue(token_steps, name)
            for step in token_steps:
                with self.subTest(workflow=name):
                    self.assertNotIn("python3 tools/", step)

    def test_every_external_action_is_commit_pinned(self) -> None:
        workflows = sorted(
            path for path in WORKFLOW_ROOT.iterdir() if path.suffix in {".yml", ".yaml"}
        )
        for path in workflows:
            source = path.read_text(encoding="utf-8")
            self.assertIn("\npermissions:\n", source, path.name)
            self.assertNotIn("write-all", source, path.name)
            actions = []
            for line in source.splitlines():
                match = WORKFLOW_USES_RE.fullmatch(line)
                if match is not None:
                    actions.append(next(group for group in match.groups() if group is not None))
            self.assertTrue(actions, path.name)
            for action in actions:
                with self.subTest(workflow=path.name, action=action):
                    if action.startswith("./"):
                        continue
                    revision = action.rsplit("@", 1)[-1]
                    self.assertRegex(revision, r"^[0-9a-f]{40}$")

    def test_workflow_tokens_have_exact_minimum_permissions(self) -> None:
        expected = {
            "untrusted.yml": {"contents": "read"},
            "trusted.yml": {"contents": "read"},
            "scheduled.yml": {"contents": "read"},
            "evidence.yml": {"actions": "read", "contents": "read"},
            "release.yml": {"actions": "read", "contents": "read"},
        }
        for name, permissions in expected.items():
            source = (WORKFLOW_ROOT / name).read_text(encoding="utf-8")
            with self.subTest(workflow=name):
                self.assertEqual(permissions, workflow_permissions(source))

    def test_untrusted_pull_requests_never_use_protected_runners(self) -> None:
        source = (WORKFLOW_ROOT / "untrusted.yml").read_text(encoding="utf-8")
        self.assertIn("pull_request:", source)
        self.assertIn("runs-on: ubuntu-24.04", source)
        self.assertNotIn("self-hosted", source)
        self.assertNotIn("environment:", source)
        self.assertNotIn("secrets.", source)

    def test_untrusted_uses_bounded_hosted_runner_gates(self) -> None:
        source = (WORKFLOW_ROOT / "untrusted.yml").read_text(encoding="utf-8")
        self.assertIn("    timeout-minutes: 30\n", source)
        self.assertIn("-- zig build test-untrusted\n", source)
        self.assertIn("-- zig build test-fuzz-driver fuzz-http1\n", source)
        self.assertIn("-Dfuzz-runs=10000 -Dfuzz-timeout-seconds=600\n", source)
        self.assertNotIn("-- zig build test\n", source)
        self.assertNotIn("run-fuzz-matrix.sh", source)
        self.assertEqual(source.count("name: untrusted-evidence-${{ github.sha }}"), 1)

    def test_protected_workflows_authenticate_checkout_before_candidate_tools(self) -> None:
        for name in ("trusted.yml", "scheduled.yml", "evidence.yml"):
            source = (WORKFLOW_ROOT / name).read_text(encoding="utf-8")
            checkouts = source.count("uses: actions/checkout@")
            checks = source.count("Authenticate exact candidate before candidate tools")
            environments = source.count("environment:")
            runners = len(re.findall(r"^\s*runs-on:.*$", source, re.MULTILINE))
            with self.subTest(workflow=name):
                self.assertEqual(checkouts, checks)
                self.assertEqual(runners, environments)
                self.assertIn("persist-credentials: false", source)
                self.assertIn("git rev-parse --verify 'HEAD^{commit}'", source)

    def test_release_authenticates_tag_and_evidence_before_and_after_download(self) -> None:
        source = (WORKFLOW_ROOT / "release.yml").read_text(encoding="utf-8")
        tag = source.index("Authenticate signed tag before candidate tools")
        install = source.index("Install exact Zig")
        fetch = source.index("Fetch evidence workflow metadata")
        run = source.index("Authenticate evidence workflow run")
        download = source.index("Download exact-candidate evidence")
        refetch = source.index("Refetch evidence workflow metadata after download")
        rerun = source.index("Re-authenticate evidence workflow run after download")
        signed_tag = source.index("Verify signed tag")
        self.assertLess(tag, install)
        self.assertLess(fetch, run)
        self.assertLess(run, download)
        self.assertLess(download, refetch)
        self.assertLess(refetch, rerun)
        self.assertLess(rerun, signed_tag)
        self.assertIn("GH_TOKEN: ${{ github.token }}", source[refetch:rerun])
        self.assertNotIn("GH_TOKEN: ${{ github.token }}", source[rerun:signed_tag])
        self.assertIn("git verify-tag", source)
        self.assertEqual(2, source.count('test "$GITHUB_REF" = "refs/tags/$RELEASE_TAG"'))
        self.assertEqual(2, source.count('test "$GITHUB_SHA" = "$tag_revision"'))
        self.assertIn("--source .github/workflows/evidence.yml=workflow_dispatch", source)
        self.assertEqual(2, source.count("--source "))
        self.assertIn("env -u GH_TOKEN -u GITHUB_TOKEN python3", source)
        self.assertIn("name: candidate-evidence", source)
        self.assertIn("run-id: ${{ inputs.evidence_run_id }}", source)
        self.assertIn("repository: ${{ github.repository }}", source)
        self.assertIn("test ! -e zig-out/evidence", source)
        self.assertIn("evidence-run.post-download.json", source)

    def test_release_limits_oidc_to_action_only_attestation_job(self) -> None:
        source = (WORKFLOW_ROOT / "release.yml").read_text(encoding="utf-8")
        build, remainder = source.split("\n  attest:", 1)
        attest, finalize = remainder.split("\n  finalize:", 1)
        self.assertIn("\n  build:", build)
        self.assertIn("needs: build", attest)
        self.assertIn("needs: [build, attest]", finalize)
        self.assertNotIn("id-token: write", build)
        self.assertNotIn("attestations: write", build)
        self.assertNotIn("id-token: write", finalize)
        self.assertNotIn("attestations: write", finalize)
        self.assertEqual(1, attest.count("id-token: write"))
        self.assertEqual(1, attest.count("attestations: write"))
        self.assertIn("runs-on: ubuntu-24.04", attest)
        self.assertEqual(3, source.count("environment: release"))
        self.assertNotIn("run:", attest)
        self.assertNotIn("tools/", attest)
        self.assertNotIn("actions/checkout@", attest)

    def test_release_binds_cross_job_artifacts_and_verifies_bundle(self) -> None:
        source = (WORKFLOW_ROOT / "release.yml").read_text(encoding="utf-8")
        self.assertEqual(
            2,
            source.count("artifact-ids: ${{ needs.build.outputs.artifact_id }}"),
        )
        self.assertEqual(
            1,
            source.count("artifact-ids: ${{ needs.attest.outputs.artifact_id }}"),
        )
        self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", source)
        verify_release = source.rindex("Verify downloaded release")
        verify_bundle = source.index("Verify GitHub attestation")
        final_upload = source.index("Retain candidate release")
        self.assertLess(verify_release, verify_bundle)
        self.assertLess(verify_bundle, final_upload)
        for argument in (
            '--repo "$GITHUB_REPOSITORY"',
            '--bundle "$bundle"',
            '--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/release.yml"',
            '--source-digest "$candidate"',
            '--source-ref "refs/tags/$RELEASE_TAG"',
            "--deny-self-hosted-runners",
        ):
            self.assertIn(argument, source)
        attest_step = source[verify_bundle:source.index("Retain provenance verification")]
        self.assertIn("GH_TOKEN: ${{ github.token }}", attest_step)
        self.assertNotIn("python3 tools/", attest_step)
        record_step = source[source.index("Retain provenance verification"):]
        self.assertNotIn("GH_TOKEN: ${{ github.token }}", record_step)
        self.assertIn("env -u GH_TOKEN -u GITHUB_TOKEN python3", record_step)


if __name__ == "__main__":
    unittest.main()
