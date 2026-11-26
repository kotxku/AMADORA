#!/usr/bin/env bash
# Builds the Arch package inside an archlinux container (makepkg refuses to run as root).
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp package/amadora/PKGBUILD package/amadora/amadora.desktop package/amadora_icons/icon_256x256.png LICENSE "$work/"
cp target/x86_64-unknown-linux-gnu/release/pandora_launcher "$work/"
if [ -d target/horizon ]; then cp -R target/horizon "$work/horizon"; fi
chmod -R a+rwX "$work"
# The container's builder user owns everything makepkg writes; hand the files back to the host user before
# exiting (even when makepkg fails), or the runner can't read the package or clean up $work.
docker run --rm -v "$work:/pkg" -w /pkg -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" archlinux:latest bash -c '
  trap "chown -R \"$HOST_UID:$HOST_GID\" /pkg" EXIT
  pacman -Syu --noconfirm --needed base-devel >/dev/null &&
  useradd -m builder &&
  chown -R builder /pkg &&
  su builder -c "makepkg --nodeps --noconfirm"'
cp "$work"/amadora-*.pkg.tar.zst AMADORA-Linux-x86_64.pkg.tar.zst
