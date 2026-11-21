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
