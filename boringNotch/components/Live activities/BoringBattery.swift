import SwiftUI
import Defaults

/// A view that displays the battery status with an icon and charging indicator.
struct BatteryView: View {

    var levelBattery: Float
    var isPluggedIn: Bool
    var isCharging: Bool
    var isInLowPowerMode: Bool
    var batteryWidth: CGFloat = 26
    var isForNotification: Bool

    var icon: String = "battery.0"

    /// Determines the icon to display when charging.
    var iconStatus: String {
        if isCharging {
            return "bolt"
        }
        else if isPluggedIn {
            return "plug"
        }
        else {
            return ""
        }
    }

    /// Determines the color of the battery based on its status.
    var batteryColor: Color {
        if isInLowPowerMode {
            return .yellow
        } else if levelBattery <= 20 && !isCharging && !isPluggedIn {
            return .red
        } else if isCharging || isPluggedIn || levelBattery == 100 {
            return .green
        } else {
            return .white
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {

            Image(systemName: icon)
                .resizable()
                .fontWeight(.thin)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.white.opacity(0.5))
                .frame(
                    width: batteryWidth + 1
                )

            RoundedRectangle(cornerRadius: 2.5)
                .fill(batteryColor)
                .frame(
                    width: CGFloat(((CGFloat(CFloat(levelBattery)) / 100) * (batteryWidth - 6))),
                    height: (batteryWidth - 2.75) - 18
                )
                .padding(.leading, 2)

            if iconStatus != "" && (isForNotification || Defaults[.showPowerStatusIcons]) {
                ZStack {
                    Image(iconStatus)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(.white)
                        .frame(
                            width: 17,
                            height: 17
                        )
                }
                .frame(width: batteryWidth, height: batteryWidth)
            }
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// A view that displays detailed battery information and settings.
struct BatteryMenuView: View {
    
    var isPluggedIn: Bool
    var isCharging: Bool
    var levelBattery: Float
    var maxCapacity: Float?
    var timeToFullCharge: Int
    var timeToDischarge: Int
    var isInLowPowerMode: Bool

    // Bluetooth accessory battery details (AirPods/headphones/speakers), shown as an extra
    // section below the Mac battery info when an accessory with battery data is active.
    // All default to "off" values so existing callers that don't pass them still compile
    // and simply hide the accessory section.
    var accessoryConnected: Bool = false
    var accessoryName: String = ""
    var accessoryKind: HeadphoneDeviceKind = .genericHeadphones
    var accessoryLevel: Int = 0
    var accessoryLeftLevel: Int?
    var accessoryRightLevel: Int?
    var accessoryCaseLevel: Int?
    var accessoryHasDetailedLevels: Bool = false

    var onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    private var formattedTimeToDischarge: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(timeToDischarge * 60)) ?? ""
    }

    private var formattedTimeToFullCharge: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(timeToFullCharge * 60)) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack {
                Text("Battery Status")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(Int(levelBattery))%")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                if let maxCapacity {
                    Text("Max Capacity: \(Int(maxCapacity))%")
                        .font(.subheadline)
                        .fontWeight(.regular)
                } else {
                    Text("Max Capacity: Not Available")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isInLowPowerMode {
                    Label("Low Power Mode", systemImage: "bolt.circle")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isPluggedIn && !isCharging {
                    Label("Plugged In", systemImage: "powerplug.fill")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if isCharging && timeToFullCharge > 0 {
                    Label("Time to Full Charge: \(formattedTimeToFullCharge)", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                } else if isCharging && timeToFullCharge == -1 {
                    Label("Time to Full Charge: Calculating...", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && !isPluggedIn && timeToDischarge > 0 {
                    Label("Time Until Empty: \(formattedTimeToDischarge)", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                } else if !isCharging && !isPluggedIn && timeToDischarge == -1 {
                    Label("Time Until Empty: Calculating...", systemImage: "clock")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                if !isCharging && isPluggedIn && levelBattery >= 80 {
                    Label("Charging on Hold: Desktop Mode", systemImage: "desktopcomputer")
                        .font(.subheadline)
                        .fontWeight(.regular)
                }
                    
            }
            .padding(.vertical, 8)

            // Accessory battery section — only shown when a Bluetooth accessory with
            // battery data is currently active (see `shouldAlternateAccessory` below).
            if accessoryConnected {
                Divider().background(Color.white)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(accessoryName, systemImage: accessoryKind.symbolName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer()
                        Text("\(accessoryLevel)%")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    if accessoryHasDetailedLevels {
                        if let accessoryLeftLevel {
                            accessoryRow(
                                title: "Left",
                                systemImage: accessoryKind.leftSymbolName ?? "airpod.left",
                                level: accessoryLeftLevel
                            )
                        }
                        if let accessoryRightLevel {
                            accessoryRow(
                                title: "Right",
                                systemImage: accessoryKind.rightSymbolName ?? "airpod.right",
                                level: accessoryRightLevel
                            )
                        }
                        if let accessoryCaseLevel {
                            accessoryRow(
                                title: "Case",
                                systemImage: accessoryKind.caseSymbolName ?? "case.fill",
                                level: accessoryCaseLevel
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider().background(Color.white)

            Button(action: openBatteryPreferences) {
                Label("Battery Settings", systemImage: "gearshape")
                    .fontWeight(.regular)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
        .padding()
        .frame(width: 280)
        .foregroundColor(.white)
    }

    /// A single "Left/Right/Case: NN%" row in the accessory detail section.
    private func accessoryRow(title: LocalizedStringKey, systemImage: String, level: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .fontWeight(.regular)
            Spacer()
            Text("\(level)%")
                .font(.subheadline)
                .fontWeight(.regular)
        }
    }

    private func openBatteryPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            openURL(url)
            onDismiss()
        }
    }
}

/// A view that displays the battery status and allows interaction to show detailed information.
/// When a Bluetooth accessory with battery is conne/// A view that displays the battery status and allows interaction to show detailed information.
/// When a Bluetooth accessory with battery is connected (and enabled in settings), the compact
/// indicator can reveal accessory battery either on hover or by timed alternation with the Mac
/// battery — controlled by `headphoneBatteryDisplayMode`.
struct BoringBatteryView: View {
    
    @State var batteryWidth: CGFloat = 26
    var isCharging: Bool = false
    var isInLowPowerMode: Bool = false
    var isPluggedIn: Bool = false
    var levelBattery: Float = 0
    var maxCapacity: Float?
    var timeToFullCharge: Int = 0
    var timeToDischarge: Int = 0
    /// When true, this instance is the transient power-status notification banner —
    /// accessory battery reveal is disabled there.
    var isForNotification: Bool = false
    
    @State private var showPopupMenu: Bool = false
    @State private var isPressed: Bool = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var hideTask: Task<Void, Never>? = nil
    /// Timer-mode only: which face the swap loop is currently on.
    @State private var timerShowsAccessory: Bool = true
    /// The repeating task that flips `timerShowsAccessory` every `swapInterval` seconds.
    @State private var swapTask: Task<Void, Never>? = nil

    /// Publishes the currently-active Bluetooth accessory's battery info, if any.
    @ObservedObject private var headphoneBatteryModel = HeadphoneBatteryViewModel.shared
    /// User setting: master on/off switch for the accessory battery feature.
    @Default(.showHeadphoneBattery) private var showHeadphoneBattery
    /// User setting: reveal accessory battery on hover, or alternate on a timer.
    @Default(.headphoneBatteryDisplayMode) private var displayMode
    /// User setting: how many seconds each face is shown before swapping (timer mode only).
    @Default(.headphoneBatterySwapInterval) private var swapInterval
    @Default(.showBatteryPercentage) private var showBatteryPercentage

    @EnvironmentObject var vm: BoringViewModel

    /// Whether accessory battery can appear in the compact indicator at all.
    private var accessoryAvailable: Bool {
        !isForNotification && showHeadphoneBattery && headphoneBatteryModel.isConnected
    }

    /// Whether timer-based Mac ↔ accessory alternation should be running.
    private var shouldRunTimerSwap: Bool {
        accessoryAvailable && displayMode == .onTimer
    }

    /// The face currently shown — derived from mode so hover never fights the timer.
    private var showingAccessory: Bool {
        guard accessoryAvailable else { return false }
        switch displayMode {
        case .onHover:
            // Peek while hovered; keep Mac battery while the popover is open.
            return isHoveringButton && !showPopupMenu
        case .onTimer:
            return timerShowsAccessory
        }
    }

    var body: some View {
        Button(action: {
            withAnimation {
                showPopupMenu.toggle()
            }
        }) {
            // One shared layout (percentage slot + icon slot). Only the values/icons
            // crossfade in place — no separate headphone HStack — so Mac ↔ accessory
            // doesn't jump layout.
            HStack(spacing: 4) {
                if showBatteryPercentage {
                    Text("\(displayedPercentage)%")
                        .font(.callout)
                        .foregroundStyle(percentageColor)
                        .contentTransition(.numericText())
                        .monospacedDigit()
                }

                ZStack {
                    BatteryView(
                        levelBattery: levelBattery,
                        isPluggedIn: isPluggedIn,
                        isCharging: isCharging,
                        isInLowPowerMode: isInLowPowerMode,
                        batteryWidth: batteryWidth,
                        isForNotification: isForNotification
                    )
                    .opacity(showingAccessory ? 0 : 1)

                    if accessoryAvailable {
                        Image(systemName: headphoneBatteryModel.deviceKind.symbolName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(percentageColor)
                            .opacity(showingAccessory ? 1 : 0)
                    }
                }
                .frame(width: batteryWidth + 1, height: batteryWidth)
            }
            .animation(.easeInOut(duration: 0.3), value: showingAccessory)
            .animation(.easeInOut(duration: 0.3), value: displayedPercentage)
        }
        .buttonStyle(ScaleButtonStyle())
        // Ensure the whole indicator (not just opaque pixels) receives hover.
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringButton = hovering
            if !hovering {
                scheduleHideIfNeeded()
            } else {
                hideTask?.cancel()
                hideTask = nil
            }
        }
        .popover(
            isPresented: $showPopupMenu,
            arrowEdge: .bottom) {
            BatteryMenuView(
                isPluggedIn: isPluggedIn,
                isCharging: isCharging,
                levelBattery: levelBattery,
                maxCapacity: maxCapacity,
                timeToFullCharge: timeToFullCharge,
                timeToDischarge: timeToDischarge,
                isInLowPowerMode: isInLowPowerMode,
                accessoryConnected: accessoryAvailable,
                accessoryName: headphoneBatteryModel.deviceName,
                accessoryKind: headphoneBatteryModel.deviceKind,
                accessoryLevel: headphoneBatteryModel.headlineLevel,
                accessoryLeftLevel: headphoneBatteryModel.leftLevel,
                accessoryRightLevel: headphoneBatteryModel.rightLevel,
                accessoryCaseLevel: headphoneBatteryModel.caseLevel,
                accessoryHasDetailedLevels: headphoneBatteryModel.hasDetailedLevels,
                onDismiss: {
                    showPopupMenu = false
                }
            )
            .onHover { hovering in
                isHoveringPopover = hovering
                if hovering {
                    hideTask?.cancel()
                    hideTask = nil
                } else {
                    scheduleHideIfNeeded()
                }
            }
        }
        .onChange(of: showPopupMenu) {
            vm.isBatteryPopoverActive = showPopupMenu
        }
        .onAppear {
            resetTimerFace()
            restartSwapLoop()
        }
        .onChange(of: headphoneBatteryModel.isConnected) { _, _ in
            resetTimerFace()
            restartSwapLoop()
        }
        .onChange(of: showHeadphoneBattery) { _, _ in
            resetTimerFace()
            restartSwapLoop()
        }
        .onChange(of: displayMode) { _, _ in
            resetTimerFace()
            restartSwapLoop()
        }
        .onChange(of: swapInterval) { _, _ in
            restartSwapLoop()
        }
        .onDisappear {
            hideTask?.cancel()
            hideTask = nil
            swapTask?.cancel()
            swapTask = nil
        }
    }

    /// Percentage shown in the shared text slot (Mac level, or accessory while revealed).
    private var displayedPercentage: Int {
        showingAccessory ? headphoneBatteryModel.headlineLevel : Int(levelBattery)
    }

    private var percentageColor: Color {
        if showingAccessory && headphoneBatteryModel.headlineLevel <= 20 {
            return .red
        }
        return .white
    }

    /// Timer mode starts on the accessory face (issue #1387); hover mode ignores this flag.
    private func resetTimerFace() {
        timerShowsAccessory = accessoryAvailable && displayMode == .onTimer
    }

    /// (Re)starts the timer-mode swap loop. Uses `toggle()` so we never read a stale
    /// face value from a captured View copy. No-ops unless timer mode is active.
    private func restartSwapLoop() {
        swapTask?.cancel()
        guard shouldRunTimerSwap else {
            swapTask = nil
            return
        }

        let interval = max(1.0, swapInterval)
        swapTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    timerShowsAccessory.toggle()
                }
            }
        }
    }

    private func scheduleHideIfNeeded() {
        if isHoveringButton || isHoveringPopover { return }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { showPopupMenu = false } }
        }
    }
}

#Preview {
    BoringBatteryView(
        batteryWidth: 30,
        isCharging: false,
        isInLowPowerMode: false,
        isPluggedIn: true,
        levelBattery: 80,
        maxCapacity: 100,
        timeToFullCharge: 10,
        timeToDischarge: 10,
        isForNotification: false
    ).frame(width: 200, height: 200)
}
