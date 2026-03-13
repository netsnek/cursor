#!/bin/bash
# Patch the downloaded VS Code web server to load Cursor's desktop workbench
# (with AI features) in the browser via IPC protocol bridge.
# Run after 'cursor serve-web' has downloaded the server at least once.
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
SERVBASE="${HOME}/.vscode/cli/serve-web"

if [ ! -d "$SERVBASE" ]; then
  echo "ERROR: Web server not found. Run 'cursor serve-web' first to download it."
  exit 1
fi

# Find the latest server directory
SERVDIR=$(ls -td "$SERVBASE"/*/out 2>/dev/null | head -1)
SERVDIR="${SERVDIR%/out}"

if [ -z "$SERVDIR" ] || [ ! -d "$SERVDIR/out" ]; then
  echo "ERROR: No server installation found in $SERVBASE"
  exit 1
fi

echo "==> Patching server at: $SERVDIR"

# 0. Backup original files (only once)
if [ ! -d "$SERVDIR/out.bak" ]; then
  echo "==> Creating backup of original files..."
  cp -a "$SERVDIR/out" "$SERVDIR/out.bak"
fi

# 1. Patch product.json with Cursor identity
echo "==> Patching product.json..."
python3 -c "
import json

p = '$SERVDIR/product.json'
d = json.load(open(p))

# Cursor branding
d['nameShort'] = 'Cursor Web'
d['nameLong'] = 'Cursor Web'
d['applicationName'] = 'cursor-web'

# Microsoft Marketplace
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

json.dump(d, open(p, 'w'), indent=2)
"

# 2. Patch PWA manifest
echo "==> Patching PWA manifest..."
MANIFEST="$SERVDIR/resources/server/manifest.json"
if [ -f "$MANIFEST" ]; then
  python3 -c "
import json
m = json.load(open('$MANIFEST'))
m['name'] = 'Cursor Web'
m['short_name'] = 'Cursor'
json.dump(m, open('$MANIFEST', 'w'), indent=2)
"
fi

# 3. Copy Cursor icon if available
CURSOR_ICON="/usr/share/pixmaps/cursor.png"
if [ -f "$CURSOR_ICON" ]; then
  for size in 192 512; do
    target="$SERVDIR/resources/server/code-${size}.png"
    [ -f "$target" ] && cp "$CURSOR_ICON" "$target"
  done
  echo "  Updated icons"
fi

# 4. Install desktop workbench IPC shim
echo "==> Installing desktop workbench IPC shim..."
SHIM_SRC="$SCRIPTDIR/workbench-desktop-shim.js"
SHIM_DST="$SERVDIR/out/vs/code/browser/workbench/workbench-desktop-shim.js"
if [ -f "$SHIM_SRC" ]; then
  cp "$SHIM_SRC" "$SHIM_DST"
  echo "  Installed: workbench-desktop-shim.js"
else
  echo "  WARNING: workbench-desktop-shim.js not found at $SHIM_SRC"
fi

# 5. Patch workbench.html to load desktop CSS and shim
echo "==> Patching workbench.html..."
WB_HTML="$SERVDIR/out/vs/code/browser/workbench/workbench.html"
python3 -c "
html = open('$WB_HTML').read()

# Replace web CSS with desktop CSS
html = html.replace(
    'workbench/workbench.web.main.css',
    'workbench/workbench.desktop.main.css'
)

# Replace web workbench loader with desktop shim
html = html.replace(
    'workbench/workbench.js',
    'workbench/workbench-desktop-shim.js'
)

open('$WB_HTML', 'w').write(html)
"

# 6. Restore server NLS messages (desktop NLS has fewer entries)
echo "==> Restoring server NLS messages..."
if [ -d "$SERVDIR/out.bak" ]; then
  for f in nls.messages.js nls.messages.json; do
    if [ -f "$SERVDIR/out.bak/$f" ]; then
      cp "$SERVDIR/out.bak/$f" "$SERVDIR/out/$f"
    fi
  done
  echo "  NLS messages restored from backup"
fi

# 7. Patch VSBuffer.wrap to handle ArrayBuffer from MessagePort
echo "==> Patching VSBuffer.wrap for MessagePort compatibility..."
DESKTOP_JS="$SERVDIR/out/vs/workbench/workbench.desktop.main.js"
if [ -f "$DESKTOP_JS" ]; then
  # Add ArrayBuffer→Uint8Array conversion before the Buffer.isBuffer check
  python3 -c "
import re
js = open('$DESKTOP_JS').read()
# Find: static wrap(e){return uFn&&!Buffer.isBuffer(e)
# Replace with: static wrap(e){return e instanceof ArrayBuffer&&(e=new Uint8Array(e)),uFn&&!Buffer.isBuffer(e)
old = 'static wrap(e){return uFn&&!Buffer.isBuffer(e)'
new = 'static wrap(e){return e instanceof ArrayBuffer&&(e=new Uint8Array(e)),uFn&&!Buffer.isBuffer(e)'
if old in js:
    js = js.replace(old, new, 1)
    open('$DESKTOP_JS', 'w').write(js)
    print('  VSBuffer.wrap patched')
elif new in js:
    print('  VSBuffer.wrap already patched')
else:
    print('  WARNING: VSBuffer.wrap pattern not found')
"
fi

# 8. Copy ALL Cursor extensions
echo "==> Installing Cursor extensions..."
CURSOR_EXTS="/opt/cursor/resources/app/extensions"
SERV_EXTS="$SERVDIR/extensions"
if [ -d "$CURSOR_EXTS" ]; then
  for ext in "$CURSOR_EXTS"/cursor-*/ "$CURSOR_EXTS"/theme-cursor/; do
    if [ -d "$ext" ]; then
      extname=$(basename "$ext")
      cp -R "$ext" "$SERV_EXTS/" 2>/dev/null && echo "  Installed: $extname" || true
    fi
  done
fi

# 9. Seed auth tokens from desktop Cursor
echo "==> Seeding auth tokens from desktop Cursor..."
CURSOR_DB="${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
AUTH_SEED="$SERVDIR/out/vs/code/browser/workbench/cursor-auth-seed.json"
if [ -f "$CURSOR_DB" ]; then
  python3 -c "
import sqlite3, json
db = sqlite3.connect('$CURSOR_DB')
tokens = {}
for key, value in db.execute(\"SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth%' OR key LIKE 'cursorai/%' OR key LIKE 'cursor/%' OR key LIKE 'cursor.%' OR key LIKE 'telemetry.%'\"):
    tokens[key] = value
db.close()
if tokens:
    json.dump(tokens, open('$AUTH_SEED', 'w'))
    auth_keys = [k for k in tokens if k.startswith('cursorAuth')]
    print('  Auth tokens seeded: ' + ', '.join(auth_keys))
    print('  Total keys seeded: ' + str(len(tokens)))
else:
    print('  WARNING: No auth tokens found in desktop Cursor DB')
"
else
  echo "  WARNING: Desktop Cursor DB not found at $CURSOR_DB"
  echo "  Login will not work without auth tokens."
fi

echo "==> Cursor Web patched successfully!"
echo "    Start with: cursor-web"
