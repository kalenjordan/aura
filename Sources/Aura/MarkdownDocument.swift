import AppKit
import Darwin
import SwiftUI

@MainActor
final class MarkdownDocument: ObservableObject {
    @Published var text: String {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var fileURL: URL?

    private var autosaveTask: Task<Void, Never>?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var isApplyingDiskChange = false

    init(text: String = "# Untitled\n\nStart writing…\n") {
        self.text = text
    }

    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            autosaveTask?.cancel()
            isApplyingDiskChange = true
            fileURL = url.standardizedFileURL
            text = decoded
            isApplyingDiskChange = false
            startMonitoring(url)
        } catch {
            isApplyingDiskChange = false
            present(error)
        }
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownDocument, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func newFile() {
        autosaveTask?.cancel()
        stopMonitoring()
        fileURL = nil
        text = "# Untitled\n\nStart writing…\n"
    }

    func save() {
        guard let fileURL else {
            saveAs()
            return
        }
        write(to: fileURL)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownDocument]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        write(to: url)
        startMonitoring(url)
    }

    private func scheduleAutosave() {
        guard fileURL != nil, !isApplyingDiskChange else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func write(to url: URL) {
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            present(error)
        }
    }

    private func startMonitoring(_ url: URL) {
        stopMonitoring()
        let directory = url.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reloadIfChangedOnDisk()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        fileMonitor = source
        source.resume()
    }

    private func stopMonitoring() {
        fileMonitor?.cancel()
        fileMonitor = nil
    }

    private func reloadIfChangedOnDisk() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let diskText = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16),
              diskText != text else { return }

        autosaveTask?.cancel()
        isApplyingDiskChange = true
        text = diskText
        isApplyingDiskChange = false
    }

    private func present(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
