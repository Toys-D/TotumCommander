# minizip-ng — vendored source

This directory holds a **vendored copy** of minizip-ng: plain files tracked in this
repository, exactly like `third_party/ntfs-3g`. It is deliberately *not* a git
submodule and no longer contains its own `.git` — a nested checkout meant local
edits were recorded only as `<commit>-dirty` in the parent and never made it into
this project's history.

## Provenance

| | |
|---|---|
| Upstream | https://github.com/zlib-ng/minizip-ng.git |
| Commit | `27cdb50b66ad8bb6295eb9c16514079de4884433` |
| Date | 2026-03-18 |
| Subject | Use python from setup-python action. |

## Local modifications

`mz_zip_rw.c` — honour the progress callback's return value and abort the walk on a
non-`MZ_OK` result, so cancelling an archive operation actually stops it. Without
this the callback's cancel result was ignored and the write ran to completion.

The same change is kept as a standalone diff in
`third_party/patches/minizip-ng-progress-cb.patch`, so it can be re-applied if this
directory is ever refreshed from upstream.

## Updating from upstream

1. Fetch the new upstream tree (e.g. clone it elsewhere and copy the files in,
   keeping this file).
2. Re-apply `third_party/patches/minizip-ng-progress-cb.patch`.
3. Update the commit/date/subject in the table above.
4. Run the archive tests: `cd build && cmake --build . && ctest -R archive`.
