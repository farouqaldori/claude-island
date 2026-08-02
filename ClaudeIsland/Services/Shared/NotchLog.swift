//
//  NotchLog.swift
//  ClaudeIsland
//
//  Plain-text log for things worth inspecting after the fact — mainly the
//  keystrokes sent to a tmux picker, which fail silently when they land in
//  the wrong pane. `log show` can't be read over the user's shoulder while
//  a picker is stuck; a file can.
//

import Foundation

enum NotchLog {
    /// ~/Library/Logs/VibeNotch/vibe-notch.log
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/VibeNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vibe-notch.log")
    }()

    private static let queue = DispatchQueue(label: "com.claudeisland.notchlog")
    private static let maxBytes = 2 * 1024 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Fixed locale/calendar: the user's own calendar (e.g. Hijri) would
        // otherwise make timestamps hard to line up with anything else
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Append one line. `category` groups related entries, e.g. "answer".
    static func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let url = fileURL

            // ponytail: truncate rather than rotate — the tail is what matters
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > maxBytes {
                try? FileManager.default.removeItem(at: url)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
