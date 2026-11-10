#!/bin/bash
# Install only a separately built Henge wrapper; never touch its target app.
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo 'Usage: install.sh /path/VLC\ Hardware.app [absolute destination directory]' >&2
  exit 64
fi
src="${1%/}"
name="${src##*/}"
case "$name" in *.app) ;; *) echo 'Source must be an app bundle' >&2; exit 64;; esac
src="$(cd "$(dirname "$src")" && pwd -P)/$name"
destination="${2:-$HOME/Applications}"
case "$destination" in /*) ;; *) echo 'Destination must be absolute' >&2; exit 64;; esac
marker=$(/usr/libexec/PlistBuddy -c 'Print :HengeOpenGLLauncher' "$src/Contents/Info.plist")
[ "$marker" = true ] || { echo 'Source is not a Henge launcher wrapper' >&2; exit 65; }
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$src/Contents/Info.plist")
/usr/bin/codesign --verify --deep --strict "$src"
mkdir -p "$destination"
staging=$(mktemp -d "$destination/.henge-launcher.XXXXXX")
installed="$destination/$name"
backup=''
cleanup() {
  status=$?
  # Restore only a wrapper moved by this invocation, and only into an absent
  # destination. Never replace a newly appeared app during error recovery.
  if [ "$status" -ne 0 ] && [ -n "$backup" ] && [ ! -e "$installed" ]; then
    /bin/mv "$backup" "$installed" || true
  fi
  /bin/rm -rf "$staging"
  exit "$status"
}
trap cleanup EXIT
/usr/bin/ditto "$src" "$staging/$name"
/usr/bin/codesign --verify --deep --strict "$staging/$name"
if [ -e "$installed" ]; then
  old_marker=$(/usr/libexec/PlistBuddy -c 'Print :HengeOpenGLLauncher' "$installed/Contents/Info.plist" 2>/dev/null || true)
  old_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist" 2>/dev/null || true)
  [ "$old_marker" = true ] && [ "$old_identifier" = "$identifier" ] || {
    echo 'Refusing to replace an app that is not the matching Henge wrapper' >&2; exit 65;
  }
  backup_dir="$HOME/Library/Application Support/Henge/LauncherBackups/$(/usr/bin/uuidgen)"
  mkdir -p "$backup_dir"
  backup="$backup_dir/$name"
  /bin/mv "$installed" "$backup"
fi
[ ! -e "$installed" ] || { echo 'Destination appeared during installation' >&2; exit 73; }
/bin/mv "$staging/$name" "$installed"
printf 'Installed: %s\n' "$installed"
if [ -n "$backup" ]; then printf 'Previous wrapper backup: %s\n' "$backup"; fi
printf 'Configured target app was not modified. Quit VLC, then open this wrapper.\n'
