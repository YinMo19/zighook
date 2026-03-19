#!/bin/sh
set -eu

usage() {
    echo "usage: $0 package-dir|bridge-c" >&2
    exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

global_cache_dir=$(
    zig env | sed -n 's/.*\.global_cache_dir = "\([^"]*\)".*/\1/p'
)

dep_hash=$(
    awk '
        /^[[:space:]]*\.zydis_zig[[:space:]]*=[[:space:]]*\.\{/ { in_dep = 1; next }
        in_dep && /^[[:space:]]*\.hash[[:space:]]*=[[:space:]]*"/ {
            line = $0
            sub(/^[^"]*"/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
        in_dep && /^[[:space:]]*\},?[[:space:]]*$/ { in_dep = 0 }
    ' "$repo_root/build.zig.zon"
)

[ -n "$global_cache_dir" ] || {
    echo "failed to resolve Zig global cache directory" >&2
    exit 1
}

[ -n "$dep_hash" ] || {
    echo "failed to resolve zydis_zig dependency hash from build.zig.zon" >&2
    exit 1
}

package_dir="$global_cache_dir/p/$dep_hash"

[ -d "$package_dir" ] || {
    echo "zydis_zig dependency is not fetched; run 'cd $repo_root && zig build --fetch'" >&2
    exit 1
}

case "${1:-}" in
    package-dir)
        printf '%s\n' "$package_dir"
        ;;
    bridge-c)
        printf '%s\n' "$package_dir/c/x86_64/decoder_zydis.c"
        ;;
    *)
        usage
        ;;
esac
