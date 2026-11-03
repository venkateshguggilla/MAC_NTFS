#!/usr/bin/env python3
"""
End-to-end tests for the macntfs CLI / engine.

Every scenario works on a fresh NTFS image and keeps a local "model"
directory mirroring what the image should contain. After the scenario the
image is checked two ways:
  * ntfsfix -n (libntfs-3g's consistency check)
  * mounted read-only with macOS's own NTFS driver and compared file by file
    against the model, so we are not only checking ntfs-3g against itself.

Run: make test   (or: python3 tests/test_cli.py -v)
"""
import hashlib
import os
import random
import shutil
import subprocess
import tempfile
import unicodedata
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "build/out/macntfs")
NTFS_BIN = os.path.join(ROOT, "build/ntfs-3g/prefix")
MKNTFS = os.path.join(NTFS_BIN, "sbin/mkntfs")
NTFSCP = os.path.join(NTFS_BIN, "sbin/ntfscp")
NTFSFIX = os.path.join(NTFS_BIN, "bin/ntfsfix")
SET_DIRTY = os.path.join(ROOT, "build/out/test-set-dirty")


def nfc(s):
    return unicodedata.normalize("NFC", s)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


class Image:
    """A scratch NTFS image plus a local model of its expected contents."""

    def __init__(self, tmp, size_mb=64):
        self.tmp = tmp
        self.path = os.path.join(tmp, "vol.img")
        self.model = os.path.join(tmp, "model")
        os.mkdir(self.model)
        subprocess.run(["mkfile", "-n", f"{size_mb}m", self.path], check=True)
        subprocess.run([MKNTFS, "-F", "-Q", "-q", "-L", "test", "-s", "512",
                        "-p", "0", "-H", "255", "-S", "63", self.path],
                       check=True, capture_output=True)

    def run(self, *args, ok=True):
        r = subprocess.run([CLI, self.path, *args], capture_output=True)
        if ok and r.returncode != 0:
            raise AssertionError(f"macntfs {' '.join(args)} failed: {r.stderr.decode()}")
        if not ok and r.returncode == 0:
            raise AssertionError(f"macntfs {' '.join(args)} unexpectedly succeeded")
        return r

    def local(self, path):
        return os.path.join(self.model, path.lstrip("/"))

    # Operations applied to both the image and the model.
    def put_bytes(self, path, data):
        src = os.path.join(self.tmp, "upload")
        with open(src, "wb") as f:
            f.write(data)
        self.run("put", src, path)
        with open(self.local(path), "wb") as f:
            f.write(data)

    def mkdir(self, path):
        self.run("mkdir", path)
        os.mkdir(self.local(path))

    def rm(self, path):
        self.run("rm", path)
        p = self.local(path)
        os.rmdir(p) if os.path.isdir(p) else os.remove(p)

    def mv(self, a, b):
        self.run("mv", a, b)
        src, dst = self.local(a), self.local(b)
        # The model lives on case-insensitive APFS, so a case-only rename is "the same" path.
        if os.path.isdir(dst) and not os.path.samefile(src, dst):
            os.rmdir(dst)
        os.rename(src, dst)

    def truncate(self, path, size):
        self.run("truncate", path, str(size))
        os.truncate(self.local(path), size)

    def verify(self, test):
        r = subprocess.run([NTFSFIX, "-n", self.path], capture_output=True)
        test.assertEqual(r.returncode, 0, r.stdout.decode() + r.stderr.decode())
        with macos_mount(self.path) as mnt:
            test.assertEqual(tree(mnt), tree(self.model))


def tree(root):
    """{relative NFC path: sha256 or 'dir'}"""
    out = {}
    for dirpath, dirs, files in os.walk(root):
        for d in dirs:
            out[nfc(os.path.relpath(os.path.join(dirpath, d), root))] = "dir"
        for f in files:
            full = os.path.join(dirpath, f)
            out[nfc(os.path.relpath(full, root))] = sha(full)
    return out


class macos_mount:
    def __init__(self, image):
        self.image = image

    def __enter__(self):
        out = subprocess.run(["hdiutil", "attach", "-readonly", "-nomount", "-imagekey",
                              "diskimage-class=CRawDiskImage", self.image],
                             check=True, capture_output=True, text=True).stdout
        self.dev = out.split()[0]
        self.mnt = tempfile.mkdtemp()
        subprocess.run(["diskutil", "quiet", "mount", "readOnly", "-mountPoint",
                        self.mnt, self.dev], check=True)
        return self.mnt

    def __exit__(self, *exc):
        subprocess.run(["umount", self.mnt], capture_output=True)
        subprocess.run(["hdiutil", "detach", "-quiet", self.dev], capture_output=True)
        os.rmdir(self.mnt)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="macntfs-test-")
        self.img = Image(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class ReadTests(Base):
    def test_info_on_fresh_volume(self):
        out = self.img.run("info").stdout.decode()
        self.assertIn("label:          test", out)
        self.assertIn("safe to write:  yes", out)

    def test_ls_hides_metadata(self):
        out = self.img.run("ls").stdout.decode()
        self.assertNotIn("$MFT", out)

    def test_missing_file(self):
        r = self.img.run("cat", "/nope", ok=False)
        self.assertIn(b"no such file", r.stderr)

    def test_not_ntfs(self):
        junk = os.path.join(self.tmp, "junk.img")
        with open(junk, "wb") as f:
            f.write(b"\0" * (1 << 20))
        r = subprocess.run([CLI, junk, "info"], capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b"not an NTFS volume", r.stderr)


class WriteTests(Base):
    def test_file_sizes(self):
        rnd = random.Random(1)
        for name, size in [("empty", 0), ("tiny", 10), ("resident", 600),
                           ("cluster", 4096), ("odd", 1000003), ("big", 20 << 20)]:
            self.img.put_bytes(f"/{name}.bin", rnd.randbytes(size))
        self.img.verify(self)

    def test_get_roundtrip(self):
        data = random.Random(2).randbytes(3 << 20)
        self.img.put_bytes("/f.bin", data)
        out = os.path.join(self.tmp, "out.bin")
        self.img.run("get", "/f.bin", out)
        with open(out, "rb") as f:
            self.assertEqual(f.read(), data)

    def test_overwrite_shrinks(self):
        self.img.put_bytes("/f.bin", b"x" * 100000)
        self.img.put_bytes("/f.bin", b"short")
        self.img.verify(self)

    def test_directories(self):
        self.img.mkdir("/a")
        self.img.mkdir("/a/b")
        self.img.mkdir("/a/b/c")
        self.img.put_bytes("/a/b/c/deep.txt", b"deep")
        self.img.put_bytes("/a/one.txt", b"one")
        self.img.verify(self)

    def test_unicode_names(self):
        for name in ["héllo wörld.txt", "日本語のファイル.txt", "emoji 🎉.txt",
                     "Ελληνικά", "x" * 200]:
            self.img.put_bytes("/" + name, name.encode())
        # macOS hands us decomposed (NFD) names; they must land as NFC like Windows writes.
        self.img.put_bytes("/" + unicodedata.normalize("NFD", "café.txt"), b"nfd")
        os.rename(self.img.local("/" + unicodedata.normalize("NFD", "café.txt")),
                  self.img.local("/café.txt"))
        self.img.verify(self)

    def test_truncate(self):
        self.img.put_bytes("/t.bin", random.Random(3).randbytes(50000))
        self.img.truncate("/t.bin", 10)
        self.img.truncate("/t.bin", 5 << 20)   # grow: zero filled
        self.img.truncate("/t.bin", 0)
        self.img.verify(self)

    def test_touch(self):
        self.img.run("touch", "/new.txt")
        open(self.img.local("/new.txt"), "w").close()
        self.img.run("touch", "/new.txt")
        self.img.verify(self)

    def test_remove(self):
        self.img.mkdir("/d")
        self.img.put_bytes("/d/f", b"f")
        self.img.run("rm", "/d", ok=False)          # not empty
        self.img.rm("/d/f")
        self.img.rm("/d")
        self.img.run("rm", "/d", ok=False)          # gone
        self.img.verify(self)

    def test_rename_and_move(self):
        self.img.mkdir("/src")
        self.img.mkdir("/dst")
        self.img.put_bytes("/src/a.txt", b"a")
        self.img.mv("/src/a.txt", "/src/b.txt")      # rename in place
        self.img.mv("/src/b.txt", "/dst/b.txt")      # move across directories
        self.img.mkdir("/src/sub")
        self.img.put_bytes("/src/sub/x", b"x")
        self.img.mv("/src/sub", "/dst/sub")          # move a non-empty directory
        self.img.verify(self)

    def test_rename_case_only(self):
        self.img.put_bytes("/readme.txt", b"hi")
        self.img.mv("/readme.txt", "/README.txt")
        self.img.mkdir("/folder")
        self.img.mv("/folder", "/Folder")
        out = self.img.run("ls").stdout.decode()
        self.assertIn("README.txt", out)
        self.assertNotIn("readme.txt", out)
        self.img.verify(self)

    def test_rename_replaces_file(self):
        self.img.put_bytes("/old", b"old contents")
        self.img.put_bytes("/new", b"new contents")
        self.img.mv("/new", "/old")
        self.img.verify(self)

    def test_rename_replaces_empty_dir_only(self):
        self.img.mkdir("/a")
        self.img.mkdir("/b")
        self.img.put_bytes("/b/f", b"f")
        self.img.run("mv", "/a", "/b", ok=False)     # b not empty
        self.img.rm("/b/f")
        self.img.mv("/a", "/b")
        self.img.verify(self)

    def test_rename_type_mismatch(self):
        self.img.mkdir("/d")
        self.img.put_bytes("/f", b"f")
        self.img.run("mv", "/f", "/d", ok=False)
        self.img.run("mv", "/d", "/f", ok=False)
        self.img.verify(self)

    def test_move_dir_into_itself(self):
        self.img.mkdir("/a")
        self.img.mkdir("/a/b")
        self.img.run("mv", "/a", "/a/b/a", ok=False)
        self.img.run("mv", "/a", "/a/a", ok=False)
        self.img.verify(self)

    def test_windows_invalid_names(self):
        for bad in ["/a:b", "/q?", "/star*", "/pipe|", "/lt<", '/quote"',
                    "/trailing.", "/trailing ", "/CON", "/nul.txt", "/COM1"]:
            r = self.img.run("touch", bad, ok=False)
            self.assertIn(b"not valid on Windows", r.stderr, bad)
        self.img.verify(self)

    def test_create_is_case_insensitive(self):
        self.img.put_bytes("/Photo.JPG", b"p")
        self.img.run("mkdir", "/photo.jpg", ok=False)
        self.img.run("touch", "/PHOTO.jpg")        # updates the existing file
        self.img.verify(self)

    def test_lookup_is_case_insensitive(self):
        self.img.mkdir("/Docs")
        self.img.put_bytes("/Docs/Report.TXT", b"r")
        self.assertEqual(self.img.run("cat", "/docs/report.txt").stdout, b"r")

    def test_max_length_name(self):
        # 255 UTF-16 units is the NTFS limit; 256 must be refused.
        self.img.run("touch", "/" + "y" * 255)
        self.img.run("touch", "/" + "y" * 256, ok=False)
        self.assertIn("y" * 255, self.img.run("ls").stdout.decode())

    def test_cannot_touch_metadata(self):
        self.img.run("rm", "/$MFT", ok=False)
        self.img.run("mv", "/$MFT", "/mft", ok=False)
        self.img.verify(self)

    def test_large_directory(self):
        # Enough entries to force the directory index from resident into a B+tree.
        self.img.mkdir("/many")
        src = os.path.join(self.tmp, "upload")
        with open(src, "wb") as f:
            f.write(b"z")
        for i in range(2000):
            self.img.run("put", src, f"/many/file-{i:05d}.txt")
            shutil.copy(src, self.img.local(f"/many/file-{i:05d}.txt"))
        for i in range(0, 2000, 3):
            self.img.rm(f"/many/file-{i:05d}.txt")
        self.img.verify(self)

    def test_disk_full(self):
        small_dir = os.path.join(self.tmp, "small")
        os.mkdir(small_dir)
        small = Image(small_dir, size_mb=8)
        src = os.path.join(self.tmp, "upload")
        with open(src, "wb") as f:
            f.write(os.urandom(16 << 20))
        r = small.run("put", src, "/huge", ok=False)
        self.assertIn(b"no space", r.stderr)
        r = subprocess.run([NTFSFIX, "-n", small.path], capture_output=True)
        self.assertEqual(r.returncode, 0)

    def test_random_operations(self):
        """Random mix of operations, checked against the model at the end."""
        rnd = random.Random(1234)
        files, dirs = [], ["/"]
        for step in range(300):
            op = rnd.random()
            parent = rnd.choice(dirs)
            base = parent.rstrip("/")
            if op < 0.35 or not files:
                p = f"{base}/f{step}.bin"
                self.img.put_bytes(p, rnd.randbytes(rnd.choice([0, 7, 900, 5000, 70000, 300000])))
                files.append(p)
            elif op < 0.45:
                p = f"{base}/d{step}"
                self.img.mkdir(p)
                dirs.append(p)
            elif op < 0.6:
                p = rnd.choice(files)
                self.img.put_bytes(p, rnd.randbytes(rnd.randint(0, 200000)))
            elif op < 0.7:
                p = rnd.choice(files)
                self.img.truncate(p, rnd.randint(0, 400000))
            elif op < 0.85:
                p = rnd.choice(files)
                q = f"{base}/m{step}.bin"
                self.img.mv(p, q)
                files[files.index(p)] = q
            else:
                p = rnd.choice(files)
                self.img.rm(p)
                files.remove(p)
        self.img.verify(self)


class SafetyTests(Base):
    def assert_refuses_writes(self, reason):
        before = sha(self.img.path)
        for args in [("touch", "/x"), ("mkdir", "/d")]:
            r = self.img.run(*args, ok=False)
            self.assertIn(reason, r.stderr)
        self.assertEqual(sha(self.img.path), before, "image was modified")
        self.img.run("ls")   # reading still works

    def test_hibernated_volume(self):
        hib = os.path.join(self.tmp, "hiberfil.sys")
        with open(hib, "wb") as f:
            f.write(b"HIBR" + b"\0" * 8188)
        subprocess.run([NTFSCP, "-q", self.img.path, hib, "/hiberfil.sys"], check=True)
        self.assertIn("hibernated:     YES", self.img.run("info").stdout.decode())
        self.assert_refuses_writes(b"hibernated")

    def test_dirty_flag_reported(self):
        subprocess.run([SET_DIRTY, self.img.path], check=True)
        self.assertIn("dirty flag:     SET", self.img.run("info").stdout.decode())


if __name__ == "__main__":
    unittest.main()
