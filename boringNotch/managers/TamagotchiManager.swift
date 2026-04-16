//
//  TamagotchiManager.swift
//  boringNotch
//
//  Created by Codex on 2026-04-16.
//

import Defaults
import Foundation

@MainActor
final class TamagotchiManager: ObservableObject {
    static let shared = TamagotchiManager()

    @Published private(set) var baseState: TamagotchiState

    private init() {
        baseState = Self.loadState() ?? .initial
    }

    func currentState(at now: Date = Date()) -> TamagotchiState {
        var state = baseState
        state.applyDecay(until: now)
        return state
    }

    func perform(_ action: TamagotchiAction, at now: Date = Date()) {
        var state = baseState
        state.applyAction(action, at: now)
        baseState = state
        persistState()
    }

    func refreshBaseState(at now: Date = Date()) {
        var state = baseState
        state.applyDecay(until: now)
        baseState = state
        persistState()
    }

    private func persistState() {
        do {
            Defaults[.tamagotchiStateData] = try JSONEncoder().encode(baseState)
        } catch {
            NSLog("Failed to persist Tamagotchi state: \(error.localizedDescription)")
        }
    }

    private static func loadState() -> TamagotchiState? {
        guard let data = Defaults[.tamagotchiStateData] else { return nil }
        return try? JSONDecoder().decode(TamagotchiState.self, from: data)
    }
}
