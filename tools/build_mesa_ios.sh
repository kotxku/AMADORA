#!/bin/bash
# Builds OSMesa with Zink from a current Mesa for iOS arm64. The Payload step copies Natives/build/*.dylib over
# Natives/resources/Frameworks, replacing the Mesa 21.0 build whose Zink cannot compile Minecraft 26.x's shaders.
# usage: build_mesa_ios.sh <mesa-source (tag mesa-25.0.7, the last with OSMesa)> <MoltenVK-source (tag v1.2.9)> <output-dir>
set -euo pipefail
SRC="$(cd "$1" && pwd)"
MVK="$(cd "$2" && pwd)"
OUT="$3"
BUILD="$SRC/build-ios"

# Zink dlopens the Vulkan loader by name; an iOS app has none, so it loads the MoltenVK bundled next to libOSMesa
sed -i '' 's|#define VK_LIBNAME "libvulkan.1.dylib"|#define VK_LIBNAME "@loader_path/libMoltenVK.dylib"|' \
    "$SRC/src/gallium/drivers/zink/zink_screen.c"
grep -q '@loader_path/libMoltenVK.dylib' "$SRC/src/gallium/drivers/zink/zink_screen.c" || { echo "VK_LIBNAME not patched"; exit 1; }
# OSMesa only links the software rasterizers (and not the xmlconfig Zink reads drirc with); sw_screen_create_named already handles GALLIUM_DRIVER=zink once Zink is linked in
sed -i '' 's/dep_unwind, driver_swrast, idep_mesautil,/dep_unwind, driver_swrast, driver_zink, idep_xmlconfig, idep_mesautil,/' \
    "$SRC/src/gallium/targets/osmesa/meson.build"
grep -q 'driver_zink' "$SRC/src/gallium/targets/osmesa/meson.build" || { echo "OSMesa not patched to link Zink"; exit 1; }
# The inline helper OSMesa uses calls zink_create_screen but, unlike sw_helper.h, never includes its declaration
HELPER="$SRC/src/gallium/auxiliary/target-helpers/inline_sw_helper.h"
# perl without /g changes only the first #ifdef GALLIUM_SOFTPIPE, the one among the includes
grep -q 'zink/zink_public.h' "$HELPER" || perl -0pi -e 's|#ifdef GALLIUM_SOFTPIPE|#ifdef GALLIUM_ZINK
#include "zink/zink_public.h"
#endif

#ifdef GALLIUM_SOFTPIPE|' "$HELPER"
grep -q 'zink/zink_public.h' "$HELPER" || { echo "inline_sw_helper.h not patched"; exit 1; }

# Zink names SPIR-V variables after their GLSL names; MoltenVK 1.2.9's SPIRV-Cross keeps a texture named "sampler",
# which clashes with Metal's sampler type and fails the shader. OpName is debug-only, so emit none.
NAMES="$SRC/src/gallium/drivers/zink/nir_to_spirv/spirv_builder.c"
grep -q 'AMADORA: no debug names' "$NAMES" || perl -0pi -e 's|(spirv_builder_emit_name\(struct spirv_builder \*b, SpvId target,\s*const char \*name\)\s*\{)|$1
   return; /* AMADORA: no debug names */|' "$NAMES"
grep -q 'AMADORA: no debug names' "$NAMES" || { echo "spirv_builder_emit_name not patched"; exit 1; }

# The iOS 26.5 SDK has an <endian.h>, so meson sets HAVE_ENDIAN_H and u_endian.h takes its glibc branch, whose
# macros Apple's header doesn't define. Use Mesa's own Apple branch (machine/endian.h) first.
ENDIAN="$SRC/src/util/u_endian.h"
sed -i '' 's|^#ifdef HAVE_ENDIAN_H$|#if defined(HAVE_ENDIAN_H) \&\& !defined(__APPLE__) /* AMADORA */|' "$ENDIAN"
grep -q 'AMADORA' "$ENDIAN" || { echo "u_endian.h not patched"; exit 1; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
CXX="$(xcrun --sdk iphoneos -f clang++)"
# MoltenVK's headers turn on the Metal and iOS surface platforms, but only after some files already included
# vulkan.h without them; defining them everywhere keeps the generated dispatch tables and vulkan.h in agreement
FLAGS="'-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=14.0', '-DVK_USE_PLATFORM_METAL_EXT', '-DVK_USE_PLATFORM_IOS_MVK'"
cat > "$SRC/ios-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$CC'
ar = '$(xcrun --sdk iphoneos -f ar)'
strip = '$(xcrun --sdk iphoneos -f strip)'

[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS]
objc_args = [$FLAGS]
c_link_args = [$FLAGS, '-framework', 'Foundation', '-framework', 'IOSurface', '-framework', 'Metal', '-framework', 'QuartzCore']
cpp_link_args = [$FLAGS, '-framework', 'Foundation', '-framework', 'IOSurface', '-framework', 'Metal', '-framework', 'QuartzCore']

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

rm -rf "$BUILD"
# OSMesa refuses to build without a software rasterizer; the launcher picks Zink with GALLIUM_DRIVER=zink
meson setup "$BUILD" "$SRC" --cross-file "$SRC/ios-cross.txt" \
    -Dbuildtype=release -Db_ndebug=true \
    -Dgallium-drivers=softpipe,zink -Dvulkan-drivers= -Dplatforms= \
    -Dosmesa=true -Dopengl=true -Dshared-glapi=enabled \
    -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled -Dglvnd=disabled \
    -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dzstd=disabled \
    -Dexpat=disabled -Dxmlconfig=disabled -Dshader-cache=disabled -Dperfetto=false \
    -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled -Dgallium-nine=false \
    -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dvideo-codecs= -Dtools= -Dbuild-tests=false \
    -Dmoltenvk-dir="$MVK/MoltenVK"
ninja -C "$BUILD"

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$(find "$BUILD" -name 'libOSMesa.8.dylib' -type f | head -1)" "$OUT/libOSMesa.8.dylib"
# Same install name as the Mesa 21.0 build, so dlopen("@rpath/libOSMesa.8.dylib") resolves in Frameworks.
# Mesa 25.0 links glapi into libOSMesa; the old libglapi.0.dylib stays in Frameworks for the other renderers.
install_name_tool -id @rpath/libOSMesa.8.dylib "$OUT/libOSMesa.8.dylib"
# Each tool's output is captured before grep -q, which would otherwise SIGPIPE it and fail the pipefail pipeline
LINKS="$(otool -L "$OUT/libOSMesa.8.dylib")"
if grep -q libglapi <<< "$LINKS"; then echo "libOSMesa still links a separate libglapi"; exit 1; fi

# Fail the build rather than ship a macOS binary, one without Zink, or one missing the entry points osm_bridge uses
for lib in "$OUT"/*.dylib; do
    BUILD_VERSION="$(otool -l "$lib" | grep -A4 LC_BUILD_VERSION)"
    [[ "$BUILD_VERSION" == *"platform 2"* ]] || { echo "$lib is not an iOS binary"; exit 1; }
done
# osm_bridge dlsyms these through the libOSMesa handle
SYMS="$(nm -gU "$OUT"/*.dylib)"
for sym in OSMesaCreateContext OSMesaMakeCurrent OSMesaGetCurrentContext OSMesaDestroyContext OSMesaPixelStore OSMesaGetProcAddress glGetString glFinish; do
    grep -q " _$sym\$" <<< "$SYMS" || { echo "libOSMesa does not export $sym"; exit 1; }
done
grep -q '@loader_path/libMoltenVK.dylib' <<< "$(strings "$OUT/libOSMesa.8.dylib")" || { echo "Zink not built in"; exit 1; }
otool -L "$OUT/libOSMesa.8.dylib"
echo "Built $OUT/libOSMesa.8.dylib"
