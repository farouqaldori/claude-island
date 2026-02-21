#!/usr/bin/env python3
# /// script
# requires-python = ">=3.14"
# ///
"""Claude Island Hook - Session state bridge to ClaudeIsland.app.

Sends session state to ClaudeIsland.app via Unix socket.
For PermissionRequest events, waits for user decisions from the app.

Requires: Python 3.14+
"""


__all__ = [
    "HookEventData",
    "PermissionResponse",
    "SessionState",
    "SessionStateDict",
    "ToolExtras",
    "ToolInputType",
    "determine_status",
    "get_claude_pid",
    "get_remote_hostname",
    "get_remote_tmux_target",
    "get_tty",
    "handle_permission_response",
    "is_hook_event_data",
    "is_permission_response",
    "is_remote",
    "is_session_active",
    "main",
    "nats_publish",
    "nats_request",
    "send_event",
    "validate_tty",
]

import json
import os
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NotRequired, TypedDict, TypeIs, cast


# TypedDict definitions for JSON structures
class HookEventData(TypedDict, total=False):
    """Input data from Claude Code hook via stdin."""

    session_id: str
    hook_event_name: str
    cwd: str
    tool_name: str
    tool_input: dict[str, str | int | bool | list[str] | None]
    tool_use_id: str
    notification_type: str
    message: str


class ToolExtras(TypedDict, total=False):
    """Extra fields returned by determine_status()."""

    tool: str
    tool_input: dict[str, str | int | bool | list[str] | None]
    tool_use_id: str
    notification_type: str
    message: str


class PermissionResponse(TypedDict, total=False):
    """Response from ClaudeIsland.app for permission requests."""

    decision: str
    reason: str


class SessionStateDict(TypedDict):
    """Dictionary representation of SessionState for JSON serialization."""

    session_id: str
    cwd: str
    event: str
    pid: int
    tty: str | None
    tty_valid: bool
    session_active: bool
    status: str
    tool: NotRequired[str]
    tool_input: dict[str, str | int | bool | list[str] | None]  # Always included
    tool_use_id: NotRequired[str]
    notification_type: NotRequired[str]
    message: NotRequired[str]


ToolInputType = dict[str, str | int | bool | list[str] | None]

SOCKET_PATH = Path("/tmp/claude-island.sock")
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions
NATS_HOST = "localhost"
NATS_PORT = 4222
NATS_SUBJECT_STATE = "claude.island.state"
NATS_SUBJECT_PERMISSION = "claude.island.permission"


def is_remote():
    """Detect if running in a remote SSH session"""
    return bool(
        os.environ.get("SSH_CLIENT")
        or os.environ.get("SSH_TTY")
        or os.environ.get("SSH_CONNECTION")
    )


def nats_publish(subject, payload):
    """Publish a message via raw NATS protocol (no library needed)"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect((NATS_HOST, NATS_PORT))
        # Read server INFO
        s.recv(4096)
        # Send CONNECT
        s.sendall(b"CONNECT {}\r\n")
        # PUB subject length\r\npayload\r\n
        data = payload.encode("utf-8")
        s.sendall(f"PUB {subject} {len(data)}\r\n".encode())
        s.sendall(data + b"\r\n")
        s.sendall(b"PING\r\n")
        s.recv(4096)  # wait for PONG to ensure delivery
        s.close()
    except Exception:
        pass


def nats_request(subject, payload, timeout=300):
    """Send a NATS request and wait for reply (raw protocol, no library needed)"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((NATS_HOST, NATS_PORT))
        # Read server INFO
        s.recv(4096)
        # Send CONNECT
        s.sendall(b"CONNECT {}\r\n")
        # Subscribe to a unique inbox for the reply
        inbox = f"_INBOX.{os.getpid()}.{id(s)}"
        s.sendall(f"SUB {inbox} 1\r\n".encode())
        # PUB with reply-to
        data = payload.encode("utf-8")
        s.sendall(f"PUB {subject} {inbox} {len(data)}\r\n".encode())
        s.sendall(data + b"\r\n")
        s.sendall(b"PING\r\n")
        # Read until we get a MSG
        buf = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
            text = buf.decode("utf-8", errors="replace")
            if "MSG " in text:
                # Parse MSG inbox sid length\r\npayload\r\n
                lines = text.split("\r\n")
                for i, line in enumerate(lines):
                    if line.startswith("MSG "):
                        parts = line.split()
                        msg_len = int(parts[-1])
                        msg_payload = lines[i + 1][:msg_len]
                        s.close()
                        return json.loads(msg_payload)
        s.close()
    except Exception:
        pass
    return None


def get_remote_tmux_target():
    """Get tmux pane target on remote machine (only when in tmux)"""
    if not os.environ.get("TMUX"):
        return None
    # Use TMUX_PANE to get THIS pane's target, not the active pane
    tmux_pane = os.environ.get("TMUX_PANE")
    import subprocess
    try:
        cmd = ["tmux", "display-message", "-p",
               "#{session_name}:#{window_index}.#{pane_index}"]
        if tmux_pane:
            cmd = ["tmux", "display-message", "-t", tmux_pane, "-p",
                   "#{session_name}:#{window_index}.#{pane_index}"]
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=2,
        )
        target = result.stdout.strip()
        if target:
            return target
    except Exception:
        pass
    return None


def get_remote_hostname():
    """Get FQDN of remote machine"""
    import subprocess
    try:
        result = subprocess.run(
            ["hostname", "-f"], capture_output=True, text=True, timeout=2,
        )
        hostname = result.stdout.strip()
        if hostname:
            return hostname
    except Exception:
        pass
    return None


@dataclass(slots=True, frozen=True)
class SessionState:
    """Represents the state of a Claude Code session."""

    session_id: str
    cwd: str
    event: str
    pid: int
    tty: str | None
    tty_valid: bool = False
    session_active: bool = True
    status: str = "unknown"
    tool: str | None = None
    tool_input: ToolInputType = field(default_factory=dict)
    tool_use_id: str | None = None
    notification_type: str | None = None
    message: str | None = None

    def to_dict(self, /) -> SessionStateDict:
        """Convert to dictionary for JSON serialization."""
        result: SessionStateDict = {
            "session_id": self.session_id,
            "cwd": self.cwd,
            "event": self.event,
            "pid": self.pid,
            "tty": self.tty,
            "tty_valid": self.tty_valid,
            "session_active": self.session_active,
            "status": self.status,
            "tool_input": self.tool_input,  # Required field - include in literal
        }

        if self.tool is not None:
            result["tool"] = self.tool
        if self.tool_use_id is not None:
            result["tool_use_id"] = self.tool_use_id
        if self.notification_type is not None:
            result["notification_type"] = self.notification_type
        if self.message is not None:
            result["message"] = self.message

        return result


def validate_tty(tty: str | None, /) -> bool:
    """Validate that a TTY is still active and writable.

    Args:
        tty: The TTY path to validate (e.g., "/dev/ttys001")

    Returns:
        True if the TTY exists, is a character device, and is writable
    """
    if not tty:
        return False
    tty_path = Path(tty)
    try:
        return (
            tty_path.exists()
            and tty_path.is_char_device()
            and os.access(tty_path, os.W_OK)
        )
    except OSError:
        return False


def is_session_active(pid: int, tty: str | None, /) -> bool:
    """Check if the Claude Code session is still active.

    Combines PID existence check with TTY validation for robust detection.

    Args:
        pid: The process ID to check
        tty: The TTY path associated with the session

    Returns:
        True if the session appears active, False otherwise
    """
    # Check if process exists
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass  # Process exists but we lack permission to signal it

    # Validate TTY if available
    if tty and not validate_tty(tty):
        return False

    return True


def get_tty(ppid: int, /) -> str | None:
    """Get the TTY of the Claude process.

    Args:
        ppid: Parent process ID (Claude process)

    Returns:
        The TTY path (e.g., "/dev/ttys001") or None if unavailable
    """
    # Try to get TTY from ps command for the parent process
    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        if tty := result.stdout.strip():
            if tty not in ("??", "-"):
                # ps returns just "ttys001", we need "/dev/ttys001"
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
    except subprocess.TimeoutExpired, OSError:
        pass

    # Fallback: try current process stdin/stdout
    for fd in (sys.stdin, sys.stdout):
        try:
            return os.ttyname(fd.fileno())
        except OSError, AttributeError:
            continue

    return None


def get_claude_pid() -> int:
    """Walk process tree to find Claude Code process PID.

    When hooks are run via 'uv run', os.getppid() returns uv's PID,
    which exits after the hook completes. This causes the session
    to disappear since the stored PID becomes invalid.

    This function walks up the process tree to find the actual
    Claude Code process (identified by command name 'claude').

    Returns:
        The PID of the Claude Code process, or falls back to immediate parent.
    """
    current_pid = os.getpid()

    for _ in range(10):  # Max depth to prevent infinite loops
        try:
            result = subprocess.run(
                ["ps", "-p", str(current_pid), "-o", "ppid=,comm="],
                capture_output=True,
                text=True,
                timeout=2,
                check=False,
            )
            if result.returncode != 0:
                break

            parts = result.stdout.strip().split()
            if len(parts) < 2:
                break

            ppid = int(parts[0])
            command = parts[1].lower()

            # Claude Code process shows as 'claude' in ps output
            if command == "claude":
                return current_pid

            current_pid = ppid
        except subprocess.TimeoutExpired, ValueError, OSError:
            break

    # Fallback to immediate parent
    return os.getppid()


def _all_keys_are_strings(d: dict[object, object], /) -> bool:
    """Check if all keys in a dictionary are strings."""
    for key in d:
        if not isinstance(key, str):
            return False
    return True


def _normalize_tool_input(value: object, /) -> ToolInputType:
    """Normalize tool_input to an empty dict unless it's actually a dict.

    Handles cases where hook payload contains "tool_input": null or other
    malformed content, ensuring the Swift decoder always receives a valid dict.

    Args:
        value: The raw tool_input value from the hook payload

    Returns:
        The value if it's a dict with string keys, otherwise an empty dict
    """
    if isinstance(value, dict) and _all_keys_are_strings(
        cast(dict[object, object], value)
    ):
        return cast(ToolInputType, value)
    return {}


def is_hook_event_data(obj: object, /) -> TypeIs[HookEventData]:
    """Validate that obj is a valid HookEventData dictionary.

    Args:
        obj: Object to validate (typically from json.load)

    Returns:
        True if obj is a valid HookEventData, False otherwise
    """
    if not isinstance(obj, dict):
        return False
    # HookEventData is total=False, so all keys are optional
    # Just verify it's a dict with string keys
    return _all_keys_are_strings(cast(dict[object, object], obj))


def is_permission_response(obj: object, /) -> TypeIs[PermissionResponse]:
    """Validate that obj is a valid PermissionResponse dictionary.

    Validates that the object is a dict with string keys, and that if
    decision/reason fields are present, they are strings.

    Args:
        obj: Object to validate (typically from json.loads)

    Returns:
        True if obj is a valid PermissionResponse, False otherwise
    """
    if not isinstance(obj, dict):
        return False
    if not _all_keys_are_strings(cast(dict[object, object], obj)):
        return False
    # Validate decision and reason are strings if present
    if "decision" in obj and not isinstance(obj["decision"], str):
        return False
    if "reason" in obj and not isinstance(obj["reason"], str):
        return False
    return True


def send_event(state: SessionState, /) -> PermissionResponse | None:
    """Send event to app, return response if any.

    Args:
        state: The session state to send

    Returns:
        Response dictionary for permission requests, None otherwise
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(TIMEOUT_SECONDS)
            sock.connect(str(SOCKET_PATH))
            sock.sendall(json.dumps(state.to_dict()).encode())
            if state.status == "waiting_for_approval":
                if response := sock.recv(4096):
                    parsed = cast(object, json.loads(response.decode()))
                    if is_permission_response(parsed):
                        return parsed
            return None
    except OSError, json.JSONDecodeError:
        # Socket unavailable — fall back to NATS for remote sessions
        if is_remote():
            nats_publish(NATS_SUBJECT_STATE, json.dumps(state.to_dict()))
        return None


def determine_status(
    event: str,
    data: HookEventData,
    /,
) -> tuple[str, ToolExtras]:
    """Determine session status and extra fields from hook event.

    Uses pattern matching to dispatch on event type.

    Args:
        event: The hook event name
        data: The full event data dictionary

    Returns:
        Tuple of (status, extra_fields_dict)
    """
    match event:
        case "UserPromptSubmit":
            # User just sent a message - Claude is now processing
            return "processing", {}

        case "PreToolUse":
            extras: ToolExtras = {}
            if tool := data.get("tool_name"):
                extras["tool"] = tool
            extras["tool_input"] = _normalize_tool_input(data.get("tool_input"))
            if tool_use_id := data.get("tool_use_id"):
                extras["tool_use_id"] = tool_use_id
            return "running_tool", extras

        case "PostToolUse":
            extras_post: ToolExtras = {}
            if tool := data.get("tool_name"):
                extras_post["tool"] = tool
            extras_post["tool_input"] = _normalize_tool_input(data.get("tool_input"))
            if tool_use_id := data.get("tool_use_id"):
                extras_post["tool_use_id"] = tool_use_id
            return "processing", extras_post

        case "PermissionRequest":
            extras_perm: ToolExtras = {
                "tool_input": _normalize_tool_input(data.get("tool_input"))
            }
            if tool := data.get("tool_name"):
                extras_perm["tool"] = tool
            return "waiting_for_approval", extras_perm

        case "Notification":
            notification_type = data.get("notification_type")
            match notification_type:
                case "permission_prompt":
                    # Handled by PermissionRequest hook with better info
                    return "skip", {}
                case "idle_prompt":
                    extras_notif: ToolExtras = {}
                    if notification_type:
                        extras_notif["notification_type"] = notification_type
                    if msg := data.get("message"):
                        extras_notif["message"] = msg
                    return "waiting_for_input", extras_notif
                case _:
                    extras_other: ToolExtras = {}
                    if notification_type:
                        extras_other["notification_type"] = notification_type
                    if msg := data.get("message"):
                        extras_other["message"] = msg
                    return "notification", extras_other

        case "Stop":
            return "waiting_for_input", {}

        case "SubagentStop":
            # SubagentStop fires when a subagent completes - main session continues
            return "processing", {}

        case "SessionStart":
            # New session starts waiting for user input
            return "waiting_for_input", {}

        case "SessionEnd":
            return "ended", {}

        case "PreCompact":
            # Context is being compacted (manual or auto)
            return "compacting", {}

        case _:
            return "unknown", {}


def handle_permission_response(response: PermissionResponse | None, /) -> None:
    """Handle the permission response from ClaudeIsland.app.

    Args:
        response: The response dictionary from the app, or None
    """
    if not response:
        # No response or "ask" - let Claude Code show its normal UI
        return

    decision = response.get("decision", "ask")
    reason = response.get("reason", "")

    match decision:
        case "allow":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {"behavior": "allow"},
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case "deny":
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PermissionRequest",
                    "decision": {
                        "behavior": "deny",
                        "message": reason or "Denied by user via ClaudeIsland",
                    },
                }
            }
            print(json.dumps(output))
            sys.exit(0)

        case _decision:
            # "ask" or unknown - let Claude Code show its normal UI
            pass


def main() -> None:
    """Main entry point for the hook."""
    try:
        raw_data = cast(object, json.load(sys.stdin))
    except json.JSONDecodeError:
        sys.exit(1)

    if not is_hook_event_data(raw_data):
        sys.exit(1)
    data: HookEventData = raw_data

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")

    # Get process info
    claude_pid = get_claude_pid()
    tty = get_tty(claude_pid)

    # Validate session state
    tty_valid = validate_tty(tty)
    session_active = is_session_active(claude_pid, tty)

    # Determine status and extra fields
    status, extras = determine_status(event, data)

    # Skip certain events
    if status == "skip":
        sys.exit(0)

    # Build state object
    state = SessionState(
        session_id=session_id,
        cwd=cwd,
        event=event,
        pid=claude_pid,
        tty=tty,
        tty_valid=tty_valid,
        session_active=session_active,
        status=status,
        tool=extras.get("tool"),
        tool_input=_normalize_tool_input(extras.get("tool_input")),
        tool_use_id=extras.get("tool_use_id"),
        notification_type=extras.get("notification_type"),
        message=extras.get("message"),
    )

    # Handle permission requests specially
    if status == "waiting_for_approval":
        # Remote: use NATS request/reply for bidirectional approve/deny
        if is_remote():
            response_data = nats_request(
                NATS_SUBJECT_PERMISSION, json.dumps(state.to_dict())
            )
            if response_data and is_permission_response(response_data):
                handle_permission_response(response_data)
            sys.exit(0)
        else:
            response = send_event(state)
            handle_permission_response(response)
            sys.exit(0)

    # Add remote tmux info for state events (not permissions — those exit above)
    # Bridge uses these to create proxy tmux panes for remote sessions
    state_dict = state.to_dict()
    if is_remote() and os.environ.get("TMUX"):
        remote_target = get_remote_tmux_target()
        remote_hostname = get_remote_hostname()
        if remote_target:
            state_dict["remote_tmux_target"] = remote_target
        if remote_hostname:
            state_dict["remote_hostname"] = remote_hostname

    # Send to socket (fire and forget for non-permission events)
    # For remote sessions, send_event will fall back to NATS if socket unavailable
    _ = send_event(state)


if __name__ == "__main__":
    main()
