// Message type numbers from spice-protocol enums.h (BSD-licensed).
// Server→client enums are `…ServerMessage`, client→server are `…ClientMessage`.

/// `SPICE_MSG_*` common to every channel.
public enum BaseServerMessage: UInt16, Sendable {
    case migrate = 1
    case migrateData
    case setAck
    case ping
    case waitForChannels
    case disconnecting
    case notify
    case list
}

/// `SPICE_MSGC_*` common to every channel.
public enum BaseClientMessage: UInt16, Sendable {
    case ackSync = 1
    case ack
    case pong
    case migrateFlushMark
    case migrateData
    case disconnecting
}

/// `SPICE_MSG_MAIN_*`.
public enum MainServerMessage: UInt16, Sendable {
    case migrateBegin = 101
    case migrateCancel
    case initialize  // SPICE_MSG_MAIN_INIT
    case channelsList
    case mouseMode
    case multiMediaTime
    case agentConnected
    case agentDisconnected
    case agentData
    case agentToken
    case migrateSwitchHost
    case migrateEnd
    case name
    case uuid
    case agentConnectedTokens
    case migrateBeginSeamless
    case migrateDstSeamlessAck
    case migrateDstSeamlessNack
}

/// `SPICE_MSGC_MAIN_*`.
public enum MainClientMessage: UInt16, Sendable {
    case clientInfo = 101
    case migrateConnected
    case migrateConnectError
    case attachChannels
    case mouseModeRequest
    case agentStart
    case agentData
    case agentToken
    case migrateEnd
    case migrateDstDoSeamless
    case migrateConnectedSeamless
    case qualityIndicator
}

/// `SPICE_MSG_DISPLAY_*`.
public enum DisplayServerMessage: UInt16, Sendable {
    case mode = 101
    case mark
    case reset
    case copyBits
    case invalList
    case invalAllPixmaps
    case invalPalette
    case invalAllPalettes
    case streamCreate = 122
    case streamData
    case streamClip
    case streamDestroy
    case streamDestroyAll
    case drawFill = 302
    case drawOpaque
    case drawCopy
    case drawBlend
    case drawBlackness
    case drawWhiteness
    case drawInvers
    case drawRop3
    case drawStroke
    case drawText
    case drawTransparent
    case drawAlphaBlend
    case surfaceCreate
    case surfaceDestroy
    case streamDataSized
    case monitorsConfig
    case drawComposite
    case streamActivateReport
    case glScanoutUnix
    case glDraw
    case qualityIndicator
}

/// `SPICE_MSGC_DISPLAY_*`.
public enum DisplayClientMessage: UInt16, Sendable {
    case initialize = 101  // SPICE_MSGC_DISPLAY_INIT
    case streamReport
    case preferredCompression
    case glDrawDone
    case preferredVideoCodecType
}

/// `SPICE_MSG_INPUTS_*`.
public enum InputsServerMessage: UInt16, Sendable {
    case initialize = 101  // SPICE_MSG_INPUTS_INIT
    case keyModifiers
    case mouseMotionAck = 111
}

/// `SPICE_MSGC_INPUTS_*`.
public enum InputsClientMessage: UInt16, Sendable {
    case keyDown = 101
    case keyUp
    case keyModifiers
    case keyScancode
    case mouseMotion = 111
    case mousePosition
    case mousePress
    case mouseRelease
}

/// `SPICE_MSG_CURSOR_*`.
public enum CursorServerMessage: UInt16, Sendable {
    case initialize = 101  // SPICE_MSG_CURSOR_INIT
    case reset
    case set
    case move
    case hide
    case trail
    case invalOne
    case invalAll
}

/// `SPICE_MSG_SPICEVMC_*` / `SPICE_MSGC_SPICEVMC_*` (usbredir, port, webdav).
public enum SpiceVMCMessage: UInt16, Sendable {
    case data = 101
    case compressedData
}
