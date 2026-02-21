//
//  SessionLabelEditor.swift
//  ClaudeIsland
//
//  Inline editor for session color and name customization
//

import SwiftUI

struct SessionLabelEditor: View {
    // MARK: Internal

    static let colorPresets: [String] = [
        "EF4444", // red
        "F97316", // orange
        "EAB308", // yellow
        "22C55E", // green
        "3B82F6", // blue
        "8B5CF6", // purple
        "EC4899", // pink
    ]

    let sessionID: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.colorPresets, id: \.self) { hex in
                self.colorDot(hex: hex)
            }

            Spacer()

            self.clearButton
        }
    }

    // MARK: Private

    private let metadataManager = SessionMetadataManager.shared

    private var clearButton: some View {
        Button {
            self.metadataManager.setColor(nil, for: self.sessionID)
        } label: {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.4)),
                )
        }
        .buttonStyle(.plain)
    }

    private func colorDot(hex: String) -> some View {
        let currentHex = self.metadataManager.sessionColors[self.sessionID]
        let isSelected = currentHex == hex

        return Button {
            self.metadataManager.setColor(hex, for: self.sessionID)
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .gray)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: isSelected ? 2 : 0),
                )
        }
        .buttonStyle(.plain)
    }
}
