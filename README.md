# MAC_NTFS

Open-source read/write NTFS for macOS 26, built as an **FSKit** file system
module (no kernel extension, no reduced-security boot) on top of
[libntfs-3g](https://github.com/tuxera/ntfs-3g), plus a small menu-bar app
that remounts NTFS drives read-write on request.

Licensed under GPLv2 (see `LICENSE`), matching libntfs-3g.

> **Status: working end to end on macOS 26.** The signed FSKit module mounts
> NTFS read-write, and file operations through it have been verified on disk
> images (see [Verified through FSKit](#verified-through-fskit)). It hasn't been
> tried on real Windows-formatted drives yet, so use drives whose data you have
> backed up.

## Roadmap

| Phase | What | Status |
|---|---|---|
| 0 | Build libntfs-3g from source; NTFS test images | done |
| 1 | Engine read API + `macntfs` CLI (`info ls stat cat get`) | done, tested |
| 2 | Engine write API + CLI (`put mkdir rm mv truncate touch`) | done, tested |
| 3 | FSKit module (`NTFSModule.appex`) | done, verified through FSKit on images |
| 4 | Menu-bar app: detect drives, remount read-write, Fast Startup warnings | done, verified on images |

## Architecture

```
 Finder / any app
        │  (VFS)
   macOS FSKit ──▶ NTFSModule.appex   fskit/Sources/
                    FileSystem.swift   probe, load (falls back to read-only if unsafe)
                    Volume.swift       FSVolume operations → engine
                    BlockDevice.swift  FSBlockDeviceResource → mn_io
                    Engine.swift       Swift wrapper, one lock per volume
                          │
                    engine/  (C)       mn.h: inode-based API used by everything
                    mn.c               lookup/readdir/read/write/create/rename/...
                    mn_io.c            block-aligned I/O (read-modify-write) + fd backend
                          │
                    libntfs-3g (static, GPLv2)

 MAC_NTFS.app (menu bar)  app/Sources/   DiskArbitration watcher, mount/unmount
 macntfs (CLI)            cli/           same engine, on images or /dev nodes
```

Behaviour worth knowing:

- **Safety:** read-write opens never pass libntfs-3g's override flags. A volume
  that Windows left hibernated, with Fast Startup metadata cached, or with an
  unreplayed journal is mounted **read-only** and the app explains why. Fix it
  in Windows: hold Shift while choosing Shut Down, or turn off Fast Startup.
- **Names behave like Windows:** lookups are case-insensitive and case-preserving.
  `Photo.JPG` and `photo.jpg` can't coexist. Names Windows can't use (`a:b`,
  `CON`, trailing dot or space, ...) are refused. macOS's decomposed (NFD) names
  are stored as composed (NFC), like Windows writes them.
- **What's supported:** files and directories, any size, sparse and compressed
  files (libntfs-3g handles them), hidden and read-only attributes, timestamps.
- **Not supported:** symlinks and hard links (refused), extended attributes and
  alternate data streams, writing encrypted (EFS) files, BitLocker.
- **Not atomic:** a rename that replaces an existing file is done as several
  link and unlink steps, as in ntfs-3g. If a drive is unplugged mid-write it may
  need `chkdsk` on Windows. Always eject first.

## Requirements

- macOS 26, Xcode 26 (command-line tools are enough). No Homebrew.
- For the FSKit module to load: an Apple Developer Program team (see below).

## Build and test

```bash
make            # libntfs-3g (first time), engine, CLI
make test       # CLI suite at 1-byte and 4 KiB alignment + FSKit volume harness
make app        # build/app/MAC_NTFS.app with NTFSModule.appex inside
```

`make test` takes about four minutes. Each scenario keeps a local copy of what
the image should contain, then checks the image with `ntfsfix` **and** by
mounting it with macOS's own NTFS driver, so we don't rely on ntfs-3g agreeing
with itself. Coverage includes 2,000-file directories (index B+tree growth), a
300-step random-operations run, disk full, Unicode and 255-character names,
case-only renames, and refusing writes on hibernated volumes.

### CLI

```bash
build/out/macntfs disk.img info
build/out/macntfs disk.img ls -l /
build/out/macntfs disk.img put ~/photo.jpg /Photos/photo.jpg
sudo build/out/macntfs /dev/rdisk4s1 info     # real device (unmount it first to write)
```

## Signing and installing (needs an Apple Developer account)

macOS loads an FSKit module only if it is signed by a team and carries the
`com.apple.developer.fskit.fsmodule` entitlement. `MacNTFS.xcodeproj` uses
Xcode's automatic signing, which sets all of that up:

```bash
scripts/gen-xcodeproj.py YOUR_TEAM_ID     # only if your team isn't NRZQU2K9AD
xcodebuild -project MacNTFS.xcodeproj -scheme MacNTFS -configuration Debug \
    -derivedDataPath build/xcode -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
ditto build/xcode/Build/Products/Debug/MAC_NTFS.app /Applications/MAC_NTFS.app
open /Applications/MAC_NTFS.app
```

The first build registers the App IDs `com.venky.macntfs` and
`com.venky.macntfs.fsmodule` with the FSKit Module capability, registers this
Mac as a device, and creates the profiles. For your own prefix, change
`APP_ID` in `scripts/gen-xcodeproj.py`, the IDs in both `Info.plist` files, and
`extensionID` in `app/Sources/Mounter.swift`. (Xcode must be signed in to the
account: Settings › Accounts.)

Then turn the module on in **System Settings › General › Login Items &
Extensions › File System Extensions**, plug in an NTFS drive, and choose
**Mount read-write** from the menu bar. The drive is mounted under
`~/NTFS Volumes/<label>` and shows in Finder's sidebar. From a shell:
`mount -F -t ntfsrw /dev/diskNsM <dir>`.

`scripts/build-app.sh` still makes an ad-hoc build, which is useful for CI but
can't load the module. To share builds with other people, archive with a
Developer ID and notarize.

### Verified through FSKit

On an NTFS image remounted through the signed module (`fskit` in `mount`):

- Writing, copying (50 MB, `ditto` of a source tree, 200 small files),
  appending, truncating and regrowing, renaming (including case-only renames),
  moving files and folders, `rm`, `rmdir`.
- `cp -p` and `touch -t` timestamps, `chflags hidden`, and `chmod 444` (stored
  as the Windows read-only attribute). `.` and `..` appear exactly once.
- Windows-invalid names and case-insensitive duplicates are refused, and `df`
  shows correct sizes and inode counts.
- Afterwards the image passes `ntfsfix`, and macOS's own NTFS driver reads
  every file back byte for byte.
- An image with a hibernated `hiberfil.sys` mounts read-only: writes fail with
  `EROFS`, the image stays byte for byte unchanged, and the app shows the Fast
  Startup warning.

Things to know:

- **`._` files:** the module doesn't support extended attributes yet, so macOS
  stores them in AppleDouble `._name` files, as it does on FAT and exFAT.
  Windows shows them as small hidden-looking files.
- **Read-only fallback isn't visible to the kernel:** FSKit gives a module no
  way to make the mount itself read-only, so a protected volume still mounts as
  read-write and every write is refused with `EROFS`. The module sets statfs's
  `f_fssubtype` to 1 in this case, which is how the app tells.
- `FSClient` doesn't list third-party modules reliably, so the app shows its
  "turn on the extension" notice only after a mount fails with "Unable to
  invoke task".

## Layout

```
engine/      C engine over libntfs-3g (mn.h is the only public header)
cli/         macntfs command-line tool
fskit/       FSKit module sources, Info.plist, entitlements, volume harness
app/         menu-bar app sources, Info.plist, disk-probe test tool
MacNTFS.xcodeproj  generated by scripts/gen-xcodeproj.py (for signing)
scripts/     build-ntfs3g.sh, build-app.sh, gen-xcodeproj.py, make/verify-test-image.sh
tests/       test_cli.py (end-to-end), set-dirty.c, run-harness.sh
```

## Known limitations

- No extended attributes (see `._` files above), symlinks or hard links.
- Each operation opens and closes the NTFS inode, and one lock serializes the
  whole volume. That's correct but slow for big directory trees.
- Large directories are re-read for each enumeration that starts from the beginning.
- Builds for the host architecture only. Set `ARCH=arm64` on Apple silicon;
  universal builds would need libntfs-3g built for both architectures.
- Test images come from `mkntfs`. Before trusting this with real data, also test
  images created on real Windows (fragmented and compressed files, deep trees)
  and run `chkdsk` on Windows after writes.
