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

# 全局快捷键的可选编译（RFC-002 §6.3）：有 X11 dev 就带上（CJ_HAVE_X11 + -lX11），
# 没有也能编——能力位如实不置位，运行期调用打一行说明。Debian/Ubuntu: libx11-dev
X11_FLAGS=""
X11_LIBS=""
if pkg-config --exists x11; then
  X11_FLAGS="-DCJ_HAVE_X11"
  X11_LIBS="$(pkg-config --libs x11)"
  echo "[ok] X11 found - global hotkeys enabled (CJ_HAVE_X11)"
else
  echo "[warn] X11 dev not found - global hotkeys disabled (apt install libx11-dev to enable)" >&2
fi

# 托盘的可选编译（RFC-002 §6.3）：有 libayatana-appindicator3 就带上（CJ_HAVE_TRAY），
# 没有也能编——能力位如实不置位。Debian/Ubuntu: libayatana-appindicator3-dev
TRAY_FLAGS=""
TRAY_LIBS=""
TRAY_CFLAGS=""
if pkg-config --exists ayatana-appindicator3-0.1; then
  TRAY_FLAGS="-DCJ_HAVE_TRAY"
  TRAY_CFLAGS="$(pkg-config --cflags ayatana-appindicator3-0.1)"
  TRAY_LIBS="$(pkg-config --libs ayatana-appindicator3-0.1)"
  echo "[ok] ayatana-appindicator3 found - tray enabled (CJ_HAVE_TRAY)"
else
  echo "[warn] ayatana-appindicator3 not found - tray disabled (apt install libayatana-appindicator3-dev to enable)" >&2
fi

# shellcheck disable=SC2086
# core/ = 跨平台共享层；platforms/linux/ = GTK/WebKit 平台实现（目录契约见 AGENTS §2）
"$CC" -shared -fPIC -O2 -fstack-protector-all \
    -Icore $X11_FLAGS $TRAY_FLAGS $TRAY_CFLAGS core/bridge_core.c platforms/linux/bridge_linux.c \
    -o libcjtbridge.so \
    $(pkg-config --cflags --libs $PKGS) $X11_LIBS $TRAY_LIBS

if [ ! -f libcjtbridge.so ]; then
  echo "[ERROR] build libcjtbridge.so failed" >&2
  exit 1
fi

echo "[OK] libcjtbridge.so built"
