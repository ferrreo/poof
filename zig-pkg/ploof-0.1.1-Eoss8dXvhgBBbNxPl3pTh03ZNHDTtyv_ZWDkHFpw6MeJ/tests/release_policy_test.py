#!/usr/bin/env python3

from __future__ import annotations

import copy
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from release_artifact_check import validate_dependency_policy
from release_common import ReleaseError, read_json
from release_environment import require_kernel_minimum
from release_structure import check_gates, check_matrix, check_proxy_script
from release_structure_profiles import EXPECTED_ARTIFACT_POLICY


class ReleasePolicyTest(unittest.TestCase):
    def test_sigbench_identity_is_one_exact_tuple(self) -> None:
        policy = read_json(ROOT / "release/dependencies.json")
        validate_dependency_policy(policy)
        mutations = {
            "url": "https://evil.example/sigbench.tar.gz",
            "zig_hash": "sigbench-0.0.5-" + "x" * 48,
            "sha256": "0" * 64,
        }
        for field, value in mutations.items():
            with self.subTest(field=field):
                invalid = copy.deepcopy(policy)
                invalid["build_only"][0][field] = value
                with self.assertRaises(ReleaseError):
                    validate_dependency_policy(invalid)

    def test_current_kernel_case_is_a_minimum_not_an_exact_release(self) -> None:
        require_kernel_minimum("7.1.3", "7.1.3", "fixture")
        require_kernel_minimum("7.1.3-pikaos", "7.1.3", "fixture")
        require_kernel_minimum("7.2.0-custom", "7.1.3", "fixture")
        with self.assertRaises(ReleaseError):
            require_kernel_minimum("7.1.2", "7.1.3", "fixture")

        matrix = read_json(ROOT / "release/support-matrix.json")
        errors: list[str] = []
        check_matrix(matrix, errors)
        self.assertEqual([], errors)

        invalid = copy.deepcopy(matrix)
        for case in invalid["kernels"]:
            if case["series"] == "7.1":
                case["minimum_version"] = "7.1.0"
                case["runner_labels"] = [
                    "self-hosted",
                    "linux",
                    "x64",
                    "ploof-trusted",
                    "kernel-min-7.1.0",
                    "intel" if case["cpu_vendor"] == "GenuineIntel" else "amd",
                ]
        invalid["release_soaks"][1]["minimum_version"] = "7.1.0"
        errors = []
        check_matrix(invalid, errors)
        self.assertIn("release/support-matrix.json: kernel minimum policy changed", errors)

    def test_proxy_script_uses_support_matrix_image_pins(self) -> None:
        matrix = read_json(ROOT / "release/support-matrix.json")
        with tempfile.TemporaryDirectory(prefix="ploof-proxy-policy-") as directory:
            root = Path(directory)
            script = root / "tools/test-proxy-interop.sh"
            script.parent.mkdir(parents=True)
            source = (ROOT / "tools/test-proxy-interop.sh").read_text(encoding="utf-8")
            script.write_text(source, encoding="utf-8")
            errors: list[str] = []
            check_proxy_script(root, matrix, errors)
            self.assertEqual([], errors)

            script.write_text(source.replace("2.11.4", "2.11.3", 1), encoding="utf-8")
            check_proxy_script(root, matrix, errors)
            self.assertIn(
                "tools/test-proxy-interop.sh: proxy images do not match support matrix",
                errors,
            )

            script.write_text(
                source.replace('"$CADDY_IMAGE" >/dev/null', '"attacker:latest" >/dev/null', 1),
                encoding="utf-8",
            )
            errors = []
            check_proxy_script(root, matrix, errors)
            self.assertIn(
                "tools/test-proxy-interop.sh: canonical proxy execution changed",
                errors,
            )

    def test_release_numeric_policies_require_exact_integer_types(self) -> None:
        matrix = read_json(ROOT / "release/support-matrix.json")
        gates = read_json(ROOT / "release/gates.json")
        for value in (True, 2.0):
            with self.subTest(artifact_value=value):
                invalid = copy.deepcopy(gates)
                invalid["artifact_policy"]["minimum_by_prefix"]["scheduled."] = value
                errors: list[str] = []
                check_gates(matrix, invalid, errors)
                self.assertIn("release/gates.json: exact artifact policy changed", errors)

        invalid = copy.deepcopy(matrix)
        invalid["release_soaks"][0]["duration_seconds"] = 86_400.0
        errors = []
        check_matrix(invalid, errors)
        self.assertIn(
            "release/support-matrix.json: minimum-threshold soaks are required",
            errors,
        )
        self.assertEqual(8, EXPECTED_ARTIFACT_POLICY["minimum_by_gate"]["release.archive"])
        self.assertEqual(
            3,
            EXPECTED_ARTIFACT_POLICY["minimum_by_gate"]["release.provenance"],
        )


if __name__ == "__main__":
    unittest.main()
