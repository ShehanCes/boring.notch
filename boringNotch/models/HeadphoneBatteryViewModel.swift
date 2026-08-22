import Combine
import Foundation

/// A view model that publishes the battery status of connected Bluetooth headphones/earbuds.
///
/// This is a thin `ObservableObject` wrapper around `HeadphoneBatteryManager` (which does the
/// actual IOKit/IOBluetooth work). It exists so SwiftUI views can simply observe
/// `HeadphoneBatteryViewModel.shared` and get `@Published` updates, without needing to know
/// about the manager's observer-closure API.
class HeadphoneBatteryViewModel: ObservableObject {

    static let shared = HeadphoneBatteryViewModel()

    /// Whether any battery-reporting accessory is currently active.
    @Published private(set) var isConnected: Bool = false
    /// Display name of the active accessory (e.g. "John's AirPods Pro").
    @Published private(set) var deviceName: String = ""
    /// Classified kind of the active accessory, used to pick an SF Symbol.
    @Published private(set) var deviceKind: HeadphoneDeviceKind = .genericHeadphones
    /// The single percentage shown in the compact header indicator.
    @Published private(set) var headlineLevel: Int = 0
    @Published private(set) var leftLevel: Int?
    @Published private(set) var rightLevel: Int?
    @Published private(set) var caseLevel: Int?
    /// Whether `leftLevel`/`rightLevel`/`caseLevel` have at least one non-nil value,
    /// i.e. whether the detail popover should show the L/R/Case breakdown.
    @Published private(set) var hasDetailedLevels: Bool = false

    private let manager = HeadphoneBatteryManager.shared
    private var observerId: Int?

    private init() {
        // Seed the initial state synchronously, then subscribe for future updates.
        apply(manager.currentBatteryInfo())
        observerId = manager.addObserver { [weak self] info in
            self?.apply(info)
        }
    }

    /// Copies a `HeadphoneBatteryInfo` snapshot (or `nil` if nothing is connected) into
    /// this view model's `@Published` properties.
    private func apply(_ info: HeadphoneBatteryInfo?) {
        if let info {
            isConnected = true
            deviceName = info.deviceName
            deviceKind = info.deviceKind
            headlineLevel = info.headlineLevel
            leftLevel = info.left
            rightLevel = info.right
            caseLevel = info.caseLevel
            hasDetailedLevels = info.hasDetailedLevels
        } else {
            isConnected = false
            deviceName = ""
            deviceKind = .genericHeadphones
            headlineLevel = 0
            leftLevel = nil
            rightLevel = nil
            caseLevel = nil
            hasDetailedLevels = false
        }
    }

    deinit {
        // Unsubscribe from the manager so it doesn't keep a dangling reference to this
        // instance's closure after it's gone.
        if let observerId {
            manager.removeObserver(byId: observerId)
        }
    }
}
