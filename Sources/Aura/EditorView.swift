import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var document: MarkdownDocument
    @ObservedObject var recentFiles: RecentFiles
    @AppStorage("editorFontSize") private var fontSize = 16.0
    @State private var didCopyMarkdown = false
    @State private var isToolbarHovered = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    HStack {
                        Spacer()

                        Button {
                            copyMarkdown()
                        } label: {
                            Label(
                                didCopyMarkdown ? "Copied" : "Copy Markdown",
                                systemImage: didCopyMarkdown ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(didCopyMarkdown ? .secondary : .primary)
                        .opacity(isToolbarHovered || didCopyMarkdown ? 1 : 0)
                        .allowsHitTesting(isToolbarHovered || didCopyMarkdown)
                        .help("Copy all Markdown")

                        Text(wordCountLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 14)
                    }

                    HStack(spacing: 8) {
                        RepositoryFaviconView(fileURL: document.fileURL, size: 18)
                        Text(displayName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 520)
                    .help(document.fileURL?.path ?? "Unsaved file")
                }
                .padding(.horizontal, 18)
                .frame(height: 38)
                .onHover { isToolbarHovered = $0 }

                Divider()

                RichMarkdownEditor(
                    text: $document.text,
                    fontSize: fontSize,
                    onCopyAll: copyMarkdown
                )
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

    private var displayName: String {
        document.fileURL?.lastPathComponent ?? "Untitled.md"
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(document.text, forType: .string)
        didCopyMarkdown = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyMarkdown = false
        }
    }
}
