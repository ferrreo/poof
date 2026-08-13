#!/usr/bin/env sh
set -eu

zhlc=${ZHLC:-zig-out/bin/zhlc}
out_dir=${1:-grammars/sublime-packs}
tmp_root=${TMPDIR:-/tmp}/zhl-sublime-packs.$$
corpus_cache=${ZHL_CORPUS_CACHE:-.zig-cache/zhl-corpus}
source_dir=$tmp_root/sources
native_dir=$tmp_root/native
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM

if [ ! -x "$zhlc" ]; then
    printf 'missing zhlc at %s; run zig build -Doptimize=ReleaseFast first\n' "$zhlc" >&2
    exit 1
fi

mkdir -p "$out_dir"
mkdir -p "$source_dir" "$native_dir"
ZHL_CORPUS_CACHE=$corpus_cache sh tools/fetch_corpus_cache.sh >/dev/null
for first_part in "$corpus_cache"/grammars/sublime/*.sublime-syntax.part00; do
    [ -e "$first_part" ] || continue
    base=${first_part##*/}
    base=${base%.sublime-syntax.part00}
    cat "$corpus_cache/grammars/sublime/${base}.sublime-syntax.part"* > "$source_dir/${base}.sublime-syntax"
done

jobs=${ZHL_INTEGRATION_JOBS:-32}
find "$source_dir" -maxdepth 1 -type f -name '*.sublime-syntax' -print0 |
    xargs -0 -r -n 1 -P "$jobs" sh -c '
        zhlc=$1
        out_dir=$2
        native_dir=$3
        source=$4
        base=${source##*/}
        base=${base%.sublime-syntax}
        lang=$(printf "%s" "$base" | tr "[:upper:]" "[:lower:]")
        native="$native_dir/${base}.$$.zhl"
        "$zhlc" convert-sublime "$source" "$native" >/dev/null
        "$zhlc" pack-native "$native" "$out_dir/${lang}.zhlb" >/dev/null
        rm -f "$native"
    ' sh "$zhlc" "$out_dir" "$native_dir"
