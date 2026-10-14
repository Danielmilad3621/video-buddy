// Block-level Markdown for Claude's summaries: headings, paragraphs, bullets, numbered lists, rules.
// Inline bold/italic/code/links use Foundation's own Markdown parser.
import SwiftUI

enum MDBlock: Equatable {
    case heading(String, Int)
    case paragraph(String)
    case bullet(String, Int)
    case numbered(String, String)
    case rule
}

enum Markdown {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = [], paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count / 2
            if line.isEmpty { flush(); continue }
            if let m = line.wholeMatch(of: #/(#{1,6})\s+(.+)/#) {
                flush(); blocks.append(.heading(String(m.2), m.1.count)); continue
            }
            if line.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil { flush(); blocks.append(.rule); continue }
            if let m = line.wholeMatch(of: #/\*\*([^*]+?)\*\*:?/#) {
                flush(); blocks.append(.heading(String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: ": ")), 2)); continue
            }
            // "**TL;DR:** text" → a heading and its paragraph
            if let m = line.wholeMatch(of: #/\*\*([^*]{1,40}?):\*\*\s+(.+)/#) ?? line.wholeMatch(of: #/\*\*([^*]{1,40}?)\*\*:\s+(.+)/#) {
                flush(); blocks.append(.heading(String(m.1), 2)); blocks.append(.paragraph(String(m.2))); continue
            }
            if let m = line.wholeMatch(of: #/[-*•+]\s+(.+)/#) { flush(); blocks.append(.bullet(String(m.1), indent)); continue }
            if let m = line.wholeMatch(of: #/(\d+)[.)]\s+(.+)/#) { flush(); blocks.append(.numbered(String(m.1), String(m.2))); continue }
            paragraph.append(line)
        }
        flush()
        return blocks
    }

    /// Display title and icon for a section heading, matching the mockup's "AI Summary" / "Key Points" sections.
    static func section(_ title: String) -> (String, String) {
        let t = title.lowercased()
        if t.contains("tl;dr") || t.contains("tldr") { return ("AI Summary", "sparkles") }
        if t.contains("summary") || t.contains("overview") || t.contains("ملخص") { return (title, "sparkles") }
        if t.contains("key") || t.contains("أهم") || t.contains("نقاط") { return (title, "key.fill") }
        if t.contains("takeaway") || t.contains("action") || t.contains("next step") || t.hasPrefix("⭐") { return (title, "checkmark.seal.fill") }
        if t.contains("detail") { return (title, "info.circle.fill") }
        return (title, "text.alignleft")
    }

    /// True when the first letter is Arabic or Hebrew, so the summary lays out right-to-left.
    static func isRTL(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return false }
        return (0x0590...0x08FF).contains(first.value) || (0xFB1D...0xFEFF).contains(first.value)
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    @Environment(\.palette) private var p
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { item in
                block(item.element)
            }
        }
        .textSelection(.enabled)
        .environment(\.layoutDirection, Markdown.isRTL(text) ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case let .heading(title, level):
            let (shown, icon) = Markdown.section(title)
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(level <= 1 ? p.blue : p.text)
                Text(Markdown.inline(shown)).font(level <= 1 ? .title2.weight(.bold) : .title3.weight(.semibold))
            }
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
        case let .paragraph(t):
            Text(Markdown.inline(t)).lineSpacing(4).foregroundStyle(p.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        case let .bullet(t, indent):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("●").font(.system(size: 9)).foregroundStyle(p.blue)
                Text(Markdown.inline(t)).lineSpacing(3).foregroundStyle(p.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case let .numbered(n, t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(n).").monospacedDigit().foregroundStyle(p.blue)
                Text(Markdown.inline(t)).lineSpacing(3).foregroundStyle(p.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider().overlay(p.border)
        }
    }
}
