import AppKit
import SwiftUI
import XCTest
@testable import ChopChop

@MainActor final class ReleaseNotesTests: XCTestCase {
    private let baseURL = URL(string: "https://github.com/Conight/ChopChop/releases/tag/v1.0.0")!

    func testBlockStructureAndInlineFormattingSurviveRendering() throws {
        let rendered = ReleaseNotesRenderer.render("""
        ## Improvements

        **Reliable** downloads, *native* controls and ~~old~~ behavior.

        - First item with `code`
          - Nested item

          Another paragraph in the nested item.
        - Second item

        3. Three
        4. Four

        > A quoted note

        ```sh
        shasum -a 256 archive.dmg
        echo done
        ```

        [Read more](https://example.com/notes)
        """, baseURL: baseURL)
        let text = rendered.string as NSString
        func attributes(_ needle: String) throws -> [NSAttributedString.Key: Any] {
            let location = text.range(of: needle).location
            XCTAssertNotEqual(location, NSNotFound)
            return rendered.attributes(at: location, effectiveRange: nil)
        }
        XCTAssertTrue(rendered.string.hasPrefix("Improvements\n"))
        XCTAssertTrue(rendered.string.contains("•\tFirst item"))
        XCTAssertTrue(rendered.string.contains("•\tNested item"))
        XCTAssertTrue(rendered.string.contains("3.\tThree\n4.\tFour"))
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertFalse(rendered.string.contains("**"))
        let title = try XCTUnwrap(attributes("Improvements")[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(title.headerLevel, 2)
        let bold = try XCTUnwrap(attributes("Reliable")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let italic = try XCTUnwrap(attributes("native")[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        XCTAssertNotNil(try attributes("old")[.strikethroughStyle])
        let code = try XCTUnwrap(attributes("shasum")[.font] as? NSFont)
        XCTAssertTrue(code.isFixedPitch)
        XCTAssertEqual(try attributes("Read more")[.link] as? URL, URL(string: "https://example.com/notes"))
        let first = try XCTUnwrap(attributes("First item")[.paragraphStyle] as? NSParagraphStyle)
        let nested = try XCTUnwrap(attributes("Nested item")[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertGreaterThan(nested.headIndent, first.headIndent)
        XCTAssertTrue(rendered.string.contains("\nAnother paragraph"), "Continuation paragraphs must not gain a second bullet")
    }

    func testTablesUseNativeCellsAndRemoteContentCannotBecomeActiveAttachments() throws {
        let rendered = ReleaseNotesRenderer.render("""
        | Feature | Status |
        | :--- | ---: |
        | 下载 | Ready |

        [Good](/Conight/ChopChop) [Unsafe](file:///tmp/private) [Script](javascript:alert)
        ![Diagram](https://example.com/tracker.png)
        <script>alert('test')</script>
        """, baseURL: baseURL)
        let text = rendered.string as NSString
        for (word, row, column) in [("Feature", 0, 0), ("Status", 0, 1), ("下载", 1, 0), ("Ready", 1, 1)] {
            let style = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: text.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle)
            let cell = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
            XCTAssertEqual(cell.startingRow, row)
            XCTAssertEqual(cell.startingColumn, column)
            if column == 1 { XCTAssertEqual(style.alignment, .right) }
        }
        var links: [URL] = []
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.attachment])
            XCTAssertNil(attributes[.imageURL])
            if let link = attributes[.link] as? URL { links.append(link) }
        }
        XCTAssertEqual(links, [URL(string: "https://github.com/Conight/ChopChop")!])
        XCTAssertTrue(rendered.string.contains("Diagram"))
    }

    func testMarkdownReflowsAtNarrowWidthsInLightAndDarkAppearance() async throws {
        let markdown = """
        ## What’s New

        - **Reliable downloads:** 下载记录会保留，重新打开应用后任务保持暂停。
        - **Native controls:** Select, copy and open [documentation](https://example.com).
          - Nested items stay aligned when a line wraps onto the next line.

        ### Installation

        > Download the installer, then follow the instructions.

        ```sh
        shasum -a 256 -c ChopChop-v0.0.1-beta.2-macos-arm64.dmg.sha256
        ```

        | Feature | Status |
        | --- | --- |
        | English / 简体中文 | Ready |
        | Download history | Preserved |

        \(String(repeating: "LongUnbrokenReleaseAssetName", count: 8))

        Final paragraph. 最后一段。
        """
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingController(rootView: ScrollView {
                ReleaseNotesView(markdown: markdown, baseURL: baseURL).frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.background(.background))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = host
            window.orderBack(nil)
            defer { window.close() }
            var previousHeight: CGFloat = 0
            for width in [480, 400] {
                window.setContentSize(NSSize(width: width, height: 650))
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutSubtreeIfNeeded()
                let view = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextView }.first)
                XCTAssertTrue(view.isSelectable)
                XCTAssertFalse(view.isEditable)
                let container = try XCTUnwrap(view.textContainer)
                let layout = try XCTUnwrap(view.layoutManager)
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container)
                XCTAssertLessThanOrEqual(used.maxX, CGFloat(width) - 48 + 1, "Long code, links and tables must wrap")
                XCTAssertLessThanOrEqual(used.maxY, view.bounds.height + 1, "The final paragraph must be reachable")
                XCTAssertGreaterThanOrEqual(view.bounds.height, previousHeight)
                previousHeight = view.bounds.height
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let output = try Aria2NextPaths.supportDirectory().appendingPathComponent("Design Previews")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("release-notes-\(appearance.rawValue)-\(width).png"))
                print("RELEASE_NOTES_PREVIEW=\(output.path)")
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
