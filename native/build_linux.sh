#!/usr/bin/env bash
# ============================================================
# cj-tauri Linux backend: build the GTK/WebKit C bridge (libcjtbridge.so)
#
# Requirements:
#   - gcc (or clang via CC=clang) + pkg-config
#   - libwebkit2gtk-4.1-dev + libgtk-3-dev
#       Debian/Ubuntu: sudo apt install gcc pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev
#       Fedora:        sudo dnf install gcc pkgconf-pkg-config webkit2gtk4.1-devel gtk3-devel
#       Arch:          sudo pacman -S gcc pkgconf webkit2gtk-4.1 gtk3
#
# Output: native/libcjtbridge.so
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CC="${CC:-gcc}"

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "[ERROR] C compiler '$CC' not found. Install gcc, or override with CC=clang." >&2
  exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "[ERROR] pkg-config not found." >&2
  echo "        Debian/Ubuntu: sudo apt install pkg-config libwebkit2gtk-4.1-dev libgtk-3-dev" >&2
  exit 1
fi

PKGS="webkit2gtk-4.1 gtk+-3.0"
# shellcheck disable=SC2086
if ! pkg-config --exists $PKGS; then
  echo "[ERROR] webkit2gtk-4.1 / gtk+-3.0 development packages not found." >&2
  echo "        Debian/Ubuntu: sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev" >&2
  echo "        Fedora:        sudo dnf install webkit2gtk4.1-devel gtk3-devel" >&2
  exit 1
fi

# shellcheck disable=SC2086
"$CC" -shared -fPIC -O2 -fstack-protector-all bridge_core.c bridge_linux.c \
    -o libcjtbridge.so \
    $(pkg-config --cflags --libs $PKGS)

if [ ! -f libcjtbridge.so ]; then
  echo "[ERROR] build libcjtbridge.so failed" >&2
  exit 1
fi

echo "[OK] libcjtbridge.so built"
