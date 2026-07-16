import SwiftUI

struct RecentFilesPalette: View {
    @ObservedObject var recentFiles: RecentFiles

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent files")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(recentFiles.urls.enumerated()), id: \.element) { index, url in
                            Button {
                                recentFiles.select(index)
                                recentFiles.commitSelection()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(index == recentFiles.selectedIndex ? .white : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                            .fontWeight(.medium)
                                        Text(url.deletingLastPathComponent().path)
                                            .font(.caption)
                                            .opacity(0.72)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .foregroundStyle(index == recentFiles.selectedIndex ? .white : .primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    index == recentFiles.selectedIndex
                                        ? Color.accentColor
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: recentFiles.selectedIndex) { _, index in
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(width: 520, height: min(360, CGFloat(58 + recentFiles.urls.count * 58)))
        .onExitCommand {
            recentFiles.cancelSwitcher()
        }
    }
}
