#!/usr/bin/env bash
# Builds Horizon (Minecraft: Java Edition 26.3 rewritten in Rust, MIT licensed at the pinned commit) as the release
# folder AMADORA's desktop packages carry: horizon-client, horizon-prepare (and horizon-ctl, horizon-server), Horizon's
# sources and research-lock.json, and its compiled exporter classes. AMADORA finds it beside the launcher
# (crates/backend/src/horizon.rs). Output: target/horizon. Runs on the Linux and Windows CI runners (bash).
#
# Needs JAVA_HOME at a JDK 25 (compiling the exporters), Python 3, and on Linux libasound2-dev and libudev-dev.
# Mojang's jars are downloaded for compiling the exporters only and never leave the runner; AMADORA downloads its own
# copy from Mojang, for a signed-in owner, when a Horizon instance is first played.
set -euo pipefail
cd "$(dirname "$0")/../.."
top=$PWD
here=$top/package/amadora/horizon
commit=$(tr -d '[:space:]' < "$here/COMMIT")
out=$top/target/horizon
exe=
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) exe=.exe ;; esac

if [ -f "$out/.amadora-horizon-commit" ] && [ "$(cat "$out/.amadora-horizon-commit")" = "$commit" ] && [ -f "$out/horizon-client$exe" ]; then
  echo "Horizon $commit is already built in $out"
  exit 0
fi

# The pinned commit, from the first source that has it (package/amadora/horizon/SOURCES)
src=${RUNNER_TEMP:-$top/target}/horizon-src
mkdir -p "$src"
cd "$src"
[ -d .git ] || git init -q .
from=
while read -r repo; do
  repo=${repo%$'\r'}
  case "$repo" in '' | '#'*) continue ;; esac
  if git fetch -q --depth 1 "https://github.com/$repo.git" "$commit" 2>/dev/null; then
    from=$repo
    break
  fi
  echo "$repo doesn't have Horizon $commit"
done < "$here/SOURCES"
[ -n "$from" ] || { echo "::error::No source in package/amadora/horizon/SOURCES has Horizon $commit"; exit 1; }
git checkout -q --force FETCH_HEAD
[ "$(git rev-parse HEAD)" = "$commit" ] || { echo "::error::Fetched $(git rev-parse HEAD), not $commit"; exit 1; }
git clean -qfdx -e target
echo "Building Horizon $commit from $from"

# Horizon's exporter classes, compiled against the pinned jars as Horizon's own release does
python=$(command -v python3 || command -v python)
work=${RUNNER_TEMP:-/tmp}/horizon-minecraft
"$python" "$here/fetch_minecraft.py" research-lock.json "$work"
[ -n "${JAVA_HOME:-}" ] || { echo "::error::JAVA_HOME must be a JDK 25"; exit 1; }
# compile-exporters --prepare imports the pinned jars first; upstream refuses --prepare there, so a horizon-prepare
# with that one check relaxed (the iOS build's patch has the same hunk) compiles them. The shipped programs are
# built afterwards from the unpatched source.
git apply "$here/compile-exporters.patch"
cargo build --release --locked -p horizon-prepare --bin horizon-prepare
rm -rf .local/exporters
bundle=$("target/release/horizon-prepare$exe" compile-exporters --prepare --root "$PWD" --java-home "$JAVA_HOME" \
  --version-json "$work/version.json" --client-jar "$work/client.jar" \
  --libraries-dir "$work/libraries" --server-jar "$work/server.jar" | tail -1 | tr -d '\r')
command -v cygpath > /dev/null && bundle=$(cygpath -u "$bundle")
rm -rf exporters
mkdir -p exporters
cp -R "$bundle/server" "$bundle/client" "$bundle/manifest.json" exporters/
# Only Horizon's own classes ship
stray=$(find exporters -type f ! -path exporters/manifest.json \
  ! \( -name '*.class' \( -path 'exporters/server/dev/horizonlab/parity/*' -o -path 'exporters/client/dev/horizonlab/parity/*' \) \))
[ -z "$stray" ] || { echo "::error::not one of Horizon's classes: $stray"; exit 1; }
git checkout -q -- crates/horizon-prepare/src/main.rs

# The game and its tools, then Horizon's own release folder layout
if [ -n "$exe" ]; then
  # The C runtime linked in, so the game runs without the Visual C++ redistributable (as Horizon's releases)
  export RUSTFLAGS="-C target-feature=+crt-static"
fi
cargo build --release --locked -p horizon-client -p horizon-client-lib --bin horizon-client --bin horizon-ctl \
  -p horizon-prepare --bin horizon-prepare -p horizon-server --bin horizon-server
unset RUSTFLAGS
"target/release/horizon-client$exe" --help | grep -q -- '--resources'
"target/release/horizon-prepare$exe" --help | grep -q -- '--minecraft-dir'
mkdir -p "$(dirname "$out")"
cargo run --locked -p xtask -- package "target/release/horizon-client$exe" "$out"
for file in horizon-client horizon-prepare; do
  [ -f "$out/$file$exe" ] || { echo "::error::$out/$file$exe is missing"; exit 1; }
done
[ -f "$out/research-lock.json" ] && [ -f "$out/exporters/manifest.json" ] || { echo "::error::Horizon's release folder is incomplete"; exit 1; }
printf '%s\n' "$commit" > "$out/.amadora-horizon-commit"
printf 'Horizon %s, built by AMADORA from %s.\nMIT licensed at this commit: see LICENSE.\n' "$commit" "$from" > "$out/AMADORA-BUILD.txt"
du -sh "$out"
