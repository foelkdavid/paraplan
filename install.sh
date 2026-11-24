#!/bin/sh
# Build paraplan and register it with the desktop: binary link in ~/.local/bin,
# icon in the hicolor theme and a .desktop entry for app launchers.
set -e
cd "$(dirname "$0")"
c3c build
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$BIN" "$DATA/applications" "$DATA/icons/hicolor/scalable/apps"
ln -sf "$PWD/build/paraplan" "$BIN/paraplan"
cp assets/paraplan.svg "$DATA/icons/hicolor/scalable/apps/paraplan.svg"
cp assets/paraplan.desktop "$DATA/applications/paraplan.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" || true
# Refresh an existing GTK icon cache (a stale one hides the new icon); never create one.
[ -f "$DATA/icons/hicolor/icon-theme.cache" ] && command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true
echo "installed: $BIN/paraplan, $DATA/applications/paraplan.desktop"
