import SwiftUI
import UniformTypeIdentifiers

@main
struct AuraApp: App {
    @StateObject private var document = MarkdownDocument()
    @StateObject private var recentFiles = RecentFiles()

    var body: some Scene {
        Window("Aura", id: "editor") {
            EditorView(document: document, recentFiles: recentFiles)
                .onOpenURL { open($0) }
                .onAppear {
                    guard document.fileURL == nil, let latest = recentFiles.urls.first else { return }
                    open(latest)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { document.newFile() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { document.chooseAndOpen() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { document.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { document.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            TextEditingCommands()
            TextFormattingCommands()
            RecentFileCommands(recentFiles: recentFiles)
        }

        Settings {
            SettingsView()
        }
    }

    private func open(_ url: URL) {
        document.open(url)
        recentFiles.record(url)
    }
}

extension UTType {
    static var markdownDocument: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
}
