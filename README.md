# Cursor Server — Full Desktop Workbench in the Browser

Run [Cursor](https://cursor.sh)'s **complete desktop workbench** (with all AI features) in a web browser via `cursor serve-web`, on any architecture including ARM64.

This project solves two problems:
1. **ARM64 native build** — Cursor is x86-only; we graft Cursor's JS onto VS Code ARM64
2. **Browser AI features** — `cursor serve-web` normally serves a limited web workbench; we load the full desktop workbench (Composer, Agent, Chat, CursorTab, model selection) in the browser instead

## How It Works

### The Desktop Workbench in a Browser

Cursor's `serve-web` command launches a VS Code web server, but it only serves the **web workbench** — a stripped-down variant without Cursor's AI features. The AI features (Composer, Agent mode, Chat, CursorTab, model selection) live in the **desktop workbench** (`workbench.desktop.main.js`), which normally runs inside Electron.

This project makes the desktop workbench run in a plain browser by:

1. **IPC Protocol Bridge** (`workbench-desktop-shim.js`) — The desktop workbench communicates with Electron via IPC channels (binary MessagePort protocol). The shim intercepts these and translates them to work over HTTP, implementing the full IPC protocol including varint-based binary serialization matching VS Code's internal `MQ` format.

2. **CORS Proxy** (`cursor-cors-proxy.js`) — The desktop workbench makes fetch/gRPC calls to `api2/api3/api4/api5.cursor.sh` and Statsig endpoints. These are blocked by CORS in the browser. A lightweight Node.js proxy forwards requests with proper CORS headers.

3. **Workbench Patches** (`patch-cursor-web.sh`) — Multiple patches to the desktop workbench JS to make it browser-compatible (see [Patches](#patches) below).

4. **Auth Token Seeding** — Extracts auth tokens from the desktop Cursor SQLite database and seeds them into the browser's localStorage, so you're logged in immediately.

```
┌─────────────────────────────────────────────────────────┐
│  Browser                                                │
│  ┌───────────────────────────────────────────────────┐  │
│  │  workbench.desktop.main.js (full Cursor AI)       │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  workbench-desktop-shim.js (IPC bridge)     │  │  │
│  │  │  - MessagePort ↔ HTTP translation           │  │  │
│  │  │  - Binary protocol (varint MQ serialization)│  │  │
│  │  │  - Storage backed by localStorage           │  │  │
│  │  │  - CORS proxy fetch interception            │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
│         ↕ HTTP/WS              ↕ HTTP (CORS proxy)      │
│  ┌──────────────┐      ┌──────────────────────┐         │
│  │ serve-web    │      │ cursor-cors-proxy.js │         │
│  │ (port 8080)  │      │ (port 9080)          │         │
│  └──────────────┘      └──────────────────────┘         │
│         ↕                       ↕ HTTPS                 │
│  Local filesystem        api[2-5].cursor.sh             │
│  Extension host          statsigcdn.com                 │
│  Remote agent            featureassets.org              │
└─────────────────────────────────────────────────────────┘
```

### IPC Bridge Architecture

The shim implements these IPC channels that the desktop workbench expects:

| Channel | Purpose |
|---------|---------|
| `storage` | Persistent key-value storage (backed by localStorage with `cursor-web-storage:` prefix) |
| `lifecycle` | Window lifecycle events (close, reload) |
| `process` | Process info (PID, cwd, platform, env) |
| `configuration` | Settings read/write via the remote server |
| `auth` | Auth token management (seeded from desktop Cursor) |
| `window` | Window state (maximize, fullscreen) |
| `clipboard` | Clipboard read/write via navigator API |
| `paths` | System paths (home, appData, temp) |
| `vsda` | VS Code license validation (stub) |

Each channel uses VS Code's binary protocol: varint-length-prefixed messages with type tags (Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4, Object=5, Int=6, Uint8Array=7).

### ARM64 Native Build

```
x86 Cursor AppImage           VS Code ARM64 (open source)
┌──────────────────┐         ┌──────────────────────────┐
│ Electron (x86)   │ ←skip   │ Electron (ARM64)    ✓    │
│ Node.js  (x86)   │ ←skip   │ Node.js  (ARM64)    ✓    │
│ V8       (x86)   │ ←skip   │ V8       (ARM64)    ✓    │
│                  │         │                          │
│ resources/app/   │ ←copy→  │ resources/app/      ✓    │
│   out/           │  (JS)   │   out/           (Cursor)│
│   extensions/    │         │   extensions/    (Cursor)│
│   node_modules   │         │   node_modules   (Cursor)│
│   product.json   │         │   product.json   (Cursor)│
└──────────────────┘         └──────────────────────────┘
                                       ↓
                              Cursor ARM64 (native)
```

1. Download x86 Cursor AppImage, extract the squashfs
2. Read `product.json` to find the matching VS Code version
3. Download that exact VS Code ARM64 build (open source)
4. Copy Cursor's JS (`out/`, extensions, node_modules, config) onto VS Code ARM64
5. Replace x86 native `.node` modules with ARM64 versions from Cursor's ARM64 AppImage
6. Replace helper binaries with ARM64 versions
7. Rename binary `code` → `cursor`, package as RPM

## Install

### From RPM repository (Fedora/Asahi Linux)

```bash
sudo tee /etc/yum.repos.d/netsnek.repo << 'EOF'
[netsnek]
name=Netsnek Custom Packages for Asahi Linux
baseurl=https://rpm.netsnek.com/
enabled=1
gpgcheck=0
metadata_expire=300
EOF

sudo dnf install cursor
```

### From GitHub Release

Download the latest `.rpm` from [Releases](https://github.com/netsnek/cursor-server/releases):

```bash
sudo dnf install cursor-*.aarch64.rpm
```

## Usage

### Desktop Application (ARM64)

```bash
cursor                    # Launch Cursor desktop
cursor /path/to/project   # Open a project
```

### Browser Workbench (cursor-web)

```bash
# First launch — downloads the serve-web server:
cursor serve-web --port 8080

# Apply patches (required once after each Cursor update):
/opt/cursor/share/cursor-web/patch-cursor-web.sh

# Start with launcher script (includes CORS proxy):
cursor-web [port] [cors-port]
cursor-web 8080 9080      # defaults
```

Then open the URL shown in the terminal (includes `?cors_port=` parameter). The full desktop workbench loads with all Cursor AI features:
- **Composer** — multi-file AI editing
- **Agent mode** — autonomous coding agent
- **Chat** — AI chat panel
- **CursorTab** — AI autocomplete
- **Model selection** — choose between Claude, GPT-4, etc.

Open a specific folder: `http://localhost:8080/?cors_port=9080&folder=/path/to/project`

Install as a PWA via your browser's "Install" menu for a native app experience.

## Patches

The patch script (`patch-cursor-web.sh`) applies these modifications to make the desktop workbench work in a browser:

### Product & Branding
- **product.json** — Cursor branding, Microsoft VS Code Marketplace, Statsig client key, disable telemetry
- **PWA manifest** — Cursor name and icons
- **Cursor logos/media** — Copy brand assets from desktop installation

### Workbench HTML
- **CSS** — Load `workbench.desktop.main.css` instead of web CSS
- **JS loader** — Load `workbench-desktop-shim.js` instead of `workbench.js`
- **Base URL** — Add `<base>` tag for correct static file resolution

### NLS (Localization)
- **Desktop NLS** — Install desktop NLS strings as browser-only JS wrapper (`nls.messages.js`)
- **Dual NLS** — Patch `bootstrap-fork.js` so server processes use server NLS while the extension host uses desktop NLS (different message indices)

### Extension Host
- **Cursor extension host** — Replace server's extension host with Cursor's (has AI transport infrastructure)

### Desktop Workbench JS (`workbench.desktop.main.js`)
| Patch | Description |
|-------|-------------|
| 7a. VSBuffer.wrap | ArrayBuffer→Uint8Array conversion for MessagePort (no Node.js Buffer in browser) |
| 7b. Statsig SDK URLs | Restore feature flag endpoints (needed for model loading) |
| 7c. Extension isolation | Disable isolation (cursor-agent-exec needs single extension host) |
| 7d. rc() | Null-safe extension ID comparison for marketplace control manifest |
| 7e. yau() | Handle string entries and non-array input from marketplace |
| 7f. Extension tips | Fallback to `[]` when `extensionTipsService` returns undefined |
| 7g. Ebe() | Null-safe string comparison (prevents crashes on undefined extension IDs) |
| 7h. userHome | Fallback when native paths object is unavailable in browser |
| 7i. Resource URLs | Use HTTP scheme instead of `vscode-remote-resource://` for CSS @font-face |
| 7j. b_b() | Use `vscodeVersion` for extension engine compatibility (Cursor 2.x fails `^1.x` checks) |
| 7k. webviewExternalEndpoint | Local static URL instead of `vscodeWebview://` scheme |
| 7l. webviewContentEndpoint | Browser-safe webview content URL resolution |
| 7m. Webview platform | Return `"browser"` instead of `"electron"` (use postMessage, not Electron IPC) |
| 7n. argvResource | Handle missing `dataFolderName` with `.cursor` fallback |
| 7o. migrate_editor_mode | Disable Statsig gate that forces Agent mode on every load |
| 7p. Onboarding Ic() | Disable Agent mode force in onboarding callback |
| 7q. Onboarding render | Skip onboarding walkthrough entirely (forces Agent mode on completion) |
| 7r. Sandbox notification | Suppress terminal sandbox AppArmor warning (no sandbox helper in serve-web) |
| 7s. Update notification | Suppress "New update available" banner (auto-update N/A for serve-web/RPM) |

### Server JS (`server-main.js`)
| Patch | Description |
|-------|-------------|
| 8a. CSP connect-src | Add CORS proxy origin (`http://127.0.0.1:9080`) |
| 8b. CSP font-src | Add `vscode-remote-resource:` for font loading |
| 8c. CSP frame-src | Add `blob:` and `http:` for extension webviews |
| 8d. U0() | Server-side engine compat check uses `vscodeVersion` |
| 8e. MIME type | Add `.wasm` → `application/wasm` |
| 8f. Webview index.html | Skip origin hash validation for same-origin serve-web |

### Git Extension
- **onDidChangeWorkspaceTrustedFolders** — Null check for missing Cursor-specific API

### Extension Compatibility
- **extensionKind** — Force Cursor extensions with Node.js entry points to `["workspace"]` (run on remote host, not in browser)
- **Electron stub** — Provide stub `electron` module for extensions that import it

### Auth & Privacy
- **Auth token seeding** — Extract tokens from desktop Cursor SQLite DB
- **Git attribution** — Disabled (`isAttributionDisabledByAdmin` returns true)
- **Sentry/Datadog** — DSN and endpoint strings nulled out
- **Statsig event proxy** — Disabled (feature flags still work for model loading)

## Project Structure

```
├── build-cursor-arm64.sh       # ARM64 build: graft Cursor JS onto VS Code ARM64
├── build-rpm.sh                # Package as RPM
├── cursor.spec                 # RPM spec file
├── cursor.desktop              # Desktop entry file
├── cursor-web.sh               # Launch script (serve-web + CORS proxy)
├── cursor-cors-proxy.js        # CORS proxy for browser API calls
├── workbench-desktop-shim.js   # IPC bridge: desktop workbench ↔ browser
├── patch-cursor-web.sh         # All browser workbench patches
└── .github/
    └── workflows/              # CI/CD: weekly build + deploy
```

## Build Locally

Requirements: `curl`, `python3`, `squashfs-tools`, `rpm-build`

```bash
# Build ARM64 native desktop app
./build-cursor-arm64.sh
./build-rpm.sh
sudo dnf install /tmp/cursor-rpm/RPMS/aarch64/cursor-*.rpm

# Set up browser workbench (after installing the RPM)
cursor serve-web --port 8080          # First run downloads server
/opt/cursor/share/cursor-web/patch-cursor-web.sh   # Apply patches
cursor-web                            # Launch with CORS proxy
```

## CI/CD

GitHub Actions workflow runs weekly (Monday 06:00 UTC) and on manual dispatch:

1. Checks for new Cursor version
2. Builds ARM64 RPM via the grafting technique
3. Creates a GitHub Release with the RPM
4. Uploads to `rpm.netsnek.com` (Cloudflare R2)

## Prior Art

Inspired by [coder/cursor-arm](https://github.com/coder/cursor-arm) (archived Dec 2025),
which used Nix to do the same grafting. This repo uses plain bash + rpmbuild instead.

## License

Build scripts: MIT. Cursor itself is proprietary — see [cursor.sh](https://cursor.sh).
