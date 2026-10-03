# Helium for Void Linux x86_64-musl

Void Linux packaging for Helium, targeting x86_64-musl.

This repository is an overlay rather than a fork of void-packages. The package recipe reuses Helium's upstream Linux packaging/tooling and adapts the Chromium configuration to Void's native musl toolchain.

## Pinned source

- Helium Linux packaging: imputnet/helium-linux commit 0e4e30b0a7c612182e255790fe7eaa4ccfcab15f
- Helium source submodule: imputnet/helium commit 57a40ad82583d21787cff0500150539ce54c5960
- Chromium: 154.0.8037.97

The pinned Helium Linux commit references the exact Helium source commit above. The build checks that relationship before compiling.

## Build

Clone Void's source package tree and install this package:

~~~sh
git clone https://github.com/void-linux/void-packages.git
cd void-packages
/path/to/helium/scripts/overlay.sh "$PWD"
./xbps-src -A x86_64-musl binary-bootstrap
./xbps-src -A x86_64-musl pkg helium
~~~

The package is intentionally restricted to x86_64-musl.

You can inspect options with:

~~~sh
./xbps-src -A x86_64-musl show-options helium
~~~

The first build is deliberately conservative. Enable LTO with:

~~~sh
./xbps-src -A x86_64-musl -o lto pkg helium
~~~

Disable it again with -o '~lto'.

## Build design

The fetch phase clones the pinned Helium Linux packaging repository and initializes its pinned helium-chromium submodule.

The build then:

1. downloads Chromium and Helium's declared assets using Helium's own verified download metadata;
2. applies Helium's patch stacks, pruning, domain substitution, branding substitutions, translations, versioning, and generated resources;
3. applies Void's Chromium musl patches for the sandbox and DNS resolver;
4. configures native Void clang, lld, Rust, pkg-config, and system libraries;
5. disables Chromium's glibc sysroot, bundled LLVM/Rust bootstrap, and Siso;
6. builds chrome, chromedriver, and chrome_crashpad_handler;
7. installs the browser under /usr/lib/helium.

The recipe is intentionally based on Void's current Chromium musl packaging rather than Helium's Debian Docker image.

## Runtime

Installed entry points:

- /usr/bin/helium
- /usr/lib/helium/*
- /usr/share/applications/helium.desktop
- /usr/share/icons/hicolor/256x256/apps/helium.png

Do not use --no-sandbox; the package includes the musl-specific sandbox changes used by Void's Chromium package.

## CI

GitHub Actions only performs syntax and pin checks. A full Chromium build is not placed in CI because it is a multi-hour, high-storage job.
