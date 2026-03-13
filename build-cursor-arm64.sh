#!/bin/bash
# Build Cursor ARM64 by grafting Cursor's JS resources onto VS Code ARM64.
# Cursor is a closed-source VS Code fork — all proprietary code is JS (arch-independent).
# Native binaries (Electron, Node) come from the open-source VS Code ARM64 build.
#
# Cursor 2.x changed its AppImage structure:
#   Old (0.x): squashfs-root/resources/app/...
#   New (2.x): squashfs-root/usr/share/cursor/resources/app/...
# This script handles both layouts.
set -euo pipefail

WORKDIR="${WORKDIR:-/tmp/cursor-build}"
OUTDIR="${OUTDIR:-$WORKDIR/out}"

mkdir -p "$WORKDIR" "$OUTDIR"
cd "$WORKDIR"

# 1. Download latest x86 Cursor AppImage
echo "==> Downloading x86 Cursor AppImage..."
curl -Lo cursor-x86.AppImage \
  "https://api2.cursor.sh/updates/download/golden/linux-x64/cursor/latest"

# 2. Extract (AppImage = ELF header + squashfs, find the squashfs offset)
echo "==> Extracting AppImage..."
rm -rf squashfs-root
OFFSET=$(grep -aobP 'hsqs' cursor-x86.AppImage | tail -1 | cut -d: -f1)
unsquashfs -o "$OFFSET" -d squashfs-root cursor-x86.AppImage

# 3. Detect app root (handles both old and new AppImage layouts)
if [ -f "squashfs-root/usr/share/cursor/resources/app/product.json" ]; then
  APP_ROOT="squashfs-root/usr/share/cursor"
elif [ -f "squashfs-root/resources/app/product.json" ]; then
  APP_ROOT="squashfs-root"
else
  echo "ERROR: Cannot find product.json in extracted AppImage" >&2
  exit 1
fi
echo "==> App root: $APP_ROOT"

# 4. Detect versions
CURSOR_VERSION=$(python3 -c "import json; print(json.load(open('$APP_ROOT/resources/app/product.json'))['version'])")
VSCODE_VERSION=$(python3 -c "import json; print(json.load(open('$APP_ROOT/resources/app/product.json'))['vscodeVersion'])")
echo "==> Cursor $CURSOR_VERSION (VS Code $VSCODE_VERSION)"
echo "$CURSOR_VERSION" > "$OUTDIR/version.txt"

# 5. Download matching VS Code ARM64
echo "==> Downloading VS Code ARM64 $VSCODE_VERSION..."
curl -Lo vscode-arm64.tar.gz \
  "https://update.code.visualstudio.com/${VSCODE_VERSION}/linux-arm64/stable"
rm -rf vscode-arm64
mkdir vscode-arm64
tar xzf vscode-arm64.tar.gz -C vscode-arm64 --strip-components=1

# 6. Graft Cursor's proprietary JS onto VS Code ARM64
echo "==> Grafting Cursor onto VS Code ARM64..."

# Core app code (AI features, UI modifications)
rm -rf vscode-arm64/resources/app/out
cp -R "$APP_ROOT/resources/app/out" vscode-arm64/resources/app/

# Product identity and config
cp "$APP_ROOT/resources/app/"*.json vscode-arm64/resources/app/
cp "$APP_ROOT/resources/app/"*.txt vscode-arm64/resources/app/ 2>/dev/null || true

# Cursor-specific extensions
for ext in "$APP_ROOT/resources/app/extensions/cursor-"* "$APP_ROOT/resources/app/extensions/theme-cursor"; do
  [ -e "$ext" ] && cp -R "$ext" vscode-arm64/resources/app/extensions/
done

# Node modules (both dir and asar may exist in 2.x)
rm -rf vscode-arm64/resources/app/node_modules vscode-arm64/resources/app/node_modules.asar
[ -d "$APP_ROOT/resources/app/node_modules" ] && \
  cp -R "$APP_ROOT/resources/app/node_modules" vscode-arm64/resources/app/
[ -f "$APP_ROOT/resources/app/node_modules.asar" ] && \
  cp "$APP_ROOT/resources/app/node_modules.asar" vscode-arm64/resources/app/

# App resources (icons, etc.)
rm -rf vscode-arm64/resources/app/resources
cp -R "$APP_ROOT/resources/app/resources" vscode-arm64/resources/app/

# 7. Rename binary: code → cursor
echo "==> Renaming binary..."
mv vscode-arm64/code vscode-arm64/cursor 2>/dev/null || true
mv vscode-arm64/bin/code vscode-arm64/bin/cursor 2>/dev/null || true
sed -i 's|ELECTRON="$VSCODE_PATH/code"|ELECTRON="$VSCODE_PATH/cursor"|' vscode-arm64/bin/cursor

# 8. Extract icon
ICON=""
for candidate in "$APP_ROOT/../co.anysphere.cursor.png" "squashfs-root/co.anysphere.cursor.png" "squashfs-root/cursor.png"; do
  [ -f "$candidate" ] && ICON="$candidate" && break
done
[ -n "$ICON" ] && cp "$ICON" "$OUTDIR/cursor.png"

echo "==> Build complete: $WORKDIR/vscode-arm64"
echo "==> Version: $CURSOR_VERSION"
