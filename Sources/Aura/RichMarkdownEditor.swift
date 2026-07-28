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
        private var pendingTablePreviews: [PendingTablePreview] = []
        private var pendingCodePreviews: [PendingCodePreview] = []

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

        func applyStyles(fontSize: Double) {
            guard let textView, let storage = textView.textStorage, !isStyling else { return }
            isStyling = true
            defer { isStyling = false }

            textView.subviews
                .filter { $0 is MarkdownTablePreview || $0 is MarkdownCodePreview }
                .forEach { $0.removeFromSuperview() }
            pendingTablePreviews.removeAll()
            pendingCodePreviews.removeAll()

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
            styleCodeBlocks(in: storage, fontSize: fontSize)
            styleTables(in: storage, fontSize: fontSize)
            storage.endEditing()
            installTablePreviews(in: textView)
            installCodePreviews(in: textView)
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

            let width = min(
                1_000,
                max(320, (textView?.bounds.width ?? 800) - 48)
            )
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
                pending.preview.frame.origin = NSPoint(
                    x: max(24, (textView.bounds.width - pending.preview.frame.width) / 2),
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

        private struct PendingTablePreview {
            let characterLocation: Int
            let preview: MarkdownTablePreview
        }

        private struct PendingCodePreview {
            let characterLocation: Int
            let preview: MarkdownCodePreview
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
                NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
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
