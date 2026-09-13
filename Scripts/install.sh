#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: ./Scripts/install.sh [--help]

Build and install Scribe for the current platform using Swift's default build system.

macOS:
  Builds and signs Scribe.app (including the embedded CLI).
  SCRIBE_INSTALL_PATH       App destination (default: /Applications/Scribe.app)
  SCRIBE_CODESIGN_IDENTITY  Stable signing identity (default: first Apple Development identity)

Linux:
  Builds a redistributable archive and installs the CLI and Wayland app.
  PREFIX                   Install prefix (default: ~/.local)
  CONFIGURATION            Swift build configuration (default: release)
  OUTPUT_DIRECTORY         Archive output directory (default: repository dist/)
  VERSION                  Override the archive version
  SCRIBE_CLI_BINARY         Use an existing CLI executable
  SCRIBE_WAYLAND_BINARY     Use an existing Wayland executable

Install prerequisites first; see README.md. This script does not elevate privileges.
EOF
}

case "$#" in
  0) ;;
  1)
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
platform=$(uname -s)
case "$platform" in
  Darwin) exec "$script_directory/install-macos.sh" ;;
  Linux) exec "$script_directory/package-linux.sh" --install ;;
  *)
    printf 'error: unsupported platform: %s (expected macOS or Linux)\n' "$platform" >&2
    exit 1
    ;;
esac
