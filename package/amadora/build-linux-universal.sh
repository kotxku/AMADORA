#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
install -Dm755 target/x86_64-unknown-linux-gnu/release/pandora_launcher AppDir/usr/bin/amadora
install -Dm644 package/amadora_icons/icon_256x256.png AppDir/usr/share/icons/hicolor/256x256/apps/amadora.png
# Horizon's release folder (build-horizon.sh), beside AMADORA at usr/lib/amadora/horizon
if [ -d target/horizon ]; then
  rm -rf AppDir/usr/lib/amadora/horizon
  mkdir -p AppDir/usr/lib/amadora
  cp -R target/horizon AppDir/usr/lib/amadora/horizon
fi
mkdir -p AppDir/usr/share/applications
cat > AppDir/usr/share/applications/amadora.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=AMADORA
Exec=amadora
Icon=amadora
Terminal=false
Categories=Game;
DESKTOP
curl -fL --retry 3 https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage -o linuxdeploy.AppImage
chmod +x linuxdeploy.AppImage
OUTPUT=AMADORA-Linux-x86_64.AppImage APPIMAGE_EXTRACT_AND_RUN=1 ./linuxdeploy.AppImage --appdir AppDir --executable AppDir/usr/bin/amadora --desktop-file AppDir/usr/share/applications/amadora.desktop --icon-file AppDir/usr/share/icons/hicolor/256x256/apps/amadora.png --output appimage
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user --noninteractive flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08
flatpak-builder --user --force-clean --repo=flatpak-repo flatpak-build package/amadora/io.github.kotxku.AMADORA.yml
flatpak build-bundle flatpak-repo AMADORA-Linux-x86_64.flatpak io.github.kotxku.AMADORA desktop --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo
