// App.swift - MAC_NTFS menu-bar app.

import AppKit
import SwiftUI

@main
struct MacNTFSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("MAC_NTFS", systemImage: "externaldrive") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    let monitor = DiskMonitor()
    @Published var busy: Set<String> = []
    @Published var lastError: String?
    @Published var extensionEnabled: Bool?
    @AppStorage("autoMountReadWrite") var autoMount = false

    init() {
        monitor.onAppear = { [weak self] disk in
            guard let self, self.autoMount, disk.state == .systemReadOnly else { return }
            self.perform(disk) { try await Mounter.mountReadWrite(disk) }
        }
        Task { extensionEnabled = await Mounter.extensionEnabled() }
    }

    func perform(_ disk: NTFSDisk, _ action: @escaping () async throws -> Void) {
        busy.insert(disk.bsdName)
        lastError = nil
        Task {
            do {
                try await action()
            } catch {
                lastError = error.localizedDescription
            }
            busy.remove(disk.bsdName)
            monitor.refresh()
            extensionEnabled = await Mounter.extensionEnabled()
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: DiskMonitor

    init(model: AppModel) {
        self.model = model
        self.monitor = model.monitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NTFS drives").font(.headline)

            if model.extensionEnabled == false || model.extensionEnabled == nil {
                ExtensionNotice(enabled: model.extensionEnabled)
            }

            if monitor.disks.isEmpty {
                Text("No NTFS drives connected.").foregroundStyle(.secondary)
            }
            ForEach(monitor.disks) { disk in
                DiskRow(disk: disk, busy: model.busy.contains(disk.bsdName), model: model)
            }

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }

            Divider()
            Toggle("Mount new NTFS drives read-write automatically", isOn: model.$autoMount)
                .font(.callout)
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

struct ExtensionNotice: View {
    let enabled: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(enabled == nil ? "File system extension not registered"
                                 : "File system extension is turned off",
                  systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
            Text("Turn on MAC_NTFS in System Settings › General › Login Items & Extensions › File System Extensions.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct DiskRow: View {
    let disk: NTFSDisk
    let busy: Bool
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading) {
                    Text(disk.displayName).font(.body.weight(.medium))
                    Text("\(disk.bsdName) · \(ByteCountFormatter.string(fromByteCount: disk.size, countStyle: .file)) · \(status)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if disk.state == .protectedReadOnly {
                Text("Windows didn't fully shut down (Fast Startup or hibernation), so writing could corrupt the drive. "
                     + "In Windows, hold Shift while choosing Shut Down, or turn off Fast Startup, then reconnect.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                switch disk.state {
                case .unmounted, .systemReadOnly:
                    Button("Mount read-write") { model.perform(disk) { try await Mounter.mountReadWrite(disk) } }
                case .readWrite, .protectedReadOnly:
                    Button("Use macOS read-only") { model.perform(disk) { try await Mounter.remountSystemReadOnly(disk) } }
                }
                if let path = disk.mountPath {
                    Button("Show") { NSWorkspace.shared.open(path) }
                    Button("Eject") { model.perform(disk) { try await Mounter.eject(disk) } }
                }
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }

    var status: String {
        switch disk.state {
        case .unmounted:         return "not mounted"
        case .systemReadOnly:    return "read-only (macOS)"
        case .readWrite:         return "read-write"
        case .protectedReadOnly: return "read-only (protected)"
        }
    }

    var icon: String {
        switch disk.state {
        case .readWrite:         return "externaldrive.fill.badge.checkmark"
        case .protectedReadOnly: return "externaldrive.badge.exclamationmark"
        default:                 return "externaldrive"
        }
    }

    var color: Color {
        switch disk.state {
        case .readWrite:         return .green
        case .protectedReadOnly: return .orange
        default:                 return .secondary
        }
    }
}
