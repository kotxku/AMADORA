#!/usr/bin/env bash
# Builds the Arch package inside an archlinux container (makepkg refuses to run as root).
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp package/amadora/PKGBUILD package/amadora/amadora.desktop package/amadora_icons/icon_256x256.png LICENSE "$work/"
cp target/x86_64-unknown-linux-gnu/release/pandora_launcher "$work/"
chmod -R a+rwX "$work"
docker run --rm -v "$work:/pkg" -w /pkg archlinux:latest bash -c '
  pacman -Syu --noconfirm --needed base-devel >/dev/null &&
  useradd -m builder &&
  chown -R builder /pkg &&
  su builder -c "makepkg --nodeps --noconfirm"'
cp "$work"/amadora-*.pkg.tar.zst AMADORA-Linux-x86_64.pkg.tar.zst
