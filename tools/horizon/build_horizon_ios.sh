#!/bin/bash
# Builds Horizon (github.com/horizon-rust/horizon, Minecraft 26.3 in Rust) for iOS arm64 as
# libhorizon_ios.dylib, which AMADORA loads from its Frameworks (Natives/horizon/HorizonGame.m).
#
# usage: build_horizon_ios.sh HORIZON_CHECKOUT OUT_DYLIB
#   HORIZON_CHECKOUT  a clone at the commit horizon-ios.patch was made on (HORIZON_COMMIT in the workflow)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
src=$1
out=$2
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

cd "$src"
git apply "$here/horizon-ios.patch"

# winit 0.30.13 from crates.io, patched to run inside AMADORA and take its input
winit_dir="$RUNNER_TEMP/winit-0.30.13"
if [ ! -d "$winit_dir" ]; then
  curl -fsSL https://static.crates.io/crates/winit/winit-0.30.13.crate | tar xz -C "$RUNNER_TEMP"
fi
python3 "$here/patch_winit.py" "$winit_dir" "$src"

rustup target add aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=14.0
# Thin LTO in one codegen unit takes most of an hour on a hosted runner; parallel codegen is
# close in speed for a game that spends its frames on the GPU.
export CARGO_PROFILE_RELEASE_LTO=false
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
export CARGO_PROFILE_RELEASE_DEBUG=false
cargo build --release --locked --target aarch64-apple-ios -p horizon-ios

lib=target/aarch64-apple-ios/release/libhorizon_ios.dylib
install_name_tool -id @rpath/libhorizon_ios.dylib "$lib"
strip -x "$lib"

# The entry points HorizonGame.m looks up
exports=$(nm -gU "$lib")
for sym in horizon_ios_main horizon_ios_key horizon_ios_text horizon_ios_mouse_button horizon_ios_cursor \
           horizon_ios_mouse_motion horizon_ios_scroll horizon_ios_cursor_grabbed horizon_ios_has_window; do
  if ! grep -q " _$sym\$" <<<"$exports"; then
    echo "libhorizon_ios.dylib does not export $sym" >&2
    exit 1
  fi
done
lipo -info "$lib"
otool -L "$lib"

mkdir -p "$(dirname "$out")"
cp "$lib" "$out"
ls -la "$out"
