# MAC_NTFS

Open-source read/write NTFS support for macOS, built as an **FSKit** filesystem
module (no kernel extension, no reduced-security boot) on top of
[libntfs-3g](https://github.com/tuxera/ntfs-3g).

Licensed under GPLv2 (see `LICENSE`), matching libntfs-3g.

> **Status: Phase 0.** Do not use on drives with data you care about yet.
> All testing happens on disk images.

## Roadmap

| Phase | Goal | Status |
|---|---|---|
| 0 | Build libntfs-3g from source, NTFS test images, verification harness | done |
| 1 | Read-only CLI over libntfs-3g (`ls`, `cat`, `stat`), refuse dirty/hibernated volumes | next |
| 2 | Write support in the CLI (create, write, truncate, rename, delete, mkdir) | |
| 3 | FSKit module + host app; mount read-write in Finder | needs Apple Developer account |
| 4 | Menu-bar app: drive detection, dirty-volume warnings | |

Out of scope for v1: writing compressed files, EFS encryption, ACL editing,
alternate data streams in Finder, BitLocker.

## Requirements

- macOS 26 (FSKit with block-device support needs macOS 15.4+)
- Xcode command-line tools. No Homebrew needed.

## Getting started

```bash
scripts/build-ntfs3g.sh        # fetch (checksum-pinned), build libntfs-3g + tools
scripts/make-test-image.sh     # build/fixtures/basic/basic.img with fixture files
scripts/verify-test-image.sh   # ntfsfix + read back via libntfs-3g AND macOS's NTFS driver
```

`make-test-image.sh [name] [size_mb]` and `verify-test-image.sh [name]` take an
optional fixture name, so you can keep several images side by side.

## Layout

```
scripts/
  build-ntfs3g.sh        build libntfs-3g (static) + ntfsprogs into build/ntfs-3g/prefix
  make-test-image.sh     create a populated NTFS image
  verify-test-image.sh   check an image against its manifest with two independent drivers
  tools/pkg-config       stub so ntfs-3g configures without Homebrew (FUSE/GnuTLS disabled)
third_party/             downloaded source tarballs (gitignored)
build/                   all build output and fixtures (gitignored)
```

## Safety notes

- NTFS volumes that Windows left hibernated or "dirty" (Fast Startup enabled,
  unsafe removal) must never be written. The driver will refuse them.
- Images made with `mkntfs` exercise only what ntfs-3g itself writes. Before
  Phase 3, test against images created on real Windows as well (fragmented files,
  compressed files, deep trees), and check with `chkdsk` after writes.
