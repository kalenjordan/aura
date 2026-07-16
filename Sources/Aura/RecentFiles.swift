import AppKit
import SwiftUI

@MainActor
final class RecentFiles: ObservableObject {
    static let storageKey = "recentMarkdownFiles"
    static let maximumCount = 20

    @Published private(set) var urls: [URL] = []
    @Published var isPalettePresented = false
    @Published private(set) var selectedIndex = 0
    var activeURL: URL?
    var openAction: ((URL) -> Void)?

    private var localMonitor: Any?
    private var globalMonitor: Any?

    init() {
        reload()
        installEventMonitors()
    }

    func record(_ url: URL?) {
        guard let url, url.isFileURL else { return }
        let canonical = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == canonical }
        urls.insert(canonical, at: 0)
        urls = Array(urls.prefix(Self.maximumCount))
        save()
    }

    func reload() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        urls = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        save()
    }

    func activateSwitcher() {
        reload()
        guard !urls.isEmpty else { return }

        if isPalettePresented {
            selectedIndex = (selectedIndex + 1) % urls.count
        } else {
            let currentIndex = activeURL.flatMap { active in
                urls.firstIndex { $0.standardizedFileURL == active.standardizedFileURL }
            }
            selectedIndex = currentIndex.map { ($0 + 1) % urls.count } ?? 0
            isPalettePresented = true
        }
    }

    func select(_ index: Int) {
        guard urls.indices.contains(index) else { return }
        selectedIndex = index
    }

    func commitSelection() {
        guard isPalettePresented, urls.indices.contains(selectedIndex) else { return }
        let url = urls[selectedIndex]
        isPalettePresented = false
        openAction?(url)
    }

    func cancelSwitcher() {
        isPalettePresented = false
    }

    private func installEventMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged]
        ) { [weak self] event in
            guard let self, self.isPalettePresented else { return event }
            if !event.modifierFlags.contains(.command) {
                self.commitSelection()
            }
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.cancelSwitcher() }
        }
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.storageKey)
    }
}

struct RecentFileCommands: Commands {
    @ObservedObject var recentFiles: RecentFiles

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Open…") {
                recentFiles.activateSwitcher()
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}
