// Mounter.swift - swaps a drive between macOS's read-only mount and ours.

import Foundation
import FSKit

enum MountError: LocalizedError {
    case command(String, String)

    var errorDescription: String? {
        switch self {
        case let .command(cmd, output): return "\(cmd) failed: \(output)"
        }
    }
}

enum Mounter {
    static let fsType = "ntfsrw"        // FSShortName in fskit/Info.plist
    static let extensionID = "com.venky.macntfs.fsmodule"

    /// Where read-write mounts go. /Volumes is root-only, so use a folder in the user's home.
    static func mountPoint(for disk: NTFSDisk) throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("NTFS Volumes")
        let safe = disk.displayName.replacingOccurrences(of: "/", with: "-")
        let dir = base.appendingPathComponent(safe)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func mountReadWrite(_ disk: NTFSDisk) async throws {
        if disk.mountPath != nil {
            try await run("/usr/sbin/diskutil", ["unmount", disk.bsdName])
        }
        let dir = try mountPoint(for: disk)
        do {
            try await run("/sbin/mount", ["-F", "-t", fsType, "/dev/\(disk.bsdName)", dir.path])
        } catch {
            // Put the drive back the way macOS had it.
            try? FileManager.default.removeItem(at: dir)
            _ = try? await run("/usr/sbin/diskutil", ["mount", disk.bsdName])
            throw error
        }
    }

    static func remountSystemReadOnly(_ disk: NTFSDisk) async throws {
        if disk.mountPath != nil {
            try await run("/usr/sbin/diskutil", ["unmount", disk.bsdName])
        }
        try await run("/usr/sbin/diskutil", ["mount", disk.bsdName])
    }

    static func eject(_ disk: NTFSDisk) async throws {
        try await run("/usr/sbin/diskutil", ["unmount", disk.bsdName])
        if let path = disk.mountPath, path.path.contains("/NTFS Volumes/") {
            try? FileManager.default.removeItem(at: path)   // only removes an empty folder
        }
    }

    /// Whether the extension is enabled in System Settings, or nil if unknown.
    /// FSClient doesn't always list third-party modules, so nil is common.
    static func extensionEnabled() async -> Bool? {
        guard let modules = try? await FSClient.shared.installedExtensions,
              let ours = modules.first(where: { $0.bundleIdentifier == extensionID })
        else { return nil }
        return ours.isEnabled
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { p in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: out)
                } else {
                    let cmd = ([URL(fileURLWithPath: tool).lastPathComponent] + args).joined(separator: " ")
                    cont.resume(throwing: MountError.command(cmd, out.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
