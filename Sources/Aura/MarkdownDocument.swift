import AppKit
import Darwin
import SwiftUI

@MainActor
final class MarkdownDocument: ObservableObject {
    static let defaultText = "# Untitled\n\nStart writing…\n"
    private static let restoredFileKey = "activeMarkdownFile"
    private static let restoreUntitledKey = "activeDocumentWasUntitled"

    @Published var text: String {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var fileURL: URL?

    var hasSavedUntitledDraft: Bool {
        FileManager.default.fileExists(atPath: untitledDraftURL.path)
    }

    var restoredFileURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.restoredFileKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var shouldRestoreUntitledDraft: Bool {
        UserDefaults.standard.bool(forKey: Self.restoreUntitledKey)
    }

    private var autosaveTask: Task<Void, Never>?
    private var fileMonitor: DispatchSourceFileSystemObject?
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var isApplyingDiskChange = false

    init(text: String? = nil) {
        self.text = text ?? Self.loadUntitledDraft() ?? Self.defaultText
    }

    func open(_ url: URL) {
        do {
            if fileURL == nil {
                saveUntitledDraft()
            }
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
            rememberActiveFile(fileURL)
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
        guard fileURL != nil else { return }
        autosaveTask?.cancel()
        stopMonitoring()
        fileURL = nil
        rememberActiveFile(nil)
        text = Self.loadUntitledDraft() ?? Self.defaultText
    }

    func closeFile() {
        guard fileURL != nil else { return }
        flushAutosave()
        newFile()
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
        let wasUntitled = fileURL == nil
        fileURL = url
        if write(to: url) {
            rememberActiveFile(url)
            if wasUntitled {
                try? FileManager.default.removeItem(at: untitledDraftURL)
            }
            startMonitoring(url)
        }
    }

    func flushAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
        if let fileURL {
            _ = write(to: fileURL)
        } else {
            saveUntitledDraft()
        }
    }

    private func scheduleAutosave() {
        guard !isApplyingDiskChange else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushAutosave()
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            present(error)
            return false
        }
    }

    private var untitledDraftURL: URL {
        Self.untitledDraftURL
    }

    private static var untitledDraftURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aura", isDirectory: true)
            .appendingPathComponent("Untitled.md")
    }

    private static func loadUntitledDraft() -> String? {
        try? String(contentsOf: untitledDraftURL, encoding: .utf8)
    }

    private func saveUntitledDraft() {
        guard text != Self.defaultText || hasSavedUntitledDraft else { return }
        do {
            let directory = untitledDraftURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: untitledDraftURL, options: .atomic)
        } catch {
            present(error)
        }
    }

    private func rememberActiveFile(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: Self.restoredFileKey)
            UserDefaults.standard.set(false, forKey: Self.restoreUntitledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.restoredFileKey)
            UserDefaults.standard.set(true, forKey: Self.restoreUntitledKey)
        }
    }

    private func startMonitoring(_ url: URL) {
        stopMonitoring()
        startFileMonitoring(url)

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
            self?.startFileMonitoring(url)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        directoryMonitor = source
        source.resume()
    }

    private func startFileMonitoring(_ url: URL) {
        fileMonitor?.cancel()
        fileMonitor = nil

        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            self?.reloadIfChangedOnDisk()

            let replacementEvents: DispatchSource.FileSystemEvent = [.rename, .delete, .revoke]
            if let events = source?.data, !events.intersection(replacementEvents).isEmpty {
                self?.startFileMonitoring(url)
            }
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
        directoryMonitor?.cancel()
        directoryMonitor = nil
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
