# Helium for Void Linux x86_64-musl

Void Linux packaging for Helium, optimized for Intel Skylake and Wayland.

## Target

- Architecture: x86_64-musl
- CPU profile: Skylake
- Display backend: Wayland-only
- ThinLTO: enabled by default

The package intentionally does not target pre-Skylake CPUs or X11-only systems.

## Build

```sh
git clone https://github.com/void-linux/void-packages.git
cd void-packages
/path/to/helium/scripts/overlay.sh "$PWD"
./xbps-src -A x86_64-musl binary-bootstrap
./xbps-src -A x86_64-musl pkg helium
```

Disable ThinLTO for diagnostics:

```sh
./xbps-src -A x86_64-musl -o '~lto' pkg helium
```

Enable debug symbols:

```sh
./xbps-src -A x86_64-musl -o debug pkg helium
```

## Pinned source

- Helium Linux packaging: `0e4e30b0a7c612182e255790fe7eaa4ccfcab15f`
- Helium Chromium source: `57a40ad82583d21787cff0500150539ce54c5960`
- Chromium: `154.0.8037.97`

The recipe verifies that the pinned Helium Linux commit resolves to the expected Helium Chromium submodule before compiling.

## Build design

The recipe reuses Helium's upstream Linux packaging/tooling instead of carrying a Chromium fork. It uses Helium's own Chromium clone path when the release tarball is unavailable, which pins the exact Chromium tag while avoiding an obsolete 404-prone archive URL. It then applies Helium's pruning, patches, branding, translations, versioning, and resource-generation pipeline, followed by the current Void musl compatibility patches. Because this build explicitly sets Chromium's PGO phase to 0, the clone helper is patched to skip downloading unused Chrome/V8 PGO profiles, reducing build I/O without changing the resulting PGO configuration.

The build uses the system Clang/LLVM/LLD/Rust toolchain with sccache, bootstraps the pinned GN revision produced by Helium's clone helper, disables the upstream glibc sysroot and Siso, disables PulseAudio/Sndio in favor of PipeWire, and builds `chrome`, `chromedriver`, and `chrome_crashpad_handler`.

The Chromium sandbox remains enabled; `--no-sandbox` is not supported.

## CI

CI runs only for changes to `main` and manual dispatches. It validates shell syntax and package invariants, overlays the package into the current Void `master` tree, restores caches, builds the package, checks the resulting XBPS repository, and uploads the package artifacts.

The repository is intentionally kept to a single integration branch: `main`.


## Audit notes

The build intentionally pins both the Helium Linux packaging commit and its Helium Chromium submodule commit. The build helper validates both commits before compiling. Download metadata is read from the Helium Chromium submodule, matching upstream Helium's own build pipeline.

The package is maintained as a single integration branch, `main`. The optimization branch used during development is no longer part of the build configuration.
