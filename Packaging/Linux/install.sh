#!/bin/sh
set -eu

package_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${PREFIX:-"$HOME/.local"}
bindirectory="$prefix/bin"
sharedirectory="$prefix/share"
desktopdirectory="$sharedirectory/applications"
icondirectory="$sharedirectory/icons/hicolor/512x512/apps"

for file in \
  "$package_root/bin/scribe" \
  "$package_root/bin/scribe-wayland" \
  "$package_root/share/applications/com.zaneenders.scribe.desktop" \
  "$package_root/share/icons/hicolor/512x512/apps/com.zaneenders.scribe.png"
do
  if [ ! -f "$file" ]; then
    echo "error: package is missing ${file#"$package_root/"}" >&2
    exit 1
  fi
done

mkdir -p "$bindirectory" "$desktopdirectory" "$icondirectory"
install -m 755 "$package_root/bin/scribe" "$bindirectory/scribe"
install -m 755 "$package_root/bin/scribe-wayland" "$bindirectory/scribe-wayland"
install -m 644 \
  "$package_root/share/icons/hicolor/512x512/apps/com.zaneenders.scribe.png" \
  "$icondirectory/com.zaneenders.scribe.png"

# Desktop entries do not expand $HOME and desktop sessions do not always inherit
# the shell PATH, so install an entry containing the absolute executable path.
awk -v executable="$bindirectory/scribe-wayland" '
  {
    marker = "@SCRIBE_WAYLAND_EXEC@"
    position = index($0, marker)
    if (position == 0) {
      print
    } else {
      print substr($0, 1, position - 1) executable substr($0, position + length(marker))
    }
  }
' "$package_root/share/applications/com.zaneenders.scribe.desktop" \
  > "$desktopdirectory/com.zaneenders.scribe.desktop"
chmod 644 "$desktopdirectory/com.zaneenders.scribe.desktop"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$desktopdirectory" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t "$sharedirectory/icons/hicolor" >/dev/null 2>&1 || true
fi

printf 'Installed Scribe to %s\n' "$prefix"
case ":${PATH:-}:" in
  *":$bindirectory:"*) ;;
  *) printf 'Add %s to PATH to run scribe from a terminal.\n' "$bindirectory" ;;
esac
