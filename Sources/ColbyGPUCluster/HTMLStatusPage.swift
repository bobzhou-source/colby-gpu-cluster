import Foundation

/// Decodes the HTML node-status table Colby HPC publishes at
/// `https://hpc.colby.edu/public/gpu.html` into the app's snapshot model.
///
/// The page is a single `<table>` with one row per node:
/// `Node ID | State | Total Resources | Allocated GPUs`, where both resource
/// cells read `TYPE:COUNT` (comma-separated when a node has several types),
/// plus a `Last Updated: yyyy-MM-dd HH:mm:ss TZ` stamp in Colby's local time.
/// It publishes no jobs, queue, or reservations, so those stay empty.
enum HTMLStatusPageMapper {
    /// True when the body looks like an HTML page rather than a JSON document.
    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let first = data.first(where: { !Character(UnicodeScalar($0)).isWhitespace }) else {
            return false
        }
        return first == UInt8(ascii: "<")
    }

    static func snapshot(from data: Data, now: Date = Date()) throws -> ClusterSnapshot {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw StatusFeedError.unreadableHTML
        }
        guard let body = firstMatch(#"<tbody[^>]*>(.*?)</tbody>"#, in: html) else {
            throw StatusFeedError.unreadableHTML
        }

        var nodes: [ClusterNode] = []
        for row in allMatches(#"<tr[^>]*>(.*?)</tr>"#, in: body) {
            let cells = allMatches(#"<td[^>]*>(.*?)</td>"#, in: row).map(plainText)
            guard cells.count >= 4, !cells[0].isEmpty,
                  let node = node(name: cells[0], state: cells[1], total: cells[2], allocated: cells[3])
            else { continue }
            nodes.append(node)
        }

        nodes.sort {
            if $0.isIdle != $1.isIdle { return $0.isIdle }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let generatedAt = lastUpdated(in: html) ?? now
        return ClusterSnapshot(generatedAt: generatedAt, nodes: nodes, pending: [], queuePublished: false)
    }

    private static func node(name: String, state rawState: String, total: String, allocated: String) -> ClusterNode? {
        let totals = resources(total)
        guard !totals.isEmpty else { return nil }
        let used = Dictionary(resources(allocated).map { ($0.type.lowercased(), $0.count) }, uniquingKeysWith: +)

        let gres = totals.map { entry in
            let hardware = GPUHardwareProfile.lookup(entry.type)
            let count = max(0, entry.count)
            return GPUResource(
                gpuType: entry.type,
                profile: hardware.profile,
                vramGB: hardware.vramGB,
                count: count,
                used: min(count, max(0, used[entry.type.lowercased()] ?? 0))
            )
        }
        let state = rawState.lowercased()
        let (status, label) = StatusFeedMapper.statusAndLabel(forFeedState: state, reason: nil)
        return ClusterNode(name: name, gres: gres, state: state, status: status, stateLabel: label, jobs: [])
    }

    /// `A100:2` or `A100:2,L4:1` → `[(A100, 2), (L4, 1)]`. Entries without a
    /// numeric count are dropped rather than guessed.
    private static func resources(_ cell: String) -> [(type: String, count: Int)] {
        cell.split(separator: ",").compactMap { part in
            let fields = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, !fields[0].isEmpty, let count = Int(fields[fields.count - 1]) else {
                return nil
            }
            return (fields[0..<(fields.count - 1)].joined(separator: ":"), count)
        }
    }

    /// The stamp is Colby wall-clock time with a zone abbreviation (EDT/EST).
    /// The abbreviation is dropped and the time read in America/New_York, which
    /// resolves daylight saving the same way the publisher did.
    private static func lastUpdated(in html: String) -> Date? {
        guard let stamp = firstMatch(#"Last Updated:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"#, in: html) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: stamp)
    }

    private static func plainText(_ fragment: String) -> String {
        let stripped = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }
}
