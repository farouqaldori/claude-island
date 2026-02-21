//
//  ProcessingSpinner.swift
//  ClaudeIsland
//
//  Animated symbol spinner for processing state
//

import SwiftUI

struct ProcessingSpinner: View {
    // MARK: Internal

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.15) % self.symbols.count
            Text(self.symbols[phase])
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(self.color)
                .frame(width: 12, alignment: .center)
        }
    }

    // MARK: Private

    private let symbols = ["·", "✢", "✳", "∗", "✻", "✽"]
    private let color = Color(red: 0.85, green: 0.47, blue: 0.34) // Claude orange
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
