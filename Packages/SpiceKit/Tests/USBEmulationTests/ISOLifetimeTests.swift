import Foundation
import Synchronization
import Testing
@testable import USBEmulation
import USBRedirWire

@Suite("ISO storage lifetime")
struct ISOLifetimeTests {
    @Test func closedDriveReleasesSourceOnceAndRejectsFurtherRequests() async {
        let source = ClosingBlockSource()
        let drive = EmulatedCDROM(source: source, name: "test.iso")
        #expect(await drive.setConfiguration(1) == .success)
        await drive.close()
        await drive.close()

        #expect(source.closeCount == 1)
        let descriptor = await drive.control(
            setup: USBControlSetup(requestType: 0x80, request: 6, value: 0x0100, index: 0, length: 18), data: [])
        #expect(descriptor.status == .ioerror)
        #expect(descriptor.data.isEmpty)
        #expect(await drive.bulk(endpoint: 0x81, data: [], length: 2048).status == .ioerror)
        #expect(await drive.interrupt(endpoint: 0x81, data: [], length: 8).status == .ioerror)
        #expect(await drive.setConfiguration(1) == .ioerror)
        #expect(await drive.configuration() == 0)
        #expect(await drive.setAltSetting(interface: 0, alt: 0) == .ioerror)
        #expect(await drive.altSetting(interface: 0) == nil)
        #expect(await drive.reset() == false)
        #expect(source.readCount == 0)
    }

    @Test func fileSourceRejectsReadsAfterExplicitCloseWhileStillRetained() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iso")
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileBlockSource(url: url)
        #expect(source.size == 4)
        #expect(try source.read(offset: 1, count: 2) == [2, 3])
        source.close()
        source.close()
        #expect(throws: POSIXError.self) { try source.read(offset: 0, count: 4) }
        #expect(source.size == 4)
    }
}

private final class ClosingBlockSource: BlockSource, Sendable {
    let size: UInt64 = 2048
    private let counts = Mutex((reads: 0, closes: 0))
    var closeCount: Int { counts.withLock { $0.closes } }
    var readCount: Int { counts.withLock { $0.reads } }

    func read(offset: UInt64, count: Int) throws -> [UInt8] {
        counts.withLock { $0.reads += 1 }
        return [UInt8](repeating: 0, count: count)
    }

    func close() { counts.withLock { $0.closes += 1 } }
}
