#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$repo_root/dist/Scribe.app"
destination="${SCRIBE_INSTALL_PATH:-/Applications/Scribe.app}"
identity="${SCRIBE_CODESIGN_IDENTITY:-}"

if [ -z "$identity" ]; then
  identity=$(
    /usr/bin/security find-identity -v -p codesigning 2>&1 \
      | /usr/bin/sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
      | /usr/bin/head -n 1
  )
fi

if [ -z "$identity" ]; then
  cat >&2 <<'EOF'
error: no Apple Development signing identity was found.
Create one in Xcode (Settings > Accounts > Manage Certificates), or set
SCRIBE_CODESIGN_IDENTITY to another stable code-signing identity.

A stable signature is required for macOS to retain Accessibility and Screen
Recording grants across Scribe rebuilds.
EOF
  exit 1
fi

cd "$repo_root"
swift package --allow-writing-to-package-directory bundle

# The SwiftPM plugin creates an ad-hoc-signed assembly. Re-sign outside the plugin
# sandbox, where codesign can access the user's login keychain.
printf 'Signing Scribe with "%s"...\n' "$identity"
/usr/bin/codesign --force --sign "$identity" "$app/Contents/Helpers/scribe"
/usr/bin/codesign --force --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

/bin/rm -rf "$destination"
/usr/bin/ditto "$app" "$destination"

printf 'Installed %s\n' "$destination"
printf 'Launch it with: open %s\n' "$destination"
