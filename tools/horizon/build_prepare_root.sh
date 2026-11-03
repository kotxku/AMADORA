#!/usr/bin/env bash
# What AMADORA ships so the device can prepare Horizon's 26.3 files itself (Natives/horizon/HorizonSetup.m):
# Horizon's own exporter classes, compiled here against Mojang's pinned jars as Horizon's release CI does,
# plus the sources and lock their key hashes. Mojang's jars are downloaded for the compile only and never
# leave this runner; the device downloads its own copy from Mojang.
# Usage: build_prepare_root.sh <patched Horizon checkout> <output folder>
set -euo pipefail
src=$(cd "$1" && pwd)
mkdir -p "$2" && out=$(cd "$2" && pwd) # absolute: the steps below run inside the checkout
tools=$(cd "$(dirname "$0")" && pwd)
work="${RUNNER_TEMP:-/tmp}/horizon-prepare-work"
mkdir -p "$work"

# The pinned Java (25) for javac, kept apart from the JDK 8 the launcher builds with
if [ ! -x "$work/jdk/Contents/Home/bin/javac" ]; then
  arch=$(uname -m)
  case "$arch" in arm64) arch=aarch64 ;; x86_64) arch=x64 ;; esac
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/25/ga/mac/$arch/jdk/hotspot/normal/eclipse" -o "$work/jdk.tar.gz"
  rm -rf "$work/jdk" && mkdir "$work/jdk"
  tar -xzf "$work/jdk.tar.gz" -C "$work/jdk" --strip-components 1
fi
jdk="$work/jdk/Contents/Home"

python3 "$tools/fetch_minecraft.py" "$src/research-lock.json" "$work/mc"

cd "$src"
cargo build --release --locked -p horizon-prepare
rm -rf .local/exporters
bundle=$(target/release/horizon-prepare compile-exporters --prepare --root "$src" --java-home "$jdk" \
  --version-json "$work/mc/version.json" --client-jar "$work/mc/client.jar" \
  --libraries-dir "$work/mc/libraries" --server-jar "$work/mc/server.jar" | tail -1)

rm -rf "$out"
mkdir -p "$out/exporters" "$out/crates/horizon-prepare/src"
cp -R "$bundle/server" "$bundle/client" "$bundle/manifest.json" "$out/exporters/"
# Only Horizon's classes and their manifest ship
stray=$(cd "$out" && find exporters -type f ! -path exporters/manifest.json \
  ! \( -name '*.class' \( -path 'exporters/server/dev/horizonlab/parity/*' -o -path 'exporters/client/dev/horizonlab/parity/*' \) \))
[ -z "$stray" ] || { echo "::error::not one of Horizon's classes: $stray"; exit 1; }
rsync -a --include='*/' --include='*.java' --exclude='*' mods/horizon/src/test/java/dev/horizonlab/parity/ \
  "$out/mods/horizon/src/test/java/dev/horizonlab/parity/"
cp crates/horizon-prepare/src/exporters.rs "$out/crates/horizon-prepare/src/"
cp research-lock.json LICENSE "$out/"
echo "Horizon's prepare files: $(du -sh "$out" | cut -f1) in $out"
