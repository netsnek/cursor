# Cursor ARM64 — Open-Source Native Build

Unofficial native ARM64 builds of [Cursor](https://cursor.sh), the AI code editor.

Cursor is closed-source and built on VS Code (Electron). All of Cursor's proprietary
code is JavaScript — architecture-independent. The native binaries (Electron, Node.js, V8)
are identical to VS Code's and available for ARM64 as open source.

This repo builds Cursor ARM64 by **grafting Cursor's JS resources onto the open-source
VS Code ARM64 binary**, maximizing the use of open-source components.

## How it works

```
x86 Cursor AppImage           VS Code ARM64 (open source)
┌──────────────────┐          ┌──────────────────────────┐
│ Electron (x86)   │ ←skip   │ Electron (ARM64)    ✓    │
│ Node.js  (x86)   │ ←skip   │ Node.js  (ARM64)    ✓    │
│ V8       (x86)   │ ←skip   │ V8       (ARM64)    ✓    │
│                  │          │                          │
│ resources/app/   │ ←copy→  │ resources/app/      ✓    │
│   out/           │  (JS)   │   out/           (Cursor) │
│   extensions/    │         │   extensions/    (Cursor) │
│   node_modules   │         │   node_modules   (Cursor) │
│   product.json   │         │   product.json   (Cursor) │
└──────────────────┘          └──────────────────────────┘
                                       ↓
                              Cursor ARM64 (native)
```

1. Download x86 Cursor AppImage, extract the squashfs
2. Read `product.json` to find the matching VS Code version
3. Download that exact VS Code ARM64 build (open source)
4. Copy Cursor's JS (`out/`, extensions, node_modules, config) onto VS Code ARM64
5. Rename binary `code` → `cursor`
6. Package as RPM

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

Download the latest `.rpm` from [Releases](https://github.com/netsnek/cursor/releases):

```bash
sudo dnf install cursor-*.aarch64.rpm
```

## Build locally

Requirements: `curl`, `python3`, `squashfs-tools`, `rpm-build`

```bash
./build-cursor-arm64.sh   # graft Cursor JS onto VS Code ARM64
./build-rpm.sh            # package as RPM
sudo dnf install /tmp/cursor-rpm/RPMS/aarch64/cursor-*.rpm
```

## CI/CD

GitHub Actions workflow runs weekly (Monday 06:00 UTC) and on manual dispatch:

1. Checks for new Cursor version
2. Builds ARM64 RPM via the grafting technique
3. Creates a GitHub Release with the RPM
4. Uploads to `rpm.netsnek.com` (Cloudflare R2)

## Prior art

Inspired by [coder/cursor-arm](https://github.com/coder/cursor-arm) (archived Dec 2025),
which used Nix to do the same grafting. This repo uses plain bash + rpmbuild instead.

## License

Build scripts: MIT. Cursor itself is proprietary — see [cursor.sh](https://cursor.sh).
