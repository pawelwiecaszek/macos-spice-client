import AppKit
import CryptoKit
import Darwin
import SpiceKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Opens `.vv` files and manages one window per session.
@MainActor
final class SessionWindowManager: NSObject, NSWindowDelegate {
    static let shared = SessionWindowManager()

    private var windows: [UUID: (window: NSWindow, controller: SessionController)] = [:]
    private let log = Logger(subsystem: "com.pawelwiecaszek.spiceclient", category: "app")
    private var openingFiles: Set<URL> = []
    private var deliveryHistory = ConnectionFileDeliveryHistory()

    var hasSessions: Bool { !windows.isEmpty }

    /// The session of the key window, for menu commands.
    var keyController: SessionController? {
        guard let key = NSApp.keyWindow else { return nil }
        return windows.values.first { $0.window === key }?.controller
    }

    // MARK: Opening files

    /// Connection files are a few KiB; anything bigger isn't one.
    private nonisolated static let maxConnectionFileBytes = 1024 * 1024

    enum ReadResult: Sendable {
        case file(VVFile, digest: String, deleteFailed: Bool)
        case failed(String, missing: Bool = false)
    }

    /// Reads and parses off the main actor, then connects immediately (Proxmox tickets
    /// expire in ~30 s).
    func open(_ url: URL, expectedContents: Data? = nil) {
        guard url.isFileURL else { return }
        let key = url.standardizedFileURL
        guard openingFiles.insert(key).inserted else { return }
        Task {
            defer { openingFiles.remove(key) }
            let result = await Task.detached(priority: .userInitiated) {
                Self.read(url, expectedContents: expectedContents)
            }.value
            switch result {
            case .failed(let message, let missing):
                if missing && deliveryHistory.wasJustDeleted(key) { return }
                presentError(message, file: url)
            case .file(let file, let digest, let deleteFailed):
                if file.profile.deleteThisFile && !deleteFailed { deliveryHistory.recordDeletion(of: key) }
                guard deliveryHistory.accept(digest: digest) else { return }
                log.debug("vv file parsed with \(file.warnings.count, privacy: .public) warning(s)")
                for warning in file.warnings { log.debug("vv warning: \(String(describing: warning), privacy: .private)") }
                if deleteFailed { log.debug("could not delete the connection file") }
                // Note: a downloaded .vv is NOT trusted to teach the app a CA for the Proxmox
                // API (anyone can craft one); CAs are only learned from files fetched over the API.
                if !openSession(file.profile) { deliveryHistory.discard(digest: digest) }
            }
        }
    }

    nonisolated static func read(_ url: URL, expectedContents: Data? = nil) -> ReadResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file: VVFile
        let digest: String
        do {
            // A watcher candidate can be replaced before delivery. Never follow a symlink
            // or block on a substituted pipe; validate and read the same descriptor.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else {
                let missing = errno == ENOENT
                return .failed(String(localized: "The connection file could not be read."), missing: missing)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
                return .failed(String(localized: "Choose a regular connection file."))
            }
            // Read one byte past the limit to tell "exactly at the limit" from "too big".
            let data = try handle.read(upToCount: maxConnectionFileBytes + 1) ?? Data()
            guard data.count <= maxConnectionFileBytes else {
                return .failed(String(localized: "The file is too large to be a connection file."))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  expectedContents.map({ $0 == data }) ?? true else {
                return .failed(String(localized: "The connection file changed while it was being opened. Try again after the download finishes."))
            }
            file = try VVFileParser.parse(Array(data))
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch let error as VVFileError {
            return .failed(error.localizedDescription)
        } catch {
            return .failed(String(localized: "The connection file could not be read."))
        }
        var deleteFailed = false
        if file.profile.deleteThisFile {
            do { try FileManager.default.removeItem(at: url) } catch { deleteFailed = true }
        }
        return .file(file, digest: digest, deleteFailed: deleteFailed)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(importedAs: "com.pawelwiecaszek.spiceclient.vv")]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose a virt-viewer connection file (.vv)")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    // MARK: Windows

    @discardableResult
    func openSession(_ profile: ConnectionProfile, settings: AppSettings = .shared) -> Bool {
        guard confirmUnencrypted(profile) else { return false }
        let controller = SessionController(profile: profile, settings: settings)
        let hosting = NSHostingController(rootView: SessionView(controller: controller))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        // No .fullSizeContentView: the toolbar must never cover the guest display.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = controller.title
        window.toolbarStyle = .unified
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.contentMinSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("")
        window.center()
        controller.window = window
        windows[controller.id] = (window, controller)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        WelcomeWindow.shared.close()
        controller.start()
        if profile.fullscreen { window.toggleFullScreen(nil) }
        return true
    }

    /// Puts a new session for the same VM into an existing window (reconnect, M8); the
    /// window keeps its place, size and full-screen state.
    func replace(_ old: SessionController, with profile: ConnectionProfile, context: ReconnectContext) {
        guard let entry = windows[old.id] else { return }
        let window = entry.window
        old.stop()
        windows.removeValue(forKey: old.id)
        let controller = SessionController(profile: profile, settings: old.sessionSettings, reconnect: context)
        let hosting = NSHostingController(rootView: SessionView(controller: controller))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let frame = window.frame
        let fullScreen = window.styleMask.contains(.fullScreen)
        window.contentViewController = hosting
        if !fullScreen { window.setFrame(frame, display: true) }
        controller.window = window
        windows[controller.id] = (window, controller)
        controller.start()
        if window.isKeyWindow, let view = controller.displayView { window.makeFirstResponder(view) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = windows.first(where: { $0.value.window === window }) else { return }
        entry.value.controller.stop()
        windows.removeValue(forKey: entry.key)
    }

    func closeAll() {
        for entry in windows.values { entry.controller.stop() }
    }

    /// Without TLS nothing is protected: the screen, keystrokes and clipboard travel in the
    /// clear, and the server's ticket-encryption key isn't authenticated, so anyone on the
    /// path could impersonate the server. Ask before every connection that would send any
    /// channel in the clear, including partially encrypted sessions where `secure-channels`
    /// covers only some channels (reconnects in the same window don't ask again).
    private func confirmUnencrypted(_ profile: ConnectionProfile) -> Bool {
        let alert = NSAlert()
        switch profile.plaintextExposure {
        case .encrypted:
            return true
        case .unencrypted:
            alert.messageText = String(localized: "Connect without encryption?")
            alert.informativeText = String(localized: """
                “\(profile.displayTitle)” offers no TLS port, so this connection isn’t encrypted or \
                authenticated. Anyone on the network path can see the screen and your keystrokes, \
                and could pretend to be the server. Only continue on a network you trust.
                """)
        case .partial(let channels):
            let names = channels.map(\.rawValue).sorted().formatted(.list(type: .and))
            alert.messageText = String(localized: "Connect with partial encryption?")
            alert.informativeText = String(localized: """
                “\(profile.displayTitle)” encrypts only some channels. These would travel \
                unencrypted: \(names). Anyone on the network path could see or alter that \
                traffic, which may include the screen, your keystrokes or the clipboard. Only \
                continue on a network you trust.
                """)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Connect Anyway"))
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func presentError(_ message: String, file: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Can’t open “\(file.lastPathComponent)”")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
