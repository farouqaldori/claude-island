#!/usr/bin/env python3
"""
NATS → Claude Island bridge

Subscribes to NATS subjects and forwards events to Claude Island's Unix socket.
Also writes local transcript .jsonl files for remote sessions.

Features:
- No message rate limits (local NATS server)
- Supports request/reply for remote PermissionRequest (approve/deny)
- Manages tmux proxy panes per remote session (for message relay)
- Parses ~/.ssh/config for hostname → SSH alias resolution

Requires: pip install nats-py

Usage:
  nats-bridge.py start   # run in foreground
  nats-bridge.py stop    # stop the daemon
  nats-bridge.py status  # check if running
"""
import asyncio
import glob as glob_mod
import json
import os
import shutil
import signal
import socket as sock
import subprocess
import sys
import time
import uuid as uuid_mod
from datetime import datetime, timezone

NATS_URL = "nats://localhost:4222"
SUBJECT_STATE = "claude.island.state"
SUBJECT_PERMISSION = "claude.island.permission"
SOCKET_PATH = "/tmp/claude-island.sock"
PID_FILE = "/tmp/nats-bridge.pid"
CLAUDE_PROJECTS = os.path.expanduser("~/.claude/projects")

PROXY_SESSION = "claude-nats-proxy"
PROXY_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nats-proxy-pane.py")
TMUX_BIN = shutil.which("tmux") or "/opt/homebrew/bin/tmux"

# Track parent UUIDs per session for transcript chaining
last_uuid = {}

# Proxy pane state: session_id -> {"remote_target": str, "ssh_host": str, "tty": str, "pid": int, "window": str}
proxy_panes = {}

# SSH HostName -> alias mapping (cached at startup)
ssh_hostname_map = {}

# SSH_AUTH_SOCK from user's tmux (cached at startup)
user_ssh_auth_sock = None


def cwd_to_project_dir(cwd):
    """Match Claude Island's ConversationParser.sessionFilePath() exactly"""
    return cwd.replace("/", "-").replace(".", "-")


def get_transcript_path(state):
    cwd = state.get("cwd", "/tmp")
    session_id = state.get("session_id", "unknown")
    project_dir = os.path.join(CLAUDE_PROJECTS, cwd_to_project_dir(cwd))
    os.makedirs(project_dir, exist_ok=True)
    return os.path.join(project_dir, f"{session_id}.jsonl")


def append_entry(transcript_path, entry):
    """Compact JSON — Claude Island matches 'line.contains(\"type\":\"user\")'"""
    with open(transcript_path, "a") as f:
        f.write(json.dumps(entry, separators=(",", ":")) + "\n")


def write_transcript(state, transcript_path):
    session_id = state.get("session_id", "unknown")
    cwd = state.get("cwd", "/tmp")
    event = state.get("event", "")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    wrote = False

    # Only write user-facing messages (user prompts + final assistant text)
    if event == "UserPromptSubmit":
        user_prompt = state.get("user_prompt", "") or "(remote session)"
        msg_uuid = str(uuid_mod.uuid4())
        append_entry(transcript_path, {
            "parentUuid": last_uuid.get(session_id),
            "isSidechain": False,
            "userType": "external",
            "cwd": cwd,
            "sessionId": session_id,
            "version": "remote-bridge",
            "type": "user",
            "uuid": msg_uuid,
            "timestamp": now,
            "message": {"content": user_prompt},
        })
        last_uuid[session_id] = msg_uuid
        wrote = True

    elif event == "Stop":
        message_text = state.get("last_assistant_message", "")
        if message_text:
            msg_uuid = str(uuid_mod.uuid4())
            append_entry(transcript_path, {
                "parentUuid": last_uuid.get(session_id),
                "isSidechain": False,
                "userType": "external",
                "cwd": cwd,
                "sessionId": session_id,
                "version": "remote-bridge",
                "type": "assistant",
                "uuid": msg_uuid,
                "timestamp": now,
                "message": {
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "text", "text": message_text}],
                },
            })
            last_uuid[session_id] = msg_uuid
            wrote = True

    return wrote


def parse_ssh_config():
    """Parse ~/.ssh/config to build HostName → SSH alias mapping"""
    ssh_dir = os.path.expanduser("~/.ssh")
    mapping = {}

    def parse_file(path):
        try:
            with open(path) as f:
                lines = f.readlines()
        except FileNotFoundError:
            return

        current_host = None
        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            key_val = stripped.split(None, 1)
            if len(key_val) < 2:
                continue
            key, val = key_val[0].lower(), key_val[1]

            if key == "include":
                pattern = val if os.path.isabs(val) else os.path.join(ssh_dir, val)
                for included in sorted(glob_mod.glob(pattern)):
                    parse_file(included)
            elif key == "host":
                hosts = val.split()
                current_host = hosts[0] if hosts and "*" not in hosts[0] and "?" not in hosts[0] else None
            elif key == "hostname" and current_host:
                mapping[val] = current_host

    parse_file(os.path.join(ssh_dir, "config"))
    return mapping


def resolve_ssh_host(remote_hostname):
    """Resolve a remote hostname to an SSH alias from config"""
    if not remote_hostname:
        return None
    # Exact match
    if remote_hostname in ssh_hostname_map:
        return ssh_hostname_map[remote_hostname]
    # Prefix match (hostname without domain vs FQDN in config)
    for config_hostname, alias in ssh_hostname_map.items():
        if config_hostname.startswith(remote_hostname + ".") or remote_hostname.startswith(config_hostname + "."):
            return alias
    # K8s: pod hostname (name-<hash>-<hash>) vs service FQDN (name-svc.domain)
    for config_hostname, alias in ssh_hostname_map.items():
        svc_idx = config_hostname.find("-svc.")
        if svc_idx > 0:
            base = config_hostname[:svc_idx]
            if remote_hostname.startswith(base + "-") or remote_hostname == base:
                return alias
    return None


def cleanup_proxy_session():
    """Kill stale proxy session from previous runs"""
    subprocess.run(
        [TMUX_BIN, "kill-session", "-t", PROXY_SESSION],
        capture_output=True, timeout=5,
    )
    proxy_panes.clear()


def get_user_ssh_auth_sock():
    """Get SSH_AUTH_SOCK from the user's main tmux server (has keys loaded)"""
    result = subprocess.run(
        [TMUX_BIN, "show-environment", "SSH_AUTH_SOCK"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode == 0:
        line = result.stdout.strip()
        if "=" in line and not line.startswith("-"):
            return line.split("=", 1)[1]
    return None


def create_proxy_pane(session_id, ssh_host, remote_target):
    """Create a proxy tmux pane for a remote session, return (tty, pid) or (None, None)"""
    window_name = session_id[:12]

    # Check if proxy session exists
    result = subprocess.run(
        [TMUX_BIN, "has-session", "-t", PROXY_SESSION],
        capture_output=True, timeout=5,
    )
    python_bin = shutil.which("python3") or sys.executable
    base_cmd = f"{python_bin} {PROXY_SCRIPT} {session_id} {ssh_host} {remote_target}"

    # Use cached SSH_AUTH_SOCK from user's tmux (has keys loaded)
    if user_ssh_auth_sock:
        cmd = f"SSH_AUTH_SOCK={user_ssh_auth_sock} {base_cmd}"
    else:
        cmd = base_cmd

    if result.returncode != 0:
        # Create session with first window
        subprocess.run(
            [TMUX_BIN, "new-session", "-d", "-s", PROXY_SESSION, "-n", window_name, cmd],
            capture_output=True, timeout=5,
        )
    else:
        # Add window to existing session
        subprocess.run(
            [TMUX_BIN, "new-window", "-d", "-t", PROXY_SESSION, "-n", window_name, cmd],
            capture_output=True, timeout=5,
        )

    # Get pane TTY and PID
    result = subprocess.run(
        [TMUX_BIN, "list-panes", "-t", f"{PROXY_SESSION}:{window_name}",
         "-F", "#{pane_tty} #{pane_pid}"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode == 0 and result.stdout.strip():
        parts = result.stdout.strip().split()
        tty, pid = parts[0], int(parts[1])
        proxy_panes[session_id] = {
            "remote_target": remote_target,
            "ssh_host": ssh_host,
            "tty": tty,
            "pid": pid,
            "window": window_name,
        }
        print(f"[{time.strftime('%H:%M:%S')}] proxy: created {window_name} tty={tty} pid={pid}")
        return tty, pid

    return None, None


def is_proxy_pane_alive(session_id):
    """Check if proxy pane is still alive"""
    info = proxy_panes.get(session_id)
    if not info:
        return False
    result = subprocess.run(
        [TMUX_BIN, "list-panes", "-t", f"{PROXY_SESSION}:{info['window']}",
         "-F", "#{pane_pid}"],
        capture_output=True, text=True, timeout=5,
    )
    return result.returncode == 0 and result.stdout.strip() != ""


def destroy_proxy_pane(session_id):
    """Destroy proxy pane for a session"""
    info = proxy_panes.pop(session_id, None)
    if info:
        subprocess.run(
            [TMUX_BIN, "kill-window", "-t", f"{PROXY_SESSION}:{info['window']}"],
            capture_output=True, timeout=5,
        )
        print(f"[{time.strftime('%H:%M:%S')}] proxy: destroyed {info['window']}")


def destroy_all_proxy_panes():
    """Destroy the entire proxy session"""
    proxy_panes.clear()
    subprocess.run(
        [TMUX_BIN, "kill-session", "-t", PROXY_SESSION],
        capture_output=True, timeout=5,
    )
    print(f"[{time.strftime('%H:%M:%S')}] proxy: destroyed all")


def ensure_proxy_pane(state):
    """Ensure proxy pane exists for a remote session, override pid/tty in state"""
    remote_target = state.get("remote_tmux_target")
    remote_hostname = state.get("remote_hostname")
    session_id = state.get("session_id")

    if not remote_target or not session_id:
        return

    # Resolve SSH host
    ssh_host = resolve_ssh_host(remote_hostname) if remote_hostname else None
    if not ssh_host:
        return

    existing = proxy_panes.get(session_id)

    # If target changed, destroy and recreate
    if existing and existing["remote_target"] != remote_target:
        print(f"[{time.strftime('%H:%M:%S')}] proxy: target changed for {session_id[:8]}")
        destroy_proxy_pane(session_id)
        existing = None

    # Create if not exists or dead
    if not existing or not is_proxy_pane_alive(session_id):
        if existing:
            proxy_panes.pop(session_id, None)
        tty, pid = create_proxy_pane(session_id, ssh_host, remote_target)
        if tty and pid:
            state["pid"] = pid
            state["tty"] = tty
    else:
        state["pid"] = existing["pid"]
        state["tty"] = existing["tty"]


def forward_to_island(state, timeout=5):
    try:
        s = sock.socket(sock.AF_UNIX, sock.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCKET_PATH)
        s.sendall(json.dumps(state).encode())
        # For permission requests, wait for response
        if state.get("status") == "waiting_for_approval":
            response = s.recv(4096)
            s.close()
            if response:
                return json.loads(response.decode())
            return None
        s.close()
        return True
    except (sock.error, OSError, json.JSONDecodeError):
        return False


async def run_bridge():
    import nats

    # Parse SSH config for hostname → alias resolution
    global ssh_hostname_map
    ssh_hostname_map = parse_ssh_config()
    if ssh_hostname_map:
        print(f"nats-bridge: loaded {len(ssh_hostname_map)} SSH host mappings")

    # Cache SSH_AUTH_SOCK from user's tmux (has keys loaded)
    global user_ssh_auth_sock
    user_ssh_auth_sock = get_user_ssh_auth_sock()
    if user_ssh_auth_sock:
        print(f"nats-bridge: SSH_AUTH_SOCK={user_ssh_auth_sock}")

    # Clean up stale proxy session from previous runs
    cleanup_proxy_session()

    print(f"nats-bridge: connecting to {NATS_URL}")
    nc = await nats.connect(NATS_URL)
    print(f"nats-bridge: subscribed to {SUBJECT_STATE}, {SUBJECT_PERMISSION}")
    print(f"nats-bridge: transcripts to {CLAUDE_PROJECTS}")

    async def handle_state(msg):
        """Handle fire-and-forget state events"""
        try:
            state = json.loads(msg.data.decode())
        except json.JSONDecodeError:
            return

        transcript_path = get_transcript_path(state)
        state["transcript_path"] = transcript_path

        wrote = write_transcript(state, transcript_path)
        if wrote:
            print(f"[{time.strftime('%H:%M:%S')}] wrote: {transcript_path}")

        # Manage proxy pane for remote tmux sessions
        remote_target = state.get("remote_tmux_target")
        remote_host = state.get("remote_hostname")
        if state.get("status") == "ended":
            destroy_proxy_pane(state.get("session_id", ""))
        elif remote_target:
            ssh_alias = resolve_ssh_host(remote_host) if remote_host else None
            print(f"[{time.strftime('%H:%M:%S')}] remote: target={remote_target} host={remote_host} ssh={ssh_alias}")
            ensure_proxy_pane(state)

        result = forward_to_island(state)
        label = "forwarded" if result else "socket unavailable"
        session = state.get("session_id", "?")[:8]
        event = state.get("event", "?")
        status = state.get("status", "?")
        pid = state.get("pid")
        tty = state.get("tty", "")
        print(f"[{time.strftime('%H:%M:%S')}] {label}: {session} {event}={status} pid={pid} tty={tty}")

    async def handle_permission(msg):
        """Handle request/reply permission events — forward to Claude Island and reply"""
        try:
            state = json.loads(msg.data.decode())
        except json.JSONDecodeError:
            return

        transcript_path = get_transcript_path(state)
        state["transcript_path"] = transcript_path

        session = state.get("session_id", "?")[:8]
        tool = state.get("tool", "?")
        print(f"[{time.strftime('%H:%M:%S')}] permission: {session} {tool}")

        # Forward to Claude Island and wait for approve/deny (in thread to avoid blocking event loop)
        response = await asyncio.get_event_loop().run_in_executor(
            None, lambda: forward_to_island(state, timeout=300)
        )

        if isinstance(response, dict):
            reply = json.dumps(response).encode()
            print(f"[{time.strftime('%H:%M:%S')}] replied: {response.get('decision', '?')}")
        else:
            # No response from Claude Island — tell remote to fall back to terminal UI
            reply = json.dumps({"decision": "ask"}).encode()
            print(f"[{time.strftime('%H:%M:%S')}] replied: ask (fallback)")

        await msg.respond(reply)

    await nc.subscribe(SUBJECT_STATE, cb=handle_state)
    await nc.subscribe(SUBJECT_PERMISSION, cb=handle_permission)

    # Keep running
    stop = asyncio.Event()
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()
    destroy_all_proxy_panes()
    await nc.close()
    print("\nnats-bridge: stopped")


def write_pid():
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def read_pid():
    try:
        with open(PID_FILE) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None


def is_running(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def cmd_start():
    write_pid()
    try:
        asyncio.run(run_bridge())
    finally:
        try:
            os.unlink(PID_FILE)
        except FileNotFoundError:
            pass


def cmd_stop():
    pid = read_pid()
    if not pid or not is_running(pid):
        print("nats-bridge: not running")
        return
    os.kill(pid, signal.SIGTERM)
    print(f"nats-bridge: stopped (pid {pid})")
    try:
        os.unlink(PID_FILE)
    except FileNotFoundError:
        pass


def cmd_status():
    pid = read_pid()
    if pid and is_running(pid):
        print(f"nats-bridge: running (pid {pid})")
    else:
        print("nats-bridge: not running")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "start"
    {"start": cmd_start, "stop": cmd_stop, "status": cmd_status}.get(cmd, cmd_start)()
