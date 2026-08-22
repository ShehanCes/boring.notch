//
//  HeadphoneDeviceKind.swift
//  boringNotch
//
//  Shared headphone/earbud/speaker name classification used by audio route
//  resolution and the Bluetooth accessory battery indicator.
//

import Foundation

enum HeadphoneDeviceKind: Equatable {
    case airPods
    case airPodsPro
    case airPodsMax
    case genericHeadphones
    case bluetoothSpeaker

    /// SF Symbol-style asset name used across the app's headphone/AirPods icons.
    var symbolName: String {
        switch self {
        case .airPods:
            return "airpods"
        case .airPodsPro:
            return "airpodspro"
        case .airPodsMax:
            return "airpodsmax"
        case .genericHeadphones:
            return "headphones"
        case .bluetoothSpeaker:
            return "hifispeaker.fill"
        }
    }

    /// SF Symbol for the left earbud, if this device kind has a distinct one.
    var leftSymbolName: String? {
        switch self {
        case .airPods:
            return "airpod.left"
        case .airPodsPro:
            return "airpodpro.left"
        case .airPodsMax, .genericHeadphones, .bluetoothSpeaker:
            return nil
        }
    }

    /// SF Symbol for the right earbud, if this device kind has a distinct one.
    var rightSymbolName: String? {
        switch self {
        case .airPods:
            return "airpod.right"
        case .airPodsPro:
            return "airpodpro.right"
        case .airPodsMax, .genericHeadphones, .bluetoothSpeaker:
            return nil
        }
    }

    /// SF Symbol for the charging case, if this device kind has one.
    var caseSymbolName: String? {
        switch self {
        case .airPods:
            return "airpods.chargingcase.wireless"
        case .airPodsPro:
            return "airpodspro.chargingcase.wireless"
        case .airPodsMax, .genericHeadphones, .bluetoothSpeaker:
            return nil
        }
    }
}

/// Classifies a Bluetooth/audio device name (as reported by CoreAudio, IOBluetooth,
/// or IORegistry) into a `HeadphoneDeviceKind`.
func classifyHeadphoneDeviceKind(named deviceName: String) -> HeadphoneDeviceKind {
    let normalizedName = deviceName.lowercased()

    if normalizedName.contains("airpods max") {
        return .airPodsMax
    }
    if normalizedName.contains("airpods pro") {
        return .airPodsPro
    }
    if normalizedName.contains("airpods") {
        return .airPods
    }
    if isSpeakerLikeName(deviceName) {
        return .bluetoothSpeaker
    }
    return .genericHeadphones
}

/// Whether a device name looks like headphones/earbuds/a headset based on common keywords.
func isHeadphoneLikeName(_ deviceName: String) -> Bool {
    let normalizedName = deviceName.lowercased()
    return normalizedName.contains("headphone")
        || normalizedName.contains("headset")
        || normalizedName.contains("earbud")
        || normalizedName.contains("earphone")
        || normalizedName.contains("pods")
}

/// Whether a device name looks like a Bluetooth speaker.
func isSpeakerLikeName(_ deviceName: String) -> Bool {
    let normalizedName = deviceName.lowercased()
    return normalizedName.contains("speaker")
        || normalizedName.contains("soundbar")
        || normalizedName.contains("hifi")
}
