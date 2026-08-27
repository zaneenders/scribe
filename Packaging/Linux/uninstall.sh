#!/bin/sh
set -eu

prefix=${PREFIX:-"$HOME/.local"}
sharedirectory="$prefix/share"

rm -f \
  "$prefix/bin/scribe" \
  "$prefix/bin/scribe-wayland" \
  "$sharedirectory/applications/com.zaneenders.scribe.desktop" \
  "$sharedirectory/icons/hicolor/512x512/apps/com.zaneenders.scribe.png"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$sharedirectory/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t "$sharedirectory/icons/hicolor" >/dev/null 2>&1 || true
fi

printf 'Uninstalled Scribe from %s\n' "$prefix"
