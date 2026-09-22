//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import MediaPlayer
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    /// Extra controller instances subscribed only for multi-source playback discovery (not for preference-based `activeController`).
    private var discoveryControllers: [any MediaControllerProtocol] = []
    private var discoveryCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?
    private var sourceCommandControllers: [String: any MediaControllerProtocol] = [:]
    private var youtubeTabBridge: any YouTubeTabPlayerBridging = YouTubeTabPlayerBridge()
    private var youtubeTabPollTask: Task<Void, Never>?
    private var lastYouTubeTabSnapshot: YouTubeTabSnapshot = .unmatched
    private var lastYouTubeTabSnapshotDate: Date?
    /// Consecutive failed YouTube tab matches before dropping a browser video source.
    private var consecutiveMissingYouTubeTabPolls = 0
    private let missingYouTubeTabDropThreshold = 8
    #if DEBUG
    private var testControllerOverrides: [MediaControllerType: any MediaControllerProtocol] = [:]
    #endif
    private let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.apple.Safari",
    ]

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var audioCaptureBundleIdentifiers: [String] = []
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var isLiveStream: Bool = false
    /// True when a live stream is caught up to the live edge (show LIVE, don't scrub).
    @Published var isAtLiveEdge: Bool = false
    @Published var timestampDate: Date = .init()
    private let liveEdgeTolerance: TimeInterval = 2
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var canFavoriteTrack: Bool = false
    
    // Lyrics are now managed by LyricsService
    var lyricsService: LyricsService { LyricsService.shared }
    var currentLyrics: String { lyricsService.currentLyrics }
    var isFetchingLyrics: Bool { lyricsService.isFetchingLyrics }
    var syncedLyrics: [(time: Double, text: String)] { lyricsService.syncedLyrics }
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil
    private var artworkUpdateGeneration: UInt64 = 0
    @Published private(set) var mediaSources: [MediaSourceItem] = []
    @Published private(set) var selectedSourceID: String?
    private var lastManualSourceSelectionDate: Date?
    private let manualSelectionHoldDuration: TimeInterval = 20
    /// Paused sources with no updates beyond this age are dropped from the carousel.
    private let stalePausedSourceTimeout: TimeInterval = 180
    /// "Playing" sources that stop receiving heartbeats can otherwise linger forever; drop after this age.
    private let stalePlayingSourceTimeout: TimeInterval = 300

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        youtubeTabPollTask?.cancel()
        youtubeTabPollTask = nil
        cancellables.removeAll()
        controllerCancellables.removeAll()
        teardownDiscoveryFeeds()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods

    private enum PlaybackFeedKind {
        case nowPlaying
        case dedicated
    }

    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        teardownDiscoveryFeeds()
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController = makeController(for: type)
        if newController == nil {
            return nil
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(
                        state,
                        feedKind: controller is NowPlayingController ? .nowPlaying : .dedicated
                    )
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func makeController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                return NowPlayingController()
            }
            return nil
        case .appleMusic:
            return AppleMusicController()
        case .spotify:
            return SpotifyController()
        case .youtubeMusic:
            return YouTubeMusicController()
        }
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        resetSourceCarouselState()
        sourceCommandControllers.removeAll()
        
        self.canFavoriteTrack = controller.supportsFavorite

        setupDiscoveryFeeds()

        // Get current state from active + discovery feeds
        forceUpdate()
    }

    /// Subscribes to every controller type except the active preference controller so multiple apps can populate `mediaSources` concurrently.
    private func setupDiscoveryFeeds() {
        teardownDiscoveryFeeds()
        guard let active = activeController else { return }

        for feedType in MediaControllerType.allCases {
            guard !controller(active, matches: feedType) else { continue }
            guard let feedController = makeController(for: feedType) else { continue }

            discoveryControllers.append(feedController)
            feedController.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.updateFromPlaybackState(
                        state,
                        feedKind: feedController is NowPlayingController ? .nowPlaying : .dedicated
                    )
                }
                .store(in: &discoveryCancellables)
        }
    }

    private func teardownDiscoveryFeeds() {
        discoveryCancellables.removeAll()
        discoveryControllers.removeAll()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(
        _ state: PlaybackState,
        feedKind: PlaybackFeedKind? = nil
    ) {
        if shouldSuppressDuplicateFeedUpdate(state, feedKind: feedKind) {
            pruneStaleSources(referenceDate: Date())
            return
        }

        upsertMediaSource(with: state)
        pruneStaleSources(referenceDate: state.lastUpdated == .distantPast ? Date() : state.lastUpdated)
        let displayState = resolvedDisplayState(fallback: state)
        guard !isPlaceholderPlaybackState(displayState) else { return }
        applyDisplayState(displayState)
        updateYouTubeTabPolling()
    }

    @MainActor
    private func applyDisplayState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if let artwork = state.artwork, artworkChanged || bundleChanged {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                artworkUpdateGeneration += 1
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                } else {
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: defaultImage)
                }
            }
            self.artworkData = state.artwork
            self.lastArtworkTitle = state.title
            self.lastArtworkArtist = state.artist
            self.lastArtworkAlbum = state.album
            self.lastArtworkBundleIdentifier = state.bundleIdentifier

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        let liveChanged = state.isLive != self.isLiveStream
        let atLiveEdge = isAtLiveEdge(state)
        let liveEdgeChanged = atLiveEdge != self.isAtLiveEdge
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            updateControlCapabilities(for: state.bundleIdentifier)
        }

        let captureBundleIDs = state.effectiveAudioCaptureBundleIdentifiers
        if captureBundleIDs != self.audioCaptureBundleIdentifiers {
            self.audioCaptureBundleIdentifiers = captureBundleIDs
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }

        if liveChanged {
            self.isLiveStream = state.isLive
        }
        if liveEdgeChanged {
            self.isAtLiveEdge = atLiveEdge
        }
        
        self.timestampDate = state.lastUpdated
        updateSystemNowPlayingInfo(with: state)
    }

    @MainActor
    private func updateSystemNowPlayingInfo(with state: PlaybackState) {
        // Claiming Now Playing for browser media makes MediaRemote transport commands
        // target this process (or whichever client last published) instead of the browser.
        if isBrowserBundleIdentifier(state.bundleIdentifier) {
            return
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? state.playbackRate : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: NSNumber(value: state.isLive)
        ]

        if !state.album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = state.album
        }

        if !state.isLive {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.currentTime
            if state.duration > 0 {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = state.duration
            }
        }

        if let artworkData = state.artwork, let image = NSImage(data: artworkData) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }

        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nowPlayingInfo
        nowPlayingCenter.playbackState = state.isPlaying ? .playing : .paused
    }

    var selectedSourceIndex: Int {
        guard let selectedSourceID else { return 0 }
        return mediaSources.firstIndex(where: { $0.id == selectedSourceID }) ?? 0
    }

    var selectedSource: MediaSourceItem? {
        guard let selectedSourceID else { return mediaSources.first }
        return mediaSources.first(where: { $0.id == selectedSourceID })
    }

    var shouldShowMediaSourceCarousel: Bool {
        mediaSources.count > 1
    }

    @MainActor
    func selectMediaSource(at index: Int, userInitiated: Bool = true) {
        guard mediaSources.indices.contains(index) else { return }
        selectedSourceID = mediaSources[index].id
        lastYouTubeTabSnapshot = .unmatched
        lastYouTubeTabSnapshotDate = nil
        consecutiveMissingYouTubeTabPolls = 0
        if userInitiated {
            lastManualSourceSelectionDate = Date()
        }
        applyDisplayState(mediaSources[index].state)
        updateYouTubeTabPolling()
    }

    @MainActor
    func selectNextMediaSource() {
        guard !mediaSources.isEmpty else { return }
        let nextIndex = (selectedSourceIndex + 1) % mediaSources.count
        selectMediaSource(at: nextIndex)
    }

    @MainActor
    func selectPreviousMediaSource() {
        guard !mediaSources.isEmpty else { return }
        let previousIndex = selectedSourceIndex == 0 ? mediaSources.count - 1 : selectedSourceIndex - 1
        selectMediaSource(at: previousIndex)
    }

    @MainActor
    private func resetSourceCarouselState() {
        mediaSources.removeAll()
        selectedSourceID = nil
        lastManualSourceSelectionDate = nil
        lastYouTubeTabSnapshot = .unmatched
        lastYouTubeTabSnapshotDate = nil
        consecutiveMissingYouTubeTabPolls = 0
        youtubeTabPollTask?.cancel()
        youtubeTabPollTask = nil
    }

    @MainActor
    private func upsertMediaSource(with state: PlaybackState) {
        var sourceID = sourceIdentifier(for: state)
        // Media Session uses titles; the tab bridge prefers video ids. Merge NP updates
        // into an existing same-browser web-video source when titles match.
        if sourceID.contains("::web-video::"),
           let existing = mediaSources.first(where: {
               $0.id.contains("::web-video")
                   && normalizeBundleIdentifier($0.state.bundleIdentifier)
                   == normalizeBundleIdentifier(state.bundleIdentifier)
                   && YouTubeTabMatching.titleMatchScore(
                       tabTitle: $0.state.title,
                       mediaTitle: state.title
                   ) > 0
           }) {
            sourceID = existing.id
        }
        if shouldIgnoreIncomingState(state, sourceIdentifier: sourceID) {
            return
        }

        let timestamp = state.lastUpdated == .distantPast ? Date() : state.lastUpdated
        var sourceState = state
        sourceState.isLive = isLivePlayback(sourceState)

        if let existingIndex = mediaSources.firstIndex(where: { $0.id == sourceID }) {
            if mediaSources[existingIndex].state.title != sourceState.title {
                lastYouTubeTabSnapshot = .unmatched
                lastYouTubeTabSnapshotDate = nil
            }
            sourceState = mergedIncomingState(sourceState, existingState: mediaSources[existingIndex].state)
            sourceState.isLive = isLivePlayback(sourceState)
            mediaSources[existingIndex].state = sourceState
            mediaSources[existingIndex].lastSeen = timestamp
        } else {
            mediaSources.append(MediaSourceItem(id: sourceID, state: sourceState, lastSeen: timestamp))
        }

        mediaSources.sort { $0.lastSeen > $1.lastSeen }

        if selectedSourceID == nil || !isManualSelectionActive {
            selectedSourceID = mediaSources.first?.id
        }
    }

    @MainActor
    private func pruneStaleSources(referenceDate: Date) {
        let now = referenceDate == .distantPast ? Date() : referenceDate
        mediaSources.removeAll { source in
            // If a dedicated app controller exists but the app quit, drop sooner than the
            // generic stale timeouts — but keep a short grace window so fresh Now Playing /
            // test updates are not wiped by an idle discovery controller.
            if shouldDropSourceBecauseControllerInactive(source),
               source.lastSeen < now.addingTimeInterval(-30) {
                return true
            }
            let cutoff = now.addingTimeInterval(-staleTimeout(for: source))
            return source.lastSeen < cutoff
        }

        pruneSourceCommandControllers(
            retainedBundleIdentifiers: Set(
                mediaSources
                    .map(\.state.bundleIdentifier)
                    .filter { !$0.isEmpty }
            )
        )

        if let selectedSourceID, !mediaSources.contains(where: { $0.id == selectedSourceID }) {
            self.selectedSourceID = mediaSources.first?.id
            lastManualSourceSelectionDate = nil
        }
    }

    private func staleTimeout(for source: MediaSourceItem) -> TimeInterval {
        // Browser Media Session heartbeats are sparse when another app is selected.
        // Keep carousel entries around long enough for multi-source switching.
        if source.state.isPlaying {
            return stalePlayingSourceTimeout
        }
        return stalePausedSourceTimeout
    }

    private func pruneSourceCommandControllers(retainedBundleIdentifiers: Set<String>) {
        for key in sourceCommandControllers.keys where !retainedBundleIdentifiers.contains(key) {
            sourceCommandControllers.removeValue(forKey: key)
        }
    }

    private func resolvedDisplayState(fallback: PlaybackState) -> PlaybackState {
        guard let selectedSource else {
            return fallback
        }
        return selectedSource.state
    }

    private var isManualSelectionActive: Bool {
        guard let lastManualSourceSelectionDate else { return false }
        return Date().timeIntervalSince(lastManualSourceSelectionDate) < manualSelectionHoldDuration
    }

    private func normalizedSourceIdentifier(from bundleIdentifier: String) -> String {
        if bundleIdentifier.isEmpty {
            return "unknown.media.source"
        }
        return bundleIdentifier
    }

    private func sourceIdentifier(for state: PlaybackState) -> String {
        let normalizedBundleID = normalizedSourceIdentifier(from: state.bundleIdentifier)
        guard normalizedBundleID != "unknown.media.source" else {
            return normalizedBundleID
        }
        guard isBrowserBundleIdentifier(normalizedBundleID) else {
            return normalizedBundleID
        }
        guard let browserBucket = browserMediaBucket(for: state) else {
            return normalizedBundleID
        }
        if browserBucket == "web-video" {
            let trackKey = YouTubeTabMatching.webVideoTrackKey(title: state.title)
            return "\(normalizedBundleID)::\(browserBucket)::\(trackKey)"
        }
        return "\(normalizedBundleID)::\(browserBucket)"
    }

    private func browserMediaBucket(for state: PlaybackState) -> String? {
        let lowercasedTitle = state.title.lowercased()
        let lowercasedAlbum = state.album.lowercased()
        let artistMeaningful = !state.artist.isEmpty && state.artist != "Me"
        let albumMeaningful = !state.album.isEmpty && state.album != "Self Love"

        if lowercasedTitle.contains("youtube music") || lowercasedAlbum.contains("youtube music") {
            return "web-audio"
        }

        if lowercasedTitle.contains(" - youtube") || lowercasedTitle.hasSuffix("youtube") {
            return "web-video"
        }

        if lowercasedTitle.contains("youtube"), !artistMeaningful, !albumMeaningful {
            return "web-video"
        }

        // YouTube watch / live pages usually set artist = channel and leave album empty,
        // without putting "YouTube" in the Media Session title.
        if artistMeaningful && !albumMeaningful {
            return "web-video"
        }

        if artistMeaningful || albumMeaningful {
            return "web-audio"
        }

        return nil
    }

    private func isBrowserBundleIdentifier(_ bundleID: String) -> Bool {
        let normalized = normalizeBundleIdentifier(bundleID)
        if browserBundleIdentifiers.contains(normalized) {
            return true
        }
        return browserBundleIdentifiers.contains { prefix in
            normalized.hasPrefix(prefix + ".")
        }
    }

    /// Live broadcast (as opposed to a finished VOD). Does not mean "caught up to live".
    private func isLivePlayback(_ state: PlaybackState) -> Bool {
        if lastYouTubeTabSnapshot.matched,
           isYouTubeWebVideoSource(selectedSource),
           selectedSource?.state.bundleIdentifier == state.bundleIdentifier {
            return lastYouTubeTabSnapshot.isLiveBroadcast
                || YouTubeTabMatching.titleIndicatesLiveBroadcast(state.title)
        }

        if YouTubeTabMatching.titleIndicatesLiveBroadcast(state.title)
            || YouTubeTabMatching.titleIndicatesLiveBroadcast(state.album) {
            return true
        }

        // A finite duration on a YouTube watch page is a VOD (or DVR window). Don't
        // trust Media Session isLive / canSeek — Chrome flags many VODs as live.
        if isBrowserBundleIdentifier(state.bundleIdentifier),
           browserMediaBucket(for: state) == "web-video",
           state.duration > liveEdgeTolerance {
            return false
        }

        if state.isLive {
            return true
        }

        if state.canSeek == false {
            return true
        }

        // YouTube live Media Session often reports 0:00 / 0:00 with no live flags.
        if state.duration <= 0,
           isBrowserBundleIdentifier(state.bundleIdentifier),
           browserMediaBucket(for: state) == "web-video" {
            return true
        }

        return false
    }

    /// Caught up to the live edge: YouTube tab snapshot wins when matched,
    /// including duration-0 Media Session lives that are actually behind on DVR.
    private func isAtLiveEdge(_ state: PlaybackState) -> Bool {
        if lastYouTubeTabSnapshot.matched,
           isYouTubeWebVideoSource(selectedSource),
           selectedSource?.state.bundleIdentifier == state.bundleIdentifier {
            return lastYouTubeTabSnapshot.isLiveBroadcast && lastYouTubeTabSnapshot.atLiveEdge
        }
        guard isLivePlayback(state) else { return false }
        if state.duration <= 0 {
            return true
        }
        return state.currentTime >= (state.duration - liveEdgeTolerance)
    }

    private func isYouTubeWebVideoSource(_ source: MediaSourceItem?) -> Bool {
        guard let source else { return false }
        guard source.id.contains("::web-video") else { return false }
        return YouTubeTabBrowserKind.from(bundleIdentifier: source.state.bundleIdentifier) != nil
    }

    @MainActor
    private func updateYouTubeTabPolling() {
        let hasYouTubeBrowserSource = mediaSources.contains { isYouTubeWebVideoSource($0) }
        guard hasYouTubeBrowserSource || isYouTubeWebVideoSource(selectedSource) else {
            youtubeTabPollTask?.cancel()
            youtubeTabPollTask = nil
            lastYouTubeTabSnapshot = .unmatched
            lastYouTubeTabSnapshotDate = nil
            consecutiveMissingYouTubeTabPolls = 0
            return
        }
        guard youtubeTabPollTask == nil else { return }
        youtubeTabPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAllYouTubeBrowserSources()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    private func refreshAllYouTubeBrowserSources() async {
        var browserBundles = Set(
            mediaSources
                .filter { isYouTubeWebVideoSource($0) }
                .map(\.state.bundleIdentifier)
                .filter { !$0.isEmpty }
        )
        if let selected = selectedSource, isYouTubeWebVideoSource(selected) {
            browserBundles.insert(selected.state.bundleIdentifier)
        }
        // Always scan Chrome/Brave/Safari when any browser media exists so a second
        // YouTube tab can appear even if Media Session only reports one session.
        for candidate in ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari"] {
            if mediaSources.contains(where: { $0.state.bundleIdentifier.hasPrefix(candidate) })
                || browserBundles.contains(where: { $0.hasPrefix(candidate) }) {
                browserBundles.insert(candidate)
            }
        }

        var discoveredAny = false
        for bundleID in browserBundles {
            let playings = await youtubeTabBridge.playingTabSnapshots(bundleIdentifier: bundleID)
            for playback in playings {
                discoveredAny = true
                upsertYouTubeTabPlayback(playback, bundleIdentifier: bundleID)
            }
        }

        guard let source = selectedSource, isYouTubeWebVideoSource(source) else {
            if !discoveredAny {
                consecutiveMissingYouTubeTabPolls = 0
            }
            return
        }

        let snapshot = await youtubeTabBridge.snapshot(
            bundleIdentifier: source.state.bundleIdentifier,
            title: source.state.title
        )
        storeYouTubeTabSnapshot(snapshot)
        if snapshot.tabMissing {
            consecutiveMissingYouTubeTabPolls += 1
            if consecutiveMissingYouTubeTabPolls >= missingYouTubeTabDropThreshold {
                handleMissingYouTubeWatchTab(sourceID: source.id)
            } else if let index = mediaSources.firstIndex(where: { $0.id == source.id }) {
                var state = mediaSources[index].state
                if state.isPlaying {
                    state.isPlaying = false
                    mediaSources[index].state = state
                    applyDisplayState(state)
                }
            }
            return
        }
        consecutiveMissingYouTubeTabPolls = 0
        applyYouTubeTabSnapshot(lastYouTubeTabSnapshot, toSourceID: source.id)
    }

    @MainActor
    private func upsertYouTubeTabPlayback(_ playback: YouTubeTabPlayback, bundleIdentifier: String) {
        let title = YouTubeTabMatching.normalizedTitle(playback.tab.title).isEmpty
            ? playback.tab.title
            : playback.tab.title
        let trackKey = YouTubeTabMatching.webVideoTrackKey(title: title, url: playback.tab.url)
        let sourceID = "\(normalizeBundleIdentifier(bundleIdentifier))::web-video::\(trackKey)"

        var state = PlaybackState(bundleIdentifier: bundleIdentifier)
        state.title = title
        state.artist = ""
        state.album = ""
        state.currentTime = playback.snapshot.currentTime
        state.duration = playback.snapshot.duration
        state.isPlaying = playback.snapshot.isPlaying ?? true
        state.isLive = playback.snapshot.isLiveBroadcast
            || YouTubeTabMatching.titleIndicatesLiveBroadcast(title)
        state.canSeek = playback.snapshot.canSeek
        state.lastUpdated = Date()
        state.isLive = isLivePlayback(state) || playback.snapshot.isLiveBroadcast

        if let existingIndex = mediaSources.firstIndex(where: { $0.id == sourceID }) {
            var merged = mergedIncomingState(state, existingState: mediaSources[existingIndex].state)
            merged.currentTime = playback.snapshot.currentTime
            if playback.snapshot.duration > 0 {
                merged.duration = playback.snapshot.duration
            }
            if let playing = playback.snapshot.isPlaying {
                merged.isPlaying = playing
            }
            merged.isLive = playback.snapshot.isLiveBroadcast
                || YouTubeTabMatching.titleIndicatesLiveBroadcast(merged.title)
            merged.canSeek = playback.snapshot.canSeek
            merged.lastUpdated = Date()
            mediaSources[existingIndex].state = merged
            mediaSources[existingIndex].lastSeen = merged.lastUpdated
            if selectedSourceID == sourceID {
                lastYouTubeTabSnapshot = playback.snapshot
                lastYouTubeTabSnapshotDate = Date()
                applyDisplayState(merged)
            }
        } else {
            mediaSources.append(MediaSourceItem(id: sourceID, state: state, lastSeen: state.lastUpdated))
            mediaSources.sort { $0.lastSeen > $1.lastSeen }
            if selectedSourceID == nil || !isManualSelectionActive {
                selectedSourceID = mediaSources.first?.id
            }
        }
    }

    @MainActor
    private func refreshYouTubeTabSnapshot() async {
        await refreshAllYouTubeBrowserSources()
    }

    private func storeYouTubeTabSnapshot(_ snapshot: YouTubeTabSnapshot) {
        if snapshot.tabMissing {
            // Keep the last good snapshot briefly so LIVE/edge state does not flicker.
            if lastYouTubeTabSnapshot.matched,
               let date = lastYouTubeTabSnapshotDate,
               Date().timeIntervalSince(date) < 8 {
                return
            }
            lastYouTubeTabSnapshot = .unmatched
            lastYouTubeTabSnapshotDate = nil
            return
        }
        if snapshot.matched {
            lastYouTubeTabSnapshot = snapshot
            lastYouTubeTabSnapshotDate = Date()
            consecutiveMissingYouTubeTabPolls = 0
            return
        }
        if lastYouTubeTabSnapshot.matched,
           let date = lastYouTubeTabSnapshotDate,
           Date().timeIntervalSince(date) < 8 {
            return
        }
        lastYouTubeTabSnapshot = snapshot
        lastYouTubeTabSnapshotDate = nil
    }

    @MainActor
    private func applyYouTubeTabSnapshot(_ snapshot: YouTubeTabSnapshot, toSourceID sourceID: String) {
        guard snapshot.matched else { return }
        guard let index = mediaSources.firstIndex(where: { $0.id == sourceID }) else { return }
        var state = mediaSources[index].state
        state.currentTime = snapshot.currentTime
        if snapshot.duration > 0 {
            state.duration = snapshot.duration
        }
        state.canSeek = snapshot.canSeek
        state.isLive = snapshot.isLiveBroadcast
            || YouTubeTabMatching.titleIndicatesLiveBroadcast(state.title)
        if let playing = snapshot.isPlaying {
            state.isPlaying = playing
        }
        state.lastUpdated = Date()
        mediaSources[index].state = state
        mediaSources[index].lastSeen = state.lastUpdated
        if selectedSourceID == sourceID {
            applyDisplayState(state)
        }
    }

    private func handleMissingYouTubeWatchTab(sourceID: String) {
        guard let index = mediaSources.firstIndex(where: { $0.id == sourceID }) else { return }
        var state = mediaSources[index].state
        state.isPlaying = false
        state.isLive = false
        mediaSources[index].state = state
        if selectedSourceID == sourceID {
            applyDisplayState(state)
        }
        clearMediaSource(id: sourceID)
    }

    private func commandTargetMatchesSelectedSource(
        _ controller: any MediaControllerProtocol,
        selectedBundleID: String
    ) -> Bool {
        let selected = normalizeBundleIdentifier(selectedBundleID)
        let target = normalizeBundleIdentifier(controller.commandTargetBundleIdentifier)
        guard !selected.isEmpty, !target.isEmpty else { return false }
        return selected == target
    }

    private func shouldIgnoreIncomingState(_ state: PlaybackState, sourceIdentifier: String) -> Bool {
        if isPlaceholderPlaybackState(state) {
            // Controllers reset to placeholders when inactive (e.g. YouTube Music quit).
            // Clear any existing carousel entry so dead sources don't linger as "playing".
            clearMediaSource(id: sourceIdentifier)
            return true
        }

        if sourceIdentifier == "unknown.media.source" {
            // Unknown source must contain at least some real media signal.
            return !hasMeaningfulMediaContent(state)
        }

        return false
    }

    private func mergedIncomingState(_ incomingState: PlaybackState, existingState: PlaybackState) -> PlaybackState {
        var merged = incomingState
        let incomingHadMeaningfulTitle =
            !incomingState.title.isEmpty && incomingState.title != "I'm Handsome"
        let sameTrack = !incomingHadMeaningfulTitle || incomingState.title == existingState.title

        // Keep prior artwork only for the same track. A Chrome live update with no
        // art must not inherit YouTube Music (or a previous video) cover art.
        if merged.artwork == nil, sameTrack {
            merged.artwork = existingState.artwork
        }
        if merged.title.isEmpty || merged.title == "I'm Handsome" {
            merged.title = existingState.title
        }
        if merged.artist.isEmpty || merged.artist == "Me" {
            merged.artist = existingState.artist
        }
        if merged.album.isEmpty || merged.album == "Self Love" {
            merged.album = existingState.album
        }
        // Only reuse duration for the same track — otherwise a previous VOD duration can
        // make a YouTube live (duration 0) look seekable.
        if merged.duration <= 0, sameTrack {
            merged.duration = existingState.duration
        }
        if merged.currentTime <= 0 && existingState.currentTime > 0 && !merged.isPlaying {
            merged.currentTime = existingState.currentTime
        }
        if merged.bundleIdentifier.isEmpty {
            merged.bundleIdentifier = existingState.bundleIdentifier
        }

        return merged
    }

    private func isPlaceholderPlaybackState(_ state: PlaybackState) -> Bool {
        state.title == "I'm Handsome" &&
            state.artist == "Me" &&
            state.album == "Self Love" &&
            state.duration == 0 &&
            state.currentTime == 0 &&
            state.artwork == nil &&
            !state.isPlaying
    }

    private func hasMeaningfulMediaContent(_ state: PlaybackState) -> Bool {
        if state.artwork != nil {
            return true
        }
        if state.duration > 0 || state.currentTime > 0 {
            return true
        }

        let titleMeaningful = !state.title.isEmpty && state.title != "I'm Handsome"
        let artistMeaningful = !state.artist.isEmpty && state.artist != "Me"
        let albumMeaningful = !state.album.isEmpty && state.album != "Self Love"

        return titleMeaningful || artistMeaningful || albumMeaningful || state.isPlaying
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = commandControllerForSelectedSource() else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            Task { @MainActor in
                lyricsService.clearLyrics()
            }
            return
        }
        
        Task { @MainActor in
            await lyricsService.fetchLyrics(bundleIdentifier: bundleIdentifier, title: title, artist: artist)
        }
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        artworkUpdateGeneration += 1
        let generation = artworkUpdateGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.artworkUpdateGeneration else { return }
                    self.usingAppIconForArtwork = false
                    self.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        if isLiveStream, isAtLiveEdge {
            guard songDuration > 0 else { return max(0, elapsedTime) }
            return songDuration
        }

        if isLiveStream {
            guard isPlaying else { return max(0, elapsedTime) }
            let timeDifference = date.timeIntervalSince(timestampDate)
            let estimated = elapsedTime + (timeDifference * playbackRate)
            if songDuration > 0 {
                return min(max(0, estimated), songDuration)
            }
            return max(0, estimated)
        }

        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await commandControllerForSelectedSource()?.togglePlay()
        }
    }

    func play() {
        Task {
            await commandControllerForSelectedSource()?.play()
        }
    }

    func pause() {
        Task {
            await commandControllerForSelectedSource()?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await commandControllerForSelectedSource()?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await commandControllerForSelectedSource()?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await commandControllerForSelectedSource()?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await commandControllerForSelectedSource()?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await commandControllerForSelectedSource()?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        if isYouTubeWebVideoSource(selectedSource) {
            guard !isShowingLiveEdge else { return }
            markYouTubePlaybackBehindLiveEdge(currentTime: position)
            let bundleID = selectedSource?.state.bundleIdentifier ?? ""
            let title = selectedSource?.state.title ?? songTitle
            let mediaTime = (lastYouTubeTabSnapshot.matched ? lastYouTubeTabSnapshot.seekOrigin : 0) + position
            Task {
                await youtubeTabBridge.seek(to: mediaTime, bundleIdentifier: bundleID, title: title)
            }
            return
        }
        if isShowingLiveEdge {
            return
        }
        Task {
            await commandControllerForSelectedSource()?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        if isShowingLiveEdge {
            return
        }
        let upperBound = songDuration > 0 ? songDuration : .greatestFiniteMagnitude
        let newPos = min(max(0, elapsedTime + seconds), upperBound)
        seek(to: newPos)
    }

    func goLive() {
        guard isYouTubeWebVideoSource(selectedSource) else { return }
        if lastYouTubeTabSnapshot.matched {
            lastYouTubeTabSnapshot.atLiveEdge = true
            lastYouTubeTabSnapshotDate = Date()
        }
        isAtLiveEdge = true
        let bundleID = selectedSource?.state.bundleIdentifier ?? ""
        let title = selectedSource?.state.title ?? songTitle
        Task {
            await youtubeTabBridge.goLive(bundleIdentifier: bundleID, title: title)
        }
    }

    private func markYouTubePlaybackBehindLiveEdge(currentTime: TimeInterval) {
        isAtLiveEdge = false
        if lastYouTubeTabSnapshot.matched {
            lastYouTubeTabSnapshot.atLiveEdge = false
            lastYouTubeTabSnapshot.currentTime = max(0, currentTime)
            lastYouTubeTabSnapshotDate = Date()
        }
    }

    private var isShowingLiveEdge: Bool {
        if let selected = selectedSource {
            return isAtLiveEdge(selected.state)
        }
        return isLiveStream && isAtLiveEdge
    }
    
    func setVolume(to level: Double) {
        if let controller = commandControllerForSelectedSource() {
            Task {
                await controller.setVolume(level)
            }
        }
    }

    private func updateControlCapabilities(for bundleIdentifier: String?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
            self.canFavoriteTrack = activeController?.supportsFavorite ?? false
            return
        }

        if let selectedType = mediaControllerType(for: bundleIdentifier) {
            if let selectedController = commandController(for: bundleIdentifier, type: selectedType) {
                self.volumeControlSupported = selectedController.supportsVolumeControl
                self.canFavoriteTrack = selectedController.supportsFavorite
                return
            }
        }

        // Browsers / unknown apps are controlled via Now Playing only when it targets them.
        if let nowPlaying = mediaRemoteControllerIfTargeting(bundleIdentifier) {
            self.volumeControlSupported = nowPlaying.supportsVolumeControl
            self.canFavoriteTrack = nowPlaying.supportsFavorite
            return
        }

        self.volumeControlSupported = false
        self.canFavoriteTrack = false
    }

    private func commandControllerForSelectedSource() -> (any MediaControllerProtocol)? {
        guard let selectedBundleID = selectedSource?.state.bundleIdentifier ?? bundleIdentifier else {
            return activeController
        }

        if let preferredType = mediaControllerType(for: selectedBundleID) {
            // Never fall back to the settings-preference controller — that routes
            // Spotify/Apple Music/browser seeks to whichever app the user prefers (e.g. YTM).
            return commandController(for: selectedBundleID, type: preferredType)
        }

        // Browsers and other unmapped apps must use Now Playing / MediaRemote,
        // and only when MediaRemote is currently targeting that same app.
        if let nowPlaying = mediaRemoteControllerIfTargeting(selectedBundleID) {
            return nowPlaying
        }
        if let cached = sourceCommandControllers[selectedBundleID],
           commandTargetMatchesSelectedSource(cached, selectedBundleID: selectedBundleID) {
            return cached
        }
        return nil
    }

    /// MediaRemote commands are global — only safe when the NP client matches the selected app.
    private func mediaRemoteControllerIfTargeting(_ bundleIdentifier: String) -> (any MediaControllerProtocol)? {
        guard let nowPlaying = existingController(matching: .nowPlaying) else {
            return nil
        }
        guard commandTargetMatchesSelectedSource(nowPlaying, selectedBundleID: bundleIdentifier) else {
            return nil
        }
        return nowPlaying
    }

    private func commandController(for bundleIdentifier: String, type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Explicit per-source overrides (including tests) win first.
        if let cachedController = sourceCommandControllers[bundleIdentifier] {
            return cachedController
        }
        // Prefer the already-subscribed active/discovery instance so commands and UI share state.
        if let existing = existingController(matching: type) {
            return existing
        }
        guard let newController = makeController(for: type) else {
            return nil
        }
        sourceCommandControllers[bundleIdentifier] = newController
        return newController
    }

    private func existingController(matching type: MediaControllerType) -> (any MediaControllerProtocol)? {
        #if DEBUG
        if let override = testControllerOverrides[type] {
            return override
        }
        #endif
        if controller(activeController, matches: type) {
            return activeController
        }
        return discoveryControllers.first { controller($0, matches: type) }
    }

    /// Now Playing and dedicated app controllers can both report the same bundle.
    /// Prefer the dedicated feed so metadata/position don't fight.
    private func shouldSuppressDuplicateFeedUpdate(
        _ state: PlaybackState,
        feedKind: PlaybackFeedKind?
    ) -> Bool {
        guard feedKind == .nowPlaying else { return false }
        guard let dedicatedType = mediaControllerType(for: state.bundleIdentifier) else {
            return false
        }
        guard let dedicated = existingController(matching: dedicatedType) else {
            return false
        }
        return dedicated.isActive()
    }

    @MainActor
    private func clearMediaSource(id: String) {
        guard let index = mediaSources.firstIndex(where: { $0.id == id }) else { return }
        guard hasMeaningfulMediaContent(mediaSources[index].state) else { return }

        let wasSelected = selectedSourceID == id
        mediaSources.remove(at: index)

        if wasSelected {
            selectedSourceID = mediaSources.first?.id
            lastManualSourceSelectionDate = nil
            if let selected = selectedSource, !isPlaceholderPlaybackState(selected.state) {
                applyDisplayState(selected.state)
            } else {
                isPlaying = false
                isLiveStream = false
                isAtLiveEdge = false
                updateIdleState(state: false)
            }
        }
    }

    private func shouldDropSourceBecauseControllerInactive(_ source: MediaSourceItem) -> Bool {
        guard let type = mediaControllerType(for: source.state.bundleIdentifier) else {
            return false
        }
        guard let dedicated = existingController(matching: type) else {
            return false
        }
        return !dedicated.isActive()
    }

    private func mediaControllerType(for bundleIdentifier: String) -> MediaControllerType? {
        switch bundleIdentifier {
        case "com.apple.Music":
            return .appleMusic
        case "com.spotify.client":
            return .spotify
        case YouTubeMusicConfiguration.default.bundleIdentifier:
            return .youtubeMusic
        default:
            return nil
        }
    }

    private func controller(_ controller: (any MediaControllerProtocol)?, matches type: MediaControllerType) -> Bool {
        guard let controller else { return false }
        switch type {
        case .nowPlaying:
            return controller is NowPlayingController
        case .appleMusic:
            return controller is AppleMusicController
        case .spotify:
            return controller is SpotifyController
        case .youtubeMusic:
            return controller is YouTubeMusicController
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        Task { @MainActor [weak self] in
            await self?.refreshAllPlaybackFeeds()
        }
    }

    @MainActor
    private func refreshAllPlaybackFeeds() async {
        if let active = activeController, active.isActive() {
            await refreshFeed(for: active)
        }
        for discovery in discoveryControllers where discovery.isActive() {
            await refreshFeed(for: discovery)
        }
    }

    private func refreshFeed(for controller: any MediaControllerProtocol) async {
        if let youtubeController = controller as? YouTubeMusicController {
            await youtubeController.pollPlaybackState()
        } else {
            await controller.updatePlaybackInfo()
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}

#if DEBUG
extension MusicManager {
    @MainActor
    func test_resetMediaSources() {
        resetSourceCarouselState()
        sourceCommandControllers.removeAll()
        testControllerOverrides.removeAll()
        youtubeTabPollTask?.cancel()
        youtubeTabPollTask = nil
        lastYouTubeTabSnapshot = .unmatched
        lastYouTubeTabSnapshotDate = nil
        consecutiveMissingYouTubeTabPolls = 0
        youtubeTabBridge = YouTubeTabPlayerBridge()
    }

    @MainActor
    func test_ingestPlaybackState(_ state: PlaybackState) {
        updateFromPlaybackState(state)
    }

    @MainActor
    func test_ingestPlaybackState(_ state: PlaybackState, as type: MediaControllerType) {
        let feedKind: PlaybackFeedKind = (type == .nowPlaying) ? .nowPlaying : .dedicated
        updateFromPlaybackState(state, feedKind: feedKind)
    }

    @MainActor
    var test_commandControllerKindForSelectedSource: MediaControllerType? {
        guard commandControllerForSelectedSource() != nil else { return nil }
        guard let selectedBundleID = selectedSource?.state.bundleIdentifier ?? bundleIdentifier else {
            return nil
        }
        if let preferredType = mediaControllerType(for: selectedBundleID) {
            return preferredType
        }
        // Unmapped sources (browsers) resolve to Now Playing only when NP targets them.
        return .nowPlaying
    }

    @MainActor
    func test_setControllerOverride(for type: MediaControllerType, controller: any MediaControllerProtocol) {
        testControllerOverrides[type] = controller
    }

    @MainActor
    var test_mediaSources: [MediaSourceItem] {
        mediaSources
    }

    @MainActor
    var test_selectedSourceID: String? {
        selectedSourceID
    }

    @MainActor
    var test_isLiveStream: Bool {
        isLiveStream
    }

    @MainActor
    var test_isAtLiveEdge: Bool {
        isAtLiveEdge
    }

    @MainActor
    func test_isLivePlayback(_ state: PlaybackState) -> Bool {
        isLivePlayback(state)
    }

    @MainActor
    var test_resolvedControllerTypeForSelectedSource: MediaControllerType? {
        guard let selectedBundleID = selectedSource?.state.bundleIdentifier ?? bundleIdentifier else {
            return nil
        }
        return mediaControllerType(for: selectedBundleID)
    }

    @MainActor
    func test_setCommandController(for bundleIdentifier: String, controller: any MediaControllerProtocol) {
        sourceCommandControllers[bundleIdentifier] = controller
    }

    @MainActor
    func test_selectSource(bundleIdentifier: String) {
        if let sourceIndex = mediaSources.firstIndex(where: { $0.id == bundleIdentifier }) {
            selectMediaSource(at: sourceIndex)
            return
        }
        // Allow selecting by browser bucket prefix (e.g. "com.google.Chrome::web-video").
        if let sourceIndex = mediaSources.firstIndex(where: { $0.id.hasPrefix(bundleIdentifier) }) {
            selectMediaSource(at: sourceIndex)
        }
    }

    @MainActor
    func test_commandPlay() async {
        await commandControllerForSelectedSource()?.play()
    }

    @MainActor
    func test_commandPause() async {
        await commandControllerForSelectedSource()?.pause()
    }

    @MainActor
    func test_commandNextTrack() async {
        await commandControllerForSelectedSource()?.nextTrack()
    }

    @MainActor
    func test_commandSeek(to position: TimeInterval) async {
        await commandControllerForSelectedSource()?.seek(to: position)
    }

    @MainActor
    func test_setYouTubeTabBridge(_ bridge: any YouTubeTabPlayerBridging) {
        youtubeTabBridge = bridge
    }

    @MainActor
    func test_applyYouTubeSnapshot(_ snapshot: YouTubeTabSnapshot) {
        storeYouTubeTabSnapshot(snapshot)
        guard let sourceID = selectedSourceID else { return }
        if snapshot.tabMissing {
            consecutiveMissingYouTubeTabPolls += 1
            if consecutiveMissingYouTubeTabPolls >= missingYouTubeTabDropThreshold {
                handleMissingYouTubeWatchTab(sourceID: sourceID)
            } else if let index = mediaSources.firstIndex(where: { $0.id == sourceID }) {
                var state = mediaSources[index].state
                if state.isPlaying {
                    state.isPlaying = false
                    mediaSources[index].state = state
                    applyDisplayState(state)
                }
            }
            return
        }
        consecutiveMissingYouTubeTabPolls = 0
        applyYouTubeTabSnapshot(lastYouTubeTabSnapshot, toSourceID: sourceID)
    }

    @MainActor
    func test_forceDropMissingYouTubeTab() {
        consecutiveMissingYouTubeTabPolls = missingYouTubeTabDropThreshold
        guard let sourceID = selectedSourceID else { return }
        handleMissingYouTubeWatchTab(sourceID: sourceID)
    }

    @MainActor
    func test_refreshYouTubeTabSnapshot() async {
        await refreshYouTubeTabSnapshot()
    }

    @MainActor
    func test_seek(to position: TimeInterval) {
        seek(to: position)
    }

    @MainActor
    func test_skip(seconds: TimeInterval) {
        skip(seconds: seconds)
    }

    @MainActor
    func test_goLive() {
        goLive()
    }
}
#endif
