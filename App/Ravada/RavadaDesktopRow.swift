import Foundation
import SpiceKit

struct RavadaDesktopRow: Identifiable, Equatable {
    let machine: RavadaMachine
    let parentName: String?
    let portalOnly: Bool
    var id: Int { machine.id }
    var name: String { machine.alias.flatMap { $0.isEmpty ? nil : $0 } ?? machine.name }
    var stateLabel: String {
        if portalOnly { return String(localized: "Use Portal") }
        return machine.isActive == true ? String(localized: "Running") : String(localized: "Stopped")
    }

    static func rows(in catalog: RavadaCatalog) throws -> [Self] {
        var rows: [Self] = []
        for entry in catalog.entries {
            if entry.isBase == true && !entry.clones.isEmpty {
                rows += entry.clones.map { Self(machine: $0, parentName: entry.machine.alias ?? entry.machine.name,
                    portalOnly: $0.isLocked != false || $0.isActive == nil) }
            } else {
                rows.append(Self(machine: entry.machine, parentName: nil,
                    portalOnly: entry.isBase != false || entry.machine.isLocked != false || entry.machine.isActive == nil))
            }
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw RavadaBrokerError.invalidResponse }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

