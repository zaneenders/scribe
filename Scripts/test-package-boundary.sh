#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift package --package-path "$root" show-dependencies --format json | python3 -c '
import json, sys

def identities(package):
    yield package["identity"]
    for dependency in package["dependencies"]:
        yield from identities(dependency)

packages = set(identities(json.load(sys.stdin)))
assert "chroma" not in packages, packages
assert "swift-profile-recorder" not in packages, packages
'
printf 'PASS: runtime dependency graph excludes desktop dependencies\n'
