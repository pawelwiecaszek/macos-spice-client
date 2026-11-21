import SpiceKit
import Testing

struct GuestMonitorLayoutTests {
    @Test func singleOriginHeadNeedsOnlyMonitorConfigurationCapability() throws {
        let layout = try #require(GuestMonitorLayout([monitor(0, width: 800, height: 600)]))
        #expect(layout.message(capabilities: CapabilitySet()) == nil)
        let message = try #require(layout.message(capabilities: capabilities(.monitorsConfig)))
        let decoded = try decode(message)
        #expect(message.knownType == .monitorsConfig)
        #expect(decoded.flags == 0 && decoded.monitors == [monitor(0, width: 800, height: 600)])
    }

    @Test func sparseIDsKeepArraySlotIdentityAndDisableMissingHeads() throws {
        let layout = try #require(GuestMonitorLayout([monitor(3, x: 400), monitor(1)]))
        #expect(layout.monitors.map(\.id) == [1, 3])
        #expect(layout.message(capabilities: capabilities(.monitorsConfig, .monitorsConfigPosition)) == nil)
        #expect(layout.message(capabilities: capabilities(.monitorsConfig, .sparseMonitorsConfig)) == nil)
        let message = try #require(layout.message(capabilities: fullCapabilities))
        let decoded = try decode(message)
        #expect(decoded.flags == 1)
        #expect(decoded.monitors == [monitor(0, width: 0, height: 0), monitor(1),
                                    monitor(2, width: 0, height: 0), monitor(3, x: 400)])
    }

    @Test func explicitDisabledHeadRequiresSparseAndEncodesZeroPosition() throws {
        let disabled = monitor(1, width: 0, height: 0, x: .max, y: .min)
        let layout = try #require(GuestMonitorLayout([monitor(0), disabled]))
        #expect(layout.monitors[1] == disabled)
        #expect(layout.message(capabilities: capabilities(.monitorsConfig)) == nil)
        let message = try #require(layout.message(capabilities: capabilities(.monitorsConfig, .sparseMonitorsConfig)))
        #expect(try decode(message).monitors == [monitor(0), monitor(1, width: 0, height: 0)])
    }

    @Test func positionsAndMultipleHeadsRequirePositionCapability() throws {
        let shifted = try #require(GuestMonitorLayout([monitor(0, x: -400, y: -200)]))
        #expect(shifted.message(capabilities: capabilities(.monitorsConfig)) == nil)
        #expect(try decode(#require(shifted.message(capabilities: fullCapabilities))).monitors == shifted.monitors)
        let pair = try #require(GuestMonitorLayout([monitor(0), monitor(1, x: 400)]))
        #expect(pair.message(capabilities: capabilities(.monitorsConfig, .sparseMonitorsConfig)) == nil)
        #expect(try decode(#require(pair.message(capabilities: fullCapabilities))).monitors == pair.monitors)
    }

    @Test func highestByteIDUsesBoundedSlotsWithoutRenumbering() throws {
        let layout = try #require(GuestMonitorLayout([monitor(255)]))
        let decoded = try decode(#require(layout.message(capabilities: fullCapabilities)))
        #expect(decoded.monitors.count == 256)
        #expect(decoded.monitors[254] == monitor(254, width: 0, height: 0))
        #expect(decoded.monitors[255] == monitor(255))
    }

    @Test func horizontalAndVerticalReflowPreserveGapsAndUnrelatedSizes() throws {
        let layout = try #require(GuestMonitorLayout([
            monitor(0), monitor(1, width: 200, x: 450), monitor(2, height: 100, y: 350),
            monitor(3, width: 200, height: 100, x: 450, y: 350),
        ]))
        let larger = try #require(layout.resizing(id: 0, width: 500, height: 400))
        #expect(larger.monitors == [monitor(0, width: 500, height: 400), monitor(1, width: 200, x: 550),
                                   monitor(2, height: 100, y: 450), monitor(3, width: 200, height: 100, x: 550, y: 450)])
        #expect(larger.resizing(id: 0, width: 400, height: 300) == layout)
        #expect(try decode(#require(larger.message(capabilities: fullCapabilities))).monitors == larger.monitors)
    }

    @Test func resizingOneHeadRetainsNegativeOriginsAndDisabledEntries() throws {
        let disabled = monitor(7, width: 0, height: 0, x: 999, y: -999)
        let layout = try #require(GuestMonitorLayout([monitor(2, x: -500, y: -300), monitor(4, x: 0, y: -300), disabled]))
        let resized = try #require(layout.resizing(id: 2, width: 450, height: 300))
        #expect(resized.monitors == [monitor(2, width: 450, x: -500, y: -300), monitor(4, x: 50, y: -300), disabled])
        #expect(layout.resizing(id: 7, width: 400, height: 300) == nil)
        #expect(layout.resizing(id: 1, width: 400, height: 300) == nil)
    }

    @Test func malformedAndExcessiveSetsRejectBeforeEncoding() {
        #expect(GuestMonitorLayout([]) == nil)
        #expect(GuestMonitorLayout((0..<17).map { monitor(UInt8($0), width: 1, x: Int32($0)) }) == nil)
        #expect(GuestMonitorLayout([monitor(0), monitor(0, x: 400)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, width: 0)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, height: 0)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, width: 0, height: 0)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, width: 16_385)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, height: 16_385)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, x: .max)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, y: .max)]) == nil)
        #expect(GuestMonitorLayout([monitor(0), monitor(1, x: 399)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, width: 16_384, height: 16_384), monitor(1, x: 16_384)]) == nil)
        #expect(GuestMonitorLayout([monitor(0, width: 16_384, height: 16_384)]) != nil)
    }

    @Test func resizeRejectsNewOverlapEdgeOverflowAndInvalidDimensions() throws {
        // Shrinking shifts the right-hand head left into an unshifted head
        // above the target; the resulting overlap must reject the request.
        let overlap = try #require(GuestMonitorLayout([monitor(0, width: 100, height: 100),
            monitor(1, width: 50, height: 100, x: 50, y: -100),
            monitor(2, width: 100, height: 100, x: 100, y: -100)]))
        #expect(overlap.resizing(id: 0, width: 50, height: 100) == nil)
        let edge = try #require(GuestMonitorLayout([monitor(0, width: 1, height: 1),
                                                   monitor(1, width: 1, height: 1, x: Int32.max - 1)]))
        #expect(edge.resizing(id: 0, width: 2, height: 1) == nil)
        let underflow = try #require(GuestMonitorLayout([monitor(0, width: 400, height: 1, x: .min),
                                                        monitor(1, width: 1, height: 1, x: Int32.min + 400)]))
        #expect(underflow.resizing(id: 0, width: 1, height: 1) != nil)
        #expect(edge.resizing(id: 0, width: 0, height: 1) == nil)
        #expect(edge.resizing(id: 0, width: 16_385, height: 1) == nil)
    }

    private var fullCapabilities: CapabilitySet {
        capabilities(.monitorsConfig, .sparseMonitorsConfig, .monitorsConfigPosition)
    }

    private func capabilities(_ values: AgentCapability...) -> CapabilitySet {
        CapabilitySet(bits: values.map(\.rawValue))
    }

    private func monitor(_ id: UInt8, width: UInt32 = 400, height: UInt32 = 300,
                         x: Int32 = 0, y: Int32 = 0) -> GuestMonitor {
        GuestMonitor(id: id, width: width, height: height, x: x, y: y)
    }

    private func decode(_ message: AgentMessage) throws -> (flags: UInt32, monitors: [GuestMonitor]) {
        var reader = ByteReader(message.data)
        let count = try reader.readU32(), flags = try reader.readU32()
        var monitors: [GuestMonitor] = []
        for id in 0..<count {
            let height = try reader.readU32(), width = try reader.readU32(), depth = try reader.readU32()
            #expect(depth == 32)
            monitors.append(monitor(UInt8(id), width: width, height: height, x: try reader.readI32(), y: try reader.readI32()))
        }
        #expect(reader.isAtEnd)
        return (flags, monitors)
    }
}
