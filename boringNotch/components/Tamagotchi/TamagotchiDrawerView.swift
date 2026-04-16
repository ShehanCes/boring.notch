//
//  TamagotchiDrawerView.swift
//  boringNotch
//
//  Created by Codex on 2026-04-16.
//

import SwiftUI

struct TamagotchiDrawerView: View {
    @ObservedObject private var tamagotchiManager = TamagotchiManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = tamagotchiManager.currentState(at: context.date)

            VStack(alignment: .leading, spacing: 10) {
                TamagotchiView(state: state) { action in
                    tamagotchiManager.perform(action, at: Date())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onDisappear {
            tamagotchiManager.refreshBaseState(at: Date())
        }
    }
}

#Preview {
    TamagotchiDrawerView()
        .frame(width: 380, height: 180)
        .background(.black)
}
