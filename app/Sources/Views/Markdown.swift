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

    /// The summary split at its headings, one card each (TL;DR, Key Points, Action Takeaways…). Text before the first
    /// heading, or a summary without headings (Brief, Bullets), becomes one untitled card. Empty headings are dropped.
    static func sections(_ blocks: [MDBlock]) -> [MDSection] {
        var out: [MDSection] = []
        for b in blocks {
            if case let .heading(title, _) = b { out.append(MDSection(title: title, blocks: [])); continue }
            if case .rule = b { continue }
            if out.isEmpty { out.append(MDSection(title: nil, blocks: [])) }
            out[out.count - 1].blocks.append(b)
        }
        return out.filter { !$0.blocks.isEmpty }
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

struct MDSection: Equatable {
    var title: String?
    var blocks: [MDBlock]

    enum Kind { case tldr, keyPoints, takeaways, other }

    /// Which card style a section gets, from its heading (English or Arabic) or, untitled, from its content.
    var kind: Kind {
        guard let t = title?.lowercased() else {
            return blocks.allSatisfy { if case .paragraph = $0 { false } else { true } } ? .keyPoints : .tldr
        }
        if t.contains("tl;dr") || t.contains("tldr") || t.contains("summary") || t.contains("overview") || t.contains("ملخص") { return .tldr }
        if t.contains("takeaway") || t.contains("action") || t.contains("next step") || t.hasPrefix("⭐") || t.contains("خلاصة")
            || t.contains("نصائح") || t.contains("خطوات") { return .takeaways }
        if t.contains("key") || t.contains("main point") || t.contains("أهم") || t.contains("نقاط") { return .keyPoints }
        return .other
    }

    var displayTitle: String {
        title ?? (kind == .keyPoints ? "Key Points" : "Summary")
    }
}

/// A summary as cards: TL;DR, Key Points (numbered), Action Takeaways (ticked), and any other sections.
struct SummaryCards: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Markdown.sections(Markdown.parse(text)).enumerated()), id: \.offset) { SummaryCard(section: $0.element) }
        }
        .textSelection(.enabled)
        .environment(\.layoutDirection, Markdown.isRTL(text) ? .rightToLeft : .leftToRight)
    }
}

struct SummaryCard: View {
    @Environment(\.palette) private var p
    let section: MDSection

    var body: some View {
        let kind = section.kind
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon(kind)).font(.title3).foregroundStyle(kind == .takeaways ? p.gold : p.accent)
                Text(Markdown.inline(section.displayTitle)).font(.title3.weight(.semibold))
            }
            .accessibilityAddTraits(.isHeader)
            let numbers = bulletNumbers
            ForEach(Array(section.blocks.enumerated()), id: \.offset) { i, b in
                block(b, kind: kind, number: numbers[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 1, 2, 3… for the top-level bullets and numbered items, in order.
    private var bulletNumbers: [Int?] {
        var n = 0
        return section.blocks.map { b in
            switch b {
            case .bullet(_, 0), .numbered: n += 1; return n
            default: return nil
            }
        }
    }

    private func icon(_ kind: MDSection.Kind) -> String {
        switch kind {
        case .tldr: "doc.text.fill"
        case .keyPoints: "list.bullet.rectangle.fill"
        case .takeaways: "lightbulb.fill"
        case .other: "text.alignleft"
        }
    }

    @ViewBuilder private func block(_ b: MDBlock, kind: MDSection.Kind, number: Int?) -> some View {
        switch b {
        case let .paragraph(t):
            prose(t).lineSpacing(4)
        case let .bullet(t, indent) where indent > 0:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(p.secondary).frame(width: 5, height: 5)
                prose(t)
            }
            .padding(.leading, 34 + CGFloat(indent - 1) * 16)
        case let .bullet(t, _), let .numbered(_, t):
            HStack(alignment: .top, spacing: 12) {
                marker(kind, number: number)
                prose(t).padding(.top, 1)
            }
        case .heading, .rule:
            EmptyView()
        }
    }

    @ViewBuilder private func marker(_ kind: MDSection.Kind, number: Int?) -> some View {
        switch kind {
        case .keyPoints:
            Text("\(number ?? 0)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(p.accent))
        case .takeaways:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 19)).foregroundStyle(.white, p.accent).frame(width: 22, height: 22)
        case .tldr, .other:
            Circle().fill(p.accent).frame(width: 7, height: 7).frame(width: 22, height: 18)
        }
    }

    private func prose(_ t: String) -> some View {
        Text(Markdown.inline(t)).font(.body).foregroundStyle(p.text.opacity(0.9))
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
