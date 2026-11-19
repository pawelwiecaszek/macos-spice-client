import AppKit
import Observation

/// Opt-in automatic opening for newly downloaded connection files.
@MainActor
@Observable
final class DownloadWatcher {
    static let shared = DownloadWatcher()

    private(set) var isWatching = false
    private(set) var folder: URL?
    private(set) var errorMessage: String?
    private(set) var skippedFiles = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    /// Folder permission is intentionally session-only; no bookmark entitlement is needed.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Watch Folder")
        panel.message = String(localized: "New .vv files in this folder will open automatically while the app is running.")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(folder: url)
    }

    func start(folder url: URL) {
        stop()
        errorMessage = nil
        skippedFiles = 0
        folder = url
        let accessing = url.startAccessingSecurityScopedResource()
        let scanner = DownloadScanner(folder: url)
        let currentGeneration = UUID()
        generation = currentGeneration
        isWatching = true
        task = Task { [weak self] in
            // Keep directory access alive until any outstanding scanner operation ends.
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                while !Task.isCancelled {
                    let result = try await scanner.poll()
                    try Task.checkCancellation()
                    guard let self, self.generation == currentGeneration else { return }
                    self.skippedFiles += result.skipped
                    for file in result.ready {
                        guard !Task.isCancelled, self.generation == currentGeneration else { return }
                        guard let contents = result.contents[file] else { continue }
                        SessionWindowManager.shared.open(file, expectedContents: contents)
                    }
                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.errorMessage = String(localized: "The folder could not be monitored. Check access and choose the folder again.")
                if let scanError = error as? DownloadScanner.ScanError {
                    self.errorMessage = scanError.localizedDescription
                }
                self.isWatching = false
                self.folder = nil
                self.task = nil
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isWatching = false
        folder = nil
        errorMessage = nil
    }
}
