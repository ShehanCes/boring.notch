import XCTest
@testable import boringNotch

final class YouTubeTabPlayerBridgeTests: XCTestCase {
    func testParseJSONSnapshot() {
        let json = """
        {"matched":true,"isLive":true,"atLiveEdge":false,"currentTime":120.5,"duration":800,"canSeek":true}
        """
        let snapshot = YouTubeTabSnapshot.parseJSON(json)
        XCTAssertEqual(snapshot?.matched, true)
        XCTAssertEqual(snapshot?.isLiveBroadcast, true)
        XCTAssertEqual(snapshot?.atLiveEdge, false)
        XCTAssertEqual(snapshot?.currentTime ?? 0, 120.5, accuracy: 0.01)
        XCTAssertEqual(snapshot?.duration ?? 0, 800, accuracy: 0.01)
        XCTAssertEqual(snapshot?.canSeek, true)
        XCTAssertEqual(snapshot?.seekOrigin ?? 0, 0, accuracy: 0.01)
    }

    func testParseSeekOrigin() {
        let json = """
        {"matched":true,"isLive":true,"atLiveEdge":false,"currentTime":40,"duration":600,"canSeek":true,"seekOrigin":86400}
        """
        let snapshot = YouTubeTabSnapshot.parseJSON(json)
        XCTAssertEqual(snapshot?.seekOrigin ?? 0, 86400, accuracy: 0.01)
        XCTAssertEqual(snapshot?.atLiveEdge, false)
    }

    func testParsePlayingFlag() {
        let json = """
        {"matched":true,"isLive":false,"atLiveEdge":false,"currentTime":10,"duration":100,"canSeek":true,"playing":false}
        """
        XCTAssertEqual(YouTubeTabSnapshot.parseJSON(json)?.isPlaying, false)
        XCTAssertEqual(YouTubeTabSnapshot.parseJSON(json)?.isLiveBroadcast, false)
    }

    func testParseDoesNotForceLiveEdgeWhenDurationMissing() {
        let json = """
        {"matched":true,"isLive":true,"atLiveEdge":false,"currentTime":40,"duration":0,"canSeek":true}
        """
        let snapshot = YouTubeTabSnapshot.parseJSON(json)
        XCTAssertEqual(snapshot?.isLiveBroadcast, true)
        XCTAssertEqual(snapshot?.atLiveEdge, false)
        XCTAssertEqual(snapshot?.currentTime ?? 0, 40, accuracy: 0.01)
    }

    func testSanitizedDurationDropsSentinels() {
        XCTAssertEqual(YouTubeTabSnapshot.sanitizedDuration(4_294_967_296), 0)
        XCTAssertEqual(YouTubeTabSnapshot.sanitizedDuration(.infinity), 0)
        XCTAssertEqual(YouTubeTabSnapshot.sanitizedDuration(-1), 0)
        XCTAssertEqual(YouTubeTabSnapshot.sanitizedDuration(640), 640, accuracy: 0.01)
    }

    func testTitleIndicatesLiveBroadcast() {
        XCTAssertTrue(YouTubeTabMatching.titleIndicatesLiveBroadcast("🔴LIVE: HARDEST GUESS THE SONG CHALLENGE🔴"))
        XCTAssertTrue(YouTubeTabMatching.titleIndicatesLiveBroadcast("LIVE • Festival Stream - YouTube"))
        XCTAssertTrue(YouTubeTabMatching.titleIndicatesLiveBroadcast("Night Market [LIVE]"))
        XCTAssertFalse(YouTubeTabMatching.titleIndicatesLiveBroadcast("iPhone Features I'm Probably Not Using"))
        XCTAssertFalse(YouTubeTabMatching.titleIndicatesLiveBroadcast("Pro Lobbies? Can I Still Comp"))
        XCTAssertFalse(YouTubeTabMatching.titleIndicatesLiveBroadcast("alive inside the machine"))
        XCTAssertFalse(YouTubeTabMatching.titleIndicatesLiveBroadcast("Some Music Video - YouTube"))
    }

    func testYouTubeWatchURLDetection() {
        XCTAssertTrue(YouTubeTabMatching.isYouTubeWatchURL("https://www.youtube.com/watch?v=abc"))
        XCTAssertTrue(YouTubeTabMatching.isYouTubeWatchURL("https://www.youtube.com/live/xyz"))
        XCTAssertTrue(YouTubeTabMatching.isYouTubeWatchURL("https://youtu.be/abc"))
        XCTAssertFalse(YouTubeTabMatching.isYouTubeWatchURL("https://www.youtube.com/feed/subscriptions"))
        XCTAssertFalse(YouTubeTabMatching.isYouTubeWatchURL("https://music.youtube.com/watch?v=abc"))
        XCTAssertFalse(YouTubeTabMatching.isYouTubeWatchURL("https://example.com/watch"))
    }

    func testParseJSONRejectsMissingPlayer() {
        let json = """
        {"matched":true,"foundPlayer":false,"isLive":false,"atLiveEdge":false,"currentTime":0,"duration":0,"canSeek":true}
        """
        XCTAssertEqual(YouTubeTabSnapshot.parseJSON(json)?.matched, false)
    }

    func testSingleYouTubeTabIsUsedWithoutTitleMatch() {
        let tabs = [
            YouTubeBrowserTab(
                windowIndex: 1,
                tabIndex: 1,
                url: "https://www.youtube.com/watch?v=ewc",
                title: "CS2 at EWC 26 - Day 9 - Playoffs - YouTube"
            )
        ]
        let best = YouTubeTabMatching.bestTab(in: tabs, mediaTitle: "Unrelated Media Session Title")
        XCTAssertEqual(best?.tabIndex, 1)
    }

    func testBestTabPrefersTitleMatchAndIgnoresUnrelatedFrontmost() {
        let tabs = [
            YouTubeBrowserTab(
                windowIndex: 1,
                tabIndex: 1,
                url: "https://www.youtube.com/watch?v=other",
                title: "Totally Different Video - YouTube"
            ),
            YouTubeBrowserTab(
                windowIndex: 2,
                tabIndex: 3,
                url: "https://www.youtube.com/watch?v=ewc",
                title: "CS2 at EWC 26 - Day 9 - Playoffs - YouTube"
            )
        ]
        let best = YouTubeTabMatching.bestTab(in: tabs, mediaTitle: "C 26 - Day 9 - Playoffs")
        XCTAssertEqual(best?.windowIndex, 2)
        XCTAssertEqual(best?.tabIndex, 3)
    }

    func testParseTabList() {
        let raw = "1\u{001F}2\u{001F}https://www.youtube.com/watch?v=a\u{001F}Hello\n"
        let tabs = YouTubeTabPlayerBridge.parseTabList(raw)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.windowIndex, 1)
        XCTAssertEqual(tabs.first?.tabIndex, 2)
        XCTAssertEqual(tabs.first?.title, "Hello")
    }

    func testBrowserKindMapping() {
        XCTAssertNotNil(YouTubeTabBrowserKind.from(bundleIdentifier: "com.google.Chrome"))
        XCTAssertNotNil(YouTubeTabBrowserKind.from(bundleIdentifier: "com.google.Chrome.app.Google-YouTube"))
        XCTAssertNotNil(YouTubeTabBrowserKind.from(bundleIdentifier: "com.brave.Browser"))
        XCTAssertNotNil(YouTubeTabBrowserKind.from(bundleIdentifier: "com.apple.Safari"))
        XCTAssertNil(YouTubeTabBrowserKind.from(bundleIdentifier: "org.mozilla.firefox"))
        XCTAssertNil(YouTubeTabBrowserKind.from(bundleIdentifier: "com.github.th-ch.youtube-music"))
    }

    func testWebVideoTrackKeyPrefersVideoID() {
        XCTAssertEqual(
            YouTubeTabMatching.webVideoTrackKey(
                title: "Anything",
                url: "https://www.youtube.com/watch?v=smA4njygJMk"
            ),
            "smA4njygJMk"
        )
        let slug = YouTubeTabMatching.webVideoTrackKey(title: "Pro Lobbies? Can I Still Comp")
        XCTAssertFalse(slug.isEmpty)
        XCTAssertNotEqual(slug, "smA4njygJMk")
    }
}
