#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
install -Dm755 target/x86_64-unknown-linux-gnu/release/pandora_launcher "$root/usr/bin/amadora"
install -Dm644 package/amadora_icons/icon_256x256.png "$root/usr/share/icons/hicolor/256x256/apps/amadora.png"
install -Dm644 LICENSE "$root/usr/share/doc/amadora/copyright"
# Horizon's release folder (build-horizon.sh), found by AMADORA at ../lib/amadora/horizon from its executable
if [ -d target/horizon ]; then
  mkdir -p "$root/usr/lib/amadora"
  cp -R target/horizon "$root/usr/lib/amadora/horizon"
fi
mkdir -p "$root/DEBIAN" "$root/usr/share/applications"
cat > "$root/usr/share/applications/amadora.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=AMADORA
Exec=amadora
Icon=amadora
Terminal=false
Categories=Game;
StartupWMClass=AMADORA
DESKTOP
# Resolve dependencies from the actual binary rather than guess its linked libraries.
mkdir -p "$root/debian"
printf 'Source: amadora\nSection: games\nPriority: optional\nMaintainer: AMADORA project\nStandards-Version: 4.6.2\n\nPackage: amadora\nArchitecture: amd64\nDescription: AMADORA desktop Minecraft launcher\n' > "$root/debian/control"
deps=$(cd "$root" && dpkg-shlibdeps -O usr/bin/amadora | sed -n 's/^shlibs:Depends=//p')
cat > "$root/DEBIAN/control" <<CONTROL
Package: amadora
Version: 0.1.0
Architecture: amd64
Maintainer: AMADORA project
Section: games
Priority: optional
Depends: $deps, libgl1, libvulkan1, libasound2 | libasound2t64
Description: AMADORA desktop Minecraft launcher
 Development desktop edition of AMADORA based on Pandora Launcher.
CONTROL
rm -r "$root/debian"
dpkg-deb --root-owner-group --build "$root" AMADORA-Linux-x86_64.deb
