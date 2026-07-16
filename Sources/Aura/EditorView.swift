import SwiftUI

struct EditorView: View {
    @ObservedObject var document: MarkdownDocument
    @ObservedObject var recentFiles: RecentFiles
    @AppStorage("editorFontSize") private var fontSize = 16.0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    HStack {
                        Spacer()
                        Text(wordCountLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text(displayPath)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 520)
                        .help(document.fileURL?.path ?? "Unsaved file")
                }
                .padding(.horizontal, 18)
                .frame(height: 38)

                Divider()

                RichMarkdownEditor(text: $document.text, fontSize: fontSize)
                    .background(Color(nsColor: .textBackgroundColor))
            }

            if recentFiles.isPalettePresented {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { recentFiles.cancelSwitcher() }

                RecentFilesPalette(recentFiles: recentFiles)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.separator.opacity(0.5), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
            }
        }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 640, minHeight: 520)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                recentFiles.activeURL = document.fileURL
                recentFiles.openAction = { url in
                    document.open(url)
                    recentFiles.record(url)
                }
            }
            .onChange(of: document.fileURL) { _, newURL in
                recentFiles.activeURL = newURL
                recentFiles.record(newURL)
            }
    }

    private var wordCountLabel: String {
        let count = document.text.split { $0.isWhitespace || $0.isNewline }.count
        return "\(count) \(count == 1 ? "word" : "words")"
    }

    private var displayPath: String {
        guard let path = document.fileURL?.path else { return "Untitled.md" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let repos = home + "/repos/"
        if path.hasPrefix(repos) {
            return String(path.dropFirst(repos.count))
        }
        return path == home ? "~" : path.replacingOccurrences(of: home + "/", with: "~/")
    }
}
