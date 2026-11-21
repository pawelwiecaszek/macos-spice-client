import Testing
import SpiceAgent
import SpiceWire

@Suite("Clipboard codec")
struct ClipboardCodecTests {
    @Test func grabWithAndWithoutSelectionHeader() throws {
        let withHeader = ClipboardCodec.grab([.utf8Text, .png], selectionHeader: true)
        #expect(withHeader.knownType == .clipboardGrab)
        #expect(withHeader.data == [0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0])
        #expect(try ClipboardCodec.decode(withHeader, selectionHeader: true) == .grab(selection: .clipboard, types: [.utf8Text, .png]))

        let bare = ClipboardCodec.grab([.utf8Text], selectionHeader: false)
        #expect(bare.data == [1, 0, 0, 0])
        #expect(try ClipboardCodec.decode(bare, selectionHeader: false) == .grab(selection: .clipboard, types: [.utf8Text]))
    }

    @Test func dataRoundTripAndPrimarySelection() throws {
        let message = AgentMessage(type: .clipboard, data: [1, 0, 0, 0, 1, 0, 0, 0] + Array("hi".utf8))
        #expect(try ClipboardCodec.decode(message, selectionHeader: true) == .data(selection: .primary, type: .utf8Text, bytes: Array("hi".utf8)))
        let request = AgentMessage(type: .clipboardRequest, data: [0, 0, 0, 0, 2, 0, 0, 0])
        #expect(try ClipboardCodec.decode(request, selectionHeader: true) == .request(selection: .clipboard, type: .png))
        #expect(try ClipboardCodec.decode(AgentMessage(type: .clipboardRelease, data: [0, 0, 0, 0]), selectionHeader: true)
                == .release(selection: .clipboard))
        #expect(try ClipboardCodec.decode(AgentMessage(type: .mouseState, data: []), selectionHeader: true) == nil)
    }

    @Test func truncatedMessagesThrow() {
        #expect(throws: WireError.self) {
            try ClipboardCodec.decode(AgentMessage(type: .clipboardRequest, data: [0, 0]), selectionHeader: true)
        }
    }

    @Test func lineEndings() {
        #expect(ClipboardCodec.textToGuest("a\nb\r\nc", guestUsesCRLF: true) == Array("a\r\nb\r\nc".utf8))
        #expect(ClipboardCodec.textToGuest("a\r\nb", guestUsesCRLF: false) == Array("a\nb".utf8))
        #expect(ClipboardCodec.textFromGuest(Array("x\r\ny".utf8) + [0, 0]) == "x\ny")
    }

    @Test func controlLayoutsAreExactAndUnknownTypesStillCountTowardLimit() throws {
        let unknown = [UInt8](repeating: 0xFF, count: 65 * 4)
        #expect(throws: WireError.limitExceeded("clipboard types")) {
            try ClipboardCodec.decode(AgentMessage(type: .clipboardGrab, data: unknown), selectionHeader: false)
        }
        #expect(try ClipboardCodec.decode(AgentMessage(type: .clipboardGrab, data: Array(unknown.prefix(64 * 4))),
                                         selectionHeader: false) == .grab(selection: .clipboard, types: []))
        #expect(throws: WireError.self) {
            try ClipboardCodec.decode(AgentMessage(type: .clipboardGrab, data: [1]), selectionHeader: false)
        }
        #expect(throws: WireError.self) {
            try ClipboardCodec.decode(AgentMessage(type: .clipboardRequest, data: [1, 0, 0, 0, 0]), selectionHeader: false)
        }
        #expect(throws: WireError.self) {
            try ClipboardCodec.decode(AgentMessage(type: .clipboardRelease, data: [0]), selectionHeader: false)
        }
    }

    @Test func noneAndMatchingEmptyDataAreBothValidFailureReplies() throws {
        for type in [ClipboardDataType.none, .utf8Text, .png] {
            #expect(try ClipboardCodec.decode(ClipboardCodec.data(type, bytes: [], selectionHeader: true),
                                             selectionHeader: true) == .data(selection: .clipboard, type: type, bytes: []))
        }
    }
}
