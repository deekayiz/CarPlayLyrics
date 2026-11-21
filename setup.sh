#!/usr/bin/env bash
set -euo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Run this inside your cloned GitHub repo."; exit 1; }

mkdir -p Sources/App Sources/Shared Sources/Widget Config .github/workflows

############################################
# .gitignore
############################################
cat > .gitignore <<'__EOF__'
*.xcodeproj
build/
Payload/
*.ipa
.DS_Store
xcuserdata/
DerivedData/
__EOF__

############################################
# project.yml
############################################
cat > project.yml <<'__EOF__'
name: CarPlayLyrics
options:
  bundleIdPrefix: com.personal
  createIntermediateGroups: true
  deploymentTarget:
    iOS: "18.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"
    TARGETED_DEVICE_FAMILY: "1"
    ENABLE_USER_SCRIPT_SANDBOXING: "NO"
targets:
  CarPlayLyrics:
    type: application
    platform: iOS
    sources:
      - path: Sources/App
      - path: Sources/Shared
    info:
      path: Config/App-Info.plist
      properties:
        CFBundleDisplayName: CarPlay Lyrics
        CFBundleName: CarPlayLyrics
        NSAppleMusicUsageDescription: "CarPlay Lyrics reads the song currently playing in Apple Music so it can show synced lyrics."
        NSSupportsLiveActivities: true
        NSSupportsLiveActivitiesFrequentUpdates: true
        UIBackgroundModes:
          - audio
          - fetch
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
        UISupportedInterfaceOrientations~ipad:
          - UIInterfaceOrientationPortrait
          - UIInterfaceOrientationPortraitUpsideDown
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight
    entitlements:
      path: Config/App.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.personal.carplaylyrics
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.personal.carplaylyrics
        PRODUCT_NAME: CarPlayLyrics
    dependencies:
      - target: CarPlayLyricsWidget
      - sdk: MediaPlayer.framework
      - sdk: ActivityKit.framework
      - sdk: AVFoundation.framework
  CarPlayLyricsWidget:
    type: app-extension
    platform: iOS
    sources:
      - path: Sources/Widget
      - path: Sources/Shared
    info:
      path: Config/Widget-Info.plist
      properties:
        CFBundleDisplayName: CarPlay Lyrics Widget
        CFBundleName: CarPlayLyricsWidget
        NSSupportsLiveActivities: true
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    entitlements:
      path: Config/Widget.entitlements
      properties:
        com.apple.security.application-groups:
          - group.com.personal.carplaylyrics
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.personal.carplaylyrics.widget
        PRODUCT_NAME: CarPlayLyricsWidget
        SKIP_INSTALL: "YES"
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
      - sdk: ActivityKit.framework
__EOF__

############################################
# Shared attributes
############################################
cat > Sources/Shared/LyricsActivityAttributes.swift <<'__EOF__'
import ActivityKit
import Foundation

public struct LyricsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var songTitle: String
        public var artistName: String
        public var currentLine: String
        public var nextLine: String
        public var isPlaying: Bool

        public init(songTitle: String,
                    artistName: String,
                    currentLine: String,
                    nextLine: String,
                    isPlaying: Bool) {
            self.songTitle = songTitle
            self.artistName = artistName
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
        }
    }

    public var appName: String

    public init(appName: String = "CarPlay Lyrics") {
        self.appName = appName
    }
}
__EOF__

############################################
# LyricsService
############################################
cat > Sources/App/LyricsService.swift <<'__EOF__'
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
__EOF__

############################################
# MusicObserver
############################################
cat > Sources/App/MusicObserver.swift <<'__EOF__'
import ActivityKit
import AVFoundation
import Combine
import Foundation
import MediaPlayer
import UIKit

/// Plays an inaudible looping buffer (mixed with other audio) so iOS keeps the app
/// running in the background while Apple Music plays.
final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var configured = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !configured { configure() }
            try restart()
        } catch {
            print("KeepAlive start failed: \(error)")
        }
    }

    private func configure() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        let frames: AVAudioFrameCount = 44_100
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        if let channel = buf.floatChannelData {
            memset(channel[0], 0, Int(frames) * MemoryLayout<Float>.size)
        }
        buffer = buf
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.start()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            self?.start()
        })
        configured = true
    }

    private func restart() throws {
        guard let buffer else { return }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        if !engine.isRunning { try engine.start() }
        node.play()
    }
}

enum LyricsState {
    case idle, searching, loaded, missing
}

@MainActor
final class MusicObserver: ObservableObject {
    @Published private(set) var authorization: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var currentLine = "Play something in Apple Music"
    @Published private(set) var nextLine = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var lyricsState: LyricsState = .idle
    @Published private(set) var liveActivityActive = false
    @Published private(set) var message = ""
    @Published var autoManage = true

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let keepAlive = SilentAudioKeepAlive()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var lyrics: SyncedLyrics?
    private var lyricsTask: Task<Void, Never>?
    private var currentKey = ""
    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsActivityAttributes.ContentState?
    private var started = false
    private let syncOffset: TimeInterval = 0.25

    // MARK: Authorization

    func requestAuthorization() async {
        let status: MPMediaLibraryAuthorizationStatus = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        authorization = status
        if status == .authorized {
            message = ""
            start()
        } else {
            message = "Apple Music access is required. Enable it in Settings > CarPlay Lyrics."
        }
    }

    func appBecameActive() {
        authorization = MPMediaLibrary.authorizationStatus()
        adoptExistingActivity()
        guard authorization == .authorized else { return }
        start()
        trackChanged()
        playbackStateChanged()
        if autoManage, isPlaying { ensureLiveActivity() }
    }

    // MARK: Observation

    private func start() {
        guard !started, authorization == .authorized else { return }
        started = true
        keepAlive.start()
        player.beginGeneratingPlaybackNotifications()

        NotificationCenter.default
            .publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
            .sink { [weak self] _ in
                Task { @MainActor in self?.trackChanged() }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
            .sink { [weak self] _ in
                Task { @MainActor in self?.playbackStateChanged() }
            }
            .store(in: &cancellables)

        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        trackChanged()
        playbackStateChanged()
    }

    private func trackChanged() {
        guard let item = player.nowPlayingItem else {
            currentKey = ""
            title = ""; artist = ""; album = ""
            lyrics = nil
            lyricsState = .idle
            lyricsTask?.cancel()
            refreshDisplay(force: true)
            if autoManage { endActivity() }
            return
        }

        let newTitle = item.title ?? "Unknown Title"
        let newArtist = item.artist ?? ""
        let newAlbum = item.albumTitle ?? ""
        let duration = item.playbackDuration
        let key = "\(newTitle)|\(newArtist)|\(newAlbum)|\(Int(duration.rounded()))"
        guard key != currentKey else { return }

        currentKey = key
        title = newTitle
        artist = newArtist
        album = newAlbum
        lyrics = nil
        lyricsState = .searching
        refreshDisplay(force: true)

        lyricsTask?.cancel()
        lyricsTask = Task { [weak self] in
            let found = await LyricsService.shared.lyrics(title: newTitle,
                                                          artist: newArtist,
                                                          album: newAlbum,
                                                          duration: duration)
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            self.lyrics = found
            self.lyricsState = found == nil ? .missing : .loaded
            self.refreshDisplay(force: true)
        }

        if autoManage { ensureLiveActivity() }
    }

    private func playbackStateChanged() {
        let state = player.playbackState
        let playing = state == .playing
        if playing != isPlaying { isPlaying = playing }

        if state == .stopped, player.nowPlayingItem == nil, autoManage {
            endActivity()
        } else if playing, autoManage, activity == nil {
            ensureLiveActivity()
        }
        refreshDisplay(force: true)
    }

    private func tick() {
        let playing = player.playbackState == .playing
        if playing != isPlaying { isPlaying = playing }
        refreshDisplay(force: false)
    }

    private func displayLines() -> (String, String) {
        switch lyricsState {
        case .idle:
            return (title.isEmpty ? "Play something in Apple Music" : "", "")
        case .searching:
            return ("Finding lyrics…", "")
        case .missing:
            return ("No synced lyrics", "")
        case .loaded:
            let p = lyrics?.position(at: player.currentPlaybackTime + syncOffset) ?? ("", "")
            return (p.current.isEmpty ? "♪" : p.current, p.next)
        }
    }

    private func refreshDisplay(force: Bool) {
        let (cur, next) = displayLines()
        if cur != currentLine { currentLine = cur }
        if next != nextLine { nextLine = next }
        pushState(force: force)
    }

    // MARK: Live Activity

    private func currentState() -> LyricsActivityAttributes.ContentState {
        LyricsActivityAttributes.ContentState(songTitle: title.isEmpty ? "Apple Music" : title,
                                              artistName: artist,
                                              currentLine: currentLine,
                                              nextLine: nextLine,
                                              isPlaying: isPlaying)
    }

    func startLiveActivity() {
        autoManage = true
        ensureLiveActivity()
    }

    func stopLiveActivity() {
        autoManage = false
        endActivity()
    }

    private func adoptExistingActivity() {
        if activity == nil, let existing = Activity<LyricsActivityAttributes>.activities.first {
            activity = existing
            liveActivityActive = true
            watch(existing)
        }
    }

    private func ensureLiveActivity() {
        guard autoManage else { return }
        guard !title.isEmpty else {
            message = "Play a song in Apple Music first."
            return
        }
        if let existing = activity, existing.activityState == .active {
            pushState(force: true)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities are turned off. Enable them in Settings > CarPlay Lyrics."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            message = "Open the app once to start the Live Activity."
            return
        }
        let state = currentState()
        do {
            let new = try Activity<LyricsActivityAttributes>.request(
                attributes: LyricsActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activity = new
            lastState = state
            liveActivityActive = true
            message = ""
            watch(new)
        } catch {
            message = "Could not start Live Activity: \(error.localizedDescription)"
        }
    }

    private func pushState(force: Bool) {
        guard let activity, activity.activityState == .active else { return }
        let state = currentState()
        if !force, state == lastState { return }
        lastState = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func endActivity() {
        activity = nil
        lastState = nil
        liveActivityActive = false
        Task {
            for existing in Activity<LyricsActivityAttributes>.activities {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func watch(_ watched: Activity<LyricsActivityAttributes>) {
        Task { [weak self] in
            for await state in watched.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    guard let self else { return }
                    if self.activity?.id == watched.id {
                        // Ended by the user (swipe away), not by us.
                        self.activity = nil
                        self.lastState = nil
                        self.liveActivityActive = false
                        if state == .dismissed { self.autoManage = false }
                    }
                    return
                }
            }
        }
    }
}
__EOF__

############################################
# App entry + ContentView
############################################
cat > Sources/App/CarPlayLyricsApp.swift <<'__EOF__'
import SwiftUI

@main
struct CarPlayLyricsApp: App {
    @StateObject private var observer = MusicObserver()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(observer)
                .preferredColorScheme(.dark)
                .onAppear { observer.appBecameActive() }
        }
    }
}
__EOF__

cat > Sources/App/ContentView.swift <<'__EOF__'
import MediaPlayer
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var observer: MusicObserver
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    nowPlayingCard
                    lyricsCard
                    controls
                    statusFooter
                }
                .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("CarPlay Lyrics")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { observer.appBecameActive() }
        }
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 14) {
            Image(systemName: observer.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.pink)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(observer.title.isEmpty ? "Nothing playing" : observer.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(observer.artist.isEmpty ? "Start a song in Apple Music" : observer.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !observer.album.isEmpty {
                    Text(observer.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LIVE LYRICS PREVIEW")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(observer.currentLine)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: observer.currentLine)
            if !observer.nextLine.isEmpty {
                Text(observer.nextLine)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if observer.authorization != .authorized {
                if observer.authorization == .denied || observer.authorization == .restricted {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("Open Settings to Allow Apple Music", systemImage: "gearshape")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else {
                    Button {
                        Task { await observer.requestAuthorization() }
                    } label: {
                        Label("Allow Apple Music Access", systemImage: "music.note.list")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                }
            }

            HStack(spacing: 12) {
                Button {
                    observer.startLiveActivity()
                } label: {
                    Label("Start Live Activity", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(observer.liveActivityActive)

                Button {
                    observer.stopLiveActivity()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!observer.liveActivityActive)
            }
            .controlSize(.large)
        }
    }

    private var statusFooter: some View {
        VStack(spacing: 6) {
            Text(observer.liveActivityActive ? "Live Activity is running" : "Live Activity is not running")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(observer.liveActivityActive ? .green : .secondary)
            if !observer.message.isEmpty {
                Text(observer.message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Text("Keep this app open once per session to start the activity. It then keeps updating in the background and appears on the CarPlay dashboard (iOS 26+).")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}
__EOF__

############################################
# Widget extension
############################################
cat > Sources/Widget/CarPlayLyricsWidgetBundle.swift <<'__EOF__'
import SwiftUI
import WidgetKit

@main
struct CarPlayLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CarPlayLyricsLiveActivity()
    }
}
__EOF__

cat > Sources/Widget/CarPlayLyricsLiveActivity.swift <<'__EOF__'
import ActivityKit
import SwiftUI
import WidgetKit

struct LyricsActivityView: View {
    let state: LyricsActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        if family == .small {
            compact
        } else {
            full
        }
    }

    /// Small family: CarPlay dashboard / Smart Stack. Big, glanceable text only.
    private var compact: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.songTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(state.currentLine)
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(state.nextLine)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    /// Medium family: Lock Screen banner.
    private var full: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "music.note" : "pause.fill")
                    .foregroundStyle(.pink)
                Text(state.artistName.isEmpty ? state.songTitle : "\(state.songTitle) · \(state.artistName)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Text(state.currentLine)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            Text(state.nextLine)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

struct CarPlayLyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.currentLine)
                        .font(.system(size: 22, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.nextLine)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(context.state.songTitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "music.note").foregroundStyle(.pink)
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(.pink)
            }
        }
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(Color.white)
        .supplementalActivityFamilies([.small])
    }
}
__EOF__

############################################
# GitHub Actions workflow
############################################
cat > .github/workflows/build.yml <<'__EOF__'
name: Build IPA

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  build:
    runs-on: macos-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Build (unsigned)
        run: |
          set -o pipefail
          xcodebuild \
            -project CarPlayLyrics.xcodeproj \
            -scheme CarPlayLyrics \
            -configuration Release \
            -sdk iphoneos \
            -destination 'generic/platform=iOS' \
            -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGN_IDENTITY="" \
            AD_HOC_CODE_SIGNING_ALLOWED=YES \
            clean build

      - name: Ad-hoc sign with entitlements and package IPA
        run: |
          APP="build/Build/Products/Release-iphoneos/CarPlayLyrics.app"
          test -d "$APP"
          codesign --force --sign - --entitlements Config/Widget.entitlements \
            "$APP/PlugIns/CarPlayLyricsWidget.appex" || echo "widget ad-hoc sign skipped"
          codesign --force --sign - --entitlements Config/App.entitlements \
            "$APP" || echo "app ad-hoc sign skipped"
          rm -rf Payload CarPlayLyrics-unsigned.ipa
          mkdir Payload
          cp -R "$APP" Payload/
          zip -qry CarPlayLyrics-unsigned.ipa Payload
          ls -lh CarPlayLyrics-unsigned.ipa

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: CarPlayLyrics-unsigned-ipa
          path: CarPlayLyrics-unsigned.ipa

      - name: Publish GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: build-${{ github.run_number }}
          name: CarPlay Lyrics build ${{ github.run_number }}
          files: CarPlayLyrics-unsigned.ipa
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
__EOF__

############################################
# Commit and push
############################################
git add .
git commit -m "Initial CarPlay Lyrics App" || echo "Nothing new to commit."
git branch -M main
git push origin main

echo "Pushed. Watch the build in the Actions tab; the .ipa lands in Releases."