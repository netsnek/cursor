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

# Statsig feature flags (needed for model loading)
d['statsigClientKey'] = 'client-Bm4HJ0aDjXHQVsoACMREyLNxm5p6zzuzhO50MgtoT5D'

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

# 3. Copy Cursor icons and logos
CURSOR_ICON="/usr/share/pixmaps/cursor.png"
if [ -f "$CURSOR_ICON" ]; then
  for size in 192 512; do
    target="$SERVDIR/resources/server/code-${size}.png"
    [ -f "$target" ] && cp "$CURSOR_ICON" "$target"
  done
  echo "  Updated PWA icons"
fi

# Copy Cursor-specific media files (logos, brand assets) from desktop app
CURSOR_OUT="/opt/cursor/resources/app/out"
if [ -d "$CURSOR_OUT" ]; then
  for f in \
    media/agents-toggle-filled.svg \
    media/agents-toggle-outline.svg \
    media/codicon.ttf \
    media/cursor-icons-outline.woff2 \
    media/jetbrains-mono-regular.ttf \
    media/logo.png \
    vs/workbench/browser/parts/editor/media/lockup-horizontal-dark.png \
    vs/workbench/browser/parts/editor/media/lockup-horizontal-light.png \
    vs/workbench/browser/parts/editor/media/back-tb.png \
    vs/workbench/browser/parts/editor/media/forward-tb.png \
    vs/workbench/browser/parts/editor/media/logo.png \
    vs/workbench/services/extensionManagement/common/media/defaultIcon.png \
    ; do
    if [ -f "$CURSOR_OUT/$f" ]; then
      mkdir -p "$SERVDIR/out/$(dirname "$f")"
      cp "$CURSOR_OUT/$f" "$SERVDIR/out/$f"
    fi
  done
  echo "  Copied Cursor logos and media"
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

# Add desktop CSS (contains Tailwind v4 runtime + Cursor-specific styles)
# The HTML has workbench.css (not workbench.web.main.css), so replace doesn't work.
# Instead, add a second <link> for the desktop CSS.
html = html.replace(
    'workbench/workbench.web.main.css',
    'workbench/workbench.desktop.main.css'
)
desktop_css_link = '<link rel=\"stylesheet\" href=\"{{WORKBENCH_WEB_BASE_URL}}/out/vs/workbench/workbench.desktop.main.css\">'
if 'workbench.desktop.main.css' not in html:
    html = html.replace(
        '</head>',
        '\t' + desktop_css_link + '\n\t</head>'
    )

# Replace web workbench loader with desktop shim
html = html.replace(
    'workbench/workbench.js',
    'workbench/workbench-desktop-shim.js'
)

# Add <base> tag so relative URLs in the desktop workbench JS resolve
# to the correct static file path on the serve-web server.
# The server replaces {{WORKBENCH_WEB_BASE_URL}} at runtime.
if '<base ' not in html:
    html = html.replace(
        '<meta charset=\"utf-8\" />',
        '<meta charset=\"utf-8\" />\n\t\t<base href=\"{{WORKBENCH_WEB_BASE_URL}}/out/vs/code/browser/workbench/\" />'
    )

open('$WB_HTML', 'w').write(html)
"

# 6. Install desktop NLS messages for browser only
# IMPORTANT: Do NOT overwrite nls.messages.json — server-side Node.js processes
# (extensionHostProcess.js etc.) need the SERVER's NLS indices. Desktop NLS has
# different indices and will crash the extension host with "NLS MISSING" errors.
# We only generate nls.messages.js (loaded by the browser via <script> tag).
echo "==> Installing desktop NLS messages (browser-only)..."
CURSOR_NLS="/opt/cursor/resources/app/out/nls.messages.json"
if [ -f "$CURSOR_NLS" ]; then
  # Generate the JS wrapper that sets globalThis._VSCODE_NLS_MESSAGES
  # This is loaded by workbench.html in the browser, not by server-side Node.js
  python3 -c "
nls = open('$CURSOR_NLS').read().strip()
js = '''/*---------------------------------------------------------
 * Copyright (C) Microsoft Corporation. All rights reserved.
 *--------------------------------------------------------*/
globalThis._VSCODE_NLS_MESSAGES=''' + nls + ';'
open('$SERVDIR/out/nls.messages.js', 'w').write(js)
"
  echo "  Desktop NLS JS wrapper installed ($(wc -c < "$CURSOR_NLS") bytes)"
  echo "  Server nls.messages.json preserved for extension host"

  # Also save desktop NLS as separate file for the extension host
  cp "$CURSOR_NLS" "$SERVDIR/out/nls.messages.desktop.json"
  echo "  Desktop NLS saved as nls.messages.desktop.json for extension host"
else
  echo "  WARNING: Desktop NLS not found at $CURSOR_NLS"
  echo "  UI strings will be garbled. Install the cursor package first."
fi

# 6b. Install Cursor's extension host (has AI connect transport infrastructure)
echo "==> Installing Cursor extension host..."
CURSOR_EXTHOST="/opt/cursor/resources/app/out/vs/workbench/api/node/extensionHostProcess.js"
SERV_EXTHOST="$SERVDIR/out/vs/workbench/api/node/extensionHostProcess.js"
if [ -f "$CURSOR_EXTHOST" ]; then
  if [ ! -f "$SERV_EXTHOST.server-bak" ]; then
    cp "$SERV_EXTHOST" "$SERV_EXTHOST.server-bak"
  fi
  cp "$CURSOR_EXTHOST" "$SERV_EXTHOST"
  echo "  Cursor extension host installed ($(wc -c < "$CURSOR_EXTHOST") bytes)"
  echo "  Server original backed up as .server-bak"
else
  echo "  WARNING: Cursor extension host not found at $CURSOR_EXTHOST"
fi

# 6c. Patch bootstrap-fork.js to use desktop NLS for extension host
# The server and extension host share bootstrap-fork.js but need different NLS indices.
# Server processes use server NLS (nls.messages.json), extension host needs desktop NLS.
echo "==> Patching bootstrap-fork.js for dual NLS..."
python3 -c "
js = open('$SERVDIR/out/bootstrap-fork.js').read()
old = 'e?.defaultMessagesFile&&(r=e.defaultMessagesFile),globalThis._VSCODE_NLS_LANGUAGE=e?.resolvedLanguage'
patch = ';if(r&&process.env.VSCODE_ESM_ENTRYPOINT&&process.env.VSCODE_ESM_ENTRYPOINT.includes(\"extensionHostProcess\")){let _dr=r.replace(\"nls.messages.json\",\"nls.messages.desktop.json\");try{I(\"node:fs\").accessSync(_dr);r=_dr}catch{}}'
if old in js and '_dr=' not in js:
    js = js.replace(old, old + patch, 1)
    open('$SERVDIR/out/bootstrap-fork.js', 'w').write(js)
    print('  bootstrap-fork.js patched for dual NLS')
elif '_dr=' in js:
    print('  bootstrap-fork.js already patched')
else:
    print('  WARNING: bootstrap-fork.js NLS pattern not found')
"

# 7. Patch desktop workbench JS (VSBuffer, Statsig, isolation, marketplace)
echo "==> Patching desktop workbench JS..."
DESKTOP_JS="$SERVDIR/out/vs/workbench/workbench.desktop.main.js"
if [ -f "$DESKTOP_JS" ]; then
  # Apply all desktop workbench JS patches in a single Python script using heredoc
  # (heredoc avoids bash history expansion mangling '!' in JS patterns)
  python3 - "$DESKTOP_JS" << 'PATCH_DESKTOP_EOF'
import sys
f = sys.argv[1]
js = open(f).read()
changed = False

# 7a. VSBuffer.wrap: ArrayBuffer→Uint8Array conversion for MessagePort
old = 'static wrap(e){return uFn&&!Buffer.isBuffer(e)'
new = 'static wrap(e){return e instanceof ArrayBuffer&&(e=new Uint8Array(e)),uFn&&!Buffer.isBuffer(e)'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  VSBuffer.wrap patched')
elif new in js:
    print('  VSBuffer.wrap already patched')
else:
    print('  WARNING: VSBuffer.wrap pattern not found')

# 7b. Statsig SDK URLs (needed for model loading)
old_sg = '[Sme._initialize]:"https://",[Sme._download_config_specs]:"https://"'
new_sg = '[Sme._initialize]:"https://api.statsigcdn.com/v1",[Sme._download_config_specs]:"https://featureassets.org/v1"'
if old_sg in js:
    js = js.replace(old_sg, new_sg, 1)
    changed = True
    print('  Statsig SDK URLs restored')
elif new_sg in js:
    print('  Statsig SDK URLs already present')
else:
    print('  NOTE: Statsig URL pattern not found (may not need patching)')

# 7c. Disable extension isolation (cursor-agent-exec needs single ext host)
old = 'this._isolationEnabled=r&&!s'
new = 'this._isolationEnabled=!1'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  Extension isolation disabled')
elif new in js:
    print('  Extension isolation already disabled')
else:
    print('  NOTE: Isolation pattern not found')

# 7d. rc(): fully safe extension ID comparison for marketplace control manifest
old = 'function rc(n,e){return n.uuid&&e.uuid?n.uuid===e.uuid:n.id===e.id?!0:Ebe(n.id,e.id)===0}'
new = 'function rc(n,e){if(!e)return!1;if(typeof e==="string")return Ebe(n.id,e)===0;if(!e.id&&!e.uuid)return!1;return n.uuid&&e.uuid?n.uuid===e.uuid:n.id===e.id?!0:e.id?Ebe(n.id,e.id)===0:!1}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  rc() patched (fully safe)')
elif '!e)return!1;if(typeof e==="string")' in js:
    print('  rc() already patched')
else:
    print('  NOTE: rc() pattern not found')

# 7e. yau(): handle string entries and non-array input from marketplace
old = 'function yau(n,e){return e.some(t=>Qo(t)?Ebe(n.id.split(".")[0],t)===0:rc(n,t))}'
new = 'function yau(n,e){if(!Array.isArray(e))return!1;return e.some(t=>{if(!t)return!1;if(typeof t==="string")return Ebe(n.id,t)===0||Ebe(n.id.split(".")[0],t)===0;return rc(n,t)})}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  yau() patched for safe marketplace handling')
elif 'Array.isArray(e))return!1' in js:
    print('  yau() already patched')
else:
    print('  NOTE: yau() pattern not found')

# 7f. _otherTips + _importantTips: fallback to [] when extensionTipsService returns undefined
old = 'this._otherTips=await this.extensionTipsService.getOtherExecutableBasedTips()'
new = 'this._otherTips=await this.extensionTipsService.getOtherExecutableBasedTips()??[]'
if old in js and '??[]' not in js[js.find(old):js.find(old)+len(old)+5]:
    js = js.replace(old, new, 1)
    changed = True
    print('  _otherTips fallback patched')

old = 'this._importantTips=await this.extensionTipsService.getImportantExecutableBasedTips(),this._importantTips.forEach'
new = 'this._importantTips=await this.extensionTipsService.getImportantExecutableBasedTips()??[],this._importantTips.forEach'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  _importantTips fallback patched')
elif '??[],' in js and 'getImportantExecutableBasedTips' in js:
    print('  _importantTips already patched')
else:
    print('  NOTE: _importantTips pattern not found')

# 7g. Ebe(): null-safe string comparison (prevents crashes when extension IDs are undefined)
old = 'function Ebe(n,e){return sFn(n,e,0,n.length,0,e.length)}'
new = 'function Ebe(n,e){if(!n||!e)return n===e?0:n?1:-1;return sFn(n,e,0,n.length,0,e.length)}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  Ebe() made null-safe')
elif 'if(!n||!e)return n===e' in js:
    print('  Ebe() already patched')
else:
    print('  NOTE: Ebe() pattern not found')

# 7h. userHome: fallback when native paths object is unavailable (browser context)
old = 'get userHome(){return je.file(this.paths.homeDir)}'
new = 'get userHome(){return je.file(this.paths?.homeDir??"/home")}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  userHome fallback patched')
elif 'paths?.homeDir' in js:
    print('  userHome already patched')

# 7i. Resource URLs: use http scheme instead of vscode-remote-resource for browser compat
# CSS @font-face can't be intercepted by fetch shim, so must use real http:// URLs
old = 'scheme:Eu?this._preferredWebSchema:wn.vscodeRemoteResource'
new = 'scheme:this._preferredWebSchema||wn.vscodeRemoteResource'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  Resource URLs use web schema')
elif '_preferredWebSchema||wn.vscodeRemoteResource' in js:
    print('  Resource URLs already patched')

# 7j. b_b(): use vscodeVersion for extension engine compatibility checks only
# Cursor version (2.6.19) fails engines.vscode checks like ^1.101.0
# vscodeVersion (1.105.1) is the actual VS Code API version and passes
# This is targeted to b_b() only — Composer/update checks still see 2.6.19
old = 'function b_b(n,e,t,i=[]){const r=l4u(c4u(t));'
new = 'function b_b(n,e,t,i=[]){n=globalThis._VSCODE_PRODUCT_JSON?.vscodeVersion||n;const r=l4u(c4u(t));'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  b_b(): uses vscodeVersion for engine checks')
elif 'vscodeVersion||n;const r=l4u' in js:
    print('  b_b() already patched')

# 7k. webviewExternalEndpoint: use local static URL instead of vscodeWebview:// scheme
old = 'get webviewExternalEndpoint(){return`${wn.vscodeWebview}://{{uuid}}`}'
new = 'get webviewExternalEndpoint(){const q=(globalThis._VSCODE_PRODUCT_JSON?.quality||"stable"),c=(globalThis._VSCODE_PRODUCT_JSON?.commit||"");return window.location.origin+"/"+q+"-"+c+"/static/out/vs/workbench/contrib/webview/browser/pre"}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  webviewExternalEndpoint: local static URL')
elif 'window.location.origin+"/"+q+"-"+c+"/static' in js:
    print('  webviewExternalEndpoint already patched')

# 7l. Desktop webviewContentEndpoint: use web version approach (env service)
# The desktop class returns vscodeWebview:// which doesn't work in browser
old = 'webviewContentEndpoint(e){return`${wn.vscodeWebview}://${e}`}'
new = 'webviewContentEndpoint(e){const q=(globalThis._VSCODE_PRODUCT_JSON?.quality||"stable"),c=(globalThis._VSCODE_PRODUCT_JSON?.commit||"");const t=this._environmentService?.webviewExternalEndpoint||(window.location.origin+"/"+q+"-"+c+"/static/out/vs/workbench/contrib/webview/browser/pre");const i=t.replace("{{uuid}}",e);return i[i.length-1]==="/"?i.slice(0,i.length-1):i}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  Desktop webviewContentEndpoint: browser-safe')
elif 'window.location.origin+"/"+q+"-"+c+"/static' in js and 'webviewContentEndpoint' in js:
    print('  Desktop webviewContentEndpoint already patched')

# 7m. Webview platform: use "browser" instead of "electron" so webview uses postMessage
# The desktop webview class returns platform="electron" which makes the webview iframe
# expect a MessagePort via Electron IPC. In browser, we need postMessage communication.
old = 'get platform(){return"electron"}'
new = 'get platform(){return"browser"}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  Webview platform: browser (not electron)')
elif 'return"browser"' in js and 'get platform' in js:
    print('  Webview platform already patched')

# 7n. argvResource: handle missing dataFolderName
old = 'get argvResource(){const n=c2.VSCODE_PORTABLE;return n?je.file(bS(n,"argv.json")):Fo(this.userHome,this.productService.dataFolderName,"argv.json")}'
new = 'get argvResource(){const n=c2.VSCODE_PORTABLE;return n?je.file(bS(n,"argv.json")):Fo(this.userHome,this.productService.dataFolderName||".cursor","argv.json")}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  argvResource: dataFolderName fallback')
elif 'dataFolderName||".cursor"' in js:
    print('  argvResource already patched')

# 7o. Disable migrate_editor_mode feature gate
# This Statsig gate forces Agent mode on every load, hiding sidebar/activity bar/aux panel.
migr_count = js.count('checkFeatureGate("migrate_editor_mode")')
if migr_count > 0:
    js = js.replace('checkFeatureGate("migrate_editor_mode")', 'checkFeatureGate("_disabled_migrate_editor_mode")')
    changed = True
    print(f'  migrate_editor_mode: disabled ({migr_count} gate checks neutralized)')
elif '_disabled_migrate_editor_mode' in js:
    print('  migrate_editor_mode already disabled')
else:
    print('  NOTE: migrate_editor_mode gate checks not found')

# 7p. Disable onboarding Agent mode force (Ic callback in ide_onboarding_marketplace)
old = 'Ic(()=>{R(M0.Agent),(async()=>(await e.agentLayoutService.enableUnificationMode(),await e.agentLayoutService.setUnifiedSidebarLocation("left"),e.appLayoutService.hasSeenAgentWindowWalkthrough.set(!0,void 0)))()'
new = 'Ic(()=>{e.appLayoutService.hasSeenAgentWindowWalkthrough.set(!0,void 0)'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  onboarding Ic() Agent force disabled')
elif new in js:
    print('  onboarding Ic() already patched')

# 7q-pre0. Disable onboarding render function (it forces Agent mode on completion)
old = 'function vC_(n,e,t,i,r,s,o){return jv(()=>K(bC_,'
new = 'function vC_(n,e,t,i,r,s,o){s&&s();o&&o();return;return jv(()=>K(bC_,'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  vC_ onboarding render: disabled (early return)')
elif new in js:
    print('  vC_ onboarding render already disabled')

# 7q-pre. Disable onboarding walkthrough entirely (it forces Agent mode)
old = 'ide_onboarding_experiment_holdback:{client:!0,default:!1}'
new = 'ide_onboarding_experiment_holdback:{client:!0,default:!0}'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  onboarding holdback: enabled (onboarding disabled)')
elif new in js:
    print('  onboarding holdback already enabled')

# 7q. Disable sC_ onboarding component Agent mode force (vn effect)
old = 'H?M?(g(M0.Agent),(async()=>(await e.agentLayoutService.enableUnificationMode(),await e.agentLayoutService.setUnifiedSidebarLocation("left"),e.appLayoutService.hasSeenAgentWindowWalkthrough.set(!0,void 0)))()):e.workbenchLayoutService.setUnifiedMaximizeState(!0):M?(g(M0.Agent),(async()=>(await e.agentLayoutService.enableUnificationMode(),await e.agentLayoutService.setUnifiedSidebarLocation("right"),e.appLayoutService.hasSeenAgentWindowWalkthrough.set(!0,void 0)))()):e.workbenchLayoutService.setUnifiedMaximizeState(!1)'
new = 'e.appLayoutService.hasSeenAgentWindowWalkthrough.set(!0,void 0)'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  sC_ onboarding Agent force disabled')
elif new in js and 'sC_' in js:
    print('  sC_ onboarding already patched')

# 7r. Suppress terminal sandbox AppArmor notification (always fires on Linux >= 6.2 without sandbox helper)
old = '!this._rawSandboxSupported&&e?.linuxKernelVersion?this._showSandboxUnsupportedNotification(e.linuxKernelVersion)'
new = '!this._rawSandboxSupported&&e?.linuxKernelVersion?void 0'
if old in js:
    js = js.replace(old, new, 1)
    changed = True
    print('  sandbox AppArmor notification suppressed')
elif new in js:
    print('  sandbox notification already suppressed')

# 7s. Suppress "New update available" notification (auto-update not applicable for serve-web/RPM)
old = 'minor-version-notification-text>New update available'
new = 'minor-version-notification-text>New update available" style="display:none'
if old in js and 'style="display:none' not in js[js.find(old):js.find(old)+200] if old in js else True:
    js = js.replace(old, new, 1)
    changed = True
    print('  update notification suppressed')

# 7t. Keep default Editor layout
# (no change needed — M0.Editor is already the default)

if changed:
    open(f, 'w').write(js)
PATCH_DESKTOP_EOF
fi

# 7g. Patch git extension for missing Cursor API (onDidChangeWorkspaceTrustedFolders)
echo "==> Patching git extension..."
GIT_EXT="$SERVDIR/extensions/git/dist/main.js"
if [ -f "$GIT_EXT" ]; then
  python3 - "$GIT_EXT" << 'PATCH_GIT_EOF'
import sys
f = sys.argv[1]
js = open(f).read()
old = 'K.workspace.onDidChangeWorkspaceTrustedFolders(this.onDidChangeWorkspaceTrustedFolders,this,this.disposables)'
new = 'K.workspace.onDidChangeWorkspaceTrustedFolders&&K.workspace.onDidChangeWorkspaceTrustedFolders(this.onDidChangeWorkspaceTrustedFolders,this,this.disposables)'
if old in js:
    js = js.replace(old, new, 1)
    open(f, 'w').write(js)
    print('  git extension patched: null check for onDidChangeWorkspaceTrustedFolders')
elif '&&K.workspace.onDidChangeWorkspaceTrustedFolders' in js:
    print('  git extension already patched')
else:
    print('  NOTE: git extension pattern not found')
PATCH_GIT_EOF
fi

# 8. Patch server-main.js (CSP, MIME types)
echo "==> Patching server-main.js..."
python3 - "$SERVDIR/out/server-main.js" << 'PATCH_SERVER_EOF'
import sys
f = sys.argv[1]
js = open(f).read()

# 8a. CSP connect-src: same-origin proxy, no external origin needed
old = "connect-src 'self' ws: wss: https:;"
if old in js:
    print('  connect-src: already allows https: (no change needed)')
elif 'connect-src' in js:
    print('  connect-src: non-standard, skipping')

# 8b. CSP font-src: add vscode-remote-resource
old = "font-src 'self' blob:;"
new = "font-src 'self' blob: vscode-remote-resource:;"
if old in js:
    js = js.replace(old, new, 1)
    print('  font-src: added vscode-remote-resource')
elif new in js:
    print('  font-src: already patched')

# 8c. CSP frame-src: add blob: and http: for extension description webviews
old = "frame-src 'self' https://*.vscode-cdn.net data:"
new = "frame-src 'self' https://*.vscode-cdn.net data: blob: http:"
if old in js:
    js = js.replace(old, new, 1)
    print('  frame-src: added blob: http:')
elif new in js:
    print('  frame-src: already patched')

# 8d. U0(): server-side extension engine compatibility check
# Same as b_b() on the client — uses vscodeVersion instead of Cursor version
old = 'function U0(o,t,e,n=[]){let r=ZS(YS(e));'
new = 'function U0(o,t,e,n=[]){o="1.105.1";let r=ZS(YS(e));'
if old in js:
    js = js.replace(old, new, 1)
    print('  U0(): uses vscodeVersion for engine checks')
elif 'o="1.105.1";let r=ZS' in js:
    print('  U0() already patched')

# 8e. MIME types: add .wasm, .ttf, .woff2
old = '".woff":"application/font-woff"'
new = '".wasm":"application/wasm",".ttf":"font/ttf",".woff":"application/font-woff",".woff2":"font/woff2"'
if old in js and '".wasm"' not in js:
    js = js.replace(old, new, 1)
    print('  MIME: added .wasm, .ttf, .woff2')
elif '".wasm"' in js and '".ttf"' not in js:
    old2 = '".wasm":"application/wasm",".woff":"application/font-woff"'
    new2 = '".wasm":"application/wasm",".ttf":"font/ttf",".woff":"application/font-woff",".woff2":"font/woff2"'
    if old2 in js:
        js = js.replace(old2, new2, 1)
        print('  MIME: added .ttf, .woff2')
elif '".ttf"' in js:
    print('  MIME: .ttf/.woff2 already present')

# 8f0. Inject /cors-proxy/ route into server request handler (same-origin, no allowlist)
# URL format: /cors-proxy/<target-host>/path → https://<target-host>/path
# Must go BEFORE the GET-only method check since API calls use POST.
old = 'handleRequest(e,n){if(e.method!=="GET")'
cors_route = r'''handleRequest(e,n){let _u=new URL(e.url||"/",`http://${e.headers.host}`),_p=_u.pathname;if(this._serverBasePath!==void 0&&_p.startsWith(this._serverBasePath)){_p=_p.substring(this._serverBasePath.length);if(_p[0]!=="/")_p="/"+_p}if(_p.startsWith("/cors-proxy/")){const _cp=_p.substring(12),_si=_cp.indexOf("/"),_host=_si>0?_cp.substring(0,_si):_cp,_path=_si>0?_cp.substring(_si):"/";if(e.method==="OPTIONS"){n.writeHead(200,{"access-control-allow-origin":"*","access-control-allow-methods":"GET, POST, PUT, DELETE, OPTIONS","access-control-allow-headers":"*","access-control-max-age":"86400"});n.end();return}const _https=yH("https"),_chunks=[];e.on("data",_c=>_chunks.push(_c));e.on("end",()=>{const _body=Buffer.concat(_chunks),_fh={...e.headers};delete _fh["host"];delete _fh["origin"];delete _fh["referer"];delete _fh["connection"];delete _fh["accept-encoding"];_fh["host"]=_host;const _opts={hostname:_host,port:443,path:_path+(_u.search||""),method:e.method,headers:_fh},_pr=_https.request(_opts,_res=>{const _rh={..._res.headers};_rh["access-control-allow-origin"]="*";_rh["access-control-expose-headers"]="*";delete _rh["access-control-allow-credentials"];n.writeHead(_res.statusCode,_rh);_res.pipe(n)});_pr.on("error",_e=>{n.writeHead(502,{"Content-Type":"text/plain"});n.end("Proxy error: "+_e.message)});if(_body.length>0)_pr.write(_body);_pr.end()});return}if(e.method!=="GET")'''
if old in js and '/cors-proxy/' not in js:
    js = js.replace(old, cors_route, 1)
    print('  CORS proxy route injected at /cors-proxy/')
elif '/cors-proxy/' in js:
    print('  CORS proxy route already present')

open(f, 'w').write(js)
PATCH_SERVER_EOF

# 8f. Patch webview index.html: skip origin hash validation for same-origin (serve-web)
echo "==> Patching webview index.html..."
WEBVIEW_HTML="$SERVDIR/out/vs/workbench/contrib/webview/browser/pre/index.html"
if [ -f "$WEBVIEW_HTML" ]; then
  python3 - "$WEBVIEW_HTML" << 'PATCH_WEBVIEW_EOF'
import sys, hashlib, base64, re
f = sys.argv[1]
html = open(f).read()

# Add same-origin bypass before the hash validation error throw
old = "throw new Error(`Expected '${parentOriginHash}' as hostname or subdomain!`);"
bypass = """// Same-origin webview (serve-web): skip hash validation
\t\t\t\tif (parentOrigin && location.origin === parentOrigin) {
\t\t\t\t\treturn start(parentOrigin);
\t\t\t\t}

\t\t\t\t""" + old

if 'location.origin === parentOrigin' not in html and old in html:
    html = html.replace(old, bypass, 1)
    # Update CSP script hash
    match = re.search(r'<script async type="module">(.*?)</script>', html, re.DOTALL)
    if match:
        digest = hashlib.sha256(match.group(1).encode('utf-8')).digest()
        new_hash = 'sha256-' + base64.b64encode(digest).decode('utf-8')
        html = re.sub(r"sha256-[A-Za-z0-9+/=]+", new_hash, html, count=1)
    open(f, 'w').write(html)
    print('  Webview: same-origin bypass + CSP hash updated')
elif 'location.origin === parentOrigin' in html:
    print('  Webview: already patched')
else:
    print('  WARNING: Webview pattern not found')
PATCH_WEBVIEW_EOF
fi

# 9. Copy ALL Cursor extensions
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

# 9a2. Copy ARM64 native modules from ARM64 AppImage
# The desktop Cursor installation may have x86-64 native modules;
# we need ARM64 versions from the ARM64 AppImage for aarch64 systems.
if [ "$(uname -m)" = "aarch64" ]; then
  ARM64_APPIMAGE="/tmp/cursor-arm64.AppImage"
  ARM64_SQ="/tmp/cursor-arm64-sq"
  if [ ! -d "$ARM64_SQ" ] && [ -f "$ARM64_APPIMAGE" ]; then
    echo "==> Extracting ARM64 AppImage..."
    cd /tmp && chmod +x "$ARM64_APPIMAGE" && ./"$(basename "$ARM64_APPIMAGE")" --appimage-extract 2>/dev/null && mv squashfs-root "$ARM64_SQ"
    cd "$SCRIPTDIR"
  fi
  ARM64_EXTS="$ARM64_SQ/usr/share/cursor/resources/app/extensions"
  if [ -d "$ARM64_EXTS" ]; then
    echo "==> Copying ARM64 native modules for extensions..."
    find "$ARM64_EXTS" -name "*.node" -type f 2>/dev/null | while read f; do
      relpath="${f#$ARM64_EXTS/}"
      target="$SERV_EXTS/$relpath"
      if [ -d "$(dirname "$target")" ]; then
        cp "$f" "$target" 2>/dev/null && echo "  Copied: $relpath"
      fi
    done
  fi
fi

# 9b. Fix extensionKind for Cursor extensions that must run on remote host
# In serve-web, extensions with extensionKind: ["ui"] only run in the browser.
# Cursor extensions with Node.js entry points need extensionKind: ["workspace"]
# to run on the remote extension host where Node.js APIs are available.
echo "==> Fixing Cursor extension kinds for serve-web..."
for ext in "$SERV_EXTS"/cursor-*/package.json; do
  [ -f "$ext" ] || continue
  python3 -c "
import json, sys
p = json.load(open('$ext'))
# If extension has main (Node.js) but no browser entry, force workspace kind
if p.get('main') and not p.get('browser'):
    kind = p.get('extensionKind', [])
    if kind != ['workspace']:
        p['extensionKind'] = ['workspace']
        json.dump(p, open('$ext', 'w'), indent=2)
        print('  Fixed: ' + p['name'] + ' → workspace')
"
done

# 9c. Install electron stub for extensions that import electron
# In serve-web there's no Electron runtime, but some extensions try to require('electron').
echo "==> Installing electron stub for extensions..."
for ext in cursor-always-local cursor-deeplink cursor-socket; do
  STUB_DIR="$SERV_EXTS/$ext/node_modules/electron"
  if [ -d "$SERV_EXTS/$ext" ] && [ ! -f "$STUB_DIR/index.js" ]; then
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/index.js" << 'STUBEOF'
// Stub electron module for serve-web (no Electron available)
module.exports = {
    app: { getPath: () => '/tmp', getName: () => 'cursor-web', getVersion: () => '0.0.0', on: () => {}, isReady: () => true, whenReady: () => Promise.resolve() },
    net: { request: () => { throw new Error('electron.net not available'); } },
    safeStorage: { isEncryptionAvailable: () => false, encryptString: (s) => Buffer.from(s), decryptString: (b) => b.toString() },
    ipcRenderer: { on: () => {}, send: () => {}, invoke: () => Promise.resolve() },
    shell: { openExternal: () => Promise.resolve() },
    BrowserWindow: class { constructor() {} },
};
STUBEOF
    echo '{"name":"electron","version":"0.0.0","main":"index.js"}' > "$STUB_DIR/package.json"
    echo "  Installed electron stub: $ext"
  fi
done

# 10. Seed auth tokens from desktop Cursor
echo "==> Seeding auth tokens from desktop Cursor..."
CURSOR_DB="${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
AUTH_SEED="$SERVDIR/out/vs/code/browser/workbench/cursor-auth-seed.json"
if [ -f "$CURSOR_DB" ]; then
  python3 -c "
import sqlite3, json
db = sqlite3.connect('$CURSOR_DB')
tokens = {}
for key, value in db.execute(\"SELECT key, value FROM ItemTable WHERE key LIKE 'cursorAuth%' OR key LIKE 'cursorai/%' OR key LIKE 'telemetry.%'\"):
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
