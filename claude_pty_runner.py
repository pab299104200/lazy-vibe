#!/usr/bin/env python3
"""Drive interactive Claude through a PTY for harnesses that cannot use claude -p."""
from __future__ import annotations

import os
import re
import shlex
import sys
import time

try:
    import pexpect
except Exception as exc:  # pragma: no cover - environment guard
    sys.stderr.write(f"[claude-pty] pexpect is required: {exc}\n")
    raise SystemExit(2)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: claude_pty_runner.py PROMPT_FILE CLAUDE [ARGS...]\n")
        return 2

    prompt_file = sys.argv[1]
    cmd = sys.argv[2:]
    with open(prompt_file, encoding="utf-8") as handle:
        prompt = handle.read()

    startup_seconds = float(os.environ.get("CLAUDE_PTY_STARTUP_SECONDS", "3"))
    idle_after_result = float(os.environ.get("CLAUDE_PTY_IDLE_AFTER_RESULT_SECONDS", "20"))
    result_re = re.compile(r"RESULT:\s*(PASS|FAIL|INCOMPLETE|BLOCKED)", re.I)

    sys.stdout.write("[claude-pty] spawning: " + " ".join(shlex.quote(part) for part in cmd) + "\n")
    sys.stdout.flush()
    child = pexpect.spawn(cmd[0], cmd[1:], encoding="utf-8", timeout=1, echo=False, dimensions=(40, 160))
    last_output = time.monotonic()
    result_seen = False
    output_tail = ""

    end_startup = time.monotonic() + startup_seconds
    while time.monotonic() < end_startup:
        try:
            chunk = child.read_nonblocking(size=4096, timeout=0.25)
        except pexpect.TIMEOUT:
            continue
        except pexpect.EOF:
            sys.stdout.write("\n[claude-pty] claude exited before prompt was sent\n")
            sys.stdout.flush()
            return child.exitstatus if child.exitstatus is not None else 1
        if chunk:
            sys.stdout.write(chunk)
            sys.stdout.flush()
            last_output = time.monotonic()
            output_tail = (output_tail + chunk)[-8000:]

    child.send("\x1b[200~" + prompt + "\x1b[201~")
    child.send("\r")
    sys.stdout.write("\n[claude-pty] prompt pasted; monitoring terminal output\n")
    sys.stdout.flush()

    while True:
        try:
            chunk = child.read_nonblocking(size=4096, timeout=1)
        except pexpect.TIMEOUT:
            now = time.monotonic()
            if result_seen and now - last_output >= idle_after_result:
                sys.stdout.write(
                    f"\n[claude-pty] RESULT observed and terminal idle for {idle_after_result:.0f}s; exiting session\n"
                )
                sys.stdout.flush()
                child.sendcontrol("c")
                time.sleep(0.5)
                child.sendline("/exit")
                try:
                    child.expect(pexpect.EOF, timeout=5)
                except Exception:
                    child.terminate(force=True)
                return 0
            continue
        except pexpect.EOF:
            sys.stdout.write("\n[claude-pty] claude exited\n")
            sys.stdout.flush()
            return child.exitstatus if child.exitstatus is not None else 0

        if not chunk:
            continue
        sys.stdout.write(chunk)
        sys.stdout.flush()
        last_output = time.monotonic()
        output_tail = (output_tail + chunk)[-8000:]
        if result_re.search(output_tail):
            result_seen = True


if __name__ == "__main__":
    raise SystemExit(main())
