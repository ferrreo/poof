#!/usr/bin/env sh
# Generates zig-out/grammars_selected/root.zig (+ symlinks to ext grammar modules).
# LANGS: native (default 26), full (native + all ext in src/grammars_ext/), or
# comma-separated names e.g. zig,haskell,elixir,js.
set -eu

langs=${LANGS:-native}
out_dir=${OUT_DIR:-zig-out/grammars_selected}
ext_root=src/grammars_ext/root.zig

mkdir -p "$out_dir"
rm -f "$out_dir"/*.zig

# native canonical -> zhl_grammars module field (grammar = native.<field>.grammar)
native_field() {
    case "$1" in
        bash) echo bash ;;
        c) echo c ;;
        cpp) echo cpp ;;
        csharp) echo csharp ;;
        css) echo css ;;
        go) echo go ;;
        html) echo html ;;
        java) echo java ;;
        javascript) echo javascript ;;
        jsx) echo jsx ;;
        json) echo json ;;
        kotlin) echo kotlin ;;
        log) echo log ;;
        markdown) echo markdown ;;
        php) echo php ;;
        python) echo python ;;
        ruby) echo ruby ;;
        rust) echo rust ;;
        sql) echo sql ;;
        swift) echo swift ;;
        toml) echo toml ;;
        tsx) echo tsx ;;
        typescript) echo typescript ;;
        xml) echo xml ;;
        yaml) echo yaml ;;
        zig|zig_0_16) echo zig_0_16 ;;
        sh|shell) echo bash ;;
        h) echo c ;;
        ansi-c) echo c ;;
        c++|cc|cxx) echo cpp ;;
        cs|c#) echo csharp ;;
        golang) echo go ;;
        htm|xhtml) echo html ;;
        js|mjs|cjs|node) echo javascript ;;
        javascriptreact) echo jsx ;;
        jsonc|jsonl) echo json ;;
        kt) echo kotlin ;;
        md|mdown) echo markdown ;;
        py|pyw) echo python ;;
        rb) echo ruby ;;
        rs) echo rust ;;
        typescriptreact) echo tsx ;;
        ts|mts|cts) echo typescript ;;
        xsd|svg) echo xml ;;
        yml) echo yaml ;;
        *) return 1 ;;
    esac
}

native_id() {
    case "$1" in
        bash) echo 1 ;;
        c) echo 2 ;;
        cpp) echo 3 ;;
        csharp) echo 4 ;;
        css) echo 5 ;;
        go) echo 6 ;;
        html) echo 7 ;;
        java) echo 8 ;;
        javascript) echo 9 ;;
        jsx) echo 10 ;;
        json) echo 11 ;;
        kotlin) echo 12 ;;
        log) echo 26 ;;
        markdown) echo 13 ;;
        php) echo 14 ;;
        python) echo 15 ;;
        ruby) echo 16 ;;
        rust) echo 17 ;;
        sql) echo 18 ;;
        swift) echo 19 ;;
        toml) echo 20 ;;
        tsx) echo 21 ;;
        typescript) echo 22 ;;
        xml) echo 23 ;;
        yaml) echo 24 ;;
        zig_0_16) echo 25 ;;
        *) return 1 ;;
    esac
}

native_canonical() {
    case "$1" in
        bash) echo bash ;;
        c) echo c ;;
        cpp) echo cpp ;;
        csharp) echo csharp ;;
        css) echo css ;;
        go) echo go ;;
        html) echo html ;;
        java) echo java ;;
        javascript) echo javascript ;;
        jsx) echo jsx ;;
        json) echo json ;;
        kotlin) echo kotlin ;;
        log) echo log ;;
        markdown) echo markdown ;;
        php) echo php ;;
        python) echo python ;;
        ruby) echo ruby ;;
        rust) echo rust ;;
        sql) echo sql ;;
        swift) echo swift ;;
        toml) echo toml ;;
        tsx) echo tsx ;;
        typescript) echo typescript ;;
        xml) echo xml ;;
        yaml) echo yaml ;;
        zig_0_16) echo zig ;;
        *) return 1 ;;
    esac
}

all_native_fields="bash c cpp csharp css go html java javascript jsx json kotlin log markdown php python ruby rust sql swift toml tsx typescript xml yaml zig_0_16"

list_langs() {
    case "$langs" in
        native)
            for f in $all_native_fields; do
                native_canonical "$f"
            done
            ;;
        full)
            for f in $all_native_fields; do
                native_canonical "$f"
            done
            if [ -f "$ext_root" ]; then
                awk '/^pub const names = \[_\]\[\]const u8\{$/,/^\};$/ {
                    if ($0 ~ /^    "/) {
                        gsub(/[",]/, "", $1)
                        print $1
                    }
                }' "$ext_root"
            fi
            ;;
        *)
            old_ifs=$IFS
            IFS=,
            for part in $langs; do
                part=$(printf %s "$part" | tr -d ' ')
                [ -n "$part" ] || continue
                printf '%s\n' "$part"
            done
            IFS=$old_ifs
            ;;
    esac
}

# ext name -> module file stem (from grammars_ext/root.zig)
ext_mod_for_name() {
    name=$1
    awk -v want="$name" '
        /^pub const g_/ {
            line = $0
            sub(/^pub const g_/, "", line)
            sub(/ = .*/, "", line)
            mods[++m] = line
        }
        /^    "/ {
            gsub(/[",]/, "", $1)
            if ($1 != "") names[++n] = $1
        }
        END {
            for (i = 1; i <= n; i++) {
                if (names[i] == want) { print mods[i]; exit }
            }
        }
    ' "$ext_root"
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT HUP TERM

seen_native=""
seen_ext=""
ext_index=0

while read -r raw; do
    [ -n "$raw" ] || continue
    if field=$(native_field "$raw" 2>/dev/null); then
        case " $seen_native " in
            *" $field "*) continue ;;
        esac
        seen_native="$seen_native $field"
        id=$(native_id "$field")
        canon=$(native_canonical "$field")
        printf 'native\t%s\t%s\t%s\n' "$id" "$canon" "$field" >> "$tmp"
        continue
    fi
    if [ ! -f "$ext_root" ]; then
        printf 'select_grammars: unknown language %s (no src/grammars_ext/; run tools/generate_grammars_ext.sh)\n' "$raw" >&2
        exit 1
    fi
    mod=$(ext_mod_for_name "$raw")
    if [ -z "$mod" ]; then
        printf 'select_grammars: unknown language %s\n' "$raw" >&2
        exit 1
    fi
    case " $seen_ext " in
        *" $raw "*) continue ;;
    esac
    seen_ext="$seen_ext $raw"
    src=src/grammars_ext/$mod.zig
    if [ ! -f "$src" ]; then
        printf 'select_grammars: missing %s for %s\n' "$src" "$raw" >&2
        exit 1
    fi
    ext_index=$((ext_index + 1))
    id=$((1000 + ext_index - 1))
    ln -sf "$(cd "$(dirname "$src")" && pwd)/$mod.zig" "$out_dir/$mod.zig"
    printf 'ext\t%s\t%s\t%s\t%s\n' "$id" "$raw" "$mod" "g_$mod" >> "$tmp"
done <<EOF
$(list_langs)
EOF

if [ ! -s "$tmp" ]; then
    printf 'select_grammars: no languages selected\n' >&2
    exit 1
fi

root="$out_dir/root.zig"
{
    echo '//! Generated by tools/select_grammars.sh. Do not edit.'
    echo 'const std = @import("std");'
    echo 'const native = @import("zhl_grammars");'
    echo ''
    echo 'pub const ext_base_id: u32 = 1000;'
    echo ''
    while IFS="$(printf '\t')" read -r kind id canon mod gsym; do
        if [ "$kind" = ext ]; then
            echo "pub const $gsym = @import(\"$mod.zig\");"
        fi
    done < "$tmp"
    echo ''
    echo 'pub const names = [_][]const u8{'
    while IFS="$(printf '\t')" read -r kind id canon mod gsym; do
        echo "    \"$canon\","
    done < "$tmp"
    echo '};'
    echo ''
    echo 'pub const ids = [_]u32{'
    while IFS="$(printf '\t')" read -r kind id canon mod gsym; do
        echo "    $id,"
    done < "$tmp"
    echo '};'
    echo ''
    echo 'pub fn count() usize {'
    echo '    return names.len;'
    echo '}'
    echo ''
    echo 'pub fn idFromName(name: []const u8) u32 {'
    echo '    inline for (names, ids) |n, id| {'
    echo '        if (std.mem.eql(u8, name, n)) return id;'
    echo '    }'
    echo '    if (native.findByName(name)) |meta| {'
    echo '        const mid = @intFromEnum(meta.id);'
    echo '        inline for (ids) |id| {'
    echo '            if (id == mid) return id;'
    echo '        }'
    echo '    }'
    echo '    return 0;'
    echo '}'
    echo ''
    echo 'pub fn dispatchHighlight(id: u32, src: []const u8, comptime mode: anytype, run: anytype) u32 {'
    echo '    return switch (id) {'
    while IFS="$(printf '\t')" read -r kind id canon mod gsym; do
        if [ "$kind" = native ]; then
            echo "        $id => run(native.$mod.grammar, src, mode),"
        else
            echo "        $id => run($gsym.grammar, src, mode),"
        fi
    done < "$tmp"
    echo '        else => 101,'
    echo '    };'
    echo '}'
} > "$root"

count=$(wc -l < "$tmp" | tr -d ' ')
native_n=$(grep -c '^native' "$tmp" || true)
ext_n=$(grep -c '^ext' "$tmp" || true)
printf 'select_grammars: langs=%s selected=%s (native=%s ext=%s) -> %s\n' "$langs" "$count" "$native_n" "$ext_n" "$root"
