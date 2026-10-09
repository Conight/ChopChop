import AppKit
import SwiftUI

/// Selectable native text inside the update window's existing scroll view.
struct ReleaseNotesView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        // SwiftUI owns the frame; the text view must not resize itself after it is placed.
        view.isVerticallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize.height = .greatestFiniteMagnitude
        view.setAccessibilityLabel(String(localized: "What’s New"))
        view.setAccessibilityIdentifier("app-update-release-notes")
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard context.coordinator.markdown != markdown || context.coordinator.baseURL != baseURL else { return }
        context.coordinator.markdown = markdown
        context.coordinator.baseURL = baseURL
        let text = ReleaseNotesRenderer.render(markdown, baseURL: baseURL)
        view.textStorage?.setAttributedString(text)
        context.coordinator.storage.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // SwiftUI can ask about several widths and then reuse a cached size. Measuring on the
        // displayed container would leave it at a trial width instead of the actual frame width.
        let container = context.coordinator.container
        let layout = context.coordinator.layout
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).maxY))
    }

    final class Coordinator {
        var markdown: String?
        var baseURL: URL?
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer()

        init() {
            container.lineFragmentPadding = 0
            layout.backgroundLayoutEnabled = false
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }
    }
}

/// Foundation parses Markdown structure; TextKit handles selection, links, wrapping and tables.
/// Presentation intents describe blocks but don't insert the paragraph separators or list markers.
@MainActor enum ReleaseNotesRenderer {
    static func render(_ markdown: String, baseURL: URL) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let parsed = try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible), baseURL: baseURL) else {
            return NSAttributedString(string: markdown, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        }
        let result = NSMutableAttributedString(string: "")
        var seenListItems = Set<Int>()
        var tables: [Int: NSTextTable] = [:]
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 10
            var font = bodyFont
            var color = NSColor.labelColor
            var prefix = ""
            var isCode = false

            let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
            let quoteDepth = components.filter { $0.kind == .blockQuote }.count
            let indentation = CGFloat(max(0, lists.count - 1) * 18 + quoteDepth * 14)
            style.firstLineHeadIndent = indentation
            style.headIndent = indentation
            if let item = components.first(where: { if case .listItem = $0.kind { return true }; return false }),
               case .listItem(let ordinal) = item.kind {
                if seenListItems.insert(item.identity).inserted {
                    prefix = lists.first?.kind == .orderedList ? "\(ordinal).\t" : "•\t"
                }
                let markerWidth = max(18, (prefix as NSString).size(withAttributes: [.font: font]).width)
                style.headIndent += markerWidth
                if prefix.isEmpty { style.firstLineHeadIndent = style.headIndent }
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                style.paragraphSpacing = 6
            }
            if quoteDepth > 0 { color = .secondaryLabelColor }
            for component in components {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: level == 1 ? 20 : level == 2 ? 17 : 14, weight: .semibold)
                    style.paragraphSpacingBefore = result.length == 0 ? 0 : 8
                    style.paragraphSpacing = 8
                    style.headerLevel = level
                case .codeBlock:
                    isCode = true
                    font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    style.lineBreakMode = .byCharWrapping
                    style.firstLineHeadIndent += 8
                    style.headIndent += 8
                    style.tailIndent = -8
                default: break
                }
            }

            if let component = components.first(where: { if case .table = $0.kind { return true }; return false }),
               case .table(let columns) = component.kind {
                let table = tables[component.identity] ?? NSTextTable()
                table.numberOfColumns = columns.count
                table.layoutAlgorithm = .fixed
                table.setContentWidth(100, type: .percentageValueType)
                tables[component.identity] = table
                var row = 0, column = 0
                for component in components {
                    switch component.kind {
                    case .tableRow(let index): row = index
                    case .tableCell(let index): column = index
                    case .tableHeaderRow: font = .systemFont(ofSize: bodyFont.pointSize, weight: .semibold)
                    default: break
                    }
                }
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setContentWidth(100 / CGFloat(max(1, columns.count)), type: .percentageValueType)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                if row == 0 { cell.backgroundColor = .quaternaryLabelColor }
                style.textBlocks = [cell]
                style.paragraphSpacing = 0
                if columns.indices.contains(column) {
                    switch columns[column].alignment {
                    case .left: style.alignment = .left
                    case .center: style.alignment = .center
                    case .right: style.alignment = .right
                    @unknown default: break
                    }
                }
            }

            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            let block = NSMutableAttributedString(string: prefix, attributes: base)
            for run in parsed[range].runs {
                var attributes = base
                let inline = run.inlinePresentationIntent ?? []
                var runFont = inline.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : font
                if inline.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                attributes[.font] = runFont
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if inline.contains(.code) || isCode { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
                // Build only text attributes. Embedded HTML/images cannot execute or load remote resources.
                if let link = run.link, ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                    attributes[.link] = link.absoluteURL
                }
                block.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            if !block.string.hasSuffix("\n") { block.append(NSAttributedString(string: "\n", attributes: base)) }
            result.append(block)
        }
        return result
    }
}
