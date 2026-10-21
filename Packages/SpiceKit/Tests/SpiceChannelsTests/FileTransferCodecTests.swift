import Testing
import SpiceAgent
import SpiceWire

@Suite("File transfer codec")
struct FileTransferCodecTests {
    @Test func startCarriesAKeyFile() {
        let message = FileTransferCodec.start(id: 7, name: "report.pdf", size: 1234)
        #expect(message.knownType == .fileXferStart)
        #expect(Array(message.data.prefix(4)) == [7, 0, 0, 0])
        let text = String(decoding: message.data.dropFirst(4).dropLast(), as: UTF8.self)
        #expect(text == "[vdagent-file-xfer]\nname=report.pdf\nsize=1234\n")
        #expect(message.data.last == 0)
    }

    @Test func namesCannotEscapeTheDownloadFolder() {
        let message = FileTransferCodec.start(id: 1, name: "../evil\nname=x/..\\y", size: 1)
        let text = String(decoding: message.data.dropFirst(4).dropLast(), as: UTF8.self)
        #expect(text == "[vdagent-file-xfer]\nname=_._evil_name=x_.._y\nsize=1\n")
    }

    @Test func dataAndStatus() {
        let data = FileTransferCodec.data(id: 2, bytes: [9, 9, 9][...])
        #expect(data.data == [2, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 9, 9, 9])
        let status = AgentMessage(type: .fileXferStatus, data: [2, 0, 0, 0, 3, 0, 0, 0])
        #expect(FileTransferCodec.decodeStatus(status)! == (2, .success))
        #expect(FileTransferCodec.decodeStatus(AgentMessage(type: .fileXferStatus, data: [1])) == nil)
    }
}
