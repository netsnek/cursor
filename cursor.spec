Name:           cursor
Version:        %{cursor_version}
Release:        1.fc43
Summary:        Cursor AI Code Editor (ARM64)
License:        Proprietary
URL:            https://cursor.sh
AutoReqProv:    no
ExclusiveArch:  aarch64

%description
Cursor is an AI-powered code editor built on VS Code.
This is an unofficial native ARM64 build created by grafting
Cursor's JavaScript resources onto VS Code ARM64.

%install
cp -a %{_sourcedir}/staging/. %{buildroot}/

%files
/opt/cursor
/usr/bin/cursor
/usr/share/applications/cursor.desktop
/usr/share/pixmaps/cursor.png
