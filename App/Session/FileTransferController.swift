import AppKit
import Observation
import SpiceKit

/// Copies files into the guest through spice-vdagent (drag & drop or "Send Files…").
/// Files are sent one after another; they land in the guest agent's download folder.
@MainActor
@Observable
final class FileTransferController {
    private(set) var currentName: String?
    private(set) var fraction: Double = 0
    private(set) var queued = 0
    var errorMessage: String?

    @ObservationIgnored private let session: SpiceSession
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(session: SpiceSession) {
        self.session = session
    }

    var isBusy: Bool { currentName != nil }

    func chooseAndSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose files to copy into the virtual machine")
        guard panel.runModal() == .OK else { return }
        send(panel.urls)
    }

    func send(_ urls: [URL]) {
        // Dropped files come with a sandbox extension; keep it while the file is queued.
        for url in urls where url.startAccessingSecurityScopedResource() || FileManager.default.isReadableFile(atPath: url.path) {
            queue.append(url)
        }
        queued = queue.count
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        for url in queue { url.stopAccessingSecurityScopedResource() }
        queue.removeAll()
        queued = 0
        currentName = nil
    }

    private func drain() async {
        let session = self.session
        while !queue.isEmpty, !Task.isCancelled {
            let url = queue.removeFirst()
            queued = queue.count
            currentName = url.lastPathComponent
            fraction = 0
            do {
                try await session.sendFile(url) { sent, total in
                    let value = total > 0 ? Double(sent) / Double(total) : 1
                    Task { @MainActor in self.fraction = value }
                }
            } catch is CancellationError {
                url.stopAccessingSecurityScopedResource()
                break
            } catch {
                let reason = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMessage = String(localized: "“\(url.lastPathComponent)” wasn’t copied: \(reason)")
            }
            url.stopAccessingSecurityScopedResource()
        }
        currentName = nil
        worker = nil
    }
}
