#!/usr/bin/env python3
"""
Proxy pane relay — runs inside a local tmux pane.

Claude Island sends keystrokes via `tmux send-keys` to this pane.
Each line read from stdin is forwarded to the remote Claude Code
session via SSH + tmux send-keys.
"""
import shlex
import subprocess
import sys


def ensure_ssh_agent_keys():
    """Load SSH keys from macOS Keychain if agent has none"""
    result = subprocess.run(
        ["ssh-add", "-l"], capture_output=True, text=True, timeout=5,
    )
    if "no identities" in result.stderr or result.returncode != 0:
        # Load keys previously stored in Keychain (non-interactive)
        subprocess.run(
            ["ssh-add", "--apple-load-keychain"], capture_output=True, timeout=5,
        )


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <session_id> <ssh_host> <remote_tmux_target>")
        sys.exit(1)

    session_id = sys.argv[1]
    ssh_host = sys.argv[2]
    remote_target = sys.argv[3]

    ensure_ssh_agent_keys()

    print(f"proxy-pane [{session_id[:8]}] ssh={ssh_host} target={remote_target}")
    print("Waiting for input...")

    while True:
        try:
            line = input()
        except EOFError:
            break

        if not line:
            continue

        escaped_text = shlex.quote(line)
        escaped_target = shlex.quote(remote_target)
        remote_cmd = (
            f"tmux send-keys -t {escaped_target} -l {escaped_text}"
            f" && tmux send-keys -t {escaped_target} Enter"
        )

        try:
            result = subprocess.run(
                [
                    "ssh",
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    ssh_host,
                    remote_cmd,
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != 0:
                print(f"[error] ssh exit {result.returncode}: {result.stderr.strip()}")
        except subprocess.TimeoutExpired:
            print(f"[timeout] Failed to relay: {line[:50]}")
        except Exception as e:
            print(f"[error] {e}")


if __name__ == "__main__":
    main()
