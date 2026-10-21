import AppKit
import SpiceKit
import SwiftUI

/// Window content for one session: the remote display plus connection state.
/// The display area stays free of overlays once connected.
struct SessionView: View {
    @Bindable var controller: SessionController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            Color.black
            if let view = controller.displayView {
                DisplayViewRepresentable(view: view)
            }
            switch controller.phase {
            case .connecting:
                if let reconnect = controller.reconnect {
                    reconnectingOverlay(SessionController.ReconnectProgress(
                        attempt: reconnect.attempt, maxAttempts: controller.maxReconnectAttempts), connecting: true)
                } else {
                    ProgressView("Connecting…")
                        .controlSize(.large)
                        .padding(24)
                        .glassEffect(in: .rect(cornerRadius: 16))
                }
            case .connected:
                EmptyView()
            case .reconnecting(let progress):
                reconnectingOverlay(progress, connecting: progress.retryAt == nil && !progress.waitingForNetwork)
            case .ended(let message):
                endedOverlay(message)
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .alert("USB", isPresented: Binding(
            get: { controller.usb.errorMessage != nil },
            set: { if !$0 { controller.usb.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.usb.errorMessage ?? "")
        }
        .alert("Smartcard", isPresented: Binding(
            get: { controller.smartcard.errorMessage != nil },
            set: { if !$0 { controller.smartcard.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.smartcard.errorMessage ?? "")
        }
        .alert("File Transfer", isPresented: Binding(
            get: { controller.files.errorMessage != nil },
            set: { if !$0 { controller.files.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.files.errorMessage ?? "")
        }
        .alert("Microphone", isPresented: Binding(
            get: { controller.audio.errorMessage != nil },
            set: { if !$0 { controller.audio.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.audio.errorMessage ?? "")
        }
        .alert("Power", isPresented: Binding(
            get: { controller.powerError != nil },
            set: { if !$0 { controller.powerError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.powerError ?? "")
        }
        .navigationTitle(controller.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if controller.usb.isAllowed {
                    USBToolbarItems(usb: controller.usb, connected: controller.phase == .connected)
                }
                FileTransferToolbarItem(files: controller.files, connected: controller.phase == .connected)
                MicrophoneToolbarItem(audio: controller.audio, connected: controller.phase == .connected)
                if controller.vmRef != nil {
                    PowerToolbarItem(controller: controller)
                }
                if controller.smartcard.isAvailable {
                    SmartcardToolbarItem(smartcard: controller.smartcard, connected: controller.phase == .connected)
                }

                Button {
                    controller.sendCtrlAltDelete()
                } label: {
                    Label("Send Ctrl+Alt+Del", systemImage: "command.square")
                }
                .help("Send Ctrl+Alt+Del to the guest")
                .disabled(controller.phase != .connected)

                Button {
                    controller.releaseCursor()
                } label: {
                    Label("Release Cursor", systemImage: "cursorarrow.motionlines")
                }
                .help("Release the captured pointer and keys")
                .disabled(controller.phase != .connected || controller.clientMouseMode)

                Button {
                    controller.toggleFullscreen()
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Toggle full screen")
            }
        }
    }

    // MARK: Reconnecting / ended (M8)

    @ViewBuilder
    private func reconnectingOverlay(_ progress: SessionController.ReconnectProgress, connecting: Bool) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
            Text("Reconnecting…")
                .font(.title3.weight(.semibold))
            Group {
                if progress.waitingForNetwork {
                    Text("Waiting for a network connection.")
                } else if let retryAt = progress.retryAt, retryAt > .now {
                    Text("Attempt \(progress.attempt) of \(progress.maxAttempts) in \(Text(timerInterval: Date.now...retryAt, countsDown: true))")
                } else {
                    Text("Attempt \(progress.attempt) of \(progress.maxAttempts)")
                }
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
            HStack {
                Button("Cancel") { controller.cancelReconnect() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Now") { controller.reconnectNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting)
            }
        }
        .padding(28)
        .glassEffect(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reconnecting to \(controller.title)")
    }

    @ViewBuilder
    private func endedOverlay(_ message: String?) -> some View {
        let ended = EndedDescription(controller: controller, message: message)
        VStack(spacing: 12) {
            Image(systemName: ended.symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(ended.title)
                .font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }
            if let hint = ended.hint {
                Text(hint)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }
            HStack {
                Button("Close Window") { controller.window?.performClose(nil) }
                    .keyboardShortcut(ended.primary == nil ? .defaultAction : .cancelAction)
                switch ended.primary {
                case .startAndReconnect:
                    Button("Start & Reconnect") { controller.startAndReconnect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.powerBusy)
                case .reconnect:
                    Button("Reconnect") { controller.reconnectNow() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.powerBusy)
                case .setUpProxmox:
                    Button("Set Up Proxmox Access…") {
                        ProxmoxStore.shared.pendingHost = controller.vmRef?.apiHost
                        openSettings()
                    }
                case .openFile:
                    Button("Open Connection File…") { SessionWindowManager.shared.presentOpenPanel() }
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(28)
        .glassEffect(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

/// Wording and the main action for a session that ended.
@MainActor
private struct EndedDescription {
    enum Action { case startAndReconnect, reconnect, setUpProxmox, openFile }

    let symbol: String
    let title: LocalizedStringKey
    let hint: LocalizedStringKey?
    let primary: Action?

    init(controller: SessionController, message: String?) {
        switch controller.endKind {
        case _ where message == nil:
            (symbol, title) = ("bolt.horizontal.circle", "Disconnected")
        case .networkLost:
            (symbol, title) = ("wifi.exclamationmark", "Connection lost")
        case .serverEnded:
            (symbol, title) = ("bolt.horizontal.circle", "Session ended")
        case .authentication:
            (symbol, title) = ("key.slash", "Access denied")
        case .vmNotRunning:
            (symbol, title) = ("power", "The virtual machine is off")
        case .failed:
            (symbol, title) = ("exclamationmark.triangle", "Can’t connect")
        }
        if controller.endKind == .vmNotRunning, controller.canControlPower {
            primary = .startAndReconnect
            hint = nil
        } else if controller.canReconnect {
            primary = .reconnect
            hint = nil
        } else if controller.vmRef != nil {
            primary = .setUpProxmox
            hint = "Reconnecting needs a new ticket. Click SPICE in Proxmox again, or add this server under Settings › Proxmox so the app can reconnect by itself."
        } else {
            primary = .openFile
            hint = "The ticket in the connection file can only be used once. Open a new connection file to reconnect."
        }
    }
}

/// Hosts the AppKit display view inside SwiftUI.
struct DisplayViewRepresentable: NSViewRepresentable {
    let view: RemoteDisplayView

    func makeNSView(context: Context) -> RemoteDisplayView { view }
    func updateNSView(_ nsView: RemoteDisplayView, context: Context) {}
}

/// Toolbar menus for USB redirection and ISO mounting (AGENTS.md §7a/§7b).
struct USBToolbarItems: View {
    @Bindable var usb: USBController
    let connected: Bool

    var body: some View {
        Menu {
            if usb.slotCount == 0 {
                Text("This virtual machine has no USB redirection slots.")
                Text("In Proxmox: VM › Hardware › Add › USB Device › Spice Port (one per device).")
            } else {
                Section("Devices on this Mac") {
                    if usb.inventory.devices.isEmpty {
                        Text("No USB devices found")
                    }
                    ForEach(usb.inventory.devices) { device in
                        let reason = usb.unavailableReason(device)
                        Toggle(isOn: Binding(get: { usb.isRedirected(device) }, set: { _ in usb.toggle(device) })) {
                            if let reason {
                                Text("\(device.name) — \(reason)")
                            } else if device.isKeyboardOrMouse && !usb.isRedirected(device) {
                                Text("\(device.name) (acts as a keyboard)")
                            } else if device.claimedByMacOS && !usb.isRedirected(device) {
                                Text("\(device.name) (in use by macOS)")
                            } else {
                                Text(device.name)
                            }
                        }
                        .disabled(reason != nil || (!usb.isRedirected(device) && usb.freeSlots == 0))
                    }
                }
                Section {
                    Text("\(usb.freeSlots) of \(usb.slotCount) USB slots free")
                }
            }
        } label: {
            Label("USB Devices", systemImage: "cable.connector.horizontal")
        }
        .help("Redirect USB devices from this Mac to the virtual machine")
        .disabled(!connected)

        if let iso = usb.mountedISO {
            Menu {
                Button("Eject “\(iso.name)”") { usb.detach(slot: iso.slot) }
            } label: {
                Label("Disc Image", systemImage: "opticaldisc.fill")
            }
            .help("“\(iso.name)” is inserted in the virtual CD-ROM drive")
        } else {
            Button {
                usb.chooseAndMountISO()
            } label: {
                Label("Mount ISO…", systemImage: "opticaldisc")
            }
            .help("Insert a disc image (.iso) into the virtual machine as a CD/DVD drive")
            .disabled(!connected || usb.freeSlots == 0)
        }
    }
}

/// Toolbar menu for sharing a smartcard (e.g. a YubiKey's PIV applet) with the guest.
struct SmartcardToolbarItem: View {
    @Bindable var smartcard: SmartcardController
    let connected: Bool

    var body: some View {
        Menu {
            if smartcard.readers.isEmpty {
                Text("No smartcard readers on this Mac")
            }
            ForEach(smartcard.readers) { reader in
                Toggle(isOn: Binding(get: { smartcard.sharedReader == reader.name },
                                     set: { _ in smartcard.toggle(reader) })) {
                    Text(reader.hasCard ? reader.name : "\(reader.name) (no card)")
                }
                .disabled(!reader.hasCard || smartcard.isBusy
                          || (smartcard.sharedReader != nil && smartcard.sharedReader != reader.name)
                          || (smartcard.sharedReader == nil && !smartcard.canShare))
            }
            Section {
                Text(smartcard.transportNote)
                Text("While shared, macOS can't use the card. Security keys share only their smartcard (PIV) function.")
            }
        } label: {
            Label("Smartcard", systemImage: smartcard.sharedReader == nil ? "creditcard" : "creditcard.fill")
        }
        .help("Share a smartcard or security key (smartcard function) with the virtual machine")
        .disabled(!connected)
    }
}

/// Toolbar Power menu (Proxmox API): shut down, reboot, reset, stop the session's VM.
struct PowerToolbarItem: View {
    @Bindable var controller: SessionController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            if controller.canControlPower {
                ForEach([ProxmoxPowerAction.shutdown, .reboot, .suspend, .resume], id: \.self) { action in
                    Button { controller.power(action) } label: { Label(action.title, systemImage: action.symbol) }
                }
                Divider()
                ForEach([ProxmoxPowerAction.reset, .stop], id: \.self) { action in
                    Button { controller.power(action) } label: { Label(action.title, systemImage: action.symbol) }
                }
                Divider()
                Button("Virtual Machines…") { VMListWindow.shared.show() }
            } else {
                Text("Power control needs a Proxmox API token for this server.")
                Button("Set Up Proxmox Access…") {
                    ProxmoxStore.shared.pendingHost = controller.vmRef?.apiHost
                    openSettings()
                }
            }
        } label: {
            Label("Power", systemImage: "power")
        }
        .help("Start, shut down or reboot the virtual machine (Proxmox)")
        .disabled(controller.powerBusy)
    }
}

/// Microphone on/off for this session (off by default). Shows when the guest is listening.
struct MicrophoneToolbarItem: View {
    @Bindable var audio: AudioController
    let connected: Bool

    var body: some View {
        Button {
            audio.toggleMicrophone()
        } label: {
            Label(audio.microphoneEnabled ? "Microphone On" : "Microphone Off",
                  systemImage: audio.microphoneEnabled ? (audio.guestWantsMicrophone ? "mic.fill" : "mic") : "mic.slash")
        }
        .help(audio.microphoneEnabled
              ? (audio.guestWantsMicrophone ? "The virtual machine is hearing your microphone. Click to turn it off."
                                            : "Microphone allowed; sent only while the virtual machine records.")
              : "Allow the virtual machine to use your microphone")
        .disabled(!connected)
    }
}

/// "Send Files…" button; shows progress while files are copied into the guest.
struct FileTransferToolbarItem: View {
    @Bindable var files: FileTransferController
    let connected: Bool

    var body: some View {
        if let name = files.currentName {
            Menu {
                Text("Copying “\(name)” (\(Int(files.fraction * 100)) %)")
                if files.queued > 0 { Text("\(files.queued) more waiting") }
                Button("Cancel") { files.cancel() }
            } label: {
                Label {
                    Text("Copying…")
                } icon: {
                    ProgressView(value: files.fraction).progressViewStyle(.circular).controlSize(.small)
                }
            }
            .help("Copying files into the virtual machine")
        } else {
            Button {
                files.chooseAndSend()
            } label: {
                Label("Send Files…", systemImage: "doc.badge.arrow.up")
            }
            .help("Copy files into the virtual machine (or drag them onto its screen). Needs spice-vdagent.")
            .disabled(!connected)
        }
    }
}
