//
//  MarkdownRenderer.swift
//  ClaudeIsland
//
//  Markdown renderer using swift-markdown for efficient parsing
//

import Markdown
import SwiftUI

// MARK: - Document Cache

/// Caches parsed markdown documents to avoid re-parsing
private final class DocumentCache: @unchecked Sendable {
    static let shared = DocumentCache()
    private var cache: [String: Document] = [:]
    private let lock = NSLock()
    private let maxSize = 100

    func document(for text: String) -> Document {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cache[text] {
            return cached
        }
        // Enable strikethrough and other extended syntax
        let doc = Document(parsing: text, options: [.parseBlockDirectives, .parseSymbolLinks])
        if cache.count >= maxSize {
            cache.removeAll()
        }
        cache[text] = doc
        return doc
    }
}

// MARK: - Markdown Text View

/// Renders markdown text with inline formatting using swift-markdown
struct MarkdownText: View {
    let text: String
    let baseColor: Color
    let fontSize: CGFloat

    private let document: Document

    init(_ text: String, color: Color = .white.opacity(0.9), fontSize: CGFloat = 13) {
        self.text = text
        self.baseColor = color
        self.fontSize = fontSize
        self.document = DocumentCache.shared.document(for: text)
    }

    var body: some View {
        let children = Array(document.children)
        if children.isEmpty {
            // Fallback for empty parse result
            SwiftUI.Text(text)
                .foregroundColor(baseColor)
                .font(.system(size: fontSize))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    BlockRenderer(markup: child, baseColor: baseColor, fontSize: fontSize)
                }
            }
        }
    }
}

// MARK: - Block Renderer

private struct BlockRenderer: View {
    let markup: Markup
    let baseColor: Color
    let fontSize: CGFloat

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let paragraph = markup as? Paragraph {
            InlineRenderer(children: Array(paragraph.inlineChildren), baseColor: baseColor, fontSize: fontSize)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } else if let heading = markup as? Heading {
            headingView(heading)
        } else if let codeBlock = markup as? CodeBlock {
            CodeBlockView(code: codeBlock.code)
        } else if let blockQuote = markup as? BlockQuote {
            blockQuoteView(blockQuote)
        } else if let list = markup as? UnorderedList {
            unorderedListView(list)
        } else if let list = markup as? OrderedList {
            orderedListView(list)
        } else if markup is ThematicBreak {
            Divider()
                .background(baseColor.opacity(0.3))
                .padding(.vertical, 4)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func headingView(_ heading: Heading) -> some View {
        let text = InlineRenderer(children: Array(heading.inlineChildren), baseColor: baseColor, fontSize: fontSize).asText()
        switch heading.level {
        case 1: text.bold().italic().underline()
        case 2: text.bold()
        default: text.bold().foregroundColor(baseColor.opacity(0.7))
        }
    }

    @ViewBuilder
    private func blockQuoteView(_ blockQuote: BlockQuote) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(baseColor.opacity(0.4))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blockQuote.children.enumerated()), id: \.offset) { _, child in
                    if let para = child as? Paragraph {
                        InlineRenderer(children: Array(para.inlineChildren), baseColor: baseColor.opacity(0.7), fontSize: fontSize)
                            .asText()
                            .italic()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func unorderedListView(_ list: UnorderedList) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    SwiftUI.Text("•")
                        .font(.system(size: fontSize))
                        .foregroundColor(baseColor.opacity(0.6))
                        .frame(width: 12, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            if let para = child as? Paragraph {
                                InlineRenderer(children: Array(para.inlineChildren), baseColor: baseColor, fontSize: fontSize)
                            } else {
                                BlockRenderer(markup: child, baseColor: baseColor, fontSize: fontSize)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func orderedListView(_ list: OrderedList) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.listItems.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 6) {
                    SwiftUI.Text("\(index + 1).")
                        .font(.system(size: fontSize))
                        .foregroundColor(baseColor.opacity(0.6))
                        .frame(width: 20, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            if let para = child as? Paragraph {
                                InlineRenderer(children: Array(para.inlineChildren), baseColor: baseColor, fontSize: fontSize)
                            } else {
                                BlockRenderer(markup: child, baseColor: baseColor, fontSize: fontSize)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Inline Renderer

private struct InlineRenderer: View {
    let children: [InlineMarkup]
    let baseColor: Color
    let fontSize: CGFloat

    var body: some View {
        asText()
    }

    func asText() -> SwiftUI.Text {
        var result = SwiftUI.Text("")
        for child in children {
            result = result + renderInline(child)
        }
        return result
    }

    private func renderInline(_ inline: InlineMarkup) -> SwiftUI.Text {
        if let text = inline as? Markdown.Text {
            return SwiftUI.Text(text.string).foregroundColor(baseColor)
        } else if let strong = inline as? Strong {
            let plainText = strong.plainText
            return SwiftUI.Text(plainText)
                .fontWeight(.bold)
                .foregroundColor(baseColor)
        } else if let emphasis = inline as? Emphasis {
            let plainText = emphasis.plainText
            return SwiftUI.Text(plainText)
                .italic()
                .foregroundColor(baseColor)
        } else if let code = inline as? InlineCode {
            return SwiftUI.Text(code.code)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(baseColor)
        } else if let link = inline as? Markdown.Link {
            let plainText = link.plainText
            return SwiftUI.Text(plainText)
                .foregroundColor(Color.blue)
                .underline()
        } else if let strike = inline as? Strikethrough {
            let plainText = strike.plainText
            return SwiftUI.Text(plainText)
                .strikethrough()
                .foregroundColor(baseColor)
        } else if inline is SoftBreak {
            return SwiftUI.Text(" ")
        } else if inline is LineBreak {
            return SwiftUI.Text("\n")
        } else {
            return SwiftUI.Text(inline.plainText).foregroundColor(baseColor)
        }
    }

    private func renderChildren(_ children: [InlineMarkup]) -> SwiftUI.Text {
        var result = SwiftUI.Text("")
        for child in children {
            result = result + renderInline(child)
        }
        return result
    }
}

// MARK: - Code Block View

private struct CodeBlockView: View {
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SwiftUI.Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(6)
    }
}
