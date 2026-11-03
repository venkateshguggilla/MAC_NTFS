// Engine.swift - Swift wrapper around the C engine (engine/include/mn.h).
//
// libntfs-3g is not thread-safe and FSKit calls in from many threads, so
// every engine call goes through one lock per volume.

import Foundation

struct EngineError: Error, CustomStringConvertible {
    let code: mn_err

    var description: String { String(cString: mn_strerror(code)) }

    var posix: Int32 {
        switch code {
        case MN_ERR_NOT_FOUND:    return ENOENT
        case MN_ERR_NOT_DIR:      return ENOTDIR
        case MN_ERR_IS_DIR:       return EISDIR
        case MN_ERR_READ_ONLY,
             MN_ERR_HIBERNATED,
             MN_ERR_UNCLEAN:      return EROFS
        case MN_ERR_EXISTS:       return EEXIST
        case MN_ERR_NOT_EMPTY:    return ENOTEMPTY
        case MN_ERR_NO_SPACE:     return ENOSPC
        case MN_ERR_PERMISSION:   return EPERM
        case MN_ERR_NO_PRIVILEGE: return EACCES
        case MN_ERR_BAD_NAME,
             MN_ERR_INVALID,
             MN_ERR_NOT_NTFS:     return EINVAL
        case MN_ERR_UNSUPPORTED:  return ENOTSUP
        case MN_ERR_NOMEM:        return ENOMEM
        case MN_ERR_BUSY:         return EBUSY
        default:                  return EIO
        }
    }

    var nsError: NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(posix)) }
}

@inline(__always)
func check(_ err: mn_err) throws {
    if err != MN_OK { throw EngineError(code: err) }
}

struct DirEntry {
    let name: String
    let inode: UInt64
    let type: mn_type
}

final class Engine: @unchecked Sendable {
    private let vol: OpaquePointer
    private let lock = NSLock()
    let readOnly: Bool

    /// Takes ownership of io, whether or not opening succeeds.
    init(io: mn_io, name: String, readWrite: Bool) throws {
        var io = io
        var out: OpaquePointer?
        try check(mn_volume_open_io(&io, name, readWrite ? UInt32(MN_OPEN_READ_WRITE) : 0, &out))
        vol = out!
        readOnly = !readWrite
    }

    /// Images and device nodes, for tools and tests.
    init(path: String, readWrite: Bool) throws {
        var out: OpaquePointer?
        try check(mn_volume_open(path, readWrite ? UInt32(MN_OPEN_READ_WRITE) : 0, &out))
        vol = out!
        readOnly = !readWrite
    }

    func close() throws {
        try locked { try check(mn_volume_close(vol)) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Volume

    var label: String { locked { String(cString: mn_volume_label(vol)) } }
    var serial: UInt64 { locked { mn_volume_serial(vol) } }

    func space() -> mn_volume_space {
        locked {
            var s = mn_volume_space()
            mn_volume_get_space(vol, &s)
            return s
        }
    }

    func info() throws -> mn_volume_info {
        try locked {
            var i = mn_volume_info()
            try check(mn_volume_get_info(vol, &i))
            return i
        }
    }

    func sync() throws {
        try locked { try check(mn_sync(vol)) }
    }

    // MARK: Items

    func stat(_ inode: UInt64) throws -> mn_attr {
        try locked {
            var a = mn_attr()
            try check(mn_stat(vol, inode, &a))
            return a
        }
    }

    func lookup(_ dir: UInt64, _ name: String) throws -> UInt64 {
        try locked {
            var ino: UInt64 = 0
            try check(mn_lookup(vol, dir, name, &ino))
            return ino
        }
    }

    func list(_ dir: UInt64) throws -> [DirEntry] {
        final class Box { var entries: [DirEntry] = [] }
        let box = Box()
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let cb: mn_readdir_cb = { ctx, ent in
            let box = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
            let e = ent!.pointee
            box.entries.append(DirEntry(name: String(cString: e.name), inode: e.inode, type: e.type))
            return 0
        }
        try locked { try check(mn_readdir(vol, dir, cb, ctx)) }
        return box.entries
    }

    func read(_ inode: UInt64, offset: UInt64, into buf: UnsafeMutableRawBufferPointer) throws -> Int {
        try locked {
            var n = 0
            try check(mn_read(vol, inode, offset, buf.baseAddress, buf.count, &n))
            return n
        }
    }

    func write(_ inode: UInt64, offset: UInt64, from buf: UnsafeRawBufferPointer) throws {
        try locked { try check(mn_write(vol, inode, offset, buf.baseAddress, buf.count)) }
    }

    func create(_ dir: UInt64, _ name: String, type: mn_type) throws -> UInt64 {
        try locked {
            var ino: UInt64 = 0
            try check(mn_create(vol, dir, name, type, &ino))
            return ino
        }
    }

    func truncate(_ inode: UInt64, to size: UInt64) throws {
        try locked { try check(mn_truncate(vol, inode, size)) }
    }

    func remove(_ dir: UInt64, _ name: String) throws {
        try locked { try check(mn_remove(vol, dir, name)) }
    }

    func rename(_ srcDir: UInt64, _ srcName: String, _ dstDir: UInt64, _ dstName: String) throws {
        try locked { try check(mn_rename(vol, srcDir, srcName, dstDir, dstName)) }
    }

    func setTimes(_ inode: UInt64, birth: timespec?, mod: timespec?, access: timespec?) throws {
        func ptr(_ t: timespec?, _ body: (UnsafePointer<timespec>?) -> mn_err) -> mn_err {
            guard var t else { return body(nil) }
            return withUnsafePointer(to: &t) { body($0) }
        }
        try locked {
            try check(ptr(birth) { b in ptr(mod) { m in ptr(access) { a in
                mn_set_times(vol, inode, b, m, a)
            } } })
        }
    }

    func setWinAttrs(_ inode: UInt64, mask: UInt32, attrs: UInt32) throws {
        try locked { try check(mn_set_win_attrs(vol, inode, mask, attrs)) }
    }
}
