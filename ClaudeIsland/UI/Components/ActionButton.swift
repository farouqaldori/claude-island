//
//  ActionButton.swift
//  ClaudeIsland
//
//  Reusable action button component
//

import SwiftUI

struct ActionButton: View {
    // MARK: Internal

    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 5) {
                Image(systemName: self.icon)
                    .font(.system(size: 9, weight: .bold))
                Text(self.title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .foregroundColor(self.isHovered ? .black : self.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovered ? self.color : self.color.opacity(0.15)),
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(self.color.opacity(0.3), lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}
