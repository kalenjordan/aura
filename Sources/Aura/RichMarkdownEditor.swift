import AppKit
import SwiftUI

struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = CenteredTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 52, height: 38)
        textView.string = text
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.insertionPointColor = .controlAccentColor

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        context.coordinator.applyStyles(fontSize: fontSize)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
        }
        context.coordinator.applyStyles(fontSize: fontSize)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        private var isStyling = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isStyling, let textView else { return }
            text = textView.string
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func applyStyles(fontSize: Double) {
            guard let textView, let storage = textView.textStorage, !isStyling else { return }
            isStyling = true
            defer { isStyling = false }

            let fullRange = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            paragraph.paragraphSpacing = 6
            let bodyFont = NSFont.systemFont(ofSize: fontSize)

            storage.beginEditing()
            storage.setAttributes([
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ], range: fullRange)

            styleHeadings(in: storage, fontSize: fontSize)
            stylePattern(#"(?m)^\s*(>)[ \t]+.*$"#, in: storage) { match in
                [.foregroundColor: NSColor.secondaryLabelColor,
                 .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
            }
            stylePattern(#"(?m)^\s*([-*+] |\d+\. )"#, in: storage) { _ in
                [.foregroundColor: NSColor.controlAccentColor,
                 .font: NSFont.boldSystemFont(ofSize: fontSize)]
            }
            stylePattern(#"(\*\*|__)(.+?)\1"#, in: storage) { _ in
                [.font: NSFont.boldSystemFont(ofSize: fontSize)]
            }
            stylePattern(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, in: storage) { _ in
                [.font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
            }
            stylePattern(#"`([^`\n]+)`"#, in: storage) { _ in
                [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                 .foregroundColor: NSColor.systemPink]
            }
            stylePattern(#"\[([^\]]+)\]\(([^)]+)\)"#, in: storage) { _ in
                [.foregroundColor: NSColor.linkColor,
                 .underlineStyle: NSUnderlineStyle.single.rawValue]
            }
            stylePattern(#"(?s)```.*?```"#, in: storage) { _ in
                [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                 .foregroundColor: NSColor.secondaryLabelColor,
                 .backgroundColor: NSColor.quaternaryLabelColor]
            }
            storage.endEditing()
        }

        private func styleHeadings(in storage: NSTextStorage, fontSize: Double) {
            stylePattern(#"(?m)^(#{1,6})[ \t]+.*$"#, in: storage) { match in
                let source = storage.string as NSString
                let level = source.substring(with: match.range(at: 1)).count
                let sizes: [Double] = [32, 27, 23, 20, 18, 17]
                let size = max(fontSize, sizes[level - 1])
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? 18 : 12
                style.paragraphSpacing = 8
                return [.font: NSFont.systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold),
                        .paragraphStyle: style]
            }

            guard let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,6})[ \t]+"#) else { return }
            let range = NSRange(location: 0, length: storage.length)
            for match in regex.matches(in: storage.string, range: range) {
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ], range: match.range)
            }
        }

        private func stylePattern(
            _ pattern: String,
            in storage: NSTextStorage,
            attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
        ) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: storage.length)
            for match in regex.matches(in: storage.string, range: range) {
                storage.addAttributes(attributes(match), range: match.range)
            }
        }
    }
}

private final class CenteredTextView: NSTextView {
    private let baseInset: CGFloat = 52
    private let maximumCanvasWidth: CGFloat = 800

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let extraSpace = max(0, newSize.width - maximumCanvasWidth)
        textContainerInset = NSSize(width: baseInset + extraSpace / 2, height: 38)
    }
}

private extension Double {
    func nonzero(or fallback: Double) -> Double { self == 0 ? fallback : self }
}
