// VolumeHarness.swift - drives NTFSVolume's FSKit operations directly against
// an NTFS image, without the FSKit daemon (which needs a signed extension).
//
// Usage: volume-harness <image>   (the image must be a freshly formatted volume)

import Foundation
import FSKit

var failures = 0

func expect(_ cond: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if cond() {
        print("  ok    \(what)")
    } else {
        print("  FAIL  \(what) (line \(line))")
        failures += 1
    }
}

/// Our volume replies synchronously, so a reply is always available on return.
func sync<T>(_ call: (@escaping (T) -> Void) -> Void) -> T {
    var result: T?
    call { result = $0 }
    return result!
}

func posix(_ error: Error?) -> Int {
    (error as NSError?)?.code ?? 0
}

@main
struct Harness {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let engine = try Engine(path: path, readWrite: true)
        let volume = NTFSVolume(engine: engine, volumeID: FSVolume.Identifier(uuid: UUID()),
                                volumeName: FSFileName(string: "test"))
        let root = volume.root
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.type, .size, .fileID, .parentID, .modifyTime, .flags, .mode]

        print("==> statfs / capabilities")
        let stats = volume.volumeStatistics
        expect(stats.totalBytes > 0 && stats.freeBytes > 0 && stats.freeBytes < stats.totalBytes, "statfs sizes")
        expect(volume.supportedVolumeCapabilities.caseFormat == .insensitiveCasePreserving, "case-insensitive, preserving")

        print("==> root")
        let (rootAttrs, e0): (FSItem.Attributes?, Error?) = sync { r in volume.getAttributes(get, of: root) { r(($0, $1)) } }
        expect(e0 == nil && rootAttrs?.type == .directory, "root is a directory")
        expect(rootAttrs?.fileID == .rootDirectory && rootAttrs?.parentID == .parentOfRoot, "root uses FSKit's reserved ids")

        print("==> create + write + read")
        let empty = FSItem.SetAttributesRequest()
        let (fileItem, _, e1): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.createItem(named: FSFileName(string: "Hello.txt"), type: .file, inDirectory: root,
                              attributes: empty) { r(($0, $1, $2)) }
        }
        expect(e1 == nil && fileItem != nil, "create file")
        let file = fileItem as! NTFSItem
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let (written, e2): (Int, Error?) = sync { r in volume.write(contents: payload, to: file, at: 0) { r(($0, $1)) } }
        expect(e2 == nil && written == payload.count, "write 300 KB")
        var back = Data(count: payload.count)
        let n = try back.withUnsafeMutableBytes { try engine.read(file.inode, offset: 0, into: $0) }
        expect(n == payload.count && back == payload, "read back matches")

        print("==> lookup")
        let (found, _, e3): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.lookupItem(named: FSFileName(string: "hello.TXT"), inDirectory: root) { r(($0, $1, $2)) }
        }
        expect(e3 == nil && found === file, "case-insensitive lookup returns the same item object")
        let (_, _, e4): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.lookupItem(named: FSFileName(string: "missing"), inDirectory: root) { r(($0, $1, $2)) }
        }
        expect(posix(e4) == Int(ENOENT), "missing name is ENOENT")

        print("==> setAttributes")
        let set = FSItem.SetAttributesRequest()
        set.size = 1000
        set.modifyTime = timespec(tv_sec: 1_600_000_000, tv_nsec: 500)
        set.flags = NTFSVolume.hiddenFlag
        set.mode = 0o444
        set.uid = 501
        let (after, e5): (FSItem.Attributes?, Error?) = sync { r in volume.setAttributes(set, on: file) { r(($0, $1)) } }
        expect(e5 == nil, "setAttributes succeeds")
        expect(after?.size == 1000, "truncate via size")
        expect(after?.modifyTime.tv_sec == 1_600_000_000, "modify time stored")
        expect((after?.flags ?? 0) & NTFSVolume.hiddenFlag != 0, "hidden flag maps to Windows hidden")
        expect((after?.mode ?? 0) & 0o222 == 0, "mode without write bit maps to read-only")
        expect(set.wasAttributeConsumed(.uid) && set.wasAttributeConsumed(.size), "all attributes consumed")
        let clear = FSItem.SetAttributesRequest()
        clear.mode = 0o644
        clear.flags = 0
        _ = sync { r in volume.setAttributes(clear, on: file) { r(($0, $1)) } } as (FSItem.Attributes?, Error?)

        print("==> directories + rename")
        let (dirItem, _, e6): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.createItem(named: FSFileName(string: "Folder"), type: .directory, inDirectory: root,
                              attributes: empty) { r(($0, $1, $2)) }
        }
        expect(e6 == nil, "create directory")
        let dir = dirItem as! NTFSItem
        let (newName, e7): (FSFileName?, Error?) = sync { r in
            volume.renameItem(file, inDirectory: root, named: FSFileName(string: "Hello.txt"),
                              to: FSFileName(string: "Moved.txt"), inDirectory: dir, overItem: nil) { r(($0, $1)) }
        }
        expect(e7 == nil && newName?.string == "Moved.txt", "move into folder")
        let (movedAttrs, _): (FSItem.Attributes?, Error?) = sync { r in volume.getAttributes(get, of: file) { r(($0, $1)) } }
        expect(movedAttrs?.parentID == NTFSVolume.fileID(dir.inode), "parent updated after move")

        print("==> errors map to POSIX")
        let (_, _, e8): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.createItem(named: FSFileName(string: "bad:name"), type: .file, inDirectory: root,
                              attributes: empty) { r(($0, $1, $2)) }
        }
        expect(posix(e8) == Int(EINVAL), "invalid Windows name is EINVAL")
        let (_, _, e9): (FSItem?, FSFileName?, Error?) = sync { r in
            volume.createItem(named: FSFileName(string: "folder"), type: .file, inDirectory: root,
                              attributes: empty) { r(($0, $1, $2)) }
        }
        expect(posix(e9) == Int(EEXIST), "case-insensitive duplicate is EEXIST")
        let e10: Error? = sync { r in
            volume.removeItem(dir, named: FSFileName(string: "Folder"), fromDirectory: root) { r($0) }
        }
        expect(posix(e10) == Int(ENOTEMPTY), "removing non-empty folder is ENOTEMPTY")

        print("==> remove + listing rows")
        let e11: Error? = sync { r in
            volume.removeItem(file, named: FSFileName(string: "Moved.txt"), fromDirectory: dir) { r($0) }
        }
        expect(e11 == nil, "remove file")
        let rows = DirectoryListing.rows(try engine.list(rootInode), dir: rootInode, includeDots: true)
        expect(rows.map(\.name) == [".", "..", "Folder"], "readdir rows: . .. Folder")
        let bulk = DirectoryListing.rows(try engine.list(rootInode), dir: rootInode, includeDots: false)
        expect(bulk.map(\.name) == ["Folder"], "attribute enumeration omits dot entries")

        print("==> sync + deactivate")
        let e12: Error? = sync { r in volume.synchronize(flags: .wait) { r($0) } }
        expect(e12 == nil, "synchronize")
        let e13: Error? = sync { r in volume.deactivate { r($0) } }
        expect(e13 == nil, "deactivate closes the engine")

        print(failures == 0 ? "==> all harness checks passed" : "==> \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
