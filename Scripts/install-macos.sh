#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repo_root/dist/Scribe.app"
destination="${SCRIBE_INSTALL_PATH:-/Applications/Scribe.app}"
identity="${SCRIBE_CODESIGN_IDENTITY:-}"

if [ -z "$identity" ]; then
  printf '[install] Looking for a stable signing identity...\n'
  identity=$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
      | /usr/bin/head -n 1
  )
fi

if [ -z "$identity" ]; then
  cat >&2 <<'EOF'
error: no Apple Development signing identity was found.
Create one in Xcode (Settings > Accounts > Manage Certificates), or set
SCRIBE_CODESIGN_IDENTITY to another stable code-signing identity.
EOF
  exit 1
fi

cd "$repo_root"
printf '[install] Building macOS products (release)...\n'
swift build -c release
printf '[install] Assembling Scribe.app...\n'
SCRIBE_SKIP_ADHOC_SIGNING=1 \
  swift package --allow-writing-to-package-directory bundle

printf 'Signing Scribe with "%s"...\n' "$identity"
/usr/bin/codesign --force --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

printf '[install] Installing app to %s...\n' "$destination"
/bin/rm -rf "$destination"
/usr/bin/ditto "$app" "$destination"

printf 'Installed %s\n' "$destination"
printf 'Launch it with: open %s\n' "$destination"
