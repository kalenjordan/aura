import AppKit
import SwiftUI

struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: Double
    let onCopyAll: () -> Void

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
        textView.textContainerInset = NSSize(width: 52, height: 76)
        textView.string = text
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = .controlAccentColor

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .auraPageShellColor
        scrollView.drawsBackground = true

        context.coordinator.textView = textView
        textView.onCanvasClick = { [weak coordinator = context.coordinator] in
            coordinator?.leaveMarkdownEditMode()
        }
        textView.onBulletDoubleClick = { [weak coordinator = context.coordinator] location in
            coordinator?.enterBulletEditMode(at: location)
        }
        textView.onHeadingDoubleClick = { [weak coordinator = context.coordinator] location in
            coordinator?.enterHeadingEditMode(at: location)
        }
        textView.onEditorClick = { [weak coordinator = context.coordinator] location in
            coordinator?.handleEditorClick(at: location)
        }
        textView.onExitEditMode = { [weak coordinator = context.coordinator] in
            coordinator?.leaveMarkdownEditMode()
        }
        textView.onCopyAll = onCopyAll
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
        private var pendingTablePreviews: [PendingTablePreview] = []
        private var pendingCodePreviews: [PendingCodePreview] = []
        private var pendingDecorations: [PendingDecoration] = []
        private var editingBulletLocation: Int?
        private var editingHeadingLocation: Int?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isStyling, let textView else { return }
            text = textView.string
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func enterBulletEditMode(at location: Int) {
            editingBulletLocation = location
            editingHeadingLocation = nil
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func enterHeadingEditMode(at location: Int) {
            editingBulletLocation = nil
            editingHeadingLocation = location
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func handleEditorClick(at location: Int?) {
            guard let textView = textView as? CenteredTextView else { return }
            var changed = false

            if editingBulletLocation != nil {
                let clickedBullet = location.map { character in
                    textView.activeBulletSourceRanges.contains { NSLocationInRange(character, $0) }
                } ?? false
                if !clickedBullet {
                    editingBulletLocation = nil
                    changed = true
                }
            }

            if let editingHeadingLocation {
                let activeRange = textView.headingSourceRanges.first {
                    NSLocationInRange(editingHeadingLocation, $0)
                }
                let clickedActiveHeading = location.map { character in
                    activeRange.map { NSLocationInRange(character, $0) } ?? false
                } ?? false
                if !clickedActiveHeading {
                    self.editingHeadingLocation = nil
                    changed = true
                }
            }

            if changed {
                applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
            }
        }

        func leaveMarkdownEditMode() {
            editingBulletLocation = nil
            editingHeadingLocation = nil
            if let textView {
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
            }
            applyStyles(fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16))
        }

        func applyStyles(fontSize: Double) {
            guard let textView, let storage = textView.textStorage, !isStyling else { return }
            isStyling = true
            defer { isStyling = false }

            textView.subviews
                .filter {
                    $0 is MarkdownTablePreview
                        || $0 is MarkdownCodePreview
                        || $0 is MarkdownDecorationView
                }
                .forEach { $0.removeFromSuperview() }
            pendingTablePreviews.removeAll()
            pendingCodePreviews.removeAll()
            pendingDecorations.removeAll()
            (textView as? CenteredTextView)?.bulletSourceRanges = []
            (textView as? CenteredTextView)?.activeBulletSourceRanges = []
            (textView as? CenteredTextView)?.headingSourceRanges = []

            let fullRange = NSRange(location: 0, length: storage.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            paragraph.paragraphSpacing = 8
            let bodyFont = NSFont.systemFont(ofSize: fontSize)

            storage.beginEditing()
            storage.setAttributes([
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ], range: fullRange)

            styleHeadings(in: storage, fontSize: fontSize)
            styleBlankSeparatorLines(in: storage)
            stylePattern(#"(?m)^\s*(>)[ \t]+.*$"#, in: storage) { match in
                [.foregroundColor: NSColor.secondaryLabelColor,
                 .font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
            }
            styleStrongEmphasis(in: storage, fontSize: fontSize)
            stylePattern(#"(?<!\*)\*([^*\n]+)\*(?!\*)|(?<!_)_([^_\n]+)_(?!_)"#, in: storage) { _ in
                [.font: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)]
            }
            stylePattern(#"`([^`\n]+)`"#, in: storage) { _ in
                [.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                 .foregroundColor: NSColor.labelColor]
            }
            stylePattern(#"\[([^\]]+)\]\(([^)]+)\)"#, in: storage) { _ in
                [.foregroundColor: NSColor.linkColor,
                 .underlineStyle: NSUnderlineStyle.single.rawValue]
            }
            styleBulletLists(in: storage, fontSize: fontSize)
            styleHorizontalRules(in: storage)
            styleCodeBlocks(in: storage, fontSize: fontSize)
            styleTables(in: storage, fontSize: fontSize)
            storage.endEditing()
            installTablePreviews(in: textView)
            installCodePreviews(in: textView)
            installDecorations(in: textView)
            textView.window?.invalidateCursorRects(for: textView)
        }

        private func styleBulletLists(in storage: NSTextStorage, fontSize: Double) {
            guard let textView = textView as? CenteredTextView,
                  let regex = try? NSRegularExpression(
                    pattern: #"(?m)^([ \t]*)([-+*]|\d+\.)([ \t]+)(?=\S)"#
                  ) else { return }

            let source = storage.string as NSString
            let fullRange = NSRange(location: 0, length: storage.length)
            let matches = regex.matches(in: storage.string, range: fullRange)
            let lineRanges = matches.map {
                source.lineRange(for: NSRange(location: $0.range.location, length: 0))
            }
            var activeSection: NSRange?
            if let editingBulletLocation,
               let activeIndex = lineRanges.firstIndex(where: {
                   NSLocationInRange(editingBulletLocation, $0)
               }) {
                var first = activeIndex
                var last = activeIndex
                while first > 0,
                      isWhitespaceOnly(
                        from: NSMaxRange(lineRanges[first - 1]),
                        to: lineRanges[first].location,
                        in: source
                      ) {
                    first -= 1
                }
                while last + 1 < lineRanges.count,
                      isWhitespaceOnly(
                        from: NSMaxRange(lineRanges[last]),
                        to: lineRanges[last + 1].location,
                        in: source
                      ) {
                    last += 1
                }
                activeSection = NSUnionRange(lineRanges[first], lineRanges[last])
            }

            for (index, match) in matches.enumerated() {
                let lineRange = source.lineRange(
                    for: NSRange(location: match.range.location, length: 0)
                )
                let content = contentRange(for: lineRange, in: source)
                let indent = source.substring(with: match.range(at: 1))
                let level = indent.reduce(0) { count, character in
                    count + (character == "\t" ? 1 : 0)
                } + indent.filter { $0 == " " }.count / 2
                let continuesPrevious = index > 0 && isWhitespaceOnly(
                    from: NSMaxRange(lineRanges[index - 1]),
                    to: lineRanges[index].location,
                    in: source
                )
                let continuesNext = index + 1 < lineRanges.count && isWhitespaceOnly(
                    from: NSMaxRange(lineRanges[index]),
                    to: lineRanges[index + 1].location,
                    in: source
                )
                let isEditing = activeSection.map {
                    NSLocationInRange(match.range.location, $0)
                } ?? false

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 6
                paragraph.paragraphSpacingBefore = continuesPrevious ? 0 : 12
                paragraph.paragraphSpacing = continuesNext ? 10 : 14
                paragraph.firstLineHeadIndent = isEditing ? 0 : CGFloat(level * 18 + 32)
                paragraph.headIndent = paragraph.firstLineHeadIndent
                storage.addAttribute(.paragraphStyle, value: paragraph, range: content)

                textView.bulletSourceRanges.append(content)
                if isEditing {
                    textView.activeBulletSourceRanges.append(content)
                    storage.addAttributes([
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: fontSize)
                    ], range: NSUnionRange(match.range(at: 2), match.range(at: 3)))
                    continue
                }

                let markerRange = NSRange(
                    location: match.range(at: 2).location,
                    length: NSMaxRange(match.range(at: 3)) - match.range(at: 2).location
                )
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ], range: markerRange)

                pendingDecorations.append(PendingDecoration(
                    characterLocation: NSMaxRange(match.range),
                    view: MarkdownDecorationView(
                        kind: source.substring(with: match.range(at: 2)).hasSuffix(".")
                            ? .number(
                                level: level,
                                label: source.substring(with: match.range(at: 2))
                            )
                            : .bullet(level: level)
                    )
                ))
            }

            for pair in zip(matches, matches.dropFirst()) {
                let previousLine = source.lineRange(
                    for: NSRange(location: pair.0.range.location, length: 0)
                )
                let nextLine = source.lineRange(
                    for: NSRange(location: pair.1.range.location, length: 0)
                )
                let separatorRange = NSRange(
                    location: NSMaxRange(previousLine),
                    length: max(0, nextLine.location - NSMaxRange(previousLine))
                )
                guard separatorRange.length > 0,
                      source.substring(with: separatorRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let compactSeparator = NSMutableParagraphStyle()
                compactSeparator.minimumLineHeight = 8
                compactSeparator.maximumLineHeight = 8
                compactSeparator.paragraphSpacing = 0
                storage.addAttribute(
                    .paragraphStyle,
                    value: compactSeparator,
                    range: separatorRange
                )
            }
        }

        private func isWhitespaceOnly(from start: Int, to end: Int, in source: NSString) -> Bool {
            guard start <= end else { return false }
            return source.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }

        private func styleHorizontalRules(in storage: NSTextStorage) {
            guard let textView = textView as? CenteredTextView,
                  let regex = try? NSRegularExpression(
                    pattern: #"(?m)^[ \t]{0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$"#
                  ) else { return }

            let fullRange = NSRange(location: 0, length: storage.length)
            let selection = textView.selectedRange()

            for match in regex.matches(in: storage.string, range: fullRange) {
                let isEditing = selection.location <= NSMaxRange(match.range)
                    && NSMaxRange(selection) >= match.range.location
                if isEditing {
                    storage.addAttributes([
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.boldSystemFont(ofSize: 16)
                    ], range: match.range)
                    continue
                }

                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ], range: match.range)
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = 28
                paragraph.maximumLineHeight = 28
                paragraph.paragraphSpacingBefore = 8
                paragraph.paragraphSpacing = 8
                storage.addAttribute(.paragraphStyle, value: paragraph, range: match.range)
                pendingDecorations.append(PendingDecoration(
                    characterLocation: match.range.location,
                    view: MarkdownDecorationView(kind: .horizontalRule)
                ))
            }
        }

        private func installDecorations(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let origin = textView.textContainerOrigin

            for pending in pendingDecorations {
                let glyph = layoutManager.glyphIndexForCharacter(at: pending.characterLocation)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let usedLine = layoutManager.lineFragmentUsedRect(
                    forGlyphAt: glyph,
                    effectiveRange: nil
                )
                switch pending.view.kind {
                case .bullet:
                    pending.view.frame = NSRect(
                        x: origin.x + line.minX + pending.view.bulletIndent,
                        y: origin.y + usedLine.midY - 6,
                        width: 12,
                        height: 12
                    )
                case .number(let level, _):
                    pending.view.frame = NSRect(
                        x: origin.x + line.minX + CGFloat(level * 18 + 2),
                        y: origin.y + usedLine.midY - 8,
                        width: 26,
                        height: 16
                    )
                case .horizontalRule:
                    pending.view.frame = NSRect(
                        x: origin.x,
                        y: origin.y + line.minY,
                        width: min(800, textView.bounds.width - origin.x * 2),
                        height: line.height
                    )
                case .headingRule:
                    let linePadding = textContainer.lineFragmentPadding
                    pending.view.frame = NSRect(
                        x: origin.x + linePadding,
                        y: origin.y + usedLine.maxY + 2,
                        width: max(1, textContainer.containerSize.width - linePadding * 2),
                        height: 1
                    )
                }
                textView.addSubview(pending.view)
            }
        }

        private func styleCodeBlocks(in storage: NSTextStorage, fontSize: Double) {
            guard let regex = try? NSRegularExpression(
                pattern: #"(?ms)^[ \t]{0,3}```[^\n]*\n.*?^[ \t]{0,3}```[ \t]*$"#
            ) else { return }

            let source = storage.string as NSString
            let fullRange = NSRange(location: 0, length: storage.length)

            for match in regex.matches(in: storage.string, range: fullRange) {
                let openingLine = source.lineRange(
                    for: NSRange(location: match.range.location, length: 0)
                )
                let lastCharacter = max(match.range.location, NSMaxRange(match.range) - 1)
                let closingLine = source.lineRange(
                    for: NSRange(location: lastCharacter, length: 0)
                )
                let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
                if selection.location < NSMaxRange(match.range),
                   NSMaxRange(selection) >= match.range.location {
                    styleEditableCodeBlock(
                        in: storage,
                        range: match.range,
                        fontSize: fontSize
                    )
                    continue
                }

                let openingText = source.substring(with: contentRange(for: openingLine, in: source))
                let indent = openingText.prefix { $0 == " " || $0 == "\t" }
                let language = openingText
                    .dropFirst(indent.count + 3)
                    .trimmingCharacters(in: .whitespaces)
                let contentStart = NSMaxRange(openingLine)
                let contentEnd = closingLine.location
                let content = contentStart <= contentEnd
                    ? source.substring(with: NSRange(
                        location: contentStart,
                        length: contentEnd - contentStart
                    ))
                    : ""
                let lines = content
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { line in
                        line.hasPrefix(indent) ? String(line.dropFirst(indent.count)) : String(line)
                    }
                let preview = MarkdownCodePreview(
                    lines: lines.last == "" ? Array(lines.dropLast()) : lines,
                    language: language,
                    width: max(
                        240,
                        textView?.textContainer?.containerSize.width
                            ?? (textView?.bounds.width ?? 800) - 104
                    ),
                    fontSize: max(11, fontSize - 1)
                )
                preview.onEdit = { [weak self] in
                    guard let self, let textView = self.textView else { return }
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: contentStart, length: 0))
                    self.applyStyles(
                        fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16)
                    )
                }

                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear
                ], range: match.range)
                let blockLines = lineRanges(in: source).filter {
                    NSIntersectionRange($0, match.range).length > 0
                }
                for (index, lineRange) in blockLines.enumerated() {
                    let affectedRange = NSIntersectionRange(lineRange, match.range)
                    guard affectedRange.length > 0 else { continue }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.paragraphSpacing = 0
                    if index == 0 {
                        paragraph.minimumLineHeight = preview.codeHeight
                        paragraph.maximumLineHeight = preview.codeHeight
                        paragraph.paragraphSpacingBefore = 8
                        paragraph.paragraphSpacing = 8
                    } else {
                        paragraph.minimumLineHeight = 0.1
                        paragraph.maximumLineHeight = 0.1
                    }
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: affectedRange)
                }
                pendingCodePreviews.append(PendingCodePreview(
                    characterLocation: match.range.location,
                    preview: preview
                ))
            }
        }

        private func styleEditableCodeBlock(
            in storage: NSTextStorage,
            range: NSRange,
            fontSize: Double
        ) {
            let codeFont = NSFont.monospacedSystemFont(
                ofSize: max(11, fontSize - 1),
                weight: .regular
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 0

            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.08),
                .paragraphStyle: paragraph
            ], range: range)
        }

        private func installCodePreviews(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)

            for pending in pendingCodePreviews {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: pending.characterLocation)
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil
                )
                let origin = textView.textContainerOrigin
                pending.preview.frame.origin = NSPoint(
                    x: origin.x,
                    y: origin.y + lineRect.minY
                )
                textView.addSubview(pending.preview)
            }
        }

        private func styleTables(in storage: NSTextStorage, fontSize: Double) {
            let source = storage.string as NSString
            let lines = lineRanges(in: source)
            guard lines.count >= 2 else { return }

            var lineIndex = 0
            while lineIndex + 1 < lines.count {
                let header = tableCells(in: source.substring(with: lines[lineIndex]))
                let delimiter = tableCells(in: source.substring(with: lines[lineIndex + 1]))

                guard header.count >= 2,
                      header.count == delimiter.count,
                      delimiter.allSatisfy(isTableDelimiter) else {
                    lineIndex += 1
                    continue
                }

                var endIndex = lineIndex + 2
                while endIndex < lines.count {
                    let cells = tableCells(in: source.substring(with: lines[endIndex]))
                    guard !cells.isEmpty else { break }
                    endIndex += 1
                }

                styleTable(
                    in: storage,
                    source: source,
                    lineRanges: Array(lines[lineIndex..<endIndex]),
                    rows: [header] + Array((lineIndex + 2)..<endIndex).map {
                        tableCells(in: source.substring(with: lines[$0]))
                    },
                    fontSize: fontSize
                )
                lineIndex = endIndex
            }
        }

        private func styleTable(
            in storage: NSTextStorage,
            source: NSString,
            lineRanges: [NSRange],
            rows: [[String]],
            fontSize: Double
        ) {
            guard let firstLine = lineRanges.first, let lastLine = lineRanges.last else { return }
            let tableRange = NSUnionRange(firstLine, lastLine)
            let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            if selection.location < NSMaxRange(tableRange),
               NSMaxRange(selection) >= tableRange.location {
                styleEditableTable(
                    in: storage,
                    source: source,
                    lineRanges: lineRanges,
                    fontSize: fontSize
                )
                return
            }

            let containerWidth = textView?.textContainer?.containerSize.width
                ?? (textView?.bounds.width ?? 800) - 104
            let linePadding = textView?.textContainer?.lineFragmentPadding ?? 5
            let width = max(320, containerWidth - linePadding * 2)
            let preview = MarkdownTablePreview(
                rows: rows,
                width: width,
                fontSize: max(11, fontSize - 2)
            )
            preview.onEdit = { [weak self] in
                guard let self, let textView = self.textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: tableRange.location, length: 0))
                self.applyStyles(
                    fontSize: UserDefaults.standard.double(forKey: "editorFontSize").nonzero(or: 16)
                )
            }

            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear
            ], range: tableRange)
            for (index, lineRange) in lineRanges.enumerated() {
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 0
                if index == 0 {
                    style.minimumLineHeight = preview.tableHeight
                    style.maximumLineHeight = preview.tableHeight
                    style.paragraphSpacingBefore = 8
                    style.paragraphSpacing = 8
                } else {
                    style.minimumLineHeight = 0.1
                    style.maximumLineHeight = 0.1
                }
                storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
            }
            pendingTablePreviews.append(PendingTablePreview(
                characterLocation: tableRange.location,
                preview: preview
            ))
        }

        private func installTablePreviews(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)

            for pending in pendingTablePreviews {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: pending.characterLocation)
                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil
                )
                let origin = textView.textContainerOrigin
                let linePadding = textContainer.lineFragmentPadding
                pending.preview.frame.origin = NSPoint(
                    x: origin.x + linePadding,
                    y: origin.y + lineRect.minY
                )
                textView.addSubview(pending.preview)
            }
        }

        private func styleEditableTable(
            in storage: NSTextStorage,
            source: NSString,
            lineRanges: [NSRange],
            fontSize: Double
        ) {
            let tableFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
            for (rowIndex, lineRange) in lineRanges.enumerated() {
                let contentRange = contentRange(for: lineRange, in: source)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                paragraph.paragraphSpacing = 0

                storage.addAttributes([
                    .font: rowIndex == 0
                        ? NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .semibold)
                        : tableFont,
                    .foregroundColor: rowIndex == 1 ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: paragraph
                ], range: contentRange)

                var isEscaped = false
                for location in contentRange.location..<NSMaxRange(contentRange) {
                    let character = source.character(at: location)
                    if character == 0x7C, !isEscaped {
                        storage.addAttribute(
                            .foregroundColor,
                            value: NSColor.separatorColor,
                            range: NSRange(location: location, length: 1)
                        )
                    }
                    isEscaped = character == 0x5C && !isEscaped
                    if character != 0x5C { isEscaped = false }
                }
            }
        }

        private func lineRanges(in source: NSString) -> [NSRange] {
            var ranges: [NSRange] = []
            var location = 0

            while location < source.length {
                let range = source.lineRange(for: NSRange(location: location, length: 0))
                ranges.append(range)
                location = NSMaxRange(range)
            }
            return ranges
        }

        private func contentRange(for lineRange: NSRange, in source: NSString) -> NSRange {
            var length = lineRange.length
            while length > 0 {
                let character = source.character(at: lineRange.location + length - 1)
                guard character == 0x0A || character == 0x0D else { break }
                length -= 1
            }
            return NSRange(location: lineRange.location, length: length)
        }

        private func tableCells(in line: String) -> [String] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("|") else { return [] }

            var cells: [String] = []
            var cell = ""
            var isEscaped = false

            for character in trimmed {
                if character == "|", !isEscaped {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                } else {
                    cell.append(character)
                }

                if character == "\\", !isEscaped {
                    isEscaped = true
                } else {
                    isEscaped = false
                }
            }
            cells.append(cell.trimmingCharacters(in: .whitespaces))

            if trimmed.hasPrefix("|") { cells.removeFirst() }
            if trimmed.hasSuffix("|") { cells.removeLast() }
            return cells
        }

        private func isTableDelimiter(_ cell: String) -> Bool {
            cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }

        private func styleHeadings(in storage: NSTextStorage, fontSize: Double) {
            stylePattern(#"(?m)^(#{1,6})[ \t]+.*$"#, in: storage) { match in
                let source = storage.string as NSString
                if let editingHeadingLocation,
                   NSLocationInRange(editingHeadingLocation, match.range) {
                    let bodyParagraph = NSMutableParagraphStyle()
                    bodyParagraph.lineSpacing = 6
                    bodyParagraph.paragraphSpacing = 6
                    return [
                        .font: NSFont.systemFont(ofSize: fontSize),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: bodyParagraph
                    ]
                }
                let level = source.substring(with: match.range(at: 1)).count
                let sizes: [Double] = [25.6, 21.6, 19, 18, 17, 16]
                let size = max(fontSize, sizes[level - 1])
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = level <= 2 ? 18 : 12
                let followingText = source.substring(from: NSMaxRange(match.range))
                let isFollowedByH2 = level == 1 && followingText.range(
                    of: #"^\r?\n(?:[ \t]*\r?\n)?##[ \t]+"#,
                    options: .regularExpression
                ) != nil
                style.paragraphSpacing = level == 1
                    ? (isFollowedByH2 ? 8 : 22)
                    : level == 2 ? 22 : level == 3 ? 14 : 8
                return [
                    .font: NSFont.systemFont(
                        ofSize: size,
                        weight: level <= 2 ? .bold : .semibold
                    ),
                    .foregroundColor: level <= 3
                        ? NSColor.labelColor.withAlphaComponent(0.68)
                        : NSColor.labelColor,
                    .paragraphStyle: style
                ]
            }

            guard let textView = textView as? CenteredTextView,
                  let regex = try? NSRegularExpression(pattern: #"(?m)^(#{1,6})[ \t]+"#) else { return }
            let range = NSRange(location: 0, length: storage.length)
            for match in regex.matches(in: storage.string, range: range) {
                let lineRange = (storage.string as NSString).lineRange(
                    for: NSRange(location: match.range.location, length: 0)
                )
                textView.headingSourceRanges.append(lineRange)
                let isEditing = editingHeadingLocation.map {
                    NSLocationInRange($0, lineRange)
                } ?? false
                let level = (storage.string as NSString)
                    .substring(with: match.range(at: 1)).count
                if !isEditing {
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.1),
                        .foregroundColor: NSColor.clear
                    ], range: match.range)
                    if level == 2 {
                        pendingDecorations.append(PendingDecoration(
                            characterLocation: match.range.location,
                            view: MarkdownDecorationView(kind: .headingRule)
                        ))
                    }
                }
            }
        }

        private func styleBlankSeparatorLines(in storage: NSTextStorage) {
            guard let blankLineRegex = try? NSRegularExpression(
                pattern: #"(?m)^([ \t]*\r?\n)"#
            ), let codeBlockRegex = try? NSRegularExpression(
                pattern: #"(?ms)^[ \t]{0,3}```[^\n]*\n.*?^[ \t]{0,3}```[ \t]*$"#
            ) else { return }

            let fullRange = NSRange(location: 0, length: storage.length)
            let selectionLocation = textView?.selectedRange().location
            let codeBlockRanges = codeBlockRegex.matches(
                in: storage.string,
                range: fullRange
            ).map(\.range)
            var previousBlankLineEnd: Int?
            for match in blankLineRegex.matches(in: storage.string, range: fullRange) {
                let blankLineRange = match.range(at: 1)
                let continuesBlankLineRun = previousBlankLineEnd == blankLineRange.location
                previousBlankLineEnd = NSMaxRange(blankLineRange)
                if continuesBlankLineRun {
                    continue
                }
                if let selectionLocation,
                   selectionLocation >= blankLineRange.location,
                   selectionLocation <= NSMaxRange(blankLineRange) {
                    continue
                }
                if codeBlockRanges.contains(where: {
                    NSIntersectionRange($0, blankLineRange).length > 0
                }) {
                    continue
                }

                let collapsedParagraph = NSMutableParagraphStyle()
                collapsedParagraph.minimumLineHeight = 1
                collapsedParagraph.maximumLineHeight = 1
                storage.addAttributes([
                    .font: NSFont.systemFont(ofSize: 0.1),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: collapsedParagraph
                ], range: blankLineRange)
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

        private func styleStrongEmphasis(in storage: NSTextStorage, fontSize: Double) {
            guard let regex = try? NSRegularExpression(pattern: #"(\*\*|__)(.+?)\1"#) else {
                return
            }

            let range = NSRange(location: 0, length: storage.length)
            for match in regex.matches(in: storage.string, range: range) {
                let openingMarker = match.range(at: 1)
                let content = match.range(at: 2)
                let closingMarker = NSRange(
                    location: NSMaxRange(content),
                    length: openingMarker.length
                )

                storage.addAttribute(
                    .font,
                    value: NSFont.boldSystemFont(ofSize: fontSize),
                    range: content
                )
                for marker in [openingMarker, closingMarker] {
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: 0.1),
                        .foregroundColor: NSColor.clear
                    ], range: marker)
                }
            }
        }

        private struct PendingTablePreview {
            let characterLocation: Int
            let preview: MarkdownTablePreview
        }

        private struct PendingCodePreview {
            let characterLocation: Int
            let preview: MarkdownCodePreview
        }

        private struct PendingDecoration {
            let characterLocation: Int
            let view: MarkdownDecorationView
        }
    }
}

private final class MarkdownCodePreview: NSView {
    var onEdit: (() -> Void)?
    let codeHeight: CGFloat

    private let lines: [String]
    private let language: String
    private let font: NSFont
    private let lineHeight: CGFloat

    override var isFlipped: Bool { true }

    init(lines: [String], language: String, width: CGFloat, fontSize: CGFloat) {
        self.lines = lines.isEmpty ? [""] : lines
        self.language = language
        font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        codeHeight = CGFloat(max(1, lines.count)) * lineHeight + 28
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: codeHeight))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        toolTip = "Click to edit Markdown code block"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        onEdit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.secondaryLabelColor.withAlphaComponent(0.08).setFill()
        bounds.fill()

        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 7,
            yRadius: 7
        ).stroke()

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                at: NSPoint(x: 16, y: 14 + CGFloat(index) * lineHeight),
                withAttributes: textAttributes
            )
        }

        if !language.isEmpty {
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let labelSize = (language as NSString).size(withAttributes: labelAttributes)
            (language.uppercased() as NSString).draw(
                at: NSPoint(x: bounds.maxX - labelSize.width - 12, y: 8),
                withAttributes: labelAttributes
            )
        }
    }
}

private final class MarkdownTablePreview: NSView {
    var onEdit: (() -> Void)?
    let tableHeight: CGFloat

    private let rows: [[String]]
    private let columnWidths: [CGFloat]
    private let rowHeights: [CGFloat]
    private let fontSize: CGFloat
    private let padding: CGFloat = 10

    override var isFlipped: Bool { true }

    init(rows: [[String]], width: CGFloat, fontSize: CGFloat) {
        let sourceRows = rows
        let displayFontSize = fontSize
        self.rows = rows
        self.fontSize = fontSize

        let columnCount = max(1, rows.map(\.count).max() ?? 1)
        var weights = Array(repeating: CGFloat(4), count: columnCount)
        for row in rows {
            for (index, cell) in row.enumerated() {
                weights[index] = max(weights[index], sqrt(CGFloat(cell.count)))
            }
        }
        let minimumWidth: CGFloat = min(72, width / CGFloat(columnCount))
        let flexibleWidth = max(0, width - minimumWidth * CGFloat(columnCount))
        let weightTotal = weights.reduce(0, +)
        let calculatedColumnWidths = weights.map {
            minimumWidth + flexibleWidth * ($0 / weightTotal)
        }
        columnWidths = calculatedColumnWidths

        let calculatedRowHeights = sourceRows.enumerated().map { rowIndex, row in
            let font = rowIndex == 0
                ? NSFont.systemFont(ofSize: displayFontSize, weight: .semibold)
                : NSFont.systemFont(ofSize: displayFontSize)
            var height = displayFontSize + 10
            for (columnIndex, cell) in row.enumerated()
                where columnIndex < calculatedColumnWidths.count {
                let bounds = (cell as NSString).boundingRect(
                    with: NSSize(
                        width: max(1, calculatedColumnWidths[columnIndex] - 20),
                        height: .greatestFiniteMagnitude
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                height = max(height, ceil(bounds.height) + 10)
            }
            return height
        }
        rowHeights = calculatedRowHeights
        tableHeight = calculatedRowHeights.reduce(0, +)

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: tableHeight))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        toolTip = "Click to edit Markdown table"
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        onEdit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        var rowY: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = rowHeights[rowIndex]
            let rowRect = NSRect(x: 0, y: rowY, width: bounds.width, height: rowHeight)

            if rowIndex == 0 {
                NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                rowRect.fill()
            } else if rowIndex.isMultiple(of: 2) {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.06).setFill()
                rowRect.fill()
            }

            var columnX: CGFloat = 0
            for columnIndex in columnWidths.indices {
                let width = columnWidths[columnIndex]
                let cell = columnIndex < row.count ? row[columnIndex] : ""
                let textRect = NSRect(
                    x: columnX + padding,
                    y: rowY + padding / 2,
                    width: max(1, width - padding * 2),
                    height: rowHeight - padding
                )
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: rowIndex == 0
                        ? NSFont.systemFont(ofSize: fontSize, weight: .semibold)
                        : NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.labelColor
                ]
                (cell as NSString).draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes
                )

                columnX += width
                if columnIndex < columnWidths.count - 1 {
                    drawLine(
                        from: NSPoint(x: columnX, y: rowY),
                        to: NSPoint(x: columnX, y: rowY + rowHeight)
                    )
                }
            }
            drawLine(
                from: NSPoint(x: 0, y: rowY + rowHeight),
                to: NSPoint(x: bounds.width, y: rowY + rowHeight)
            )
            rowY += rowHeight
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 5,
            yRadius: 5
        ).stroke()
    }

    private func drawLine(from start: NSPoint, to end: NSPoint) {
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }
}

private final class CenteredTextView: NSTextView {
    private let pageContentInset: CGFloat = 52
    private let maximumContentWidth: CGFloat = 700
    private let pageVerticalMargin: CGFloat = 24
    var bulletSourceRanges: [NSRange] = []
    var activeBulletSourceRanges: [NSRange] = []
    var headingSourceRanges: [NSRange] = []
    var onCanvasClick: (() -> Void)?
    var onBulletDoubleClick: ((Int) -> Void)?
    var onHeadingDoubleClick: ((Int) -> Void)?
    var onEditorClick: ((Int?) -> Void)?
    var onExitEditMode: (() -> Void)?
    var onCopyAll: (() -> Void)?
    private var isCanvasFocused = false
    private var cursorTrackingArea: NSTrackingArea?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainerInset = NSSize(
            width: max(pageContentInset, (newSize.width - maximumContentWidth) / 2),
            height: pageVerticalMargin + pageContentInset
        )
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.auraPageShellColor.setFill()
        dirtyRect.fill()

        let pageRect = currentPageRect

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.textBackgroundColor.setFill()
        let pagePath = NSBezierPath(roundedRect: pageRect, xRadius: 2.5, yRadius: 2.5)
        pagePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        pagePath.addClip()
        NSColor(patternImage: Self.paperTexture).setFill()
        pageRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        pagePath.lineWidth = 0.5
        pagePath.stroke()
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard currentPageRect.contains(point) else {
            isCanvasFocused = true
            let location = min(selectedRange().location, string.utf16.count)
            setSelectedRange(NSRange(location: location, length: 0))
            window?.makeFirstResponder(self)
            onCanvasClick?()
            needsDisplay = true
            return
        }

        isCanvasFocused = false
        guard let character = character(at: point) else {
            focusCanvas()
            return
        }
        if event.clickCount == 2,
           bulletSourceRanges.contains(where: { NSLocationInRange(character, $0) }) {
            onBulletDoubleClick?(character)
        } else if event.clickCount == 2,
                  headingSourceRanges.contains(where: { NSLocationInRange(character, $0) }) {
            onHeadingDoubleClick?(character)
        } else {
            onEditorClick?(character)
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        cursorTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if currentPageRect.contains(point) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func drawInsertionPoint(
        in rect: NSRect,
        color: NSColor,
        turnedOn flag: Bool
    ) {
        guard !isCanvasFocused else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func copy(_ sender: Any?) {
        guard isCanvasFocused else {
            super.copy(sender)
            return
        }
        onCopyAll?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isCanvasFocused,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers.contains(.command) {
            onCopyAll?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if isCanvasFocused, item.action == #selector(copy(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, modifiers.isEmpty {
            focusCanvas()
            return
        }
        if isCanvasFocused,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers.contains(.control) {
            onCopyAll?()
            return
        }
        super.keyDown(with: event)
    }

    private func focusCanvas() {
        isCanvasFocused = true
        window?.makeFirstResponder(self)
        onExitEditMode?()
        needsDisplay = true
    }

    private var currentPageRect: NSRect {
        let pageWidth = min(bounds.width, maximumContentWidth + pageContentInset * 2)
        var contentHeight: CGFloat = 0
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            contentHeight = layoutManager.usedRect(for: textContainer).height
        }
        return NSRect(
            x: (bounds.width - pageWidth) / 2,
            y: bounds.minY + pageVerticalMargin,
            width: pageWidth,
            height: max(pageContentInset * 2 + contentHeight, pageContentInset * 2 + 20)
        )
    }

    private func character(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let glyph = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let usedLine = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyph,
            effectiveRange: nil
        ).insetBy(dx: -4, dy: -2)
        guard usedLine.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    private static let paperTexture = NSImage(
        size: NSSize(width: 36, height: 36),
        flipped: false
    ) { _ in
        NSColor(calibratedWhite: 0.45, alpha: 0.018).setFill()
        [
            NSPoint(x: 4, y: 7),
            NSPoint(x: 17, y: 3),
            NSPoint(x: 29, y: 12),
            NSPoint(x: 9, y: 24),
            NSPoint(x: 24, y: 30),
            NSPoint(x: 34, y: 22)
        ].forEach { point in
            NSRect(x: point.x, y: point.y, width: 0.5, height: 0.5).fill()
        }
        return true
    }

}

private final class MarkdownDecorationView: NSView {
    enum Kind {
        case bullet(level: Int)
        case number(level: Int, label: String)
        case horizontalRule
        case headingRule
    }

    let kind: Kind

    var bulletIndent: CGFloat {
        if case .bullet(let level) = kind {
            return CGFloat(level * 18 + 14)
        }
        return 0
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch kind {
        case .bullet(let level):
            let diameter: CGFloat = level.isMultiple(of: 2) ? 6 : 5
            let rect = NSRect(
                x: (bounds.width - diameter) / 2,
                y: (bounds.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            let path = NSBezierPath(ovalIn: rect)
            NSColor.secondaryLabelColor.set()
            if level.isMultiple(of: 2) {
                path.fill()
            } else {
                path.lineWidth = 1.25
                path.stroke()
            }
        case .number(_, let label):
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            label.draw(
                in: bounds,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]
            )
        case .horizontalRule, .headingRule:
            let path = NSBezierPath()
            path.lineWidth = kind.isHeadingRule ? 0.5 : 1
            path.move(to: NSPoint(x: 0, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
            NSColor.separatorColor.withAlphaComponent(kind.isHeadingRule ? 0.35 : 1).setStroke()
            path.stroke()
        }
    }
}

private extension MarkdownDecorationView.Kind {
    var isHeadingRule: Bool {
        if case .headingRule = self { return true }
        return false
    }
}

private extension Double {
    func nonzero(or fallback: Double) -> Double { self == 0 ? fallback : self }
}

private extension NSColor {
    static let auraPageShellColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.11, alpha: 1)
            : NSColor(calibratedWhite: 0.955, alpha: 1)
    }
}
