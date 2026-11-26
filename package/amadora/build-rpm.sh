#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT
mkdir -p "$top/SOURCES"
cp target/x86_64-unknown-linux-gnu/release/pandora_launcher "$top/SOURCES/"
cp package/amadora_icons/icon_256x256.png package/amadora/amadora.desktop LICENSE "$top/SOURCES/"
if [ -d target/horizon ]; then cp -R target/horizon "$top/SOURCES/horizon"; fi
rpmbuild -bb --define "_topdir $top" --define "debug_package %{nil}" --define "_build_id_links none" package/amadora/amadora.spec
cp "$top"/RPMS/*/amadora-*.rpm AMADORA-Linux-x86_64.rpm
