//
//  TamagotchiState.swift
//  boringNotch
//
//  Created by Codex on 2026-04-16.
//

import Foundation

struct TamagotchiState: Codable {
    var hunger: Double
    var energy: Double
    var happiness: Double
    var lastUpdatedAt: Date
    var petName: String?

    static let valueRange: ClosedRange<Double> = 0...100

    static var initial: TamagotchiState {
        TamagotchiState(
            hunger: 80,
            energy: 75,
            happiness: 85,
            lastUpdatedAt: Date(),
            petName: nil
        )
    }

    var minimumMetric: Double {
        min(hunger, min(energy, happiness))
    }

    mutating func applyDecay(until now: Date) {
        guard now > lastUpdatedAt else { return }

        let elapsedHours = now.timeIntervalSince(lastUpdatedAt) / 3600
        guard elapsedHours > 0 else { return }

        hunger = (hunger - elapsedHours * TamagotchiTuning.hungerDecayPerHour).clamped(to: Self.valueRange)
        energy = (energy - elapsedHours * TamagotchiTuning.energyDecayPerHour).clamped(to: Self.valueRange)
        happiness = (happiness - elapsedHours * TamagotchiTuning.happinessDecayPerHour).clamped(to: Self.valueRange)
        lastUpdatedAt = now
    }
}

enum TamagotchiAction {
    case feed
    case play
    case rest
}

enum TamagotchiTuning {
    static let hungerDecayPerHour: Double = 8
    static let energyDecayPerHour: Double = 5
    static let happinessDecayPerHour: Double = 6

    static let feedHungerGain: Double = 25
    static let feedEnergyCost: Double = 5

    static let playHappinessGain: Double = 20
    static let playHungerCost: Double = 10
    static let playEnergyCost: Double = 10

    static let restEnergyGain: Double = 25
    static let restHappinessGain: Double = 5
}

extension TamagotchiState {
    mutating func applyAction(_ action: TamagotchiAction, at now: Date) {
        applyDecay(until: now)

        switch action {
        case .feed:
            hunger = (hunger + TamagotchiTuning.feedHungerGain).clamped(to: Self.valueRange)
            energy = (energy - TamagotchiTuning.feedEnergyCost).clamped(to: Self.valueRange)
        case .play:
            happiness = (happiness + TamagotchiTuning.playHappinessGain).clamped(to: Self.valueRange)
            hunger = (hunger - TamagotchiTuning.playHungerCost).clamped(to: Self.valueRange)
            energy = (energy - TamagotchiTuning.playEnergyCost).clamped(to: Self.valueRange)
        case .rest:
            energy = (energy + TamagotchiTuning.restEnergyGain).clamped(to: Self.valueRange)
            happiness = (happiness + TamagotchiTuning.restHappinessGain).clamped(to: Self.valueRange)
        }

        lastUpdatedAt = now
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
