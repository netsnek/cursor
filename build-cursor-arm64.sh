#!/bin/bash
# Build Cursor ARM64 by grafting Cursor's JS resources onto VS Code ARM64.
# Cursor is a closed-source VS Code fork — all proprietary code is JS (arch-independent).
# Native binaries (Electron, Node) come from VS Code ARM64.
set -euo pipefail

WORKDIR="${WORKDIR:-/tmp/cursor-build}"
OUTDIR="${OUTDIR:-$WORKDIR/out}"

mkdir -p "$WORKDIR" "$OUTDIR"
cd "$WORKDIR"

# 1. Download latest x86 Cursor AppImage
echo "==> Downloading x86 Cursor AppImage..."
curl -Lo cursor-x86.AppImage \
  "https://dl.todesktop.com/230313mzl4w4u92/linux/appImage/x64"

# 2. Extract (AppImage = ELF header + squashfs, find the squashfs offset)
echo "==> Extracting AppImage..."
rm -rf squashfs-root
OFFSET=$(grep -aobP 'hsqs' cursor-x86.AppImage | tail -1 | cut -d: -f1)
unsquashfs -o "$OFFSET" -d squashfs-root cursor-x86.AppImage

# 3. Detect versions
CURSOR_VERSION=$(python3 -c "import json; print(json.load(open('squashfs-root/resources/app/product.json'))['version'])")
VSCODE_VERSION=$(python3 -c "import json; print(json.load(open('squashfs-root/resources/app/product.json'))['vscodeVersion'])")
echo "==> Cursor $CURSOR_VERSION (VS Code $VSCODE_VERSION)"
echo "$CURSOR_VERSION" > "$OUTDIR/version.txt"

# 4. Download matching VS Code ARM64
echo "==> Downloading VS Code ARM64 $VSCODE_VERSION..."
curl -Lo vscode-arm64.tar.gz \
  "https://update.code.visualstudio.com/${VSCODE_VERSION}/linux-arm64/stable"
rm -rf vscode-arm64
mkdir vscode-arm64
tar xzf vscode-arm64.tar.gz -C vscode-arm64 --strip-components=1

# 5. Graft Cursor files onto VS Code ARM64
echo "==> Grafting Cursor onto VS Code ARM64..."
cp -R squashfs-root/resources/app/out vscode-arm64/resources/app/
cp squashfs-root/resources/app/*.json vscode-arm64/resources/app/
cp -R squashfs-root/resources/app/extensions/cursor-* vscode-arm64/resources/app/extensions/
rm -rf vscode-arm64/resources/app/node_modules vscode-arm64/resources/app/node_modules.asar
if [ -d squashfs-root/resources/app/node_modules ]; then
  cp -R squashfs-root/resources/app/node_modules vscode-arm64/resources/app/
elif [ -f squashfs-root/resources/app/node_modules.asar ]; then
  cp squashfs-root/resources/app/node_modules.asar vscode-arm64/resources/app/
fi
rm -rf vscode-arm64/resources/app/resources
cp -R squashfs-root/resources/app/resources vscode-arm64/resources/app/

# 6. Branding
cp squashfs-root/cursor.png vscode-arm64/ 2>/dev/null || true
cp squashfs-root/cursor.desktop vscode-arm64/ 2>/dev/null || true
cp -R squashfs-root/resources/todesktop* vscode-arm64/resources/ 2>/dev/null || true

# 7. Rename binary
mv vscode-arm64/code vscode-arm64/cursor 2>/dev/null || true
mv vscode-arm64/bin/code vscode-arm64/bin/cursor 2>/dev/null || true
# Fix bin wrapper to reference 'cursor' instead of 'code'
sed -i 's|ELECTRON="$VSCODE_PATH/code"|ELECTRON="$VSCODE_PATH/cursor"|' vscode-arm64/bin/cursor

echo "==> Build complete: $WORKDIR/vscode-arm64"
echo "==> Version: $CURSOR_VERSION"
