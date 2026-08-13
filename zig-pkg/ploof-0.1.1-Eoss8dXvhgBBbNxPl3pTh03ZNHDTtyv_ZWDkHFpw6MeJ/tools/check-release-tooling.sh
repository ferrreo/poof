#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
python3 tools/release.py structure
zig fmt --check build*.zig src tests tools
sh tools/test-release-tools.sh
python3 -m unittest -v \
    tests/release_tooling_test.py \
    tests/release_policy_test.py \
    tests/workflow_run_test.py
