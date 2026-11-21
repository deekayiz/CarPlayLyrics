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
