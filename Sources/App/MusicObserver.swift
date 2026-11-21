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
            return (p.0.isEmpty ? "♪" : p.0, p.1)
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
