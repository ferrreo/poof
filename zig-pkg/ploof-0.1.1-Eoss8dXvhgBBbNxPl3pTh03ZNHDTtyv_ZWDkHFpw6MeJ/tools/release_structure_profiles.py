"""Exact external release-profile policy."""

from __future__ import annotations


APPLICATION_WORKLOADS = [
    "fixed-response",
    "typed-json",
    "html-template",
    "identity-body",
    "gzip-body",
    "multipart-discard",
    "multipart-file",
    "embedded-static",
    "live-static",
    "finite-response",
    "streaming-response",
    "trusted-proxy",
]
RELEASE_MODES = ["ReleaseSafe", "ReleaseFast"]
ALL_MODES = ["Debug", "ReleaseSafe", "ReleaseFast"]
EXPECTED_FUZZ_FAMILIES = [
    "http1",
    "multipart",
    "csrf",
    "html",
    "upload",
    "upload-worker",
    "routing",
    "url",
    "static",
    "assets",
    "observability",
    "runtime",
    "stream-wake",
    "stream-lifecycle",
    "stream-response",
    "stream-driver",
]
EXPECTED_ARTIFACT_POLICY = {
    "default_minimum": 1,
    "minimum_by_prefix": {"scheduled.": 2},
    "minimum_by_gate": {
        "trusted.sigbench-regression": 2,
        "release.fuzz-budget": 2,
        "release.soak-floor": 2,
        "release.soak-current": 2,
        "release.archive": 8,
        "release.documentation": 2,
        "release.provenance": 3,
    },
}
EXPECTED_CONTRACTS = {
    "trusted.sigbench-regression": "sigbench-regression",
    "scheduled.kernel-linux-6.1-intel": "kernel-suite",
    "scheduled.kernel-linux-6.1-amd": "kernel-suite",
    "scheduled.kernel-linux-6.6-intel": "kernel-suite",
    "scheduled.kernel-linux-6.12-amd": "kernel-suite",
    "scheduled.kernel-linux-6.18-intel": "kernel-suite",
    "scheduled.kernel-linux-7.1-intel": "kernel-suite",
    "scheduled.kernel-linux-7.1-amd": "kernel-suite",
    "scheduled.security-fuzz": "security-fuzz",
    "scheduled.resource-plateau": "resource-plateau",
    "scheduled.runtime-benchmarks": "runtime-benchmarks",
    "scheduled.deployment-direct": "deployment-direct",
    "scheduled.deployment-caddy": "deployment-caddy",
    "scheduled.deployment-nginx": "deployment-nginx",
    "release.fuzz-budget": "release-fuzz",
    "release.soak-floor": "release-soak",
    "release.soak-current": "release-soak",
}


def profile(**changes: object) -> dict:
    value = {
        "baseline_required": False,
        "optimization_modes": ["ReleaseSafe"],
        "case_parity": False,
        "fuzz_budget": None,
        "soak_seconds": None,
        "host_roles": [],
        "physical_host_roles": [],
        "distinct_host_roles": [],
        "resource_plateau_seconds": None,
        "topologies": [],
        "proxy_ids": [],
        "workloads": [],
        "sigbench": False,
        "load_driver": False,
    }
    value.update(changes)
    return value


def fuzz_budget(
    families: list[str],
    processes: int,
    generated_cases: int,
) -> dict:
    return {
        "target_families": families,
        "processes_per_target": processes,
        "generated_cases_per_process": generated_cases,
        "timeout_seconds_per_process": 3_600,
    }


def expected_profiles(families: list[str]) -> dict[str, dict]:
    values = {
        "kernel-suite": profile(
            optimization_modes=ALL_MODES,
            case_parity=True,
            host_roles=["runner"],
            topologies=["loopback-io-uring"],
            workloads=[
                "correctness-suite",
                "real-io-suite",
                "security-corpus",
                "allocation-traps",
                "lifecycle-drain",
            ],
        ),
        "security-fuzz": profile(
            optimization_modes=ALL_MODES,
            case_parity=True,
            fuzz_budget=fuzz_budget(families, 8, 250_000),
            host_roles=["runner"],
            topologies=["direct-http1", "caddy-http1", "nginx-http1"],
            proxy_ids=["caddy", "nginx"],
            workloads=["security-corpus", "request-smuggling-canaries", "proxy-canaries"],
        ),
        "resource-plateau": profile(
            host_roles=["server"],
            resource_plateau_seconds=3_600,
            topologies=["direct-http1"],
            workloads=["connection-churn", "saturation", "drain"],
            load_driver=True,
        ),
        "release-fuzz": profile(
            optimization_modes=ALL_MODES,
            case_parity=True,
            fuzz_budget=fuzz_budget(families, 4, 250_000),
            host_roles=["runner"],
            topologies=["in-process"],
            workloads=["fuzz-matrix"],
        ),
        "release-soak": profile(
            soak_seconds=86_400,
            host_roles=["server"],
            resource_plateau_seconds=86_400,
            topologies=["direct-http1"],
            workloads=APPLICATION_WORKLOADS,
            load_driver=True,
        ),
    }
    values.update(expected_performance_profiles())
    return values


def expected_performance_profiles() -> dict[str, dict]:
    values = {
        "sigbench-regression": profile(
            baseline_required=True,
            optimization_modes=RELEASE_MODES,
            case_parity=True,
            host_roles=["benchmark"],
            physical_host_roles=["benchmark"],
            topologies=["in-process"],
            workloads=["microbenchmarks"],
            sigbench=True,
        ),
        "runtime-benchmarks": profile(
            baseline_required=True,
            optimization_modes=RELEASE_MODES,
            case_parity=True,
            host_roles=["benchmark"],
            physical_host_roles=["benchmark"],
            topologies=["in-process", "loopback-io-uring"],
            workloads=APPLICATION_WORKLOADS,
            sigbench=True,
            load_driver=True,
        ),
    }
    for name, topology, proxy_ids in (
        ("deployment-direct", "direct-http1", []),
        ("deployment-caddy", "caddy-http1", ["caddy"]),
        ("deployment-nginx", "nginx-http1", ["nginx"]),
    ):
        values[name] = profile(
            baseline_required=True,
            optimization_modes=RELEASE_MODES,
            case_parity=True,
            host_roles=["client", "server"],
            physical_host_roles=["client", "server"],
            distinct_host_roles=["client", "server"],
            topologies=[topology],
            proxy_ids=proxy_ids,
            workloads=APPLICATION_WORKLOADS,
            load_driver=True,
        )
    return values


def check_profiles(profiles: dict, families: list[str], errors: list[str]) -> None:
    expected = expected_profiles(families)
    if profiles != expected:
        mismatched = sorted(
            name for name in set(profiles) | set(expected)
            if profiles.get(name) != expected.get(name)
        )
        errors.append(f"release/gates.json: exact profiles changed: {mismatched}")
