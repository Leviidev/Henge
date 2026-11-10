#!/bin/bash
# Remove only this exact, unchanged version. Never delete config, tokens or caches.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
(cd "$here" && shasum -a 256 -c manifest.sha256)
expected='install.sh libHengeDynamic.dylib manifest.json manifest.sha256 recipe.json run.sh uninstall.sh'
for path in "$here"/* "$here"/.[!.]*; do
 [ -e "$path" ] || continue
 name=$(basename "$path")
 case " $expected " in *" $name "*) ;; *) echo "Refusing to remove a version containing extra file: $name" >&2; exit 65;; esac
done
for name in $expected; do rm "$here/$name"; done
rmdir "$here"
printf 'Removed adapter version. Configuration, token and cache paths were not changed.\n'
