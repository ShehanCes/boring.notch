import CoreAudio
import Foundation
import IOBluetooth
import IOKit
import ObjectiveC

/// Battery information for a connected Bluetooth audio accessory
/// (headphones, earbuds, or speakers).
struct HeadphoneBatteryInfo: Equatable {
    var deviceName: String
    var deviceKind: HeadphoneDeviceKind
    var overall: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// The single value shown in the compact header indicator.
    /// Prefers the lower of the left/right earbuds (matching how AirPods report
    /// "worst case" battery to the system), falling back to whichever value is available.
    var headlineLevel: Int {
        if let left, let right {
            return min(left, right)
        }
        if let left {
            return left
        }
        if let right {
            return right
        }
        if let overall {
            return overall
        }
        return caseLevel ?? 0
    }

    /// Whether there's a left/right/case breakdown worth showing in a detail popover.
    var hasDetailedLevels: Bool {
        left != nil || right != nil || caseLevel != nil
    }
}

/// Reads and monitors battery levels of Bluetooth audio accessories.
///
/// Data sources (in priority order when merging a single active device):
/// 1. `IOBluetoothDevice` battery selectors (`batteryPercentSingle` / Left / Right / Case) —
///    covers most non-Apple headsets and speakers that macOS itself can show battery for.
/// 2. IORegistry `AppleDeviceManagementHIDEventService` `BatteryPercent*` keys —
///    richer L/R/Case breakdown for AirPods and some Apple accessories.
///
/// A device is considered "active" (and thus shown) when it reports a battery level and
/// either `isConnected()` is true, or its name matches the current CoreAudio default
/// output (needed because A2DP headsets often report `isConnected() == false`).
final class HeadphoneBatteryManager {

    static let shared = HeadphoneBatteryManager()

    /// Called on the main thread whenever the active accessory battery info changes.
    /// `nil` means no battery-reporting accessory is currently active.
    var onBatteryInfoChange: ((HeadphoneBatteryInfo?) -> Void)?

    private var observers: [Int: (HeadphoneBatteryInfo?) -> Void] = [:]
    private var nextObserverId = 0
    private var pollTimer: Timer?
    private var lastBatteryInfo: HeadphoneBatteryInfo?
    private var audioRouteChangeListenerInstalled = false

    /// How often to re-read accessory battery while a device stays connected.
    /// Levels don't need to be perfect — Bluetooth accessories have no public
    /// "percent changed" push API (unlike Mac battery via IOPS), so we poll.
    /// 90s keeps overhead low; bump this up if profiling shows too much IOKit /
    /// IOBluetooth churn, or lower it if fresher percentages matter more.
    private let pollInterval: TimeInterval = 90

    private init() {
        // Kick off periodic polling and start listening for audio route changes
        // (e.g. connecting/disconnecting a Bluetooth device) as soon as the
        // singleton is first accessed.
        startPolling()
        setupAudioRouteListener()
    }

    /// Returns the current accessory battery info, refreshing synchronously.
    /// Used for the initial value when a view model is created.
    func currentBatteryInfo() -> HeadphoneBatteryInfo? {
        readHeadphoneBatteryInfo()
    }

    /// Registers a closure to be called (on the main thread) whenever the active
    /// accessory's battery info changes. Returns a token to pass to `removeObserver`.
    @discardableResult
    func addObserver(_ observer: @escaping (HeadphoneBatteryInfo?) -> Void) -> Int {
        let id = nextObserverId
        nextObserverId += 1
        observers[id] = observer
        return id
    }

    /// Unregisters a previously-added observer using the token returned by `addObserver`.
    func removeObserver(byId id: Int) {
        observers.removeValue(forKey: id)
    }

    /// Does an immediate refresh, then schedules a repeating timer so battery levels
    /// stay reasonably up to date even if the OS doesn't notify us of a change
    /// (accessories don't push battery updates, so periodic polling is required).
    private func startPolling() {
        refresh()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Subscribes to CoreAudio's "default output device changed" notification so we
    /// re-evaluate battery info immediately when the user connects/disconnects/switches
    /// audio output, instead of waiting for the next poll tick.
    private func setupAudioRouteListener() {
        guard !audioRouteChangeListenerInstalled else { return }
        audioRouteChangeListenerInstalled = true

        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            nil
        ) { [weak self] _, _ in
            self?.refresh()
        }
    }

    /// Re-reads battery info and, only if it actually changed, notifies `onBatteryInfoChange`
    /// and every registered observer on the main thread. The equality check avoids
    /// redundant UI churn/animation restarts on every poll tick when nothing changed.
    private func refresh() {
        let info = readHeadphoneBatteryInfo()
        guard info != lastBatteryInfo else { return }
        lastBatteryInfo = info

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onBatteryInfoChange?(info)
            for observer in self.observers.values {
                observer(info)
            }
        }
    }

    /// Determines which single accessory (if any) should be reported as "active" right now,
    /// and returns its merged battery info. See the priority order in the type-level doc
    /// comment above for how the Bluetooth and IORegistry sources are combined.
    private func readHeadphoneBatteryInfo() -> HeadphoneBatteryInfo? {
        let routeName = currentDefaultOutputDeviceName()
        let bluetoothCandidates = readBluetoothDeviceBatteries()
        let registryInfo = readIORegistryBatteryInfo()

        // Prefer the Bluetooth device that matches the current audio route.
        if let routeName,
           let match = bluetoothCandidates.first(where: {
               deviceNamesMatch($0.info.deviceName, routeName)
           }) {
            return merge(preferred: match.info, registry: registryInfo)
        }

        // Next: any Bluetooth device macOS reports as connected with battery data.
        if let connected = bluetoothCandidates.first(where: \.isConnected) {
            return merge(preferred: connected.info, registry: registryInfo)
        }

        // Fall back to Apple HID registry (AirPods etc.) when no BT candidate is active,
        // but only if that product looks like the current route (or we have no route name).
        if let registryInfo {
            if let routeName, !deviceNamesMatch(registryInfo.deviceName, routeName) {
                return nil
            }
            return registryInfo
        }

        return nil
    }

    // MARK: - IOBluetooth

    /// A paired Bluetooth device that reported some battery data, plus whether
    /// `IOBluetoothDevice` currently considers it connected (used as a tiebreaker in
    /// `readHeadphoneBatteryInfo`).
    private struct BluetoothBatteryCandidate {
        let info: HeadphoneBatteryInfo
        let isConnected: Bool
    }

    /// Reads battery levels from paired `IOBluetoothDevice`s via undocumented but
    /// long-standing selectors that the system Bluetooth UI also uses.
    private func readBluetoothDeviceBatteries() -> [BluetoothBatteryCandidate] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var results: [BluetoothBatteryCandidate] = []
        var seenAddresses = Set<String>()

        for device in devices {
            let address = device.addressString ?? device.name ?? UUID().uuidString
            if seenAddresses.contains(address) { continue }
            seenAddresses.insert(address)

            let overall = nonzeroPercent(bluetoothUInt8(device, selector: "batteryPercentSingle"))
                ?? nonzeroPercent(bluetoothUInt8(device, selector: "batteryPercentCombined"))
                ?? nonzeroHeadsetBattery(device)
            let left = nonzeroPercent(bluetoothUInt8(device, selector: "batteryPercentLeft"))
            let right = nonzeroPercent(bluetoothUInt8(device, selector: "batteryPercentRight"))
            let caseLevel = nonzeroPercent(bluetoothUInt8(device, selector: "batteryPercentCase"))

            guard overall != nil || left != nil || right != nil || caseLevel != nil else {
                continue
            }

            let name = device.name ?? "Bluetooth Audio"
            let info = HeadphoneBatteryInfo(
                deviceName: name,
                deviceKind: classifyHeadphoneDeviceKind(named: name),
                overall: overall,
                left: left,
                right: right,
                caseLevel: caseLevel
            )
            results.append(BluetoothBatteryCandidate(info: info, isConnected: device.isConnected()))
        }

        return results
    }

    /// Calls an undocumented `IOBluetoothDevice` getter (by selector name) that returns a
    /// `UInt8` percentage, using Objective-C runtime introspection. These selectors
    /// (`batteryPercentSingle`, `batteryPercentLeft`, etc.) aren't in the public
    /// `IOBluetooth` headers but are what macOS's own Bluetooth menu/System Settings use
    /// internally, so they're the most reliable way to get third-party accessory battery.
    /// Returns `nil` if the device doesn't respond to the selector at all.
    private func bluetoothUInt8(_ device: IOBluetoothDevice, selector name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard device.responds(to: selector),
              let method = device.method(for: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt8
        let getter = unsafeBitCast(method, to: Getter.self)
        return Int(getter(device, selector))
    }

    /// Fallback overall-battery reader for older/simpler headsets that only expose the
    /// legacy `headsetBattery` selector (an `Int64`, using -1/0 as "unknown").
    private func nonzeroHeadsetBattery(_ device: IOBluetoothDevice) -> Int? {
        let selector = NSSelectorFromString("headsetBattery")
        guard device.responds(to: selector),
              let method = device.method(for: selector) else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int64
        let getter = unsafeBitCast(method, to: Getter.self)
        let value = Int(getter(device, selector))
        // headsetBattery can be -1 / 0 when unknown.
        return (1...100).contains(value) ? value : nil
    }

    /// Clamps a raw battery reading to a valid 1-100% range, treating 0/negative/out-of-range
    /// values (which typically mean "not reported") as `nil` instead of a real 0%.
    private func nonzeroPercent(_ value: Int?) -> Int? {
        guard let value, (1...100).contains(value) else { return nil }
        return value
    }

    // MARK: - IORegistry (Apple accessories)

    /// Scans the IORegistry for `AppleDeviceManagementHIDEventService` entries (how macOS
    /// tracks paired Apple accessories like AirPods) and returns the first one that reports
    /// a battery-related property. This is the source for the detailed Left/Right/Case
    /// breakdown that `IOBluetoothDevice` selectors don't always expose.
    private func readIORegistryBatteryInfo() -> HeadphoneBatteryInfo? {
        var iterator: io_iterator_t = 0
        let matchResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"),
            &iterator
        )
        guard matchResult == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var propertiesRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service,
                &propertiesRef,
                kCFAllocatorDefault,
                0
            ) == KERN_SUCCESS,
                let properties = propertiesRef?.takeRetainedValue() as? [String: Any]
            else {
                continue
            }

            if let info = parseRegistryBatteryInfo(from: properties) {
                return info
            }
        }

        return nil
    }

    /// Extracts `BatteryPercent`/`Left`/`Right`/`Case` keys from a single IORegistry entry's
    /// property dictionary. Returns `nil` if none of those keys are present, meaning this
    /// particular registry entry isn't a battery-reporting accessory.
    private func parseRegistryBatteryInfo(from properties: [String: Any]) -> HeadphoneBatteryInfo? {
        let overall = intValue(properties["BatteryPercent"])
        let left = intValue(properties["BatteryPercentLeft"])
        let right = intValue(properties["BatteryPercentRight"])
        let caseLevel = intValue(properties["BatteryPercentCase"])

        guard overall != nil || left != nil || right != nil || caseLevel != nil else {
            return nil
        }

        let productName = (properties["Product"] as? String) ?? "Headphones"
        return HeadphoneBatteryInfo(
            deviceName: productName,
            deviceKind: classifyHeadphoneDeviceKind(named: productName),
            overall: overall,
            left: left,
            right: right,
            caseLevel: caseLevel
        )
    }

    /// Prefer Bluetooth candidate levels, fill missing L/R/Case from registry when
    /// it looks like the same device (AirPods often have both sources).
    private func merge(
        preferred: HeadphoneBatteryInfo,
        registry: HeadphoneBatteryInfo?
    ) -> HeadphoneBatteryInfo {
        guard let registry else { return preferred }

        let sameName = deviceNamesMatch(preferred.deviceName, registry.deviceName)
        let sameAppleKind = preferred.deviceKind == registry.deviceKind
            && preferred.deviceKind != .genericHeadphones
            && preferred.deviceKind != .bluetoothSpeaker
        guard sameName || sameAppleKind else { return preferred }

        return HeadphoneBatteryInfo(
            deviceName: preferred.deviceName,
            deviceKind: preferred.deviceKind == .genericHeadphones ? registry.deviceKind : preferred.deviceKind,
            overall: preferred.overall ?? registry.overall,
            left: preferred.left ?? registry.left,
            right: preferred.right ?? registry.right,
            caseLevel: preferred.caseLevel ?? registry.caseLevel
        )
    }

    // MARK: - Audio route helpers

    /// Returns the display name of the current default CoreAudio output device (e.g.
    /// "John's AirPods Pro"), or `nil` if it can't be determined. Used to figure out which
    /// Bluetooth candidate is actually the one currently in use for audio.
    private func currentDefaultOutputDeviceName() -> String? {
        let deviceID = systemOutputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &value
        ) == noErr else {
            return nil
        }
        let name = value as String
        return name.isEmpty ? nil : name
    }

    /// Fetches the `AudioObjectID` of the system's current default audio output device.
    private func systemOutputDeviceID() -> AudioObjectID {
        var defaultDeviceID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &defaultDeviceID
        )
        return status == noErr ? defaultDeviceID : kAudioObjectUnknown
    }

    /// Loosely compares two device names (e.g. a `IOBluetoothDevice.name` vs. a CoreAudio
    /// output device name), since the same physical accessory is sometimes reported with
    /// slightly different strings by different subsystems. Uses substring containment
    /// rather than strict equality to tolerate that.
    private func deviceNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizeDeviceName(lhs)
        let b = normalizeDeviceName(rhs)
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Lowercases, trims whitespace, and normalizes curly apostrophes so name comparisons
    /// in `deviceNamesMatch` aren't tripped up by cosmetic differences.
    private func normalizeDeviceName(_ name: String) -> String {
        name.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Converts an `NSNumber`-boxed IORegistry property value to an `Int`, discarding it
    /// (returning `nil`) if it falls outside the valid 0-100% battery range.
    private func intValue(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.intValue else { return nil }
        return (0...100).contains(number) ? number : nil
    }

    deinit {
        // Stop the polling timer so it doesn't keep firing after this singleton would
        // otherwise be torn down.
        pollTimer?.invalidate()
    }
}
