#!/bin/zsh
# Builds libhenge_rpclient.a (ios/rppairing-client: pairing as the computer, for the Apple Vision Pro) into
# ios/deps/lib. Needs rustup with the aarch64-apple-ios target (`rustup target add aarch64-apple-ios`).
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
# Match the app's deployment target, or the linker warns on every object.
export IPHONEOS_DEPLOYMENT_TARGET=15.5
cd "$IOS/rppairing-client"
cargo build --release --target aarch64-apple-ios
mkdir -p "$IOS/deps/lib"
cp target/aarch64-apple-ios/release/libhenge_rpclient.a "$IOS/deps/lib/"
echo "-> ios/deps/lib/libhenge_rpclient.a"
