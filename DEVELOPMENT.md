# Development

## Requirements

Until a 1.0.0 release the project targets the latest Swift version only.

Currently only working on MacOs and Linux support so Windows is not currently
supported but contributions and maintainers for that effort are welcome.

## Branches

Feature branches are scoped with a prefix so work stays isolated until merged.
The prefix comes from the `.dev/` file name — `.dev/api.md` means `api/` branches.

```
api/streaming
scribe/fix-tool-arg-parsing
context/compaction
ui/slash-commands
```

## `.dev` directory

`.dev/` holds the north star for each active effort — a living design doc that
describes the target and evolves alongside implementation. Once shipped, its
content is absorbed into permanent documentation (inline doc comments surfaced
by [Swift DocC][docc], `README.md`, etc.) and the `.dev/` file is removed.

[docc]: https://www.swift.org/documentation/docc/

