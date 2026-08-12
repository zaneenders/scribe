#!/bin/sh
set -eu

version=0.16.0
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root/Vendor/.tools/zig-$version"
archive="$root/Vendor/.tools/zig-$version.tar.xz"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    platform=aarch64-macos
    sha256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
    ;;
  Darwin-x86_64)
    platform=x86_64-macos
    sha256=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
    ;;
  Linux-x86_64)
    platform=x86_64-linux
    sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
    ;;
  Linux-aarch64|Linux-arm64)
    platform=aarch64-linux
    sha256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
    ;;
  *)
    echo "error: Zig bootstrap does not support $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

if [ -x "$destination/zig" ]; then
  installed=$($destination/zig version)
  if [ "$installed" = "$version" ]; then
    echo "Zig $version is already installed at $destination/zig"
    exit 0
  fi
  rm -rf "$destination"
fi

mkdir -p "$root/Vendor/.tools"
url="https://ziglang.org/download/$version/zig-$platform-$version.tar.xz"
echo "Downloading Zig $version for $platform…"
curl --fail --location --retry 3 --output "$archive" "$url"

actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual" != "$sha256" ]; then
  rm -f "$archive"
  echo "error: Zig archive checksum mismatch" >&2
  echo "expected: $sha256" >&2
  echo "actual:   $actual" >&2
  exit 1
fi

staging="$root/Vendor/.tools/zig-$platform-$version"
rm -rf "$staging" "$destination"
tar -xJf "$archive" -C "$root/Vendor/.tools"
mv "$staging" "$destination"
rm -f "$archive"
echo "Installed Zig $version at $destination/zig"
