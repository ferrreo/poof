#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

for script in \
    "$root/tools/check-compile-failure.sh" \
    "$root/tools/check-release-tooling.sh" \
    "$root/tools/check-package.sh" \
    "$root/tools/install-zig.sh" \
    "$root/tools/run-external-gate.sh" \
    "$root/tools/run-fuzz-matrix.sh"
do
    sh -n "$script"
done

cat > "$temporary/compiler-fail" <<'EOF'
#!/bin/sh
printf '%s\n' 'fixture: error: expected diagnostic with detail' >&2
exit 1
EOF
chmod +x "$temporary/compiler-fail"
sh "$root/tools/check-compile-failure.sh" \
    'expected diagnostic' "$temporary/compiler-fail"
if sh "$root/tools/check-compile-failure.sh" \
        'missing diagnostic' "$temporary/compiler-fail" 2>/dev/null; then
    echo "release shell test: missing compile diagnostic passed" >&2
    exit 1
fi
if sh "$root/tools/check-compile-failure.sh" \
        'expected diagnostic' /bin/true 2>/dev/null; then
    echo "release shell test: successful compilation passed failure check" >&2
    exit 1
fi

mkdir "$temporary/bin"
log=$temporary/zig.log
cat > "$temporary/bin/zig" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PLOOF_TEST_ZIG_LOG"
EOF
chmod +x "$temporary/bin/zig"
PATH=$temporary/bin:$PATH PLOOF_TEST_ZIG_LOG=$log \
    "$root/tools/run-fuzz-matrix.sh" 7
if [ "$(wc -l < "$log")" -ne 48 ]; then
    echo "release shell test: fuzz matrix did not run 48 campaigns" >&2
    exit 1
fi
if grep -v -- '-Dfuzz-runs=7 -Dfuzz-timeout-seconds=3600$' "$log" >/dev/null; then
    echo "release shell test: fuzz matrix changed fixed work or timeout" >&2
    exit 1
fi
fuzz_families='http1 multipart csrf html upload upload-worker routing url static assets
observability runtime stream-wake stream-lifecycle stream-response stream-driver'
for family in $fuzz_families; do
    for suffix in '' -release-safe -release-fast; do
        command="build fuzz-$family$suffix -Dfuzz-runs=7 -Dfuzz-timeout-seconds=3600"
        if [ "$(grep -Fxc -- "$command" "$log")" -ne 1 ]; then
            echo "release shell test: missing or duplicate fuzz command: $command" >&2
            exit 1
        fi
    done
done
if "$root/tools/run-fuzz-matrix.sh" 7 extra 2>/dev/null; then
    echo "release shell test: fuzz matrix accepted an extra argument" >&2
    exit 1
fi

if "$root/tools/run-external-gate.sh" fixture.gate 2>/dev/null; then
    echo "release shell test: missing external command passed" >&2
    exit 1
fi
PLOOF_FIXTURE_GATE_COMMAND='printf passed' \
    "$root/tools/run-external-gate.sh" fixture.gate > "$temporary/external.out"
if [ "$(cat "$temporary/external.out")" != passed ]; then
    echo "release shell test: external command was not executed" >&2
    exit 1
fi

dangling=$temporary/dangling.tar
dangling_victim=$temporary/dangling-victim
ln -s "$dangling_victim" "$dangling"
if PLOOF_FIXTURE_GATE_COMMAND='printf overwritten > "$PLOOF_GATE_ARTIFACT"' \
        "$root/tools/run-external-gate.sh" fixture.gate "$dangling" 2>/dev/null; then
    echo "release shell test: dangling evidence symlink passed" >&2
    exit 1
fi
if [ -e "$dangling_victim" ]; then
    echo "release shell test: dangling evidence symlink overwrote its target" >&2
    exit 1
fi

mkdir "$temporary/real-parent"
ln -s "$temporary/real-parent" "$temporary/linked-parent"
linked=$temporary/linked-parent/evidence.tar
if PLOOF_FIXTURE_GATE_COMMAND='printf overwritten > "$PLOOF_GATE_ARTIFACT"' \
        "$root/tools/run-external-gate.sh" fixture.gate "$linked" 2>/dev/null; then
    echo "release shell test: symlinked evidence parent passed" >&2
    exit 1
fi
if [ -e "$temporary/real-parent/evidence.tar" ]; then
    echo "release shell test: symlinked evidence parent was traversed" >&2
    exit 1
fi

invalid=$temporary/invalid.tar
if PLOOF_FIXTURE_GATE_COMMAND='printf invalid > "$PLOOF_GATE_ARTIFACT"' \
        "$root/tools/run-external-gate.sh" fixture.gate "$invalid" 2>/dev/null; then
    echo "release shell test: invalid evidence tar passed" >&2
    exit 1
fi
rm -f "$invalid"
mkdir "$temporary/raw"
printf 'raw evidence\n' > "$temporary/raw/sample"
trivial=$temporary/scheduled.kernel-linux-6.1-intel.tar
if PLOOF_TEST_RAW=$temporary/raw \
        PLOOF_CANDIDATE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        PLOOF_SCHEDULED_KERNEL_LINUX_6_1_INTEL_COMMAND='tar -C "$PLOOF_TEST_RAW" \
            -cf "$PLOOF_GATE_ARTIFACT" sample' \
        "$root/tools/run-external-gate.sh" scheduled.kernel-linux-6.1-intel "$trivial" \
        2>/dev/null; then
    echo "release shell test: trivial evidence tar passed" >&2
    exit 1
fi
rm -f "$trivial"
cat > "$temporary/raw/external-evidence-manifest.json" <<'EOF'
{
  "schema_version": 1,
  "gate_id": "scheduled.kernel-linux-6.1-intel",
  "candidate_revision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "baseline_revision": null,
  "optimization_modes": ["Debug", "ReleaseSafe", "ReleaseFast"],
  "cases_by_mode": {
    "Debug": ["fixture-case"],
    "ReleaseSafe": ["fixture-case"],
    "ReleaseFast": ["fixture-case"]
  },
  "fuzz_budget": null,
  "soak": null,
  "hosts": [{
    "role": "runner",
    "kind": "virtual",
    "machine_id_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "inventory_id_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "architecture": "x86_64",
    "operating_system": "linux",
    "kernel": "7.1.3",
    "cpu_vendor": "FixtureVendor",
    "cpu_model": "Fixture CPU",
    "cpu_flags": "cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
  }],
  "resource_plateau": null,
  "topologies": ["loopback-io-uring"],
  "workloads": [
    "correctness-suite",
    "real-io-suite",
    "security-corpus",
    "allocation-traps",
    "lifecycle-drain"
  ],
  "sigbench": null,
  "load_driver": null,
  "proxy_images": [],
  "artifacts": [{
    "path": "sample",
    "sha256": "805a821b837c808eb729c8cae298f309111d2c43b83cbd92332a0ec2a12b8a4e"
  }]
}
EOF
PLOOF_TEST_RAW=$temporary/raw \
PLOOF_CANDIDATE_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
PLOOF_SCHEDULED_KERNEL_LINUX_6_1_INTEL_COMMAND='tar -C "$PLOOF_TEST_RAW" \
    -cf "$PLOOF_GATE_ARTIFACT" external-evidence-manifest.json sample' \
    "$root/tools/run-external-gate.sh" \
    scheduled.kernel-linux-6.1-intel \
    "$temporary/scheduled.kernel-linux-6.1-intel.tar"
