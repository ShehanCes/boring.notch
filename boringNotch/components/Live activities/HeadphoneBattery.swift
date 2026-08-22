import SwiftUI

/// Compact accessory battery chrome used for previews / isolated layout checks.
/// The live notch indicator inlines the same idea inside `BoringBatteryView` so the
/// Mac percentage slot and icon slot stay fixed while values crossfade.
struct HeadphoneBatteryView: View {

    var deviceKind: HeadphoneDeviceKind
    var headlineLevel: Int

    private var batteryColor: Color {
        headlineLevel <= 20 ? .red : .white
    }

    var body: some View {
        // Same order as the Mac indicator: percentage, then icon.
        HStack(spacing: 4) {
            Text("\(headlineLevel)%")
                .font(.callout)
                .foregroundStyle(batteryColor)
                .monospacedDigit()

            Image(systemName: deviceKind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(batteryColor)
                .frame(width: 27, height: 26)
        }
    }
}

#Preview {
    HeadphoneBatteryView(deviceKind: .airPodsPro, headlineLevel: 72)
        .frame(width: 200, height: 200)
        .preferredColorScheme(.dark)
}
