import SwiftUI

struct ClientHelpView: View {
    let initialTopicID: String
    let requestID: UUID
    @State private var selection: String?
    @State private var query = ""

    init(initialTopicID: String, requestID: UUID) {
        self.initialTopicID = initialTopicID
        self.requestID = requestID
        _selection = State(initialValue: initialTopicID)
    }

    private var filtered: [ClientHelpTopic] { ClientHelpContent.topics.filter { $0.matches(query) } }
    private var selected: ClientHelpTopic? { filtered.first { $0.id == selection } ?? filtered.first }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Help").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                TextField("Search help", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clientHelpSearch")
                List(filtered, selection: $selection) { topic in
                    Label(topic.title, systemImage: topic.symbol)
                        .tag(topic.id)
                        .accessibilityIdentifier("clientHelpTopic-\(topic.id)")
                }
                .listStyle(.sidebar)
            }
            .padding(12)
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            if let topic = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(topic.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        Text(topic.summary).foregroundStyle(.secondary)
                        ForEach(topic.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                                Text(section.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !topic.links.isEmpty {
                            Divider()
                            Text("Official References").font(.headline)
                            ForEach(topic.links) { reference in
                                if let url = URL(string: reference.address) { Link(reference.title, destination: url) }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .id(topic.id)
            } else {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("clientHelpGuide")
        .onChange(of: requestID) { _, _ in selection = initialTopicID; query = "" }
        .onChange(of: query) { _, _ in
            if !filtered.contains(where: { $0.id == selection }) { selection = filtered.first?.id }
        }
    }
}
