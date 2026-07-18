//
//  YouTubeMusicModels.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-14.
//

import Foundation

// MARK: - Configuration
struct YouTubeMusicConfiguration: Sendable {
    let baseURL: String
    let bundleIdentifier: String
    let reconnectDelay: ClosedRange<TimeInterval>
    let updateInterval: TimeInterval
    
    static let `default` = YouTubeMusicConfiguration(
        baseURL: "http://localhost:26538",
        bundleIdentifier: "com.github.th-ch.youtube-music",
        reconnectDelay: 1...60,
        updateInterval: 2.0
    )
}

// MARK: - API Models
struct AuthResponse: Decodable, Sendable {
    let accessToken: String
}

struct PlaybackResponse: Decodable, Sendable {
    let isPaused: Bool
    let title: String?
    let artist: String?
    let album: String?
    let elapsedSeconds: Double?
    let songDuration: Double?
    let imageSrc: String?
    let repeatMode: Int?
    let isShuffled: Bool?
    let volume: Double?
    let isLive: Bool?
    let isSeekableLive: Bool?

    init(
        isPaused: Bool,
        title: String?,
        artist: String?,
        album: String?,
        elapsedSeconds: Double?,
        songDuration: Double?,
        imageSrc: String?,
        repeatMode: Int?,
        isShuffled: Bool?,
        volume: Double?,
        isLive: Bool?,
        isSeekableLive: Bool?
    ) {
        self.isPaused = isPaused
        self.title = title
        self.artist = artist
        self.album = album
        self.elapsedSeconds = elapsedSeconds
        self.songDuration = songDuration
        self.imageSrc = imageSrc
        self.repeatMode = repeatMode
        self.isShuffled = isShuffled
        self.volume = volume
        self.isLive = isLive
        self.isSeekableLive = isSeekableLive
    }

    private enum CodingKeys: String, CodingKey {
        case isPaused
        case title
        case artist
        case album
        case elapsedSeconds
        case elapsed
        case position
        case songDuration
        case duration
        case imageSrc
        case repeatMode
        case isShuffled
        case shuffle
        case volume
        case isLive
        case isLiveContent
        case isLiveNow
        case isLiveStream
        case live
        case isSeekableLive
        case isDvrEnabled
        case isLiveDVR
        case canSeek
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? true
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        elapsedSeconds = Self.decodeDouble(
            from: container,
            keys: [.elapsedSeconds, .elapsed, .position]
        )
        songDuration = Self.decodeDouble(
            from: container,
            keys: [.songDuration, .duration]
        )
        imageSrc = try container.decodeIfPresent(String.self, forKey: .imageSrc)
        repeatMode = try container.decodeIfPresent(Int.self, forKey: .repeatMode)
        isShuffled = Self.decodeBool(
            from: container,
            keys: [.isShuffled, .shuffle]
        )
        volume = Self.decodeDouble(from: container, keys: [.volume])
        isLive = Self.decodeBool(
            from: container,
            keys: [.isLive, .isLiveContent, .isLiveNow, .isLiveStream, .live]
        )
        isSeekableLive = Self.decodeBool(
            from: container,
            keys: [.isSeekableLive, .isDvrEnabled, .isLiveDVR, .canSeek]
        )
    }

    private static func decodeDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Double? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(intValue)
            }
        }
        return nil
    }

    private static func decodeBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Bool? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
                return intValue != 0
            }
        }
        return nil
    }
}

// MARK: - WebSocket Message Types
enum WebSocketMessageType: String, Sendable {
    case playerInfo = "PLAYER_INFO"
    case videoChanged = "VIDEO_CHANGED"
    case playerStateChanged = "PLAYER_STATE_CHANGED"
    case positionChanged = "POSITION_CHANGED"
    case volumeChanged = "VOLUME_CHANGED"
    case repeatChanged = "REPEAT_CHANGED"
    case shuffleChanged = "SHUFFLE_CHANGED"
}

struct WebSocketMessage {
    let type: WebSocketMessageType
    let rawData: Data
    private let parsedJSON: [String: Any]?

    init?(from data: Data) {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard let typeString = json?["type"] as? String,
              let messageType = WebSocketMessageType(rawValue: typeString) else {
            return nil
        }

        self.type = messageType
        self.rawData = data
        self.parsedJSON = json
    }

    func extractData() -> [String: Any]? {
        parsedJSON
    }
}

// MARK: - Extensions
extension PlaybackResponse {
    static func from(websocketData: [String: Any]) -> PlaybackResponse? {
        let songData = websocketData["song"] as? [String: Any]
        
        let isPaused: Bool
        if let paused = songData?["isPaused"] as? Bool {
            isPaused = paused
        } else if let playing = websocketData["isPlaying"] as? Bool {
            isPaused = !playing
        } else {
            isPaused = true
        }
        
        let title = (songData?["title"] as? String) ??
                   (songData?["alternativeTitle"] as? String) ??
                   (websocketData["title"] as? String)
        let artist = (songData?["artist"] as? String) ?? (websocketData["artist"] as? String)
        let album = songData?["album"] as? String

        let elapsed = extractDouble(from: songData, key: "elapsedSeconds") ??
                     extractDouble(from: websocketData, key: "position")

        let duration = extractDouble(from: songData, key: "songDuration") ??
                      extractDouble(from: websocketData, key: "songDuration")
        
        let imageSrc = (songData?["imageSrc"] as? String) ?? (websocketData["imageSrc"] as? String)
        let isShuffled = (websocketData["shuffle"] as? Bool) ?? (songData?["isShuffled"] as? Bool)
        let isLive = extractBool(
            from: websocketData,
            paths: [
                ["isLive"], ["isLiveContent"], ["isLiveNow"], ["isLiveStream"], ["live"],
                ["song", "isLive"], ["song", "isLiveContent"], ["song", "isLiveNow"], ["song", "isLiveStream"], ["song", "live"],
                ["videoDetails", "isLive"], ["videoDetails", "isLiveContent"], ["videoDetails", "isLiveNow"],
                ["playerResponse", "videoDetails", "isLive"], ["playerResponse", "videoDetails", "isLiveContent"], ["playerResponse", "videoDetails", "isLiveNow"],
                ["playerResponse", "microformat", "playerMicroformatRenderer", "liveBroadcastDetails", "isLiveNow"]
            ]
        )
        let isSeekableLive = extractBool(
            from: websocketData,
            paths: [
                ["isSeekableLive"], ["isDvrEnabled"], ["isLiveDVR"], ["canSeek"],
                ["song", "isSeekableLive"], ["song", "isDvrEnabled"], ["song", "isLiveDVR"], ["song", "canSeek"],
                ["videoDetails", "isLiveDvrEnabled"], ["videoDetails", "isLiveDVR"],
                ["playerResponse", "videoDetails", "isLiveDvrEnabled"], ["playerResponse", "videoDetails", "isLiveDVR"]
            ]
        )

        var repeatModeInt: Int? = nil
        if let repeatVal = websocketData["repeat"] as? String {
            switch repeatVal.uppercased() {
            case "NONE": repeatModeInt = 0
            case "ALL": repeatModeInt = 1
            case "ONE": repeatModeInt = 2
            default: break
            }
        } else if let repeatStr = songData?["repeat"] as? String {
            switch repeatStr.uppercased() {
            case "NONE": repeatModeInt = 0
            case "ALL": repeatModeInt = 1
            case "ONE": repeatModeInt = 2
            default: break
            }
        }
        
        let volume = extractDouble(from: websocketData, key: "volume") ?? extractDouble(from: songData, key: "volume")

        return PlaybackResponse(
            isPaused: isPaused,
            title: title,
            artist: artist,
            album: album,
            elapsedSeconds: elapsed,
            songDuration: duration,
            imageSrc: imageSrc,
            repeatMode: repeatModeInt,
            isShuffled: isShuffled,
            volume: volume,
            isLive: isLive,
            isSeekableLive: isSeekableLive
        )
    }
    
    func with(elapsedSeconds: Double) -> PlaybackResponse {
        PlaybackResponse(
            isPaused: isPaused,
            title: title,
            artist: artist,
            album: album,
            elapsedSeconds: elapsedSeconds,
            songDuration: songDuration,
            imageSrc: imageSrc,
            repeatMode: repeatMode,
            isShuffled: isShuffled,
            volume: volume,
            isLive: isLive,
            isSeekableLive: isSeekableLive
        )
    }
}

private func extractDouble(from dict: [String: Any]?, key: String) -> Double? {
    guard let dict = dict else { return nil }
    if let value = dict[key] as? Double {
        return value
    } else if let value = dict[key] as? Int {
        return Double(value)
    }
    return nil
}

private func extractBool(from dict: [String: Any]?, keys: [String]) -> Bool? {
    guard let dict = dict else { return nil }

    for key in keys {
        if let value = boolValue(from: dict[key]) { return value }
    }

    return nil
}

private func extractBool(from dict: [String: Any]?, paths: [[String]]) -> Bool? {
    guard let dict = dict else { return nil }
    for path in paths {
        if let value = value(at: path, in: dict), let bool = boolValue(from: value) {
            return bool
        }
    }
    return nil
}

private func value(at path: [String], in dict: [String: Any]) -> Any? {
    guard !path.isEmpty else { return nil }
    var current: Any = dict
    for key in path {
        guard let object = current as? [String: Any], let next = object[key] else {
            return nil
        }
        current = next
    }
    return current
}

private func boolValue(from value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let int as Int:
        return int != 0
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        let lowered = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "true" || lowered == "1" { return true }
        if lowered == "false" || lowered == "0" { return false }
        return nil
    default:
        return nil
    }
}
