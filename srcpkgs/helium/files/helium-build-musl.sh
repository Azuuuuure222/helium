#!/usr/bin/env bash
set -euo pipefail

ROOT="$1"
USE_LTO="${2:-}"
USE_DEBUG="${3:-}"

HELIUM_LINUX="$ROOT/helium-linux"
HELIUM="$HELIUM_LINUX/helium-chromium"
BUILD_ROOT="$HELIUM_LINUX/build"
SRC="$BUILD_ROOT/src"
CACHE="$BUILD_ROOT/download_cache"
OUT="$SRC/out/Default"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$CACHE" "$SRC" "$OUT"

export HOME="$BUILD_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
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

mkdir -p     "$SRC/third_party/node/linux/node-linux-x64/bin"     "$SRC/third_party/dawn/tools/golang/linux-amd64/bin"     "$SRC/third_party/gperf/cipd/bin"     "$SRC/buildtools/linux64-format"     "$SRC/buildtools/third_party/mold/cipd"     "$SRC/third_party/devtools-frontend/src/third_party/esbuild"

ln -sf /usr/bin/node     "$SRC/third_party/node/linux/node-linux-x64/bin/node"

ln -sf /usr/bin/go     "$SRC/third_party/dawn/tools/golang/linux-amd64/bin/go"

ln -sf /usr/bin/gperf     "$SRC/third_party/gperf/cipd/bin/gperf"

if command -v clang-format >/dev/null 2>&1; then
    ln -sf "$(command -v clang-format)"         "$SRC/buildtools/linux64-format/clang-format"
fi

if command -v mold >/dev/null 2>&1; then
    ln -sf "$(command -v mold)"         "$SRC/buildtools/third_party/mold/cipd/mold"
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
    find "third_party/$lib" -type f         ! -path "third_party/$lib/chromium/*"         ! -path "third_party/$lib/google/*"         ! -path "base/third_party/icu/*"         ! -path "third_party/harfbuzz-ng/utils/hb_scoped.h"         ! -regex '.*\.(gn|gni|isolate)'         -delete 2>/dev/null || :
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

rust_sysroot_absolute = "/usr"
rust_bindgen_root = "/usr"
use_custom_libcxx = false

host_pkg_config = "/usr/bin/pkg-config"
clang_use_chrome_plugins = false
use_clang_modules = false

is_official_build = true
is_debug = $( [ -n "$USE_DEBUG" ] && printf true || printf false )
symbol_level = $( [ -n "$USE_DEBUG" ] && printf 1 || printf 0 )
blink_symbol_level = 0

treat_warnings_as_errors = false
fatal_linker_warnings = false

use_system_harfbuzz = false
use_system_libffi = false
use_cups = true

use_vaapi = true
rtc_use_pipewire = true
use_kerberos = false

chrome_pgo_phase = 0
icu_use_data_file = true
EOF

if [ -n "$USE_LTO" ]; then
    printf '%s\n'         'use_thin_lto = true'         'symbol_level = 0'         >> "$OUT/args.gn"
else
    printf '%s\n' 'use_thin_lto = false' >> "$OUT/args.gn"
fi

./buildtools/linux64/gn gen "$OUT" --fail-on-unused-args

ninja -C "$OUT" -j"${XBPS_MAKEJOBS:-$(nproc)}"     chrome     chromedriver     chrome_crashpad_handler
