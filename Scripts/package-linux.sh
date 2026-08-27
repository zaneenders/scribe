#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

if [ "$(uname -s)" != Linux ]; then
  echo "error: Linux packages must be built on Linux" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64) architecture=x86_64 ;;
  aarch64|arm64) architecture=aarch64 ;;
  *)
    echo "error: unsupported Linux architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

version=${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || printf unknown)}
version=${version#v}
configuration=${CONFIGURATION:-release}
output_directory=${OUTPUT_DIRECTORY:-"$root/dist"}
package_name="scribe-linux-$architecture-$version"
staging="$output_directory/$package_name"
archive="$output_directory/$package_name.tar.gz"

# CI can supply its static-musl CLI artifact. Local packages otherwise build a
# native CLI with a static Swift runtime, just like the graphical executable.
cli_binary=${SCRIBE_CLI_BINARY:-}
wayland_binary=${SCRIBE_WAYLAND_BINARY:-}

# Fail before the lengthy Swift build when a native development package is
# absent. Having a versioned runtime library (for example libcurl.so.4) is not
# enough: the linker and SwiftPM also need the unversioned library and pkg-config
# metadata supplied by the distribution's development package.
if [ -z "$cli_binary" ] || [ -z "$wayland_binary" ]; then
  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "error: pkg-config is required to build the Linux package" >&2
    exit 1
  fi
  missing=
  for module in libcurl; do
    if ! pkg-config --exists "$module"; then
      missing="$missing $module"
    fi
  done
  if [ -z "$wayland_binary" ]; then
    for module in wayland-client wayland-cursor wayland-egl egl glesv2 xkbcommon; do
      if ! pkg-config --exists "$module"; then
        missing="$missing $module"
      fi
    done
  fi
  if [ -n "$missing" ]; then
    echo "error: missing native development modules:$missing" >&2
    echo "Install your distribution's corresponding development packages and retry." >&2
    exit 1
  fi
fi

bin_path=$(swift build -c "$configuration" --show-bin-path)
if [ -z "$cli_binary" ]; then
  swift build -c "$configuration" --product scribe --static-swift-stdlib
  cli_binary="$bin_path/scribe"
fi
if [ -z "$wayland_binary" ]; then
  swift build -c "$configuration" --product scribe-wayland --static-swift-stdlib
  wayland_binary="$bin_path/scribe-wayland"
fi

for binary in "$cli_binary" "$wayland_binary"; do
  if [ ! -x "$binary" ]; then
    echo "error: executable not found: $binary" >&2
    exit 1
  fi
  case "$(file -b "$binary")" in
    ELF*executable*) ;;
    *)
      echo "error: expected a Linux ELF executable: $binary" >&2
      exit 1
      ;;
  esac
done

binary_architecture() {
  case "$(file -b "$1")" in
    *x86-64*) printf x86_64 ;;
    *ARM\ aarch64*) printf aarch64 ;;
    *) printf unknown ;;
  esac
}
for binary in "$cli_binary" "$wayland_binary"; do
  actual=$(binary_architecture "$binary")
  if [ "$actual" != "$architecture" ]; then
    echo "error: $binary is $actual, expected $architecture" >&2
    exit 1
  fi
done

# A distributable build must not depend on Swift shared libraries or retain a
# path into the build machine's toolchain.
if command -v readelf >/dev/null 2>&1; then
  dynamic=$(readelf -d "$wayland_binary" 2>/dev/null || true)
  if printf '%s\n' "$dynamic" | grep -q 'Shared library: \[libswift'; then
    echo "error: scribe-wayland still depends on the Swift shared runtime" >&2
    echo "Build with --static-swift-stdlib and install all native development packages." >&2
    exit 1
  fi
  if printf '%s\n' "$dynamic" | grep -E '(RPATH|RUNPATH).*(\.swiftly|/usr/lib/swift|/opt/swift|/home/)' >/dev/null; then
    echo "error: scribe-wayland contains a build-machine Swift runtime path" >&2
    exit 1
  fi
fi

rm -rf "$staging" "$archive" "$archive.sha256"
mkdir -p \
  "$staging/bin" \
  "$staging/share/applications" \
  "$staging/share/icons/hicolor/512x512/apps"
install -m 755 "$cli_binary" "$staging/bin/scribe"
install -m 755 "$wayland_binary" "$staging/bin/scribe-wayland"
install -m 755 Packaging/Linux/install.sh "$staging/install.sh"
install -m 755 Packaging/Linux/uninstall.sh "$staging/uninstall.sh"
install -m 644 Packaging/Linux/com.zaneenders.scribe.desktop \
  "$staging/share/applications/com.zaneenders.scribe.desktop"
install -m 644 Packaging/Linux/com.zaneenders.scribe.png \
  "$staging/share/icons/hicolor/512x512/apps/com.zaneenders.scribe.png"
install -m 644 LICENSE "$staging/LICENSE"

# Exercise installation into an isolated prefix and ensure desktop substitution
# and executable permissions are correct before publishing the archive.
test_prefix="$output_directory/.install-test-$architecture"
rm -rf "$test_prefix"
PREFIX="$test_prefix" "$staging/install.sh" >/dev/null
test -x "$test_prefix/bin/scribe"
test -x "$test_prefix/bin/scribe-wayland"
grep -F "Exec=\"$test_prefix/bin/scribe-wayland\"" \
  "$test_prefix/share/applications/com.zaneenders.scribe.desktop" >/dev/null
PREFIX="$test_prefix" "$staging/uninstall.sh" >/dev/null
test ! -e "$test_prefix/bin/scribe"
rm -rf "$test_prefix"

tar -C "$output_directory" -czf "$archive" "$package_name"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$output_directory" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
else
  (cd "$output_directory" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
fi

printf 'Created %s\n' "$archive"
printf 'Created %s\n' "$archive.sha256"
