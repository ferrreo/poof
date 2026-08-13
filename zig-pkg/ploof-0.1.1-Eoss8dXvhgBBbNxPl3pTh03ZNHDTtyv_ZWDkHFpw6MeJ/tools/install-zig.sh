#!/bin/sh
set -eu

version=0.16.0
sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
url=https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
destination=${1:?usage: install-zig.sh DESTINATION}

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo "install-zig: Linux x86_64 host required" >&2
    exit 1
fi
if [ -e "$destination" ]; then
    echo "install-zig: destination already exists: $destination" >&2
    exit 1
fi

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
archive=$temporary/zig.tar.xz
curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$url"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status
tar -xJf "$archive" -C "$temporary"
mv "$temporary/zig-x86_64-linux-$version" "$destination"

if [ "$("$destination/zig" version)" != "$version" ]; then
    echo "install-zig: installed compiler did not report $version" >&2
    exit 1
fi
