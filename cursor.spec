Name:           cursor
Version:        %{cursor_version}
Release:        6.fc43
Summary:        Cursor AI Code Editor (ARM64)
License:        Proprietary
URL:            https://cursor.sh
AutoReqProv:    no
ExclusiveArch:  aarch64

%description
Cursor is an AI-powered code editor built on VS Code.
This is an unofficial native ARM64 build created by grafting
Cursor's JavaScript resources onto VS Code ARM64.

Includes cursor-web: loads the desktop workbench (with Cursor AI features)
in a browser via IPC protocol bridge.

%install
cp -a %{_sourcedir}/staging/. %{buildroot}/

%post
echo "To enable Cursor Web with AI features:"
echo "  1. Run: cursor-web"
echo "  2. After first launch, run: /opt/cursor/share/cursor-web/patch-cursor-web.sh"
echo "  3. Reload the browser"

%files
/opt/cursor
/usr/bin/cursor
/usr/bin/cursor-web
/usr/share/applications/cursor.desktop
/usr/share/pixmaps/cursor.png
