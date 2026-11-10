// Disks.swift - watches DiskArbitration for NTFS partitions.

import DiskArbitration
import Foundation

struct NTFSDisk: Identifiable, Equatable {
    enum State: Equatable {
        case unmounted
        case systemReadOnly             // macOS's own driver (always read-only)
        case readWrite                  // our FSKit module
        case protectedReadOnly          // our module, refused writes (hibernated / unclean)
    }

    let bsdName: String                 // "disk4s1"
    let label: String
    let size: Int64
    let mountPath: URL?
    let state: State

    var id: String { bsdName }
    var displayName: String { label.isEmpty ? bsdName : label }
}

/// Partition types that can hold NTFS: MBR 0x07 and GPT Microsoft Basic Data.
private let ntfsContentHints: Set<String> = ["Windows_NTFS", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"]

@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var disks: [NTFSDisk] = []
    /// Called for disks that just appeared, so the app can auto-mount them.
    var onAppear: ((NTFSDisk) -> Void)?

    private let session: DASession
    private var known: [String: DADisk] = [:]

    init() {
        session = DASessionCreate(kCFAllocatorDefault)!
        DASessionSetDispatchQueue(session, .main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.update(disk, appeared: true) }
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.remove(disk) }
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, ctx in
            let me = Unmanaged<DiskMonitor>.fromOpaque(ctx!).takeUnretainedValue()
            MainActor.assumeIsolated { me.update(disk, appeared: false) }
        }, ctx)
    }

    func refresh() {
        for disk in known.values { update(disk, appeared: false) }
    }

    private func update(_ disk: DADisk, appeared: Bool) {
        guard let desc = DADiskCopyDescription(disk) as? [CFString: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey] as? String,
              let entry = Self.describe(bsd: bsd, desc: desc)
        else { return }
        known[bsd] = disk
        let isNew = !disks.contains { $0.bsdName == bsd }
        disks.removeAll { $0.bsdName == bsd }
        disks.append(entry)
        disks.sort { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        if appeared && isNew { onAppear?(entry) }
    }

    private func remove(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        known[bsd] = nil
        disks.removeAll { $0.bsdName == bsd }
    }

    static func describe(bsd: String, desc: [CFString: Any]) -> NTFSDisk? {
        let kind = desc[kDADiskDescriptionVolumeKindKey] as? String
        let content = desc[kDADiskDescriptionMediaContentKey] as? String ?? ""
        // Basic Data partitions are also used for FAT/exFAT; trust the probed kind when present.
        let isNTFS = kind == "ntfs" || kind == "ntfsrw" || (kind == nil && content == "Windows_NTFS")
        guard isNTFS, ntfsContentHints.contains(content) || kind != nil else { return nil }

        let path = desc[kDADiskDescriptionVolumePathKey] as? URL
        var state = NTFSDisk.State.unmounted
        if let path {
            var st = statfs()
            if statfs(path.path, &st) == 0 {
                let type = withUnsafeBytes(of: st.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                // Our module reports subtype 1 when it refused writes (see Volume.swift).
                let ro = st.f_flags & UInt32(MNT_RDONLY) != 0 || st.f_fssubtype == 1
                if type == "ntfsrw" {
                    state = ro ? .protectedReadOnly : .readWrite
                } else {
                    state = .systemReadOnly
                }
            }
        }
        return NTFSDisk(bsdName: bsd,
                        label: desc[kDADiskDescriptionVolumeNameKey] as? String ?? "",
                        size: (desc[kDADiskDescriptionMediaSizeKey] as? NSNumber)?.int64Value ?? 0,
                        mountPath: path,
                        state: state)
    }
}
