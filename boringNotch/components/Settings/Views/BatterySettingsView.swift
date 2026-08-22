//
//  BatterySettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct Charge: View {
    /// Master switch for the accessory battery feature — read from `body` so the
    /// mode picker / swap-interval slider can be hidden/shown alongside the toggle.
    @Default(.showHeadphoneBattery) private var showHeadphoneBattery
    /// On hover vs timed alternation for the compact notch indicator.
    @Default(.headphoneBatteryDisplayMode) private var displayMode
    /// Seconds between alternating Mac and accessory battery (timer mode only).
    @Default(.headphoneBatterySwapInterval) private var swapInterval

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
                Defaults.Toggle(key: .showPowerStatusNotifications) {
                    Text("Show power status notifications")
                }
            } header: {
                Text("General")
            }
            Section {
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
            } header: {
                Text("Battery Information")
            }
            // Bluetooth accessory battery: toggle enables accessory details in the battery
            // popup and (optionally) revealing accessory % in the compact notch indicator.
            Section {
                Defaults.Toggle(key: .showHeadphoneBattery) {
                    Text("Show accessory battery")
                }
                if showHeadphoneBattery {
                    Picker("Reveal accessory battery", selection: $displayMode) {
                        ForEach(HeadphoneBatteryDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if displayMode == .onTimer {
                        Slider(value: $swapInterval, in: 1...10, step: 1) {
                            Text("Swap interval")
                        } minimumValueLabel: {
                            Text("1s")
                        } maximumValueLabel: {
                            Text("10s")
                        }
                        Text("Alternates every \(Int(swapInterval)) seconds")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Bluetooth Accessories")
            } footer: {
                Text(footerText)
            }
        }
        .onAppear {
            Task { @MainActor in
                await XPCHelperClient.shared.isAccessibilityAuthorized()
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Battery")
    }

    private var footerText: LocalizedStringKey {
        switch (showHeadphoneBattery, displayMode) {
        case (true, .onHover):
            return "When a Bluetooth headphone or speaker reports battery, hover the battery indicator to peek at the accessory level. Details also appear in the battery popup."
        case (true, .onTimer):
            return "When a Bluetooth headphone or speaker reports battery, the notch indicator starts on the accessory, then smoothly alternates with the Mac battery. Details also appear in the battery popup."
        case (false, _):
            return "Shows accessory battery details in the battery popup when a Bluetooth headphone or speaker reports battery."
        }
    }
}
