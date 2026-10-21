import AppKit
import SpiceKit
import SwiftUI

/// "Virtual Machines" window: VMs of every configured Proxmox server, with power actions
/// and one-click connect (no .vv download needed).
struct VMListView: View {
    @Bindable var store: ProxmoxStore
    @State private var vms: [UUID: [ProxmoxVM]] = [:]
    @State private var errors: [UUID: String] = [:]
    /// Errors from Connect/power actions; kept until the next action (reloads don't clear them).
    @State private var actionError: String?
    /// A refresh was requested while one was running: run once more afterwards.
    @State private var reloadAgain = false
    /// Servers whose list has been fetched at least once.
    @State private var loaded: Set<UUID> = []
    @State private var busy: Set<String> = []
    @State private var loading = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Proxmox Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a Proxmox server with an API token to start, stop and connect to virtual machines from here.")
                } actions: {
                    Button("Open Settings…") { openSettings() }
                }
            } else {
                List {
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                    }
                    ForEach(store.servers) { server in
                        Section(server.name) {
                            if let error = errors[server.id] {
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                            } else if !loaded.contains(server.id) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(.secondary)
                                }
                            } else if vms[server.id]?.isEmpty ?? true {
                                Label("No virtual machines are visible to this API token. Give the token (not only its user) VM.Audit, VM.PowerMgmt and VM.Console, e.g. the PVEVMUser role on /vms, or turn off its privilege separation.",
                                      systemImage: "eye.slash")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(vms[server.id] ?? []) { vm in
                                row(vm, server: server)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .toolbar {
            Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(loading)
                .keyboardShortcut("r")
        }
        .task { await reload() }
        .task {
            // Keep states fresh while the window is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await reload()
            }
        }
    }

    private func row(_ vm: ProxmoxVM, server: ProxmoxServer) -> some View {
        HStack {
            Circle()
                .fill(vm.isRunning ? Color.green : vm.isPaused ? .orange : .secondary)
                .frame(width: 8, height: 8)
                .accessibilityLabel(vm.status)
            VStack(alignment: .leading) {
                Text(vm.name)
                Text("\(vm.vmid) · \(vm.node) · \(vm.status)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if busy.contains(vm.id) {
                ProgressView().controlSize(.small).accessibilityLabel("Working")
            }
            Button(vm.isRunning ? "Connect" : vm.isPaused ? "Resume & Connect" : "Start & Connect") { connect(vm, server) }
                .disabled(busy.contains(vm.id))
                .accessibilityHint(Text("Opens \(vm.name) in a new window"))
            Menu {
                powerItems(vm, server: server)
            } label: {
                Image(systemName: "power")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy.contains(vm.id))
            .help("Power")
            .accessibilityLabel(Text("Power options for \(vm.name)"))
        }
        .contextMenu { powerItems(vm, server: server) }
    }

    @ViewBuilder
    private func powerItems(_ vm: ProxmoxVM, server: ProxmoxServer) -> some View {
        let actions: [ProxmoxPowerAction] = vm.isRunning
            ? [.shutdown, .reboot, .suspend, .reset, .stop]
            : vm.isPaused ? [.resume, .stop] : [.start]
        ForEach(actions, id: \.self) { action in
            Button { run(action, vm, server) } label: { Label(action.title, systemImage: action.symbol) }
        }
    }

    /// One refresh at a time (a request during a refresh runs once more afterwards). The
    /// list is shown as soon as it arrives; paused states are filled in afterwards.
    private func reload() async {
        guard !loading else {
            reloadAgain = true
            return
        }
        loading = true
        defer { loading = false }
        repeat {
            reloadAgain = false
            for server in store.servers {
                do {
                    let client = try store.client(for: server)
                    let list = try await client.virtualMachines()
                    vms[server.id] = list
                    errors[server.id] = nil
                    loaded.insert(server.id)
                    vms[server.id] = await client.withDetailedStates(list)
                } catch {
                    errors[server.id] = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
                    loaded.insert(server.id)
                }
            }
        } while reloadAgain
    }

    private func connect(_ vm: ProxmoxVM, _ server: ProxmoxServer) {
        busy.insert(vm.id)
        actionError = nil
        Task {
            defer { busy.remove(vm.id) }
            do {
                try await store.connect(to: vm, on: server)
            } catch {
                actionError = "\(vm.name): " + ((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            await reload()
        }
    }

    private func run(_ action: ProxmoxPowerAction, _ vm: ProxmoxVM, _ server: ProxmoxServer) {
        guard ProxmoxStore.confirm(action, vmName: vm.name) else { return }
        busy.insert(vm.id)
        actionError = nil
        Task {
            defer { busy.remove(vm.id) }
            do {
                try await store.client(for: server).perform(action, node: vm.node, vmid: vm.vmid)
                try? await Task.sleep(for: .seconds(2))
            } catch {
                actionError = "\(vm.name): " + ((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            await reload()
        }
    }
}

/// AppKit-managed window for `VMListView`.
@MainActor
final class VMListWindow {
    static let shared = VMListWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: VMListView(store: .shared))
            hosting.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = String(localized: "Virtual Machines")
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 480))
            window.center()
            self.window = window
            // Drop the window (and its view's polling tasks) when it closes.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.window = nil
                    if let observer = self?.closeObserver { NotificationCenter.default.removeObserver(observer) }
                    self?.closeObserver = nil
                }
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private var closeObserver: (any NSObjectProtocol)?
}
