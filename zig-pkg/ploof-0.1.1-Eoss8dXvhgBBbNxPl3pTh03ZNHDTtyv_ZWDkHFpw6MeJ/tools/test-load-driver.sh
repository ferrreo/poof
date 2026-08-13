#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 9 ]]; then
  echo "load-driver integration: expected three MODE DRIVER ORIGIN triples" >&2
  exit 2
fi

root=$(pwd)
work=$(mktemp -d "$root/zig-out/load-driver-test.XXXXXX")
origin_pid=""

cleanup() {
  if [[ -n "$origin_pid" ]]; then
    kill "$origin_pid" 2>/dev/null || true
    wait "$origin_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

validate_report() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["driver"] == "ploof-load-driver"
assert report["schema_version"] == 1
assert report["driver_version"] == 1
assert report["optimization_mode"] == sys.argv[2]
assert report["scheduling_mode"] == sys.argv[3]
assert report["results"]["transport_failures"] == 0
assert report["results"]["application_failures"] == 0
assert report["results"]["successful_requests"] > 0
PY
}

run_driver() {
  local driver=$1
  local mode=$2
  local port=$3
  local name=$4
  shift 4
  local output="$work/$mode-$name.json"
  "$driver" --address 127.0.0.1 --host app.test --port "$port" \
    --header 'Forwarded: not valid ]]]' \
    --header 'X-Forwarded-For: totally invalid' \
    --header 'X-Forwarded-Host: attacker.test' \
    --header 'X-Forwarded-Proto: http' "$@" >"$output"
  validate_report "$output" "$mode" "$name"
}

run_calibration() {
  local driver=$1
  local mode=$2
  local output="$work/$mode-calibration.json"
  "$driver" --scheduling constant-rate --rate 1 --requests 1000 \
    --concurrency 1 --calibrate >"$output"
  validate_report "$output" "$mode" constant-rate
  python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["calibration"] is True
assert report["calibration_kind"] == "scheduler-request-loop-lower-bound"
assert report["results"]["calibration_ratio_milli"] >= 2000
PY
}

run_mode() {
  local mode=$1
  local driver=$2
  local origin=$3
  local ready="$work/$mode.ready"
  local errors="$work/$mode.origin.err"

  run_calibration "$driver" "$mode"
  "$origin" direct 8 >"$ready" 2>"$errors" &
  origin_pid=$!
  local port=""
  for _ in $(seq 1 200); do
    port=$(awk '/^READY / { print $2; exit }' "$ready")
    [[ -n "$port" ]] && break
    kill -0 "$origin_pid" 2>/dev/null || {
      cat "$errors" >&2
      return 1
    }
    sleep 0.01
  done
  [[ -n "$port" ]] || {
    echo "load-driver integration: $mode origin readiness timed out" >&2
    return 1
  }

  run_driver "$driver" "$mode" "$port" closed-loop \
    --path /identity --requests 2 --concurrency 2 --connections keepalive \
    --expect-status 200 --expect-body proxy-ok
  run_driver "$driver" "$mode" "$port" constant-rate \
    --path /identity --requests 2 --concurrency 2 --connections keepalive \
    --scheduling constant-rate --rate 1000 --expect-status 200 --expect-body proxy-ok
  run_driver "$driver" "$mode" "$port" closed-loop \
    --path /identity --requests 2 --concurrency 1 --connections churn \
    --expect-status 200 --expect-body proxy-ok
  run_driver "$driver" "$mode" "$port" closed-loop \
    --path /stream --requests 1 --concurrency 1 --connections keepalive \
    --expect-status 200 --expect-body-bytes 32768 \
    --expect-sha256 c8696f37c6bf8b546509e7f3a1eeade28a0b29989c8dd6315392f89db68f1143
  run_driver "$driver" "$mode" "$port" closed-loop \
    --path /finish --requests 1 --concurrency 1 --connections keepalive \
    --expect-status 200 --expect-body proxy-ok

  wait "$origin_pid" || {
    cat "$errors" >&2
    return 1
  }
  origin_pid=""
}

while [[ $# -ne 0 ]]; do
  run_mode "$1" "$2" "$3"
  shift 3
done

echo "load-driver integration: 3 modes, 24 exact responses passed"
