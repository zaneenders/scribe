#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root/scribe-desktop"
# SwiftPM requires an explicit write grant for the app destination on macOS.
if [ "$(uname -s)" = Darwin ]; then
  exec swift package --allow-writing-to-directory "$HOME/Applications" chroma-install "$@"
fi
exec swift package chroma-install "$@"
