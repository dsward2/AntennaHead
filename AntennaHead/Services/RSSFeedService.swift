import Foundation

/// One headline read off an RSS 2.0 `<item>` or Atom `<entry>`, for the
/// "Speak RSS Headlines" page. `summary` has already had HTML tags/entities
/// stripped so it reads cleanly aloud; `publishedAt` is best-effort (`nil`
/// when the feed's date couldn't be parsed) and is only used to pick the
/// newest items.
struct RSSItem {
    let title: String
    let summary: String
    let publishedAt: Date?
}

enum RSSFeedServiceError: Error {
    case badResponse
}

/// Fetches and parses RSS/Atom feeds and OPML subscription lists — pure
/// networking/parsing, no pipeline coupling (mirrors `FCCSearch.swift`'s
/// separation of concerns: fetch-and-parse a remote resource, nothing more).
/// The app is already sandboxed with `com.apple.security.network.client`,
/// and `FCCSearch` already fetches/parses an external HTTPS URL under that
/// sandbox today, so this needs no new entitlement.
enum RSSFeedService {
    /// Fetches `feedURL` and returns its items, newest first when publish
    /// dates are available (feed order otherwise).
    static func fetchItems(feedURL: String) async throws -> [RSSItem] {
        guard let url = URL(string: feedURL) else { throw RSSFeedServiceError.badResponse }
        // A bounded timeout, same idea as `proxyToLiveAudioServer`'s: a slow
        // or unreachable feed shouldn't be able to leave a Listen request
        // hanging indefinitely — this route is async, so a slow feed also
        // means a longer window where a stale response could otherwise land
        // well after the user has moved on.
        let request = URLRequest(url: url, timeoutInterval: 15)
        let (data, _) = try await URLSession.shared.data(for: request)
        let items = FeedXMLParser.parse(data)
        return items.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// Flattens an OPML document's `<outline type="rss" text="…" xmlUrl="…">`
    /// elements (including nested folders) into a flat `(name, url)` list.
    static func parseOPML(_ data: Data) -> [(name: String, url: String)] {
        OPMLParser.parse(data)
    }
}

/// RSS-2.0-or-Atom item parser. Both formats are simple enough to handle
/// with one `XMLParserDelegate`: an `item`/`entry` element starts a new
/// pending item, and a handful of child element names (which don't overlap
/// between the two formats, `description`/`pubDate` vs `summary`/`updated`,
/// aside from the shared `title`) are collected as its text.
private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private var items: [RSSItem] = []
    private var currentElement = ""
    private var title = ""
    private var summary = ""
    private var dateText = ""
    private var insideItem = false
    private static let dateFormatters: [DateFormatter] = {
        // RFC 822 (RSS `pubDate`) and ISO 8601 (Atom `updated`), with and
        // without seconds — feeds are inconsistent about this.
        let patterns = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = pattern
            return f
        }
    }()

    static func parse(_ data: Data) -> [RSSItem] {
        let delegate = FeedXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "item" || elementName == "entry" {
            insideItem = true
            title = ""
            summary = ""
            dateText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title": title += string
        case "description", "summary", "content": summary += string
        case "pubDate", "updated", "published": dateText += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "item" || elementName == "entry" {
            insideItem = false
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).strippingHTML()
            guard !cleanTitle.isEmpty else { return }
            items.append(RSSItem(title: cleanTitle,
                                 summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).strippingHTML(),
                                 publishedAt: Self.parseDate(dateText)))
        }
    }
}

/// OPML `<outline>` parser — collects every `type="rss"` outline's `text`
/// (falling back to `title`) and `xmlUrl`, regardless of nesting depth, so a
/// reader's folder structure is flattened rather than rejected.
private final class OPMLParser: NSObject, XMLParserDelegate {
    private var feeds: [(name: String, url: String)] = []

    static func parse(_ data: Data) -> [(name: String, url: String)] {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.feeds
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "outline", let url = attributeDict["xmlUrl"], !url.isEmpty else { return }
        let name = attributeDict["text"] ?? attributeDict["title"] ?? url
        feeds.append((name: name, url: url))
    }
}

private extension String {
    /// Strips `<…>` tags and decodes the handful of entities feed
    /// descriptions actually use, so summaries read as plain spoken text
    /// rather than literal markup. Not a full HTML parser — feed
    /// descriptions are simple enough that this is sufficient.
    func strippingHTML() -> String {
        var s = self.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let namedEntities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–",
            "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}"
        ]
        for (entity, replacement) in namedEntities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#39; and &#x27; forms.
        while let range = s.range(of: "&#[0-9]+;", options: .regularExpression) {
            let digits = s[range].dropFirst(2).dropLast()
            guard let scalarValue = UInt32(digits), let scalar = Unicode.Scalar(scalarValue) else {
                s.removeSubrange(range); continue
            }
            s.replaceSubrange(range, with: String(Character(scalar)))
        }
        while let range = s.range(of: "&#x[0-9A-Fa-f]+;", options: .regularExpression) {
            let digits = s[range].dropFirst(3).dropLast()
            guard let scalarValue = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(scalarValue) else {
                s.removeSubrange(range); continue
            }
            s.replaceSubrange(range, with: String(Character(scalar)))
        }
        return s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
