#!/usr/bin/env bash
set -euo pipefail

if (( $# != 5 && $# != 6 )); then
    echo "usage: $0 ZIG CACHE_ROOT STEP RUNS TIMEOUT_SECONDS [SHARDS]" >&2
    exit 2
fi

zig=$1
cache_root=$2
step=$3
runs=$4
timeout_seconds=$5
shards=${6:-1}
case "$runs" in
    ''|*[!0-9]*|0)
        echo "fuzz runs must be a positive integer" >&2
        exit 2
        ;;
esac
case "$timeout_seconds" in
    ''|*[!0-9]*|0)
        echo "fuzz timeout must be a positive integer" >&2
        exit 2
        ;;
esac
if (( timeout_seconds > 86400 )); then
    echo "fuzz timeout must not exceed 86400 seconds" >&2
    exit 2
fi
case "$shards" in
    ''|*[!0-9]*|0)
        echo "fuzz shards must be a positive integer" >&2
        exit 2
        ;;
esac
if (( shards > 32 )); then
    echo "fuzz shards must not exceed 32" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "fuzz driver requires the Linux timeout command" >&2
    exit 2
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "fuzz driver requires the Linux setsid command" >&2
    exit 2
fi
if ! command -v flock >/dev/null 2>&1; then
    echo "fuzz driver requires the Linux flock command" >&2
    exit 2
fi

acquire_cache_lock() {
    local path=$1 root=$2
    if [[ -L $path || -e $path && ! -f $path ]]; then
        echo "fuzz cache lock is not a regular file: $path" >&2
        return 2
    fi
    exec {fuzz_lock_fd}>"$path"
    if ! flock -n "$fuzz_lock_fd"; then
        echo "fuzz cache is already in use: $root" >&2
        return 2
    fi
}

if (( $# == 6 && shards > 1 )); then
    if (( shards > runs )); then
        shards=$runs
    fi
    supervisor_gate=$cache_root/fuzz-driver
    supervisor_lock=$supervisor_gate/lock
    shard_root=$cache_root/fuzz-shards/$step
    mkdir -p "$supervisor_gate" "$shard_root"
    acquire_cache_lock "$supervisor_lock" "$cache_root"

    shard_pids=()
    shard_logs=()
    supervisor_cleanup() {
        local status=$?
        trap - EXIT HUP INT TERM
        for pid in "${shard_pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        for pid in "${shard_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        exit "$status"
    }
    trap supervisor_cleanup EXIT
    trap 'exit 130' HUP INT TERM

    base_runs=$((runs / shards))
    extra_runs=$((runs % shards))
    for ((shard = 0; shard < shards; shard += 1)); do
        shard_runs=$base_runs
        if (( shard < extra_runs )); then
            shard_runs=$((shard_runs + 1))
        fi
        shard_cache=$shard_root/$shard
        shard_log=$supervisor_gate/$step.shard-$shard.log
        shard_logs+=("$shard_log")
        bash "$0" "$zig" "$shard_cache" "$step" \
            "$shard_runs" "$timeout_seconds" >"$shard_log" 2>&1 &
        shard_pids+=("$!")
    done

    failed=false
    remaining=$shards
    while (( remaining != 0 )); do
        set +e
        wait -n
        shard_status=$?
        set -e
        if (( shard_status != 0 )); then
            failed=true
            break
        fi
        remaining=$((remaining - 1))
    done
    if [[ $failed == true ]]; then
        for pid in "${shard_pids[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    for pid in "${shard_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    for shard_log in "${shard_logs[@]}"; do
        cat "$shard_log"
    done
    if [[ $failed == true ]]; then
        echo "one or more fuzz shards failed" >&2
        exit 1
    fi
    echo "fuzz sharded campaign complete: step=$step shards=$shards total-runs=$runs"
    exit 0
fi

gate=$cache_root/fuzz-driver
lock=$gate/lock
crash=$cache_root/f/crash
log=$gate/$step.log
runner=$gate/build_runner.zig
mkdir -p "$gate" "$cache_root/f"
acquire_cache_lock "$lock" "$cache_root"
nested_pid=""
terminate_worker() {
    if [[ -n $nested_pid ]]; then
        kill -TERM -- "-$nested_pid" 2>/dev/null || true
        wait "$nested_pid" 2>/dev/null || true
    fi
    exit 130
}
trap terminate_worker HUP INT TERM

version=$("$zig" version)
if [[ $version != 0.16.0 ]]; then
    echo "fuzz driver requires Zig 0.16.0, found $version" >&2
    exit 2
fi
lib_dir=$("$zig" env | sed -n 's/^[[:space:]]*\.lib_dir = "\(.*\)",$/\1/p')
source_runner=$lib_dir/compiler/build_runner.zig
expected_sha=2791bc495d2d9f819a3cc4602578535a9ac1fd8246b77c1918dc5734c9afdf8b
actual_sha=$(sha256sum "$source_runner" | awk '{print $1}')
if [[ $actual_sha != "$expected_sha" ]]; then
    echo "unsupported Zig 0.16 build runner: $actual_sha" >&2
    exit 2
fi
anchor='        try f.waitAndPrintReport();'
if [[ $(grep -Fxc "$anchor" "$source_runner") != 1 ]]; then
    echo "Zig fuzz build-runner patch anchor is not unique" >&2
    exit 2
fi

temporary=$runner.tmp.$$
awk -v anchor="$anchor" '
    { print }
    $0 == anchor {
        print "        for (step_stack.keys()) |s| {"
        print "            const fuzz_run = s.cast(Step.Run) orelse continue;"
        print "            if (fuzz_run.fuzz_tests.items.len == 0 or"
        print "                s.result_error_msgs.items.len == 0 or s.state != .success)"
        print "            {"
        print "                continue;"
        print "            }"
        print "            s.state = .failure;"
        print "            assert(success_count > 0);"
        print "            success_count -= 1;"
        print "            failure_count += 1;"
        print "        }"
    }
' "$source_runner" > "$temporary"
mv "$temporary" "$runner"

rm -f "$crash" "$log"
set +e
campaign_started=$SECONDS
setsid timeout --signal=TERM --kill-after=5s "$timeout_seconds" \
    "$zig" build "$step" \
    -Dfuzz-driver=true \
    --fuzz="$runs" \
    --cache-dir "$cache_root" \
    --build-runner "$runner" >"$log" 2>&1 &
nested_pid=$!
wait "$nested_pid"
nested_status=$?
nested_pid=""
campaign_elapsed=$((SECONDS - campaign_started))
set -e
cat "$log"

failed=false
if (( nested_status == 124 ||
    nested_status == 137 && campaign_elapsed >= timeout_seconds )); then
    echo "fuzz campaign exceeded ${timeout_seconds}-second deadline" >&2
    failed=true
elif (( nested_status != 0 )); then
    echo "nested fuzz build failed with status $nested_status" >&2
    failed=true
fi
if [[ -f $crash ]]; then
    echo "fuzz crash input saved to $crash" >&2
    failed=true
fi
if grep -Fq 'failed to rerun in fuzz mode:' "$log" ||
    grep -Fq 'failed to rebuild in fuzz mode:' "$log" ||
    grep -Fq 'one or more unit tests failed to be rebuilt in fuzz mode' "$log" ||
    grep -Fq 'input saved to' "$log"
then
    echo "fuzz runner reported a failed target" >&2
    failed=true
fi
if ! grep -Fq '======= FUZZING REPORT =======' "$log" ||
    ! grep -Fq '==============================' "$log"
then
    echo "fuzz runner did not emit a complete report" >&2
    failed=true
fi
if [[ $failed == true ]]; then
    exit 1
fi
