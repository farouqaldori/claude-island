//
//  HookSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//
// swiftlint:disable file_length

import Foundation
import os.log
import Synchronization

// MARK: - SocketReconnectionManager

/// Manages exponential backoff retry logic for socket server creation
private actor SocketReconnectionManager {
    private var attempt = 0
    private let maxAttempts = 5
    private let baseDelay: Double = 0.5
    private let maxDelay: Double = 10.0

    /// Calculate the next delay with exponential backoff and jitter
    /// Returns nil if max attempts exceeded
    func nextDelay() -> Double? {
        guard attempt < maxAttempts else { return nil }
        attempt += 1
        let exponential = min(baseDelay * pow(2.0, Double(attempt - 1)), maxDelay)
        let jitter = Double.random(in: 0 ... 0.3) * exponential
        return exponential + jitter
    }

    /// Reset the retry counter (call on successful connection)
    func reset() {
        attempt = 0
    }

    /// Get current attempt count for logging
    var currentAttempt: Int { attempt }
}

// MARK: - HookEvent

/// Event received from Claude Code hooks
nonisolated struct HookEvent: Sendable {
    // MARK: Lifecycle

    /// Create a copy with updated toolUseID
    nonisolated init(
        sessionID: String,
        cwd: String,
        event: String,
        status: String,
        pid: Int?,
        tty: String?,
        tool: String?,
        toolInput: [String: JSONValue]?,
        toolUseID: String?,
        notificationType: String?,
        message: String?
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.notificationType = notificationType
        self.message = message
    }

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseID = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }

    let sessionID: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: JSONValue]?
    let toolUseID: String?
    let notificationType: String?
    let message: String?

    nonisolated var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        // Handle Notification events explicitly (aligned with determinePhase())
        if event == "Notification" {
            if notificationType == "idle_prompt" {
                return .waitingForInput
            }
            // Other notifications - session is still processing
            return .processing
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseID: toolUseID ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool",
             "processing",
             "starting":
            return .processing
        case "notification":
            // Explicit notification status - session is still active
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

// MARK: - HookEvent + Codable

nonisolated extension HookEvent: Codable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        cwd = try container.decode(String.self, forKey: .cwd)
        event = try container.decode(String.self, forKey: .event)
        status = try container.decode(String.self, forKey: .status)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        tty = try container.decodeIfPresent(String.self, forKey: .tty)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        toolInput = try container.decodeIfPresent([String: JSONValue].self, forKey: .toolInput)
        toolUseID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(event, forKey: .event)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(tty, forKey: .tty)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(toolUseID, forKey: .toolUseID)
        try container.encodeIfPresent(notificationType, forKey: .notificationType)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

// MARK: - HookResponse

/// Response to send back to the hook
nonisolated struct HookResponse: Sendable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

// MARK: - HookResponse + Codable

nonisolated extension HookResponse: Codable {
    enum CodingKeys: String, CodingKey {
        case decision, reason
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        decision = try container.decode(String.self, forKey: .decision)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(reason, forKey: .reason)
    }
}

// MARK: - PendingPermission

/// Pending permission request waiting for user decision
nonisolated struct PendingPermission: Sendable {
    let sessionID: String
    let toolUseID: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionID: String, _ toolUseID: String) -> Void

// MARK: - PermissionsState

/// State protected by permissions Mutex
private nonisolated struct PermissionsState: Sendable {
    var pendingPermissions: [String: PendingPermission] = [:]
    var respondedPermissions: Set<String> = []
}

// MARK: - CacheState

/// State protected by cache Mutex
private nonisolated struct CacheState: Sendable {
    var toolUseIDCache: [String: [String]] = [:]
}

// MARK: - HookSocketServer

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
/// `@unchecked Sendable` because queue-protected state requires manual synchronization.
/// Lock-protected state uses Mutex for proper Sendable conformance.
final class HookSocketServer: @unchecked Sendable { // swiftlint:disable:this type_body_length
    // MARK: Lifecycle

    private nonisolated init() {}

    // MARK: Internal

    nonisolated static let shared = HookSocketServer()
    nonisolated static let socketPath = "/tmp/claude-island.sock"

    /// Logger for hook socket server
    private nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Hooks")

    /// Start the socket server
    nonisolated func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    /// Stop the socket server
    nonisolated func stop() {
        // All state mutations must happen on the queue to avoid races
        queue.sync {
            // Mark as stopped to prevent pending retries from restarting
            isStopped = true

            // Cancel accept source if active
            if let source = acceptSource {
                source.cancel()
                acceptSource = nil
            }
        }
        unlink(Self.socketPath)

        // Clean up pending permissions - collect sockets outside the lock
        let socketsToClose = permissionsState.withLock { state -> [Int32] in
            let sockets = state.pendingPermissions.values.map(\.clientSocket)
            state.pendingPermissions.removeAll()
            return sockets
        }
        for socket in socketsToClose {
            close(socket)
        }
    }

    /// Respond to a pending permission request by toolUseID
    nonisolated func respondToPermission(toolUseID: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseID: toolUseID, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionID (finds the most recent pending for that session)
    nonisolated func respondToPermissionBySession(sessionID: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionID: sessionID, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    nonisolated func cancelPendingPermissions(sessionID: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionID: sessionID)
        }
    }

    /// Check if there's a pending permission request for a session
    nonisolated func hasPendingPermission(sessionID: String) -> Bool {
        permissionsState.withLock { state in
            state.pendingPermissions.values.contains { $0.sessionID == sessionID }
        }
    }

    /// Get the pending permission details for a session (if any)
    nonisolated func getPendingPermission(sessionID: String) -> (toolName: String?, toolID: String?, toolInput: [String: JSONValue]?)? {
        permissionsState.withLock { state -> (toolName: String?, toolID: String?, toolInput: [String: JSONValue]?)? in
            guard let pending = state.pendingPermissions.values.first(where: { $0.sessionID == sessionID }) else {
                return nil
            }
            return (pending.event.tool, pending.toolUseID, pending.event.toolInput)
        }
    }

    /// Cancel a specific pending permission by toolUseID (when tool completes via terminal approval)
    nonisolated func cancelPendingPermission(toolUseID: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseID: toolUseID)
        }
    }

    // MARK: Private

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private nonisolated static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Thread-safety model: This class uses a two-tier synchronization strategy.
    ///
    /// **Queue-protected state** (`nonisolated(unsafe)` properties below):
    /// `serverSocket`, `acceptSource`, `eventHandler`, `permissionFailureHandler`, and `isStopped`
    /// are accessed exclusively from the serial `queue`. These are coupled to DispatchSource-based
    /// I/O, which inherently requires a DispatchQueue. Using Mutex here would create pointless
    /// double-locking (Mutex inside serialized queue callbacks).
    ///
    /// **Mutex-protected state** (`permissionsState`, `cacheState`):
    /// These use `Mutex` because they are accessed from multiple contexts — both the serial queue
    /// and nonisolated call sites (e.g., `hasPendingPermission`, `getPendingPermission`). Mutex
    /// provides proper Sendable conformance for cross-context access without requiring queue hops.
    ///
    /// This hybrid approach is intentional: each synchronization primitive is used where it is
    /// the natural fit, avoiding unnecessary overhead in either direction. The `@unchecked Sendable`
    /// conformance is justified because all mutable state is protected by one of these two mechanisms.
    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var acceptSource: DispatchSourceRead?
    private nonisolated(unsafe) var eventHandler: HookEventHandler?
    private nonisolated(unsafe) var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.claudeisland.socket", qos: .userInitiated)
    private let reconnectionManager = SocketReconnectionManager()

    /// Explicit stopped state to prevent retries after stop() is called
    private nonisolated(unsafe) var isStopped = false

    /// Permissions and responded-permissions state protected by Mutex
    private let permissionsState = Mutex(PermissionsState())
    private let maxRespondedPermissions = 100

    /// Timeout for pending permission sockets (5 minutes)
    private let permissionTimeoutSeconds: TimeInterval = 300

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private let cacheState = Mutex(CacheState())

    private nonisolated func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        // Reset stopped state when explicitly starting
        isStopped = false

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        attemptServerStart()
    }

    private nonisolated func attemptServerStart() {
        // Check if stopped to prevent restarts after stop() was called
        guard !isStopped else {
            Self.logger.debug("Server start aborted - server has been stopped")
            return
        }

        // Clean up stale socket file before attempting
        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Self.logger.error("Failed to create socket: \(errno)")
            scheduleRetry()
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Self.logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            scheduleRetry()
            return
        }

        chmod(Self.socketPath, 0o777)

        guard listen(serverSocket, 10) == 0 else {
            Self.logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            scheduleRetry()
            return
        }

        // Success - reset retry counter
        Task(name: "reset-retry-counter") {
            await reconnectionManager.reset()
        }
        Self.logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    private nonisolated func scheduleRetry() {
        // Check if stopped before scheduling retry
        guard !isStopped else {
            Self.logger.debug("Retry aborted - server has been stopped")
            return
        }

        Task(name: "handle-client") { [weak self] in
            guard let self else { return }

            // Check again after Task starts in case stop() was called
            // Read isStopped directly on the queue without MainActor to avoid deadlock potential
            let stopped = self.queue.sync { self.isStopped }
            guard !stopped else {
                Self.logger.debug("Retry cancelled - server has been stopped")
                return
            }

            guard let delay = await reconnectionManager.nextDelay() else {
                let attempts = await reconnectionManager.currentAttempt
                Self.logger.error("Socket server failed after \(attempts) attempts - giving up")
                return
            }

            let attempt = await reconnectionManager.currentAttempt
            Self.logger.warning("Socket server failed, retrying in \(String(format: "%.1f", delay))s (attempt \(attempt))")

            try? await Task.sleep(for: .seconds(delay))

            // Final check after sleep before actually restarting
            let stoppedAfterSleep = self.queue.sync { self.isStopped }
            guard !stoppedAfterSleep else {
                Self.logger.debug("Retry cancelled after sleep - server has been stopped")
                return
            }

            queue.async { [weak self] in
                self?.attemptServerStart()
            }
        }
    }

    private nonisolated func cleanupSpecificPermission(toolUseID: String) {
        let pending = permissionsState.withLock { state -> PendingPermission? in
            guard let removed = state.pendingPermissions.removeValue(forKey: toolUseID) else {
                return nil
            }
            Self.markPermissionResponded(in: &state, toolUseID: toolUseID, maxCount: maxRespondedPermissions)
            return removed
        }

        guard let pending else { return }
        Self.logger
            .debug(
                "Tool completed externally, closing socket for \(pending.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)"
            )
        close(pending.clientSocket)
    }

    /// Mark a permission as responded to prevent duplicate responses
    /// Static helper that operates on state within the Mutex lock
    private nonisolated static func markPermissionResponded(in state: inout PermissionsState, toolUseID: String, maxCount: Int) {
        state.respondedPermissions.insert(toolUseID)

        // Bound the set size to prevent unbounded growth
        if state.respondedPermissions.count > maxCount {
            // Remove oldest entries (arbitrary since Set is unordered, but keeps size bounded)
            while state.respondedPermissions.count > maxCount / 2 {
                _ = state.respondedPermissions.removeFirst()
            }
        }
    }

    private nonisolated func cleanupPendingPermissions(sessionID: String) {
        let socketsToClose = permissionsState.withLock { state -> [(String, Int32)] in
            let matching = state.pendingPermissions.filter { $0.value.sessionID == sessionID }
            for (toolUseID, _) in matching {
                state.pendingPermissions.removeValue(forKey: toolUseID)
            }
            return matching.map { ($0.key, $0.value.clientSocket) }
        }

        for (toolUseID, socket) in socketsToClose {
            Self.logger.debug("Cleaning up stale permission for \(sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)")
            close(socket)
        }
    }

    /// Generate cache key from event properties
    private nonisolated func cacheKey(sessionID: String, toolName: String?, toolInput: [String: JSONValue]?) -> String {
        let inputStr: String = if let input = toolInput,
                                  let data = try? Self.sortedEncoder.encode(input),
                                  let str = String(data: data, encoding: .utf8) {
            str
        } else {
            "{}"
        }
        return "\(sessionID):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private nonisolated func cacheToolUseID(event: HookEvent) {
        guard let toolUseID = event.toolUseID else { return }

        let key = cacheKey(sessionID: event.sessionID, toolName: event.tool, toolInput: event.toolInput)

        cacheState.withLock { state in
            state.toolUseIDCache[key, default: []].append(toolUseID)
        }

        Self.logger
            .debug(
                "Cached tool_use_id for \(event.sessionID.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseID.prefix(12), privacy: .public)"
            )
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private nonisolated func popCachedToolUseID(event: HookEvent) -> String? {
        let key = cacheKey(sessionID: event.sessionID, toolName: event.tool, toolInput: event.toolInput)

        let toolUseID = cacheState.withLock { state -> String? in
            guard var queue = state.toolUseIDCache[key], !queue.isEmpty else {
                return nil
            }
            let id = queue.removeFirst()
            if queue.isEmpty {
                state.toolUseIDCache.removeValue(forKey: key)
            } else {
                state.toolUseIDCache[key] = queue
            }
            return id
        }

        if let toolUseID {
            Self.logger
                .debug(
                    "Retrieved cached tool_use_id for \(event.sessionID.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseID.prefix(12), privacy: .public)"
                )
        }
        return toolUseID
    }

    /// Clean up cache entries for a session (on session end)
    private nonisolated func cleanupCache(sessionID: String) {
        let removedCount = cacheState.withLock { state -> Int in
            let keysToRemove = state.toolUseIDCache.keys.filter { $0.hasPrefix("\(sessionID):") }
            for key in keysToRemove {
                state.toolUseIDCache.removeValue(forKey: key)
            }
            return keysToRemove.count
        }

        if removedCount > 0 {
            Self.logger.debug("Cleaned up \(removedCount) cache entries for session \(sessionID.prefix(8), privacy: .public)")
        }
    }

    private nonisolated func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private nonisolated func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        guard let data = readClientData(clientSocket: clientSocket) else {
            close(clientSocket)
            return
        }

        guard let event = parseHookEvent(from: data) else {
            close(clientSocket)
            return
        }

        processEventActions(event)

        if event.expectsResponse {
            handlePermissionRequest(event: event, clientSocket: clientSocket)
        } else {
            close(clientSocket)
            eventHandler?(event)
        }
    }

    private nonisolated func readClientData(clientSocket: Int32) -> Data? {
        var allData = Data()
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        // Use stack allocation for buffer to avoid heap allocation per read
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 131_072) { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            while Date().timeIntervalSince(startTime) < 0.5 {
                let pollResult = poll(&pollFd, 1, 50)

                if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                    let bytesRead = read(clientSocket, baseAddress, buffer.count)
                    if bytesRead > 0 {
                        allData.append(baseAddress, count: bytesRead)
                    } else if bytesRead == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                        break
                    }
                } else if pollResult == 0 && !allData.isEmpty {
                    break
                } else if pollResult != 0 {
                    break
                }
            }
        }

        return allData.isEmpty ? nil : allData
    }

    private nonisolated func parseHookEvent(from data: Data) -> HookEvent? {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            Self.logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            return nil
        }
        Self.logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionID.prefix(8), privacy: .public)")
        return event
    }

    private nonisolated func processEventActions(_ event: HookEvent) {
        if event.event == "PreToolUse" {
            cacheToolUseID(event: event)
        }
        if event.event == "SessionEnd" {
            cleanupCache(sessionID: event.sessionID)
        }
    }

    private nonisolated func handlePermissionRequest(event: HookEvent, clientSocket: Int32) {
        guard let toolUseID = resolveToolUseID(for: event) else {
            Self.logger.warning("Permission request missing tool_use_id for \(event.sessionID.prefix(8), privacy: .public) - no cache hit")
            close(clientSocket)
            eventHandler?(event)
            return
        }

        Self.logger.debug("Permission request - keeping socket open for \(event.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)")

        let updatedEvent = createUpdatedEvent(from: event, with: toolUseID)
        storePendingPermission(event: updatedEvent, toolUseID: toolUseID, clientSocket: clientSocket)
        eventHandler?(updatedEvent)
    }

    private nonisolated func resolveToolUseID(for event: HookEvent) -> String? {
        if let eventToolUseID = event.toolUseID {
            return eventToolUseID
        }
        return popCachedToolUseID(event: event)
    }

    private nonisolated func createUpdatedEvent(from event: HookEvent, with toolUseID: String) -> HookEvent {
        HookEvent(
            sessionID: event.sessionID,
            cwd: event.cwd,
            event: event.event,
            status: event.status,
            pid: event.pid,
            tty: event.tty,
            tool: event.tool,
            toolInput: event.toolInput,
            toolUseID: toolUseID,
            notificationType: event.notificationType,
            message: event.message
        )
    }

    private nonisolated func storePendingPermission(event: HookEvent, toolUseID: String, clientSocket: Int32) {
        let pending = PendingPermission(
            sessionID: event.sessionID,
            toolUseID: toolUseID,
            clientSocket: clientSocket,
            event: event,
            receivedAt: Date()
        )
        permissionsState.withLock { state in
            state.pendingPermissions[toolUseID] = pending
        }

        // Schedule timeout cleanup to prevent FD leak if Claude dies
        schedulePermissionTimeout(toolUseID: toolUseID, sessionID: event.sessionID)
    }

    private nonisolated func schedulePermissionTimeout(toolUseID: String, sessionID: String) {
        queue.asyncAfter(deadline: .now() + permissionTimeoutSeconds) { [weak self] in
            self?.cleanupTimedOutPermission(toolUseID: toolUseID, sessionID: sessionID)
        }
    }

    private nonisolated enum TimeoutResult {
        case notFound
        case wrongSession
        case notTimedOut
        case timedOut(pending: PendingPermission, age: TimeInterval)
    }

    private nonisolated func cleanupTimedOutPermission(toolUseID: String, sessionID: String) {
        let result = permissionsState.withLock { state -> TimeoutResult in
            guard let pending = state.pendingPermissions[toolUseID] else {
                // Already handled (approved/denied/cancelled)
                return .notFound
            }
            // Verify this is actually the same permission (not a reused toolUseID)
            guard pending.sessionID == sessionID else {
                return .wrongSession
            }
            // Check if it's actually timed out (could have been refreshed)
            let age = Date().timeIntervalSince(pending.receivedAt)
            guard age >= permissionTimeoutSeconds else {
                return .notTimedOut
            }
            state.pendingPermissions.removeValue(forKey: toolUseID)
            return .timedOut(pending: pending, age: age)
        }

        guard case let .timedOut(pending, age) = result else { return }
        Self.logger.warning("Permission timed out after \(Int(age))s for \(sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public)")
        close(pending.clientSocket)

        // Notify of failure
        permissionFailureHandler?(sessionID, toolUseID)
    }

    private nonisolated enum PermissionLookupResult {
        case alreadyResponded
        case notFound
        case found(pending: PendingPermission)
    }

    private nonisolated func sendPermissionResponse(toolUseID: String, decision: String, reason: String?) {
        let result = permissionsState.withLock { state -> PermissionLookupResult in
            // Check if already responded (race condition with terminal approval)
            if state.respondedPermissions.contains(toolUseID) {
                return .alreadyResponded
            }
            guard let pending = state.pendingPermissions.removeValue(forKey: toolUseID) else {
                return .notFound
            }
            Self.markPermissionResponded(in: &state, toolUseID: toolUseID, maxCount: maxRespondedPermissions)
            return .found(pending: pending)
        }

        switch result {
        case .alreadyResponded:
            Self.logger.debug("Permission already responded for toolUseId: \(toolUseID.prefix(12), privacy: .public) - skipping duplicate")
            return
        case .notFound:
            Self.logger.debug("No pending permission for toolUseId: \(toolUseID.prefix(12), privacy: .public)")
            return
        case let .found(pending):
            let response = HookResponse(decision: decision, reason: reason)
            guard let data = try? JSONEncoder().encode(response) else {
                close(pending.clientSocket)
                return
            }

            let age = Date().timeIntervalSince(pending.receivedAt)
            Self.logger
                .info(
                    "Sending response: \(decision, privacy: .public) for \(pending.sessionID.prefix(8), privacy: .public) tool:\(toolUseID.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
                )

            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    Self.logger.error("Failed to get data buffer address")
                    return
                }
                let writeResult = write(pending.clientSocket, baseAddress, data.count)
                if writeResult < 0 {
                    Self.logger.error("Write failed with errno: \(errno)")
                } else {
                    Self.logger.debug("Write succeeded: \(writeResult) bytes")
                }
            }

            close(pending.clientSocket)
        }
    }

    private nonisolated func sendPermissionResponseBySession(sessionID: String, decision: String, reason: String?) {
        let result = permissionsState.withLock { state -> PermissionLookupResult in
            let matchingPending = state.pendingPermissions.values
                .filter { $0.sessionID == sessionID }
                .max { $0.receivedAt < $1.receivedAt }

            guard let pending = matchingPending else {
                return .notFound
            }
            // Check if already responded (race condition with terminal approval)
            if state.respondedPermissions.contains(pending.toolUseID) {
                return .alreadyResponded
            }
            state.pendingPermissions.removeValue(forKey: pending.toolUseID)
            Self.markPermissionResponded(in: &state, toolUseID: pending.toolUseID, maxCount: maxRespondedPermissions)
            return .found(pending: pending)
        }

        switch result {
        case .notFound:
            Self.logger.debug("No pending permission for session: \(sessionID.prefix(8), privacy: .public)")
            return
        case .alreadyResponded:
            Self.logger.debug("Permission already responded for session: \(sessionID.prefix(8), privacy: .public) - skipping duplicate")
            return
        case let .found(pending):
            let response = HookResponse(decision: decision, reason: reason)
            guard let data = try? JSONEncoder().encode(response) else {
                close(pending.clientSocket)
                permissionFailureHandler?(sessionID, pending.toolUseID)
                return
            }

            let age = Date().timeIntervalSince(pending.receivedAt)
            Self.logger
                .info(
                    "Sending response: \(decision, privacy: .public) for \(sessionID.prefix(8), privacy: .public) tool:\(pending.toolUseID.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)"
                )

            var writeSuccess = false
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    Self.logger.error("Failed to get data buffer address")
                    return
                }
                let writeResult = write(pending.clientSocket, baseAddress, data.count)
                if writeResult < 0 {
                    Self.logger.error("Write failed with errno: \(errno)")
                } else {
                    Self.logger.debug("Write succeeded: \(writeResult) bytes")
                    writeSuccess = true
                }
            }

            close(pending.clientSocket)

            if !writeSuccess {
                permissionFailureHandler?(sessionID, pending.toolUseID)
            }
        }
    }
}
