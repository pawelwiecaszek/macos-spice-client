import Foundation
import Testing
@testable import SpiceClient

struct ConnectionFileDeliveryTests {
    @Test func duplicateDeliveryExpiresAndNewTicketsRemainUsable() {
        var history = ConnectionFileDeliveryHistory()
        let now = ContinuousClock.now
        let initial = history.accept(digest: "first-ticket", at: now)
        let duplicate = history.accept(digest: "first-ticket", at: now.advanced(by: .seconds(1)))
        let fresh = history.accept(digest: "fresh-ticket", at: now.advanced(by: .seconds(1)))
        let expired = history.accept(digest: "first-ticket", at: now.advanced(by: .seconds(6)))
        #expect(initial)
        #expect(!duplicate)
        #expect(fresh)
        #expect(expired)
    }

    @Test func lateDeliveryOfDeletedFileIsSuppressedBriefly() {
        var history = ConnectionFileDeliveryHistory()
        let url = URL(fileURLWithPath: "/tmp/example.vv")
        let now = ContinuousClock.now
        history.recordDeletion(of: url, at: now)
        let recent = history.wasJustDeleted(url, at: now.advanced(by: .seconds(1)))
        let expired = history.wasJustDeleted(url, at: now.advanced(by: .seconds(6)))
        #expect(recent)
        #expect(!expired)
    }

    @Test func cancellingAConnectionAllowsImmediateRetry() {
        var history = ConnectionFileDeliveryHistory()
        let now = ContinuousClock.now
        let initial = history.accept(digest: "ticket", at: now)
        history.discard(digest: "ticket")
        let retry = history.accept(digest: "ticket", at: now)
        #expect(initial)
        #expect(retry)
    }

    @Test func onlyMissingFilesQualifyForLateDeletionSuppression() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("guest.vv")
        try Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\ndelete-this-file=1\n".utf8)
            .write(to: url)
        if case .file(_, _, let deleteFailed) = SessionWindowManager.read(url) {
            #expect(!deleteFailed)
        } else { Issue.record("Expected a parsed and deleted connection file") }
        if case .failed(_, let missing) = SessionWindowManager.read(url) {
            #expect(missing)
        } else { Issue.record("Expected missing-file failure") }
        try Data("malformed replacement".utf8).write(to: url)
        if case .failed(_, let missing) = SessionWindowManager.read(url) {
            #expect(!missing)
        } else { Issue.record("Expected a visible parser failure for the new file") }
    }

    @Test func watchedFileMustMatchValidatedBytesAndCannotBecomeASymlink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("guest.vv")
        let contents = Data("[virt-viewer]\ntype=spice\nhost=example.invalid\nport=5930\n".utf8)
        try contents.write(to: url)
        if case .file = SessionWindowManager.read(url, expectedContents: contents) {} else {
            Issue.record("Expected validated contents to be accepted")
        }
        try (contents + Data("password=fresh\n".utf8)).write(to: url)
        if case .failed = SessionWindowManager.read(url, expectedContents: contents) {} else {
            Issue.record("Expected replaced contents to be refused")
        }
        let target = folder.appendingPathComponent("target.txt")
        try contents.write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        if case .failed = SessionWindowManager.read(url, expectedContents: contents) {} else {
            Issue.record("Expected substituted symlink to be refused")
        }
    }
}
