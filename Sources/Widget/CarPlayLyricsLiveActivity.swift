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
