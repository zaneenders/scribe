# Vendored libghostty-vt

`Libraries/macos/libghostty-vt.a` is a prebuilt universal (x86_64 + arm64)
static library of [libghostty-vt](https://github.com/ghostty-org/ghostty),
the VT parsing and terminal-state core extracted from the Ghostty terminal
emulator. The public C headers are vendored in `Headers/`.

The library was produced from a Ghostty checkout with:

```sh
zig build -Demit-lib-vt -Doptimize=ReleaseFast
```

Zig is only needed to refresh the prebuilt library; building Scribe does not
require it.

## Licenses

libghostty-vt is MIT licensed — see `LICENSE`. The compiled library embeds
[uucode](https://github.com/jacobsandlund/uucode) (MIT), which in turn
contains Björn Höhrmann's DFA-based UTF-8 decoder (MIT) and Unicode character
data (Unicode License V3); those notices live in `licenses/`.
