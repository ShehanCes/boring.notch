import Combine
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
        XCTAssertTrue(ids.contains(where: { $0.hasPrefix("com.google.Chrome::web-video") }))
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

    func testBrowserYouTubeLiveWithoutDurationIsMarkedLive() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Night Market - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0
            )
        )

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome::web-video") ?? false)
        XCTAssertTrue(manager.test_mediaSources.first?.state.isLive ?? false)
        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertTrue(manager.test_isAtLiveEdge)
    }

    func testBrowserYouTubeVideoWithDvrDurationIsMarkedLive() {
        // Real Chrome Media Session for YouTube live often reports a positive DVR
        // window duration and omits live flags / "LIVE" in the title.
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Building in Public Q&A - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 7200,
                currentTime: 12
            )
        )

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome::web-video") ?? false)
        XCTAssertFalse(manager.test_mediaSources.first?.state.isLive ?? true)
        XCTAssertFalse(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = false
        snapshot.currentTime = 12
        snapshot.duration = 7200
        snapshot.canSeek = true
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
    }

    func testLiveDvrPlayheadAtEndIsAtLiveEdge() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Building in Public Q&A - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 7200,
                currentTime: 7199
            )
        )

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = true
        snapshot.currentTime = 7199
        snapshot.duration = 7200
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertTrue(manager.test_isAtLiveEdge)
    }

    func testChromePWABundleWithZeroDurationIsLiveAtEdge() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome.app.Google-YouTube",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome") ?? false)
        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertTrue(manager.test_isAtLiveEdge)
    }

    func testYouTubeSnapshotOverridesZeroDurationWhenBehind() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )

        XCTAssertTrue(manager.test_isAtLiveEdge)

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = false
        snapshot.currentTime = 100
        snapshot.duration = 800
        snapshot.canSeek = true
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
        XCTAssertEqual(manager.songDuration, 800, accuracy: 0.01)
        XCTAssertEqual(manager.elapsedTime, 100, accuracy: 0.01)
    }

    func testYouTubeSnapshotAtLiveEdgeKeepsLiveLabel() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = true
        snapshot.currentTime = 800
        snapshot.duration = 800
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertTrue(manager.test_isAtLiveEdge)
    }

    func testYouTubeSnapshotBehindWithZeroDurationClearsLiveLabel() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )
        XCTAssertTrue(manager.test_isAtLiveEdge)

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = false
        snapshot.currentTime = 40
        snapshot.duration = 0
        snapshot.canSeek = true
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
    }

    func testFailedYouTubeSnapshotDoesNotFlipBackToLiveEdge() async {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = true
        snapshot.atLiveEdge = false
        snapshot.currentTime = 120
        snapshot.duration = 800
        manager.test_applyYouTubeSnapshot(snapshot)
        XCTAssertFalse(manager.test_isAtLiveEdge)

        let bridge = MockStaleYouTubeTabBridge()
        manager.test_setYouTubeTabBridge(bridge)
        await manager.test_refreshYouTubeTabSnapshot()

        XCTAssertFalse(manager.test_isAtLiveEdge)
        XCTAssertEqual(manager.songDuration, 800, accuracy: 0.01)
    }

    func testBrowserYouTubeWatchPageWithoutYoutubeInTitleIsVideoAndLive() {
        // Chrome Media Session for youtube.com/watch often looks like:
        // title = video title, artist = channel, album empty, duration 0 — no "YouTube" text.
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0
            )
        )

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome::web-video") ?? false)
        XCTAssertTrue(manager.test_mediaSources.first?.state.isLive ?? false)
        XCTAssertTrue(manager.test_isLiveStream)
    }

    func testFinishedYouTubeVodIsNotShownAsLive() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Some Music Video - YouTube",
                artist: "A Channel",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 240,
                currentTime: 12
            )
        )

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome::web-video") ?? false)
        XCTAssertFalse(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
    }

    func testYouTubeSnapshotNotLiveClearsFalseLiveLabel() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "iPhone Features I'm Probably Not Using",
                artist: "brooke tierney",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 0,
                currentTime: 0
            )
        )
        XCTAssertTrue(manager.test_isLiveStream)

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = false
        snapshot.atLiveEdge = false
        snapshot.currentTime = 144
        snapshot.duration = 563
        snapshot.isPlaying = false
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertFalse(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.songDuration, 563, accuracy: 0.01)
    }

    func testEmojiLiveTitleStaysLiveEvenIfTabSnapshotSaysNotLive() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "🔴LIVE: HARDEST GUESS THE SONG CHALLENGE🔴",
                artist: "ohnepixel",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 7200,
                currentTime: 12
            )
        )

        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = true
        snapshot.isLiveBroadcast = false
        snapshot.atLiveEdge = true
        snapshot.currentTime = 12
        snapshot.duration = 7200
        manager.test_applyYouTubeSnapshot(snapshot)

        XCTAssertTrue(manager.test_isLiveStream)
    }

    func testMissingYouTubeTabDoesNotDropSourceImmediately() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "iPhone Features I'm Probably Not Using",
                artist: "brooke tierney",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 563,
                currentTime: 144
            )
        )
        XCTAssertEqual(manager.test_mediaSources.count, 1)

        manager.test_applyYouTubeSnapshot(.noMatchingTab)

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertFalse(manager.isPlaying)
    }

    func testRepeatedMissingYouTubeTabDropsBrowserVideoSource() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "iPhone Features I'm Probably Not Using",
                artist: "brooke tierney",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 563,
                currentTime: 144
            )
        )
        XCTAssertEqual(manager.test_mediaSources.count, 1)

        manager.test_forceDropMissingYouTubeTab()

        XCTAssertTrue(manager.test_mediaSources.isEmpty)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.test_isLiveStream)
    }

    func testTwoChromeYouTubeVideosBecomeSeparateCarouselSources() {
        let t1 = Date()
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Pro Lobbies? Can I Still Comp",
                artist: "Retals",
                album: "",
                isPlaying: true,
                timestamp: t1,
                duration: 2137,
                currentTime: 100
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "🔴LIVE: HARDEST GUESS THE SONG CHALLENGE🔴",
                artist: "ohnepixel",
                album: "",
                isPlaying: true,
                timestamp: t1.addingTimeInterval(1),
                duration: 0,
                currentTime: 12
            )
        )

        let chromeVideos = manager.test_mediaSources.filter { $0.id.hasPrefix("com.google.Chrome::web-video") }
        XCTAssertEqual(chromeVideos.count, 2)
        XCTAssertTrue(manager.shouldShowMediaSourceCarousel)
        XCTAssertNotEqual(chromeVideos[0].id, chromeVideos[1].id)
    }

    func testBrowserAndDedicatedSourcesStayTogetherInCarousel() {
        let t1 = Date()
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Spotify Track",
                artist: "Artist",
                album: "Album",
                isPlaying: true,
                timestamp: t1
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Pro Lobbies? Can I Still Comp",
                artist: "Retals",
                album: "",
                isPlaying: true,
                timestamp: t1.addingTimeInterval(1),
                duration: 2137,
                currentTime: 100
            )
        )

        XCTAssertEqual(manager.test_mediaSources.count, 2)
        XCTAssertTrue(manager.shouldShowMediaSourceCarousel)

        manager.test_selectSource(bundleIdentifier: "com.google.Chrome::web-video")
        manager.test_applyYouTubeSnapshot(.noMatchingTab)

        XCTAssertEqual(manager.test_mediaSources.count, 2)
        XCTAssertTrue(manager.shouldShowMediaSourceCarousel)
    }

    func testFiniteYoutubeVodIgnoresMediaSessionLiveFlags() {
        var state = makeState(
            bundleIdentifier: "com.google.Chrome",
            title: "Pro Lobbies? Can I Still Comp",
            artist: "Retals",
            album: "",
            isPlaying: true,
            timestamp: Date(),
            duration: 2137,
            currentTime: 391
        )
        state.isLive = true
        state.canSeek = false
        manager.test_ingestPlaybackState(state)

        XCTAssertTrue(manager.test_mediaSources.first?.id.hasPrefix("com.google.Chrome::web-video") ?? false)
        XCTAssertFalse(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)
    }

    func testBrowserYouTubeLiveTitleMarkerIsMarkedLive() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "LIVE • Festival Stream - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                duration: 3600
            )
        )

        XCTAssertTrue(manager.test_isLivePlayback(manager.test_mediaSources.first!.state))
        XCTAssertTrue(manager.test_isLiveStream)
    }

    func testBrowserVideoDurationDoesNotBleedAcrossTrackChanges() {
        let start = Date()
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Old VOD - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: start,
                duration: 600
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "New Live Stream - YouTube",
                artist: "",
                album: "",
                isPlaying: true,
                timestamp: start.addingTimeInterval(1),
                duration: 0
            )
        )

        let source = manager.test_mediaSources.first
        XCTAssertEqual(source?.state.title, "New Live Stream - YouTube")
        XCTAssertEqual(source?.state.duration ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(source?.state.isLive ?? false)
    }

    func testPlaceholderResetClearsExistingSource() {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Live Track",
                artist: "Artist",
                album: "Album",
                isPlaying: true,
                timestamp: Date()
            )
        )
        XCTAssertEqual(manager.test_mediaSources.count, 1)

        // Controllers emit placeholder defaults when they go inactive.
        manager.test_ingestPlaybackState(PlaybackState(bundleIdentifier: "com.spotify.client"))

        XCTAssertTrue(manager.test_mediaSources.isEmpty)
        XCTAssertNil(manager.test_selectedSourceID)
    }

    func testNowPlayingUpdateIsSuppressedWhenDedicatedFeedExists() {
        let mockSpotify = MockMediaController(bundleIdentifier: "com.spotify.client")
        manager.test_setControllerOverride(for: .spotify, controller: mockSpotify)

        let dedicated = makeState(
            bundleIdentifier: "com.spotify.client",
            title: "Dedicated Title",
            artist: "Dedicated Artist",
            album: "Dedicated Album",
            isPlaying: true,
            timestamp: Date()
        )
        manager.test_ingestPlaybackState(dedicated, as: .spotify)
        XCTAssertEqual(manager.test_mediaSources.first?.state.title, "Dedicated Title")

        // Even with a newer Now Playing event, dedicated feed wins while Spotify is active.
        var nowPlaying = dedicated
        nowPlaying.title = "Now Playing Title"
        nowPlaying.lastUpdated = Date().addingTimeInterval(5)
        manager.test_ingestPlaybackState(nowPlaying, as: .nowPlaying)

        XCTAssertEqual(manager.test_mediaSources.count, 1)
        XCTAssertEqual(manager.test_mediaSources.first?.state.title, "Dedicated Title")
    }

    func testSelectNextAndPreviousWrapAroundSources() {
        let t1 = Date()
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
                timestamp: t1.addingTimeInterval(1)
            )
        )

        // Newest source is selected first.
        XCTAssertEqual(manager.test_selectedSourceID, "com.spotify.client")
        XCTAssertEqual(manager.songTitle, "Track B")

        manager.selectNextMediaSource()
        XCTAssertEqual(manager.test_selectedSourceID, "com.apple.Music")
        XCTAssertEqual(manager.songTitle, "Track A")

        manager.selectNextMediaSource()
        XCTAssertEqual(manager.test_selectedSourceID, "com.spotify.client")
        XCTAssertEqual(manager.songTitle, "Track B")

        manager.selectPreviousMediaSource()
        XCTAssertEqual(manager.test_selectedSourceID, "com.apple.Music")
        XCTAssertEqual(manager.songTitle, "Track A")
    }

    func testManualSelectionSurvivesNewerIncomingUpdates() {
        let t1 = Date()
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
                timestamp: t1.addingTimeInterval(1)
            )
        )

        manager.selectNextMediaSource()
        XCTAssertEqual(manager.test_selectedSourceID, "com.apple.Music")
        XCTAssertEqual(manager.songTitle, "Track A")

        // A fresher update from Spotify must not steal the manual selection.
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.spotify.client",
                title: "Track B Updated",
                artist: "Artist B",
                album: "Album B",
                isPlaying: true,
                timestamp: t1.addingTimeInterval(3)
            )
        )

        XCTAssertEqual(manager.test_selectedSourceID, "com.apple.Music")
        XCTAssertEqual(manager.songTitle, "Track A")
    }

    func testNowPlayingDiffDoesNotCarryArtworkAcrossApps() {
        XCTAssertTrue(
            NowPlayingDiffReuse.allowsCarryover(
                diff: true,
                previousBundle: "com.github.th-ch.youtube-music",
                newBundle: "com.github.th-ch.youtube-music"
            )
        )
        XCTAssertFalse(
            NowPlayingDiffReuse.allowsCarryover(
                diff: true,
                previousBundle: "com.github.th-ch.youtube-music",
                newBundle: "com.google.Chrome"
            )
        )
        XCTAssertFalse(
            NowPlayingDiffReuse.allowsCarryover(
                diff: false,
                previousBundle: "com.github.th-ch.youtube-music",
                newBundle: "com.github.th-ch.youtube-music"
            )
        )
    }

    func testYouTubeMusicArtworkDoesNotStickOnBrowserVideo() {
        let art = Self.onePixelPNG
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.github.th-ch.youtube-music",
                title: "Song From YTM",
                artist: "YTM Artist",
                album: "YTM Album",
                isPlaying: true,
                timestamp: Date(),
                artwork: art
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "C 26 - Day 9 - Playoffs",
                artist: "Esports World Cup",
                album: "",
                isPlaying: true,
                timestamp: Date().addingTimeInterval(1),
                duration: 0,
                currentTime: 1
            )
        )

        let chrome = manager.test_mediaSources.first { $0.id.hasPrefix("com.google.Chrome::web-video") }
        XCTAssertNotNil(chrome)
        XCTAssertNil(chrome?.state.artwork)
        XCTAssertEqual(
            manager.test_mediaSources.first { $0.id == "com.github.th-ch.youtube-music" }?.state.artwork,
            art
        )
    }

    func testSameBrowserSourceDropsArtworkWhenTrackTitleChanges() {
        let art = Self.onePixelPNG
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "Old Video",
                artist: "Channel A",
                album: "",
                isPlaying: true,
                timestamp: Date(),
                artwork: art
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "com.google.Chrome",
                title: "New Live Stream",
                artist: "Channel B",
                album: "",
                isPlaying: true,
                timestamp: Date().addingTimeInterval(1),
                duration: 0,
                currentTime: 0
            )
        )

        XCTAssertNil(manager.test_mediaSources.first?.state.artwork)
    }

    private static let onePixelPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    private func makeState(
        bundleIdentifier: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        timestamp: Date,
        duration: Double = 240,
        currentTime: Double = 12,
        artwork: Data? = nil
    ) -> PlaybackState {
        PlaybackState(
            bundleIdentifier: bundleIdentifier,
            isPlaying: isPlaying,
            title: title,
            artist: artist,
            album: album,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: false,
            repeatMode: .off,
            lastUpdated: timestamp,
            artwork: artwork,
            volume: 0.5,
            isFavorite: false
        )
    }
}

@MainActor
private final class MockMediaController: MediaControllerProtocol {
    @Published private var playbackState: PlaybackState

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var commandTargetBundleIdentifier: String {
        playbackState.bundleIdentifier
    }

    var supportsVolumeControl: Bool = true
    var supportsFavorite: Bool = true

    init(bundleIdentifier: String) {
        self.playbackState = PlaybackState(bundleIdentifier: bundleIdentifier)
    }

    func setFavorite(_ favorite: Bool) async {}
    func play() async {}
    func pause() async {}
    func seek(to time: Double) async {}
    func nextTrack() async {}
    func previousTrack() async {}
    func togglePlay() async {}
    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {}
    func isActive() -> Bool { true }
    func updatePlaybackInfo() async {}
}

@MainActor
private final class MockStaleYouTubeTabBridge: YouTubeTabPlayerBridging {
    func snapshot(bundleIdentifier: String, title: String) async -> YouTubeTabSnapshot {
        .unmatched
    }

    func seek(to time: Double, bundleIdentifier: String, title: String) async {}
    func goLive(bundleIdentifier: String, title: String) async {}
    func playingTabSnapshots(bundleIdentifier: String) async -> [YouTubeTabPlayback] { [] }
}
