import Darwin
import Foundation
import SpiceKit

/// Polling and validation run on this actor, never on the UI actor.
actor DownloadScanner {
    struct Result: Sendable {
        var ready: [URL] = []
        var contents: [URL: Data] = [:]
        var skipped = 0
    }

    enum ScanError: Error, LocalizedError {
        case tooManyFiles

        var errorDescription: String? {
            String(localized: "This folder has too many files to monitor. Choose a smaller download folder.")
        }
    }

    private struct Stamp: Equatable, Sendable {
        let size: Int
        let modified: Date
        let inode: UInt64
    }

    private let folder: URL
    private var observed: [URL: Stamp] = [:]
    private var processed: [URL: Stamp] = [:]
    private var initialized = false
    private static let maxBytes = 1024 * 1024
    private static let maxEntries = 10_000

    init(folder: URL) {
        self.folder = folder
    }

    /// The first scan establishes a baseline so existing tickets are never opened.
    func poll() throws -> Result {
        let current = try snapshot()
        defer {
            observed = current
            initialized = true
        }
        guard initialized else {
            processed = current
            return Result()
        }

        processed = processed.filter { current[$0.key] != nil }
        var result = Result()
        for (url, stamp) in current {
            try Task.checkCancellation()
            // Limit each handoff to 16 MiB even if a folder receives a large burst.
            if result.ready.count >= 16 { break }
            guard processed[url] != stamp, observed[url] == stamp else { continue }
            // A stable invalid file is checked once. A later write changes the stamp,
            // allowing an incomplete download to become a new candidate.
            processed[url] = stamp
            guard stamp.size > 0, stamp.size <= Self.maxBytes,
                  let data = Self.validatedContents(url, expected: stamp) else {
                result.skipped += 1
                continue
            }
            result.ready.append(url)
            result.contents[url] = data
        }
        return result
    }

    private func snapshot() throws -> [URL: Stamp] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                       .contentModificationDateKey]
        var enumerationError: (any Error)?
        guard let entries = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        var snapshot: [URL: Stamp] = [:]
        var count = 0
        for case let url as URL in entries {
            try Task.checkCancellation()
            count += 1
            guard count <= Self.maxEntries else { throw ScanError.tooManyFiles }
            guard url.pathExtension.lowercased() == "vv" else { continue }
            // Browsers normally rename their temporary file only once complete.
            // Safari can also keep a directory with the final name plus .download.
            guard !FileManager.default.fileExists(atPath: url.path + ".crdownload"),
                  !FileManager.default.fileExists(atPath: url.path + ".part"),
                  !FileManager.default.fileExists(atPath: url.path + ".download") else { continue }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, let modified = values.contentModificationDate,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            snapshot[url] = Stamp(size: size, modified: modified, inode: inode)
        }
        if let enumerationError { throw enumerationError }
        return snapshot
    }

    private static func validatedContents(_ url: URL, expected: Stamp) -> Data? {
        // Refuse symlinks even if the path was replaced after enumeration.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size == expected.size,
              UInt64(before.st_ino) == expected.inode else { return nil }
        do {
            let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
            var after = stat()
            guard data.count == expected.size, data.count <= maxBytes,
                  fstat(descriptor, &after) == 0,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
            _ = try VVFileParser.parse(Array(data))
            return data
        } catch {
            return nil
        }
    }
}
