# AMADORA for Windows and Linux

This desktop work uses the Pandora Launcher Rust desktop code, with AMADORA branding and its own application data, window ID, socket, and credential names. It is separate from the Amethyst based iOS app. The main window opens at 1280 × 720 (16:9), remains resizable for desktop use, and has no mobile control overlay.

## Parity status

This is a desktop foundation, not yet a 1:1 port of the iOS application. Pandora's desktop code already handles Minecraft instances, Microsoft accounts, Modrinth and CurseForge content, and modpack import. The following AMADORA iOS features still need desktop implementations and validation before a parity release:

- Horizon 26.3 setup, launch, and per-instance Horizon mod, shader, and resource pack controls.
- AMADORA's archive importer behavior for Pandora instance ZIPs, including nested `.mrpack` expansion and its import report.
- Mod Doctor dependency scanning and safe download of missing Fabric or Quilt mods.
- Controller navigation for the launcher. Game controller support also needs testing in Minecraft and Horizon on each desktop platform; vanilla Java Minecraft does not supply the iOS touch controls.

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

Linux builds additionally produce an AppImage and a Flatpak bundle. Install the Flatpak with `flatpak install --user ./AMADORA-Linux-x86_64.flatpak`; its runtime is fetched from Flathub. The Flatpak permits home-directory and device access for Minecraft instances and controllers. AppImage builds require the host GPU drivers and a compatible glibc (built on Ubuntu 22.04).
