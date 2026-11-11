import Foundation

struct ClientHelpTopic: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let sections: [Section]
    var links: [Reference] = []

    struct Section: Identifiable, Sendable {
        var id: String { title }
        let title: String
        let text: String
    }
    struct Reference: Identifiable, Sendable {
        var id: String { address }
        let title: String
        let address: String
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || ([title, summary] + sections.flatMap { [$0.title, $0.text] })
            .contains { $0.localizedStandardContains(query) }
    }
}
