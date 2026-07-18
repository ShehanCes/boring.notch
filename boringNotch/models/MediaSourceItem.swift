//
//  MediaSourceItem.swift
//  boringNotch
//
//  Created by Codex on 2026-04-16.
//

import Foundation

struct MediaSourceItem: Identifiable, Equatable {
    let id: String
    var state: PlaybackState
    var lastSeen: Date

    var displayName: String {
        Self.displayName(for: id)
    }

    static func displayName(for bundleIdentifier: String) -> String {
        let (baseIdentifier, bucket) = parseSourceIdentifier(bundleIdentifier)
        let baseName = baseDisplayName(for: baseIdentifier)

        switch bucket {
        case "web-audio":
            return "\(baseName) (Web Audio)"
        case "web-video":
            return "\(baseName) (Web Video)"
        default:
            return baseName
        }
    }

    private static func parseSourceIdentifier(_ identifier: String) -> (base: String, bucket: String?) {
        let parts = identifier.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].isEmpty else {
            return (identifier, nil)
        }
        return (String(parts[0]), String(parts[2]))
    }

    private static func baseDisplayName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Music":
            return "Apple Music"
        case "com.spotify.client":
            return "Spotify"
        case "com.google.Chrome":
            return "Chrome"
        case "com.brave.Browser":
            return "Brave"
        case "org.mozilla.firefox":
            return "Firefox"
        case "com.apple.Safari":
            return "Safari"
        default:
            if bundleIdentifier.isEmpty {
                return "Unknown"
            }
            return bundleIdentifier
                .split(separator: ".")
                .last
                .map(String.init)?
                .capitalized ?? bundleIdentifier
        }
    }
}
