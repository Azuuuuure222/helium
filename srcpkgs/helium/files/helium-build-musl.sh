#!/usr/bin/env bash
set -euo pipefail

if (( $# < 1 || $# > 3 )); then
    printf 'usage: %s <helium-linux-root> [lto] [debug]\n' "$0" >&2
    exit 2
fi

ROOT="$1"
USE_LTO="${2:-}"
USE_DEBUG="${3:-}"

HELIUM_LINUX="$ROOT/helium-linux"
HELIUM="$HELIUM_LINUX/helium-chromium"
BUILD_ROOT="$HELIUM_LINUX/build"
SRC="$BUILD_ROOT/src"
CACHE="${HELIUM_DOWNLOAD_CACHE:-$BUILD_ROOT/download_cache}"
OUT="$SRC/out/Default"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$CACHE" "$SRC" "$OUT"

export HOME="$BUILD_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
unset HOST_CFLAGS HOST_CXXFLAGS HOST_LDFLAGS
export RUSTC_BOOTSTRAP=1
export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=system

python3 "$HELIUM/utils/downloads.py" retrieve     -i "$HELIUM_LINUX/downloads.ini"     -c "$CACHE"

python3 "$HELIUM/utils/downloads.py" unpack     -i "$HELIUM_LINUX/downloads.ini"     -c "$CACHE"     "$SRC"

python3 "$HELIUM/utils/downloads.py" retrieve     -i "$HELIUM_LINUX/deps.ini"     -c "$CACHE"

python3 "$HELIUM/utils/downloads.py" unpack     -i "$HELIUM_LINUX/deps.ini"     -c "$CACHE"     "$SRC"

python3 "$HELIUM/utils/prune_binaries.py"     "$SRC" "$HELIUM/pruning.list"

python3 "$HELIUM/utils/patches.py" apply     "$SRC"     "$HELIUM/patches"     "$HELIUM_LINUX/patches"

python3 "$HELIUM/utils/domain_substitution.py" apply     -r "$HELIUM/domain_regex.list"     -f "$HELIUM/domain_substitution.list"     "$SRC"

python3 "$HELIUM/utils/name_substitution.py"     --sub     -t "$SRC"

python3 "$HELIUM/utils/i18n_apply.py"     -t "$SRC"

python3 "$HELIUM/utils/helium_version.py"     --tree "$HELIUM"     --platform-tree "$HELIUM_LINUX"     --chromium-tree "$SRC"

python3 "$HELIUM/utils/generate_resources.py"     "$HELIUM/resources/generate_resources.txt"     "$HELIUM/resources"

python3 "$HELIUM/utils/replace_resources.py"     "$HELIUM/resources/helium_resources.txt"     "$HELIUM/resources"     "$SRC"

for patch in "$SCRIPT_DIR"/musl-patches/*.patch; do
    echo "Applying musl patch: $patch"
    patch -Np1 -i "$patch" -d "$SRC"
done

mkdir -p     "$SRC/third_party/node/linux/node-linux-x64/bin"     "$SRC/third_party/dawn/tools/golang/linux-amd64/bin"     "$SRC/third_party/gperf/cipd/bin"     "$SRC/buildtools/linux64-format"     "$SRC/third_party/devtools-frontend/src/third_party/esbuild"

ln -sf /usr/bin/node     "$SRC/third_party/node/linux/node-linux-x64/bin/node"

ln -sf /usr/bin/go     "$SRC/third_party/dawn/tools/golang/linux-amd64/bin/go"

ln -sf /usr/bin/gperf     "$SRC/third_party/gperf/cipd/bin/gperf"

if command -v clang-format >/dev/null 2>&1; then
    ln -sf "$(command -v clang-format)"         "$SRC/buildtools/linux64-format/clang-format"
fi

if command -v esbuild >/dev/null 2>&1; then
    ln -sf /usr/bin/esbuild         "$SRC/third_party/devtools-frontend/src/third_party/esbuild/esbuild"
    mkdir -p "$SRC/third_party/devtools-frontend/src/node_modules"
    rm -rf "$SRC/third_party/devtools-frontend/src/node_modules/esbuild"
    ln -sf /usr/lib/node_modules/esbuild         "$SRC/third_party/devtools-frontend/src/node_modules/esbuild"
fi

cd "$SRC"

system_libs=(
    flac
    fontconfig
    freetype
    libdrm
    libjpeg
    libwebp
    libxml
    libxslt
    opus
)

for lib in "${system_libs[@]}" libjpeg_turbo; do
    [ -d "third_party/$lib" ] || continue
    find "third_party/$lib" -type f         ! -path "third_party/$lib/chromium/*"         ! -path "third_party/$lib/google/*"         ! -name '*.gn'         ! -name '*.gni'         ! -name '*.isolate'         -delete
done

python3 "build/linux/unbundle/replace_gn_files.py"     --system-libraries "${system_libs[@]}"

clang_version="$(clang -dumpversion)"

cat > "$OUT/args.gn" <<EOF
$(cat "$HELIUM/flags.gn")
$(cat "$HELIUM_LINUX/flags.linux.gn")

# Void Linux x86_64-musl overrides.
target_cpu = "x64"
v8_target_cpu = "x64"
host_cpu = "x64"

custom_toolchain = "//build/toolchain/linux/unbundle:default"
host_toolchain = "//build/toolchain/linux/unbundle:default"

is_musl = true
use_sysroot = false
use_siso = false

is_clang = true
use_lld = true
clang_base_path = "/usr"
clang_version = "${clang_version%%.*}"
cc_wrapper = "/usr/bin/sccache"

rust_sysroot_absolute = "/usr"
rust_bindgen_root = "/usr"
use_custom_libcxx = false

host_pkg_config = "/usr/bin/pkg-config"
node_version_check = false
clang_use_chrome_plugins = false
use_clang_modules = false

is_official_build = true
logging_like_official_build = true
is_debug = $( [ -n "$USE_DEBUG" ] && printf true || printf false )
symbol_level = $( [ -n "$USE_DEBUG" ] && printf 1 || printf 0 )
blink_symbol_level = 0

treat_warnings_as_errors = false
fatal_linker_warnings = false

use_system_harfbuzz = false
use_system_libffi = true
use_cups = true

use_vaapi = true
rtc_use_pipewire = true
use_kerberos = false

# Target deployment: Intel Skylake / Wayland-only.
ozone_auto_platforms = false
ozone_platform = "wayland"
ozone_platform_wayland = true
ozone_platform_x11 = false
ozone_platform_headless = false
ozone_platform_gbm = false
use_x11 = false

chrome_pgo_phase = 0
icu_use_data_file = true
EOF

if [ -n "$USE_LTO" ]; then
    printf '%s\n'         'use_thin_lto = true'         'symbol_level = 0'         'v8_symbol_level = 0'         'blink_symbol_level = 0'         >> "$OUT/args.gn"
    lto_jobs="${XBPS_MAKEJOBS:-$(nproc)}"
    export LDFLAGS="${LDFLAGS:-} -Wl,--threads=$lto_jobs -Wl,--lto-O2 -Wl,--lto-partitions=$lto_jobs"
else
    printf '%s\n' 'use_thin_lto = false' >> "$OUT/args.gn"
fi

./buildtools/linux64/gn gen "$OUT" --fail-on-unused-args

if command -v sccache >/dev/null 2>&1; then
    sccache --show-stats || true
fi

ninja -C "$OUT" -j"${XBPS_MAKEJOBS:-$(nproc)}"     chrome     chromedriver     chrome_crashpad_handler

if command -v sccache >/dev/null 2>&1; then
    sccache --show-stats || true
fi
