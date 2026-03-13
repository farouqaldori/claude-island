//
//  DebugFileLogger.swift
//  ClaudeIsland
//
//  Writes debug logs to a file for reliable inspection
//

import Foundation

enum DebugFileLogger {
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("claude-island-debug.log")

    static func log(_ message: String, file: String = #file, line: Int = #line) {
        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] [\(filename):\(line)] \(message)\n"

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        }
    }

    static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}
