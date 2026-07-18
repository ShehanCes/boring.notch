import XCTest
@testable import boringNotch

@MainActor
final class MusicManagerSourceRoutingTests: XCTestCase {
    private let manager = MusicManager.shared

    override func setUp() {
        super.setUp()
        manager.test_resetMediaSources()
    }

    override func tearDown() {
        manager.test_resetMediaSources()
        super.tearDown()
    }

    func testPlaceholderStateIsIgnored() {
        let placeholder = PlaybackState(bundleIdentifier: "com.apple.Music")
        manager.test_ingestPlaybackState(placeholder)

        XCTAssertTrue(manager.test_mediaSources.isEmpty)
        XCTAssertNil(manager.test_selectedSourceID)
    }

    func testMeaningfulStateIsStoredAndSelected() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.apple.Music",
                title: "Track A",
                artist: "Artist A",
                album: "Album A",
                isPlaying: true,
                timestamp: Date()
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertEqual(manager.test_mediaSources.first?.id, "com.apple.Music")
        XCTAssertEqual(manager.test_selectedSourceID, "com.apple.Music")
    }

    func testLatestEventAutoSelectsNewestSource() {
        let t1 = Date()
        let t2 = t1.addingTimeInterval(3)

        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.apple.Music",
                title: "Track A",
                artist: "Artist A",
                album: "Album A",
                isPlaying: true,
                timestamp: t1
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Track B",
                artist: "Artist B",
                album: "Album B",
                isPlaying: true,
                timestamp: t2
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 2)
        XCTAssertEqual(manager.test_mediaSources.first?.id, "com.spotify.client")
        XCTAssertEqual(manager.test_selectedSourceID, "com.spotify.client")
    }

    func testStalePausedSourceIsPruned() {
        let oldDate = Date().addingTimeInterval(-400)
        let newDate = Date()

        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Old Track",
                artist: "Old Artist",
                album: "Old Album",
                isPlaying: false,
                timestamp: oldDate
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.apple.Music",
                title: "Fresh Track",
                artist: "Fresh Artist",
                album: "Fresh Album",
                isPlaying: true,
                timestamp: newDate
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertEqual(manager.test_mediaSources.first?.id, "com.apple.Music")
    }

    func testStalePlayingSourceIsPrunedWhenHeartbeatTooOld() {
        let oldDate = Date().addingTimeInterval(-400)
        let newDate = Date()

        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Stale Playing",
                artist: "Artist",
                album: "Album",
                isPlaying: true,
                timestamp: oldDate
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.apple.Music",
                title: "Fresh Track",
                artist: "Fresh Artist",
                album: "Fresh Album",
                isPlaying: true,
                timestamp: newDate
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertEqual(manager.test_mediaSources.first?.id, "com.apple.Music")
    }

    func testSelectedSourceResolvesSpotifyControllerType() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.apple.Music",
                title: "Track A",
                artist: "Artist A",
                album: "Album A",
                isPlaying: true,
                timestamp: Date()
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Track B",
                artist: "Artist B",
                album: "Album B",
                isPlaying: true,
                timestamp: Date().addingTimeInterval(1)
            )
        )
        manager.selectMediaSource(at: 0)

        XCTAssertEqual(manager.test_resolvedControllerTypeForSelectedSource, .spotify)
    }

    func testSelectedSourceResolvesYouTubeControllerType() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: YouTubeMusicConfiguration.default.bundleIdentifier,
                title: "YT Track",
                artist: "YT Artist",
                album: "YT Album",
                isPlaying: true,
                timestamp: Date()
            )
        )

        XCTAssertEqual(manager.test_resolvedControllerTypeForSelectedSource, .youtubeMusic)
    }

    func testBrowserAudioAndVideoAreStoredAsSeparateSources() {
        let start = Date()
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Song One",
                artist: "Artist One",
                album: "Album One",
                isPlaying: true,
                timestamp: start
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Demo Clip - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: start.addingTimeInterval(1)
            )
        )

        let ids = Set(manager.test_mediaSources.map(\.id))
        XCTAssertEqual(ids.count, 2)
        XCTAssertTrue(ids.contains("com.google.Chrome::web-audio"))
        XCTAssertTrue(ids.contains("com.google.Chrome::web-video"))
    }

    func testBrowserAudioTrackChangesDoNotCreateNewSource() {
        let start = Date()
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Song One",
                artist: "Artist One",
                album: "Album One",
                isPlaying: true,
                timestamp: start
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Song Two",
                artist: "Artist Two",
                album: "Album Two",
                isPlaying: true,
                timestamp: start.addingTimeInterval(1)
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertEqual(manager.test_mediaSources.first?.id, "com.google.Chrome::web-audio")
        XCTAssertEqual(manager.test_mediaSources.first?.state.title, "Song Two")
    }

    private func makeState(
        bundleIdentifier: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        timestamp: Date
    ) -> PlaybackState {
        PlaybackState(
            bundleIdentifier: bundleIdentifier,
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            currentTime: 12,
            duration: 240,
            playbackRate: 1,
            isShuffled: false,
            repeatMode: .off,
            lastUpdated: timestamp,
            artwork: nil,
            volume: 0.5,
            isFavorite: false
        )
    }
}
