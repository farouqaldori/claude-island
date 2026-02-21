//
//  ClawdPickerRow.swift
//  ClaudeIsland
//
//  Clawd customization picker for settings menu
//

import SwiftUI

// MARK: - ClawdPickerRow

struct ClawdPickerRow: View {
    // MARK: Internal

    var clawdSelector: ClawdSelector

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.setExpanded(!self.isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    ClaudeCrabIcon(size: 12, color: self.selectedColor)

                    Text("Clawd")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(self.textColor)

                    Spacer()

                    Circle()
                        .fill(self.selectedColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 1),
                        )

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

            if self.isExpanded {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ClaudeCrabIcon(size: 24, color: self.selectedColor, animateLegs: true)
                            .padding(.leading, 4)

                        ForEach(self.colorOptions, id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            self.selectedColor.hexString == color.hexString
                                                ? Color.white : Color.clear, lineWidth: 2,
                                        ),
                                )
                                .onTapGesture {
                                    self.selectedColor = color
                                    AppSettings.clawdColor = color
                                }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)

                    InlineColorPicker(selectedColor: self.$selectedColor)
                        .padding(.top, 4)

                    Divider()
                        .background(Color.white.opacity(0.08))

                    Button {
                        self.alwaysVisible.toggle()
                        AppSettings.clawdAlwaysVisible = self.alwaysVisible
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "eye")
                                .font(.system(size: 12))
                                .foregroundColor(self.alwaysVisibleTextColor)
                                .frame(width: 16)

                            Text("Always Visible")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(self.alwaysVisibleTextColor)

                            Spacer()

                            Circle()
                                .fill(self.alwaysVisible ? TerminalColors.green : Color.white.opacity(0.3))
                                .frame(width: 6, height: 6)

                            Text(self.alwaysVisible ? "On" : "Off")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 0)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(self.isAlwaysVisibleHovered ? Color.white.opacity(0.06) : Color.clear),
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { self.isAlwaysVisibleHovered = $0 }
                }
                .padding(.leading, 28)
                .padding(.trailing, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            self.selectedColor = AppSettings.clawdColor
            self.alwaysVisible = AppSettings.clawdAlwaysVisible
        }
        .onChange(of: self.selectedColor) { _, newValue in
            AppSettings.clawdColor = newValue
        }
    }

    // MARK: Private

    @State private var isHovered = false
    @State private var isAlwaysVisibleHovered = false
    @State private var selectedColor: Color = AppSettings.clawdColor
    @State private var alwaysVisible: Bool = AppSettings.clawdAlwaysVisible

    private let colorOptions: [Color] = [
        TerminalColors.prompt,
        TerminalColors.green,
        TerminalColors.blue,
        TerminalColors.amber,
        TerminalColors.cyan,
        TerminalColors.magenta,
        TerminalColors.red,
        Color.white,
    ]

    private var isExpanded: Bool {
        self.clawdSelector.isColorPickerExpanded
    }

    private var textColor: Color {
        .white.opacity(self.isHovered ? 1.0 : 0.7)
    }

    private var alwaysVisibleTextColor: Color {
        .white.opacity(self.isAlwaysVisibleHovered ? 1.0 : 0.7)
    }

    private func setExpanded(_ value: Bool) {
        self.clawdSelector.isColorPickerExpanded = value
    }
}
