//
//  SessionMetadataManager.swift
//  ClaudeIsland
//
//  Persists custom session metadata (colors, names) to UserDefaults
//

import SwiftUI

@Observable
final class SessionMetadataManager {
    // MARK: Lifecycle

    private init() {
        self.loadFromDefaults()
    }

    // MARK: Internal

    static let shared = SessionMetadataManager()

    private(set) var sessionColors: [String: String] = [:]
    private(set) var sessionNames: [String: String] = [:]

    func color(for sessionID: String) -> Color? {
        guard let hex = sessionColors[sessionID] else { return nil }
        return Color(hex: hex)
    }

    func name(for sessionID: String) -> String? {
        self.sessionNames[sessionID]
    }

    func setColor(_ hex: String?, for sessionID: String) {
        if let hex {
            self.sessionColors[sessionID] = hex
        } else {
            self.sessionColors.removeValue(forKey: sessionID)
        }
        self.saveColors()
    }

    func setName(_ name: String?, for sessionID: String) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            self.sessionNames[sessionID] = name
        } else {
            self.sessionNames.removeValue(forKey: sessionID)
        }
        self.saveNames()
    }

    func clearMetadata(for sessionID: String) {
        self.sessionColors.removeValue(forKey: sessionID)
        self.sessionNames.removeValue(forKey: sessionID)
        self.saveColors()
        self.saveNames()
    }

    // MARK: Private

    private let defaults = UserDefaults.standard
    private let colorsKey = "sessionColors"
    private let namesKey = "sessionNames"

    private func loadFromDefaults() {
        if let colorsData = defaults.data(forKey: colorsKey),
           let colors = try? JSONDecoder().decode([String: String].self, from: colorsData) {
            self.sessionColors = colors
        }

        if let namesData = defaults.data(forKey: namesKey),
           let names = try? JSONDecoder().decode([String: String].self, from: namesData) {
            self.sessionNames = names
        }
    }

    private func saveColors() {
        if let data = try? JSONEncoder().encode(sessionColors) {
            self.defaults.set(data, forKey: self.colorsKey)
        }
    }

    private func saveNames() {
        if let data = try? JSONEncoder().encode(sessionNames) {
            self.defaults.set(data, forKey: self.namesKey)
        }
    }
}
