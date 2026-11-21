import SwiftUI

struct RavadaDesktopListView: View {
    @Bindable var store: RavadaDesktopStore
    let openPortal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("My Desktops").font(.title2.bold())
                    Text(store.profileName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Portal", systemImage: "globe", action: openPortal)
                Button("Refresh", systemImage: "arrow.clockwise") { store.refresh() }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("refreshRavadaDesktops")
            }
            .padding()
            HStack {
                TextField("Search desktops", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("ravadaDesktopSearch")
                Toggle("Favorites", isOn: $store.favoritesOnly).toggleStyle(.button)
                    .accessibilityIdentifier("ravadaDesktopFavoritesOnly")
            }.padding(.horizontal).padding(.bottom)
            if let progress = store.progressMessage {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress)
                    Spacer()
                    Button("Cancel") { store.cancel() }
                }.padding().background(.bar)
            }
            if let error = store.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle")
                    Spacer()
                    Button("Open in Portal", action: openPortal)
                }.padding().background(.bar)
                .accessibilityIdentifier("ravadaDesktopError")
            }
            if let status = store.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                    .accessibilityIdentifier("ravadaDesktopStatus")
            }
            if store.isRefreshing {
                VStack(spacing: 16) {
                    ProgressView("Loading desktops…")
                    Button("Cancel") { store.cancel() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.rows.isEmpty && store.errorMessage != nil {
                ContentUnavailableView {
                    Label("Desktop Access Unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Open the portal to sign in or review your access, then refresh your desktops.")
                } actions: { Button("Open Portal", action: openPortal) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.rows.isEmpty {
                ContentUnavailableView {
                    Label(store.hasLoaded ? "No Desktops Available" : "Desktop Catalog", systemImage: "desktopcomputer")
                } description: {
                    Text(store.hasLoaded ? "Ravada has not listed any desktops for this account." : "Sign in through the portal, then refresh your desktops.")
                } actions: { Button("Open Portal", action: openPortal) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.visibleRows.isEmpty {
                ContentUnavailableView.search(text: store.query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.visibleRows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).font(.headline)
                            if let parent = row.parentName { Text(parent).font(.caption).foregroundStyle(.secondary) }
                            Text(row.stateLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.toggleFavorite(row.id)
                        } label: {
                            Image(systemName: store.favoriteIDs.contains(row.id) ? "star.fill" : "star")
                        }
                        .accessibilityLabel(store.favoriteIDs.contains(row.id) ? "Unfavorite \(row.name)" : "Favorite \(row.name)")
                        .accessibilityIdentifier("ravadaDesktopFavorite-\(row.id)")
                        if row.portalOnly {
                            Button("Open in Portal", action: openPortal)
                        } else {
                            Button("Connect") { store.connect(row) }
                                .disabled(store.isBusy)
                                .accessibilityIdentifier("connectRavadaDesktop-\(row.id)")
                            Menu("Actions", systemImage: "ellipsis.circle") {
                                Button("Shut Down…", role: .destructive) { store.prepareShutdown(row) }
                                    .disabled(row.machine.isActive != true)
                                    .accessibilityIdentifier("shutdownRavadaDesktop-\(row.id)")
                                Button("Open in Portal", action: openPortal)
                            }
                            .disabled(store.isBusy)
                            .accessibilityLabel("Actions for \(row.name)")
                        }
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("ravadaDesktopList")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Shut Down Desktop?", isPresented: Binding(
            get: { store.shutdownConfirmation != nil },
            set: { if !$0 { store.cancelShutdownConfirmation() } }),
            presenting: store.shutdownConfirmation) { confirmation in
                Button("Shut Down", role: .destructive) { store.confirmShutdown(confirmation.id) }
                Button("Cancel", role: .cancel) { store.cancelShutdownConfirmation() }
            } message: { confirmation in
                Text("Shut down “\(confirmation.name)” (machine \(confirmation.machineID)) in \(store.profileName)? Save your work first. Connected viewers will disconnect. Ravada may force power off after its configured timeout. Cancelling monitoring after submission does not cancel the server request.")
            }
    }
}
