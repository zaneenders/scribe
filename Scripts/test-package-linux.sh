#!/bin/sh
# Exercise packaging and real install/uninstall scripts without a Swift build.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$(uname -s)" != Linux ]; then
  echo 'SKIP: Linux packaging test'
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/build output" "$tmp/repo with spaces"
cp -R "$root/Scripts" "$root/Packaging" "$root/LICENSE" "$tmp/repo with spaces/"
export TEST_BIN_PATH="$tmp/build output" TEST_TRACE="$tmp/trace"
cp /bin/true "$TEST_BIN_PATH/scribe"
cp /bin/true "$TEST_BIN_PATH/scribe-wayland"
cat > "$tmp/bin/swift" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_TRACE"
test "$1" = build
test "$2" = --build-system
test "$3" = "${SWIFT_BUILD_SYSTEM:-native}"
case "$*" in
  *--show-bin-path*) printf '%s\n' "$TEST_BIN_PATH" ;;
  *) test "${8:-}" = --static-swift-stdlib ;;
esac
SH
# Avoid touching desktop/icon caches even within the temporary prefix.
for command in update-desktop-database gtk-update-icon-cache; do
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$command"
done
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" VERSION=test OUTPUT_DIRECTORY="$tmp/dist" PREFIX="$tmp/install prefix"
unset SCRIBE_CLI_BINARY SCRIBE_WAYLAND_BINARY SWIFT_BUILD_SYSTEM
installer="$tmp/repo with spaces/Scripts/install.sh"
"$installer"
test "$(wc -l < "$TEST_TRACE")" -eq 3
test -x "$PREFIX/bin/scribe"
test -x "$PREFIX/bin/scribe-wayland"
grep -F "Exec=\"$PREFIX/bin/scribe-wayland\"" "$PREFIX/share/applications/com.zaneenders.scribe.desktop"
archive=$(find "$OUTPUT_DIRECTORY" -name '*.tar.gz')
test -f "$archive.sha256"
(cd "$OUTPUT_DIRECTORY" && sha256sum -c "$(basename "$archive").sha256")

# Explicit engine overrides must affect path discovery AND both builds.
: > "$TEST_TRACE"
SWIFT_BUILD_SYSTEM=swiftbuild PREFIX="$tmp/override prefix" "$installer"
test "$(wc -l < "$TEST_TRACE")" -eq 3
test -x "$tmp/override prefix/bin/scribe"

# Packaging prebuilt binaries must not require Swift or install into PREFIX.
: > "$TEST_TRACE"
SCRIBE_CLI_BINARY="$TEST_BIN_PATH/scribe" SCRIBE_WAYLAND_BINARY="$TEST_BIN_PATH/scribe-wayland" \
  PREFIX="$tmp/not installed" "$tmp/repo with spaces/Scripts/package-linux.sh"
test ! -s "$TEST_TRACE"
test ! -e "$tmp/not installed"
printf 'PASS: Linux packaging, static build flags, engine selection, installation, and prebuilt binaries\n'
