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

    private func makeState(bundleIdentifier: String, title: String, timestamp: Date) -> PlaybackState {
        PlaybackState(
            bundleIdentifier: bundleIdentifier,
            isPlaying: true,
            title: title,
            artist: "Artist",
            album: "Album",
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

@MainActor
private final class MockMediaController: MediaControllerProtocol {
    @Published private var playbackState: PlaybackState

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
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
