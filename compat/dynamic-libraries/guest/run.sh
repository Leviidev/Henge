#!/bin/bash
# Opt in only this process and its children. No global environment or login item.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "${1:-}" = --config ] && [ "$#" -ge 4 ] || { echo 'usage: run.sh --config CONFIG.json -- EXECUTABLE [ARGS...]' >&2; exit 64; }
config=$2;shift 2
[ "${1:-}" = -- ] || exit 64
shift
[ -r "$config" ] && [ -f "$here/libHengeDynamic.dylib" ] || exit 66
config=$(cd "$(dirname "$config")" && printf '%s/%s' "$PWD" "$(basename "$config")")
export HENGE_DYNAMIC_CONFIG="$config"
[ -z "${DYLD_INSERT_LIBRARIES:-}" ] || { echo 'Refusing inherited DYLD injection; use explicit combined launcher arguments.' >&2; exit 64; }
export DYLD_INSERT_LIBRARIES="$here/libHengeDynamic.dylib"
exec "$@"
