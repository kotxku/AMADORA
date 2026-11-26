# AMADORA for Windows and Linux

This desktop work uses the Pandora Launcher Rust desktop code, with AMADORA branding and its own application data, window ID, socket, and credential names. It is separate from the Amethyst based iOS app. The main window opens at 1280 × 720 (16:9), remains resizable for desktop use, and has no mobile control overlay.

## Parity status

This is a desktop foundation, not yet a 1:1 port of the iOS application. Pandora's desktop code already handles Minecraft instances, Microsoft accounts, Modrinth and CurseForge content, and modpack import.

Ported from AMADORA iOS:

- **Archive importer.** Import > *From a zip* takes a Pandora instance export (a folder with `info_v1.json`), a CurseForge modpack zip, or a plain zip of a game folder (whichever folder holds `mods/`, `saves/` or `config/`). Zip entries that would escape the instance folder are refused. A plain zip's loader and Minecraft version are read from its mods. When the mods don't say, the latest release is used and the report says so. Pandora's installed `.mrpack` files stay in `mods/`, because the desktop launcher unpacks them at launch. The import report appears as a notification, and Mod Doctor runs on Fabric imports.
- **Mod Doctor.** The *Mod Doctor* button on a Fabric instance's Mods page reads every `fabric.mod.json` (including jar-in-jar), applies `config/fabric_loader_dependencies.json` overrides, and downloads missing required dependencies from Modrinth for the instance's Minecraft version. Files are SHA-1 checked. It only installs a project whose slug or title matches the mod id. Mods switched off as `.jar.disabled` count as present. Desktop has no Quilt loader, and Forge/NeoForge `mods.toml` dependencies are not checked. The iOS step that switches off native-code mods (C2ME, PhysX, OpenCL) is not needed on desktop.

Still missing before a parity release:

- Horizon 26.3 setup, launch, and per-instance Horizon mod, shader, and resource pack controls. This needs desktop builds of Horizon itself; the iOS integration patches Horizon for iOS only.
- Controller navigation for the launcher. This needs a gamepad input crate (for example `gilrs`) added to the vendored dependencies. Game controller support also needs testing in Minecraft and Horizon on each desktop platform; vanilla Java Minecraft does not supply the iOS touch controls.

Keyboard and mouse work through the native desktop UI. The desktop build does not render on-screen game controls. Do not label the build as iOS feature parity until the gaps above are implemented and tested on Windows and Linux.

## Java and graphics

In Settings > Java, enter an available Java major version and click **Install JDK**. AMADORA downloads the matching Eclipse Temurin JDK for Windows or Linux, verifies its SHA-256 checksum, and stores it under `AMADORA/java`. Select the installed `bin/javaw.exe` (Windows) or `bin/java` (Linux) in the default Java setting or an instance's Java setting. The launcher continues to install the version-specific Mojang runtime automatically when no override is selected. An unavailable Temurin version or platform combination reports an error instead of substituting a different version. `AMADORA --install-java 21` also runs the installer directly.

Minecraft Java uses the OS's native OpenGL driver through its platform-specific LWJGL libraries. The launcher downloads the native libraries named by the Minecraft version manifest. Linux also tries to select a discrete GPU when one is detected; a detection error now leaves the OS's choice intact. These native builds do not use Wine, DXVK, or MoltenVK. Windows graphics drivers and Linux OpenGL/Vulkan drivers must be installed for the machine's GPU by the OS or vendor. The archive does not install or replace a GPU driver. Horizon's Vulkan, DirectX 12 and OpenGL selection will need its own integration and hardware testing when Horizon is ported to this desktop app.

## Build

Run the `AMADORA desktop` GitHub Actions workflow. It builds x86-64 Windows and Linux archives and uploads both as workflow artifacts. The executable inside each archive is `AMADORA.exe` or `AMADORA`. No code signing is configured. Download the appropriate artifact, extract it, and run the executable. On Linux, mark `AMADORA` executable if the archive tool did not preserve permissions.

For local builds, install the current stable Rust toolchain. On Linux, install the packages listed in `.github/workflows/amadora-desktop.yml`, then run `cargo build --release --frozen -p pandora_launcher` from this directory. The executable is at `target/release/pandora_launcher` (or `.exe` on Windows).

AMADORA stores its data in the platform data directory under `AMADORA`. Existing Pandora Launcher data is not migrated automatically. This avoids changing a user's Pandora installation. The two launchers can run side by side.

This project retains the original Pandora Launcher license and attribution in `LICENSE`.

## Desktop installers

The desktop branch builds `AMADORA-Windows-x86_64-Setup.exe` (per-user installation, Start menu shortcut and uninstaller) and `AMADORA-Linux-x86_64.deb` (Ubuntu/Debian package, application menu entry and resolved shared-library dependencies). Install the Debian package with `sudo apt install ./AMADORA-Linux-x86_64.deb`. Portable archives remain available. These are development builds; the parity limitations above still apply. Windows installers are unsigned. Linux packages use the build runner’s library baseline.

Linux builds also produce `AMADORA-Linux-x86_64.rpm` (Fedora/openSUSE: `sudo dnf install ./AMADORA-Linux-x86_64.rpm`) and `AMADORA-Linux-x86_64.pkg.tar.zst` (Arch/CachyOS/Manjaro: `sudo pacman -U AMADORA-Linux-x86_64.pkg.tar.zst`; built in an Arch container in CI).

Linux builds additionally produce an AppImage and a Flatpak bundle. Install the Flatpak with `flatpak install --user ./AMADORA-Linux-x86_64.flatpak`; its runtime is fetched from Flathub. The Flatpak permits home-directory and device access for Minecraft instances and controllers. AppImage builds require the host GPU drivers and a compatible glibc (built on Ubuntu 22.04).
