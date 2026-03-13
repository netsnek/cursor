#!/bin/bash
# Build Cursor ARM64 RPM from the grafted build.
# Expects build-cursor-arm64.sh to have run first.
set -euo pipefail

WORKDIR="${WORKDIR:-/tmp/cursor-build}"
RPMDIR="${RPMDIR:-/tmp/cursor-rpm}"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

CURSOR_VERSION=$(cat "$WORKDIR/out/version.txt")
echo "==> Building RPM for Cursor $CURSOR_VERSION"

# Setup rpmbuild tree
mkdir -p "$RPMDIR"/{BUILD,RPMS,SPECS,SOURCES/staging/{opt/cursor,usr/bin,usr/share/applications,usr/share/pixmaps},SRPMS,BUILDROOT}

# Copy built cursor
cp -a "$WORKDIR/vscode-arm64/." "$RPMDIR/SOURCES/staging/opt/cursor/"

# Symlink, desktop entry, icon
ln -sf /opt/cursor/bin/cursor "$RPMDIR/SOURCES/staging/usr/bin/cursor"
cp "$SCRIPTDIR/cursor.desktop" "$RPMDIR/SOURCES/staging/usr/share/applications/"
cp "$WORKDIR/squashfs-root/cursor.png" "$RPMDIR/SOURCES/staging/usr/share/pixmaps/cursor.png"

# Copy spec
cp "$SCRIPTDIR/cursor.spec" "$RPMDIR/SPECS/"

# Build RPM
rpmbuild \
  --define "_topdir $RPMDIR" \
  --define "cursor_version $CURSOR_VERSION" \
  -bb "$RPMDIR/SPECS/cursor.spec"

RPM_PATH=$(ls "$RPMDIR/RPMS/aarch64"/cursor-*.rpm)
echo "==> RPM built: $RPM_PATH"
echo "$RPM_PATH" > "$WORKDIR/out/rpm-path.txt"
