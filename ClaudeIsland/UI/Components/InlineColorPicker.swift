//
//  InlineColorPicker.swift
//  ClaudeIsland
//
//  Inline HSB color picker for Clawd customization
//

import SwiftUI

// MARK: - InlineColorPicker

struct InlineColorPicker: View {
    // MARK: Internal

    @Binding var selectedColor: Color

    var body: some View {
        VStack(spacing: 8) {
            HueSlider(hue: self.$hue)
                .frame(height: 12)

            SaturationBrightnessPlane(
                hue: self.hue,
                saturation: self.$saturation,
                brightness: self.$brightness,
            )
            .frame(height: 100)
            .cornerRadius(6)

            HStack {
                Text("Hex:")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                Text("#\(self.selectedColor.hexString)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }
        }
        .onChange(of: self.hue) { _, _ in
            self.updateColorFromHSB()
        }
        .onChange(of: self.saturation) { _, _ in
            self.updateColorFromHSB()
        }
        .onChange(of: self.brightness) { _, _ in
            self.updateColorFromHSB()
        }
        .onChange(of: self.selectedColor) { _, newColor in
            if !self.isUpdatingFromColor {
                self.syncFromColor(newColor)
            }
        }
        .onAppear {
            self.syncFromColor(self.selectedColor)
        }
    }

    // MARK: Private

    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var brightness: Double = 1
    @State private var isUpdatingFromColor = false

    private func syncFromColor(_ color: Color) {
        let hsb = color.hsbComponents
        self.hue = hsb.hue
        self.saturation = hsb.saturation
        self.brightness = hsb.brightness
    }

    private func updateColorFromHSB() {
        self.isUpdatingFromColor = true
        self.selectedColor = Color(hue: self.hue, saturation: self.saturation, brightness: self.brightness)
        // Defer flag reset to next run loop iteration to prevent onChange feedback loops
        Task(name: "color-update-reset") { @MainActor in
            self.isUpdatingFromColor = false
        }
    }
}

// MARK: - HueSlider

struct HueSlider: View {
    // MARK: Internal

    @Binding var hue: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                LinearGradient(
                    gradient: Gradient(colors: self.hueGradientColors),
                    startPoint: .leading,
                    endPoint: .trailing,
                )
                .cornerRadius(6)

                Circle()
                    .fill(Color(hue: self.hue, saturation: 1, brightness: 1))
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2),
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .offset(x: self.thumbOffset(for: geometry.size.width))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.updateHue(from: value.location.x, width: geometry.size.width)
                    },
            )
        }
    }

    // MARK: Private

    private var hueGradientColors: [Color] {
        (0 ... 12).map { Color(hue: Double($0) / 12.0, saturation: 1, brightness: 1) }
    }

    private func thumbOffset(for width: CGFloat) -> CGFloat {
        let thumbRadius: CGFloat = 7
        let usableWidth = width - thumbRadius * 2
        return self.hue * usableWidth
    }

    private func updateHue(from x: CGFloat, width: CGFloat) {
        let thumbRadius: CGFloat = 7
        let usableWidth = width - thumbRadius * 2
        let clampedX = max(0, min(x - thumbRadius, usableWidth))
        self.hue = clampedX / usableWidth
    }
}

// MARK: - SaturationBrightnessPlane

struct SaturationBrightnessPlane: View {
    // MARK: Internal

    let hue: Double

    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [.white, Color(hue: self.hue, saturation: 1, brightness: 1)]),
                    startPoint: .leading,
                    endPoint: .trailing,
                )

                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black]),
                    startPoint: .top,
                    endPoint: .bottom,
                )

                Circle()
                    .fill(Color(hue: self.hue, saturation: self.saturation, brightness: self.brightness))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2),
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .position(self.thumbPosition(for: geometry.size))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        self.updateSaturationBrightness(from: value.location, size: geometry.size)
                    },
            )
        }
    }

    // MARK: Private

    private func thumbPosition(for size: CGSize) -> CGPoint {
        let thumbRadius: CGFloat = 8
        let insetWidth = size.width - thumbRadius * 2
        let insetHeight = size.height - thumbRadius * 2
        let x = thumbRadius + self.saturation * insetWidth
        let y = thumbRadius + (1 - self.brightness) * insetHeight
        return CGPoint(x: x, y: y)
    }

    private func updateSaturationBrightness(from location: CGPoint, size: CGSize) {
        let thumbRadius: CGFloat = 8
        let insetWidth = size.width - thumbRadius * 2
        let insetHeight = size.height - thumbRadius * 2
        let clampedX = max(0, min(location.x - thumbRadius, insetWidth))
        let clampedY = max(0, min(location.y - thumbRadius, insetHeight))

        self.saturation = clampedX / insetWidth
        self.brightness = 1 - (clampedY / insetHeight)
    }
}
