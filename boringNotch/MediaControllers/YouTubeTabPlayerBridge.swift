//
//  YouTubeTabPlayerBridge.swift
//  boringNotch
//

import Foundation

struct YouTubeTabSnapshot: Equatable {
    var matched: Bool = false
    var isLiveBroadcast: Bool = false
    var atLiveEdge: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var canSeek: Bool = true
    /// Media-timeline origin so UI times (0...duration) map to `seekTo(seekOrigin + t)`.
    var seekOrigin: Double = 0
    var isPlaying: Bool? = nil
    /// True when Chrome/Safari/Brave has no matching youtube.com watch/live tab.
    var tabMissing: Bool = false

    static let unmatched = YouTubeTabSnapshot()
    static var noMatchingTab: YouTubeTabSnapshot {
        var snapshot = YouTubeTabSnapshot()
        snapshot.tabMissing = true
        return snapshot
    }

    /// HTML5 / Media Source sometimes reports duration as 2^32 or Infinity.
    static func sanitizedDuration(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0, raw < 2_147_483_647 else {
            return 0
        }
        return raw
    }

    static func parseJSON(_ raw: String) -> YouTubeTabSnapshot? {
        let trimmed = Self.unwrapJSONString(raw)
        guard !trimmed.isEmpty, trimmed != "null", trimmed != "undefined" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return fromDictionary(object)
    }

    private static func unwrapJSONString(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return trimmed
    }

    static func fromDictionary(_ object: [String: Any]) -> YouTubeTabSnapshot {
        var snapshot = YouTubeTabSnapshot()
        snapshot.matched = boolValue(object["matched"]) ?? true
        snapshot.isLiveBroadcast = boolValue(object["isLive"]) ?? boolValue(object["isLiveBroadcast"]) ?? false
        snapshot.atLiveEdge = boolValue(object["atLiveEdge"]) ?? false
        snapshot.currentTime = max(0, doubleValue(object["currentTime"]) ?? 0)
        snapshot.duration = sanitizedDuration(doubleValue(object["duration"]) ?? 0)
        snapshot.canSeek = boolValue(object["canSeek"]) ?? true
        snapshot.seekOrigin = max(0, doubleValue(object["seekOrigin"]) ?? 0)
        if let playing = boolValue(object["playing"]) {
            snapshot.isPlaying = playing
        }
        let foundPlayer = boolValue(object["foundPlayer"]) ?? true
        if foundPlayer == false {
            snapshot.matched = false
        }
        return snapshot
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            let lowered = value.lowercased()
            if lowered == "true" || lowered == "1" { return true }
            if lowered == "false" || lowered == "0" { return false }
        }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }
}

struct YouTubeBrowserTab: Equatable {
    var windowIndex: Int
    var tabIndex: Int
    var url: String
    var title: String
}

enum YouTubeTabMatching {
    static func isYouTubeWatchURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return false
        }
        let isYouTubeHost = host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
        guard isYouTubeHost, !host.contains("music.youtube") else { return false }
        if host == "youtu.be" {
            return true
        }
        let path = url.path.lowercased()
        return path.contains("/watch")
            || path.contains("/live")
            || path.contains("/embed")
            || path.contains("/shorts")
    }

    static func titleIndicatesLiveBroadcast(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if lowered.hasPrefix("live ") || lowered.hasPrefix("live:") || lowered.hasPrefix("live•")
            || lowered.hasPrefix("live stream") || lowered.hasPrefix("livestream") {
            return true
        }
        let markers = [
            " live ", " live:", "• live", "(live)", "[live]", " - live ", "| live ",
            "livestream", "live stream", " live)", " live]", "🔴live", "live🔴"
        ]
        if markers.contains(where: { lowered.contains($0) }) {
            return true
        }
        return false
    }

    static func normalizedTitle(_ title: String) -> String {
        var value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" - YouTube", " – YouTube", " | YouTube"]
        for suffix in suffixes where value.lowercased().hasSuffix(suffix.lowercased()) {
            value = String(value.dropLast(suffix.count))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func titleMatchScore(tabTitle: String, mediaTitle: String) -> Int {
        let tab = normalizedTitle(tabTitle)
        let media = normalizedTitle(mediaTitle)
        guard !media.isEmpty, !tab.isEmpty else { return 0 }
        if tab == media { return 1_000 }
        if tab.contains(media) { return media.count }
        if media.contains(tab) { return tab.count }
        for length in [24, 18, 12] {
            let needle = String(media.suffix(length))
            if needle.count >= 12, tab.contains(needle) {
                return needle.count
            }
        }
        return 0
    }

    static func bestTab(in tabs: [YouTubeBrowserTab], mediaTitle: String) -> YouTubeBrowserTab? {
        let youtubeTabs = tabs.filter { isYouTubeWatchURL($0.url) }
        let scored = youtubeTabs.compactMap { tab -> (YouTubeBrowserTab, Int)? in
            let score = titleMatchScore(tabTitle: tab.title, mediaTitle: mediaTitle)
            guard score > 0 else { return nil }
            return (tab, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? (youtubeTabs.count == 1 ? youtubeTabs[0] : nil)
    }

    /// Stable carousel key for a browser video track (video id preferred, else title slug).
    static func webVideoTrackKey(title: String, url: String? = nil) -> String {
        if let url, let videoID = videoID(from: url), !videoID.isEmpty {
            return videoID
        }
        let normalized = normalizedTitle(title)
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        let clipped = String(normalized.prefix(48))
        return clipped.isEmpty ? "unknown" : clipped
    }

    static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" {
            let id = url.path.split(separator: "/").first.map(String.init)
            return id.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value,
           !videoID.isEmpty {
            return videoID
        }
        let parts = url.path.split(separator: "/")
        if let liveIndex = parts.firstIndex(of: "live"), parts.index(after: liveIndex) < parts.endIndex {
            return String(parts[parts.index(after: liveIndex)])
        }
        if let embedIndex = parts.firstIndex(of: "embed"), parts.index(after: embedIndex) < parts.endIndex {
            return String(parts[parts.index(after: embedIndex)])
        }
        return nil
    }
}

struct YouTubeTabPlayback: Equatable {
    var tab: YouTubeBrowserTab
    var snapshot: YouTubeTabSnapshot
    var videoID: String?
}

protocol YouTubeTabPlayerBridging: AnyObject {
    func snapshot(bundleIdentifier: String, title: String) async -> YouTubeTabSnapshot
    func seek(to time: Double, bundleIdentifier: String, title: String) async
    func goLive(bundleIdentifier: String, title: String) async
    func playingTabSnapshots(bundleIdentifier: String) async -> [YouTubeTabPlayback]
}

enum YouTubeTabBrowserKind {
    case chromium(appName: String)
    case safari

    static func from(bundleIdentifier: String) -> YouTubeTabBrowserKind? {
        let normalized = normalizeBundleIdentifier(bundleIdentifier)
        if normalized == "com.apple.Safari" || normalized.hasPrefix("com.apple.Safari.") {
            return .safari
        }
        if normalized == "com.google.Chrome" || normalized.hasPrefix("com.google.Chrome.") {
            return .chromium(appName: "Google Chrome")
        }
        if normalized == "com.brave.Browser" || normalized.hasPrefix("com.brave.Browser.") {
            return .chromium(appName: "Brave Browser")
        }
        return nil
    }
}

final class YouTubeTabPlayerBridge: YouTubeTabPlayerBridging {
    func snapshot(bundleIdentifier: String, title: String) async -> YouTubeTabSnapshot {
        guard let tab = await matchedTab(bundleIdentifier: bundleIdentifier, title: title) else {
            return .noMatchingTab
        }
        let result = await executeJavaScript(Self.snapshotJavaScript, on: tab, bundleIdentifier: bundleIdentifier)
        guard let parsed = result.flatMap(YouTubeTabSnapshot.parseJSON), parsed.matched else {
            return .unmatched
        }
        var snapshot = parsed
        snapshot.matched = true
        return snapshot
    }

    func seek(to time: Double, bundleIdentifier: String, title: String) async {
        guard let tab = await matchedTab(bundleIdentifier: bundleIdentifier, title: title) else { return }
        let clamped = max(0, time)
        let script = "(function(){var t=\(String(format: "%.3f", clamped));var p=document.getElementById('movie_player');if(p&&typeof p.seekTo==='function'){p.seekTo(t,true);return 'ok';}var v=document.querySelector('video');if(v){v.currentTime=t;return 'ok';}return 'fail';})();"
        _ = await executeJavaScript(script, on: tab, bundleIdentifier: bundleIdentifier)
    }

    func goLive(bundleIdentifier: String, title: String) async {
        guard let tab = await matchedTab(bundleIdentifier: bundleIdentifier, title: title) else { return }
        _ = await executeJavaScript(Self.goLiveJavaScript, on: tab, bundleIdentifier: bundleIdentifier)
    }

    func playingTabSnapshots(bundleIdentifier: String) async -> [YouTubeTabPlayback] {
        guard let kind = YouTubeTabBrowserKind.from(bundleIdentifier: bundleIdentifier) else {
            return []
        }
        let tabs = await listTabs(kind: kind).filter { YouTubeTabMatching.isYouTubeWatchURL($0.url) }
        var results: [YouTubeTabPlayback] = []
        for tab in tabs.prefix(6) {
            let result = await executeJavaScript(Self.snapshotJavaScript, on: tab, bundleIdentifier: bundleIdentifier)
            guard let parsed = result.flatMap(YouTubeTabSnapshot.parseJSON), parsed.matched else {
                continue
            }
            var snapshot = parsed
            snapshot.matched = true
            // Keep audible / active players in the carousel; paused tabs still count if
            // Media Session already registered them and this confirms the player exists.
            let isActive = snapshot.isPlaying == true
                || (snapshot.currentTime > 0 && snapshot.duration > 0)
            guard isActive || snapshot.isLiveBroadcast else { continue }
            results.append(
                YouTubeTabPlayback(
                    tab: tab,
                    snapshot: snapshot,
                    videoID: YouTubeTabMatching.videoID(from: tab.url)
                )
            )
        }
        return results
    }

    private func matchedTab(bundleIdentifier: String, title: String) async -> YouTubeBrowserTab? {
        guard let kind = YouTubeTabBrowserKind.from(bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let tabs = await listTabs(kind: kind)
        return YouTubeTabMatching.bestTab(in: tabs, mediaTitle: title)
    }

    private func listTabs(kind: YouTubeTabBrowserKind) async -> [YouTubeBrowserTab] {
        let script: String
        switch kind {
        case .chromium(let appName):
            script = """
            tell application "\(appName)"
                if (count of windows) is 0 then return ""
                set out to ""
                set winIndex to 0
                repeat with w in windows
                    set winIndex to winIndex + 1
                    set tabIndex to 0
                    repeat with t in tabs of w
                        set tabIndex to tabIndex + 1
                        set out to out & winIndex & character id 31 & tabIndex & character id 31 & (URL of t) & character id 31 & (title of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                set out to ""
                set winIndex to 0
                repeat with w in windows
                    set winIndex to winIndex + 1
                    set tabIndex to 0
                    repeat with t in tabs of w
                        set tabIndex to tabIndex + 1
                        set out to out & winIndex & character id 31 & tabIndex & character id 31 & (URL of t) & character id 31 & (name of t) & linefeed
                    end repeat
                end repeat
                return out
            end tell
            """
        }
        do {
            let descriptor = try await AppleScriptHelper.execute(script)
            guard let raw = descriptor.flatMap(Self.string(from:)) else {
                return []
            }
            return Self.parseTabList(raw)
        } catch {
            NSLog("[YouTubeTabPlayerBridge] Tab list failed: \(error.localizedDescription)")
            return []
        }
    }

    static func parseTabList(_ raw: String) -> [YouTubeBrowserTab] {
        let unit = "\u{001F}"
        return raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = String(line).components(separatedBy: unit)
            guard parts.count >= 4,
                  let windowIndex = Int(parts[0]),
                  let tabIndex = Int(parts[1]) else {
                return nil
            }
            return YouTubeBrowserTab(
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                url: parts[2],
                title: parts[3]
            )
        }
    }

    private func executeJavaScript(
        _ javaScript: String,
        on tab: YouTubeBrowserTab,
        bundleIdentifier: String
    ) async -> String? {
        guard let kind = YouTubeTabBrowserKind.from(bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let quotedJS = Self.appleScriptStringLiteral(javaScript)
        let script: String
        switch kind {
        case .chromium(let appName):
            script = """
            tell application "\(appName)"
                execute javascript \(quotedJS) of tab \(tab.tabIndex) of window \(tab.windowIndex)
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
                do JavaScript \(quotedJS) in document of tab \(tab.tabIndex) of window \(tab.windowIndex)
            end tell
            """
        }
        do {
            let descriptor = try await AppleScriptHelper.execute(script)
            return descriptor.flatMap(Self.string(from:))
        } catch {
            NSLog("[YouTubeTabPlayerBridge] JavaScript failed: \(error.localizedDescription). Enable View > Developer > Allow JavaScript from Apple Events.")
            return nil
        }
    }

    static func string(from descriptor: NSAppleEventDescriptor) -> String? {
        if let value = descriptor.stringValue, !value.isEmpty {
            return value
        }
        if descriptor.numberOfItems > 0, let child = descriptor.atIndex(1), let value = child.stringValue, !value.isEmpty {
            return value
        }
        return nil
    }

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static let snapshotJavaScript = """
    (function(){
      function finite(n){return typeof n==='number'&&isFinite(n)&&n>=0&&n<2147483647;}
      function visible(el){
        if(!el) return false;
        var st=window.getComputedStyle(el);
        if(!st||st.display==='none'||st.visibility==='hidden'||st.opacity==='0') return false;
        return el.getClientRects().length>0;
      }
      var player=document.getElementById('movie_player');
      var video=document.querySelector('video.html5-main-video')||document.querySelector('video');
      var badge=document.querySelector('.ytp-live-badge');
      var href=String(location.href||'');
      var currentTime=0;
      var duration=0;
      var seekOrigin=0;
      var canSeek=true;
      var isLive=false;
      var atLiveEdge=false;
      var mediaTime=0;
      var playing=null;
      try{
        if(player&&typeof player.getPlayerResponse==='function'){
          var pr=player.getPlayerResponse()||{};
          var vd=pr.videoDetails||{};
          var liveNow=pr.microformat&&pr.microformat.playerMicroformatRenderer&&pr.microformat.playerMicroformatRenderer.liveBroadcastDetails;
          if(vd.isLive===true||vd.isLiveNow===true) isLive=true;
          if(liveNow&&liveNow.isLiveNow===true) isLive=true;
        }
      }catch(e){}
      try{
        if(player&&typeof player.getVideoData==='function'){
          var data=player.getVideoData()||{};
          if(data.isLive===true) isLive=true;
        }
      }catch(e){}
      try{
        if(player&&typeof player.getProgressState==='function'){
          var ps=player.getProgressState()||{};
          if(finite(ps.current)) mediaTime=ps.current;
          else if(finite(ps.currentTime)) mediaTime=ps.currentTime;
          var s=finite(ps.seekableStart)?ps.seekableStart:(finite(ps.loadedStart)?ps.loadedStart:0);
          var e=finite(ps.seekableEnd)?ps.seekableEnd:0;
          if(finite(ps.duration)&&ps.duration>0&&ps.duration<2147483647) duration=ps.duration;
          if(e>s){
            seekOrigin=s;
            duration=e-s;
            currentTime=Math.max(0,mediaTime-s);
            canSeek=duration>0.25;
          }
        }
      }catch(e){}
      try{
        if(video){
          playing=!video.paused&&!video.ended;
          if(!mediaTime) mediaTime=video.currentTime||0;
          if(video.seekable&&video.seekable.length>0){
            var start=video.seekable.start(0);
            var end=video.seekable.end(video.seekable.length-1);
            if(finite(end)&&end>=start){
              if(!duration){
                seekOrigin=finite(start)?start:0;
                duration=Math.max(0,end-seekOrigin);
                currentTime=Math.max(0,mediaTime-seekOrigin);
                canSeek=end>seekOrigin+0.25;
              }
            }
          }else if(!duration&&finite(video.duration)&&video.duration>0){
            duration=video.duration;
            currentTime=mediaTime;
          }
        }
      }catch(e){}
      if(!currentTime&&mediaTime) currentTime=Math.max(0,mediaTime-seekOrigin);
      if(visible(badge)) isLive=true;
      if(/\\/live\\b|live_stream|is_live=1/.test(href)) isLive=true;
      if(isLive){
        try{
          if(player&&typeof player.isAtLiveHead==='function') atLiveEdge=!!player.isAtLiveHead();
        }catch(e){}
        if(!atLiveEdge&&visible(badge)){
          atLiveEdge=badge.classList.contains('ytp-live-badge-is-livehead')||!!badge.disabled||badge.hasAttribute('disabled');
        }
      }
      var foundPlayer=!!(player||video);
      return JSON.stringify({matched:true,foundPlayer:foundPlayer,isLive:!!isLive,atLiveEdge:!!atLiveEdge,currentTime:currentTime,duration:duration,canSeek:!!canSeek,seekOrigin:seekOrigin,playing:playing});
    })();
    """

    static let goLiveJavaScript = """
    (function(){
      var player=document.getElementById('movie_player');
      try{
        if(player&&typeof player.seekToLiveHead==='function'){
          player.seekToLiveHead();
          return 'seekToLiveHead';
        }
      }catch(e){}
      var badge=document.querySelector('.ytp-live-badge');
      if(badge){badge.click();return 'clicked';}
      var video=document.querySelector('video.html5-main-video')||document.querySelector('video');
      if(video&&video.seekable&&video.seekable.length>0){
        var end=video.seekable.end(video.seekable.length-1);
        if(player&&typeof player.seekTo==='function'){player.seekTo(end,true);return 'seekTo';}
        video.currentTime=end;
        return 'currentTime';
      }
      return 'noop';
    })();
    """
}
