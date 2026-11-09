import SwiftUI

struct DownloadSettingsView: View {
    @Bindable private var watcher = DownloadWatcher.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open new .vv downloads automatically", isOn: Binding(
                    get: { watcher.isWatching },
                    set: { enabled in
                        if enabled { watcher.chooseFolder() } else { watcher.stop() }
                    }
                ))
                if let folder = watcher.folder {
                    LabeledContent("Watched folder", value: folder.lastPathComponent)
                    Button("Choose Another Folder…") { watcher.chooseFolder() }
                }
                if let message = watcher.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if watcher.skippedFiles > 0 {
                    Text("Some files were skipped because they were empty, too large, or not valid SPICE connection files. You can open them manually to see the error.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection Downloads")
            } footer: {
                Text("Choose the folder your browser downloads to. Only new .vv files are opened; files already in the folder are ignored. The app keeps watching when its windows are closed, until you quit or turn this off. Choose the folder again after restarting the app.")
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
