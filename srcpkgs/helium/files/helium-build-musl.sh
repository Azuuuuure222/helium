#!/usr/bin/env bash
set -euo pipefail

trap 'rc=$?; printf "ERROR: helium-build-musl.sh failed at line %s: %s (exit %s)\\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2' ERR

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

mkdir -p "$CACHE"

export HOME="$BUILD_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
unset HOST_CFLAGS HOST_CXXFLAGS HOST_LDFLAGS
export RUSTC_BOOTSTRAP=1
export MACH_BUILD_PYTHON_NATIVE_PACKAGE_SOURCE=system

test -x /usr/bin/bsdtar
test -x /usr/bin/curl
test -x /usr/bin/node
test -x /usr/bin/go
test -x /usr/bin/gperf
test -x /usr/bin/sccache

test -f "$HELIUM/utils/clone.py"
test -f "$HELIUM/deps.ini"
test -f "$SCRIPT_DIR/skip-pgo.patch"

# Chromium's peak memory use is high enough to thrash or OOM a 4 GiB machine
# when ninja is allowed to use every logical CPU. Keep an explicit escape
# hatch for faster build hosts, but make the target machine safe by default.
if [ -n "${HELIUM_MAKEJOBS:-}" ]; then
    BUILD_JOBS="$HELIUM_MAKEJOBS"
elif [ "$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || printf 0)" -le $((6 * 1024 * 1024)) ]; then
    BUILD_JOBS=2
elif [ -n "${XBPS_MAKEJOBS:-}" ]; then
    BUILD_JOBS="$XBPS_MAKEJOBS"
else
    BUILD_JOBS="$(nproc)"
fi
case "$BUILD_JOBS" in
    ''|*[!0-9]*|0) printf 'invalid HELIUM_MAKEJOBS: %s\n' "$BUILD_JOBS" >&2; exit 2 ;;
esac
printf 'Using %s parallel build job(s)\n' "$BUILD_JOBS"

# Helium's tarball URL for Chromium 154.0.8037.97 is no longer available.
# Use the upstream clone path, which checks out the exact Chromium tag and
# prepares the same generated metadata/build inputs used by Helium's builds.
rm -rf "$SRC"
patch --batch --forward -Np1 -i "$SCRIPT_DIR/skip-pgo.patch" -d "$HELIUM"
export HELIUM_SKIP_PGO=1
python3 "$HELIUM/utils/clone.py" -o "$SRC"
mkdir -p "$OUT"

test -n "${HELIUM_CHROMIUM_COMMIT:-}"
test "$(git -C "$SRC" rev-parse HEAD)" = "$HELIUM_CHROMIUM_COMMIT"

python3 "$HELIUM/utils/downloads.py" retrieve -i "$HELIUM/deps.ini" -c "$CACHE"
python3 "$HELIUM/utils/downloads.py" unpack --tar-path /usr/bin/bsdtar -i "$HELIUM/deps.ini" -c "$CACHE" "$SRC"

# Chromium 154 GN requires the Crubit support tree shipped in Chromium's
# prebuilt Rust toolchain. Helium uses the system Rust compiler, so fetch only
# the pinned archive and extract it into the compatibility path GN references.
RUST_TOOLCHAIN_OBJECT="${HELIUM_RUST_TOOLCHAIN_OBJECT:?missing HELIUM_RUST_TOOLCHAIN_OBJECT}"
RUST_TOOLCHAIN_SHA256="${HELIUM_RUST_TOOLCHAIN_SHA256:?missing HELIUM_RUST_TOOLCHAIN_SHA256}"
RUST_TOOLCHAIN_ARCHIVE="$CACHE/${RUST_TOOLCHAIN_OBJECT##*/}"
RUST_TOOLCHAIN_DIR="$SRC/third_party/rust-toolchain"
RUST_TOOLCHAIN_URL="https://commondatastorage.googleapis.com/chromium-browser-clang/$RUST_TOOLCHAIN_OBJECT"

if [ ! -s "$RUST_TOOLCHAIN_ARCHIVE" ] || ! printf "%s  %s\n" "$RUST_TOOLCHAIN_SHA256" "$RUST_TOOLCHAIN_ARCHIVE" | sha256sum -c - >/dev/null 2>&1; then
    curl --fail --location --retry 5 --retry-all-errors \
        --connect-timeout 30 --max-time 900 \
        --output "$RUST_TOOLCHAIN_ARCHIVE.tmp" "$RUST_TOOLCHAIN_URL"
    printf "%s  %s.tmp\n" "$RUST_TOOLCHAIN_SHA256" "$RUST_TOOLCHAIN_ARCHIVE" | sha256sum -c -
    mv -f "$RUST_TOOLCHAIN_ARCHIVE.tmp" "$RUST_TOOLCHAIN_ARCHIVE"
fi

rm -rf "$RUST_TOOLCHAIN_DIR"
mkdir -p "$RUST_TOOLCHAIN_DIR"
bsdtar -xf "$RUST_TOOLCHAIN_ARCHIVE" -C "$RUST_TOOLCHAIN_DIR"
test -f "$RUST_TOOLCHAIN_DIR/lib/third_party/crubit/support/BUILD.gn"

python3 "$HELIUM/utils/prune_binaries.py"     "$SRC" "$HELIUM/pruning.list"

python3 "$HELIUM/utils/patches.py" apply     "$SRC"     "$HELIUM/patches"     "$HELIUM_LINUX/patches"

python3 "$HELIUM/utils/domain_substitution.py" apply     -r "$HELIUM/domain_regex.list"     -f "$HELIUM/domain_substitution.list"     "$SRC"

python3 "$HELIUM/utils/name_substitution.py"     --sub     -t "$SRC"

python3 "$HELIUM/utils/i18n_apply.py"     -t "$SRC"

python3 "$HELIUM/utils/helium_version.py"     --tree "$HELIUM"     --platform-tree "$HELIUM_LINUX"     --chromium-tree "$SRC"

test "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" = "154.0.8037.97"

python3 "$HELIUM/utils/generate_resources.py"     "$HELIUM/resources/generate_resources.txt"     "$HELIUM/resources"

python3 "$HELIUM/utils/replace_resources.py"     "$HELIUM/resources/helium_resources.txt"     "$HELIUM/resources"     "$SRC"

# Restore upstream build-tool URLs that Helium's domain substitution rewrites.
sed -i     -e 's/commondatastorage.9oo91eapis.qjz9zk/commondatastorage.googleapis.com/g'     "$SRC/build/linux/sysroot_scripts/sysroots.json"     "$SRC/tools/clang/scripts/update.py"     "$SRC/tools/clang/scripts/build.py"
sed -i     -e 's/chromium.9oo91esource.qjz9zk/chromium.googlesource.com/g'     "$SRC/tools/clang/scripts/build.py"     "$SRC/tools/rust/build_rust.py"     "$SRC/tools/rust/build_bindgen.py"
sed -i     -e 's/chrome-infra-packages.8pp2p8t.qjz9zk/chrome-infra-packages.appspot.com/g'     "$SRC/tools/rust/build_rust.py"

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

# Chromium tarballs normally ship a prebuilt GN under buildtools/linux64/gn.
# Helium's clone.py produces the GN source tree instead, so bootstrap the
# pinned GN revision locally and expose the resulting binary at that path.
GN_JOBS="$BUILD_JOBS"
GN_ROOT="$SRC/tools/gn"
GN_BIN="$SRC/out/Release/gn"

if [ ! -e "$GN_BIN" ]; then
    (
        cd "$GN_ROOT"
        python3 bootstrap/bootstrap.py -j"$GN_JOBS" --skip-generate-buildfiles
    )
fi

# Chromium bootstrap.py copies the binary to src/out/Release/gn after
# building the intermediate src/out/Release/gn_build/gn target.
# Keep a narrow fallback for future bootstrap layout changes.
if [ ! -f "$GN_BIN" ]; then
    GN_FALLBACK="$(find "$SRC/out" -type f -path '*/gn_build/gn' -print -quit 2>/dev/null || true)"
    test -n "$GN_FALLBACK"
    GN_BIN="$GN_FALLBACK"
fi
chmod 0755 "$GN_BIN"
test -x "$GN_BIN"

mkdir -p "$SRC/buildtools/linux64"
rm -rf "$SRC/buildtools/linux64/gn"
install -m 0755 "$GN_BIN" "$SRC/buildtools/linux64/gn"
test -x "$SRC/buildtools/linux64/gn"
test -f "$SRC/buildtools/linux64/gn"

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
rustc_version = "$(rustc --version | cut -d' ' -f2)"
use_custom_libcxx = true
enable_safe_libcxx = true

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
use_pulseaudio = false
link_pulseaudio = false
use_sndio = false
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
    lto_jobs="$BUILD_JOBS"
    export LDFLAGS="${LDFLAGS:-} -Wl,--threads=$lto_jobs -Wl,--lto-O2 -Wl,--lto-partitions=$lto_jobs"
else
    printf '%s\n' 'use_thin_lto = false' >> "$OUT/args.gn"
fi

./buildtools/linux64/gn gen "$OUT" --fail-on-unused-args

if command -v sccache >/dev/null 2>&1; then
    sccache --show-stats || true
fi

ninja -C "$OUT" -j"$BUILD_JOBS"     chrome     chromedriver     chrome_crashpad_handler

if command -v sccache >/dev/null 2>&1; then
    sccache --show-stats || true
fi
