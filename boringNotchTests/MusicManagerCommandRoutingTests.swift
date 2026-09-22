import Combine
import XCTest
@testable import boringNotch

@MainActor
final class MusicManagerCommandRoutingTests: XCTestCase {
    private let manager = MusicManager.shared

    override func setUp() {
        super.setUp()
        manager.test_resetMediaSources()
    }

    override func tearDown() {
        manager.test_resetMediaSources()
        super.tearDown()
    }

    func testCommandsRouteToSelectedSourceController() async {
        let appleBundleID = "com.apple.Music"
        let spotifyBundleID = "com.spotify.client"

        manager.test_ingestPlaybackState(
            makeState(bundleIdentifier: appleBundleID, title: "Apple Track", timestamp: Date())
        )
        manager.test_ingestPlaybackState(
            makeState(bundleIdentifier: spotifyBundleID, title: "Spotify Track", timestamp: Date().addingTimeInterval(1))
        )

        let appleController = MockMediaController(bundleIdentifier: appleBundleID)
        let spotifyController = MockMediaController(bundleIdentifier: spotifyBundleID)
        manager.test_setCommandController(for: appleBundleID, controller: appleController)
        manager.test_setCommandController(for: spotifyBundleID, controller: spotifyController)

        manager.test_selectSource(bundleIdentifier: spotifyBundleID)
        await manager.test_commandPlay()
        await manager.test_commandSeek(to: 42)

        XCTAssertEqual(spotifyController.playCallCount, 1)
        XCTAssertEqual(spotifyController.seekCallCount, 1)
        XCTAssertEqual(spotifyController.lastSeekPosition, 42, accuracy: 0.001)
        XCTAssertEqual(appleController.playCallCount, 0)
        XCTAssertEqual(appleController.seekCallCount, 0)

        manager.test_selectSource(bundleIdentifier: appleBundleID)
        await manager.test_commandPause()
        await manager.test_commandNextTrack()

        XCTAssertEqual(appleController.pauseCallCount, 1)
        XCTAssertEqual(appleController.nextCallCount, 1)
        XCTAssertEqual(spotifyController.pauseCallCount, 0)
        XCTAssertEqual(spotifyController.nextCallCount, 0)
    }

    func testBrowserCommandsRouteViaNowPlayingOverride() async {
        let chromeBundleID = "com.google.Chrome"
        let spotifyBundleID = "com.spotify.client"

        manager.test_ingestPlaybackState(
            makeState(bundleIdentifier: spotifyBundleID, title: "Spotify Track", timestamp: Date())
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "Browser Song",
                timestamp: Date().addingTimeInterval(1),
                artist: "Browser Artist",
                album: "Browser Album"
            )
        )

        let spotifyController = MockMediaController(bundleIdentifier: spotifyBundleID)
        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        manager.test_setCommandController(for: spotifyBundleID, controller: spotifyController)
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)

        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-audio")
        XCTAssertEqual(manager.test_commandControllerKindForSelectedSource, .nowPlaying)

        await manager.test_commandPlay()
        XCTAssertEqual(nowPlayingController.playCallCount, 1)
        XCTAssertEqual(spotifyController.playCallCount, 0)
    }

    func testBrowserCommandsDoNotFireWhenNowPlayingTargetsAnotherApp() async {
        let chromeBundleID = "com.google.Chrome"
        let youtubeMusicBundleID = YouTubeMusicConfiguration.default.bundleIdentifier

        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: youtubeMusicBundleID,
                title: "YTM Track",
                timestamp: Date(),
                artist: "YTM Artist",
                album: "YTM Album"
            )
        )
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "Concert Stream - YouTube",
                timestamp: Date().addingTimeInterval(1),
                artist: "",
                album: ""
            )
        )

        let youtubeController = MockMediaController(bundleIdentifier: youtubeMusicBundleID)
        // Simulate MediaRemote currently focused on YouTube Music while the carousel
        // selection is still the Chrome YouTube live source.
        let nowPlayingController = MockMediaController(bundleIdentifier: youtubeMusicBundleID)
        manager.test_setCommandController(for: youtubeMusicBundleID, controller: youtubeController)
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)

        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")
        XCTAssertNil(manager.test_commandControllerKindForSelectedSource)

        await manager.test_commandPlay()
        await manager.test_commandSeek(to: 30)

        XCTAssertEqual(nowPlayingController.playCallCount, 0)
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
        XCTAssertEqual(youtubeController.playCallCount, 0)
        XCTAssertEqual(youtubeController.seekCallCount, 0)
    }

    func testBrowserCommandsDoNotFallBackToPreferredController() async {
        let chromeBundleID = "com.google.Chrome"
        let youtubeMusicBundleID = YouTubeMusicConfiguration.default.bundleIdentifier

        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "Demo Clip - YouTube",
                timestamp: Date(),
                artist: "",
                album: ""
            )
        )

        let youtubeController = MockMediaController(bundleIdentifier: youtubeMusicBundleID)
        manager.test_setCommandController(for: youtubeMusicBundleID, controller: youtubeController)
        // No Now Playing override → browser must not fall back to YTM.

        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")
        XCTAssertNil(manager.test_commandControllerKindForSelectedSource)

        await manager.test_commandPlay()
        await manager.test_commandSeek(to: 12)

        XCTAssertEqual(youtubeController.playCallCount, 0)
        XCTAssertEqual(youtubeController.seekCallCount, 0)
    }

    func testSeekIsNoOpAtLiveEdge() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "C 26 - Day 9 - Playoffs",
                timestamp: Date(),
                artist: "Esports World Cup",
                album: "",
                duration: 0
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertTrue(manager.test_isAtLiveEdge)

        manager.test_seek(to: 90)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
        XCTAssertEqual(youtubeBridge.seekCallCount, 0)
    }

    func testSeekIsAllowedWhenLiveStreamIsBehind() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "Building in Public Q&A - YouTube",
                timestamp: Date(),
                artist: "",
                album: "",
                duration: 7200,
                isLive: true
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)

        manager.test_seek(to: 90)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
        XCTAssertEqual(youtubeBridge.seekCallCount, 1)
        XCTAssertEqual(youtubeBridge.lastSeekPosition, 90, accuracy: 0.001)
    }

    func testSkipAtLiveEdgeIsNoOp() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "C 26 - Day 9 - Playoffs",
                timestamp: Date(),
                artist: "Esports World Cup",
                album: "",
                duration: 0
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        XCTAssertTrue(manager.test_isAtLiveEdge)

        manager.test_skip(seconds: -15)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(youtubeBridge.seekCallCount, 0)
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
    }

    func testSkipBehindDvrSeeksOnYouTubeTabNotNowPlaying() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "Building in Public Q&A - YouTube",
                timestamp: Date(),
                artist: "",
                album: "",
                duration: 7200,
                isLive: true
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        XCTAssertFalse(manager.test_isAtLiveEdge)

        manager.test_skip(seconds: 15)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
        XCTAssertEqual(youtubeBridge.seekCallCount, 1)
        XCTAssertEqual(youtubeBridge.lastSeekPosition, 27, accuracy: 0.001)
        XCTAssertEqual(youtubeBridge.goLiveCallCount, 0)
    }

    func testGoLiveBehindDvrUsesYouTubeTabBridge() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "C 26 - Day 9 - Playoffs",
                timestamp: Date(),
                artist: "Esports World Cup",
                album: "",
                duration: 7200,
                isLive: true
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        manager.test_goLive()
        await Self.waitForAsyncCommands()
        XCTAssertEqual(youtubeBridge.goLiveCallCount, 1)
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
        XCTAssertEqual(nowPlayingController.playCallCount, 0)
    }

    func testGoLiveDoesNotControlYouTubeMusic() async {
        let youtubeMusicBundleID = YouTubeMusicConfiguration.default.bundleIdentifier
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: youtubeMusicBundleID,
                title: "YTM Track",
                timestamp: Date(),
                artist: "YTM Artist",
                album: "YTM Album"
            )
        )

        let youtubeController = MockMediaController(bundleIdentifier: youtubeMusicBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setCommandController(for: youtubeMusicBundleID, controller: youtubeController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: youtubeMusicBundleID)

        manager.test_goLive()
        manager.test_seek(to: 40)
        await Self.waitForAsyncCommands()

        XCTAssertEqual(youtubeBridge.goLiveCallCount, 0)
        XCTAssertEqual(youtubeBridge.seekCallCount, 0)
        XCTAssertEqual(youtubeController.seekCallCount, 1)
        XCTAssertEqual(youtubeController.lastSeekPosition, 40, accuracy: 0.001)
    }

    func testDvrSnapshotBehindThenCaughtUpChangesSeekRouting() async {
        let chromeBundleID = "com.google.Chrome"
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: chromeBundleID,
                title: "C 26 - Day 9 - Playoffs",
                timestamp: Date(),
                artist: "Esports World Cup",
                album: "",
                duration: 0
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: chromeBundleID)
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "\(chromeBundleID)::web-video")

        XCTAssertTrue(manager.test_isAtLiveEdge)
        manager.test_seek(to: 10)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(youtubeBridge.seekCallCount, 0)

        var behind = YouTubeTabSnapshot()
        behind.matched = true
        behind.isLiveBroadcast = true
        behind.atLiveEdge = false
        behind.currentTime = 120
        behind.duration = 800
        behind.canSeek = true
        manager.test_applyYouTubeSnapshot(behind)

        XCTAssertTrue(manager.test_isLiveStream)
        XCTAssertFalse(manager.test_isAtLiveEdge)

        manager.test_seek(to: 90)
        manager.test_goLive()
        await Self.waitForAsyncCommands()
        XCTAssertEqual(youtubeBridge.seekCallCount, 1)
        XCTAssertEqual(youtubeBridge.lastSeekPosition, 90, accuracy: 0.001)
        XCTAssertEqual(youtubeBridge.goLiveCallCount, 1)
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)

        var atEdge = behind
        atEdge.atLiveEdge = true
        atEdge.currentTime = 798
        manager.test_applyYouTubeSnapshot(atEdge)
        XCTAssertTrue(manager.test_isAtLiveEdge)

        manager.test_seek(to: 200)
        manager.test_skip(seconds: -15)
        await Self.waitForAsyncCommands()
        XCTAssertEqual(youtubeBridge.seekCallCount, 1)
        XCTAssertEqual(nowPlayingController.seekCallCount, 0)
    }

    func testFirefoxLiveSeekDoesNotUseYouTubeTabBridge() async {
        manager.test_ingestPlaybackState(
            makeState(
                bundleIdentifier: "org.mozilla.firefox",
                title: "Concert Stream - YouTube",
                timestamp: Date(),
                artist: "",
                album: "",
                duration: 7200,
                isLive: true
            )
        )

        let nowPlayingController = MockMediaController(bundleIdentifier: "org.mozilla.firefox")
        let youtubeBridge = MockYouTubeTabBridge()
        manager.test_setControllerOverride(for: .nowPlaying, controller: nowPlayingController)
        manager.test_setYouTubeTabBridge(youtubeBridge)
        manager.test_selectSource(bundleIdentifier: "org.mozilla.firefox::web-video")

        XCTAssertFalse(manager.test_isAtLiveEdge)
        manager.test_seek(to: 90)
        manager.test_goLive()
        await Self.waitForAsyncCommands()

        XCTAssertEqual(youtubeBridge.seekCallCount, 0)
        XCTAssertEqual(youtubeBridge.goLiveCallCount, 0)
        XCTAssertEqual(nowPlayingController.seekCallCount, 1)
        XCTAssertEqual(nowPlayingController.lastSeekPosition, 90, accuracy: 0.001)
    }

    private static func waitForAsyncCommands() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func makeState(
        bundleIdentifier: String,
        title: String,
        timestamp: Date,
        artist: String = "Artist",
        album: String = "Album",
        duration: Double = 240,
        isLive: Bool = false
    ) -> PlaybackState {
        PlaybackState(
            bundleIdentifier: bundleIdentifier,
            isPlaying: true,
            title: title,
            artist: artist,
            album: album,
            currentTime: 12,
            duration: duration,
            playbackRate: 1,
            isShuffled: false,
            repeatMode: .off,
            lastUpdated: timestamp,
            artwork: nil,
            volume: 0.5,
            isLive: isLive,
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

    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var nextCallCount = 0
    private(set) var seekCallCount = 0
    private(set) var lastSeekPosition: Double = 0

    init(bundleIdentifier: String) {
        self.playbackState = PlaybackState(bundleIdentifier: bundleIdentifier)
    }

    func setFavorite(_ favorite: Bool) async {}
    func play() async { playCallCount += 1 }
    func pause() async { pauseCallCount += 1 }
    func seek(to time: Double) async {
        seekCallCount += 1
        lastSeekPosition = time
    }
    func nextTrack() async { nextCallCount += 1 }
    func previousTrack() async {}
    func togglePlay() async {}
    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {}
    func isActive() -> Bool { true }
    func updatePlaybackInfo() async {}
}

@MainActor
private final class MockYouTubeTabBridge: YouTubeTabPlayerBridging {
    var snapshotToReturn = YouTubeTabSnapshot.unmatched
    private(set) var seekCallCount = 0
    private(set) var lastSeekPosition: Double = 0
    private(set) var goLiveCallCount = 0

    func snapshot(bundleIdentifier: String, title: String) async -> YouTubeTabSnapshot {
        snapshotToReturn
    }

    func seek(to time: Double, bundleIdentifier: String, title: String) async {
        seekCallCount += 1
        lastSeekPosition = time
    }

    func goLive(bundleIdentifier: String, title: String) async {
        goLiveCallCount += 1
    }

    func playingTabSnapshots(bundleIdentifier: String) async -> [YouTubeTabPlayback] {
        []
    }
}
