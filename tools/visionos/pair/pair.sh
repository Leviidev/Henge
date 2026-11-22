#!/bin/zsh
# Makes an RPPairing file for an Apple Vision Pro, for Henge's built-in JIT.
#   1. On the headset, open Settings › General › Remote Devices and leave it open.
#   2. tools/visionos/pair/pair.sh [OUT.plist]      (default: pairingFile.plist here)
#   3. Type the code the headset shows.
# Then import the file in Henge (JIT › Use a pairing file), or copy it in from the Mac:
#   xcrun devicectl device copy to --device UDID --domain-type appDataContainer \
#       --domain-identifier BUNDLE_ID --source OUT.plist --destination Documents/StikJIT/pairingFile.plist
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=${1:-$HERE/pairingFile.plist}
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
cargo build --release --quiet --manifest-path "$HERE/Cargo.toml"
TYPE=_remotepairing-manual-pairing._tcp

echo "==> looking for a device in pairing mode (Settings › General › Remote Devices)…" >&2
LOG=$(mktemp -t henge-pair)
trap 'rm -f "$LOG"; kill $DNS 2>/dev/null || true' EXIT
dns-sd -B $TYPE local. > "$LOG" 2>&1 & DNS=$!
for i in {1..300}; do
    NAME=$(awk -v t="$TYPE." '$2 == "Add" && $6 == t { sub(/^.*_tcp\. +/, ""); print; exit }' "$LOG")
    [ -n "$NAME" ] && break
    sleep 1
done
kill $DNS 2>/dev/null || true
[ -n "$NAME" ] || { echo "no device in pairing mode found" >&2; exit 1 }
echo "==> found $NAME" >&2

dns-sd -L "$NAME" $TYPE local. > "$LOG" 2>&1 & DNS=$!
for i in {1..20}; do
    AT=$(sed -nE 's/.* can be reached at ([^ ]+):([0-9]+) .*/\1 \2/p' "$LOG" | head -1)
    [ -n "$AT" ] && break
    sleep 0.5
done
kill $DNS 2>/dev/null || true
[ -n "$AT" ] || { echo "could not resolve $NAME" >&2; exit 1 }
HOST=${AT% *}; PORT=${AT#* }
echo "==> $HOST port $PORT" >&2
"$HERE/target/release/henge-vision-pair" "${HOST%.}" "$PORT" "$OUT"
