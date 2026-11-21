import Foundation

struct LyricLine: Hashable {
    let time: TimeInterval
    let text: String
}

struct SyncedLyrics {
    let lines: [LyricLine]

    /// Returns the line that is active at `time` and the next non-empty upcoming line.
    func position(at time: TimeInterval) -> (current: String, next: String) {
        guard !lines.isEmpty else { return ("", "") }
        var lo = 0
        var hi = lines.count - 1
        var idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time {
                idx = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        if idx < 0 {
            let first = lines.first(where: { !$0.text.isEmpty })?.text ?? ""
            return ("", first)
        }
        var next = ""
        var j = idx + 1
        while j < lines.count {
            if !lines[j].text.isEmpty {
                next = lines[j].text
                break
            }
            j += 1
        }
        return (lines[idx].text, next)
    }

    /// Parses `[mm:ss.xx] text` lines. Supports multiple timestamps per line.
    static func parse(_ lrc: String) -> [LyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#) else {
            return []
        }
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var fraction = 0.0
                if m.range(at: 3).location != NSNotFound {
                    fraction = Double("0." + ns.substring(with: m.range(at: 3))) ?? 0
                }
                out.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

private struct LRCLibTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
    let plainLyrics: String?
}

actor LyricsService {
    static let shared = LyricsService()

    private let session: URLSession
    private var cache: [String: SyncedLyrics] = [:]
    private var misses: Set<String> = []

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async -> SyncedLyrics? {
        let key = "\(title)|\(artist)|\(album)|\(Int(duration.rounded()))".lowercased()
        if let hit = cache[key] { return hit }
        if misses.contains(key) { return nil }

        var result: SyncedLyrics?
        let seconds = Int(duration.rounded())

        // 1) Exact match endpoint.
        if !album.isEmpty, seconds > 0 {
            let items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(seconds))
            ]
            if let track = await request("get", items, as: LRCLibTrack.self) {
                result = Self.synced(from: track)
            }
        }

        // 2) Search fallback.
        if result == nil {
            let items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist)
            ]
            if let list = await request("search", items, as: [LRCLibTrack].self) {
                result = Self.bestMatch(in: list, duration: duration)
            }
        }

        // 3) Free-text search as the last resort.
        if result == nil {
            let items = [URLQueryItem(name: "q", value: "\(title) \(artist)")]
            if let list = await request("search", items, as: [LRCLibTrack].self) {
                result = Self.bestMatch(in: list, duration: duration)
            }
        }

        if let result {
            cache[key] = result
        } else {
            misses.insert(key)
        }
        return result
    }

    private func request<T: Decodable>(_ path: String, _ items: [URLQueryItem], as type: T.Type) async -> T? {
        guard var components = URLComponents(string: "https://lrclib.net/api/\(path)") else { return nil }
        components.queryItems = items
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("CarPlayLyrics/1.0 (personal sideloaded app)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private static func synced(from track: LRCLibTrack) -> SyncedLyrics? {
        if track.instrumental == true { return nil }
        guard let lrc = track.syncedLyrics, !lrc.isEmpty else { return nil }
        let lines = SyncedLyrics.parse(lrc)
        return lines.isEmpty ? nil : SyncedLyrics(lines: lines)
    }

    private static func bestMatch(in list: [LRCLibTrack], duration: TimeInterval) -> SyncedLyrics? {
        let candidates = list.filter { ($0.syncedLyrics ?? "").isEmpty == false && $0.instrumental != true }
        guard !candidates.isEmpty else { return nil }
        let chosen: LRCLibTrack?
        if duration > 0 {
            chosen = candidates
                .filter { abs(($0.duration ?? 0) - duration) <= 10 }
                .min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        } else {
            chosen = candidates.first
        }
        guard let chosen else { return nil }
        return synced(from: chosen)
    }
}
