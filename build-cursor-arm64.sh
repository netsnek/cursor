#!/bin/bash
# Build Cursor ARM64 by grafting Cursor's JS resources onto VS Code ARM64.
# Cursor is a closed-source VS Code fork — all proprietary code is JS (arch-independent).
# Native binaries (Electron, Node, .node modules) come from the open-source VS Code ARM64.
#
# IMPORTANT: Cursor's node_modules contain x86 native .node files. After copying,
# we overwrite them with VS Code ARM64's native modules (same ABI, same versions).
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
#    Old (0.x): squashfs-root/resources/app/...
#    New (2.x): squashfs-root/usr/share/cursor/resources/app/...
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
rm -rf vscode-arm64 vscode-arm64-clean
mkdir vscode-arm64-clean
tar xzf vscode-arm64.tar.gz -C vscode-arm64-clean --strip-components=1
# Keep a clean copy for native module extraction
cp -a vscode-arm64-clean vscode-arm64

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

# App resources (icons, etc.)
rm -rf vscode-arm64/resources/app/resources
cp -R "$APP_ROOT/resources/app/resources" vscode-arm64/resources/app/

# 7. Handle node_modules: copy Cursor's JS, then fix native modules
echo "==> Copying Cursor node_modules (JS code)..."
rm -rf vscode-arm64/resources/app/node_modules
cp -R "$APP_ROOT/resources/app/node_modules" vscode-arm64/resources/app/

# Copy node_modules.asar if present
[ -f "$APP_ROOT/resources/app/node_modules.asar" ] && \
  cp "$APP_ROOT/resources/app/node_modules.asar" vscode-arm64/resources/app/

# Restore node_modules.asar.unpacked from VS Code ARM64
rm -rf vscode-arm64/resources/app/node_modules.asar.unpacked
[ -d "vscode-arm64-clean/resources/app/node_modules.asar.unpacked" ] && \
  cp -R "vscode-arm64-clean/resources/app/node_modules.asar.unpacked" vscode-arm64/resources/app/

# 8. Replace x86 native .node modules with ARM64 from VS Code
echo "==> Replacing x86 native modules with ARM64..."
find vscode-arm64-clean/resources/app/node_modules -name "*.node" -type f | while read arm64_file; do
  relpath="${arm64_file#vscode-arm64-clean/resources/app/node_modules/}"
  target="vscode-arm64/resources/app/node_modules/$relpath"
  if [ -f "$target" ]; then
    cp "$arm64_file" "$target"
    echo "  replaced: $relpath"
  fi
done

# Handle Cursor-only native modules:
# @anysphere/policy-watcher → same as @vscode/policy-watcher
VSCODE_PW="vscode-arm64-clean/resources/app/node_modules/@vscode/policy-watcher/build/Release/vscode-policy-watcher.node"
CURSOR_PW="vscode-arm64/resources/app/node_modules/@anysphere/policy-watcher/build/Release/vscode-policy-watcher.node"
if [ -f "$VSCODE_PW" ] && [ -f "$CURSOR_PW" ]; then
  cp "$VSCODE_PW" "$CURSOR_PW"
  echo "  replaced: @anysphere/policy-watcher (from @vscode/policy-watcher)"
fi

# cursor-proclist — x86-only, non-critical, remove
PROCLIST="vscode-arm64/resources/app/node_modules/cursor-proclist/build/Release/cursor_proclist.node"
[ -f "$PROCLIST" ] && rm "$PROCLIST" && echo "  removed: cursor-proclist (x86-only, non-critical)"

# 9. Verify no x86 .node files remain in node_modules
echo "==> Verifying architecture..."
X86_COUNT=$(find vscode-arm64/resources/app/node_modules -name "*.node" -type f -exec file {} \; | grep -c "x86-64" || true)
if [ "$X86_COUNT" -gt 0 ]; then
  echo "WARNING: $X86_COUNT x86-64 native modules still present:"
  find vscode-arm64/resources/app/node_modules -name "*.node" -type f -exec file {} \; | grep "x86-64"
else
  echo "  All clean — ARM64 only!"
fi

# 10. Patch product.json: Microsoft Marketplace + disable telemetry + no updates
echo "==> Patching product.json..."
python3 -c "
import json
p = 'vscode-arm64/resources/app/product.json'
d = json.load(open(p))

# Use Microsoft VS Code Marketplace
d['extensionsGallery'] = {
    'nlsBaseUrl': 'https://www.vscode-unpkg.net/_lp/',
    'serviceUrl': 'https://marketplace.visualstudio.com/_apis/public/gallery',
    'itemUrl': 'https://marketplace.visualstudio.com/items',
    'publisherUrl': 'https://marketplace.visualstudio.com/publishers',
    'resourceUrlTemplate': 'https://{publisher}.vscode-unpkg.net/{publisher}/{name}/{version}/{path}',
    'controlUrl': 'https://main.vscode-cdn.net/extensions/marketplace.json',
}

# Disable telemetry
d['enableTelemetry'] = False
d['enabledTelemetryLevels'] = {'error': False, 'usage': False}
d.pop('statsigClientKey', None)
d.pop('statsigLogEventProxyUrl', None)
d.pop('crashReporterId', None)
d.pop('appInsightsConnectionString', None)
d.pop('aiConfig', None)

# Remove auto-update (managed via RPM)
d.pop('updateUrl', None)
d.pop('backupUpdateUrl', None)

json.dump(d, open(p, 'w'), indent=2)
"

# 10b. Privacy: disable git commit attribution
echo "==> Disabling git commit attribution..."
sed -i 's/isAttributionDisabledByAdmin(){return this.getCached().attributionControls?.disableAttribution??!1}/isAttributionDisabledByAdmin(){return !0}/g' \
  vscode-arm64/resources/app/out/vs/workbench/workbench.desktop.main.js

# 10c. Privacy: null out all tracking endpoints in JS bundles
echo "==> Nulling tracking endpoints (Sentry, Statsig, Datadog)..."
for jsfile in \
  vscode-arm64/resources/app/out/vs/workbench/workbench.desktop.main.js \
  vscode-arm64/resources/app/out/vs/workbench/api/node/extensionHostProcess.js \
  vscode-arm64/resources/app/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js \
  vscode-arm64/resources/app/out/main.js; do
  [ -f "$jsfile" ] || continue
  # Sentry DSN
  sed -i 's|https://[a-f0-9]*@o[0-9]*.ingest\.\(us\.\)\?sentry\.io/[0-9]*||g' "$jsfile"
  # Statsig endpoints
  sed -i 's|api\.statsigcdn\.com/v1||g' "$jsfile"
  sed -i 's|featureassets\.org/v1||g' "$jsfile"
  sed -i 's|statsigapi\.net/v1/sdk_exception||g' "$jsfile"
  # Statsig client key
  sed -i 's|client-Bm4HJ0aDjXHQVsoACMREyLNxm5p6zzuzhO50MgtoT5D||g' "$jsfile"
  # Datadog
  sed -i 's|us5\.datadoghq\.com||g' "$jsfile"
  # Cursor's statsig event proxy
  sed -i 's|https://api3\.cursor\.sh/tev1/v1||g' "$jsfile"
done

# 11. Rename binary: code → cursor
echo "==> Renaming binary..."
mv vscode-arm64/code vscode-arm64/cursor 2>/dev/null || true
mv vscode-arm64/bin/code vscode-arm64/bin/cursor 2>/dev/null || true
sed -i 's|ELECTRON="$VSCODE_PATH/code"|ELECTRON="$VSCODE_PATH/cursor"|' vscode-arm64/bin/cursor

# 11. Extract icon
ICON=""
for candidate in "squashfs-root/co.anysphere.cursor.png" "squashfs-root/cursor.png"; do
  [ -f "$candidate" ] && ICON="$candidate" && break
done
[ -n "$ICON" ] && cp "$ICON" "$OUTDIR/cursor.png"

echo "==> Build complete: $WORKDIR/vscode-arm64"
echo "==> Version: $CURSOR_VERSION"
