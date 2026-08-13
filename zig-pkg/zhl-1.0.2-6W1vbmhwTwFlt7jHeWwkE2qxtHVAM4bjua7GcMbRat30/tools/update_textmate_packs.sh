#!/usr/bin/env sh
set -eu

zhlc=${ZHLC:-zig-out/bin/zhlc}
out_dir=${1:-grammars/textmate-packs}

if [ ! -x "$zhlc" ]; then
    printf 'missing zhlc at %s; run zig build -Doptimize=ReleaseFast first\n' "$zhlc" >&2
    exit 1
fi

mkdir -p "$out_dir"
jobs=${ZHL_INTEGRATION_JOBS:-32}
find grammars/textmate -maxdepth 1 -type f -name '*.tmLanguage.json' -print0 |
    xargs -0 -r -n 1 -P "$jobs" sh -c '
        zhlc=$1
        out_dir=$2
        grammar=$3
        lang=${grammar##*/}
        lang=${lang%.tmLanguage.json}
        tmp="/tmp/zhl-textmate-${lang}.$$.zhl"
        "$zhlc" convert-textmate-json "$grammar" "$tmp" --include-dir grammars/textmate >/dev/null
        "$zhlc" pack-native "$tmp" "$out_dir/${lang}.zhlb" >/dev/null
        rm -f "$tmp"
    ' sh "$zhlc" "$out_dir"
