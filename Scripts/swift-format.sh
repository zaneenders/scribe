#!/bin/sh

set -eu

usage() {
  echo "Usage: $0 [format|lint]" >&2
  exit 2
}

mode=${1:-format}
[ "$#" -le 1 ] || usage

case "$mode" in
  format)
    format_arguments="format --in-place"
    ;;
  lint)
    format_arguments="lint --strict"
    ;;
  *)
    usage
    ;;
esac

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

# Ask Git for the project's Swift files instead of recursively walking the
# checkout. Files inside submodules (especially Vendor/GhosttySource) are not
# listed by the parent repository and therefore cannot be modified here.
git ls-files --cached --others --exclude-standard -z -- '*.swift' |
  xargs -0 swift format $format_arguments --parallel
