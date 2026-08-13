#!/usr/bin/env sh
set -eu

min_fast_mib_s=${ZHL_MIN_NATIVE_FAST_MIB_S:-${ZHL_MIN_NATIVE_MIB_S:-20}}
min_medium_mib_s=${ZHL_MIN_NATIVE_MEDIUM_MIB_S:-8}
min_slow_mib_s=${ZHL_MIN_NATIVE_SLOW_MIB_S:-5}
expected_rows=${ZHL_EXPECT_NATIVE_ROWS:-29}
if [ -n "${ZHL_BENCH:-}" ]; then
    output=$("$ZHL_BENCH" 2>&1)
else
    output=$(zig build bench -Doptimize=ReleaseFast 2>&1)
fi
printf '%s\n' "$output"

printf '%s\n' "$output" | awk \
    -v min_fast="$min_fast_mib_s" \
    -v min_medium="$min_medium_mib_s" \
    -v min_slow="$min_slow_mib_s" \
    -v expected_rows="$expected_rows" '
function min_for(row) {
    if (row == "zhl TypeScript native" || row == "zhl minified JavaScript native" || row == "zhl real JavaScript source native" || row == "zhl C++ native" || row == "zhl C# native" || row == "zhl HTML native" || row == "zhl Java native" || row == "zhl JSX native" || row == "zhl Kotlin native" || row == "zhl Markdown native" || row == "zhl PHP native" || row == "zhl Ruby native" || row == "zhl Swift native" || row == "zhl TSX native") return min_slow
    if (row == "zhl Rust native" || row == "zhl Python native" || row == "zhl real Bash source native" || row == "zhl real C source native" || row == "zhl real Python source native" || row == "zhl real Rust source native" || row == "zhl real TypeScript source native") return min_medium
    return min_fast
}
function fail(message) {
    print message > "/dev/stderr"
    failed = 1
}
function reset_row() {
    throughput = setup_allocs = setup_bytes = hot_allocs = hot_bytes = total_allocs = total_bytes = ""
}
function check_row() {
    if (row == "") return
    rows += 1
    min = min_for(row)
    if (throughput == "") fail(row ": missing throughput")
    else if (throughput + 0 < min) fail(row " below gate: " throughput " MiB/s < " min " MiB/s")
    if (setup_allocs != "0" || setup_bytes != "0") fail(row " setup allocation gate failed: " setup_allocs " allocs / " setup_bytes " B")
    if (hot_allocs != "0" || hot_bytes != "0") fail(row " hot allocation gate failed: " hot_allocs " allocs / " hot_bytes " B")
    if (total_allocs != "0" || total_bytes != "0") fail(row " total allocation gate failed: " total_allocs " allocs / " total_bytes " B")
}
/^zhl .* native$/ {
    check_row()
    row = $0
    reset_row()
    next
}
row != "" && /throughput:/ { throughput = $2 }
row != "" && /setup_allocs:/ { setup_allocs = $2 }
row != "" && /setup_bytes:/ { setup_bytes = $2 }
row != "" && /hot_allocs:/ { hot_allocs = $2 }
row != "" && /hot_bytes:/ { hot_bytes = $2 }
row != "" && /total_allocs:/ { total_allocs = $2 }
row != "" && /total_bytes:/ { total_bytes = $2 }
END {
    check_row()
    if (rows == 0) fail("no zhl benchmark rows found")
    else if (rows != expected_rows) fail("native benchmark row count changed: " rows " rows != " expected_rows)
    exit failed
}'
