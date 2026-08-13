#!/usr/bin/env sh
set -eu

limit=750
report=0
if [ "${1:-}" = "--report" ]; then
    report=1
fi

count_non_test_lines() {
    file=$1
    case "$file" in
        *.zig)
            awk '
                function scan(line,    i, c, pair) {
                    if (line ~ /^[[:space:]]*\\\\/) return
                    in_quote = 0
                    quote = ""
                    escape = 0
                    for (i = 1; i <= length(line); i++) {
                        c = substr(line, i, 1)
                        pair = substr(line, i, 2)
                        if (in_quote) {
                            if (escape) {
                                escape = 0
                            } else if (c == "\\") {
                                escape = 1
                            } else if (c == quote) {
                                in_quote = 0
                            }
                            continue
                        }
                        if (pair == "//") break
                        if (c == "\"" || c == "'\''") {
                            in_quote = 1
                            quote = c
                        } else if (c == "{") {
                            depth++
                        } else if (c == "}" && depth > 0) {
                            depth--
                        }
                    }
                }
                /^[[:space:]]*test([[:space:]]|")/ && depth == 0 {
                    in_test = 1
                    scan($0)
                    if (depth == 0) in_test = 0
                    next
                }
                in_test {
                    scan($0)
                    if (depth == 0) in_test = 0
                    next
                }
                { n++ }
                END { print n + 0 }
            ' "$file"
            ;;
        *)
            awk 'END { print NR + 0 }' "$file"
            ;;
    esac
}

rows=$(git ls-files --cached --others --exclude-standard | while IFS= read -r file; do
    [ -f "$file" ] || continue
    if [ -s "$file" ] && ! LC_ALL=C grep -Iq . "$file"; then
        continue
    fi
    lines=$(count_non_test_lines "$file")
    printf '%s %s\n' "$lines" "$file"
done)

violations=$(printf '%s\n' "$rows" | awk -v limit="$limit" '$1 > limit { file = substr($0, length($1) + 2); print file ": " $1 " non-test lines exceeds " limit }')

if [ -n "$violations" ]; then
    printf '%s\n' "$violations" >&2
    exit 1
fi

if [ "$report" -eq 1 ]; then
    printf '%s\n' "$rows" | sort -nr | head -20
fi
