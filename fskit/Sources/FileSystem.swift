// FileSystem.swift - the FSKit module entry point: probe and load NTFS volumes.

import Foundation
import FSKit
import os

let log = Logger(subsystem: "dev.macntfs.fsmodule", category: "fs")

@main
struct NTFSExtension: UnaryFileSystemExtension {
    let fileSystem = NTFSFileSystem()
}

final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(.notRecognized, nil)
            return
        }
        let device = BlockDevice(block)
        guard let boot = try? device.readBootSector(), let serial = NTFSBootSector.serial(boot) else {
            reply(.notRecognized, nil)
            return
        }
        // Read the label with a short read-only open; a volume we can't parse is still "recognized".
        let label = (try? Engine(io: device.makeIO(writable: false), name: block.bsdName, readWrite: false))
            .map { engine in
                defer { try? engine.close() }
                return engine.label
            }
        let container = FSContainerIdentifier(uuid: NTFSBootSector.uuid(serial: serial))
        if let label {
            reply(.usable(name: label, containerID: container), nil)
        } else {
            reply(.recognized(name: "", containerID: container), nil)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(nil, fs_errorForPOSIXError(ENODEV))
            return
        }
        let device = BlockDevice(block)
        let wantWrite = block.isWritable && !MountOptions.readOnly(options.taskOptions)

        let engine: Engine
        do {
            engine = try Engine(io: device.makeIO(writable: wantWrite), name: block.bsdName,
                                readWrite: wantWrite)
        } catch let e as EngineError where wantWrite && (e.code == MN_ERR_HIBERNATED || e.code == MN_ERR_UNCLEAN) {
            // Never write to a volume Windows may still have cached; still show its files.
            log.error("\(block.bsdName, privacy: .public): \(e.description, privacy: .public); mounting read-only")
            do {
                engine = try Engine(io: device.makeIO(writable: false), name: block.bsdName, readWrite: false)
            } catch {
                reply(nil, (error as? EngineError)?.nsError ?? error)
                return
            }
        } catch {
            reply(nil, (error as? EngineError)?.nsError ?? error)
            return
        }

        let serial = engine.serial
        let label = engine.label
        let volume = NTFSVolume(engine: engine,
                                volumeID: FSVolume.Identifier(uuid: NTFSBootSector.uuid(serial: serial)),
                                volumeName: FSFileName(string: label.isEmpty ? "NTFS" : label))
        containerStatus = .ready
        log.info("\(block.bsdName, privacy: .public): loaded \(engine.readOnly ? "read-only" : "read-write", privacy: .public)")
        reply(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }
}

enum NTFSBootSector {
    /// Volume serial number, or nil if this is not an NTFS boot sector.
    static func serial(_ boot: Data) -> UInt64? {
        guard boot.count >= 512,
              boot[boot.startIndex + 3 ..< boot.startIndex + 11].elementsEqual("NTFS    ".utf8)
        else { return nil }
        return boot[boot.startIndex + 0x48 ..< boot.startIndex + 0x50]
            .enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// A stable UUID derived from the serial number, so the same drive keeps its identity.
    static func uuid(serial: UInt64) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        // Fixed prefix marks these as MAC_NTFS ids; the serial fills the rest.
        bytes[0...7] = [0x4d, 0x4e, 0x54, 0x46, 0x53, 0x00, 0x40, 0x80][...]
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: serial >> (8 * UInt64(i))) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

enum MountOptions {
    /// mount(8) passes options like ["-o", "rdonly,nobrowse"] or ["-r"].
    static func readOnly(_ args: [String]) -> Bool {
        var it = args.makeIterator()
        while let arg = it.next() {
            if arg == "-r" { return true }
            let opts = arg == "-o" ? (it.next() ?? "") : (arg.hasPrefix("-o") ? String(arg.dropFirst(2)) : "")
            if opts.split(separator: ",").contains(where: { $0 == "rdonly" || $0 == "ro" }) { return true }
        }
        return false
    }
}
