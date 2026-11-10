// Volume.swift - FSKit volume operations mapped onto the engine.

import Foundation
import FSKit

let rootInode = UInt64(MN_ROOT_INODE)

/// One NTFS inode. FSKit expects the same object back for the same file, so
/// items are cached until FSKit reclaims them.
final class NTFSItem: FSItem {
    let inode: UInt64
    var parent: UInt64

    init(inode: UInt64, parent: UInt64) {
        self.inode = inode
        self.parent = parent
        super.init()
    }
}

final class NTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    let engine: Engine
    private var items: [UInt64: NTFSItem] = [:]
    private let itemsLock = NSLock()
    lazy var root = item(rootInode, parent: rootInode)

    init(engine: Engine, volumeID: FSVolume.Identifier, volumeName: FSFileName) {
        self.engine = engine
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    func item(_ inode: UInt64, parent: UInt64) -> NTFSItem {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        if let existing = items[inode] {
            existing.parent = parent
            return existing
        }
        let new = NTFSItem(inode: inode, parent: parent)
        items[inode] = new
        return new
    }

    // MARK: Identity mapping
    //
    // FSKit reserves item IDs 1 (parent of root) and 2 (root). NTFS's root is
    // inode 5, and inodes 1 and 2 are metadata files that are never exposed.

    static func fileID(_ inode: UInt64) -> FSItem.Identifier {
        FSItem.Identifier(rawValue: inode == rootInode ? FSItem.Identifier.rootDirectory.rawValue : inode)!
    }

    func parentID(of item: NTFSItem) -> FSItem.Identifier {
        item.inode == rootInode ? .parentOfRoot : Self.fileID(item.parent)
    }

    // MARK: Errors

    private func fail(_ error: Error) -> NSError {
        if let e = error as? EngineError { return e.nsError }
        return error as NSError
    }

    private func name(_ n: FSFileName) throws -> String {
        guard let s = n.string, !s.isEmpty else { throw EngineError(code: MN_ERR_BAD_NAME) }
        return s
    }

    // MARK: Capabilities

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsPersistentObjectIDs = true
        c.supports64BitObjectIDs = true
        c.supports2TBFiles = true
        c.supportsFastStatFS = true
        c.supportsHiddenFiles = true
        c.supportsSymbolicLinks = false
        c.supportsHardLinks = false
        c.supportsSparseFiles = false
        c.doesNotSupportSettingFilePermissions = true
        c.caseFormat = .insensitiveCasePreserving   // matches Windows
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let s = engine.space()
        let r = FSStatFSResult(fileSystemTypeName: "ntfsrw")   // matches FSShortName; the app uses it to tell our mounts apart
        let bs = UInt64(s.cluster_size)
        r.blockSize = Int(s.cluster_size)
        r.ioSize = 1 << 20
        r.totalBlocks = s.total_clusters
        r.freeBlocks = s.free_clusters
        r.availableBlocks = s.free_clusters
        r.usedBlocks = s.total_clusters - s.free_clusters
        r.totalBytes = s.total_clusters * bs
        r.freeBytes = s.free_clusters * bs
        r.availableBytes = s.free_clusters * bs
        r.usedBytes = (s.total_clusters - s.free_clusters) * bs
        r.totalFiles = s.total_inodes
        r.freeFiles = s.free_inodes
        // The kernel mount stays read-write even when the engine refused writes,
        // so tell the app through statfs's f_fssubtype.
        r.fileSystemSubType = engine.readOnly ? Self.subtypeProtectedReadOnly : 0
        return r
    }

    var maximumLinkCount: Int { 1024 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }

    // MARK: Lifecycle

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try engine.close()
            reply(nil)
        } catch {
            reply(fail(error))
        }
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        try? engine.sync()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try engine.sync()
            reply(nil)
        } catch {
            reply(fail(error))
        }
    }

    // MARK: Attributes

    static let hiddenFlag: UInt32 = 0x8000     // UF_HIDDEN
    /// f_fssubtype for a volume opened read-only (hibernated / unclean). Mirrored in the app.
    static let subtypeProtectedReadOnly = 1

    func attributes(of item: NTFSItem) throws -> FSItem.Attributes {
        let a = try engine.stat(item.inode)
        let r = FSItem.Attributes()
        switch a.type {
        case MN_TYPE_DIR:     r.type = .directory
        case MN_TYPE_SYMLINK: r.type = .symlink
        default:              r.type = .file
        }
        let readOnly = a.win_attrs & UInt32(MN_WIN_READONLY) != 0 && a.type == MN_TYPE_FILE
        let perms: UInt32 = a.type == MN_TYPE_DIR ? 0o755 : (readOnly ? 0o444 : 0o644)
        r.mode = perms | (a.type == MN_TYPE_DIR ? UInt32(S_IFDIR) : UInt32(S_IFREG))
        r.uid = 99      // "unknown": the kernel presents files as owned by the user
        r.gid = 99
        r.linkCount = max(a.nlink, 1)
        r.flags = a.win_attrs & UInt32(MN_WIN_HIDDEN) != 0 ? Self.hiddenFlag : 0
        r.size = a.size
        r.allocSize = a.alloc_size
        r.fileID = Self.fileID(item.inode)
        r.parentID = parentID(of: item)
        r.birthTime = a.birth_time
        r.modifyTime = a.mod_time
        r.changeTime = a.change_time
        r.accessTime = a.access_time
        return r
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else { return reply(nil, fs_errorForPOSIXError(EINVAL)) }
        do {
            reply(try attributes(of: item), nil)
        } catch {
            reply(nil, fail(error))
        }
    }

    /// Apply what NTFS can store; consume (silently accept) what it can't, like ownership.
    func apply(_ req: FSItem.SetAttributesRequest, to item: NTFSItem) throws {
        var consumed: FSItem.Attribute = []

        if req.isValid(.size) {
            try engine.truncate(item.inode, to: req.size)
            consumed.insert(.size)
        }
        let times: [(FSItem.Attribute, timespec)] = [
            (.birthTime, req.birthTime), (.modifyTime, req.modifyTime), (.accessTime, req.accessTime),
        ]
        let set = times.filter { req.isValid($0.0) }
        if !set.isEmpty {
            func pick(_ a: FSItem.Attribute) -> timespec? { set.first { $0.0 == a }?.1 }
            try engine.setTimes(item.inode, birth: pick(.birthTime), mod: pick(.modifyTime),
                                access: pick(.accessTime))
            set.forEach { consumed.insert($0.0) }
        }
        if req.isValid(.flags) {
            let hidden = req.flags & Self.hiddenFlag != 0
            try engine.setWinAttrs(item.inode, mask: UInt32(MN_WIN_HIDDEN),
                                   attrs: hidden ? UInt32(MN_WIN_HIDDEN) : 0)
            consumed.insert(.flags)
        }
        if req.isValid(.mode) {
            // NTFS has no POSIX permissions; map the owner write bit to the read-only attribute.
            if try engine.stat(item.inode).type == MN_TYPE_FILE {
                let ro = req.mode & 0o200 == 0
                try engine.setWinAttrs(item.inode, mask: UInt32(MN_WIN_READONLY),
                                       attrs: ro ? UInt32(MN_WIN_READONLY) : 0)
            }
            consumed.insert(.mode)
        }
        for a in [FSItem.Attribute.uid, .gid, .changeTime, .backupTime, .addedTime] where req.isValid(a) {
            consumed.insert(a)
        }
        req.consumedAttributes = consumed
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem else { return reply(nil, fs_errorForPOSIXError(EINVAL)) }
        do {
            try apply(newAttributes, to: item)
            reply(try attributes(of: item), nil)
        } catch {
            reply(nil, fail(error))
        }
    }

    // MARK: Names

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let dir = directory as? NTFSItem else { return reply(nil, nil, fs_errorForPOSIXError(EINVAL)) }
        do {
            let ino = try engine.lookup(dir.inode, try self.name(name))
            reply(item(ino, parent: dir.inode), name, nil)
        } catch {
            reply(nil, nil, fail(error))
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let item = item as? NTFSItem, item.inode != rootInode {
            itemsLock.lock()
            if items[item.inode] === item { items[item.inode] = nil }
            itemsLock.unlock()
        }
        reply(nil)
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let dir = directory as? NTFSItem else { return reply(nil, nil, fs_errorForPOSIXError(EINVAL)) }
        let kind: mn_type
        switch type {
        case .file:      kind = MN_TYPE_FILE
        case .directory: kind = MN_TYPE_DIR
        default:         return reply(nil, nil, fs_errorForPOSIXError(ENOTSUP))
        }
        do {
            let ino = try engine.create(dir.inode, try self.name(name), type: kind)
            let new = item(ino, parent: dir.inode)
            try apply(newAttributes, to: new)
            reply(new, name, nil)
        } catch {
            reply(nil, nil, fail(error))
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(ENOTSUP))
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, fs_errorForPOSIXError(EINVAL))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let dir = directory as? NTFSItem else { return reply(fs_errorForPOSIXError(EINVAL)) }
        do {
            try engine.remove(dir.inode, try self.name(name))
            reply(nil)
        } catch {
            reply(fail(error))
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard let src = sourceDirectory as? NTFSItem, let dst = destinationDirectory as? NTFSItem,
              let moved = item as? NTFSItem
        else { return reply(nil, fs_errorForPOSIXError(EINVAL)) }
        do {
            try engine.rename(src.inode, try name(sourceName), dst.inode, try name(destinationName))
            moved.parent = dst.inode
            reply(destinationName, nil)
        } catch {
            reply(nil, fail(error))
        }
    }

    // MARK: Directories

    /// Listings are cached per directory between pages of one enumeration.
    private var listingCache: (dir: UInt64, verifier: UInt64, entries: [DirEntry])?

    func verifier(for dir: UInt64) throws -> UInt64 {
        let a = try engine.stat(dir)
        // Changes whenever the directory is modified; never the reserved initial value 0.
        return UInt64(bitPattern: Int64(a.mod_time.tv_sec)) &* 1_000_000_007 &+ UInt64(a.mod_time.tv_nsec) | 1
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let dir = directory as? NTFSItem else {
            return reply(FSDirectoryVerifier(rawValue: 0), fs_errorForPOSIXError(EINVAL))
        }
        do {
            let current = try self.verifier(for: dir.inode)
            if cookie != .initial && verifier.rawValue != current {
                return reply(FSDirectoryVerifier(rawValue: current),
                             NSError(domain: FSKitErrorDomain, code: FSError.Code.invalidDirectoryCookie.rawValue))
            }
            let entries: [DirEntry]
            itemsLock.lock()
            let cached = listingCache
            itemsLock.unlock()
            if let cached, cached.dir == dir.inode, cached.verifier == current, cookie != .initial {
                entries = cached.entries
            } else {
                entries = try engine.list(dir.inode)
                itemsLock.lock()
                listingCache = (dir.inode, current, entries)
                itemsLock.unlock()
            }

            for (index, row) in DirectoryListing.rows(entries, dir: dir.inode, includeDots: attributes == nil)
                .enumerated().dropFirst(Int(cookie.rawValue)) {
                var attrs: FSItem.Attributes?
                if attributes != nil {
                    attrs = try self.attributes(of: item(row.inode, parent: dir.inode))
                }
                let fileID = row.inode == dir.inode && row.name == "." ? Self.fileID(dir.inode)
                    : row.name == ".." ? parentID(of: dir) : Self.fileID(row.inode)
                let ok = packer.packEntry(name: FSFileName(string: row.name), itemType: row.type,
                                          itemID: fileID, nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                          attributes: attrs)
                if !ok { break }
            }
            reply(FSDirectoryVerifier(rawValue: current), nil)
        } catch {
            reply(FSDirectoryVerifier(rawValue: 0), fail(error))
        }
    }

    // MARK: Data

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem, offset >= 0 else { return reply(0, fs_errorForPOSIXError(EINVAL)) }
        do {
            let n = try buffer.withUnsafeMutableBytes { buf in
                try engine.read(item.inode, offset: UInt64(offset),
                                into: UnsafeMutableRawBufferPointer(rebasing: buf.prefix(min(length, buf.count))))
            }
            reply(n, nil)
        } catch {
            reply(0, fail(error))
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? NTFSItem, offset >= 0 else { return reply(0, fs_errorForPOSIXError(EINVAL)) }
        do {
            try contents.withUnsafeBytes { try engine.write(item.inode, offset: UInt64(offset), from: $0) }
            reply(contents.count, nil)
        } catch {
            reply(0, fail(error))
        }
    }
}

/// Directory rows in enumeration order. Cookies are positions in this list.
enum DirectoryListing {
    struct Row {
        let name: String
        let inode: UInt64
        let type: FSItem.ItemType
    }

    /// readdir()-style enumerations (no attributes requested) include "." and "..".
    static func rows(_ entries: [DirEntry], dir: UInt64, includeDots: Bool) -> [Row] {
        var rows: [Row] = []
        if includeDots {
            rows.append(Row(name: ".", inode: dir, type: .directory))
            rows.append(Row(name: "..", inode: dir, type: .directory))
        }
        for e in entries {
            let t: FSItem.ItemType
            switch e.type {
            case MN_TYPE_DIR:     t = .directory
            case MN_TYPE_SYMLINK: t = .symlink
            default:              t = .file
            }
            rows.append(Row(name: e.name, inode: e.inode, type: t))
        }
        return rows
    }
}
