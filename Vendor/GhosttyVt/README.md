# Vendored libghostty-vt interface

Scribe pins Ghostty source as the Git submodule at `Vendor/GhosttySource` and
generates the platform static library locally. Generated archives are ignored
by Git; the small public C headers, module map, and third-party notices remain
committed so API and license changes are reviewable.

Normal incremental builds never invoke Zig. They only run a cheap presence
check and use the previously generated archive.

## First build after cloning

```sh
git submodule update --init --recursive
./Scripts/bootstrap-zig.sh

swift package \
  --allow-writing-to-package-directory \
  refresh-ghostty-vt

swift build
```

Current upstream Ghostty requires Zig 0.16.0 or newer. The bootstrap script
downloads the official archive, verifies its SHA-256 checksum, and installs it
under `Vendor/.tools`; it does not modify the global toolchain. An existing Zig
0.16.0+ on `PATH` also works. On macOS, `lipo` from Xcode command-line tools is
required.

If the generated archive is missing, `swift build` stops early and prints the
same bootstrap command instead of an opaque linker error.

## Updating Ghostty

Move the submodule to the reviewed upstream commit, stage its gitlink, then
regenerate:

```sh
git -C Vendor/GhosttySource fetch origin
git -C Vendor/GhosttySource checkout <reviewed-commit>
git add Vendor/GhosttySource

swift package \
  --allow-writing-to-package-directory \
  refresh-ghostty-vt
```

The refresh command warns when the submodule differs from the revision recorded
in `Plugins/GhosttyVtRefreshPlugin/plugin.swift`; update that revision only
after reviewing C API and license changes.

## What the refresh command does

1. verifies Zig and records the submodule revision;
2. runs `zig build -Demit-lib-vt=true -Doptimize=ReleaseFast`;
3. on macOS, builds `aarch64-macos` and `x86_64-macos` separately and combines
   them into `Libraries/macos/libghostty-vt.a` with `lipo`;
4. on Linux, creates `Libraries/linux/libghostty-vt.a` as a native PIC archive;
5. refreshes public `ghostty/` headers, regenerates the narrow SwiftPM
   `GhosttyVt` module map, and refreshes Ghostty's license;
6. writes an ignored `PROVENANCE.md` with the revision, Zig version, platform,
   and SHA-256 checksum.

To compile and verify without replacing generated files:

```sh
swift package \
  --allow-writing-to-package-directory \
  refresh-ghostty-vt --dry-run
```

After refreshing, review header changes, audit bundled dependency notices, run
`swift test`, and test the terminal tab.

## Why refresh is not part of every build

Building libghostty-vt on every `swift build` would require Zig everywhere and
would compile Ghostty twice for a universal macOS archive. A one-time/update
command keeps normal builds fast and offline while avoiding generated binaries
in Scribe's Git history.

## Licenses

libghostty-vt is MIT licensed — see `LICENSE`. The compiled library embeds
[uucode](https://github.com/jacobsandlund/uucode) (MIT), which in turn
contains Björn Höhrmann's DFA-based UTF-8 decoder (MIT) and Unicode character
data (Unicode License V3); those notices live in `licenses/`.
