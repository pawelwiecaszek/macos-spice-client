import Foundation
import Testing
@testable import SpiceClient

struct DownloadScannerTests {
    private let valid = Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\n".utf8)

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func onlyNewStableFilesAreDeliveredOnce() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try valid.write(to: folder.appendingPathComponent("old.vv"))
        let scanner = DownloadScanner(folder: folder)
        #expect(try await scanner.poll().ready.isEmpty)
        let fresh = folder.appendingPathComponent("fresh.vv")
        try valid.write(to: fresh)
        #expect(try await scanner.poll().ready.isEmpty)
        #expect(try await scanner.poll().ready == [fresh])
        #expect(try await scanner.poll().ready.isEmpty)

        // A fresh browser ticket saved over the same filename is a new candidate.
        try (valid + Data("password=new-ticket\n".utf8)).write(to: fresh, options: .atomic)
        #expect(try await scanner.poll().ready.isEmpty)
        #expect(try await scanner.poll().ready == [fresh])
    }

    @Test func partialDownloadWaitsForCompletionAndValidContent() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanner = DownloadScanner(folder: folder)
        _ = try await scanner.poll()
        let file = folder.appendingPathComponent("guest.vv")
        try Data("[virt-viewer]\n".utf8).write(to: file)
        _ = try await scanner.poll()
        #expect(try await scanner.poll().ready.isEmpty)
        try valid.write(to: file)
        let partial = folder.appendingPathComponent("guest.vv.crdownload")
        try Data().write(to: partial)
        _ = try await scanner.poll()
        #expect(try await scanner.poll().ready.isEmpty)
        try FileManager.default.removeItem(at: partial)
        #expect(try await scanner.poll().ready.isEmpty)
        #expect(try await scanner.poll().ready == [file])
    }

    @Test func rejectsOversizedInvalidAndSymbolicLinkFiles() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scanner = DownloadScanner(folder: folder)
        _ = try await scanner.poll()
        try Data(repeating: 65, count: 1024 * 1024 + 1)
            .write(to: folder.appendingPathComponent("large.vv"))
        try Data("not a connection file".utf8).write(to: folder.appendingPathComponent("invalid.vv"))
        let target = folder.appendingPathComponent("target.txt")
        try valid.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.vv"), withDestinationURL: target)
        _ = try await scanner.poll()
        let result = try await scanner.poll()
        #expect(result.ready.isEmpty)
        #expect(result.skipped == 2)
        #expect(try await scanner.poll().skipped == 0)
    }
}
