//
//  SuppressionPickerRow.swift
//  ClaudeIsland
//
//  Sound suppression mode selection picker for settings menu
//

import SwiftUI

struct SuppressionPickerRow: View {
    @ObservedObject var suppressionSelector: SuppressionSelector
    @State private var isHovered = false
    @State private var selectedSuppression: SoundSuppression = AppSettings.soundSuppression

    private var isExpanded: Bool {
        suppressionSelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        suppressionSelector.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Sound Suppression")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selectedSuppression.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded suppression list
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(SoundSuppression.allCases, id: \.self) { suppression in
                        SuppressionOptionRow(
                            suppression: suppression,
                            isSelected: selectedSuppression == suppression
                        ) {
                            selectedSuppression = suppression
                            AppSettings.soundSuppression = suppression
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedSuppression = AppSettings.soundSuppression
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }
}

// MARK: - Suppression Option Row

private struct SuppressionOptionRow: View {
    let suppression: SoundSuppression
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suppression.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Text(suppression.description)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
