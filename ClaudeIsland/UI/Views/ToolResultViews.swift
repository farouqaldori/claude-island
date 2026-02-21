//
//  ToolResultViews.swift
//  ClaudeIsland
//
//  Individual views for rendering each tool's result with proper formatting
//

import SwiftUI

// swiftlint:disable file_length

// MARK: - ToolResultContent

struct ToolResultContent: View {
    let tool: ToolCallItem

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case let .read(result):
                ReadResultContent(result: result)
            case let .edit(result):
                EditResultContent(result: result, toolInput: self.tool.input)
            case let .write(result):
                WriteResultContent(result: result)
            case let .bash(result):
                BashResultContent(result: result)
            case let .grep(result):
                GrepResultContent(result: result)
            case let .glob(result):
                GlobResultContent(result: result)
            case let .todoWrite(result):
                TodoWriteResultContent(result: result)
            case let .task(result):
                TaskResultContent(result: result)
            case let .webFetch(result):
                WebFetchResultContent(result: result)
            case let .webSearch(result):
                WebSearchResultContent(result: result)
            case let .askUserQuestion(result):
                AskUserQuestionResultContent(result: result)
            case let .bashOutput(result):
                BashOutputResultContent(result: result)
            case let .killShell(result):
                KillShellResultContent(result: result)
            case let .exitPlanMode(result):
                ExitPlanModeResultContent(result: result)
            case let .mcp(result):
                MCPResultContent(result: result)
            case let .generic(result):
                GenericResultContent(result: result)
            }
        } else if self.tool.name == "Edit" {
            // Special fallback for Edit - show diff from input params
            EditInputDiffView(input: self.tool.input)
        } else if let result = tool.result {
            // Fallback to raw text display
            GenericTextContent(text: result)
        } else {
            EmptyView()
        }
    }
}

// MARK: - EditInputDiffView

struct EditInputDiffView: View {
    // MARK: Internal

    let input: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Show diff from input with integrated filename
            if !self.oldString.isEmpty || !self.newString.isEmpty {
                SimpleDiffView(oldString: self.oldString, newString: self.newString, filename: self.filename)
            }
        }
    }

    // MARK: Private

    private var filename: String {
        if let path = input["file_path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    private var oldString: String {
        self.input["old_string"] ?? ""
    }

    private var newString: String {
        self.input["new_string"] ?? ""
    }
}

// MARK: - ReadResultContent

struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        if !self.result.content.isEmpty {
            FileCodeView(
                filename: self.result.filename,
                content: self.result.content,
                startLine: self.result.startLine,
                totalLines: self.result.totalLines,
                maxLines: 10,
            )
        }
    }
}

// MARK: - EditResultContent

struct EditResultContent: View {
    // MARK: Internal

    let result: EditResult
    var toolInput: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always use SimpleDiffView for consistent styling (no @@ headers)
            if !self.oldString.isEmpty || !self.newString.isEmpty {
                SimpleDiffView(oldString: self.oldString, newString: self.newString, filename: self.result.filename)
            }

            if self.result.userModified {
                Text("(User modified)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
            }
        }
    }

    // MARK: Private

    /// Get old string - prefer result, fallback to input
    private var oldString: String {
        if !self.result.oldString.isEmpty {
            return self.result.oldString
        }
        return self.toolInput["old_string"] ?? ""
    }

    /// Get new string - prefer result, fallback to input
    private var newString: String {
        if !self.result.newString.isEmpty {
            return self.result.newString
        }
        return self.toolInput["new_string"] ?? ""
    }
}

// MARK: - WriteResultContent

struct WriteResultContent: View {
    let result: WriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Action and filename
            HStack(spacing: 4) {
                Text(self.result.type == .create ? "Created" : "Wrote")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text(self.result.filename)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            // Content preview for new files
            if self.result.type == .create && !self.result.content.isEmpty {
                CodePreview(content: self.result.content, maxLines: 8)
            } else if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches)
            }
        }
    }
}

// MARK: - BashResultContent

struct BashResultContent: View {
    let result: BashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background task indicator
            if let bgID = result.backgroundTaskID {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("Background task: \(bgID)")
                        .font(.system(size: 10, design: .monospaced))
                }
                .foregroundColor(.blue.opacity(0.7))
            }

            // Return code interpretation
            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            // Stdout
            if !self.result.stdout.isEmpty {
                CodePreview(content: self.result.stdout, maxLines: 15)
            }

            // Stderr (shown in red)
            if !self.result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stderr:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red.opacity(0.7))
                    Text(self.result.stderr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(10)
                }
            }

            // Empty state
            if !self.result.hasOutput && self.result.backgroundTaskID == nil && self.result.returnCodeInterpretation == nil {
                Text("(No content)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - GrepResultContent

struct GrepResultContent: View {
    let result: GrepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch self.result.mode {
            case .filesWithMatches:
                // Show file list
                if self.result.filenames.isEmpty {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                } else {
                    FileListView(files: self.result.filenames, limit: 10)
                }

            case .content:
                // Show matching content
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text("No matches found")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                }

            case .count:
                Text("\(self.result.numFiles) files with matches")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - GlobResultContent

struct GlobResultContent: View {
    let result: GlobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.result.filenames.isEmpty {
                Text("No files found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                FileListView(files: self.result.filenames, limit: 10)

                if self.result.truncated {
                    Text("... and more (truncated)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - TodoWriteResultContent

struct TodoWriteResultContent: View {
    // MARK: Internal

    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(self.result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: self.todoIcon(for: todo.status))
                        .font(.system(size: 10))
                        .foregroundColor(self.todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(todo.status == "completed" ? 0.4 : 0.7))
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    // MARK: Private

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": .green.opacity(0.7)
        case "in_progress": .orange.opacity(0.7)
        default: .white.opacity(0.4)
        }
    }
}

// MARK: - TaskResultContent

struct TaskResultContent: View {
    // MARK: Internal

    let result: TaskResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status and stats
            HStack(spacing: 8) {
                Text(self.result.status.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(self.statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(self.formatDuration(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                if let tools = result.totalToolUseCount {
                    Text("\(tools) tools")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Content summary
            if !self.result.content.isEmpty {
                Text(self.result.content.prefix(200) + (self.result.content.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(5)
            }
        }
    }

    // MARK: Private

    private var statusColor: Color {
        switch self.result.status {
        case "completed": .green.opacity(0.7)
        case "in_progress": .orange.opacity(0.7)
        case "failed",
             "error": .red.opacity(0.7)
        default: .white.opacity(0.5)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return "\(ms / 60000)m \((ms % 60000) / 1000)s"
        } else if ms >= 1000 {
            return "\(ms / 1000)s"
        }
        return "\(ms)ms"
    }
}

// MARK: - WebFetchResultContent

struct WebFetchResultContent: View {
    // MARK: Internal

    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL and status
            HStack(spacing: 6) {
                Text("\(self.result.code)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(self.result.code < 400 ? .green.opacity(0.7) : .red.opacity(0.7))

                Text(self.truncateURL(self.result.url))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }

            // Result summary
            if !self.result.result.isEmpty {
                Text(self.result.result.prefix(300) + (self.result.result.count > 300 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(8)
            }
        }
    }

    // MARK: Private

    private func truncateURL(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

// MARK: - WebSearchResultContent

struct WebSearchResultContent: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.result.results.isEmpty {
                Text("No results found")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                ForEach(Array(self.result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue.opacity(0.8))
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(2)
                        }
                    }
                }

                if self.result.results.count > 5 {
                    Text("... and \(self.result.results.count - 5) more results")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - AskUserQuestionResultContent

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(self.result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    // Question
                    Text(question.question)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))

                    // Answer
                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                            Text(answer)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.green.opacity(0.7))
                    }
                }
            }
        }
    }
}

// MARK: - BashOutputResultContent

struct BashOutputResultContent: View {
    let result: BashOutputResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Text("Status: \(self.result.status)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                if let exitCode = result.exitCode {
                    Text("Exit: \(exitCode)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(exitCode == 0 ? .green.opacity(0.6) : .red.opacity(0.6))
                }
            }

            // Output
            if !self.result.stdout.isEmpty {
                CodePreview(content: self.result.stdout, maxLines: 10)
            }

            if !self.result.stderr.isEmpty {
                Text(self.result.stderr)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(5)
            }
        }
    }
}

// MARK: - KillShellResultContent

struct KillShellResultContent: View {
    let result: KillShellResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red.opacity(0.6))

            Text(self.result.message.isEmpty ? "Shell \(self.result.shellID) terminated" : self.result.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - ExitPlanModeResultContent

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.white.opacity(0.6))
            }

            if let plan = result.plan, !plan.isEmpty {
                Text(plan.prefix(200) + (plan.count > 200 ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(6)
            }
        }
    }
}

// MARK: - MCPResultContent

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Server and tool info (formatted as Title Case)
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .font(.system(size: 10))
                Text("\(MCPToolFormatter.toTitleCase(self.result.serverName)) - \(MCPToolFormatter.toTitleCase(self.result.toolName))")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(.purple.opacity(0.7))

            // Raw result (formatted as key-value pairs)
            ForEach(Array(self.result.rawResultEntries.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Text("\(value.prefix(100))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - GenericResultContent

struct GenericResultContent: View {
    let result: GenericResult

    var body: some View {
        if let content = result.rawContent, !content.isEmpty {
            GenericTextContent(text: content)
        } else {
            Text("Completed")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
        }
    }
}

// MARK: - GenericTextContent

struct GenericTextContent: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
            .lineLimit(15)
    }
}

// MARK: - FileCodeView

/// File code view with filename header and line numbers (matches Edit tool styling)
struct FileCodeView: View {
    // MARK: Internal

    let filename: String
    let content: String
    let startLine: Int
    let totalLines: Int
    let maxLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Text(self.filename)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))

            // Top overflow indicator
            if self.hasLinesBefore {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
            }

            // Code lines with line numbers
            ForEach(Array(self.displayLines.enumerated()), id: \.offset) { index, line in
                let lineNumber = self.startLine + index
                let isLast = index == self.displayLines.count - 1 && !self.hasMoreAfter
                CodeLineView(
                    line: line,
                    lineNumber: lineNumber,
                    isLast: isLast,
                )
            }

            // Bottom overflow indicator
            if self.hasMoreAfter {
                Text("... (\(self.lines.count - self.maxLines) more lines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
            }
        }
    }

    // MARK: Private

    private struct CodeLineView: View {
        let line: String
        let lineNumber: Int
        let isLast: Bool

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(self.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content
                Text(self.line.isEmpty ? " " : self.line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedCorner(radius: 6, corners: self.isLast ? [.bottomLeft, .bottomRight] : []))
        }
    }

    private var lines: [String] {
        self.content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        Array(self.lines.prefix(self.maxLines))
    }

    private var hasMoreAfter: Bool {
        self.lines.count > self.maxLines
    }

    private var hasLinesBefore: Bool {
        self.startLine > 1
    }
}

// MARK: - CodePreview

struct CodePreview: View {
    let content: String
    let maxLines: Int

    var body: some View {
        let lines = self.content.components(separatedBy: "\n")
        let displayLines = Array(lines.prefix(self.maxLines))
        let hasMore = lines.count > self.maxLines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }

            if hasMore {
                Text("... (\(lines.count - self.maxLines) more lines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - FileListView

struct FileListView: View {
    let files: [String]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(self.files.prefix(self.limit).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                    Text(URL(fileURLWithPath: file).lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            if self.files.count > self.limit {
                Text("... and \(self.files.count - self.limit) more files")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - DiffView

struct DiffView: View {
    let patches: [PatchHunk]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(self.patches.prefix(3).enumerated()), id: \.offset) { _, patch in
                VStack(alignment: .leading, spacing: 1) {
                    // Hunk header
                    Text("@@ -\(patch.oldStart),\(patch.oldLines) +\(patch.newStart),\(patch.newLines) @@")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.7))

                    // Lines
                    ForEach(Array(patch.lines.prefix(10).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }

                    if patch.lines.count > 10 {
                        Text("... (\(patch.lines.count - 10) more lines)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
            }

            if self.patches.count > 3 {
                Text("... and \(self.patches.count - 3) more hunks")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - DiffLineView

struct DiffLineView: View {
    // MARK: Internal

    let line: String

    var body: some View {
        Text(self.line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(self.lineType.textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(self.lineType.backgroundColor)
    }

    // MARK: Private

    private var lineType: DiffLineType {
        if self.line.hasPrefix("+") {
            return .added
        } else if self.line.hasPrefix("-") {
            return .removed
        }
        return .context
    }
}

// MARK: - DiffLineType

private enum DiffLineType {
    case added
    case removed
    case context

    // MARK: Internal

    var textColor: Color {
        switch self {
        case .added: Color(red: 0.4, green: 0.8, blue: 0.4)
        case .removed: Color(red: 0.9, green: 0.5, blue: 0.5)
        case .context: .white.opacity(0.5)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .added: Color(red: 0.2, green: 0.4, blue: 0.2).opacity(0.3)
        case .removed: Color(red: 0.4, green: 0.2, blue: 0.2).opacity(0.3)
        case .context: .clear
        }
    }
}

// MARK: - SimpleDiffView

struct SimpleDiffView: View {
    // MARK: Internal

    let oldString: String
    let newString: String
    var filename: String?

    var body: some View {
        // Compute diff once per render pass (LCS is expensive)
        let diff = self.computeDiffResult()
        let diffLines = diff.lines
        let hasMoreChanges = diff.hasMore
        let hasLinesBefore = diffLines.first.map { $0.lineNumber > 1 } ?? false

        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight] as RoundedCorner.RectCorner))
            }

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(
                        radius: 6,
                        corners: self.filename == nil ? [.topLeft, .topRight] as RoundedCorner.RectCorner : [] as RoundedCorner.RectCorner,
                    ))
            }

            // Diff lines
            ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                let isFirst = index == 0 && self.filename == nil && !hasLinesBefore
                let isLast = index == diffLines.count - 1 && !hasMoreChanges
                DiffLineView(
                    line: line.text,
                    type: line.type,
                    lineNumber: line.lineNumber,
                    isFirst: isFirst,
                    isLast: isLast,
                )
            }

            // Bottom overflow indicator
            if hasMoreChanges {
                Text("...")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight] as RoundedCorner.RectCorner))
            }
        }
    }

    // MARK: Private

    private struct DiffLine {
        let text: String
        let type: DiffLineType
        let lineNumber: Int
    }

    /// Cached diff computation result to avoid redundant LCS calculations
    private struct DiffResult {
        let lines: [DiffLine]
        let hasMore: Bool
        let totalChanges: Int
    }

    private struct DiffLineView: View {
        // MARK: Internal

        let line: String
        let type: DiffLineType
        let lineNumber: Int
        let isFirst: Bool
        let isLast: Bool

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(self.lineNumber)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(self.type.textColor.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 4)

                // +/- indicator
                Text(self.type == .added ? "+" : "-")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(self.type.textColor)
                    .frame(width: 14)

                // Line content
                Text(self.line.isEmpty ? " " : self.line)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(self.type.textColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(self.type.backgroundColor)
            .clipShape(RoundedCorner(radius: 6, corners: self.corners))
        }

        // MARK: Private

        private var corners: RoundedCorner.RectCorner {
            if self.isFirst && self.isLast {
                return .allCorners
            } else if self.isFirst {
                return [.topLeft, .topRight]
            } else if self.isLast {
                return [.bottomLeft, .bottomRight]
            }
            return []
        }
    }

    /// Compute Longest Common Subsequence using space-optimized DP
    /// Uses O(min(n,m)) space instead of O(n*m) by keeping only two rows
    private static func computeLCS(_ oldLines: [String], _ newLines: [String]) -> [String] {
        let rowCount = oldLines.count
        let colCount = newLines.count

        // Early exit for empty inputs
        guard rowCount > 0, colCount > 0 else { return [] }

        // Space-optimized: only keep current and previous row
        // Pre-allocate both rows
        var prev = [Int](repeating: 0, count: colCount + 1)
        var curr = [Int](repeating: 0, count: colCount + 1)

        // Also track which elements are in LCS for backtracking
        // Using a direction matrix for backtracking (0 = diagonal, 1 = up, 2 = left)
        var directions = [[UInt8]](repeating: [UInt8](repeating: 0, count: colCount + 1), count: rowCount + 1)

        for idx in 1 ... rowCount {
            for jdx in 1 ... colCount {
                if oldLines[idx - 1] == newLines[jdx - 1] {
                    curr[jdx] = prev[jdx - 1] + 1
                    directions[idx][jdx] = 0 // diagonal
                } else if prev[jdx] > curr[jdx - 1] {
                    curr[jdx] = prev[jdx]
                    directions[idx][jdx] = 1 // up
                } else {
                    curr[jdx] = curr[jdx - 1]
                    directions[idx][jdx] = 2 // left
                }
            }
            swap(&prev, &curr)
            // Reset curr for next iteration
            for jdx in 0 ... colCount {
                curr[jdx] = 0
            }
        }

        // Backtrack using direction matrix
        var lcs: [String] = []
        lcs.reserveCapacity(prev[colCount])
        var row = rowCount
        var col = colCount
        while row > 0 && col > 0 {
            switch directions[row][col] {
            case 0: // diagonal - match
                lcs.append(oldLines[row - 1])
                row -= 1
                col -= 1
            case 1: // up
                row -= 1
            default: // left
                col -= 1
            }
        }

        return lcs.reversed()
    }

    /// Compute diff using LCS algorithm - call once per render pass
    private func computeDiffResult() -> DiffResult {
        let oldLines = self.oldString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = self.newString.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Compute LCS once
        let lcs = Self.computeLCS(oldLines, newLines)
        let totalChanges = (oldLines.count - lcs.count) + (newLines.count - lcs.count)

        // Build diff lines (max 12)
        var result: [DiffLine] = []
        result.reserveCapacity(min(12, totalChanges))

        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            if result.count >= 12 { break }

            let lcsLine = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            if oldIdx < oldLines.count && (lcsLine == nil || oldLines[oldIdx] != lcsLine) {
                result.append(DiffLine(text: oldLines[oldIdx], type: .removed, lineNumber: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < newLines.count && (lcsLine == nil || newLines[newIdx] != lcsLine) {
                result.append(DiffLine(text: newLines[newIdx], type: .added, lineNumber: newIdx + 1))
                newIdx += 1
            } else {
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            }
        }

        return DiffResult(lines: result, hasMore: totalChanges > 12, totalChanges: totalChanges)
    }
}

// MARK: - RoundedCorner

/// Helper for selective corner rounding (macOS compatible)
struct RoundedCorner: Shape {
    struct RectCorner: OptionSet {
        static let topLeft = Self(rawValue: 1 << 0)
        static let topRight = Self(rawValue: 1 << 1)
        static let bottomLeft = Self(rawValue: 1 << 2)
        static let bottomRight = Self(rawValue: 1 << 3)
        static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]

        let rawValue: Int
    }

    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = self.corners.contains(.topLeft) ? self.radius : 0
        let tr = self.corners.contains(.topRight) ? self.radius : 0
        let bl = self.corners.contains(.bottomLeft) ? self.radius : 0
        let br = self.corners.contains(.bottomRight) ? self.radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                radius: tr,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false,
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                radius: br,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false,
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                radius: bl,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false,
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                radius: tl,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false,
            )
        }
        path.closeSubpath()

        return path
    }
}
