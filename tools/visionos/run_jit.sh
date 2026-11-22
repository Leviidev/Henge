#!/bin/zsh
# Gives an app on a paired device JIT from this Mac (jit_service.py).
#   tools/visionos/run_jit.sh [--launch] BUNDLE_ID [DEVICE] [-- APP_ARGUMENTS...]
# Without --launch it attaches to the app already running. With --launch it starts the app suspended
# (ending a running copy), attaches, then lets it run, so the app sees a debugger from its first moment.
# APP_ARGUMENTS go to the app, e.g. `-- -henge.perf.codeCacheMB '<integer>512</integer>'` (UserDefaults takes them as
# settings: a bare 512 arrives as a string, which Henge's integer settings ignore).
# DEVICE is a UDID from `xcrun devicectl list devices`; the default is the first connected Apple Vision Pro.
# The app must be signed with get-task-allow (any development build).
set -e
LAUNCH=false
[ "$1" = "--launch" ] && { LAUNCH=true; shift; }
BUNDLE=${1:?bundle identifier required, e.g. com.example.henge}
shift
DEVICE=""
[ $# -gt 0 ] && [ "$1" != "--" ] && { DEVICE=$1; shift; }
[ "$1" = "--" ] && shift
if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/Apple Vision Pro/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')
    [ -n "$DEVICE" ] || { echo "No connected Apple Vision Pro: pass a device" >&2; exit 1; }
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
json() { /usr/bin/python3 -I -c "import json, sys
d = json.load(open(sys.argv[1])).get('result', {})
$2" "$1" 2>/dev/null; }
if $LAUNCH; then
    xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --start-stopped \
        --json-output "$TMP/launch.json" "$BUNDLE" "$@" >/dev/null
    PID=$(json "$TMP/launch.json" "print(d.get('process', {}).get('processIdentifier', ''))")
    [ -n "$PID" ] || { echo "Could not launch $BUNDLE on $DEVICE" >&2; exit 1; }
    echo "Launched $BUNDLE suspended (pid $PID) on $DEVICE"
else
    xcrun devicectl device info apps --device "$DEVICE" --bundle-id "$BUNDLE" --json-output "$TMP/apps.json" >/dev/null 2>&1 || true
    APP=$(json "$TMP/apps.json" "apps = d.get('apps', []); print(apps[0]['url'].replace('file://', '') if apps else '')")
    [ -n "$APP" ] || { echo "$BUNDLE is not installed on $DEVICE" >&2; exit 1; }
    PID=$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null | awk -v app="$APP" 'index($0, app) { print $1; exit }')
    [ -n "$PID" ] || { echo "$BUNDLE is not running on $DEVICE: open it first, or pass --launch" >&2; exit 1; }
    echo "Attaching to $BUNDLE (pid $PID) on $DEVICE"
fi
DEV=$(xcode-select -p)
PYTHONPATH="$(xcrun lldb -P)" exec "$DEV/usr/bin/python3" "${0:A:h}/jit_service.py" "$PID" "$DEVICE"
