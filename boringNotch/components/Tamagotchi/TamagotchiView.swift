//
//  TamagotchiView.swift
//  boringNotch
//

import AppKit
import SwiftUI

// MARK: - Sprite Sheet Layout
//
// Sheet: 256 × 320 px  |  Cell: 32 × 32 px  |  Grid: 8 cols × 10 rows
//
// Row | Frames | Behaviour
//  0  |   4    | idle sit
//  1  |   4    | idle stand
//  2  |   4    | crouch A
//  3  |   4    | crouch B
//  4  |   8    | happy walk
//  5  |   8    | run / excited
//  6  |   4    | sleep
//  7  |   6    | eat
//  8  |   7    | play / jump
//  9  |   8    | run burst

private enum CatAnimation: Int, Equatable {
    case idleSit   = 0
    case idleStand = 1
    case crouchA   = 2
    case crouchB   = 3
    case happyWalk = 4
    case run       = 5
    case sleep     = 6
    case eat       = 7
    case play      = 8
    case runBurst  = 9
}

// MARK: - Sprite sheet slicer

private enum CatSpriteSheet {
    static let cellWidth  = 32
    static let cellHeight = 32
    static let rows       = 10
    static let frameCounts: [Int] = [4, 4, 4, 4, 8, 8, 4, 6, 7, 8]

    static let frames: [[NSImage]] = slice()

    private static func slice() -> [[NSImage]] {
        guard let sheet = NSImage(named: "CatSpriteSheet") else { return [] }
        let sheetH = sheet.size.height

        return (0..<rows).map { row in
            let count = frameCounts[safe: row] ?? 0
            let nsY = sheetH - CGFloat(row + 1) * CGFloat(cellHeight)

            return (0..<count).compactMap { col in
                let srcRect = NSRect(
                    x: CGFloat(col * cellWidth),
                    y: nsY,
                    width: CGFloat(cellWidth),
                    height: CGFloat(cellHeight)
                )
                let frame = NSImage(size: srcRect.size)
                frame.lockFocus()
                sheet.draw(
                    in: NSRect(origin: .zero, size: srcRect.size),
                    from: srcRect,
                    operation: .copy,
                    fraction: 1.0,
                    respectFlipped: true,
                    hints: nil
                )
                frame.unlockFocus()
                return frame
            }
        }
    }
}

// MARK: - Animated sprite view

private struct CatSpriteView: View {
    let animation: CatAnimation
    let fps: Double

    @State private var frameIndex: Int = 0

    private var frames: [NSImage] {
        CatSpriteSheet.frames[safe: animation.rawValue] ?? []
    }

    var body: some View {
        Group {
            if let frame = frames[safe: frameIndex] {
                Image(nsImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                MinimalFaceFeatures(height: 18, width: 22)
            }
        }
        .onAppear { frameIndex = 0 }
        .onChange(of: animation) { frameIndex = 0 }
        .onReceive(
            Timer.publish(every: max(0.04, 1.0 / fps), on: .main, in: .common).autoconnect()
        ) { _ in
            guard frames.count > 1 else { return }
            frameIndex = (frameIndex + 1) % frames.count
        }
    }
}

// MARK: - Main card view

struct TamagotchiView: View {
    let state: TamagotchiState
    let onAction: (TamagotchiAction) -> Void

    @State private var actionAnimation: CatAnimation?
    @State private var actionResetTask: Task<Void, Never>?
    @State private var playRunTask: Task<Void, Never>?

    @State private var runOffset: CGFloat = 0
    @State private var playOverlayActive = false
    @State private var runCycleID = 0

    private static let catPanelSize: CGFloat = 92
    private static let catRunSize: CGFloat = 64

    private var catStartX: CGFloat {
        (Self.catPanelSize - Self.catRunSize) / 2
    }

    private var catRunY: CGFloat {
        (Self.catPanelSize - Self.catRunSize) / 2
    }

    private var activeAnimation: CatAnimation {
        if let actionAnimation { return actionAnimation }
        switch state.minimumMetric {
        case ..<30:
            return .sleep
        default:
            return .idleSit
        }
    }

    private var activeAnimationFPS: Double {
        switch activeAnimation {
        case .sleep:
            return 3.0
        case .eat:
            return 5.0
        default:
            return 5.0
        }
    }

    private var moodText: String {
        switch state.minimumMetric {
        case ..<30:  return Strings.needsCare
        case ..<65:  return Strings.doingOkay
        default:     return Strings.happy
        }
    }

    private var moodBadgeText: String {
        switch state.minimumMetric {
        case ..<30:  return Strings.low
        case ..<65:  return Strings.medium
        default:     return Strings.high
        }
    }

    private var moodBadgeColor: Color {
        switch state.minimumMetric {
        case ..<30:  return .red
        case ..<65:  return .yellow
        default:     return .effectiveAccent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topSection
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().opacity(0.08)

            actionsSection
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.82))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                }
        )
        .onDisappear {
            actionResetTask?.cancel()
            actionResetTask = nil
            playRunTask?.cancel()
            playRunTask = nil
            playOverlayActive = false
            runOffset = catStartX
        }
    }

    @ViewBuilder
    private var topSection: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: Self.catPanelSize, height: Self.catPanelSize)

                    CatSpriteView(animation: activeAnimation, fps: activeAnimationFPS)
                        .frame(width: Self.catPanelSize - 12, height: Self.catPanelSize - 12)
                        .scaleEffect(1.16)
                        .opacity(playOverlayActive ? 0 : 1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Strings.title)
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)

                            Text(moodText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(moodBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(moodBadgeColor.opacity(0.28))
                            )
                    }

                    VStack(spacing: 10) {
                        TamagotchiMetricRow(label: Strings.hunger, symbol: "carrot.fill", value: state.hunger)
                        TamagotchiMetricRow(label: Strings.energy, symbol: "bolt.fill", value: state.energy)
                        TamagotchiMetricRow(label: Strings.happiness, symbol: "sparkles", value: state.happiness)
                    }
                }
            }

            if playOverlayActive {
                GeometryReader { geo in
                    CatSpriteView(animation: .runBurst, fps: 8.5)
                        .frame(width: Self.catRunSize, height: Self.catRunSize)
                        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
                        .offset(x: runOffset, y: catRunY)
                        .id(runCycleID)
                        .onAppear {
                            startRunLoop(trackWidth: geo.size.width)
                        }
                        .onChange(of: geo.size.width) { width in
                            startRunLoop(trackWidth: width)
                        }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var actionsSection: some View {
        HStack(spacing: 8) {
            actionButton(title: Strings.feed, icon: "carrot.fill") {
                triggerAction(.feed, animation: .eat)
            }
            actionButton(title: Strings.play, icon: "sparkles") {
                triggerAction(.play, animation: .play)
            }
            actionButton(title: Strings.rest, icon: "moon.fill") {
                triggerAction(.rest, animation: .sleep)
            }
        }
    }

    private func startRunLoop(trackWidth: CGFloat) {
        let catWidth = Self.catRunSize
        runOffset = catStartX

        withAnimation(
            .linear(duration: max(1.6, trackWidth / 170))
            .repeatForever(autoreverses: false)
        ) {
            runOffset = trackWidth + catWidth
        }
    }

    private func triggerPlayRunOverlay() {
        playRunTask?.cancel()
        runCycleID += 1

        withAnimation(.easeInOut(duration: 0.2)) {
            playOverlayActive = true
        }

        playRunTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.4))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                playOverlayActive = false
            }
            runOffset = catStartX
        }
    }

    private func triggerAction(_ action: TamagotchiAction, animation: CatAnimation) {
        onAction(action)

        if action == .play {
            actionResetTask?.cancel()
            actionAnimation = nil
            triggerPlayRunOverlay()
            return
        }

        withAnimation(.smooth(duration: 0.25)) {
            actionAnimation = animation
        }

        let frameCount = CatSpriteSheet.frameCounts[safe: animation.rawValue] ?? 4
        let duration = max(2.8, Double(frameCount) / activeAnimationFPS * 3.3)

        actionResetTask?.cancel()
        actionResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { actionAnimation = nil }
        }
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(.white)
            .background(Capsule(style: .continuous).fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Metric row

private struct TamagotchiMetricRow: View {
    let label: String
    let symbol: String
    let value: Double

    private var normalizedValue: Double { min(max(value / 100.0, 0), 1) }

    private var barColor: Color {
        switch value {
        case ..<30:  return .red
        case ..<60:  return .yellow
        default:     return .effectiveAccent
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * normalizedValue)
                        .animation(.smooth(duration: 0.3), value: normalizedValue)
                }
            }
            .frame(height: 8)

            Text("\(Int(value.rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

// MARK: - Localized strings

private enum Strings {
    static let title      = localized("tamagotchi_title",           fallback: "Companion")
    static let hunger     = localized("tamagotchi_hunger",          fallback: "Hunger")
    static let energy     = localized("tamagotchi_energy",          fallback: "Energy")
    static let happiness  = localized("tamagotchi_happiness",       fallback: "Happiness")
    static let feed       = localized("tamagotchi_feed",            fallback: "Feed")
    static let play       = localized("tamagotchi_play",            fallback: "Play")
    static let rest       = localized("tamagotchi_rest",            fallback: "Rest")
    static let needsCare  = localized("tamagotchi_mood_needs_care", fallback: "Needs care")
    static let doingOkay  = localized("tamagotchi_mood_doing_okay", fallback: "Doing okay")
    static let happy      = localized("tamagotchi_mood_happy",      fallback: "Happy")
    static let low        = localized("tamagotchi_mood_low",        fallback: "Low")
    static let medium     = localized("tamagotchi_mood_medium",     fallback: "Medium")
    static let high       = localized("tamagotchi_mood_high",       fallback: "High")

    private static func localized(_ key: String, fallback: String) -> String {
        let s = NSLocalizedString(key, comment: "")
        return s == key ? fallback : s
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
