# MAC_NTFS

Open-source read/write NTFS for macOS 26, built as an **FSKit** file system
module (no kernel extension, no reduced-security boot) on top of
[libntfs-3g](https://github.com/tuxera/ntfs-3g), plus a small menu-bar app
that remounts NTFS drives read-write on request.

Licensed under GPLv2 (see `LICENSE`), matching libntfs-3g.

> **Status: all four phases are built, but the FSKit module has not run inside
> FSKit yet.** macOS only loads FSKit modules signed by a developer team with
> the FSKit entitlement (see [Signing](#signing-needs-an-apple-developer-account)).
> Everything below the FSKit boundary is tested against disk images.
> Try it on drives whose data you have backed up.

## Roadmap

| Phase | What | Status |
|---|---|---|
| 0 | Build libntfs-3g from source; NTFS test images | done |
| 1 | Engine read API + `macntfs` CLI (`info ls stat cat get`) | done, tested |
| 2 | Engine write API + CLI (`put mkdir rm mv truncate touch`) | done, tested |
| 3 | FSKit module (`NTFSModule.appex`) | built; volume ops tested via harness; **needs team signing to load** |
| 4 | Menu-bar app: detect drives, remount read-write, Fast Startup warnings | built; disk detection and remount fallback tested |

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

## Signing (needs an Apple Developer account)

macOS loads an FSKit module only if it is signed by a team and carries the
`com.apple.developer.fskit.fsmodule` entitlement. Ad-hoc builds compile and run
the app, but the module doesn't register: `mount -F -t ntfsrw` fails with
"Unable to invoke task", and the app falls back to the macOS read-only mount.

Once your account is active:

1. In the developer portal, register App IDs `dev.macntfs.app` and
   `dev.macntfs.app.fsmodule` (or your own prefix; also change the IDs in
   `app/Info.plist`, `fskit/Info.plist` and `app/Sources/Mounter.swift`), and
   enable the **FSKit Module** capability on the second.
2. Create a macOS development provisioning profile for `dev.macntfs.app.fsmodule`.
3. Build signed:
   ```bash
   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
   PROVISIONING_PROFILE=~/Downloads/fsmodule.provisionprofile \
   scripts/build-app.sh
   ```
4. Copy `build/app/MAC_NTFS.app` to `/Applications` and open it once.
5. Turn it on in **System Settings › General › Login Items & Extensions ›
   File System Extensions**. The menu-bar app links straight there.
6. Plug in an NTFS drive, then choose **Mount read-write** from the menu bar.
   It's mounted under `~/NTFS Volumes/<label>` and shows in Finder's sidebar.

To share builds with other people, sign with a Developer ID and notarize.

### First things to check once it loads

These parts of the FSKit integration can only be verified against the real
FSKit runtime:

- `ls -la` on the mount shows `.` and `..` exactly once (`DirectoryListing.rows`).
- Finder copy, duplicate and rename, and `cp -p`. Look for setattr errors in
  Console (subsystem `dev.macntfs.fsmodule`).
- Free space shown in Finder matches `macntfs <dev> info`.
- A volume Windows left hibernated mounts read-only and the app shows the warning.

## Layout

```
engine/      C engine over libntfs-3g (mn.h is the only public header)
cli/         macntfs command-line tool
fskit/       FSKit module sources, Info.plist, entitlements, volume harness
app/         menu-bar app sources, Info.plist, disk-probe test tool
scripts/     build-ntfs3g.sh, build-app.sh, make/verify-test-image.sh
tests/       test_cli.py (end-to-end), set-dirty.c, run-harness.sh
```

## Known limitations

- Each operation opens and closes the NTFS inode, and one lock serializes the
  whole volume. That's correct but slow for big directory trees.
- Large directories are re-read for each enumeration that starts from the beginning.
- Builds for the host architecture only. Set `ARCH=arm64` on Apple silicon;
  universal builds would need libntfs-3g built for both architectures.
- Test images come from `mkntfs`. Before trusting this with real data, also test
  images created on real Windows (fragmented and compressed files, deep trees)
  and run `chkdsk` on Windows after writes.
