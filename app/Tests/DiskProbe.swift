// DiskProbe.swift - exercises DiskMonitor and Mounter from the command line.
//
// Usage: disk-probe list
//        disk-probe mount-rw <bsdName>     try the read-write remount path

import Foundation

@main
struct DiskProbe {
    @MainActor
    static func main() async throws {
        let monitor = DiskMonitor()
        try await Task.sleep(for: .seconds(2))      // let DiskArbitration report existing disks
        let args = CommandLine.arguments
        for d in monitor.disks {
            print("\(d.bsdName)\t\(d.state)\t\(d.displayName)\t\(d.mountPath?.path ?? "-")")
        }
        if args.count == 3, args[1] == "mount-rw", let disk = monitor.disks.first(where: { $0.bsdName == args[2] }) {
            do {
                try await Mounter.mountReadWrite(disk)
                print("mounted read-write")
            } catch {
                print("mount-rw failed: \(error.localizedDescription)")
            }
            try await Task.sleep(for: .seconds(2))
            monitor.refresh()
            for d in monitor.disks where d.bsdName == disk.bsdName {
                print("after:\t\(d.bsdName)\t\(d.state)\t\(d.mountPath?.path ?? "-")")
            }
        }
        print("extension enabled: \(String(describing: await Mounter.extensionEnabled()))")
    }
}
