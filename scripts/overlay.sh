#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/srcpkgs" ]; then
    echo "usage: $0 /path/to/void-packages" >&2
    exit 2
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

rm -rf "$ROOT/srcpkgs/helium"
cp -a "$REPO_ROOT/srcpkgs/helium" "$ROOT/srcpkgs/helium"

echo "Installed helium package overlay into $ROOT/srcpkgs/helium"
