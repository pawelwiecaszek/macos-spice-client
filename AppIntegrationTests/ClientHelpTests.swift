import AppKit
import Carbon.HIToolbox
import Testing
@testable import SpiceClient

@MainActor
struct ClientHelpTests {
    @Test func helpShortcutStaysLocalWhileOtherCommandKeysCanReachGuest() throws {
        let view = RemoteDisplayView(renderer: try MetalRenderer())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        #expect(window.makeFirstResponder(view))
        view.sendsCommandToGuest = true
        let help = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "?", charactersIgnoringModifiers: "?", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Slash)))
        #expect(!view.performKeyEquivalent(with: help))
        let slash = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Slash)))
        #expect(view.performKeyEquivalent(with: slash))
    }
    @Test func helpEventRoutingDoesNotCaptureOtherGuestCommandChords() throws {
        func event(_ text: String, _ ignored: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: ignored, isARepeat: false, keyCode: UInt16(kVK_ANSI_Slash)))
        }
        #expect(ClientHelpShortcut.matches(try event("?", "?", [.command, .shift])))
        #expect(ClientHelpShortcut.matches(try event("/", "?", [.command, .shift])))
        #expect(!ClientHelpShortcut.matches(try event("/", "/", [.command])))
        #expect(!ClientHelpShortcut.matches(try event("?", "?", [.command, .control, .shift])))
        #expect(!ClientHelpShortcut.matches(try event("?", "?", [.command, .option, .shift])))
        #expect(!ClientHelpShortcut.matches(try event("?", "?", [.shift])))
    }

}
