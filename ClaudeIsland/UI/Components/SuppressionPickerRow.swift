//
//  SuppressionPickerRow.swift
//  ClaudeIsland
//
//  Sound suppression selection picker for settings menu
//

import SwiftUI

// MARK: - SuppressionPickerRow

struct SuppressionPickerRow: View {
    // MARK: Internal

    /// SuppressionSelector is @Observable, so SwiftUI automatically tracks property access
    var suppressionSelector: SuppressionSelector

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.setExpanded(!self.isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 12))
                        .foregroundColor(self.textColor)
                        .frame(width: 16)

                    Text("Sound Suppression")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(self.textColor)

                    Spacer()

                    Text(self.selectedSuppression.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered ? Color.white.opacity(0.08) : Color.clear),
                )
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            // Expanded suppression list
            if self.isExpanded {
                VStack(spacing: 2) {
                    ForEach(SoundSuppression.allCases, id: \.self) { suppression in
                        SuppressionOptionRowInline(
                            suppression: suppression,
                            isSelected: self.selectedSuppression == suppression,
                        ) {
                            self.selectedSuppression = suppression
                            AppSettings.soundSuppression = suppression
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            self.selectedSuppression = AppSettings.soundSuppression
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var selectedSuppression: SoundSuppression = AppSettings.soundSuppression

    private var isExpanded: Bool {
        self.suppressionSelector.isPickerExpanded
    }

    private var textColor: Color {
        .white.opacity(self.isHovered ? 1.0 : 0.7)
    }

    private func setExpanded(_ value: Bool) {
        self.suppressionSelector.isPickerExpanded = value
    }
}

// MARK: - SuppressionOptionRowInline

private struct SuppressionOptionRowInline: View {
    // MARK: Internal

    let suppression: SoundSuppression
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(self.suppression.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(self.isHovered ? 1.0 : 0.7))

                    Text(self.suppression.description)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(2)
                }

                Spacer()

                if self.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isHovered ? Color.white.opacity(0.06) : Color.clear),
            )
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}
