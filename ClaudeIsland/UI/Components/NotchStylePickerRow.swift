//
//  NotchStylePickerRow.swift
//  ClaudeIsland
//
//  Notch style selection for settings menu
//

import SwiftUI

struct NotchStylePickerRow: View {
    @ObservedObject var notchStyleSelector: NotchStyleSelector
    @State private var selectedStyle: NotchStyle = AppSettings.notchStyle
    @State private var isHovered = false

    private var isExpanded: Bool {
        notchStyleSelector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        notchStyleSelector.isPickerExpanded = value
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
                    Image(systemName: "rectangle.topthird.inset.filled")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Notch Style")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(currentSelectionLabel)
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

            // Expanded style list
            if isExpanded {
                VStack(spacing: 2) {
                    NotchStyleOptionRow(
                        style: .default,
                        isSelected: selectedStyle == .default
                    ) {
                        selectStyle(.default)
                    }

                    NotchStyleOptionRow(
                        style: .neat,
                        isSelected: selectedStyle == .neat
                    ) {
                        selectStyle(.neat)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedStyle = AppSettings.notchStyle
        }
    }

    private var currentSelectionLabel: String {
        switch selectedStyle {
        case .default:
            return "Default"
        case .neat:
            return "Neat"
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private func selectStyle(_ style: NotchStyle) {
        selectedStyle = style
        AppSettings.notchStyle = style
        NotificationCenter.default.post(name: .notchStyleChanged, object: nil)
        collapseAfterDelay()
    }

    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                setExpanded(false)
            }
        }
    }
}

// MARK: - Notch Style Option Row

private struct NotchStyleOptionRow: View {
    let style: NotchStyle
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(style.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                    Text(style.sublabel)
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
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
