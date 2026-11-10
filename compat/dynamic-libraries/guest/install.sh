#!/bin/bash
# User-owned versioned install. Config, tokens and caches are never bundled.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
parent=${1:-"$HOME/Library/Application Support/Henge/DynamicLibraries"}
recipe=$(/usr/bin/plutil -extract recipe_sha256 raw -o - "$here/recipe.json")
[[ "$recipe" =~ ^[0-9a-f]{64}$ ]] || exit 65
(cd "$here" && shasum -a 256 -c manifest.sha256)
mkdir -p "$parent"
target="$parent/$recipe"
if [ -d "$target" ]; then
 (cd "$target" && shasum -a 256 -c manifest.sha256)
else
 stage=$(mktemp -d "$parent/.install-$recipe.XXXXXX")
 trap 'rm -rf "$stage"' EXIT
 for name in libHengeDynamic.dylib run.sh install.sh uninstall.sh recipe.json manifest.json manifest.sha256; do cp -p "$here/$name" "$stage/$name"; done
 (cd "$stage" && shasum -a 256 -c manifest.sha256)
 mv "$stage" "$target"
 trap - EXIT
fi
printf 'Installed %s\nRun: "%s/run.sh" --config CONFIG.json -- EXECUTABLE [ARGS...]\n' "$recipe" "$target"
